"""torch backend (stub): the official YuE2 reference pipeline (yue2 / yue2_infer wheel) for CUDA Linux.

Not implemented in 0.1.0. The reference `yue2.YuE2Pipeline` exposes the same staged API that the
mlx backend drives (plan -> generate_semantic -> synthesize -> decode), so a full implementation can
reuse MLXBackend's flow almost verbatim; continuation would call its `_generate` with the section
codes appended to the prefix exactly as in backend_mlx._continue.
"""
from __future__ import annotations

from .backend_base import Backend


class TorchBackend(Backend):
    name = "torch"

    def info(self):
        try:
            import torch  # noqa: F401
            import yue2  # noqa: F401
            ok, err = True, None
        except Exception as error:
            ok, err = False, f"{type(error).__name__}: {error}"
        return {"backend": self.name, "venv_ok": ok, "venv_error": err, "weights": [],
                "capabilities": self.capabilities(), "stub": True}

    def doctor(self):
        return {"status": "fail", "reason": "torch backend is a stub in YuE2 Studio 0.1.0"}

    def capabilities(self):
        return {"extend": False, "rerender": False, "tokenize_audio": False,
                "tokenize_reason": "torch backend is a stub"}

    def _unsupported(self, *_, **__):
        raise NotImplementedError("The torch backend is not implemented yet; use mlx or yue2cpp")

    generate = rerender = continue_song = _unsupported
