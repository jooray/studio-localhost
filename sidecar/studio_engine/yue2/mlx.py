"""YuE2 on MLX: wraps lyra (vanch007/mlx-Yue) without modifying it.

Must run inside the mlx-Yue virtual environment (lyra + yue2 importable). The pipeline stays
resident between jobs; it is rebuilt only when the AR precision or the model paths change.
Progress comes from overriding the pipeline's `_status` context manager (the single place every
stage reports through: token advance, ODE step updates and VAE tile updates).
"""
from __future__ import annotations

import contextlib
import dataclasses
import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

import numpy as np

from ..backend_base import Backend
from ..common import Cancelled
from .prompt import FRAME_RATE, SAMPLE_RATE, SEMANTIC_MAX_TOKENS, continuation_budget, shape_request

_STAGES = {
    "Verifying model files": "load",
    "Planning score": "plan",
    "Using provided score": "plan",
    "Generating song": "semantic",
    "Synthesizing audio": "nar",
    "Loading MLX audio decoder": "load",
    "Decoding audio": "vae",
}


def _stage_key(label: str) -> str:
    if label in _STAGES:
        return _STAGES[label]
    if label.startswith("Loading"):
        return "load"
    return "other"


class _StageProxy:
    """Duck-types yue2.progress._Stage (advance/update/set_total/token/finish)."""

    def __init__(self, backend, label, total, unit):
        self.backend, self.label, self.total, self.unit = backend, label, total, unit
        self.done = 0
        self.stage = _stage_key(label)
        if self.stage in ("plan", "semantic") and total is None:
            self.total = backend._token_totals.get(self.stage)
        self._last = 0.0
        self._send(force=True)

    def _send(self, force=False):
        now = time.monotonic()
        if force or now - self._last >= 0.2:
            self._last = now
            self.backend.progress(self.stage, self.label, self.done, self.total, self.unit)

    def advance(self, count=1):
        self.done += count
        self._send()

    def update(self, completed, total=None):
        self.done = completed
        if total is not None:
            self.total = total
        self._send(force=self.stage in ("nar", "vae"))

    def set_total(self, total):
        self.total = total

    def token(self, phase, token):
        self.advance()

    def finish(self, status="completed"):
        self._send(force=True)


