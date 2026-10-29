#!/usr/bin/env bash
set -euo pipefail

COMFY_ROOT=/opt/comfyui-baked
DATA_ROOT=/tmp/comfyui

if [[ ! -f "${COMFY_ROOT}/main.py" ]]; then
  echo "ERROR: ComfyUI missing at ${COMFY_ROOT}" >&2
  exit 1
fi
mkdir -p "${DATA_ROOT}/input" "${DATA_ROOT}/output" \
  "${DATA_ROOT}/temp" "${DATA_ROOT}/user"

# Restore workflows and input assets from previous Pods.
for section in input user; do
  if [[ -d "/workspace/comfy-backup/${section}" ]]; then
    cp -r "/workspace/comfy-backup/${section}/." "${DATA_ROOT}/${section}/"
    echo "Restored ${section} from Global Volume."
  fi
done

# Cache only your regularly used FLUX and PuLID weights, plus ReActor weights.
# Copying occurs on EVERY new container start. No downloads from HF are used.
echo "Caching popular models on local container disk..."
if ! python3.12 -u /usr/local/bin/cache-models.py \
    2>&1 | tee /tmp/comfy-model-cache.log; then
  echo "WARNING: local model cache did not complete; global files are untouched."
fi

# Keep the existing JupyterLab login and explicit Runpod proxy origin.
if [[ -n "${JUPYTER_PASSWORD:-}" ]]; then
  JUPYTER_ARGS=(
    --allow-root --no-browser --ip=0.0.0.0 --port=8888
    --ServerApp.root_dir=/
    "--IdentityProvider.token=${JUPYTER_PASSWORD}"
  )
  if [[ -n "${RUNPOD_POD_ID:-}" ]]; then
    JUPYTER_ARGS+=("--ServerApp.allow_origin=https://${RUNPOD_POD_ID}-8888.proxy.runpod.net")
  fi
  jupyter lab "${JUPYTER_ARGS[@]}" > /tmp/comfy-jupyter.log 2>&1 &
  echo "JupyterLab started on port 8888."
else
  echo "JupyterLab disabled (set JUPYTER_PASSWORD to enable)."
fi

# Incremental backup with 30-day trash retention.
python3.12 -u /usr/local/bin/auto-backup-comfy.py \
  >> /tmp/comfy-autobackup.log 2>&1 &
echo "Incremental backup started."

cd "${COMFY_ROOT}"
echo "Starting ComfyUI from ${COMFY_ROOT} on port 8188."
exec python3.12 main.py \
  --listen 0.0.0.0 --port 8188 \
  --extra-model-paths-config /etc/comfyui/extra_model_paths.yaml \
  --input-directory "${DATA_ROOT}/input" \
  --output-directory "${DATA_ROOT}/output" \
  --temp-directory "${DATA_ROOT}/temp" \
  --user-directory "${DATA_ROOT}/user"
