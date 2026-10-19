"""Localhost Recording Studio engine sidecar: JSON-lines over stdio.

Requests (one JSON object per line on stdin):
  {"id": "r1", "cmd": "configure", "backend": "mlx", "family": "yue2", ...backend config}
  {"id": "r2", "cmd": "generate", "job": "j1", "output_dir": "...", ...params}
  {"id": "r3", "cmd": "cancel", "job": "j1"}
  {"id": "r4", "cmd": "cover", "job": "j2", "output_dir": "...", "source_audio": "...", ...params}
Responses: {"id": "r1", "ok": true, "result": {...}} | {"id": "r1", "ok": false, "error": "..."}
Events:    {"event": "progress", "job": "j1", "stage": "semantic", "label": "...", "done": 10,
            "total": 750, "unit": "tokens", "elapsed": 3.2}
           {"event": "job_done", "job": "j1", "result": {...}}
           {"event": "job_failed", "job": "j1", "error": "...", "cancelled": false}
           {"event": "log", "line": "..."}   {"event": "ready", ...}

Only one GPU job runs at a time (the app owns the queue); a second job is rejected with "busy".
Library stdout is redirected to stderr so that stdout carries only protocol lines.
"""
from __future__ import annotations

import json
import os
import platform
import sys
import threading
import time
import traceback
from pathlib import Path

from . import common
from .common import APP_VERSION, Cancelled

PROTOCOL_VERSION = 1


class Server:
    def __init__(self, out):
        self._out = out
        self._lock = threading.Lock()
        self.backend = None
        self.backend_name = None
        self._job = None  # (job_id, cancel_event, thread)
        self._job_started = 0.0
        self._last_cfg = None

    # ------------------------------------------------------------------ io

    def send(self, obj):
        line = json.dumps(obj, ensure_ascii=False, default=common._json_default)
        with self._lock:
            self._out.write(line + "\n")
            self._out.flush()

    def _emit_for(self, job_id):
        def emit(event="progress", **fields):
            payload = {"event": event, "job": job_id, **fields}
            if event == "progress":
                payload["elapsed"] = round(time.monotonic() - self._job_started, 2)
            self.send(payload)
        return emit

    # ------------------------------------------------------------------ backends

    def _make_backend(self, cfg):
        name = cfg.get("backend") or default_backend()
        emit = self._emit_proxy
        family = cfg.get("family") or "yue2"
        backends = {
            ("yue2", "mlx"): ("yue2.mlx", "MLXBackend"),
            ("yue2", "yue2cpp"): ("yue2.cpp", "Yue2CppBackend"),
            ("yue2", "torch"): ("yue2.torch_stub", "TorchBackend"),
        }
        if (family, name) not in backends:
            raise ValueError(f"No backend {name!r} for the model family {family!r}")
        module, cls = backends[(family, name)]
        import importlib
        return getattr(importlib.import_module(f".{module}", __package__), cls)(cfg, emit)

    def _emit_proxy(self, **fields):
        job = self._job[0] if self._job else None
        self._emit_for(job)(**fields)

    # ------------------------------------------------------------------ commands

    def handle(self, msg):
        cmd = msg.get("cmd")
        fn = getattr(self, f"cmd_{cmd}", None)
        if fn is None:
            raise ValueError(f"Unknown command {cmd!r}")
        return fn(msg)

    def cmd_ping(self, msg):
        return {"pong": True}

    def cmd_hello(self, msg):
        return {"app_version": APP_VERSION, "protocol": PROTOCOL_VERSION, "python": sys.executable,
                "platform": platform.platform(), "machine": platform.machine(),
                "default_backend": default_backend(), "backend": self.backend_name}

    def cmd_configure(self, msg):
        if self._busy():
            raise RuntimeError("busy")
        cfg = {k: v for k, v in msg.items() if k not in ("id", "cmd")}
        if self.backend is not None and cfg == self._last_cfg:
            return {"backend": self.backend_name, "unchanged": True}
        if self.backend is not None:
            self.backend.unload()
        self.backend = self._make_backend(cfg)
        self.backend_name = self.backend.name
        self._last_cfg = cfg
        return {"backend": self.backend_name}

    def _need_backend(self):
        if self.backend is None:
            raise RuntimeError("Backend not configured")
        return self.backend

    def cmd_info(self, msg):
        info = self._need_backend().info()
        info["busy"] = self._busy()
        info["job"] = self._job[0] if self._job else None
        return info

    def cmd_doctor(self, msg):
        if self._busy():
            raise RuntimeError("busy")
        return self._need_backend().doctor()

    def cmd_unload(self, msg):
        if self._busy():
            raise RuntimeError("busy")
        if self.backend:
            self.backend.unload()
        return {"unloaded": True}

    def cmd_cancel(self, msg):
        if self._job and (msg.get("job") in (None, self._job[0])):
            self._job[1].set()
            return {"cancelling": self._job[0]}
        return {"cancelling": None}

    def cmd_export(self, msg):
        return common.export_audio(msg["source"], msg["destination"], msg.get("format", "mp3"),
                                   msg.get("ffmpeg"))

    def cmd_stats(self, msg):
        return common.audio_stats(msg["path"])

    def cmd_shutdown(self, msg):
        if self._job:
            self._job[1].set()
        threading.Timer(0.2, lambda: os._exit(0)).start()
        return {"bye": True}

    # jobs ----------------------------------------------------------------

    def _busy(self):
        return self._job is not None and self._job[2].is_alive()

    def _start_job(self, msg, work):
        backend = self._need_backend()
        if self._busy():
            raise RuntimeError("busy")
        job_id = msg.get("job") or msg["id"]
        cancel = threading.Event()

        def run():
            self._job_started = time.monotonic()
            emit = self._emit_for(job_id)
            try:
                result = work(backend, msg, cancel)
                emit("job_done", result=result)
            except Cancelled:
                emit("job_failed", error="Cancelled", cancelled=True)
            except BaseException as error:  # noqa: BLE001
                traceback.print_exc(file=sys.stderr)
                emit("job_failed", error=f"{type(error).__name__}: {error}", cancelled=cancel.is_set())
            finally:
                self._job = None

        thread = threading.Thread(target=run, name=f"job-{job_id}", daemon=True)
        self._job = (job_id, cancel, thread)
        thread.start()
        return {"job": job_id, "accepted": True}

    def cmd_generate(self, msg):
        return self._start_job(msg, _job_generate)

    def cmd_rerender(self, msg):
        return self._start_job(msg, _job_rerender)

    def cmd_extend(self, msg):
        return self._start_job(msg, _job_extend)

    def cmd_cover(self, msg):
        return self._start_job(msg, _job_cover)


