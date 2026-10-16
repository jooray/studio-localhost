"""yue2cpp backend: runs yue2.cpp's `yue-synth` once per job with GGUF weights.

Continuation and re-rendering are native request fields there (`source_tokens`/`source_start`/
`source_end`, `semantic_tokens`). Progress is mapped from yue-synth's stderr:
  [AR] Score 100/4096, [AR] Semantic 300/9000, [AR] ... end token at step N,
  [NAR] Step i/N, [NAR] Song 0 chunk c/C, [VAE] Tiled decode: N tiles, [VAE] Tiled decode done
Cancel terminates the process (it polls nothing from us).
"""
from __future__ import annotations

import json
import os
import re
import shutil
import signal
import subprocess
import threading
import time
from pathlib import Path

import numpy as np
import soundfile as sf

from ..backend_base import Backend
from ..common import Cancelled, read_audio, tmpdir
from .prompt import FRAME_RATE, SAMPLE_RATE, SEMANTIC_MAX_TOKENS, shape_request

_AR = re.compile(r"^\[AR\] (Score|Semantic) (\d+)/(\d+)")
_AR_END = re.compile(r"^\[AR\] (Score|Semantic) song \d+: end token at step (\d+)")
_AR_PREFILL = re.compile(r"^\[AR\] (Score|Semantic) prefill: .*budget=(\d+)")
_NAR_STEP = re.compile(r"^\[NAR\] Step (\d+)/(\d+)")
_NAR_CHUNKS = re.compile(r"^\[NAR\] Song \d+: (\d+) frames .* (\d+) chunks? of")
_NAR_CHUNK = re.compile(r"^\[NAR\] Song \d+ chunk (\d+)/(\d+)")
_VAE_TILES = re.compile(r"^\[VAE\] Tiled decode: (\d+) tiles")
_VAE_DONE = re.compile(r"^\[VAE\] Tiled decode done")


