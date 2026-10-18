"""Lay out, download, repair and verify the mlx-Yue converted model (desktop setup).

mlx-Yue's verify_conversion accepts a model folder that holds exactly the files listed in its
conversion.json, conversion.json itself and optionally README.md. The VAE lives in its own folder.
So the layout under ROOT (the app's model folder for this format) is:

    ROOT/<model-name>/   exactly the conversion.json file set (both AR precisions it lists)
    ROOT/vae/            the repo's vae/ subtree
    ROOT/.staging/       partial downloads while setup runs, removed at the end
    ROOT/.verified.json  written after verify_conversion passed

0.4.4 downloaded the whole repo straight into ROOT with huggingface_hub (vae/ inside, a
.cache/huggingface tree, only one AR precision). That layout is repaired in place: files move into
ROOT/<model-name>/, vae/ stays beside it, .cache goes, and only the missing files are fetched.

usage: python -m studio_engine.mlx_setup --repo R --revision SHA --root DIR [--model-name N]
       python -m studio_engine.mlx_setup --verify-only --model-dir M --vae-dir V

Progress goes to stdout as plain lines, plus `@progress {json}` and a final `@result {json}`.
Runs inside the mlx-Yue venv (huggingface_hub and lyra importable). STUDIO_SETUP_SOURCE=<dir>
replaces the network fetch with an APFS clone from a local copy of the repo (tests only).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

MIN_FREE = 2 * 1024 ** 3
CHUNK = 4 * 1024 * 1024
OPTIONAL = {"README.md"}


def say(line):
    print(line, flush=True)


def emit(kind, data):
    print(f"@{kind} {json.dumps(data)}", flush=True)


class SetupError(Exception):
    pass


# --------------------------------------------------------------------------- metadata

class RemoteFile:
    def __init__(self, name, size, sha256=None, git_sha1=None):
        self.name, self.size, self.sha256, self.git_sha1 = name, size, sha256, git_sha1


def repo_files(repo, revision):
    """{path: RemoteFile} from the Hub: LFS files carry sha256, small files their git blob sha1."""
    from huggingface_hub import HfApi

    info = HfApi().model_info(repo, revision=revision, files_metadata=True)
    out = {}
    for s in info.siblings:
        lfs = getattr(s, "lfs", None)
        sha = (lfs.sha256 if not isinstance(lfs, dict) else lfs.get("sha256")) if lfs else None
        out[s.rfilename] = RemoteFile(s.rfilename, s.size, sha, getattr(s, "blob_id", None))
    return out


def git_blob_sha1(path):
    h = hashlib.sha1()
    h.update(b"blob %d\0" % path.stat().st_size)
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(CHUNK), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_file(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(CHUNK), b""):
            h.update(chunk)
    return h.hexdigest()


def file_ok(path, remote, expected_sha256=None):
    if not path.is_file() or path.stat().st_size != remote.size:
        return False
    sha = expected_sha256 or remote.sha256
    if sha:
        return sha256_file(path) == sha
    if remote.git_sha1:
        return git_blob_sha1(path) == remote.git_sha1
    return True


# --------------------------------------------------------------------------- layout repair

def _move_into(src, dst):
    """Move src to dst. When dst exists, merge directories and drop duplicate files from src."""
    if not dst.exists():
        dst.parent.mkdir(parents=True, exist_ok=True)
        os.replace(src, dst)
        return
    if src.is_dir() and dst.is_dir():
        for child in list(src.iterdir()):
            _move_into(child, dst / child.name)
        shutil.rmtree(src, ignore_errors=True)
    else:
        if src.is_dir():
            shutil.rmtree(src)
        else:
            src.unlink()


def repair_layout(root, model_name):
    """Fix the 0.4.4 layout in place without re-downloading. Returns a list of what changed."""
    model, vae = root / model_name, root / "vae"
    done = []
    keep = {model_name, "vae", ".staging", ".verified.json", ".cache"}
    if (root / "conversion.json").is_file():
        moved = 0
        for entry in list(root.iterdir()):
            if entry.name in keep:
                continue
            _move_into(entry, model / entry.name)
            moved += 1
        done.append(f"moved {moved} entries into {model_name}/")
    if (model / "vae").exists():
        _move_into(model / "vae", vae)
        done.append(f"moved {model_name}/vae out to vae/")
    for d in (root, model, vae):
        cache = d / ".cache"
        if cache.exists():
            shutil.rmtree(cache)
            done.append(f"removed {cache.relative_to(root)}")
    return done


def prune(directory, allowed_files):
    """Delete files and empty folders in directory that are not in allowed_files (relative paths)."""
    removed = []
    if not directory.is_dir():
        return removed
    for path in sorted(directory.rglob("*"), key=lambda x: len(x.parts), reverse=True):
        rel = path.relative_to(directory).as_posix()
        if path.is_symlink() or path.is_file():
            if rel not in allowed_files:
                path.unlink()
                removed.append(rel)
        elif path.is_dir() and not any(path.iterdir()):
            if not any(a.startswith(rel + "/") for a in allowed_files):
                path.rmdir()
    return removed


# --------------------------------------------------------------------------- download

def _url(repo, revision, name):
    return f"https://huggingface.co/{repo}/resolve/{revision}/{urllib.request.quote(name)}"


def fetch(repo, revision, remote, dest, staging, label):
    """Resumable download into staging, sha-checked, then moved to dest."""
    part = staging / (remote.name.replace("/", "__") + ".part")
    part.parent.mkdir(parents=True, exist_ok=True)
    source = os.environ.get("STUDIO_SETUP_SOURCE")
    if source:
        src = Path(source) / remote.name
        if part.exists():
            part.unlink()
        subprocess.run(["cp", "-c", str(src), str(part)], check=True)
        emit("progress", {"file": label, "done": remote.size, "total": remote.size})
    else:
        _http_fetch(_url(repo, revision, remote.name), part, remote.size, label)
    if part.stat().st_size != remote.size:
        raise SetupError(f"{label}: size {part.stat().st_size}, expected {remote.size}")
    say(f"Verifying {label}")
    ok = (sha256_file(part) == remote.sha256) if remote.sha256 else (
        git_blob_sha1(part) == remote.git_sha1 if remote.git_sha1 else True)
    if not ok:
        part.unlink()
        raise SetupError(f"{label}: checksum mismatch; the partial file was deleted. Try again.")
    dest.parent.mkdir(parents=True, exist_ok=True)
    os.replace(part, dest)
    say(f"{label}: OK")


def _http_fetch(url, part, total, label, attempts=5):
    headers = {"User-Agent": "localhost-recording-studio"}
    token = os.environ.get("HF_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    for attempt in range(1, attempts + 1):
        have = part.stat().st_size if part.exists() else 0
        if have >= total:
            return
        req = urllib.request.Request(url, headers={**headers, **({"Range": f"bytes={have}-"} if have else {})})
        try:
            with urllib.request.urlopen(req, timeout=60) as res:
                if res.status == 200 and have:
                    have = 0  # server ignored the range: start over
                elif res.status == 206:
                    say(f"{label}: resuming at {have / 1e6:.1f} MB")
                elif res.status not in (200, 206):
                    raise SetupError(f"{label}: HTTP {res.status}")
                last = 0.0
                with part.open("ab" if have else "wb") as out:
                    while True:
                        chunk = res.read(CHUNK)
                        if not chunk:
                            break
                        out.write(chunk)
                        have += len(chunk)
                        now = time.monotonic()
                        if now - last > 0.5:
                            last = now
                            emit("progress", {"file": label, "done": have, "total": total})
            emit("progress", {"file": label, "done": have, "total": total})
            if have >= total:
                return
        except (urllib.error.URLError, OSError, TimeoutError) as error:
            if attempt == attempts:
                raise SetupError(f"{label}: {error}. Run setup again to resume.") from error
            say(f"{label}: {error}; retrying ({attempt}/{attempts - 1})")
            time.sleep(min(30, 2 ** attempt))


# --------------------------------------------------------------------------- verify

def verify(model_dir, vae_dir):
    """mlx-Yue's own checks: the converted folder (with hashes) and the pinned VAE identity."""
    from lyra.conversion import _VAE_SOURCE_FILES, verify_conversion

    say("Checking the model folder with mlx-Yue (hashes every file, takes a minute)")
    manifest = verify_conversion(model_dir)
    weight = vae_dir / "model.safetensors"
    pinned = _VAE_SOURCE_FILES["model.safetensors"]
    if not weight.is_file() or weight.stat().st_size != pinned["bytes"] or sha256_file(weight) != pinned["sha256"]:
        raise SetupError(f"VAE weights in {vae_dir} do not match the pinned YuE2-Vae")
    config = vae_dir / "config.json"
    if not config.is_file() or sha256_file(config) != _VAE_SOURCE_FILES["config.json"]["sha256"]:
        raise SetupError(f"VAE config in {vae_dir} does not match the pinned YuE2-Vae")
    return manifest


