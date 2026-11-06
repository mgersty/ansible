# laya-cpp container

Builds laya.cpp and serves the pinned typed-decisions Laya checkpoint on port
**8001** (same port as the native `laya-cpp` systemd service in this repo,
so the two are drop-in alternatives — don't run both at once).

**Runs on any CPU by default** — no GPU, no drivers, no device passthrough.
Works on Linux, macOS (Docker Desktop), and Windows (WSL2). The model is
small (~843 MB), so a single question takes well under a second on a laptop
CPU.

## Build

```sh
docker build -t laya-cpp files/laya-cpp
```

The image is compiled for **the machine's own architecture**, so on Apple
Silicon a plain `docker build` produces a native arm64 image that runs
without emulation. The build compiles `laya-cli` from source and downloads
the typed-decisions checkpoint (~843 MB) from
`convaiinnovations/laya-typed-decisions` into the image, so `docker run`
needs no further setup.

Variants:

```sh
# Pin a specific source revision instead of "main":
docker build --build-arg LAYA_REF=<commit-or-branch> -t laya-cpp files/laya-cpp

# Pure-CPU image (no Vulkan code, ~90 MB smaller). Use this if the Vulkan
# build does not compile for your architecture:
docker build --build-arg LAYA_VULKAN=OFF -t laya-cpp files/laya-cpp
```

## Run

```sh
docker run --rm -p 8001:8001 laya-cpp
```

That is all a plain CPU machine needs. The server listens on port **8001**
inside the container; the `-p 8001:8001` flag publishes it to the host.
Optional environment:

- `OMP_NUM_THREADS=N` — cap the OpenMP thread count ggml-cpu uses
  (default: all cores).

### Choosing the backend: CPU, AMD GPU, or NVIDIA GPU

The image is built once and works with **three backends** — you select one at
`docker run` time, no separate images are needed:

| Backend | Select with (either form) | What the host needs | `docker run` flags |
|---|---|---|---|
| **CPU** (default) | `--cpu` or `-e LAYA_BACKEND=cpu` | Nothing — works everywhere | none |
| **AMD GPU** | `--amd-gpu` or `-e LAYA_BACKEND=amd` | AMD (or Mesa-supported Intel) GPU with Mesa RADV driver on Linux | `--device /dev/dri` |
| **NVIDIA GPU** | `--nvidia-gpu` or `-e LAYA_BACKEND=nvidia` | NVIDIA driver + NVIDIA Container Toolkit on Linux | `--device nvidia.com/gpu=all` (or `--gpus all` on Docker ≤ 28) |

How selection works:

- **Default is CPU.** With no flag and no `LAYA_BACKEND`, the server starts
  with `laya-cli --cpu`.
- **Flags and env var are equivalent.** `--amd-gpu` and
  `-e LAYA_BACKEND=amd` do the same thing; a flag on the command line is
  stripped and takes precedence over `LAYA_BACKEND`. The legacy flag
  `--vulkan` still works as an alias for `--amd-gpu`.
- **GPU backends both use Vulkan.** Under the hood the entrypoint passes
  `--vulkan` to `laya-cli` for either GPU; what differs is which driver
  provides the Vulkan device (Mesa RADV for AMD, NVIDIA's injected driver for
  NVIDIA). The image ships the Vulkan loader, Mesa's RADV ICD, and the X/GL libraries
  the NVIDIA ICD depends on (`libxext6`, `libglx0`, `libegl1`), but not the
  NVIDIA driver libraries themselves — those are injected from the host and
  must match the host kernel driver.
- **The entrypoint validates GPU choices.** If you pick `amd` but
  `/dev/dri/renderD128` is not visible in the container, it exits immediately
  with a message telling you to add `--device /dev/dri` instead of failing
  deep inside Vulkan initialization.
- **Any other options you pass after the image name are forwarded** to
  `laya-cli` unchanged, alongside the server/model defaults, so you can still
  override e.g. `--port` or `--variant`.

#### CPU (default)

```sh
docker run --rm -p 8001:8001 laya-cpp
```

#### AMD GPU on Linux (e.g. hal)

```sh
docker run --rm -p 8001:8001 --device /dev/dri laya-cpp --amd-gpu
# equivalent:
docker run --rm -p 8001:8001 --device /dev/dri -e LAYA_BACKEND=amd laya-cpp
```

For non-root containers, the user inside must be able to read
`/dev/dri/renderD128` (typically via the host's `render` group).

#### NVIDIA GPU on Linux

Install the NVIDIA driver and the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
on the host first, then:

```sh
docker run --rm -p 8001:8001 --device nvidia.com/gpu=all laya-cpp --nvidia-gpu
# equivalent:
docker run --rm -p 8001:8001 --device nvidia.com/gpu=all -e LAYA_BACKEND=nvidia laya-cpp
```

The Container Toolkit injects the host-matching NVIDIA driver libraries at
runtime; do not bake a fixed NVIDIA driver version into the image.

> **Note for Docker 29+ hosts:** `--gpus all` may fail with
> `docker: Error response from daemon: AMD CDI spec not found` even when the
> NVIDIA CDI spec is present (Docker 29 changed GPU handling to CDI).
> Use the explicit CDI form `--device nvidia.com/gpu=all` instead — it
> works on both old and new Docker versions.

If the container cannot enumerate a Vulkan device, check `docker logs` and
run `vulkaninfo` with the same GPU flags, or fall back to the CPU default.

## Verify

```sh
curl http://localhost:8001/health        # "backend" says "CPU" or "Vulkan0"
curl http://localhost:8001/v1/models
```

JEV-compatible evaluation endpoint:

```sh
curl -X POST http://localhost:8001/v1/systemone \
  -H 'Content-Type: application/json' \
  -d '{"state":"Please refund the duplicate charge.",
       "questions":{"refund":{"type":"noul",
         "instructions":"Does the customer ask for a refund?"}}}'
```

`POST /predict` accepts a JSON array of requests and is batched
automatically; see upstream `docs/http.md`.
