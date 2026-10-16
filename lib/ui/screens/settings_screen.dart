import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_info.dart';
import '../../core/engine/sidecar_engine.dart';
import '../../core/library/library.dart';
import '../../core/paths.dart';
import '../../core/settings.dart';
import '../../core/studio.dart';
import '../../core/update_check.dart';
import '../../state/nav.dart';
import '../widgets/common.dart';
import 'about.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final studio = context.watch<Studio>();
    final s = context.watch<Settings>();
    final m = studio.model;
    final e = studio.engine;
    return ScreenFrame(
      title: 'Settings',
      child: ListView(padding: const EdgeInsets.all(16), children: [
        SectionCard(
          title: 'Model and engine',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            KeyValueTable([
              ('Model', m == null ? '–' : '${m.name} · ${m.licence.spdx}'),
              ('Weights', studio.variant?.name ?? '–'),
              ('Engine', studio.engineDescriptor?.label ?? '–'),
              ('Status', e?.statusText ?? 'Not set up'),
              ('Device', studio.hardware.description),
            ]),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              FilledButton.tonal(onPressed: () => context.read<AppNav>().openSetup(true), child: const Text('Model setup')),
              if (e is SidecarEngine)
                OutlinedButton(
                  onPressed: () async {
                    await e.process.restart();
                    await e.warmUp();
                  },
                  child: const Text('Restart engine'),
                ),
            ]),
          ]),
        ),
        if (!Platform.isAndroid) ...[
          const SizedBox(height: 12),
          SectionCard(
            title: 'Library',
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SelectableText(AppPaths.instance.libraryDir),
              for (final r in s.importRoots)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
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
                  label: const Text('Add a folder (read-only)'),
                  onPressed: () async {
                    final d = await getDirectoryPath();
                    if (d != null && context.mounted) {
                      s.importRoots = {...s.importRoots, d}.toList();
                      context.read<Library>().refresh();
                    }
                  },
                ),
              ),
            ]),
          ),
        ],
        const SizedBox(height: 12),
        SectionCard(
          title: 'Updates',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Check at startup'),
              value: s.updateCheckOn,
              onChanged: (v) => s.set('updateCheck', v),
            ),
            _UrlField(initial: s.updateUrl, onChanged: (v) => s.set('updateUrl', v.trim())),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: s.updateUrl.isEmpty
                    ? null
                    : () async {
                        try {
                          final u = await checkForUpdate(s.updateUrl);
                          if (context.mounted) showSnack(context, u.newer ? 'Version ${u.latest} is available' : 'Up to date');
                        } catch (err) {
                          if (context.mounted) showSnack(context, 'Update check failed: $err', error: true);
                        }
                      },
                child: const Text('Check now'),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Image.asset('assets/icon-512.png', width: 32, height: 32),
          title: const Text(appName),
          subtitle: const Text('Version $appVersion ($appBuild)'),
          onTap: () => showAboutStudio(context),
        ),
      ]),
    );
  }
}

class _UrlField extends StatefulWidget {
  const _UrlField({required this.initial, required this.onChanged});
  final String initial;
  final ValueChanged<String> onChanged;

  @override
  State<_UrlField> createState() => _UrlFieldState();
}

class _UrlFieldState extends State<_UrlField> {
  late final _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: _c,
        decoration: const InputDecoration(labelText: 'Version URL', hintText: 'https://…/version.json', border: OutlineInputBorder(), isDense: true),
        onSubmitted: widget.onChanged,
        onTapOutside: (_) {
          if (_c.text != widget.initial) widget.onChanged(_c.text);
        },
      );
}