def _params(msg):
    return {k: v for k, v in msg.items() if k not in ("id", "cmd")}


def _extra_npy(abc_ids):
    if abc_ids:
        return {"abc_tokens.npy": __import__("numpy").asarray(abc_ids, dtype="int32")}
    return None


def _save(backend, out, result, keep_latents=True, steps=None, **kw):
    saved = common.save_song(out, audio=result["audio"], sample_rate=backend.sample_rate, codes=result["codes"],
                             abc=result.get("abc"), request=result["request"], config=result["config"],
                             timing=result["timing"], truncated=result["truncated"], **kw)
    work = Path(out) / "work"
    # The finished mix's latents, so a sketch can be refined later without mixing from scratch.
    latents = result.get("latents")
    if keep_latents and latents is not None and steps:
        from .yue2 import flow
        flow.write_latents(work, latents, int(steps), int(result["request"]["seed"]))
    (work / "preview.flac").unlink(missing_ok=True)
    return saved


def _job_generate(backend, msg, cancel):
    out = common.prepare_dir(msg["output_dir"])
    backend.work_dir = out / "work"
    checkpoint = out / "work" / "tokens.csv"
    if msg.get("resume") and checkpoint.is_file():
        # The token stream was complete when the job stopped: render it instead of sampling again.
        source = common.load_source(out / "work")
        if source["abc"] is None and (out / "work" / "score.abc").is_file():
            source["abc"] = (out / "work" / "score.abc").read_text(encoding="utf-8")
        result = backend.rerender(source, msg, out, cancel)
        result["timing"]["resumed_from"] = "tokens"
        abc_ids = source.get("abc_ids")
    else:
        result = backend.generate(msg, out, cancel)
        plan = result.get("plan")
        abc_ids = getattr(plan, "abc_ids", None) if plan is not None else None
    backend.progress("post", "Saving")
    return _save(backend, out, result, steps=msg.get("steps") or 32, extra_npy=_extra_npy(abc_ids))


def _job_rerender(backend, msg, cancel):
    source = common.load_source(msg["source_dir"])
    out = common.prepare_dir(msg["output_dir"])
    backend.work_dir = out / "work"
    result = backend.rerender(source, msg, out, cancel)
    backend.progress("post", "Saving")
    return _save(backend, out, result, steps=msg.get("steps") or 32, extra_npy=_extra_npy(source.get("abc_ids")))


