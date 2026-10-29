#!/usr/bin/env python3.12
"""Incremental ComfyUI backup + safe delete mirroring to Runpod Global Volume.

Live ComfyUI data remains on the local container filesystem. This daemon
copies new/changed files to an object-storage-mounted Global Volume, and
moves deleted files into a 30-day trash before removing the active copy.

Deletion is deliberately conservative: only paths seen locally during THIS
running daemon's lifetime may be deleted from the active backup. This is
crucial because local ComfyUI directories may start empty during Pod changes.
"""

import hashlib
import json
import os
from datetime import datetime, timezone
from pathlib import Path
import re
import shutil
import signal
import time
import uuid

SOURCE = Path(os.environ.get("COMFY_AUTOBACKUP_SOURCE", "/tmp/comfyui"))
TARGET = Path(os.environ.get("COMFY_AUTOBACKUP_TARGET", "/workspace/comfy-backup"))
INTERVAL = int(os.environ.get("COMFY_AUTOBACKUP_INTERVAL", "30"))
QUIET_SECONDS = int(os.environ.get("COMFY_AUTOBACKUP_QUIET", "8"))
DELETE_GRACE_SECONDS = int(os.environ.get("COMFY_AUTOBACKUP_DELETE_GRACE", "120"))
TRASH_DAYS = int(os.environ.get("COMFY_AUTOBACKUP_TRASH_DAYS", "30"))

# Do not mirror SQLite DBs, ComfyUI Manager caches, custom_nodes or models.
FOLDERS = ("input", "output", "user/default/workflows")
USER_FILES = (
    "user/default/comfy.settings.json",
    "user/default/settings.json",
    "user/__manager/config.ini",
)

SEEN = {}  # path -> (size, mtime_ns) of successfully checked local file
TRACKED = set()  # paths actually observed locally during this process
PENDING_DELETES = {}  # missing path -> first time observed missing
RUNNING = True
LAST_TRASH_PURGE = 0.0
TRASH_PATTERN = re.compile(r"^(\d{8}T\d{6}Z)_[0-9a-f]{12}$")


def log(msg):
    print(f"[autobackup {time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}", flush=True)


def stop(_signum, _frame):
    global RUNNING
    RUNNING = False


def mounted_ok():
    # A Global Volume backed by geesefs must be mounted at /workspace.
    # Never silently write to the ephemeral container filesystem instead.
    if str(TARGET).startswith("/workspace/"):
        return Path("/workspace").is_mount()
    return True  # Facilitates testing with an explicit different target.


def scan():
    """Return stable absolute paths and watched roots. Raise on walk errors."""
    present = {}
    active_roots = set()

    def walk_error(exc):
        raise exc

    for folder in FOLDERS:
        root = SOURCE / folder
        if not root.is_dir() or root.is_symlink():
            continue
        active_roots.add(folder)
        for parent, dirs, names in os.walk(root, followlinks=False, onerror=walk_error):
            # Do not follow links outside the ComfyUI runtime.
            dirs[:] = [d for d in dirs if not (Path(parent) / d).is_symlink()]
            for name in names:
                path = Path(parent) / name
                if not path.is_symlink() and path.is_file():
                    present[path.relative_to(SOURCE).as_posix()] = path

    for name in USER_FILES:
        path = SOURCE / name
        parent = path.parent
        if parent.is_dir() and not parent.is_symlink():
            active_roots.add(name)
            if path.is_file() and not path.is_symlink():
                present[name] = path
    return present, active_roots


def watched_root_is_available(key, active_roots):
    return any(key.startswith(folder + "/") for folder in FOLDERS if folder in active_roots) or key in active_roots


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for data in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(data)
    return digest.hexdigest()


def same_destination(path, size, content_hash=None):
    try:
        if not path.is_file() or path.is_symlink() or path.stat().st_size != size:
            return False
        return content_hash is None or sha256_file(path) == content_hash
    except OSError:
        return False


def copy_and_verify(source, target, expected_size, expected_hash=None):
    target.parent.mkdir(parents=True, exist_ok=True)
    # No temporary POSIX rename: Runpod geesefs rejects some such operations.
    # Never use this helper on live ComfyUI SQLite files.
    with source.open("rb") as inp, target.open("wb") as out:
        shutil.copyfileobj(inp, out, length=4 * 1024 * 1024)
    if target.stat().st_size != expected_size:
        raise OSError(f"size mismatch while copying to {target}")
    if expected_hash is not None and sha256_file(target) != expected_hash:
        raise OSError(f"checksum mismatch while copying to {target}")


def snapshot_updates(present, now):
    count = 0
    for key, source in present.items():
        try:
            st = source.stat()
            if now - st.st_mtime < QUIET_SECONDS:
                continue
            signature = (st.st_size, st.st_mtime_ns)
            dest = TARGET / key
            if SEEN.get(key) == signature and dest.is_file():
                continue

            validate_workflow = key.startswith("user/default/workflows/") and source.suffix.lower() == ".json"
            validate_setting = key in USER_FILES and source.suffix.lower() == ".json"
            digest = None
            if validate_workflow or validate_setting:
                payload = source.read_bytes()
                json.loads(payload)
                digest = hashlib.sha256(payload).hexdigest()

            # A media file may be overwritten without changing its byte count.
            # Hash it if we have already observed an older local version.
            if digest is None and key in SEEN and dest.is_file() and dest.stat().st_size == st.st_size:
                digest = sha256_file(source)

            if not same_destination(dest, st.st_size, digest):
                if validate_workflow:
                    history = (TARGET / "workflow-history" / key).with_name(
                        f"{source.stem}.{digest[:16]}.json"
                    )
                    if not same_destination(history, st.st_size, digest):
                        copy_and_verify(source, history, st.st_size, digest)
                copy_and_verify(source, dest, st.st_size, digest)
                count += 1
                log(f"saved {key}")

            after = source.stat()
            if (after.st_size, after.st_mtime_ns) == signature:
                SEEN[key] = signature
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            log(f"could not back up {key}: {exc}")
    if count:
        log(f"saved {count} file(s) to {TARGET}")