# --------------------------------------------------------------------------- main flow

def setup(repo, revision, root, model_name):
    root.mkdir(parents=True, exist_ok=True)
    model, vae, staging = root / model_name, root / "vae", root / ".staging"
    marker = root / ".verified.json"
    for line in repair_layout(root, model_name):
        say(f"Repair: {line}")

    try:
        remote = repo_files(repo, revision)
    except Exception as error:  # offline: fine if everything is already here
        say(f"Could not list {repo} on Hugging Face ({type(error).__name__}: {error})")
        remote = None

    conv_path = model / "conversion.json"
    if remote is not None and not file_ok(conv_path, remote["conversion.json"]):
        fetch(repo, revision, remote["conversion.json"], conv_path, staging, "conversion.json")
    if not conv_path.is_file():
        raise SetupError("conversion.json is missing and Hugging Face is unreachable")
    listed = json.loads(conv_path.read_text())["files"]

    model_files = set(listed) | {"conversion.json"} | ({n for n in OPTIONAL if remote and n in remote})
    vae_files = {n[len("vae/"):] for n in (remote or {}) if n.startswith("vae/")}

    # Unexpected files in the model folder make verify_conversion fail; vae/ tolerates extras but
    # keep it clean too. Partial downloads live in .staging, so nothing of value is lost here.
    for rel in prune(model, model_files):
        say(f"Repair: removed unexpected {model_name}/{rel}")
    if vae_files:
        for rel in prune(vae, vae_files):
            say(f"Repair: removed unexpected vae/{rel}")

    todo = []
    for name in sorted(model_files):
        path = model / name
        rec = listed.get(name)
        size = rec["bytes"] if rec else (remote[name].size if remote and name in remote else None)
        if path.is_file() and (size is None or path.stat().st_size == size):
            continue  # hashes are checked below by verify_conversion against conversion.json
        if remote is None or name not in remote:
            raise SetupError(f"{model_name}/{name} is missing and Hugging Face is unreachable")
        r = remote[name]
        if rec and r.sha256 and r.sha256 != rec["sha256"]:
            raise SetupError(f"{name}: Hugging Face and conversion.json disagree on the checksum")
        todo.append((r, path, f"{model_name}/{name}"))
    for name in sorted(vae_files):
        r, path = remote[f"vae/{name}"], vae / name
        if file_ok(path, r):
            continue
        todo.append((r, path, f"vae/{name}"))

    if todo:
        partial = sum((staging / (r.name.replace("/", "__") + ".part")).stat().st_size
                      for r, _, _ in todo if (staging / (r.name.replace("/", "__") + ".part")).exists())
        need = sum(r.size for r, _, _ in todo) - partial
        free = shutil.disk_usage(root).free
        say(f"To download: {len(todo)} files, {need / 1e9:.2f} GB ({free / 1e9:.1f} GB free)")
        if free - need < MIN_FREE:
            raise SetupError(f"Not enough disk space: {need / 1e9:.1f} GB needed, {free / 1e9:.1f} GB free")
        if marker.exists():
            marker.unlink()
        for r, path, label in todo:
            fetch(repo, revision, r, path, staging, label)
    shutil.rmtree(staging, ignore_errors=True)

    for attempt in (1, 2):
        try:
            manifest = verify(model, vae)
            break
        except ValueError as error:
            msg = str(error)
            bad = msg.split("Converted file integrity failed: ", 1)
            if attempt == 2 or len(bad) < 2 or remote is None or bad[1] not in remote:
                raise
            name = bad[1].strip()
            say(f"{name} is corrupt; downloading it again")
            (model / name).unlink()
            fetch(repo, revision, remote[name], model / name, staging, f"{model_name}/{name}")
            shutil.rmtree(staging, ignore_errors=True)
    marker.write_text(json.dumps({"repo": repo, "revision": revision, "model_dir": str(model),
                                  "vae_dir": str(vae), "precisions": sorted(manifest["precisions"]),
                                  "verified_at": time.strftime("%Y-%m-%dT%H:%M:%S%z")}, indent=2) + "\n")
    return {"ok": True, "model_dir": str(model), "vae_dir": str(vae), "downloaded": len(todo)}


def main(argv=None):
    ap = argparse.ArgumentParser(prog="studio_engine.mlx_setup")
    ap.add_argument("--repo")
    ap.add_argument("--revision", default="main")
    ap.add_argument("--root", type=Path)
    ap.add_argument("--model-name", default="mlx-Yue2-3B")
    ap.add_argument("--verify-only", action="store_true")
    ap.add_argument("--model-dir", type=Path)
    ap.add_argument("--vae-dir", type=Path)
    args = ap.parse_args(argv)
    try:
        if args.verify_only:
            verify(args.model_dir, args.vae_dir)
            result = {"ok": True, "model_dir": str(args.model_dir), "vae_dir": str(args.vae_dir)}
        else:
            if not args.repo or not args.root:
                ap.error("--repo and --root are required")
            result = setup(args.repo, args.revision, args.root.expanduser(), args.model_name)
        say("Model files verified.")
        emit("result", result)
        return 0
    except (SetupError, ValueError, OSError) as error:
        say(f"ERROR: {error}")
        emit("result", {"ok": False, "error": str(error)})
        return 1


if __name__ == "__main__":
    sys.exit(main())