class MLXBackend(Backend):
    name = "mlx"
    families = ("yue2",)
    frame_rate = FRAME_RATE
    sample_rate = SAMPLE_RATE

    def __init__(self, config, emit):
        super().__init__(config, emit)
        self.engine_dir = Path(config.get("engine_dir") or ".").expanduser()
        self.model_dir = Path(config.get("model_dir") or self.engine_dir / "models/mlx-Yue2-3B").expanduser()
        self.vae_dir = Path(config.get("vae_dir") or self.engine_dir / "models/vae").expanduser()
        self.memory_budget_gib = float(config.get("memory_budget_gib") or 0) or None
        self._pipe = None
        self._pipe_key = None
        self._token_totals = {}

    # ------------------------------------------------------------------ status

    def info(self):
        info = {"backend": self.name, "engine_dir": str(self.engine_dir), "python": sys.executable,
                "model_dir": str(self.model_dir), "vae_dir": str(self.vae_dir),
                "resident": self._pipe_key is not None}
        try:
            import lyra  # noqa: F401
            import mlx.core as mx
            from importlib.metadata import version
            info["versions"] = {n: version(n) for n in ("mlx-yue", "mlx", "mlx-lm")}
            info["metal"] = bool(mx.metal.is_available())
            info["venv_ok"] = True
        except Exception as error:  # pragma: no cover - depends on the environment
            info["venv_ok"] = False
            info["venv_error"] = f"{type(error).__name__}: {error}"
        info["weights"] = _weights(self.model_dir, self.vae_dir)
        info["capabilities"] = self.capabilities()
        return info

    def doctor(self):
        exe = Path(sys.executable).parent / "mlx-yue"
        cmd = [str(exe) if exe.exists() else sys.executable, *([] if exe.exists() else ["-m", "lyra.cli"]),
               "doctor", "--model", str(self.model_dir), "--vae", str(self.vae_dir)]
        proc = subprocess.run(cmd, capture_output=True, text=True, cwd=str(self.engine_dir), timeout=300,
                              env={**os.environ, "MLX_ENABLE_TF32": "0"})
        try:
            report = json.loads(proc.stdout)
        except json.JSONDecodeError:
            report = {"status": "error", "stdout": proc.stdout[-2000:], "stderr": proc.stderr[-2000:]}
        report["exit_code"] = proc.returncode
        return report

    def capabilities(self):
        ra = self.engine_dir / "models/realaudio-v4/converted"
        mert = self.engine_dir / "models/hf-cache"
        present = (ra / "nar_lora.safetensors").exists() or any(ra.glob("*.safetensors")) if ra.is_dir() else False
        present = present and mert.is_dir()
        return {"extend": True, "rerender": True, "tokenize_audio": bool(present),
                "tokenize_reason": None if present else (
                    "Extending external audio needs the RealAudio v4 tokenizer head "
                    f"({ra}) and MERT-v2 weights ({mert}), about 3 GB, which are not installed. "
                    "They are not downloaded automatically.")}

    # ------------------------------------------------------------------ pipeline

    def _pipeline(self, precision):
        key = (str(self.model_dir), str(self.vae_dir), precision)
        if self._pipe is not None and self._pipe_key == key:
            try:
                self._pipe._check_execution()
                return self._pipe
            except Exception:
                self.unload()
        self.unload()
        os.environ["MLX_ENABLE_TF32"] = "0"
        from lyra import YuE2Pipeline

        backend = self

        class StudioPipeline(YuE2Pipeline):
            @contextlib.contextmanager
            def _status(self, label, *, total=None, unit=None):
                yield _StageProxy(backend, label, total, unit)

        self.progress("load", "Loading pipeline")
        kwargs = {}
        if self.memory_budget_gib:
            kwargs["memory_budget_gib"] = self.memory_budget_gib
        self._pipe = StudioPipeline(self.model_dir, self.vae_dir, precision=precision, progress=True, **kwargs)
        self._pipe_key = key
        return self._pipe

    def unload(self):
        if self._pipe is not None:
            try:
                self._pipe.close()
            except Exception:
                pass
        self._pipe = None
        self._pipe_key = None

    # ------------------------------------------------------------------ helpers

    def _cancel_fn(self, cancel):
        return lambda: cancel.is_set()

    def _config(self, pipe, steps):
        from yue2.protocol import GenerationConfig
        pipe.generation_config = GenerationConfig(ode_steps=int(steps))

    def _render(self, pipe, semantic, seed, cancel):
        """NAR + VAE for a SemanticResult; returns (audio, latents, timing)."""
        from lyra.pipeline import initial_noise
        cancelled = self._cancel_fn(cancel)
        noise = initial_noise(len(semantic.tokens), seed)
        t0 = time.perf_counter()
        latents = pipe.synthesize(semantic, cancelled=cancelled, noise=noise)
        nar_seconds = time.perf_counter() - t0
        if cancel.is_set():
            raise Cancelled()
        t1 = time.perf_counter()
        audio = pipe.decode(latents, cancelled=cancelled)
        return audio, latents, {"nar_seconds": nar_seconds, "vae_seconds": time.perf_counter() - t1}

    def _run(self, fn):
        try:
            return fn()
        except InterruptedError as error:
            raise Cancelled() from error
        except MemoryError:
            self.unload()
            raise

    # ------------------------------------------------------------------ jobs

    def tokenize_audio(self, path, cancel):
        if not self.capabilities()["tokenize_audio"]:
            raise RuntimeError(self.capabilities()["tokenize_reason"])
        from lyra.realaudio.pipeline import RealAudioPipeline
        self.progress("plan", "Tokenizing audio")
        ra = RealAudioPipeline(self._pipeline("bf16"),
                               converted_dir=self.engine_dir / "models/realaudio-v4/converted")
        tokens, _meta = ra.tokenize_audio(path)
        return [int(t) for t in tokens]

    def generate(self, args, out_dir, cancel):
        return self._run(lambda: self._generate(args, cancel))

    def _generate(self, args, cancel):
        from yue2.protocol import SongRequest
        shaped = shape_request(args)
        pipe = self._pipeline(args.get("precision") or "bf16")
        self._config(pipe, args.get("steps") or 32)
        request = SongRequest(style=shaped["style"], lyrics=shaped["lyrics"], cot=shaped["cot"],
                              seed=int(args["seed"]), abc=shaped["abc"], id=args.get("request_id") or "song")
        max_tokens = SEMANTIC_MAX_TOKENS
        if args.get("max_seconds"):
            max_tokens = max(1, min(SEMANTIC_MAX_TOKENS, int(round(float(args["max_seconds"]) * FRAME_RATE))))
        semantic_sampling = {"max_tokens": max_tokens, "min_tokens": min(200, max_tokens)}
        self._token_totals = {"plan": pipe.generation_config.abc.max_tokens, "semantic": max_tokens}
        config = pipe.effective_config(request, None, semantic_sampling)
        cancelled = self._cancel_fn(cancel)
        start = time.perf_counter()
        plan = pipe.plan(request=request, cancelled=cancelled)
        semantic = pipe.generate_semantic(plan, sampling=semantic_sampling, cancelled=cancelled)
        self.checkpoint(semantic.tokens, plan.abc, getattr(plan, "abc_ids", None), request.to_dict())
        audio, latents, render_timing = self._render(pipe, semantic, request.seed, cancel)
        timing = {"abc": plan.timing, "semantic": semantic.timing, **render_timing,
                  "load": dict(pipe.load_timing), "e2e_seconds": time.perf_counter() - start}
        return {"audio": audio, "codes": semantic.tokens, "abc": plan.abc, "plan": plan,
                "request": request.to_dict(), "config": config, "timing": timing, "latents": latents,
                "truncated": {"abc": bool(plan.truncated), "semantic": bool(semantic.truncated)}}

    def _source_plan(self, pipe, source, request, reuse_score=True):
        """A SymbolicPlan for `request` that carries the source's exact ABC ids when wanted."""
        from yue2.pipeline import SymbolicPlan
        from yue2.protocol import token_prefixes
        if request.cot == "off":
            return SymbolicPlan(request, None, [], token_prefixes(request, pipe.tokenizer)), False
        ids = source.get("abc_ids") if reuse_score else None
        if ids is None and reuse_score and source.get("abc"):
            ids = pipe.tokenizer.encode(source["abc"])
        if ids:
            return SymbolicPlan(request, source.get("abc") or pipe.tokenizer.decode(ids), list(ids),
                                token_prefixes(request, pipe.tokenizer, list(ids)),
                                {"seconds": 0.0, "output_tokens": 0, "reused_source_score": True}), False
        return None, True

    def rerender(self, source, args, out_dir, cancel):
        return self._run(lambda: self._rerender(source, args, cancel))

    def _rerender(self, source, args, cancel):
        from yue2.pipeline import SemanticResult
        from yue2.protocol import SongRequest
        pipe = self._pipeline(args.get("precision") or "bf16")
        self._config(pipe, args.get("steps") or 32)
        src = source["request"]
        request = SongRequest(style=src.get("style", ""), lyrics=src.get("lyrics", ""),
                              cot=src.get("cot", "off"), seed=int(args["seed"]), abc=None,
                              cfg_scale=src.get("cfg_scale"), id=src.get("id") or "song")
        if source.get("abc") is None and src.get("abc"):
            source = {**source, "abc": src["abc"]}
        plan, needs_plan = self._source_plan(pipe, source, request)
        if needs_plan:
            raise ValueError("Source has no saved score; re-render needs the exact ABC of a cot=full/melody song")
        request = plan.request
        codes = [int(c) for c in source["codes"]]
        semantic = SemanticResult(plan, codes, {"reused_source_semantic": True}, False)
        start = time.perf_counter()
        audio, latents, render_timing = self._render(pipe, semantic, request.seed, cancel)
        timing = {"abc": plan.timing, "semantic": semantic.timing, **render_timing,
                  "load": dict(pipe.load_timing), "e2e_seconds": time.perf_counter() - start}
        return {"audio": audio, "codes": codes, "abc": plan.abc, "request": request.to_dict(),
                "config": pipe.effective_config(request), "timing": timing, "latents": latents,
                "truncated": {"abc": False, "semantic": False}}

    def continue_song(self, source, a, b, args, cancel):
        return self._run(lambda: self._continue(source, a, b, args, cancel))

    def _continue(self, source, a, b, args, cancel):
        """yue2.cpp pipeline_continue_codes on lyra: the section codes follow the normal prompt
        prefix (style + lyrics + ABC) and the AR keeps sampling semantic tokens from there."""
        from lyra.ar import generate_tokens  # noqa: F401  (import check)
        from yue2.pipeline import SemanticResult, SymbolicPlan
        from yue2.protocol import CODEC_OFFSET, SongRequest, negative_prefix, resolve_sampling
        shaped = shape_request(args)
        pipe = self._pipeline(args.get("precision") or "bf16")
        self._config(pipe, args.get("steps") or 32)
        request = SongRequest(style=shaped["style"], lyrics=shaped["lyrics"], cot=shaped["cot"],
                              seed=int(args["seed"]), abc=None, id=args.get("request_id") or "song")
        cancelled = self._cancel_fn(cancel)
        start = time.perf_counter()
        plan, needs_plan = self._source_plan(pipe, source, request, args.get("reuse_score", True))
        if needs_plan:
            self._token_totals = {"plan": pipe.generation_config.abc.max_tokens}
            plan = pipe.plan(request=request, cancelled=cancelled)
        section = [int(c) + CODEC_OFFSET for c in source["codes"][a:b]]
        budget = continuation_budget(len(section), args.get("add_seconds"), prefix_len=len(plan.prefix))
        base = resolve_sampling(None, pipe.generation_config.semantic)
        sampling = dataclasses.replace(base, max_tokens=budget, min_tokens=min(base.min_tokens, budget))
        self._token_totals = {"semantic": budget}
        negative = None
        if request.guidance != 1:
            negative = negative_prefix(request, pipe.tokenizer, plan.abc_ids) + section
        drawn, sem_timing, truncated = pipe._generate(
            plan.prefix + section, sampling, request.seed, "semantic", negative=negative,
            cfg_scale=request.guidance, legacy_off=request.cot == "off", cancelled=cancelled)
        new_codes = [int(t) - CODEC_OFFSET for t in drawn]
        codes = [int(c) for c in source["codes"][a:b]] + new_codes
        sem_timing = {**sem_timing, "section_frames": len(section), "new_frames": len(new_codes),
                      "budget": budget}
        semantic = SemanticResult(plan, codes, sem_timing, truncated)
        audio, latents, render_timing = self._render(pipe, semantic, request.seed, cancel)
        config = pipe.effective_config(request, None, dataclasses.asdict(sampling))
        timing = {"abc": plan.timing, "semantic": sem_timing, **render_timing,
                  "load": dict(pipe.load_timing), "e2e_seconds": time.perf_counter() - start}
        return {"audio": audio, "codes": codes, "abc": plan.abc, "request": request.to_dict(),
                "config": config, "timing": timing, "latents": latents,
                "truncated": {"abc": bool(plan.truncated), "semantic": bool(truncated)},
                "new_frames": len(new_codes)}


def _weights(model_dir: Path, vae_dir: Path):
    files = []
    for directory, names in ((model_dir, ("ar-bf16.safetensors", "ar-8bit.safetensors", "ar-4bit.safetensors",
                                          "nar-bf16.safetensors", "qwen.tiktoken", "conversion.json")),
                             (vae_dir, ("model.safetensors", "config.json"))):
        for name in names:
            path = directory / name
            files.append({"name": f"{directory.name}/{name}", "path": str(path), "present": path.is_file(),
                          "bytes": path.stat().st_size if path.is_file() else 0})
    return files
