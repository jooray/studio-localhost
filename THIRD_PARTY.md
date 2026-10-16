# Third-party components

Localhost Recording Studio is MIT-licensed (see `LICENSE`). It builds on the components
below. Model weights are not part of this repository or of the app packages; each model is
downloaded by the user after accepting its own licence (see "Models").

## Compiled into the app

| Component | Use | Licence |
|---|---|---|
| [Flutter](https://flutter.dev) engine and framework | UI on every platform | BSD-3-Clause |
| [yue2.cpp](https://github.com/ServeurpersoCom/yue2.cpp) (git submodule, `android/app/src/main/cpp/yue2.cpp`) | YuE2 inference on Android (JNI) | MIT |
| [ggml](https://github.com/ServeurpersoCom/ggml) (submodule of yue2.cpp) | tensor library | MIT |
| yyjson (vendored in yue2.cpp) | JSON parsing | MIT |
| minimp3 (vendored in yue2.cpp) | MP3 decoding | CC0-1.0 |
| mp3enc (in yue2.cpp) | MP3 encoding | MIT |
| `android/patches/yue2-android-hooks.patch` | progress hooks and thread override for yue2.cpp | MIT (this project) |
| [media_kit](https://github.com/media-kit/media-kit) and `media_kit_libs_*` | audio playback | MIT |
| libmpv and FFmpeg (prebuilt, shipped by `media_kit_libs_*`) | audio decoding and output | LGPL-2.1-or-later builds, dynamically linked |
| [provider](https://pub.dev/packages/provider) | state management | MIT |
| [file_selector](https://pub.dev/packages/file_selector) | open/save dialogs | BSD-3-Clause |
| [crypto](https://pub.dev/packages/crypto), [path](https://pub.dev/packages/path) | SHA-256, paths | BSD-3-Clause |
| AndroidX Core | FileProvider, compat helpers | Apache-2.0 |

The Flutter "Licences" page in About lists every Dart package with its full licence text.

## Installed at setup time on desktop (not shipped in the app)

| Component | Use | Licence |
|---|---|---|
| `sidecar/studio_engine` (this repository) | engine sidecar, JSON lines over stdio | MIT |
| [numpy](https://numpy.org), [soundfile](https://github.com/bastibe/python-soundfile) (libsndfile) | sidecar audio I/O | BSD-3-Clause (libsndfile: LGPL-2.1-or-later) |
| [mlx-Yue](https://github.com/vanch007/mlx-Yue) (cloned at a pinned commit into the app data folder) | YuE2 on MLX, Apple Silicon | Apache-2.0 |
| [MLX](https://github.com/ml-explore/mlx), mlx-lm | Apple Silicon arrays | MIT |
| huggingface_hub (in the mlx-Yue venv) | model download | Apache-2.0 |
| [yue2.cpp](https://github.com/ServeurpersoCom/yue2.cpp) (cloned and built locally on Linux / Intel Macs) | YuE2 with CUDA, Vulkan, Metal or CPU | MIT |
| [uv](https://github.com/astral-sh/uv) (user-installed) | Python environments | MIT / Apache-2.0 |

## Models

Model weights carry their own licences, recorded in `assets/models/registry.json`, shown in the
setup flow and accepted before download. Each song stores the model id and licence it was made with.

| Model | Files | Licence |
|---|---|---|
| YuE2-3B by M-A-P | [Serveurperso/YuE2-GGUF](https://huggingface.co/Serveurperso/YuE2-GGUF) (GGUF), [vanch007/mlx-Yue2-3B](https://huggingface.co/vanch007/mlx-Yue2-3B) (MLX) | CC BY-NC 4.0 (non-commercial) |

None of the vendored code is under a copyleft licence that would conflict with distributing the
app under MIT; the LGPL libraries (libmpv, FFmpeg, libsndfile) are used as separate, dynamically
linked libraries.