def history_for_workflow(key):
    """Find stored versions of this exact workflow, excluding other workflows."""
    if not (key.startswith("user/default/workflows/") and key.endswith(".json")):
        return []
    workflow = Path(key)
    history_dir = TARGET / "workflow-history" / workflow.parent
    if not history_dir.is_dir():
        return []
    pattern = re.compile(r"^" + re.escape(workflow.stem) + r"\.[a-f0-9]{16}\.json$")
    return [p for p in history_dir.iterdir() if p.is_file() and not p.is_symlink() and pattern.fullmatch(p.name)]


def move_to_trash(key, source_path):
    """Copy & checksum-verify backups into a uniquely named trash entry, then unlink.

    The trash entry is written first. If a copy fails, the active backup stays.
    Workflows also have their version history moved to the same trash entry.
    """
    active = TARGET / key
    items = []
    if active.is_file() and not active.is_symlink():
        items.append((active, Path("active") / key))
    for history in history_for_workflow(key):
        items.append((history, Path("history") / history.relative_to(TARGET / "workflow-history")))
    if not items:
        return  # No object in the active backup to delete.

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    entry = TARGET / "trash" / (timestamp + "_" + uuid.uuid4().hex[:12])

    for original, relative in items:
        size = original.stat().st_size
        digest = sha256_file(original)
        copy_and_verify(original, entry / relative, size, digest)

    metadata = {
        "deleted_at_utc": datetime.now(timezone.utc).isoformat(),
        "original_path": key,
        "retention_days": TRASH_DAYS,
        "files": [path.as_posix() for _, path in items],
    }
    meta_bytes = json.dumps(metadata, indent=2, ensure_ascii=False).encode("utf-8")
    meta_path = entry / "deleted.json"
    with meta_path.open("wb") as handle:
        handle.write(meta_bytes)
    if sha256_file(meta_path) != hashlib.sha256(meta_bytes).hexdigest():
        raise OSError(f"failed to verify trash manifest: {meta_path}")

    # If ComfyUI has recreated this file meanwhile, leave the backup alone.
    if source_path.exists():
        log(f"file reappeared during deletion: {key}; kept active backup")
        return

    for original, _ in items:
        original.unlink()
    log(f"moved deleted {key} to trash ({entry.name})")


def mirror_deletes(present, roots, now):
    # Only delete files that this daemon has actually seen in a running Pod.
    # A new Pod that starts with an empty /tmp/comfyui must never clear backups.
    for key in TRACKED - present.keys():
        if not watched_root_is_available(key, roots):
            PENDING_DELETES.pop(key, None)
            continue  # Whole directory missing: safety stop.
        first_missing = PENDING_DELETES.setdefault(key, now)
        if now - first_missing < DELETE_GRACE_SECONDS:
            continue
        source_path = SOURCE / key
        if source_path.exists():
            PENDING_DELETES.pop(key, None)
            continue
        try:
            move_to_trash(key, source_path)
            TRACKED.discard(key)
            PENDING_DELETES.pop(key, None)
            SEEN.pop(key, None)
        except OSError as exc:
            log(f"could not move deleted {key} into trash: {exc}")

    for key in present:
        PENDING_DELETES.pop(key, None)


def purge_old_trash(now):
    global LAST_TRASH_PURGE
    if now - LAST_TRASH_PURGE < 24 * 60 * 60:
        return
    LAST_TRASH_PURGE = now
    trash = TARGET / "trash"
    if not trash.is_dir() or trash.is_symlink():
        return
    for folder in trash.iterdir():
        if not folder.is_dir() or folder.is_symlink():
            continue
        match = TRASH_PATTERN.fullmatch(folder.name)
        if not match:
            continue  # Never delete unrecognized / manually created folders.
        try:
            stamped = datetime.strptime(match.group(1), "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
            if now - stamped.timestamp() >= TRASH_DAYS * 86400:
                shutil.rmtree(folder)
                log(f"permanently removed expired trash {folder.name}")
        except (OSError, ValueError) as exc:
            log(f"could not purge {folder}: {exc}")


def run_once():
    if not mounted_ok():
        log("Global Volume is not mounted at /workspace; skipping backup and deletion")
        return
    try:
        present, roots = scan()
    except OSError as exc:
        log(f"source scan failed: {exc}; no deletions will be performed")
        return

    now = time.time()
    snapshot_updates(present, now)
    mirror_deletes(present, roots, now)
    TRACKED.update(present.keys())
    purge_old_trash(now)


def main():
    if INTERVAL < 10 or DELETE_GRACE_SECONDS < INTERVAL or TRASH_DAYS < 1:
        raise ValueError("interval must be >=10s, deletion grace >= interval, trash days >=1")
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    log(f"watching {SOURCE} -> {TARGET} every {INTERVAL}s; "
        f"delete grace {DELETE_GRACE_SECONDS}s; trash retention {TRASH_DAYS} days")
    while RUNNING:
        try:
            run_once()
        except Exception as exc:
            log(f"scan failed: {exc}; next cycle will retry")
        for _ in range(INTERVAL):
            if not RUNNING:
                break
            time.sleep(1)
    log("stopped")


if __name__ == "__main__":
    main()
