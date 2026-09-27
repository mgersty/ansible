# Laya System 1 typed-decision server from laya.cpp.
#
# Runs on ANY CPU by default — no GPU, no drivers, no device passthrough.
# The image is compiled for the machine's own architecture (amd64 or arm64),
# so on Apple Silicon a plain `docker build` produces a native arm64 image.
#
#   docker build -t laya-cpp files/laya-cpp
#
# CPU (default):
#   docker run --rm -p 8001:8001 laya-cpp
#   curl http://localhost:8001/health
#
# AMD GPU hosts use Mesa RADV via /dev/dri:
#   docker run --rm -p 8001:8001 --device /dev/dri laya-cpp --amd-gpu
#   docker run --rm -p 8001:8001 --device /dev/dri -e LAYA_BACKEND=amd laya-cpp
# NVIDIA GPU hosts need NVIDIA Container Toolkit and host-driver injection:
#   docker run --rm -p 8001:8001 --device nvidia.com/gpu=all laya-cpp --nvidia-gpu
#   docker run --rm -p 8001:8001 --device nvidia.com/gpu=all -e LAYA_BACKEND=nvidia laya-cpp
# (On Docker <= 28, '--gpus all' works instead of the CDI device flag; on
# Docker 29+ it can fail with 'AMD CDI spec not found'.)
#
# Build a pure-CPU image (no Vulkan code, smaller) with:
#   docker build --build-arg LAYA_VULKAN=OFF -t laya-cpp files/laya-cpp

ARG BASE_IMAGE=ubuntu:26.04

# ---------------------------------------------------------------- build ----
FROM ${BASE_IMAGE} AS builder

# Source revision to build. Pin a commit or tag for reproducible images;
# group_vars/laya_cpp.yml currently tracks "main".
ARG LAYA_REF=main
# Vulkan is compiled in by default; CPU is the runtime default. Vulkan can
# use AMD via Mesa RADV or NVIDIA via the host's injected Vulkan ICD/driver.
# Set to OFF for a pure-CPU image, e.g. if ggml-vulkan does not build for
# your architecture.
ARG LAYA_VULKAN=ON

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        cmake \
        git \
        libicu-dev \
        ninja-build \
        nlohmann-json3-dev \
        pkg-config \
    && if [ "${LAYA_VULKAN}" = "ON" ]; then \
         apt-get install -y --no-install-recommends \
             glslc libvulkan-dev spirv-headers; \
       fi \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
# Full clone (no --depth): the CMake configure step patches the pinned ggml
# submodule in place, so the submodule's pinned commit must exist locally.
RUN git clone https://github.com/lkarlslund/laya.cpp.git repo \
    && cd repo \
    && git checkout "${LAYA_REF}" \
    && git submodule update --init --recursive \
    && cmake -S . -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DLAYA_CUDA=OFF \
        -DLAYA_VULKAN=${LAYA_VULKAN} \
    && cmake --build build --parallel "$(nproc)"

# --------------------------------------------------------------- runtime ----
FROM ${BASE_IMAGE}

ARG LAYA_VULKAN=ON

# libicu78 is the ICU runtime on ubuntu:26.04, libgomp1 is OpenMP for
# ggml-cpu. laya-cli is statically linked against the ggml/laya libraries,
# so no build-tree .so files are needed. Mesa RADV covers AMD/Intel GPUs;
# NVIDIA Container Toolkit can inject NVIDIA's host driver/ICD at runtime.
# Keep the Vulkan loader in the image, but don't bake NVIDIA driver libraries
# in: they must match the host kernel driver.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        libgomp1 \
        libicu78 \
    && if [ "${LAYA_VULKAN}" = "ON" ]; then \
         apt-get install -y --no-install-recommends \
             libvulkan1 mesa-vulkan-drivers libxext6 libglx0 libegl1; \
       fi \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/repo/build/bin/laya-cli /usr/local/bin/laya-cli
COPY entrypoint.sh /usr/local/bin/laya-entrypoint
RUN chmod 0755 /usr/local/bin/laya-entrypoint

# English checkpoint from convaiinnovations/laya, pinned to the same
# revision the ansible playbook downloads.
ARG LAYA_MODEL_REVISION=55cf4c4ebb4ebe31b2550e8bdf3bd21b99753851
ENV LAYA_MODEL_DIR=/models/laya

RUN mkdir -p "${LAYA_MODEL_DIR}/encoder" "${LAYA_MODEL_DIR}/tokenizer" \
    && cd "${LAYA_MODEL_DIR}" \
    && for f in \
           model.safetensors \
           rl_agent_config.json \
           encoder/config.json \
           tokenizer/tokenizer.json \
           tokenizer/tokenizer_config.json; do \
         curl --fail --location --retry 3 \
             -o "$f" \
             "https://huggingface.co/convaiinnovations/laya/resolve/${LAYA_MODEL_REVISION}/$f"; \
       done \
    && printf '%s\n' "${LAYA_MODEL_REVISION}" > "${LAYA_MODEL_DIR}/REVISION"

EXPOSE 8001

# Model load takes a while, so give the health check a long start period.
HEALTHCHECK --interval=30s --timeout=5s --start-period=180s \
    CMD curl --fail --silent http://127.0.0.1:8001/health || exit 1

# Defaults to CPU (laya-cli itself defaults to CUDA). The entrypoint preserves
# server/model options and appends docker run arguments, so `... laya-cpp
# --amd-gpu` / `--nvidia-gpu` (or LAYA_BACKEND=cpu|amd|nvidia) switches the
# backend without losing the server configuration.
ENTRYPOINT ["/usr/local/bin/laya-entrypoint"]
