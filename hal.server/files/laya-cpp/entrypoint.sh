#!/bin/sh
set -eu

# Backend selection:
#   LAYA_BACKEND=cpu    (default) CPU only
#   LAYA_BACKEND=amd     AMD (or Mesa-supported Intel) GPU via Vulkan + /dev/dri
#   LAYA_BACKEND=nvidia  NVIDIA GPU via Vulkan + NVIDIA Container Toolkit
# Positional GPU flags also work: `docker run ... laya-cpp --amd-gpu` or
# `--nvidia-gpu` (legacy `--vulkan` selects AMD).
BACKEND="${LAYA_BACKEND:-cpu}"
if [ $# -gt 0 ]; then
    case "$1" in
        --cpu) BACKEND=cpu; shift ;;
        --amd-gpu|--amd) BACKEND=amd; shift ;;
        --nvidia-gpu|--nvidia) BACKEND=nvidia; shift ;;
        --vulkan) BACKEND=amd; shift ;;
    esac
fi

case "$BACKEND" in
    cpu)
        exec laya-cli \
            --server \
            --host "${LAYA_HOST:-0.0.0.0}" \
            --port "${LAYA_PORT:-8001}" \
            --model "${LAYA_MODEL_DIR:-/models/laya}" \
            --variant "${LAYA_VARIANT:-typed-decisions}" \
            --cpu \
            "$@"
        ;;
    amd)
        if [ ! -e /dev/dri/renderD128 ]; then
            echo "LAYA_BACKEND=amd but /dev/dri/renderD128 is missing; start the" >&2
            echo "container with '--device /dev/dri' (and an AMD/Mesa host driver)." >&2
            exit 1
        fi
        exec laya-cli \
            --server \
            --host "${LAYA_HOST:-0.0.0.0}" \
            --port "${LAYA_PORT:-8001}" \
            --model "${LAYA_MODEL_DIR:-/models/laya}" \
            --variant "${LAYA_VARIANT:-typed-decisions}" \
            --vulkan \
            "$@"
        ;;
    nvidia)
        exec laya-cli \
            --server \
            --host "${LAYA_HOST:-0.0.0.0}" \
            --port "${LAYA_PORT:-8001}" \
            --model "${LAYA_MODEL_DIR:-/models/laya}" \
            --variant "${LAYA_VARIANT:-typed-decisions}" \
            --vulkan \
            "$@"
        ;;
    *)
        echo "Unknown LAYA_BACKEND '$BACKEND' (expected cpu, amd, or nvidia)." >&2
        exit 1
        ;;
esac
