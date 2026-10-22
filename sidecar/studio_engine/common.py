"""Model-independent pieces: the shared song folder layout, splicing, audio io and export.

Song folder (shared with the Android engine and the app; the app owns song.json):
  song.json            metadata written by the app (title, params, model, licence, status, timing)
  audio.flac|mp3       the final song
  render.flac|mp3      extend only: the raw continuation render (before the splice)
  tokens.csv           the model's token stream for the whole song timeline (comma separated ints)
  score.abc            the symbolic score, when the model wrote or reused one
  work/                engine checkpoints and engine-specific artifacts (request/config/result json)
"""
from __future__ import annotations

import datetime as _dt
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf

APP_VERSION = "0.3.0"


class Cancelled(Exception):
    pass


def now_iso() -> str:
    return _dt.datetime.now().astimezone().isoformat(timespec="seconds")


def prepare_dir(path) -> Path:
    """The song folder: may already hold song.json and checkpoints in work/."""
    path = Path(path)
    path.mkdir(parents=True, exist_ok=True)
    (path / "work").mkdir(exist_ok=True)
    return path


def write_json(path, data):
    Path(path).write_text(json.dumps(data, indent=2, ensure_ascii=False, default=_json_default) + "\n",
                          encoding="utf-8")


def _json_default(value):
    if isinstance(value, (np.integer,)):
        return int(value)
    if isinstance(value, (np.floating,)):
        return float(value)
    if isinstance(value, np.ndarray):
        return value.tolist()
    if isinstance(value, Path):
        return str(value)
    return str(value)


def write_tokens(path, codes):
    tmp = Path(str(path) + ".tmp")
    tmp.write_text(",".join(str(int(c)) for c in codes), encoding="utf-8")
    tmp.replace(path)


def read_tokens(path) -> list[int]:
    text = Path(path).read_text(encoding="utf-8").replace("\n", ",")
    return [int(x) for x in text.split(",") if x.strip()]


def save_song(directory, *, audio: np.ndarray, sample_rate: int, codes, abc: str | None, request: dict,
              config: dict, timing: dict, truncated: dict, extra_audio: dict | None = None,
              extra_npy: dict | None = None) -> dict:
    """Write the shared layout; returns the result the app merges into song.json."""
    directory = Path(directory)
    work = directory / "work"
    work.mkdir(parents=True, exist_ok=True)
    audio = np.clip(np.asarray(audio, dtype=np.float32), -1.0, 1.0)
    sf.write(directory / "audio.flac", audio, sample_rate, subtype="PCM_24")
    write_tokens(directory / "tokens.csv", codes)
    if abc:
        (directory / "score.abc").write_bytes(abc.encode("utf-8"))
    for name, data in (extra_audio or {}).items():
        sf.write(directory / name, np.clip(np.asarray(data, dtype=np.float32), -1, 1), sample_rate,
                 subtype="PCM_24")
    for name, data in (extra_npy or {}).items():
        np.save(work / name, np.asarray(data), allow_pickle=False)
    write_json(work / "request.json", request)
    write_json(work / "config.json", config)
    result = {
        "audio": "audio.flac",
        "render": next(iter(extra_audio)) if extra_audio else None,
        "truncated": truncated,
        "sample_rate": sample_rate,
        "audio_seconds": len(audio) / sample_rate,
        "token_frames": int(len(codes)),
        "engine_timing": timing,
    }
    write_json(work / "result.json", result)
    return result


# ----------------------------------------------------------------------------------------
# Source songs: the shared layout, or a legacy folder that keeps its stream in semantic.npy


def _audio_in(directory: Path, meta: dict) -> Path | None:
    names = [meta.get("audio")] if meta.get("audio") else []
    names += ["audio.flac", "audio.mp3", "audio.wav"]
    for name in names:
        if name and (directory / name).is_file():
            return directory / name
    return None


