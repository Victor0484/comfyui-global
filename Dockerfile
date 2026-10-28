# Experimental PuLID image: keep the working :latest image unchanged.
FROM runpod/comfyui:cuda12.8

# InsightFace includes a native extension that may need to be compiled.
RUN apt-get update && apt-get install -y --no-install-recommends \
    git build-essential python3-dev && \
    rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 https://github.com/lldacing/ComfyUI_PuLID_Flux_ll.git \
    /opt/comfyui-baked/custom_nodes/ComfyUI_PuLID_Flux_ll && \
    python3.12 -m pip install --no-cache-dir Cython && \
    python3.12 -m pip install --no-cache-dir \
      -r /opt/comfyui-baked/custom_nodes/ComfyUI_PuLID_Flux_ll/requirements.txt && \
    python3.12 -m pip install --no-cache-dir --no-deps facenet-pytorch

# Compatibility adjustment documented for modern ComfyUI Flux forward hooks.
COPY patch-pulid.py /tmp/patch-pulid.py
RUN python3.12 /tmp/patch-pulid.py && rm /tmp/patch-pulid.py

# These three files already exist on the user's working main branch.
COPY --chmod=755 start-comfy.sh /usr/local/bin/start-comfy-global
COPY extra_model_paths.yaml /etc/comfyui/extra_model_paths.yaml
COPY --chmod=755 backup-comfy-data.sh /usr/local/bin/backup-comfy-data

WORKDIR /opt/comfyui-baked
EXPOSE 8188 8888
ENTRYPOINT ["/bin/bash", "/usr/local/bin/start-comfy-global"]
