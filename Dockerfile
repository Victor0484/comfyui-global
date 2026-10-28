# ComfyUI is already installed in the official Runpod image.
# Only the entrypoint and external model path configuration are replaced.
FROM runpod/comfyui:cuda12.8

COPY --chmod=755 start-comfy.sh /usr/local/bin/start-comfy-global
COPY extra_model_paths.yaml /etc/comfyui/extra_model_paths.yaml
COPY --chmod=755 backup-comfy-data.sh /usr/local/bin/backup-comfy-data

WORKDIR /opt/comfyui-baked
EXPOSE 8188 8888
ENTRYPOINT ["/usr/local/bin/start-comfy-global"]
