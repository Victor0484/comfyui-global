# Experimental branch: preserve your working :pulid-test image.
FROM runpod/comfyui:cuda12.8

RUN apt-get update && apt-get install -y --no-install-recommends \
    git build-essential python3-dev libgl1 libglib2.0-0 unzip && \
    rm -rf /var/lib/apt/lists/*

# Existing working PuLID stack.
RUN git clone --depth 1 https://github.com/lldacing/ComfyUI_PuLID_Flux_ll.git \
    /opt/comfyui-baked/custom_nodes/ComfyUI_PuLID_Flux_ll && \
    python3.12 -m pip install --no-cache-dir Cython && \
    python3.12 -m pip install --no-cache-dir \
      -r /opt/comfyui-baked/custom_nodes/ComfyUI_PuLID_Flux_ll/requirements.txt && \
    python3.12 -m pip install --no-cache-dir --no-deps facenet-pytorch

COPY patch-pulid.py /tmp/patch-pulid.py
RUN python3.12 /tmp/patch-pulid.py && rm /tmp/patch-pulid.py

# ReActor 0.7+ bundles its own face analysis implementation; no separate
# insightface Python package is installed. ONNX GPU runtime is installed.
RUN git clone --depth 1 https://github.com/Gourieff/ComfyUI-ReActor.git \
    /opt/comfyui-baked/custom_nodes/ComfyUI-ReActor && \
    python3.12 -m pip install --no-cache-dir \
      -r /opt/comfyui-baked/custom_nodes/ComfyUI-ReActor/requirements.txt \
      'onnxruntime-gpu>=1.20.1' && \
    python3.12 -c 'import onnxruntime, cv2, torch; print("ReActor prerequisites:", onnxruntime.__version__, cv2.__version__, torch.__version__)'

# Disable ReActor's built-in NSFW classifier in this self-hosted test image.
# Fail the Docker build if upstream changed the detector API.
COPY patch-reactor-nsfw.py /tmp/patch-reactor-nsfw.py
RUN python3.12 /tmp/patch-reactor-nsfw.py && rm /tmp/patch-reactor-nsfw.py

COPY --chmod=755 start-comfy.sh /usr/local/bin/start-comfy-global
COPY --chmod=755 backup-comfy-data.sh /usr/local/bin/backup-comfy-data
COPY --chmod=755 cache-models.py /usr/local/bin/cache-models.py
COPY --chmod=755 auto-backup-comfy.py /usr/local/bin/auto-backup-comfy.py
COPY extra_model_paths.yaml /etc/comfyui/extra_model_paths.yaml

RUN sed -i 's/\r$//' /usr/local/bin/start-comfy-global && \
    /bin/bash -n /usr/local/bin/start-comfy-global && \
    python3.12 -m py_compile /usr/local/bin/cache-models.py /usr/local/bin/auto-backup-comfy.py

WORKDIR /opt/comfyui-baked
EXPOSE 8188 8888
ENTRYPOINT ["/bin/bash", "/usr/local/bin/start-comfy-global"]
