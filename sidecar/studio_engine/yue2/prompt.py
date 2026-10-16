"""YuE2 request shaping shared by the YuE2 backends (and mirrored by the Android engine)."""
from __future__ import annotations

FRAME_RATE = 25            # semantic frames per second
SAMPLE_RATE = 48000
SEMANTIC_MAX_TOKENS = 9000  # about 6 minutes
CONTEXT = 24576

DEFAULT_INSTRUMENTAL_LYRICS = "[Intro]\n\n[Verse]\n\n[Chorus]\n\n[Outro]\n"


def instrumental_style(style: str) -> str:
    """Same rewrite as `mlx-yue generate --instrumental` (lyra/cli.py:_request)."""
    style = style or "Instrumental music"
    if "instrumental" not in style.lower():
        style = "Instrumental, " + style.lstrip("., ")
    for cue in ("no vocals", "no singing"):
        if cue not in style.lower():
            style = style.rstrip("., ") + f", {cue}"
    return style.rstrip("., ") + "."


def shape_request(args: dict) -> dict:
    """Normalise app parameters into (style, lyrics, cot, abc)."""
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
