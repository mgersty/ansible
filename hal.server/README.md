# vLLM on hal (10.1.1.105)

Runs vLLM as a Docker container managed by systemd on `hal`, an **AMD Ryzen AI
Max "Strix Halo"** box. This is not a CUDA machine, so the setup differs
substantially from a stock vLLM install.

The host gets **Docker and nothing else** — no ROCm, no PyTorch, no Python build
environment. All of that lives inside AMD's prebuilt gfx1151 image.

## What the target actually is

Probed on 2026-08-02:

| | |
|---|---|
| GPU | Radeon 8060S iGPU, **gfx1151** (RDNA 3.5) |
| VRAM | 64 GiB dedicated (BIOS UMA carveout) |
| System RAM | 61 GB usable, GTT 30.6 GiB |
| CPU | 32 threads |
| Disk | 83 GB free on `/` |
| OS | Ubuntu 26.04 LTS ("resolute"), kernel 7.0.0-28-generic |

The amdgpu **kernel** driver is already in-tree and loaded — `/dev/kfd` and
`/dev/dri/renderD128` exist — so no DKMS and no host driver install is needed.
Only the userspace stack has to be supplied, and the container brings it.

## The image

```
rocm/vllm:rocm7.13.0_gfx1151_ubuntu24.04_py3.13_pytorch_2.10.0_vllm_0.19.1
```

10.3 GB compressed but **47 GB extracted** (measured on hal — ROCm layers
compress ~4.6x, so the registry figure badly understates the disk cost), pushed
2026-05-19. It bundles ROCm 7.13.0,
PyTorch 2.10.0 and vLLM 0.19.1, all built for gfx1151.

It is **pinned by digest**, not by tag, so a retagged upstream image cannot
silently change what runs here:

```
rocm/vllm@sha256:394194d36edcf9b36bcb563e143b21b80e64e7d04f33a447b448c0c0c00c04a8
```

Set `vllm_image_pin_digest: false` to follow the mutable tag instead.

## Layout

```
hal.server/
├── ansible.cfg              # inventory + become_ask_pass (hal needs a sudo password)
├── inventory.yml            # hal -> 10.1.1.105
├── group_vars/vllm.yml      # image pin, model, and all tunables
├── vllm.yml                 # main playbook
├── uninstall.yaml           # teardown
└── templates/
    ├── vllm.service.j2      # systemd unit wrapping `docker run`
    └── vllm.env.j2          # --env-file contents (0600; may hold tokens)
```

## Usage

```bash
cd hal.server
ansible-playbook vllm.yml -K          # -K because sudo on hal needs a password
```

First run pulls ~10 GB of image plus ~32 GB of weights, so budget time. Re-runs
skip both if already present.

Useful tags:

```bash
ansible-playbook vllm.yml -K --tags preflight   # check GPU, disk
ansible-playbook vllm.yml -K --tags image       # pull image, verify GPU passthrough
ansible-playbook vllm.yml -K --tags service     # re-render the unit and restart
ansible-playbook vllm.yml -K --tags verify      # poll /health and list models
```

Teardown (keeps weights and image unless told otherwise):

```bash
ansible-playbook uninstall.yaml -K
ansible-playbook uninstall.yaml -K -e vllm_remove_models=true -e vllm_remove_image=true
```

Docker itself is never removed.

## How it runs

systemd owns a foreground `docker run --rm`, so `systemctl` status reflects the
real container state and there is no detached container to drift out of sync:

```
ExecStartPre=-/usr/bin/docker rm -f vllm      # clear a container left by an unclean stop
ExecStart=/usr/bin/docker run --rm --name vllm ... vllm serve ...
ExecStop=/usr/bin/docker stop --time 30 vllm
```
## Measured on hal

With `ELVISIO/Qwen3-30B-A3B-Instruct-2507-AWQ` at `--gpu-memory-utilization 0.90`:

```
Model loading took            15.87 GiB
Available KV cache memory     40.83 GiB   (445,984 tokens)
init engine                    7.40 s
```

There is far more KV cache than `vllm_max_model_len: 32768` needs — this model
supports up to 262144 natively, so raising the context is cheap if you want it.

## Verifying
The playbook polls `/health` and prints the served model list. Manually:

```bash
curl http://10.1.1.105:8000/v1/models

curl http://10.1.1.105:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3-30b","messages":[{"role":"user","content":"hello"}]}'
```

## Things worth knowing