def load_source(source_dir) -> dict:
    source_dir = Path(source_dir)
    meta = {}
    if (source_dir / "song.json").is_file():
        meta = json.loads((source_dir / "song.json").read_text(encoding="utf-8"))
    if (source_dir / "tokens.csv").is_file():
        codes = np.asarray(read_tokens(source_dir / "tokens.csv"), dtype=np.int64)
    elif (source_dir / "semantic.npy").is_file():
        codes = np.load(source_dir / "semantic.npy", allow_pickle=False).astype(np.int64).reshape(-1)
    else:
        raise FileNotFoundError(f"{source_dir} has no token stream; it cannot be extended or re-rendered")
    params = meta.get("params") or {}
    request = {}
    for candidate in (source_dir / "work" / "request.json", source_dir / "request.json"):
        if candidate.is_file():
            request = json.loads(candidate.read_text(encoding="utf-8"))
            break
    if params:
        # The app's metadata wins: an Android song has no engine request.json of the same shape.
        request = {**request, "style": request.get("style") or params.get("style", ""),
                   "lyrics": request.get("lyrics") or params.get("lyrics", ""),
                   "cot": request.get("cot") or params.get("mode", "off")}
    abc = None
    if (source_dir / "score.abc").is_file():
        abc = (source_dir / "score.abc").read_bytes().decode("utf-8")
    abc_ids = None
    for candidate in (source_dir / "work" / "abc_tokens.npy", source_dir / "abc_tokens.npy"):
        if candidate.is_file():
            ids = np.load(candidate, allow_pickle=False).astype(np.int64).tolist()
            abc_ids = ids or None
            break
    return {"dir": source_dir, "codes": codes, "request": request, "abc": abc, "abc_ids": abc_ids,
            "meta": meta, "audio_path": _audio_in(source_dir, meta)}


def section_frames(n_frames: int, start_s: float, end_s: float | None, frame_rate: int):
    a = int(np.clip(round(float(start_s) * frame_rate), 0, n_frames))
    b = n_frames if end_s is None or end_s < 0 else int(np.clip(round(float(end_s) * frame_rate), 0, n_frames))
    if b <= a:
        raise ValueError(f"Empty source section {start_s:.2f} s .. {end_s} s")
    return a, b


def splice(original: np.ndarray, render: np.ndarray, start_sample: int, sample_rate: int,
           crossfade_s: float = 2.0):
    """original[:start] + render, render[0] aligned to original[start]; equal-power crossfade over
    the first `crossfade_s` of the render (both sides carry the same section there)."""
    start = start_sample
    if start <= 0:
        return render.astype(np.float32), {"seam_sample": 0, "crossfade_samples": 0}
    original = original.astype(np.float32)
    render = render.astype(np.float32)
    start = min(start, len(original))
    n = int(min(crossfade_s * sample_rate, len(original) - start, len(render)))
    head = original[:start]
    if n <= 0:
        return np.concatenate([head, render]), {"seam_sample": start, "crossfade_samples": 0}
    t = (np.arange(n, dtype=np.float64) + 0.5) / n
    fade_in = np.sin(t * np.pi / 2).astype(np.float32)[:, None]
    fade_out = np.cos(t * np.pi / 2).astype(np.float32)[:, None]
    mixed = original[start:start + n] * fade_out + render[:n] * fade_in
    out = np.concatenate([head, mixed, render[n:]])
    return out, {"seam_sample": start, "crossfade_samples": n}


def read_audio(path, sample_rate: int = 48000) -> np.ndarray:
    data, sr = sf.read(str(path), dtype="float32", always_2d=True)
    if sr != sample_rate:  # external recordings: linear resample to the model rate
        n = int(round(len(data) * sample_rate / sr))
        x = np.linspace(0, len(data) - 1, n)
        data = np.stack([np.interp(x, np.arange(len(data)), data[:, c]) for c in range(data.shape[1])],
                        axis=1).astype(np.float32)
    if data.shape[1] == 1:
        data = np.repeat(data, 2, axis=1)
    return data


# ----------------------------------------------------------------------------------------
# Cover scores: one transcription per recording, shared by every cover of it


