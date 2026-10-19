"""Download the transcriber a cover needs on MLX: SheetSage2 and its MERT-v2 parent, pinned, into
the Hugging Face cache mlx-Yue reads (models/hf-cache in the engine folder, shared with the
RealAudio tokenizer).

usage: python -m studio_engine.cover_setup --cache-dir DIR

Progress goes to stdout like mlx_setup: plain lines, `@progress {json}` and a final `@result {json}`.
Runs inside the mlx-Yue venv (huggingface_hub and lyra importable).
"""
from __future__ import annotations

import argparse
import json
import threading
from pathlib import Path


def emit(kind, data):
    print(f"@{kind} {json.dumps(data)}", flush=True)


def _repo_bytes(cache: Path, repo: str) -> int:
    """Bytes on disk for a repo in the cache, partial downloads included."""
    root = cache / ("models--" + repo.replace("/", "--")) / "blobs"
    if not root.is_dir():
        return 0
    return sum(f.stat().st_size for f in root.iterdir() if f.is_file())


def present(cache_dir) -> bool:
    """Both checkpoints are in the cache (no network)."""
    try:
        from lyra.transcription.model import resolve_models
        model, parent = resolve_models(offline=True, cache_dir=str(cache_dir))
        return (Path(model) / "model.safetensors").is_file() and (Path(parent) / "model.safetensors").is_file()
    except Exception:
        return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache-dir", required=True)
    args = ap.parse_args()
    cache = Path(args.cache_dir)
    cache.mkdir(parents=True, exist_ok=True)
    try:
        from huggingface_hub import HfApi, snapshot_download
        from lyra.transcription.model import MERT_REPO, MERT_REVISION, MODEL_REPO, MODEL_REVISION
        api = HfApi()
        for repo, revision in ((MODEL_REPO, MODEL_REVISION), (MERT_REPO, MERT_REVISION)):
            info = api.model_info(repo, revision=revision, files_metadata=True)
            total = sum(s.size or 0 for s in info.siblings if s.rfilename in ("config.json", "model.safetensors"))
            print(f"Downloading {repo} ({total / 1e9:.2f} GB)", flush=True)
            stop = threading.Event()

            def watch():
                while not stop.wait(0.5):
                    emit("progress", {"file": repo, "done": min(total, _repo_bytes(cache, repo)), "total": total})

            t = threading.Thread(target=watch, daemon=True)
            t.start()
            try:
                snapshot_download(repo, revision=revision, cache_dir=str(cache),
                                  allow_patterns=["config.json", "model.safetensors"])
            finally:
                stop.set()
                t.join()
            emit("progress", {"file": repo, "done": total, "total": total})
        if not present(cache):
            raise RuntimeError("The transcriber is still incomplete after the download")
        emit("result", {"ok": True})
    except Exception as error:  # noqa: BLE001
        print(f"ERROR: {type(error).__name__}: {error}", flush=True)
        emit("result", {"ok": False, "error": f"{type(error).__name__}: {error}"})
        raise SystemExit(1)


if __name__ == "__main__":
    main()
