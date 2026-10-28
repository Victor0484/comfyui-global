#!/usr/bin/env bash
set -euo pipefail

SOURCE=/tmp/comfyui
TARGET=/workspace/comfy-backup
if [[ ! -d /workspace ]]; then
  echo "ERROR: /workspace missing. Attach Global Volume before backup." >&2
  exit 1
fi
for name in input output user; do
  mkdir -p "${TARGET}/${name}"
  # Avoid rsync's POSIX rename/temp-file behavior on object storage.
  cp -r "${SOURCE}/${name}/." "${TARGET}/${name}/"
done
echo "Backup copied to ${TARGET}. Verify it before deleting your Pod."
