#!/usr/bin/env bash
set -euo pipefail

COMFY_ROOT=/opt/comfyui-baked
DATA_ROOT=/tmp/comfyui

if [[ ! -f "${COMFY_ROOT}/main.py" ]]; then
  echo "ERROR: ComfyUI not found at ${COMFY_ROOT}/main.py" >&2
  exit 1
fi

# Never write ComfyUI's runtime files to the object-storage mount.
mkdir -p "${DATA_ROOT}/input" "${DATA_ROOT}/output" \
         "${DATA_ROOT}/temp" "${DATA_ROOT}/user"

# Restore backed-up inputs and ComfyUI user settings from previous Pods.
# Models stay on Global Volume and are NOT copied to the container.
for section in input user; do
  if [[ -d "/workspace/comfy-backup/${section}" ]]; then
    cp -r "/workspace/comfy-backup/${section}/." "${DATA_ROOT}/${section}/"
    echo "Restored ${section} from Global Volume."
  fi
done

if [[ ! -d /workspace/models && ! -d /workspace/runpod-slim/ComfyUI/models ]]; then
  echo "WARNING: No model directory found at the expected Global Volume paths."
  echo "Attach your Global Volume at /workspace and add your model files."
fi

# Optional: a password-protected file manager and terminal through JupyterLab.
# Set JUPYTER_PASSWORD in the Runpod template and expose port 8888/http.
if [[ -n "${JUPYTER_PASSWORD:-}" ]]; then
  echo "Starting JupyterLab on port 8888 (token authentication enabled)."
  jupyter lab --allow-root --no-browser --ip=0.0.0.0 --port=8888 \
    --ServerApp.root_dir=/ \
    --IdentityProvider.token="${JUPYTER_PASSWORD}" \
    > /tmp/comfy-jupyter.log 2>&1 &
else
  echo "JupyterLab disabled. Set JUPYTER_PASSWORD to enable it."
fi

cd "${COMFY_ROOT}"
echo "Starting ComfyUI from ${COMFY_ROOT}, model storage: /workspace"
exec python3.12 main.py \
  --listen 0.0.0.0 --port 8188 \
  --extra-model-paths-config /etc/comfyui/extra_model_paths.yaml \
  --input-directory "${DATA_ROOT}/input" \
  --output-directory "${DATA_ROOT}/output" \
  --temp-directory "${DATA_ROOT}/temp" \
  --user-directory "${DATA_ROOT}/user"