def _job_cover(backend, msg, cancel):
    """Cover a recording: transcribe its score (kept in work/cover.abc, so a stopped job does not
    listen again), then a new song from that score with the cover's words and style."""
    out = common.prepare_dir(msg["output_dir"])
    work = out / "work"
    backend.work_dir = work
    mode = msg.get("mode") if msg.get("mode") in ("full", "melody") else "full"
    score = work / "cover.abc"
    shared = Path(msg["score_from"]) / "work" / "cover.abc" if msg.get("score_from") else None
    if shared is not None and shared.is_file() and shared.read_text(encoding="utf-8").strip() \
            and not (score.is_file() and score.read_text(encoding="utf-8").strip()):
        # Another take of the same cover already listened to the recording.
        work.mkdir(parents=True, exist_ok=True)
        tmp = work / "cover.abc.tmp"
        tmp.write_text(shared.read_text(encoding="utf-8"), encoding="utf-8")
        tmp.replace(score)
    if not (score.is_file() and score.read_text(encoding="utf-8").strip()):
        abc = backend.transcribe(msg["source_audio"], mode, work / "transcription", cancel)
        tmp = work / "cover.abc.tmp"
        tmp.write_text(abc, encoding="utf-8")
        tmp.replace(score)
    return _job_generate(backend, {**msg, "mode": mode, "instrumental": False,
                                   "abc": score.read_text(encoding="utf-8")}, cancel)


def _job_extend(backend, msg, cancel):
    import numpy as np
    fr = backend.frame_rate
    if msg.get("source_audio"):
        codes = backend.tokenize_audio(msg["source_audio"], cancel)
        source = {"dir": Path(msg["source_audio"]).parent, "codes": np.asarray(codes), "request": {},
                  "abc": None, "abc_ids": None, "meta": {}, "audio_path": Path(msg["source_audio"])}
    else:
        source = common.load_source(msg["source_dir"])
    n = len(source["codes"])
    a, b = common.section_frames(n, msg.get("section_start", max(0.0, n / fr - 30)), msg.get("section_end"), fr)
    out = common.prepare_dir(msg["output_dir"])
    backend.work_dir = out / "work"
    result = backend.continue_song(source, a, b, msg, cancel)
    backend.progress("post", "Splicing")
    render = result["audio"]
    samples_per_frame = backend.sample_rate // fr
    if a == 0 or source.get("audio_path") is None:
        final, seam = render, {"seam_sample": 0, "crossfade_samples": 0, "used": "render"}
    else:
        original = common.read_audio(source["audio_path"], backend.sample_rate)
        final, seam = common.splice(original, render, a * samples_per_frame, backend.sample_rate,
                                    float(msg.get("crossfade", 2.0)))
        seam["used"] = "splice"
    timeline = np.concatenate([np.asarray(source["codes"][:a], dtype=np.int64),
                               np.asarray(result["codes"], dtype=np.int64)])
    abc_ids = source.get("abc_ids") if result.get("abc") == source.get("abc") else None
    section = {"start_frame": a, "end_frame": b, "start_seconds": a / fr, "end_seconds": b / fr,
               "source_frames": n, "new_frames": result.get("new_frames"),
               "add_seconds": msg.get("add_seconds")}
    saved = _save(backend, out, {**result, "audio": final, "codes": timeline}, keep_latents=False,
                  extra_audio={"render.flac": render} if seam["used"] == "splice" else None,
                  extra_npy=_extra_npy(abc_ids))
    saved["seam"] = seam
    saved["section"] = section
    return saved


def default_backend():
    if sys.platform == "darwin" and platform.machine() == "arm64":
        return "mlx"
    return "yue2cpp"


def main():
    os.environ.setdefault("MLX_ENABLE_TF32", "0")
    proto = os.fdopen(os.dup(1), "w", buffering=1, encoding="utf-8")
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    server = Server(proto)
    server.send({"event": "ready", "app_version": APP_VERSION, "protocol": PROTOCOL_VERSION,
                 "python": sys.executable, "default_backend": default_backend(), "pid": os.getpid()})
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError as error:
            server.send({"id": None, "ok": False, "error": f"Bad JSON: {error}"})
            continue
        try:
            result = server.handle(msg)
            server.send({"id": msg.get("id"), "ok": True, "result": result})
        except Exception as error:  # noqa: BLE001
            traceback.print_exc(file=sys.stderr)
            server.send({"id": msg.get("id"), "ok": False, "error": f"{type(error).__name__}: {error}"})
    # stdin closed: the app went away
    if server._job:
        server._job[1].set()
    os._exit(0)


if __name__ == "__main__":
    main()
