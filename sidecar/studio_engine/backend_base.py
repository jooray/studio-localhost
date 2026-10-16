"""The interface every engine backend implements (one backend = one model family on one runtime)."""
from __future__ import annotations

import threading
from typing import Callable


class Backend:
    name = "base"
    families: tuple[str, ...] = ()
    frame_rate = 25          # semantic frames per second of the model's token stream
    sample_rate = 48000

    def __init__(self, config: dict, emit: Callable[..., None]):
        self.config = dict(config)
        self._emit = emit
        self.work_dir = None  # the running job's checkpoint folder (song/work)

    def checkpoint(self, codes, abc=None, abc_ids=None, request=None):
        """Save the finished token stream so a stopped job can resume without sampling again."""
        if self.work_dir is None:
            return
        from pathlib import Path

        from .common import write_json, write_tokens
        work = Path(self.work_dir)
        work.mkdir(parents=True, exist_ok=True)
        if abc:
            (work / "score.abc").write_text(abc, encoding="utf-8")
        if abc_ids:
            import numpy as np
            np.save(work / "abc_tokens.npy", np.asarray(abc_ids, dtype=np.int32), allow_pickle=False)
        if request is not None:
            write_json(work / "request.json", request)
        write_tokens(work / "tokens.csv", codes)

    # progress(stage, label, done, total, unit) -- stage in load|plan|semantic|nar|vae|post
    def progress(self, stage: str, label: str, done=None, total=None, unit=None, **extra):
        self._emit(stage=stage, label=label, done=done, total=total, unit=unit, **extra)

    def info(self) -> dict:
        raise NotImplementedError

    def capabilities(self) -> dict:
        return {"extend": True, "rerender": True, "tokenize_audio": False,
                "tokenize_reason": "Not supported by this backend"}

    def generate(self, args: dict, out_dir, cancel: threading.Event) -> dict:
        raise NotImplementedError

    def rerender(self, source: dict, args: dict, out_dir, cancel: threading.Event) -> dict:
        raise NotImplementedError

    def continue_song(self, source: dict, a: int, b: int, args: dict, cancel: threading.Event) -> dict:
        """Return {audio, codes, abc, request, config, timing, truncated} for the whole continued
        stream (section + new frames), rendered from frame `a` of the source."""
        raise NotImplementedError

    def tokenize_audio(self, path, cancel: threading.Event):
        raise RuntimeError(self.capabilities().get("tokenize_reason") or "Unsupported")

    def unload(self):
        pass
