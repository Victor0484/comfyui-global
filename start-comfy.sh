
#!/usr/bin/env bash
set -euo pipefail

COMFY_ROOT=/opt/comfyui-baked
DATA_ROOT=/tmp/comfyui

# Check ComfyUI installation
if [[ ! -f "${COMFY_ROOT}/main.py" ]]; then
  echo "ERROR: ComfyUI not found at ${COMFY_ROOT}/main.py" >&2
  exit 1
fi

# Keep runtime files on the container disk,
# never on the Global Volume.
mkdir -p \
  "${DATA_ROOT}/input" \
  "${DATA_ROOT}/output" \
  "${DATA_ROOT}/temp" \
  "${DATA_ROOT}/user"

# Restore previous inputs and user settings
# from the Global Volume.
for section in input user; do
  if [[ -d "/workspace/comfy-backup/${section}" ]]; then
    cp -r \
      "/workspace/comfy-backup/${section}/." \
      "${DATA_ROOT}/${section}/"
    echo "Restored ${section} from Global Volume."
  fi
done

# Check model directories
if [[ ! -d /workspace/models && \
      ! -d /workspace/runpod-slim/ComfyUI/models ]]; then
  echo "WARNING: No model directory found."
  echo "Attach your Global Volume at /workspace."
fi

# Start JupyterLab when a token is configured.
if [[ -n "${JUPYTER_PASSWORD:-}" ]]; then

  echo "Starting JupyterLab on port 8888."

  JUPYTER_ARGS=(
    --allow-root
    --no-browser
    --ip=0.0.0.0
    --port=8888
    --ServerApp.root_dir=/
    "--IdentityProvider.token=${JUPYTER_PASSWORD}"
  )

  # Fix Runpod reverse proxy origin validation.
  # Restrict the allowed origin to this Pod.
  if [[ -n "${RUNPOD_POD_ID:-}" ]]; then
    JUPYTER_ORIGIN="https://${RUNPOD_POD_ID}-8888.proxy.runpod.net"

    JUPYTER_ARGS+=(
      "--ServerApp.allow_origin=${JUPYTER_ORIGIN}"
    )

    echo "Jupyter allowed origin: ${JUPYTER_ORIGIN}"
  else
    echo "WARNING: RUNPOD_POD_ID is not set."
    echo "Jupyter proxy login may not work."
  fi

  jupyter lab "${JUPYTER_ARGS[@]}" \
    > /tmp/comfy-jupyter.log 2>&1 &

else
  echo "JupyterLab disabled."
  echo "Set JUPYTER_PASSWORD to enable it."
fi

# Start ComfyUI from the Docker image.
# Model files are loaded from the Global Volume.
cd "${COMFY_ROOT}"

echo "Starting ComfyUI from ${COMFY_ROOT}"
echo "Model storage: /workspace"

exec python3.12 main.py \
  --listen 0.0.0.0 \
  --port 8188 \
  --extra-model-paths-config /etc/comfyui/extra_model_paths.yaml \
  --input-directory "${DATA_ROOT}/input" \
  --output-directory "${DATA_ROOT}/output" \
  --temp-directory "${DATA_ROOT}/temp" \
  --user-directory "${DATA_ROOT}/user"
