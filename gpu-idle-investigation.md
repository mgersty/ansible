# Why the GPU shows 100% utilization and ~90% VRAM with no llama.cpp requests

**Date:** 2026-11-06
**Host:** Strix Halo APU (gfx1151, 40 CU, 64 GiB UMA), Ubuntu, kernel 7.0.0-42-generic
**Setup:** `llama-cpp` docker container (`ghcr.io/ggml-org/llama.cpp:server-rocm`) running the model manager with two models from `/opt/llama-cpp/presets.ini`:

- `kev-4b` — Kev-4B-Q4_K_M.gguf, ctx 8192, `n-gpu-layers all`, port 48137
- `qwen3.8-27b` — Qwen3.8-27B-UD-Q8_K_XL.gguf + mtp draft + mmproj F16, ctx 262144, `n-gpu-layers all`, port 55773
- Manager: `--models-max 2 --models-memory-margin 8192`, port 8000→8080, both presets `load-on-startup = true`
- A Prometheus textfile collector container reads `/sys/class/drm/card0/device/gpu_busy_percent` + `mem_info_vram_used` every 15 s and polls `/slots` on 8000.

## TL;DR

| Observation | Verdict |
|---|---|
| ~58.8 GiB / 64 GiB VRAM in use while idle | **Real, by design.** Both models are preloaded and kept resident (`load-on-startup = true`). Not a leak. |
| GPU utilization pinned at 100% while idle | **Fake reading.** `gpu_busy_percent` is a known-broken counter on AMD APUs. Proven on this machine: it reads 100 while idle *and* 100 under real load, while kernel traces show **zero GPU command submissions**. |

---

## 1. VRAM (~90% used) — real, and intentional

The server's own `/models` API accounts for the usage:

| Model | Weights | KV cache | Compute buffers | Notes |
|---|---|---|---|---|
| qwen3.8-27b | ~30.1 GiB | **~19.7 GiB** (ctx 262144!) | ~0.8 GiB | + mmproj-F16 (vision projector) |
| kev-4b | ~3.0 GiB | ~0.5 GiB (ctx 8192) | ~0.5 GiB | |
| **Total** | | | | **≈ 54.8 GiB + ROCm runtime overhead** |

`mem_info_vram_used` reported 58,804,846,592 bytes = **54.8 GiB of 64 GiB** — matches.

llama-server keeps models fully resident in VRAM between requests — that is the purpose of `load-on-startup` (instant first response, no reload penalty). Idle VRAM residency here is expected behavior, not a leak.

### Options if you want headroom

1. **Shrink qwen's context.** The single biggest chunk is the ~19.7 GiB KV cache for a 262k context. If 262k isn't needed, `ctx-size = 32768` drops it to ≈ 2.5 GiB (~17 GiB freed).
2. **Drop `load-on-startup = true`** from the preset(s) so models load on first request and can be unloaded by the manager.
3. Note the manager already keeps a `--models-memory-margin 8192` (8 GiB) reserve; actual free VRAM at idle is ~13 GiB.

---

## 2. GPU utilization = 100% — broken sysfs counter on APUs

### The counter

`/sys/class/drm/card0/device/gpu_busy_percent` is **known to be broken on AMD APUs** — it pins at 100 (or 0) regardless of actual load:

- freedesktop/drm/amd issue #1932 ("Some Raven/Picasso/Raven2 APU always report gpu_busy_percent as 100")
- btop issue #914 ("100% load AMD integrated GPU")
- MangoHud issue #923 ("GPU utilization always at 100% on Vega 3")

On this Strix Halo host it is pinned at exactly 100 at all times. **Both nvtop and the Prometheus textfile collector read this same file**, which is why everything downstream shows 100%.

### Proof the GPU is actually idle (gathered on this host)

1. **Kernel tracepoints — the decisive test.** Enabled `amdgpu:amdgpu_cs_ioctl`, `amdgpu:amdgpu_sched_run_job`, `amdgpu:amdgpu_bo_move` and sampled 20 s:
   **0 events.** No command submissions, no scheduler jobs, no buffer moves. Nothing is talking to the GPU.
   ```sh
   T=/sys/kernel/debug/tracing
   echo 1 | sudo tee $T/events/amdgpu/amdgpu_cs_ioctl/enable \
                   $T/events/amdgpu/amdgpu_sched_run_job/enable \
                   $T/events/amdgpu/amdgpu_bo_move/enable
   sudo sh -c 'echo 1 > '$T'/tracing_on; sleep 20; echo 0 > '$T'/tracing_on; cat '$T'/trace'
   ```
