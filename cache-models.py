#!/usr/bin/env python3.12
"""Copy selected persistent model weights to fast container-local storage.

No temporary files or renames are created on the Global Volume.
The FLUX/PuLID models are discovered via extra_model_paths.yaml;
ReActor reads directly from ComfyUI's own models directory.
"""
import hashlib
import os
from pathlib import Path
import shutil
import sys
import time

GLOBAL = Path(os.environ.get('COMFY_GLOBAL_MODELS', '/workspace/models'))
LOCAL = Path(os.environ.get('COMFY_CACHE_ROOT', '/tmp/comfy-model-cache'))
BAKED = Path('/opt/comfyui-baked/models')
MODE = os.environ.get('COMFY_CACHE_MODE', 'selected').lower()

CORE = [
    'diffusion_models/flux1-dev-fp8-e4m3fn.safetensors',
    'text_encoders/clip_l.safetensors',
    'text_encoders/t5xxl_fp8_e4m3fn.safetensors',
    'text_encoders/EVA02_CLIP_L_336_psz14_s6B.pt',
    'vae/ae.safetensors',
    'pulid/pulid_flux_v0.9.1.safetensors',
]
REACTOR_FILES = [
    'insightface/inswapper_128.onnx',
    'facerestore_models/GFPGANv1.4.pth',
]


def log(message):
    print(f'[model-cache] {message}', flush=True)


def copy_file(src: Path, dest: Path):
    if not src.is_file() or src.is_symlink() or src.stat().st_size == 0:
        return False
    dest.parent.mkdir(parents=True, exist_ok=True)
    size = src.stat().st_size
    if dest.is_file() and dest.stat().st_size == size:
        return True
    tmp = dest.with_name(dest.name + '.partial')
    try:
        started = time.monotonic()
        with src.open('rb') as reader, tmp.open('wb') as writer:
            shutil.copyfileobj(reader, writer, length=8 * 1024 * 1024)
        if tmp.stat().st_size != size:
            raise IOError(f'incomplete copy {src.name}')
        # Atomic rename only on the local POSIX disk; never on the Global Volume.
        os.replace(tmp, dest)
        log(f'cached {src.relative_to(GLOBAL)} ({size / (1024**3):.2f} GiB, {time.monotonic()-started:.1f}s)')
        return True
    except (OSError, IOError) as exc:
        log(f'WARNING: failed to cache {src}: {exc}; global original remains unchanged')
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass
        return False


def main():
    if MODE not in {'selected', 'off'}:
        log(f'unknown COMFY_CACHE_MODE={MODE}; use selected or off')
        return 1
    if MODE == 'off':
        log('disabled (ReActor models will also be unavailable unless manually copied)')
        return 0
    if not GLOBAL.is_dir():
        log(f'WARNING: {GLOBAL} not found; using any models bundled in the image')
        return 0

    cached = 0
    for rel in CORE:
        cached += copy_file(GLOBAL / rel, LOCAL / rel)

    # ReActor reads folder_paths.models_dir directly, not only extra-model YAML.
    for rel in REACTOR_FILES:
        cached += copy_file(GLOBAL / rel, BAKED / rel)
    buffalo = GLOBAL / 'insightface/models/buffalo_l'
    if buffalo.is_dir():
        for src in sorted(buffalo.glob('*.onnx')):
            cached += copy_file(src, BAKED / 'insightface/models/buffalo_l' / src.name)

    log(f'finished: {cached} model file(s) available locally')
    return 0


if __name__ == '__main__':
    sys.exit(main())
