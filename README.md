# ComfyUI on Runpod: only Container Disk + Global Volume

This project changes the entrypoint of the official `runpod/comfyui:cuda12.8` image.
The official image contains ComfyUI in `/opt/comfyui-baked`. The usual
`/start.sh` tries to sync its application to `/workspace`, which fails with
`rsync mkstemp Operation not permitted` when Global Volume is mounted there.

This image launches ComfyUI directly from `/opt/comfyui-baked` and uses
`/workspace` only to READ model files from the existing Global Volume.
It supports the following model layouts:

- `/workspace/models/checkpoints`, `models/loras`, etc.
- `/workspace/runpod-slim/ComfyUI/models/checkpoints`, etc.

## Publish using GitHub Actions (no local Docker installation)

1. Create a public GitHub repo named `comfyui-global` (without README).
2. Upload all files, preserving `.github/workflows/publish.yml`.
3. Open Actions, enable workflows if asked, and run `Build and publish ComfyUI Docker image` manually if it did not start automatically.
4. After the build is green, open your GitHub profile's Packages section and find `comfyui-global`.
5. Open the package's settings and set Visibility to Public. (Public image means anybody can pull the software image; do NOT put models, images, access tokens or personal data in the repo.)
6. Your image address is `ghcr.io/YOUR_LOWERCASE_GITHUB_USERNAME/comfyui-global:latest`.

## Runpod template

- Image: `ghcr.io/YOUR_LOWERCASE_GITHUB_USERNAME/comfyui-global:latest`
- Container Disk: 150 GB (ephemeral, lost when Pod deleted)
- Network Volume: none
- Local Volume/Volume Disk: none
- Global Volume: attach the existing one at `/workspace`
- HTTP ports: `8188,8888` (if using Jupyter, otherwise only `8188`)
- Docker Start Command: empty (the image sets its own ENTRYPOINT)
- Environment variable: `JUPYTER_PASSWORD` set to a strong randomly-generated secret to enable JupyterLab on 8888.

ComfyUI: Connect to HTTP port 8188.
JupyterLab: Connect to HTTP port 8888 and supply the secret token.
Do not enable public tokenless Jupyter access.

## Keep output files after Pod deletion

Output and user files are intentionally stored locally at `/tmp/comfyui`:
ComfyUI and third-party nodes may rely on file operations Global Volume does
not support. Before terminating the Pod, open Jupyter Terminal and run:

    backup-comfy-data

The script copies input, output and user files to `/workspace/comfy-backup`.
Inspect the backup before deleting the Pod. **Nothing is automatically backed up.**
On the next Pod, the starter script restores `input` and `user` from this backup;
previous `output` files remain on Global Volume under `/workspace/comfy-backup/output`.

Runtime-installed custom nodes and packages are NOT persistent across Pod
deletions. Add them to this image and rebuild for long-term persistence.

This is a reference configuration verified against the public Dockerfile and
CLI arguments of Runpod/ComfyUI, but it has NOT been end-to-end deployed.
