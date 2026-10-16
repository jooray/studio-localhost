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
import '../frame.dart';
import '../routes.dart';
import '../theme.dart';
import '../widgets/sleeve.dart';
import 'studio_screen.dart' show shortError;

/// Settings and About: model and engine (with the setup flow), library folders, update check,
/// version. Short on purpose.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final studio = context.watch<Studio>();
    final s = context.watch<Settings>();
    final e = studio.engine;
    return SleevePage(
      title: 'Settings',
      maxWidth: 820,
      child: Builder(builder: (context) {
        final u = SleeveScale.of(context);
        Widget group(String label, List<Widget> children) => Padding(
              padding: EdgeInsets.fromLTRB(25 * u, 22, 25 * u, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Etched(label, size: 12, color: Sleeve.inkMute),
                const SizedBox(height: 6),
                const Rule(),
                ...children,
              ]),
            );
        Widget cell(String label, VoidCallback? onTap) => Cell(
              shrink: true,
              onTap: onTap,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Etched(label, size: 12, color: onTap == null ? Sleeve.inkMute : Sleeve.ink),
            );
        return ListView(padding: EdgeInsets.only(bottom: 32 + MediaQuery.paddingOf(context).bottom), children: [
          group('Model and engine', [
            DataList([
              ('Model', studio.model == null ? '–' : '${studio.model!.name} · ${studio.model!.licence.spdx}'),
              ('Weights', studio.variant?.name ?? '–'),
              ('Engine', studio.engineDescriptor?.label ?? '–'),
              ('Status', e?.statusText ?? 'not set up'),
              ('Device', studio.hardware.description),
            ]),
            if (e?.fault != null) ...[
              const SizedBox(height: 10),
              ErrorLine(shortError(e!.fault!), detail: e.fault, action: 'Setup', onAction: () => openSetup(context)),
            ],
            const SizedBox(height: 14),
            Wrap(spacing: 8, runSpacing: 8, children: [
              cell('Model setup', () => openSetup(context)),
              if (e is SidecarEngine)
                cell('Restart engine', () async {
                  await e.process.restart();
                  await e.warmUp();
                }),
            ]),
            if (studio.availableEngines.length > 1) ...[
              const SizedBox(height: 18),
              Etched('Engine override', size: 11, color: Sleeve.inkMute),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final x in studio.availableEngines)
                  Cell(
                    shrink: true,
                    selected: x.id == studio.engineDescriptor?.id,
                    frame: true,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    onTap: () => studio.selectEngineOverride(x.id == studio.recommendedEngine?.id ? '' : x.id),
                    child: Text(x.id == studio.recommendedEngine?.id ? '${x.label} · auto' : x.label,
                        style: SleeveType.value(u, size: 13, color: x.id == studio.engineDescriptor?.id ? Sleeve.ink : Sleeve.inkMute)),
                  ),
              ]),
            ],
          ]),
          if (!Platform.isAndroid)
            group('Library', [
              const SizedBox(height: 8),
              SelectableText(AppPaths.instance.libraryDir, style: SleeveType.value(u, size: 13, color: Sleeve.inkSoft)),
              const SizedBox(height: 8),
              for (final r in s.importRoots)
                Row(children: [
                  const GlyphIcon(Glyph.folder, size: 16, color: Sleeve.inkMute),
                  const SizedBox(width: 10),
                  Expanded(child: Text(r, maxLines: 1, overflow: TextOverflow.ellipsis, style: SleeveType.value(u, size: 13))),
                  GlyphButton(Glyph.close, tooltip: 'Stop importing', size: 16, onTap: () {
                    s.importRoots = s.importRoots.where((x) => x != r).toList();
                    context.read<Library>().refresh();
                  }),
                ]),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: cell('Import a folder (read-only)', () async {
                  final d = await getDirectoryPath();
                  if (d != null && context.mounted) {
                    s.importRoots = {...s.importRoots, d}.toList();
                    context.read<Library>().refresh();
                  }
                }),
              ),
            ]),
          group('Updates', [
            const SizedBox(height: 6),
            Cell(
              frame: false,
              alignment: Alignment.centerLeft,
              onTap: () => s.set('updateCheck', !s.updateCheckOn),
              semanticLabel: 'Check for a new version at start',
              child: Row(children: [
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(border: Border.all(color: Sleeve.ink, width: Sleeve.hair)),
                  child: s.updateCheckOn ? const GlyphIcon(Glyph.check, size: 20) : null,
                ),
                const SizedBox(width: 14),
                Etched('Check at start', size: 12, color: Sleeve.ink),
              ]),
            ),
            const SizedBox(height: 6),
            _UrlField(initial: s.updateUrl, onChanged: (v) => s.set('updateUrl', v.trim())),
            const Rule(color: Sleeve.ruleFaint),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: cell(
                'Check now',
                s.updateUrl.isEmpty
                    ? null
                    : () async {
                        try {
                          final up = await checkForUpdate(s.updateUrl);
                          if (context.mounted) showLine(context, up.newer ? 'Version ${up.latest} is out${up.url != null ? ' · ${up.url}' : ''}' : 'Up to date');
                        } catch (err) {
                          if (context.mounted) showLine(context, 'Update check failed: ${shortError(err)}', error: true);
                        }
                      },
              ),
            ),
          ]),
          group('About', [
            const SizedBox(height: 14),
            Row(children: [
              Image.asset('assets/brand/icon-master-1024.png', width: 56, height: 56, filterQuality: FilterQuality.medium),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Etched(appName, size: 12, color: Sleeve.ink, maxLines: 2),
                  const SizedBox(height: 6),
                  Text('$appVersion ($appBuild) · $appLicence', style: SleeveType.value(u, size: 13, color: Sleeve.inkSoft)),
                  SelectableText(appSourceUrl, style: SleeveType.value(u, size: 12, color: Sleeve.inkMute)),
                ]),
              ),
            ]),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerLeft,
              child: cell('Licences', () => showLicensePage(context: context, applicationName: appName, applicationVersion: appVersion)),
            ),
          ]),
        ]);
      }),
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
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _c.text != widget.initial) widget.onChanged(_c.text);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(children: [
          const SizedBox(width: 110, child: Etched('Version URL', size: 11, color: Sleeve.inkMute)),
          Expanded(
            child: SleeveField(
              controller: _c,
              focusNode: _focus,
              style: SleeveType.value(SleeveScale.of(context), size: 14),
              maxLines: 1,
              hint: 'https://…/version.json',
              semanticLabel: 'Version URL',
              onChanged: (_) {},
            ),
          ),
        ]),
      );
}
