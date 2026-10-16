"""The interface every engine backend implements."""
from __future__ import annotations

import threading
from typing import Callable


class Backend:
    name = "base"

    def __init__(self, config: dict, emit: Callable[..., None]):
        self.config = dict(config)
        self._emit = emit

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
