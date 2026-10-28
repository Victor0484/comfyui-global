PuLID experimental build for your existing comfyui-global GitHub repository.
DO NOT upload to main: create branch `pulid-test` from main.
Upload/replace the files here to that branch, preserving your existing
start-comfy.sh and backup-comfy-data.sh on the branch. Then the push triggers
GitHub Actions and publishes ghcr.io/victor0484/comfyui-global:pulid-test.
Your working :latest remains unchanged.

1. In your existing GitHub repo, create a branch named pulid-test from main.
2. Upload Dockerfile, extra_model_paths.yaml, patch-pulid.py and
   .github/workflows/publish.yml to this branch.
3. Check Actions: Build and publish ComfyUI Docker image.
4. Only after success, deploy a temporary test Pod with image tag :pulid-test
   and the same Global Volume at /workspace (no Local or Network Volume).
5. PuLID requirements and the modern ComfyUI patch are experimental;
   not verified to build or execute on the Runpod CUDA 12.8 image.

Models: PuLID model under /workspace/models/pulid; EVA02 file under
/workspace/models/text_encoders. Download EVA to local /tmp first, verify SHA256,
then copy to Global Volume.

SHA256 EVA02_CLIP_L_336_psz14_s6B.pt:
84c3a17a228c567a155259b2245b0b59072bf7da510260a0a02ec54de6d50b05
