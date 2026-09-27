# Inference on hal (10.1.1.105)

Runs an OpenAI-compatible LLM server as a Docker container managed by systemd
on `hal`, an **AMD Ryzen AI Max "Strix Halo"** box. This is not a CUDA
machine, so the setup differs substantially from a stock install of either
engine below.

The host gets **Docker and nothing else** — no ROCm, no PyTorch, no build
toolchain, no Python environment. Everything the engine needs lives inside its
container image.

**Current deployment: llama.cpp (Vulkan), serving Qwen3.8-27B.** vLLM served a
30B model here until 2026-09-05, when we hit a hardware ceiling with a
follow-up model (below) and pivoted. Both playbooks are kept in this
directory — see [Why we moved off vLLM](#why-we-moved-off-vllm) — but only run
one engine at a time; they fight over the GPU and the `matthew` user's Docker
socket, and llama.cpp claims `--publish 0.0.0.0:8000`, the same host port vLLM
used.

## What the target actually is

Probed on 2026-08-02:

| | |
|---|---|
| GPU | Radeon 8060S iGPU, **gfx1151** (RDNA 3.5) |
| VRAM | 64 GiB dedicated (BIOS UMA carveout); Vulkan additionally reports GTT-backed headroom up to ~94.7 GiB total heap |
| System RAM | 61 GB usable, GTT 30.6 GiB |
| CPU | 32 threads |
| Disk | 83 GB free on `/` at probe time (grow the LV if this is tight — see the assert message in either playbook) |
| OS | Ubuntu 26.04 LTS ("resolute"), kernel 7.0.0-28-generic |

The amdgpu **kernel** driver is already in-tree and loaded — `/dev/kfd` and
`/dev/dri/renderD128` exist — so no DKMS and no host driver install is needed
for either engine. llama.cpp/Vulkan only touches `/dev/dri`; vLLM/ROCm needed
`/dev/kfd` too.

## Layout

```
hal.server/
├── ansible.cfg                  # inventory + become_ask_pass (hal needs a sudo password)
├── inventory.yml                # hal -> 10.1.1.105, in both the vllm and llama_cpp groups
├── group_vars/
│   ├── llama_cpp.yml            # current: image pin, model, and all tunables
│   ├── laya_cpp.yml             # laya.cpp: source pin, model revision, server args
│   └── vllm.yml                 # retired: kept for rollback, see below
├── files/
│   ├── trocr/
│   │   ├── Dockerfile           # TrOCR OCR service image (app.py + torch)
│   │   └── app.py
│   └── laya-cpp/
│       ├── Dockerfile           # laya.cpp CPU/Vulkan server image
│       ├── entrypoint.sh        # preserves server defaults while accepting runtime flags
│       └── README.md
├── llama-cpp.yml                # current playbook
├── laya.cpp.yml                 # laya.cpp (typed-decision model) build and service
├── vllm.yml                     # retired playbook, still runnable
├── trocr.yml                    # provisions microsoft/trocr-base-handwritten
├── uninstall.yaml               # vLLM teardown (llama.cpp has no equivalent yet)
└── templates/
    ├── llama-cpp.service.j2     # current: systemd unit wrapping `docker run`
    ├── vllm.service.j2          # retired
    └── vllm.env.j2              # retired
```

## Usage

```bash
cd hal.server
ansible-playbook llama-cpp.yml -K          # -K because sudo on hal needs a password
ansible-playbook laya.cpp.yml -K           # laya.cpp Vulkan build and service
ansible-playbook trocr.yml -K              # cache TrOCR for handwritten OCR
```

laya.cpp can also run as a plain Docker container instead of the native
build (same port 8001, don't run both at once) — see
[Running laya.cpp as a standalone Docker image](#running-laya-cpp-as-a-standalone-docker-image).

## Running laya.cpp as a standalone Docker image

The `files/laya-cpp/` directory contains a self-contained image: it compiles
`laya-cli` from source and bakes in the pinned English checkpoint (~843 MB),
so a fresh machine needs nothing but Docker. The same image serves all three
backends — select one at `docker run` time:

```bash
cd hal.server
docker build -t laya-cpp files/laya-cpp

docker run --rm -p 8001:8001 laya-cpp                                   # CPU (default), any machine
docker run --rm -p 8001:8001 --device /dev/dri laya-cpp --amd-gpu      # AMD/Intel Linux
# NVIDIA Linux (driver + NVIDIA Container Toolkit on the host):
docker run --rm -p 8001:8001 --device nvidia.com/gpu=all laya-cpp --nvidia-gpu
```

Notes:

- The backend can also be selected with `-e LAYA_BACKEND=cpu|amd|nvidia`;
  the flag and the env var are equivalent. Legacy `--vulkan` maps to
  `--amd-gpu`.
- On **Docker 29+** hosts, `--gpus all` can fail with
  `AMD CDI spec not found` even with NVIDIA correctly configured; the explicit
  CDI form `--device nvidia.com/gpu=all` works on all Docker versions.
- The build requires ubuntu:26.04-era packages (the 24.04 glslc segfaults on
  laya's Vulkan shaders). A pure-CPU image without Vulkan is available with
  `--build-arg LAYA_VULKAN=OFF`.
- On hal itself, the image runs fine with `--device /dev/dri` and
  `--amd-gpu` against the Radeon 8060S iGPU — but the native ansible service
  already holds port 8001, and both share the GPU with llama.cpp, so pick one
  and stop the others.

`files/laya-cpp/README.md` covers pinned revisions, the NVIDIA CDI note in
detail, backend-selection mechanics, and the HTTP endpoints.

The TrOCR playbook downloads `microsoft/trocr-base-handwritten` into
`/opt/trocr/models/trocr-base-handwritten` using a temporary Python container;
it does not install Python or PyTorch on the host. An OCR application can mount
that directory and load it with Transformers' `VisionEncoderDecoderModel`.
Use `--tags model` to re-download/update the model, or `--tags verify` to check
that the cache is present.

First run pulls the image (~310 MB, trivial next to vLLM's 47 GB) plus ~18.9
GB of target and MTP weights, so budget time for the weights on a slow link.
Re-runs skip each file if already present.

Useful tags:

```bash
ansible-playbook llama-cpp.yml -K --tags preflight   # check GPU, disk
ansible-playbook llama-cpp.yml -K --tags image       # pull image, verify Vulkan device
ansible-playbook llama-cpp.yml -K --tags model       # (re-)download weights only
ansible-playbook llama-cpp.yml -K --tags service     # re-render the unit and restart
ansible-playbook llama-cpp.yml -K --tags verify      # poll /health and list models
```

## Laya and laya.cpp

Laya is a typed-decision model/runtime, separate from the generative LLM API
served by llama.cpp. The `laya.cpp.yml` playbook provisions Vulkan build
dependencies, checks out laya.cpp, builds it, and installs a systemd service.
It has a separate inventory group and defaults to port 8001 to avoid the
llama.cpp service on port 8000.

`group_vars/laya_cpp.yml` was checked against upstream (lkarlslund/laya.cpp,
2026-09-26): the Vulkan build flags (`-DLAYA_CUDA=OFF -DLAYA_VULKAN=ON`,
CMake 3.24+, C++20, ICU, nlohmann-json, glslc/SPIR-V headers, ggml and
cpp-httplib submodules) produce `build-vulkan/bin/laya-cli`; the server is
`laya-cli --server --host ADDR --port PORT --model <store-root> --variant
english --vulkan`; routes are `GET /health`, `GET /v1/models`,
`POST /v1/systemone` (JEV schema) and `POST /predict` (batched). The English
checkpoint is the five files under the store root of
`convaiinnovations/laya` (pinned revision `55cf4c4...`, ~843 MB
`model.safetensors`); multilingual and typed-decisions live under
`<store-root>/multilingual/` and `<store-root>/typed-decisions/`.

A self-contained container alternative lives in `files/laya-cpp/`
(Dockerfile + usage notes) — see the
[standalone Docker image section above](#running-laya-cpp-as-a-standalone-docker-image)
for build/run commands and backend selection. Since both services use the
same GPU, consider stopping llama.cpp while running laya.cpp workloads.

## How it runs

systemd owns a foreground `docker run --rm`, so `systemctl status llama-cpp`
reflects the real container state and there is no detached container to drift
out of sync:

```
ExecStartPre=-/usr/bin/docker rm -f llama-cpp   # clear a container left by an unclean stop
ExecStart=/usr/bin/docker run --rm --name llama-cpp ... /app/llama-server ...
ExecStop=/usr/bin/docker stop --time 30 llama-cpp
```

## Measured on hal

`unsloth/Qwen3.8-27B-GGUF`, target quant `UD-Q8_K_XL` with the separate
`MTP/mtp-Qwen3.8-27B-Q4_0.gguf` draft head, `--ctx-size 262144`,
`--gpu-layers all`, and `--flash-attn auto` on Vulkan/RADV. The service enables
llama.cpp's native `draft-mtp` speculative decoding with up to three draft
tokens per step.

The target model is about 31.46 GB and the MTP draft head is about 1.37 GB,
so the preflight budget rounds the combined download to 34 GB. The previously
cached lower-quanted files are not removed and can still be used for rollback by changing
`llama_cpp_model_file`; the current service also needs the MTP draft file.

The existing hal benchmark for UD-Q4_K_XL without MTP was ~12.0 tok/s decode;
there is no UD-Q8_K_XL + MTP benchmark yet. MTP throughput is hardware- and
workload-dependent, so measure the deployed
service rather than assuming a fixed speedup. MTP adds verification work and
can reduce prompt-processing throughput even when it improves generation.

For comparison, the retired vLLM deployment measured ~19.6 tok/s decode with
a *different* model (30B MoE, real `awq_marlin` INT4 kernel) and ~1.9 tok/s
decode with the *same-generation* Qwen3.8-27B on a Quark/MXFP4 quant, because
gfx1151 has no native MXFP4 compute path. See below for the full story.

## Why we moved off vLLM

Short version: we deployed `amd/Qwen3.8-27B-Quark-AWQ-MXFP4` on vLLM first
(see `group_vars/vllm.yml`'s model-selection comments for that whole saga),
and it worked *correctly* but was unusable slow — ~1.9 tok/s — because gfx1151
cannot do native MXFP4 math. vLLM's own log says so outright:

```
The current platform does not support native MXFP4/MXFP6 computation.
Simulated weight dequantization ... will be used, with the linear layers
computed in high precision.
```

That is a silent ~10x regression with no error and no obvious warning outside
the engine log — the server answers requests fine, just slowly. Rather than
chase down a different vLLM-compatible quant (plain AWQ was the other option,
but ROCm's AWQ/GPTQ kernels on gfx1151 are picky about `group_size`, and FP8
MoE isn't supported on ROCm at all — see the compatibility table in the old
section below), we tried llama.cpp with the same model family in GGUF form and
a Vulkan backend, and it was both **faster** (~12 tok/s, a 6x win over the
MXFP4 fallback) and **simpler to run** (no ROCm, no `/dev/kfd`, a 310 MB image
instead of 47 GB, ~5s cold start instead of ~10 minutes of
compile/warmup). That combination made the switch an easy call.

If you're deciding between the two engines on this hardware in the future:
llama.cpp/Vulkan is the better default for gfx1151 today. Reach for vLLM only
if you need something it does that llama.cpp doesn't (e.g. specific batching
behavior at higher concurrency, or a model architecture llama.cpp hasn't
implemented yet) — and if the quant format matters, check the same class of
gotcha this section describes before assuming a quant "works" just because the
server starts.

## Verifying

The playbook polls `/health` and prints the served model list. Manually:

```bash
curl http://10.1.1.105:8000/v1/models

curl http://10.1.1.105:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.8-27b","messages":[{"role":"user","content":"hello"}]}'
```

## Things worth knowing (llama.cpp / current)

- **Vulkan needs only `/dev/dri`.** No `/dev/kfd`, no ROCm userspace, no
  `HSA_OVERRIDE_GFX_VERSION` concerns. `--group-add` still uses the numeric
  `video` GID for the same reason the vLLM role resolved GIDs with `getent`:
  the container's `/etc/group` doesn't know the host's GID assignments.
- **`--gpu-layers all` and `--ctx-size 262144` together used only ~34 GiB** of
  the ~94.7 GiB Vulkan reports as its heap ceiling (64 GiB dedicated VRAM +
  GTT-backed system RAM). There's real headroom to raise context further or
  add concurrent slots — see `n_slots`/`kv_unified` in the server startup log
  before assuming you need to shrink anything.
- **The `--alias` flag sets the served model id.** Without it, the OpenAI
  `model` field is the literal in-container file path
  (e.g. `/models/Qwen3.8-27B-UD-Q3_K_XL.gguf`), which is what you'll see if you
  ever run the image manually without this flag.
- **`--reasoning-format deepseek` puts the model's `<think>...</think>` output
  in `message.reasoning_content`** instead of leaving it inline in
  `message.content`. This model is a hybrid thinking/non-thinking model (same
  family as the vLLM-era deployment), so client configs need to handle
  `reasoning_content` — see `~/.pi/agent/models.json` on this machine for how
  Pi's config maps that in.
- **Tool calling and the model's own chat template work out of the box** with
  `--jinja` (the default), no separate `--tool-call-parser`-equivalent flag
  needed the way vLLM required matching `hermes` to the model family.
- **The unsloth install guide this deployment is based on is generic and
  CUDA-first.** Its build-from-source instructions target a bare Linux/CUDA
  box, not a Docker-only host. We used its *model and quant recommendation*
  (`unsloth/Qwen3.8-27B-GGUF`, `UD-Q8_K_XL`) and download URL, but substituted
  the official `ghcr.io/ggml-org/llama.cpp:server-vulkan` image for its
  compile-from-source steps, consistent with how this repo already ran vLLM.
- **The API is unauthenticated by default.** Set `llama_cpp_api_key` to
  require `Authorization: Bearer <key>`.
- **ufw will not actually gate this port**, for the same reason as the vLLM
  role: Docker inserts its own iptables rules ahead of ufw for published
  ports. Treat the endpoint as reachable by anything that can route to hal
  unless you also restrict Docker's own chains, or set
  `llama_cpp_bind_host: 127.0.0.1`.

## Things worth knowing (vLLM / retired, kept for rollback)

- **Disk is the binding constraint, and the fix is LVM, not cleanup.** The
  vLLM image is 47 GB extracted and its default model ~20 GB, against a root
  LV that Ubuntu's installer sized at 100 GB — while leaving ~1.72 TB of the
  1.8 TB NVMe unallocated in `ubuntu-vg`. To grow it (ext4 resizes online, no
  unmount):

  ```bash
  sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv   # or -L +500G
  sudo resize2fs /dev/ubuntu-vg/ubuntu-lv
  ```

- **GPU passthrough is verified before the service is configured.** The
  playbook runs `torch.cuda.is_available()` inside the image with the same
  `--device` and `--group-add` flags the unit will use, so a passthrough
  problem surfaces as a clear failure rather than a systemd restart loop.
- **`--group-add` uses numeric GIDs**, same reasoning as the llama.cpp role
  above but for two groups (`render` and `video`, since ROCm compute needs
  both `/dev/kfd` and `/dev/dri`).
- **The container runs as root internally**, which is what AMD documents and
  what the image expects. Files it writes into `/opt/vllm/models` are
  therefore root-owned.
- **`HSA_OVERRIDE_GFX_VERSION` is deliberately unset.** gfx1151 is natively
  supported in ROCm 7.13. The override to `11.0.0` that older Strix Halo
  guides recommend would now select the *wrong* kernels.
- **The model's quantisation format is load-bearing — and the failure mode is
  not always a refusal to start. It can also just be silently slow.** Verified
  on hal:

  | Model | Result |
  |---|---|
  | `ELVISIO/…-AWQ` (AWQ 4-bit, group 128) | **works well** — `awq_marlin` kernel, ~19.6 tok/s |
  | `amd/…-Quark-AWQ-MXFP4` | **starts and works, but slow** — gfx1151 has no native MXFP4 compute, so vLLM falls back to "simulated weight dequantization" computed in bf16: ~1.9 tok/s |
  | `Qwen/…-FP8` | `NotImplementedError: No FP8 MoE backend supports the deployment configuration` |
  | `cyankiwi/…-AWQ-4bit` (group 32) | `Failed to find a kernel that can implement the WNA16 linear layer` |
  | BF16 | ~56-61 GB of weights depending on model size; will not fit in 64 GiB with a usable KV cache |

  The MXFP4 case is the one that ultimately drove the pivot to llama.cpp: no
  error, no warning that surfaces outside the logs, and the server answers
  requests correctly — just ~10x slower than a model with a real accelerated
  kernel.

  For AWQ/GPTQ, `ConchLinearKernel` supports only group sizes `[-1, 128]`, and
  `ExllamaLinearKernel` needs float16 activations. So check `group_size` in
  the repo's `config.json` before trying another AWQ candidate on vLLM/ROCm —
  128 works, 32 does not.
- **`VLLM_ROCM_USE_AITER` was deliberately left unset**, not set to 0 — vLLM's
  backend oracle treats the variable being *set at all* as an explicit
  request and drops AITER from consideration without testing it. AITER
  already reports "does not support current device rocm" on gfx1151 anyway.
- **Secrets**: `vllm_hf_token` and `vllm_api_key` are empty in git on purpose.
  Pass them with `-e` or ansible-vault; they land in `/opt/vllm/vllm.env` at
  mode `0600`.

To bring vLLM back: `ansible-playbook vllm.yml -K` re-renders and restarts
its unit. Stop llama.cpp first (`sudo systemctl stop llama-cpp`) — they both
want port 8000 and the GPU.
