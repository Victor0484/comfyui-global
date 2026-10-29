#!/usr/bin/env bash
set -euo pipefail

# Run ONCE in the SSH terminal of your CURRENT Pod before switching images.
# Downloads to local scratch first, verifies, then copies into the Global Volume.
if [[ "$(findmnt -n -o FSTYPE -T /workspace 2>/dev/null)" != "fuse.geesefs" ]]; then
  echo "ERROR: expected Runpod Global Volume (fuse.geesefs) at /workspace." >&2
  exit 1
fi

STAGE=$(mktemp -d /tmp/reactor-models.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
DEST=/workspace/models
mkdir -p "$DEST/insightface/models/buffalo_l" "$DEST/facerestore_models"

get_file() {
  local url="$1" file="$2"
  echo "Downloading $(basename "$file") to local scratch..."
  curl --fail --location --retry 4 --connect-timeout 30 \
    --output "$file" "$url"
  if [[ ! -s "$file" ]]; then
    echo "ERROR: zero-byte download: $file" >&2
    exit 1
  fi
}

copy_verified() {
  local source="$1" target="$2" expected="$3"
  local actual
  actual=$(sha256sum "$source" | cut -d' ' -f1)
  if [[ "$actual" != "$expected" ]]; then
    echo "ERROR: hash mismatch for $(basename "$source")" >&2
    exit 1
  fi
  if [[ -f "$target" ]]; then
    local existing
    existing=$(sha256sum "$target" | cut -d' ' -f1)
    if [[ "$existing" == "$expected" ]]; then
      echo "Already stored: $target"
      return
    fi
    echo "ERROR: $target exists but hash does not match; will not overwrite" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$target")"
  cp "$source" "$target"
  actual=$(sha256sum "$target" | cut -d' ' -f1)
  if [[ "$actual" != "$expected" ]]; then
    echo "ERROR: Global Volume copy verification failed: $target" >&2
    exit 1
  fi
  echo "Saved and verified: $target"
}

INSWAPPER_SHA=e4a3f08c753cb72d04e10aa0f7dbe3deebbf39567d4ead6dce08e98aa49e16af
if [[ ! -f "$DEST/insightface/inswapper_128.onnx" ]]; then
  get_file "https://huggingface.co/datasets/Gourieff/ReActor/resolve/main/models/inswapper_128.onnx" "$STAGE/inswapper_128.onnx"
  copy_verified "$STAGE/inswapper_128.onnx" "$DEST/insightface/inswapper_128.onnx" "$INSWAPPER_SHA"
else
  echo "Already present: inswapper_128.onnx (verify against README hash if previously downloaded)"
fi

# buffalo_l face analysis files; save them permanently so future Pods don't download again.
if [[ ! -s "$DEST/insightface/models/buffalo_l/det_10g.onnx" || \
      ! -s "$DEST/insightface/models/buffalo_l/w600k_r50.onnx" || \
      ! -s "$DEST/insightface/models/buffalo_l/genderage.onnx" ]]; then
  get_file "https://huggingface.co/datasets/Gourieff/ReActor/resolve/main/models/buffalo_l.zip" "$STAGE/buffalo_l.zip"
  python3.12 - "$STAGE/buffalo_l.zip" "$STAGE/buffalo" <<'PY'
import pathlib, shutil, sys, zipfile
zip_path, out_dir = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
out_dir.mkdir(parents=True, exist_ok=True)
wanted = {'det_10g.onnx', 'w600k_r50.onnx', 'genderage.onnx', '2d106det.onnx', '1k3d68.onnx'}
with zipfile.ZipFile(zip_path) as archive:
    for entry in archive.infolist():
        name = pathlib.PurePosixPath(entry.filename).name
        if name in wanted and not entry.is_dir():
            with archive.open(entry) as source, (out_dir / name).open('wb') as target:
                shutil.copyfileobj(source, target)
for name in ('det_10g.onnx', 'w600k_r50.onnx', 'genderage.onnx'):
    if not (out_dir / name).is_file():
        raise SystemExit(f'Missing required file in buffalo_l.zip: {name}')
PY
  for spec in \
    'det_10g.onnx:5838f7fe053675b1c7a08b633df49e7af5495cee0493c7dcf6697200b85b5b91' \
    'w600k_r50.onnx:4c06341c33c2ca1f86781dab0e829f88ad5b64be9fba56e56bc9ebdefc619e43' \
    'genderage.onnx:4fde69b1c810857b88c64a335084f1c3fe8f01246c9a191b48c7bb756d6652fb' \
    '2d106det.onnx:f001b856447c413801ef5c42091ed0cd516fcd21f2d6b79635b1e733a7109dbf' \
    '1k3d68.onnx:df5c06b8a0c12e422b2ed8947b8869faa4105387f199c477af038aa01f9a45cc'; do
    name=${spec%%:*}; sha=${spec#*:}
    if [[ -f "$STAGE/buffalo/$name" ]]; then
      copy_verified "$STAGE/buffalo/$name" "$DEST/insightface/models/buffalo_l/$name" "$sha"
    fi
  done
else
  echo "Already present: buffalo_l (existing required files)"
fi

# One restorer suffices to prevent ReActor's node list from auto-downloading four.
RESTORER="$DEST/facerestore_models/GFPGANv1.4.pth"
if [[ ! -s "$RESTORER" ]]; then
  get_file "https://huggingface.co/datasets/Gourieff/ReActor/resolve/main/models/facerestore_models/GFPGANv1.4.pth" "$STAGE/GFPGANv1.4.pth"
  if [[ $(stat -c %s "$STAGE/GFPGANv1.4.pth") -lt 10000000 ]]; then
    echo "ERROR: face restorer download unexpectedly small" >&2
    exit 1
  fi
  cp "$STAGE/GFPGANv1.4.pth" "$RESTORER"
  cmp "$STAGE/GFPGANv1.4.pth" "$RESTORER"
  echo "Saved and verified: $RESTORER"
fi

echo "ReActor model setup complete. Global Volume contents:"
find "$DEST/insightface" "$DEST/facerestore_models" -type f -printf '%p (%s bytes)\n'
