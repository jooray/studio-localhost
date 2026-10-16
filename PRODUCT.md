# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

## Stack

Flutter, one codebase for Android, macOS and Linux (this repo grows from the YuE2 Studio desktop app; the Kotlin "YuE2 Pocket" Android app is folded in). Engine is chosen by hardware, not by OS:
- Apple Silicon Mac: MLX via the mlx-Yue engine in a Python sidecar (uv venv).
- Linux (and Macs without MLX): yue2.cpp (CUDA / Vulkan / CPU) via the same sidecar protocol.
- Android: yue2.cpp in-process (NDK/JNI, CPU) inside a foreground service.

## Users

Public from day one: people who want to make full songs from a style description and lyrics entirely on their own hardware, with no cloud service, account or upload. They range from phone users (e.g. a Pixel 10 Pro Fold, where a song takes many minutes and runs in the background) to desktop users with Apple Silicon or Linux GPUs (a song in minutes). The first user is the author, who generates batches of variants and then extends the keepers.

## Product Purpose

Localhost Recording Studio turns a style prompt plus lyrics into a full stereo song, locally, with open music-generation models. It is model-agnostic: YuE2-3B is the first supported model; others (with their own licences and capabilities) can be added through a model registry and engine adapters. Core loop: write style and lyrics, generate one or several variants, listen, keep the good ones, extend a song from any section, export or share. Success means a newcomer gets from install to a first song without reading documentation, and a returning user can queue work and walk away.

## Positioning

Everything runs on the user's own machine ("localhost"): no server, no account, no upload, works offline after the model download. One app on phone, tablet and desktop with the same library concepts.

## Operating Context

- Long-running jobs: seconds per song on a fast Mac, many minutes to hours on a phone CPU. Users leave and come back; jobs must survive backgrounding, show progress, and resume after being killed.
- One generation at a time per device; work is queued.
- First run requires a multi-gigabyte model download (about 3–4 GB on Android, ~8–11 GB on desktop). This is the moment for setup information.
- Layout adapts by screen size, not by OS: phone, unfolded foldable or tablet, desktop window.

## Capabilities and Constraints

- Generate: style, lyrics with section tags ([Intro], [Verse], [Chorus]…), instrumental toggle (uses score planning off; the model has no hard zero-vocal guarantee), seed, quality/steps, max length, optional ABC score.
- Batch variants with consecutive seeds; queue.
- Library: playback, details, re-render with another seed or step count, export (MP3/FLAC/WAV), share sheet on Android.
- Extend: continue a song from a chosen section (default last 30 s), crossfade splice onto the original; chained extends.
- Hard limits for YuE2-3B: about 6 minutes (9000 semantic tokens) per song including extensions; long instrumental scores in full mode can truncate.
- The app is FOSS under the MIT licence; the GitHub repo stays private until v1. Each model carries its own licence, shown and accepted at model download and recorded per song; YuE2-3B weights are CC BY-NC 4.0 (non-commercial). Engines used: mlx-Yue (Apache-2.0), yue2.cpp (MIT).
- Features a model lacks (e.g. extend/continuation, instrumental, ABC score) are hidden for that model, driven by declared capabilities.
- Versioned releases with an update check.
- Undecided: distribution channels beyond Zapstore/GitHub; whether desktop builds are signed/notarized.

## Brand Commitments

- Name: Localhost Recording Studio. Published on GitHub as free/open-source software (MIT).
- Not branded around any single model; model names appear only where a model is chosen or credited.
- Icon: a white polar pulse plot (waveform burst around a spindle hole) on matte black with the five-block colour code strip (`assets/brand/icon-master-1024.png`, macOS variant `assets/brand/icon-macos-1024.png`). Replaces the earlier gold-crescent icon after the Catalogue Sleeve direction was chosen.
- One shared look on every OS, adapting by screen size (user decision).
- Minimalistic interface: little text in the main UI. Licence notices, model details and long explanations belong in the model download/setup step, shown once, without spamming the user (user decision).

## Evidence on Hand

- Real generated songs: example songs generated during development (not in the repo).
- Measured timings: Mac M2 Max via MLX, 25 s song in ~23 s at 8 steps (8-bit AR), extend +15 s in ~14 s; full 4–6 min songs at 32 steps bf16 ~20–25 min. Android timings not yet measured on device; community Termux numbers suggest a few minutes per 10 s at 8 steps on a phone CPU.
- No testimonials, users or press exist; do not fabricate any.

## Product Principles

1. Local or nothing: never require a network after setup, never send user content anywhere.
2. Walk-away friendly: long jobs are visible, resumable and cancellable; the user is never stuck watching a spinner.
3. Quiet by default: the main screens show the instrument, not the manual; explanations appear once, at the moment they matter.
4. Same studio everywhere: phone, foldable and desktop share concepts and library; only density changes with screen size.
5. Honest about limits: truncation, non-commercial weights and slow hardware are stated plainly where relevant, never hidden.
