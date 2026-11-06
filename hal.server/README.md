# Inference on hal (10.1.1.105)

Runs an OpenAI-compatible LLM server as a Docker container managed by systemd
on `hal`, an **AMD Ryzen AI Max "Strix Halo"** box. This is not a CUDA
machine, so the setup differs substantially from a stock install of either
engine below.

The llama.cpp playbooks expect Docker and a ROCm/HIP-enabled image; host ROCm
userspace is provisioned separately. The playbooks do not install ROCm. The
legacy vLLM playbook has its own containerized ROCm setup.

**Current deployment: llama.cpp (ROCm/HIP) in router mode, serving Qwen3.8-27B
and the Kev-4B decision model on one port.** The service exposes the usual
OpenAI endpoints (`qwen3.8-27b`) plus llama.cpp's native `POST /v1/systemone`
typed-decision endpoint (`kev-4b`) — see [Decision models via
`/v1/systemone`](#decision-models-via-v1systemone). vLLM served a 30B model
here until 2026-09-05, when we hit a hardware ceiling with a follow-up model
(below) and pivoted. Both playbooks are kept in this directory — see [Why we
moved off vLLM](#why-we-moved-off-vllm) — but only run one engine at a time;
they fight over the GPU and the `matthew` user's Docker socket, and llama.cpp
claims `--publish 0.0.0.0:8000`, the same host port vLLM used.

## What the target actually is

Probed on 2026-08-02:

| | |
|---|---|
| GPU | Radeon 8060S iGPU, **gfx1151** (RDNA 3.5) |
| VRAM | 64 GiB dedicated (BIOS UMA carveout); total GPU-visible memory depends on the ROCm runtime and GTT configuration |
| System RAM | 61 GB usable, GTT 30.6 GiB |
| CPU | 32 threads |
| Disk | 83 GB free on `/` at probe time (grow the LV if this is tight — see the assert message in either playbook) |
| OS | Ubuntu 26.04 LTS ("resolute"), kernel 7.0.0-28-generic |

The amdgpu kernel driver and ROCm userspace are provisioned on the host.
llama.cpp/ROCm requires `/dev/kfd` and a DRM render node (configured by
`llama_cpp_render_node`); vLLM has its own ROCm container configuration.

## Layout

```
hal.server/
├── ansible.cfg                  # inventory + become_ask_pass (hal needs a sudo password)
├── inventory.yml                # hal -> 10.1.1.105, in the vllm, llama_cpp, laya_cpp, knowline, trocr groups
├── group_vars/
│   ├── llama_cpp.yml            # current: image backend, models (chat + decision), router, tunables
│   ├── laya_cpp.yml             # laya.cpp: source pin, model revision, server args
│   ├── knowline.yml             # KnowLine decision model: image, GGUF, server args
│   └── vllm.yml                 # retired: kept for rollback, see below
├── files/
│   └── laya-cpp/
│       ├── Dockerfile           # laya.cpp CPU/Vulkan server image
│       ├── entrypoint.sh        # preserves server defaults while accepting runtime flags
│       └── README.md
├── llama-cpp.yml                # current playbook (router mode: chat + decision model)
├── systemone-example.sh         # curl example for POST /v1/systemone on llama-cpp.service
├── laya.cpp.yml                 # laya.cpp (typed-decision model) build and service (superseded, see below)
├── knowline.yml                 # KnowLine-4B-Gen5.5 decision model (2nd llama.cpp container, :8002)
├── thinkingcap.yml              # ThinkingCap Qwen3.8-27B (2nd container, :8010); no inventory group currently
├── vllm.yml                     # retired playbook, still runnable
├── uninstall.yaml               # vLLM teardown (llama.cpp has no equivalent yet)
└── templates/
    ├── llama-cpp.service.j2     # current: systemd unit wrapping `docker run` (router + single-model branches)
    ├── llama-cpp.presets.ini.j2 # router-mode per-model presets (ctx, MTP draft, reasoning-format)
    ├── knowline.service.j2      # KnowLine decision model: systemd unit wrapping `docker run`
    ├── vllm.service.j2          # retired
    └── vllm.env.j2              # retired
```

## Usage

```bash
cd hal.server
ansible-playbook llama-cpp.yml -K          # -K because sudo on hal needs a password
ansible-playbook laya.cpp.yml -K           # laya.cpp Vulkan build and service (superseded by /v1/systemone)
ansible-playbook knowline.yml -K           # KnowLine-4B-Gen5.5 decision model on :8002
```

laya.cpp can also run as a plain Docker container instead of the native
build (same port 8001, don't run both at once) — see
[Running laya.cpp as a standalone Docker image](#running-laya-cpp-as-a-standalone-docker-image).

## Running laya.cpp as a standalone Docker image

The `files/laya-cpp/` directory contains a self-contained image: it compiles
`laya-cli` from source and bakes in the pinned typed-decisions checkpoint
(~843 MB),
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

First run pulls the image (~310 MB, trivial next to vLLM's 47 GB) plus ~34 GB
of target/MTP/mmproj weights and ~3 GB of decision-model weights, so budget
time for the weights on a slow link. Re-runs skip each file if already
present.

Useful tags:

```bash
ansible-playbook llama-cpp.yml -K --tags preflight   # check GPU, disk
ansible-playbook llama-cpp.yml -K --tags image       # pull image, verify ROCm/HIP device
ansible-playbook llama-cpp.yml -K --tags model       # (re-)download weights only
ansible-playbook llama-cpp.yml -K --tags service     # re-render the unit and restart
ansible-playbook llama-cpp.yml -K --tags verify      # poll /health and list models
```

## Decision models via `/v1/systemone`

llama.cpp natively serves typed "System 1" decision questions since build
b11361 ([ggml-org/llama.cpp#29818](https://github.com/ggml-org/llama.cpp/pull/29818);
[announcement](https://huggingface.co/blog/ggml-org/decision-models-in-llamacpp)):
`POST /v1/systemone` takes a `state` (text/JSON, or images for vision models)
and typed questions — `choice` (options → top option + probability each),
`score` (2–10 levels → expected level), `noul` (yes/no → P(yes)) — answered in
one forward pass. Decision models are ordinary GGUFs flagged with
`{arch}.decision.type` metadata, so the chat model cannot answer them; a
decision model has to be loaded.

`llama-cpp.service` runs llama.cpp's built-in **model router** for this: no
`--model` on the command line, instead `--models-dir` + `--models-preset`.
The router discovers one model per subdirectory of
`/opt/llama-cpp/models/served/` (the directory name is the served model id and
auto-wires `*mmproj*` / `mtp-*` sidecar files inside it), spawns one
`llama-server` child per model (re-executing its own `/app/llama-server`), and
proxies by the `"model"` request field. Both models load at startup
(`load-on-startup` in `presets.ini`); `--models-memory-margin` keeps 8 GiB of
GPU headroom and LRU-unloads idle models if a load does not fit.

Served on `:8000`:

| id | role | endpoints |
|---|---|---|
| `qwen3.8-27b` | chat (UD-Q8_K_XL + MTP draft + mmproj, as before) | `/v1/chat/completions`, `/v1/completions`, … |
| `kev-4b` | decision model (ggml-org/Kev-4B-GGUF, Q4_K_M, 3 GB, Apache-2.0) | `/v1/systemone` |

Existing clients are unchanged: they already send `model: "qwen3.8-27b"`, which
is the id the router uses. Decision requests add the same field at the level
of `state` — see `systemone-example.sh`. Other ggml decision models (Julia-1,
Laya, lev, OpenJev, Clef) drop in by changing `llama_cpp_decision_model_*` in
`group_vars/llama_cpp.yml` and re-running; `GET /v1/models` advertises
`output_modalities: ["decisions"]` for them, including while unloaded. The
router scan is confined to `models/served/`, so the retired flat quants and the
`thinkingcap/` subdirectory in `/opt/llama-cpp/models/` are not registered as
models. Roll back to the classic single-model unit any time with
`-e llama_cpp_router=false` (same weight layout).

`GET /v1/models` in router mode reports each model's `status` (`unloaded`,
`loading`, `loaded`), and `GET /models?reload=1` re-scans the directory after
adding a new subdirectory.

## Laya and laya.cpp

Laya is a typed-decision model/runtime, separate from the generative LLM API
served by llama.cpp. The `laya.cpp.yml` playbook provisions Vulkan build
dependencies, checks out laya.cpp, builds it, and installs a systemd service.
It has a separate inventory group and defaults to port 8001 to avoid the
llama.cpp service on port 8000.

**Superseded for new work:** llama.cpp's native `/v1/systemone` (above) speaks
the same System 1 schema and is already served by `llama-cpp.service`, so
laya-cpp and knowline no longer add capability the main service lacks. Both
are currently `inactive` on hal; retire them (and free the GPU memory and
build tree) when nothing still targets `:8001`/`:8002`.

`group_vars/laya_cpp.yml` was checked against upstream (lkarlslund/laya.cpp,
2026-09-26): the Vulkan build flags (`-DLAYA_CUDA=OFF -DLAYA_VULKAN=ON`,
CMake 3.24+, C++20, ICU, nlohmann-json, glslc/SPIR-V headers, ggml and
cpp-httplib submodules) produce `build-vulkan/bin/laya-cli`; the server is
`laya-cli --server --host ADDR --port PORT --model <store-root> --variant
typed-decisions --vulkan`; routes are `GET /health`, `GET /v1/models`,
`POST /v1/systemone` (JEV schema) and `POST /predict` (batched). The
typed-decisions checkpoint is the five files under the store root of
`convaiinnovations/laya-typed-decisions` (pinned revision
e`e929ae5...`, ~843 MB `model.safetensors`); English and multilingual are the
other variants. Retired 2026-11-04: the `english` checkpoint
(`convaiinnovations/laya` @ `55cf4c4...`) was replaced because on S1MB's own
`laya--typed-decisions-*` tasks it scores near floor (choice 0.020 /
noul 0.007 / score 0.004; Task Avg 13.4, rank 181/228), while
typed-decisions scores choice 0.287 / noul 0.444 / score 0.635 on the same
tasks. Same ModernBERT-large encoder, so only the checkpoint download and
`--variant` flag change.

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
ExecStart=/usr/bin/docker run --rm --name llama-cpp ... <image> \
    --models-dir /opt/llama-cpp/models/served --models-preset /opt/llama-cpp/presets.ini \
    --models-max 2 --models-memory-margin 8192 --host 0.0.0.0 --port 8080
ExecStop=/usr/bin/docker stop --time 30 llama-cpp
```

The router answers `/health` as soon as it is up; model instances load in the
background (`load-on-startup`), which is why the playbook's verify step polls
`/v1/models` until every served model reports `status: loaded` before probing
`/v1/systemone`.

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

# Typed decision (router mode: "model" picks the decision model)
curl http://10.1.1.105:8000/v1/systemone \
  -H 'Content-Type: application/json' \
  -d '{"model":"kev-4b","state":"Customer message: I was charged twice for my order.",
       "questions":{"route":{"type":"choice",
             "instructions":"Which team should handle this?",
             "criteria":{"billing":null,"shipping":null,"technical":null}}}}'
```

`/v1/systemone` against the chat model answers 501 `This model is not a
decision model` — expected; decision questions go to `kev-4b`.

## Things worth knowing (llama.cpp / current)

- The current deployment uses ROCm/HIP. Older performance notes below describe
  the prior Vulkan configuration and are historical, not current guidance.
- **ROCm/HIP device access.** The llama.cpp containers map `/dev/kfd` and
  `llama_cpp_render_node`, and pass numeric `render`/`video` group IDs. Host
  ROCm userspace is installed separately; the playbook checks the device nodes
  and asks the selected image to enumerate its HIP device.
- The previous Vulkan deployment used about 34 GiB with `--gpu-layers all`
  and `--ctx-size 262144`. ROCm-reported memory and available GTT can differ;
  check startup logs on hal before increasing context or concurrent slots.
- **The `--alias` flag sets the served model id.** Without it, the OpenAI
  `model` field is the literal in-container file path
  (e.g. `/models/Qwen3.8-27B-UD-Q3_K_XL.gguf`), which is what you'll see if you
  ever run the image manually without this flag.
- **Router mode: the served model id is the subdirectory name.** In router
  mode `--alias` does not apply (the router controls it); ids come from the
  directory names under `/opt/llama-cpp/models/served/`. That is why the chat
  model's directory is named exactly `qwen3.8-27b` — existing clients send that
  id and keep working. Per-model flags (`ctx-size`, `spec-type`,
  `reasoning-format`, …) live in `presets.ini`, not on the command line; the
  router strips its own reserved args (host, port, api-key, alias) and
  overlays its CLI args onto every instance.
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
  a ROCm/HIP-enabled llama.cpp image for its
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
