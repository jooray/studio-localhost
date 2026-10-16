"""Backend-independent pieces: request shaping, artifact layout, splicing, export."""
from __future__ import annotations

import datetime as _dt
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf

APP_VERSION = "0.1.0"
SAMPLE_RATE = 48000
FRAME_RATE = 25
SAMPLES_PER_FRAME = SAMPLE_RATE // FRAME_RATE  # 1920
SEMANTIC_MAX_TOKENS = 9000
CONTEXT = 24576


class Cancelled(Exception):
    pass


def now_iso() -> str:
    return _dt.datetime.now().astimezone().isoformat(timespec="seconds")


def instrumental_style(style: str) -> str:
    """Same rewrite as `mlx-yue generate --instrumental` (lyra/cli.py:_request)."""
    style = style or "Instrumental music"
    if "instrumental" not in style.lower():
        style = "Instrumental, " + style.lstrip("., ")
    for cue in ("no vocals", "no singing"):
        if cue not in style.lower():
            style = style.rstrip("., ") + f", {cue}"
    return style.rstrip("., ") + "."


DEFAULT_INSTRUMENTAL_LYRICS = "[Intro]\n\n[Verse]\n\n[Chorus]\n\n[Outro]\n"


def shape_request(args: dict) -> dict:
    """Normalise UI parameters into (style, lyrics, cot, abc)."""
    style = (args.get("style") or "").strip()
    lyrics = args.get("lyrics") or ""
    mode = args.get("mode") or "full"
    abc = args.get("abc") or None
    if abc is not None and not abc.strip():
        abc = None
    if args.get("instrumental"):
        style = instrumental_style(style)
        mode = "off"  # cot=full instrumental plans truncate; the CLI flag is used with --mode off
        abc = None
        if not lyrics.strip():
            lyrics = DEFAULT_INSTRUMENTAL_LYRICS
    if mode == "off":
        abc = None
    if mode not in ("full", "melody", "off"):
        raise ValueError("mode must be full, melody or off")
    return {"style": style, "lyrics": lyrics, "cot": mode, "abc": abc}


def fresh_dir(path) -> Path:
    path = Path(path)
    if path.exists() and any(path.iterdir()):
        raise FileExistsError(f"Output directory is not empty: {path}")
    path.mkdir(parents=True, exist_ok=True)
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


def save_song(directory, *, audio: np.ndarray, codes, abc: str | None, request: dict, config: dict,
              timing: dict, truncated: dict, studio: dict, latents=None, extra_audio: dict | None = None,
              extra_npy: dict | None = None):
    """Write the mlx-yue artifact layout (audio.flac, semantic.npy, score.abc, request.json,
    config.json, result.json) plus studio.json with the app-level parameters."""
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    audio = np.clip(np.asarray(audio, dtype=np.float32), -1.0, 1.0)
    sf.write(directory / "audio.flac", audio, SAMPLE_RATE, subtype="PCM_24")
    np.save(directory / "semantic.npy", np.asarray(codes, dtype=np.int32), allow_pickle=False)
    if latents is not None:
        np.save(directory / "latent.npy", np.asarray(latents, dtype=np.float32), allow_pickle=False)
    if abc:
        (directory / "score.abc").write_bytes(abc.encode("utf-8"))
    for name, data in (extra_audio or {}).items():
        sf.write(directory / name, np.clip(np.asarray(data, dtype=np.float32), -1, 1), SAMPLE_RATE,
                 subtype="PCM_24")
    for name, data in (extra_npy or {}).items():
        np.save(directory / name, np.asarray(data), allow_pickle=False)
    write_json(directory / "request.json", request)
    write_json(directory / "config.json", config)
    result = {
        "status": "complete",
        "truncated": truncated,
        "sample_rate": SAMPLE_RATE,
        "audio_seconds": len(audio) / SAMPLE_RATE,
        "semantic_frames": int(len(codes)),
        "timing": timing,
    }
    write_json(directory / "result.json", result)
    studio = {"app": "YuE2 Studio", "app_version": APP_VERSION, "created": now_iso(), **studio}
    write_json(directory / "studio.json", studio)
    return {"output": str(directory), "audio_seconds": result["audio_seconds"],
            "truncated": truncated, "timing": timing}


# ----------------------------------------------------------------------------------------
# Source songs (anything with semantic.npy + request.json, i.e. mlx-yue or Studio output)


