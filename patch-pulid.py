"""Apply the tested 2026 PuLID/modern ComfyUI compatibility workaround.

Source: https://github.com/lldacing/ComfyUI_PuLID_Flux_ll/issues/94
Reported working on ComfyUI 0.36.0. Needs validation on this image's 0.30.0.
Fail the build if upstream code has changed rather than silently skipping patches.
"""
from pathlib import Path

root = Path('/opt/comfyui-baked/custom_nodes/ComfyUI_PuLID_Flux_ll')
hooks = root / 'PulidFluxHook.py'
body = hooks.read_text()
old = 'transformer_options = extra_options["transformer_options"]'
new = 'transformer_options = input_args.get("transformer_options") or extra_options.get("transformer_options", {})'
if body.count(old) != 3:
    raise RuntimeError(f'Unexpected PulidFluxHook.py: expected 3 old lookups, found {body.count(old)}')
hooks.write_text(body.replace(old, new))

pulid = root / 'pulidflux.py'
body = pulid.read_text()
old = 'wrappers_name, pulid_outer_sample_wrappers_with_override)'
new = 'wrappers_name, pulid_outer_sample_wrappers)'
if body.count(old) != 1:
    raise RuntimeError(f'Unexpected pulidflux.py: expected 1 override call, found {body.count(old)}')
pulid.write_text(body.replace(old, new))
print('PuLID Flux compatibility workaround applied.')