class Yue2CppBackend(Backend):
    name = "yue2cpp"
    families = ("yue2",)
    frame_rate = FRAME_RATE
    sample_rate = SAMPLE_RATE

    def __init__(self, config, emit):
        super().__init__(config, emit)
        self.bin_dir = Path(config.get("yue2cpp_bin_dir") or "").expanduser()
        self.model = Path(config.get("gguf_model") or "").expanduser()
        self.vae = Path(config.get("gguf_vae") or "").expanduser()
        self.device = config.get("device") or None
        self._proc = None

    def _synth(self):
        for name in ("yue-synth", "yue-synth.exe"):
            for candidate in (self.bin_dir / name, self.bin_dir / "build" / name):
                if candidate.is_file():
                    return candidate
        found = shutil.which("yue-synth")
        return Path(found) if found else None

    def info(self):
        synth = self._synth()
        weights = []
        for path in (self.model, self.vae):
            weights.append({"name": path.name, "path": str(path), "present": path.is_file(),
                            "bytes": path.stat().st_size if path.is_file() else 0})
        info = {"backend": self.name, "yue_synth": str(synth) if synth else None,
                "venv_ok": synth is not None, "weights": weights, "device": self.device,
                "capabilities": self.capabilities()}
        if synth:
            try:
                proc = subprocess.run([str(synth)], capture_output=True, text=True, timeout=20)
                info["usage"] = (proc.stderr or proc.stdout)[:400]
            except Exception as error:
                info["usage"] = str(error)
        return info

    def doctor(self):
        info = self.info()
        ok = info["yue_synth"] is not None and all(w["present"] for w in info["weights"])
        return {"status": "pass" if ok else "fail", **info}

    def capabilities(self):
        tok = sorted(self.model.parent.glob("yue2-mothersuperior-realaudio-tokenizer-v4-*.gguf")) \
            if self.model.parent.is_dir() else []
        tool = (self.bin_dir / "yue-tokenize").is_file() or (self.bin_dir / "build/yue-tokenize").is_file()
        ok = bool(tok) and tool
        return {"extend": True, "rerender": True, "tokenize_audio": ok,
                "tokenize_reason": None if ok else
                "Needs yue-tokenize plus the RealAudio tokenizer and MERT GGUFs next to the backbone."}

    # ------------------------------------------------------------------ process

    def _run_synth(self, request: dict, work: Path, cancel: threading.Event, totals: dict):
        synth = self._synth()
        if synth is None:
            raise FileNotFoundError("yue-synth not found; build yue2.cpp in Models > Set up engine")
        for path in (self.model, self.vae):
            if not path.is_file():
                raise FileNotFoundError(f"GGUF not found: {path}")
        (work / "request.json").write_text(json.dumps(request, ensure_ascii=False), encoding="utf-8")
        cmd = [str(synth), "--model", str(self.model), "--vae", str(self.vae),
               "--request", str(work / "request.json"), "--out", str(work / "song.wav"),
               "--tokens", str(work / "tokens.csv"), "--score", str(work / "score.abc")]
        if self.device:
            cmd += ["--device", self.device]
        self.progress("load", "Starting yue-synth")
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
                                cwd=str(work), start_new_session=True)
        self._proc = proc
        watcher = threading.Thread(target=self._watch_cancel, args=(proc, cancel), daemon=True)
        watcher.start()
        tail = []
        state = {"nar_chunks": 1, "nar_chunk": 0, "steps": request.get("steps", 32)}
        for raw in proc.stdout:
            line = raw.rstrip()
            tail = (tail + [line])[-40:]
            self._emit(event="log", line=line)
            self._parse(line, state, totals)
        code = proc.wait()
        self._proc = None
        if cancel.is_set():
            raise Cancelled()
        if code != 0:
            raise RuntimeError(f"yue-synth exited with {code}:\n" + "\n".join(tail[-12:]))
        return work

    def _watch_cancel(self, proc, cancel):
        while proc.poll() is None:
            if cancel.wait(0.2):
                try:
                    os.killpg(proc.pid, signal.SIGINT)
                    time.sleep(2)
                    if proc.poll() is None:
                        os.killpg(proc.pid, signal.SIGKILL)
                except Exception:
                    proc.kill()
                return

    def _parse(self, line, state, totals):
        if m := _AR_PREFILL.match(line):
            phase = "plan" if m.group(1) == "Score" else "semantic"
            totals[phase] = int(m.group(2))
            self.progress(phase, "Planning score" if phase == "plan" else "Generating song", 0, totals[phase],
                          "tokens")
        elif m := _AR.match(line):
            phase = "plan" if m.group(1) == "Score" else "semantic"
            self.progress(phase, "Planning score" if phase == "plan" else "Generating song", int(m.group(2)),
                          totals.get(phase) or int(m.group(3)), "tokens")
        elif m := _AR_END.match(line):
            phase = "plan" if m.group(1) == "Score" else "semantic"
            n = int(m.group(2))
            self.progress(phase, "Planning score" if phase == "plan" else "Generating song", n, n, "tokens")
        elif m := _NAR_CHUNKS.match(line):
            state["nar_chunks"] = int(m.group(2))
        elif m := _NAR_CHUNK.match(line):
            state["nar_chunk"] = int(m.group(1))
        elif m := _NAR_STEP.match(line):
            i, n = int(m.group(1)), int(m.group(2))
            chunks = max(1, state["nar_chunks"])
            done = min(state["nar_chunk"], chunks - 1) * n + i
            self.progress("nar", "Synthesizing audio", done, chunks * n, "steps")
            if i == n:
                state["nar_chunk"] += 1
        elif m := _VAE_TILES.match(line):
            state["tiles"] = int(m.group(1))
            self.progress("vae", "Decoding audio", 0, state["tiles"], "chunks")
        elif _VAE_DONE.match(line):
            self.progress("vae", "Decoding audio", state.get("tiles", 1), state.get("tiles", 1), "chunks")

    def _collect(self, work: Path, request: dict, t0: float, truncated_hint=None):
        audio = read_audio(work / "song.wav")
        codes = []
        if (work / "tokens.csv").is_file():
            text = (work / "tokens.csv").read_text().replace("\n", ",")
            codes = [int(x) for x in text.split(",") if x.strip()]
        abc = (work / "score.abc").read_text(encoding="utf-8") if (work / "score.abc").is_file() else None
        expected = len(codes) * 1920 - 64
        semantic_cap = request.get("semantic_sampling", {}).get("max_tokens", SEMANTIC_MAX_TOKENS)
        truncated = {"abc": False, "semantic": bool(truncated_hint) if truncated_hint is not None
                     else len(codes) >= min(semantic_cap, int(request.get("duration", 360) * FRAME_RATE))}
        timing = {"e2e_seconds": time.perf_counter() - t0, "audio_samples_expected": expected}
        return {"audio": audio, "codes": codes, "abc": abc or request.get("abc") or None, "request": request,
                "config": {"backend": "yue2cpp", "model": str(self.model), "vae": str(self.vae),
                           "steps": request.get("steps"), "device": self.device},
                "timing": timing, "truncated": truncated, "latents": None}

    def _base_request(self, shaped, args):
        seed = int(args["seed"])
        return {"style": shaped["style"], "lyrics": shaped["lyrics"], "cot": shaped["cot"],
                "abc": shaped["abc"] or "", "lm_seed": seed, "seed": seed, "steps": int(args.get("steps") or 32),
                "output_format": "wav32"}

    # ------------------------------------------------------------------ jobs

    def generate(self, args, out_dir, cancel):
        shaped = shape_request(args)
        request = self._base_request(shaped, args)
        if args.get("max_seconds"):
            request["duration"] = float(args["max_seconds"])
        work = tmpdir("yue2cpp-")
        t0 = time.perf_counter()
        try:
            self._run_synth(request, work, cancel, {})
            result = self._collect(work, request, t0)
            self.checkpoint(result["codes"], result.get("abc"), None, request)
            return result
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def rerender(self, source, args, out_dir, cancel):
        src = source["request"]
        request = {"style": src.get("style", ""), "lyrics": src.get("lyrics", ""), "cot": src.get("cot", "off"),
                   "abc": source.get("abc") or src.get("abc") or "", "seed": int(args["seed"]),
                   "lm_seed": int(args["seed"]), "steps": int(args.get("steps") or 32), "output_format": "wav32",
                   "semantic_tokens": ",".join(str(int(c)) for c in source["codes"])}
        work = tmpdir("yue2cpp-")
        t0 = time.perf_counter()
        try:
            self._run_synth(request, work, cancel, {})
            result = self._collect(work, request, t0, truncated_hint=False)
            result["codes"] = [int(c) for c in source["codes"]]
            return result
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def continue_song(self, source, a, b, args, cancel):
        shaped = shape_request(args)
        request = self._base_request(shaped, args)
        if shaped["cot"] != "off" and args.get("reuse_score", True) and source.get("abc"):
            request["abc"] = source["abc"]
        request["source_tokens"] = ",".join(str(int(c)) for c in source["codes"])
        request["source_start"] = a / FRAME_RATE
        request["source_end"] = b / FRAME_RATE
        if args.get("add_seconds"):
            request["duration"] = (b - a) / FRAME_RATE + float(args["add_seconds"])
        work = tmpdir("yue2cpp-")
        t0 = time.perf_counter()
        try:
            self._run_synth(request, work, cancel, {})
            result = self._collect(work, request, t0)
            result["new_frames"] = max(0, len(result["codes"]) - (b - a))
            return result
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def unload(self):
        if self._proc is not None and self._proc.poll() is None:
            self._proc.terminate()