def load_source(source_dir) -> dict:
    source_dir = Path(source_dir)
    codes_path = source_dir / "semantic.npy"
    if not codes_path.is_file():
        raise FileNotFoundError(f"{source_dir} has no semantic.npy; it cannot be extended or re-rendered")
    codes = np.load(codes_path, allow_pickle=False).astype(np.int64).reshape(-1)
    request = {}
    if (source_dir / "request.json").is_file():
        request = json.loads((source_dir / "request.json").read_text(encoding="utf-8"))
    abc = None
    if (source_dir / "score.abc").is_file():
        abc = (source_dir / "score.abc").read_bytes().decode("utf-8")
    abc_ids = None
    if (source_dir / "abc_tokens.npy").is_file():
        ids = np.load(source_dir / "abc_tokens.npy", allow_pickle=False).astype(np.int64).tolist()
        abc_ids = ids or None
    studio = {}
    if (source_dir / "studio.json").is_file():
        studio = json.loads((source_dir / "studio.json").read_text(encoding="utf-8"))
    audio_path = source_dir / "audio.flac"
    return {"dir": source_dir, "codes": codes, "request": request, "abc": abc, "abc_ids": abc_ids,
            "studio": studio, "audio_path": audio_path if audio_path.is_file() else None}


def section_frames(n_frames: int, start_s: float, end_s: float | None):
    a = int(np.clip(round(float(start_s) * FRAME_RATE), 0, n_frames))
    b = n_frames if end_s is None or end_s < 0 else int(np.clip(round(float(end_s) * FRAME_RATE), 0, n_frames))
    if b <= a:
        raise ValueError(f"Empty source section {start_s:.2f} s .. {end_s} s")
    return a, b


def continuation_budget(section_len: int, add_seconds: float | None, prefix_len: int = 0,
                        max_tokens: int = SEMANTIC_MAX_TOKENS) -> int:
    """New frames the AR may write: the requested length counts the section (as yue2.cpp)."""
    budget = max_tokens - section_len
    if add_seconds is not None and add_seconds > 0:
        target = section_len + int(round(add_seconds * FRAME_RATE))
        budget = min(budget, target - section_len)
    if prefix_len:
        budget = min(budget, CONTEXT - prefix_len - section_len)
    if budget < 1:
        raise ValueError(f"Nothing left to write after the {section_len} frames of the section")
    return budget


def splice(original: np.ndarray, render: np.ndarray, start_frame: int, crossfade_s: float = 2.0):
    """original[:start] + render, render[0] aligned to original[start]; equal-power crossfade over
    the first `crossfade_s` of the render (both sides carry the same section there)."""
    start = start_frame * SAMPLES_PER_FRAME
    if start <= 0:
        return render.astype(np.float32), {"seam_sample": 0, "crossfade_samples": 0}
    original = original.astype(np.float32)
    render = render.astype(np.float32)
    start = min(start, len(original))
    n = int(min(crossfade_s * SAMPLE_RATE, len(original) - start, len(render)))
    head = original[:start]
    if n <= 0:
        return np.concatenate([head, render]), {"seam_sample": start, "crossfade_samples": 0}
    t = (np.arange(n, dtype=np.float64) + 0.5) / n
    fade_in = np.sin(t * np.pi / 2).astype(np.float32)[:, None]
    fade_out = np.cos(t * np.pi / 2).astype(np.float32)[:, None]
    mixed = original[start:start + n] * fade_out + render[:n] * fade_in
    out = np.concatenate([head, mixed, render[n:]])
    return out, {"seam_sample": start, "crossfade_samples": n}


def read_audio(path) -> np.ndarray:
    data, sr = sf.read(str(path), dtype="float32", always_2d=True)
    if sr != SAMPLE_RATE:  # external recordings: linear resample to the model rate
        n = int(round(len(data) * SAMPLE_RATE / sr))
        x = np.linspace(0, len(data) - 1, n)
        data = np.stack([np.interp(x, np.arange(len(data)), data[:, c]) for c in range(data.shape[1])],
                        axis=1).astype(np.float32)
    if data.shape[1] == 1:
        data = np.repeat(data, 2, axis=1)
    return data


# ----------------------------------------------------------------------------------------
# Export


def find_ffmpeg(hint: str | None = None) -> str | None:
    for candidate in (hint, "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg",
                      shutil.which("ffmpeg")):
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


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


def tmpdir(prefix="yue2-") -> Path:
    return Path(tempfile.mkdtemp(prefix=prefix))
