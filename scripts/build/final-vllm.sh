#!/bin/sh
# Install the vLLM wheel and its three hand-written gfx803 kernels into the
# runtime venv, and prove the package imports.
set -eu

VENV="${VIRTUAL_ENV:?VIRTUAL_ENV is required}"

# --no-deps: vllm/requirements/rocm.txt pulls in AMD-specific extras
# (amd-quark, tilelang, runai-model-streamer and similar) that nobody has
# exercised on gfx803. requirements/common.txt below is the cross-platform
# core vLLM needs to import and run text generation, and is what this image
# actually installs.
"$VENV/bin/pip" install --no-cache-dir --no-deps /tmp/vllm/*.whl
"$VENV/bin/pip" install --no-cache-dir -r /tmp/vllm-requirements-common.txt
rm -rf /tmp/vllm /tmp/vllm-requirements-common.txt

# Each kernel's Python ctypes loader finds its .so next to itself, so the
# directory shape under /tmp/vllm-kernels (written by scripts/build/vllm.sh)
# mirrors site-packages/vllm exactly and is copied on as-is. scripts/build/vllm.sh
# only produces these .so files for a build that includes gfx803 (they are
# hand-written GCN3/wave64 kernels, unsafe to compile for any other arch), so a
# gfx1010-only (or other non-gfx803) build leaves these directories empty --
# `cp` with no matches is not an error here, only a glob that matched nothing.
site="$("$VENV/bin/python3" -c "import vllm, os; print(os.path.dirname(vllm.__file__))")"
for f in /tmp/vllm-kernels/model_executor/layers/*.so; do
    [ -e "$f" ] || continue
    cp "$f" "$site/model_executor/layers/"
done
for f in /tmp/vllm-kernels/v1/attention/ops/*.so; do
    [ -e "$f" ] || continue
    cp "$f" "$site/v1/attention/ops/"
done
rm -rf /tmp/vllm-kernels

"$VENV/bin/python3" -c "import vllm; print('vllm', vllm.__version__)"
