import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/library.dart';
import '../core/paths.dart';
import '../core/settings.dart';
import '../core/sidecar.dart';
import '../core/update_check.dart';
import 'widgets.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Settings>();
    final sc = context.read<Sidecar>();
    void changed(String key, String v) {
      s.set(key, v.trim().isEmpty ? null : v.trim());
      sc.stop(); // restart with the new configuration on next use
    }

    return PageScaffold(
      title: 'Settings',
      subtitle: 'Stored in ${AppPaths.instance.settingsFile}',
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          SectionCard(
            title: 'Engine backend',
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(value: '', label: Text('Automatic (${Settings.platformDefaultBackend})')),
                  const ButtonSegment(value: 'mlx', label: Text('mlx')),
                  const ButtonSegment(value: 'yue2cpp', label: Text('yue2.cpp')),
                  const ButtonSegment(value: 'torch', label: Text('torch (stub)')),
                ],
                selected: {s.backendOverride},
                onSelectionChanged: (v) {
                  s.set('backend', v.first.isEmpty ? null : v.first);
                  sc.stop();
                },
              ),
              const SizedBox(height: 14),
              _PathField(label: 'Sidecar Python (blank = per backend)', value: s.sidecarPythonOverride, hint: s.sidecarPython, onChanged: (v) => changed('sidecarPython', v)),
            ]),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'mlx (mlx-Yue)',
            child: Column(children: [
              _PathField(label: 'Engine directory (with .venv)', value: s.raw('mlxEngineDir'), hint: s.mlxEngineDir, directory: true, onChanged: (v) => changed('mlxEngineDir', v)),
              _PathField(label: 'Model directory', value: s.raw('mlxModelDir'), hint: s.mlxModelDir, directory: true, onChanged: (v) => changed('mlxModelDir', v)),
              _PathField(label: 'VAE directory', value: s.raw('mlxVaeDir'), hint: s.mlxVaeDir, directory: true, onChanged: (v) => changed('mlxVaeDir', v)),
            ]),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'yue2.cpp',
            child: Column(children: [
              _PathField(label: 'Binary directory (yue-synth)', value: s.raw('yue2cppBinDir'), hint: s.yue2cppBinDir, directory: true, onChanged: (v) => changed('yue2cppBinDir', v)),
              _PathField(label: 'Backbone GGUF', value: s.raw('ggufModel'), hint: s.ggufModel, onChanged: (v) => changed('ggufModel', v)),
              _PathField(label: 'VAE GGUF', value: s.raw('ggufVae'), hint: s.ggufVae, onChanged: (v) => changed('ggufVae', v)),
              _PathField(label: 'Device (e.g. CUDA0, Vulkan0, MTL0, CPU; blank = best)', value: s.raw('yue2cppDevice'), hint: '', onChanged: (v) => changed('yue2cppDevice', v)),
            ]),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Library',
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('New songs: ${AppPaths.instance.libraryDir}'),
              const SizedBox(height: 8),
              const Text('Imported folders (read-only; each subfolder with audio.flac is a song):'),
              for (final r in s.importRoots)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(r),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      s.importRoots = s.importRoots.where((x) => x != r).toList();
                      context.read<Library>().refresh();
                    },
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Import folder…'),
                  onPressed: () async {
                    final d = await getDirectoryPath();
                    if (d != null && context.mounted) {
                      s.importRoots = {...s.importRoots, d}.toList();
                      context.read<Library>().refresh();
                    }
                  },
                ),
              ),
              if (s.hiddenSongs.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () {
                      s.set('hiddenSongs', null);
                      context.read<Library>().refresh();
                    },
                    child: Text('Show ${s.hiddenSongs.length} removed imported song(s) again'),
                  ),
                ),
              _PathField(label: 'ffmpeg (blank = auto-detect)', value: s.ffmpegPath, hint: AppPaths.ffmpeg() ?? 'not found: WAV/FLAC/MP3 export falls back to libsndfile', onChanged: (v) => s.set('ffmpegPath', v.trim().isEmpty ? null : v.trim())),
            ]),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Update check',
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Check for a newer version at startup'),
                subtitle: const Text('Off by default. The URL returns a version string ("0.2.0") or JSON {"version": "...", "url": "..."}.'),
                value: s.updateCheckOn,
                onChanged: (v) => s.set('updateCheck', v),
              ),
              _PathField(label: 'Version URL', value: s.updateUrl, hint: 'https://example.org/yue2-studio/version.json', onChanged: (v) => s.set('updateUrl', v.trim().isEmpty ? null : v.trim())),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  onPressed: s.updateUrl.isEmpty
                      ? null
                      : () async {
                          try {
                            final u = await checkForUpdate(s.updateUrl);
                            if (context.mounted) showSnack(context, u.newer ? 'Version ${u.latest} is available' : 'Up to date (latest ${u.latest})');
                          } catch (e) {
                            if (context.mounted) showSnack(context, 'Update check failed: $e', error: true);
                          }
                        },
                  child: const Text('Check now'),
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

class _PathField extends StatefulWidget {
  const _PathField({required this.label, required this.value, required this.hint, required this.onChanged, this.directory = false});

  final String label;
  final String value;
  final String hint;
  final bool directory;
  final ValueChanged<String> onChanged;

  @override
  State<_PathField> createState() => _PathFieldState();
}

class _PathFieldState extends State<_PathField> {
  late final _c = TextEditingController(text: widget.value);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: _c,
            decoration: InputDecoration(labelText: widget.label, hintText: widget.hint, border: const OutlineInputBorder(), isDense: true),
            onSubmitted: widget.onChanged,
            onTapOutside: (_) {
              if (_c.text != widget.value) widget.onChanged(_c.text);
            },
          ),
        ),
        if (widget.directory)
          IconButton(
            icon: const Icon(Icons.folder_open),
            onPressed: () async {
              final d = await getDirectoryPath();
              if (d != null) {
                _c.text = d;
                widget.onChanged(d);
              }
            },
          ),
      ]),
    );
  }
}