- **Disk is the binding constraint, and the fix is LVM, not cleanup.** The image
  is 47 GB extracted and the default model ~32 GB, against a root LV that
  Ubuntu's installer sized at 100 GB — while leaving ~1.72 TB of the 1.8 TB NVMe
  unallocated in `ubuntu-vg`. To grow it (ext4 resizes online, no unmount):

  ```bash
  sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv   # or -L +500G
  sudo resize2fs /dev/ubuntu-vg/ubuntu-lv
  ```

  Preflight only requires space for artefacts that are still *missing*, so a
  re-run after a successful pull does not fail on the space the pull consumed.
- **GPU passthrough is verified before the service is configured.** The playbook
  runs `torch.cuda.is_available()` inside the image with the same `--device` and
  `--group-add` flags the unit will use, so a passthrough problem surfaces as a
  clear failure rather than a systemd restart loop.
- **`--group-add` uses numeric GIDs.** Group *names* resolve against the
  container's `/etc/group`, but the device nodes are owned by host GIDs
  (`render`, `video`), so the playbook looks them up with `getent` and passes
  numbers.
- **Host GPU tooling needs two separate things**, and neither affects the
  container (which runs as root with GIDs passed via `--group-add`):
  1. **Group membership.** `/dev/dri/*` and `/dev/kfd` are mode 0660
     `root:render` / `root:video`. The playbook adds `vllm_gpu_group_users` to
     both; **log out and back in** for it to take effect.
  2. **`libdrm-amdgpu1`.** nvtop dlopens `libdrm_amdgpu.so.1` at runtime and
     does *not* declare it in `Depends`, so on a machine with only `libdrm2` it
     silently skips the AMD backend and reports "No GPU to monitor" with no clue
     that a library is missing. Installed via `vllm_host_gpu_tools`.

  Both produce the identical symptom, so check the library before assuming
  permissions.
- **The container runs as root internally**, which is what AMD documents and
  what the image expects. Files it writes into `/opt/vllm/models` are therefore
  root-owned. Membership of the `docker` group (granted to `matthew`) is
  effectively root on this host.
- **`HSA_OVERRIDE_GFX_VERSION` is deliberately unset.** gfx1151 is natively
  supported in ROCm 7.13. The override to `11.0.0` that older Strix Halo guides
  recommend would now select the *wrong* kernels.
- **`VLLM_ROCM_USE_AITER=0`.** AITER kernels target CDNA (MI300); they are not
  built for RDNA 3.5.
- **The model's quantisation format is load-bearing, and the failure mode is a
  refusal to start — not slowness.** Verified on hal:

  | Model | Result |
  |---|---|
  | `ELVISIO/…-AWQ` (AWQ 4-bit, group 128) | **works** — `awq_marlin` kernel |
  | `Qwen/…-FP8` | `NotImplementedError: No FP8 MoE backend supports the deployment configuration` |
  | `cyankiwi/…-AWQ-4bit` (group 32) | `Failed to find a kernel that can implement the WNA16 linear layer` |
  | BF16 | ~61 GB of weights; will not fit in 64 GiB with a usable KV cache |

  The FP8 repo uses DeepSeek-style **128×128 block-scaled** FP8. On ROCm the only
  candidate MoE backend is Triton, and it rejects that scheme
  (`QuantKey(f8e4m3fn, scale(f32, static, GroupShape(row=128, col=128)))`); every
  other backend rejects the *device*. Note dense FP8 is fine — the failure is
  specific to fused MoE layers, so a dense FP8 model would load.

  For AWQ/GPTQ, `ConchLinearKernel` supports only group sizes `[-1, 128]`, and
  `ExllamaLinearKernel` needs float16 activations. So **check `group_size` in the
  repo's `config.json` before switching models** — 128 works, 32 does not.
  `--dtype float16` is the fallback that unlocks Exllama for group-32 repos.
- **ufw will not actually gate this port.** Docker inserts its own iptables
  rules ahead of ufw for published ports. The rule is applied for completeness,
  but treat the endpoint as reachable by anything that can route to hal unless
  you also restrict Docker's own chains, or set `vllm_bind_host: 127.0.0.1`.
- **The API is unauthenticated by default.** Set `vllm_api_key` to require
  `Authorization: Bearer <key>`.
- **GTT tuning is off by default** (`vllm_tune_gtt: false`). hal already
  dedicates 64 GiB to VRAM, so raising `amdttm.pages_limit` buys nothing. It
  edits the kernel command line and needs a reboot.
- **Secrets**: `vllm_hf_token` and `vllm_api_key` are empty in git on purpose.
  Pass them with `-e` or ansible-vault; they land in `/opt/vllm/vllm.env` at
  mode `0600`.