def source_digest(path) -> str:
    """Content key for a recording, so copies of the same file share one score."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def cover_score_cache(source, mode: str, song_dir) -> Path:
    """Where the score heard in this recording lives: beside the library, not inside a take.

    Keyed by the file's bytes and the transcription mode (full keeps chords, melody does not), so
    a new cover from the same recording skips listening even in a later session or another take
    whose folder has been deleted."""
    song_dir = Path(song_dir)
    # v1: bump when the transcriber or its output format changes.
    return song_dir.parent.parent / "cache" / "covers" / f"v1-{source_digest(source)}-{mode}.abc"


def write_cover_score(cache: Path, abc: str) -> None:
    """Best effort: a cache that cannot be written must never fail the song."""
    try:
        cache.parent.mkdir(parents=True, exist_ok=True)
        tmp = cache.with_name(cache.name + ".tmp")
        tmp.write_text(abc, encoding="utf-8")
        tmp.replace(cache)
    except OSError:
        pass


# ----------------------------------------------------------------------------------------
# Export


def find_ffmpeg(hint: str | None = None) -> str | None:
    home = Path.home()
    for candidate in (hint, "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg",
                      "/snap/bin/ffmpeg", home / ".local/bin/ffmpeg", home / "bin/ffmpeg",
                      shutil.which("ffmpeg")):
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def use_system_ffmpeg(hint: str | None = None) -> str:
    """Find ffmpeg and put its folder on PATH for the rest of this process.

    lyra's transcriber (cover listening) shells out to a bare `ffmpeg`, and a GUI-launched app
    misses Homebrew on macOS and ~/.local/bin or snap on Linux. Returns the binary it found."""
    ffmpeg = find_ffmpeg(hint)
    if ffmpeg is None:
        raise RuntimeError("Covers need ffmpeg, and it is not on PATH: install it "
                           "(brew install ffmpeg on macOS, apt or snap on Linux) or set its path in Settings")
    folder = str(Path(ffmpeg).parent)
    parts = [p for p in os.environ.get("PATH", "").split(os.pathsep) if p]
    if folder not in parts:
        os.environ["PATH"] = os.pathsep.join([folder, *parts])
    return ffmpeg


def export_audio(source, destination, fmt: str, ffmpeg_hint: str | None = None, mp3_bitrate: int = 256):
    source, destination = Path(source), Path(destination)
    fmt = fmt.lower()
    if fmt not in ("mp3", "flac", "wav", "m4a"):
        raise ValueError("Format must be mp3, flac, wav or m4a")
    destination.parent.mkdir(parents=True, exist_ok=True)
    ffmpeg = find_ffmpeg(ffmpeg_hint)
    if ffmpeg:
        codec = {"mp3": ["-codec:a", "libmp3lame", "-b:a", f"{mp3_bitrate}k"],
                 "flac": ["-codec:a", "flac"], "wav": ["-codec:a", "pcm_s24le"],
                 "m4a": ["-codec:a", "aac", "-b:a", "256k"]}[fmt]
        cmd = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", str(source), *codec, str(destination)]
        subprocess.run(cmd, check=True, capture_output=True)
        return {"output": str(destination), "tool": "ffmpeg"}
    if fmt == "m4a":
        raise RuntimeError("m4a export needs ffmpeg")
    data, sr = sf.read(str(source), dtype="float32", always_2d=True)
    if fmt == "mp3":
        sf.write(str(destination), data, sr, format="MP3")
    elif fmt == "flac":
        sf.write(str(destination), data, sr, subtype="PCM_24", format="FLAC")
    else:
        sf.write(str(destination), data, sr, subtype="PCM_24", format="WAV")
    return {"output": str(destination), "tool": "soundfile"}


def audio_stats(path) -> dict:
    data, sr = sf.read(str(path), dtype="float32", always_2d=True)
    rms = float(np.sqrt(np.mean(np.square(data)))) if data.size else 0.0
    return {"seconds": len(data) / sr, "sample_rate": sr, "channels": data.shape[1],
            "rms_dbfs": 20 * np.log10(max(rms, 1e-12)), "peak": float(np.max(np.abs(data))) if data.size else 0.0}


def tmpdir(prefix="studio-") -> Path:
    return Path(tempfile.mkdtemp(prefix=prefix))