2. **No in-flight requests.** All slots `is_processing: false` on both models; `llamacpp:requests_processing 0`; no established TCP connections to ports 8000/48137/55773 (`ss -tnp`).
3. **Servers not spinning.** All 36 threads of the qwen server in state `S`; cumulative CPU jiffies static across samples; host load ~2.0, CPU ~99% idle.
4. **No other GPU clients.** Only the three llama-server processes (manager + 2 model servers) hold `/dev/kfd` + `/dev/dri/renderD128`. No displays connected (all DP/HDMI `status: disconnected`), no compositor/Xorg process.
5. **No GPU hangs or resets** in `dmesg`.
6. **Counter is dead even under load.** Ran a real completion on kev-4b while sampling: `gpu_busy_percent` read **100 during inference, identical to idle**. A counter that can't distinguish idle from load measures nothing.
7. **radeontop agrees it's unsupported.** Installed `radeontop` prints `Unknown Radeon card` for gfx1151; its fallback generic `gpu`/`cr` counters read 100% (reads of invalid addresses return all-1s) while every real pipeline — shader (`sx`, `sh`), texture (`ta`, `tc`), pixel (`pa`), depth/color (`db`, `cb`), vertex (`vgt`) — reads **0%**.

### The high GPU clock (red herring)

`pp_dpm_sclk` showed 600 MHz at one point and later pinned at 2.6–2.9 GHz. On Strix Halo the iGPU **cannot power down** (`dmesg: amdgpu: Runtime PM not available`) and holds high clocks while the llama servers keep a live GPU context with a ~55 GiB VM reservation. Clock state on this APU does not reflect utilization.

---

## 3. Recommendations

1. **Stop exposing `amdgpu_gpu_utilization`** in Grafana/dashboards — on this APU it is a constant 100 and will trigger false alerts.
   - In the metrics collector container (the `docker run` that writes `/textfile/gpu.prom`), drop the `amdgpu_gpu_utilization` gauge, or clearly mark it unreliable.
2. **Use a metric that means "the LLM is busy".** The servers already expose `--metrics`; the useful signals are:
   - `llamacpp:requests_processing` (gauge, in-flight requests)
   - `llamacpp:prompt_tokens_seconds` / `llamacpp:predicted_tokens_seconds` (throughput)
   - the slot context-usage gauge you already collect from `/slots`
3. **If you ever need true GPU utilization on gfx1151:** amdgpu PMU via `perf`, `rocprof`, or a newer radeontop build. For an LLM box the llama.cpp metrics are the better instrument anyway.
4. **Optional VRAM relief:** reduce qwen `ctx-size` (biggest win: ~17 GiB going 262k → 32k) and/or drop `load-on-startup`.

---

## Appendix: key commands used

```sh
# VRAM + fake utilization
cat /sys/class/drm/card0/device/gpu_busy_percent          # always 100 on this APU
cat /sys/class/drm/card0/device/mem_info_vram_used        # 58804846592 (~54.8 GiB)
cat /sys/class/drm/card0/device/pp_dpm_sclk               # DPM clock states (red herring)

# Who has the GPU open (run as root)
for p in /proc/[0-9]*; do ls -l $p/fd 2>/dev/null | grep -qE 'renderD128|/dev/kfd' && \
  echo "${p}: $(tr '\0' ' ' < $p/cmdline)"; done

# Are models actually serving?
curl -s http://127.0.0.1:8000/slots?model=qwen3.8-27b     # is_processing: false
curl -s http://127.0.0.1:8000/slots?model=kev-4b
curl -s "http://127.0.0.1:8000/metrics?model=qwen3.8-27b" | grep requests_processing

# Is anything submitting GPU work? (0 events = idle GPU)
T=/sys/kernel/debug/tracing
sudo sh -c "echo 1 > $T/events/amdgpu/amdgpu_cs_ioctl/enable;
            echo 1 > $T/events/amdgpu/amdgpu_sched_run_job/enable;
            echo > $T/trace; echo 1 > $T/tracing_on; sleep 20;
            echo 0 > $T/tracing_on; grep -c amdgpu $T/trace"
```
