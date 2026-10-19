"""The acoustic (NAR) flow solve for the MLX backend, with two additions over lyra's solver:

- a preview: partway through, one jump from the current state to the clean latents
  (x0 = x_t - t * v) decoded to audio, so a long render can be judged before it finishes;
- a refine: start from a finished song's latents pulled back to time t on the straight path
  from the same noise (x_t = x0 + t * (noise - x0)), then solve the rest with fine steps.

Same midpoint math, noise and chunk cuts as lyra.nar.synthesize, so a plain solve is bit
identical to pipe.synthesize."""

from __future__ import annotations

from pathlib import Path

import numpy as np

LATENT_DIM = 64


def write_latents(work: Path, latents: np.ndarray, steps: int, seed: int) -> None:
    """work/latents.f32 (float32 little-endian, frames x 64) and its description."""
    import json
    lat = np.ascontiguousarray(latents, dtype="<f4")
    tmp = work / "latents.f32.tmp"
    lat.tofile(tmp)
    tmp.replace(work / "latents.f32")
    (work / "latents.json").write_text(json.dumps(
        {"frames": int(lat.shape[0]), "dim": int(lat.shape[1]), "steps": int(steps), "seed": int(seed)}))


def read_latents(work: Path) -> tuple[np.ndarray, dict]:
    import json
    info = json.loads((work / "latents.json").read_text())
    lat = np.fromfile(work / "latents.f32", dtype="<f4").reshape(info["frames"], info["dim"])
    return lat, info


def solve(pipe, semantic, seed: int, steps: int, *, cancelled, on_progress=None,
          preview_at: int | None = None, on_preview=None,
          start: np.ndarray | None = None, start_t: float = 1.0) -> np.ndarray:
    """Return float32 [frames, 64] latents.

    steps: the schedule (dt = 1/steps). With `start`, the solve begins at `start_t` from those
    latents and runs round(start_t * steps) steps. `on_preview(latents)` is called once after
    step `preview_at` (single-chunk songs only)."""
    import mlx.core as mx
    from lyra.nar import CachedNAR, _chunks_with_supplied_noise, _logit
    from lyra.pipeline import initial_noise

    pipe._check_execution()
    model = pipe._load_model(for_nar=True)
    tokens = semantic.tokens
    noise = initial_noise(len(tokens), seed)
    chunks = _chunks_with_supplied_noise(semantic.plan.prefix, tokens, seed,
                                         pipe.generation_config.context, noise)
    if start is not None and start.shape != (len(tokens), LATENT_DIM):
        raise ValueError(f"Saved latents have {start.shape[0]} frames, the song has {len(tokens)}")
    n_steps = steps if start is None else max(1, round(start_t * steps))
    t0 = 1.0 if start is None else n_steps / steps
    dt = 1.0 / steps
    half, full = mx.array(dt / 2.0, dtype=mx.float32), mx.array(dt, dtype=mx.float32)
    mx.eval(half, full)
    total = n_steps * len(chunks)
    out, offset = [], 0
    for index, chunk in enumerate(chunks):
        if cancelled():
            raise InterruptedError("Cancelled before acoustic prefill")
        frames = len(chunk.noise)
        engine = CachedNAR(model, chunk, query_chunk_size=pipe.query_chunk_size, cancelled=cancelled)
        try:
            state = engine._initial_state
            if start is not None:
                x0 = mx.array(start[offset:offset + frames], dtype=mx.float32)
                state = (x0 + t0 * (state.astype(mx.float32) - x0)).astype(mx.bfloat16)
            t = t0
            for step in range(n_steps):
                if cancelled():
                    raise InterruptedError("Cancelled during acoustic flow matching")
                first = engine.velocity(state, _logit(t))
                mx.eval(first)
                mid = state - (first.astype(mx.float32) * half).astype(mx.bfloat16)
                if cancelled():
                    raise InterruptedError("Cancelled during acoustic flow matching")
                velocity = engine.velocity(mid, _logit(t - dt / 2.0))
                state = state - (velocity.astype(mx.float32) * full).astype(mx.bfloat16)
                mx.eval(state)
                t = t0 - (step + 1) * dt
                if on_progress is not None:
                    on_progress(index * n_steps + step + 1, total)
                if on_preview is not None and len(chunks) == 1 and step + 1 == preview_at and t > 0:
                    v = engine.velocity(state, _logit(t))
                    guess = state - (v.astype(mx.float32) * t).astype(mx.bfloat16)
                    on_preview(np.array(guess.astype(mx.float32), dtype=np.float32))
            result = np.array(state.astype(mx.float32), dtype=np.float32, copy=True)
        finally:
            engine.close()
        if not np.isfinite(result).all():
            raise FloatingPointError("Acoustic flow matching produced non-finite latents")
        out.append(result)
        offset += frames
    return out[0] if len(out) == 1 else np.concatenate(out, axis=0)


def preview_step(steps: int) -> int | None:
    """When to take a preview: a quarter of the way, for renders long enough to be worth it."""
    return steps // 4 if steps >= 16 else None
