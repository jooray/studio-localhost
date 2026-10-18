import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_info.dart';
import '../../core/paths.dart';
import '../../core/setup/model_setup.dart';
import '../../core/studio.dart';
import '../../state/nav.dart';
import '../theme.dart';
import '../widgets/sleeve.dart';
import 'studio_screen.dart' show shortError;

/// The one place that explains the model: licence, sizes, engine and expected speed. Shown on
/// first run and from Settings.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  bool _log = false;
  bool _engines = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.read<ModelSetup>().refresh());
  }

  @override
  Widget build(BuildContext context) {
    final studio = context.watch<Studio>();
    final setup = context.watch<ModelSetup>();
    final nav = context.read<AppNav>();
    final w = MediaQuery.sizeOf(context).width;
    final u = (w / 576).clamp(0.7, 1.0);
    final m = studio.model, e = studio.engineDescriptor, f = studio.format, v = studio.variant;
    final accepted = studio.licenceAccepted;
    final st = setup.status;
    final canClose = studio.settings.setupComplete && !studio.needsSetup;
    final side = 25 * u;

    Widget section(String label, List<Widget> children) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: w < 600 ? 96 * u : 130,
            child: Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Etched(label, size: 11, color: Sleeve.inkMute),
            ),
          ),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
          ),
        ],
      ),
    );
    final valueStyle = SleeveType.value(u, size: 15);
    final titleStyle = SleeveType.body(u).copyWith(fontSize: 18, height: 1.3, fontWeight: FontWeight.w400);
    final noteStyle = SleeveType.body(u, color: Sleeve.inkSoft).copyWith(fontSize: 14, height: 1.4);

    final List<Widget> body;
    if (m == null || e == null || f == null || v == null) {
      body = [
        const SizedBox(height: 24),
        ErrorLine('No engine runs on this device', detail: studio.hardware.description),
        const SizedBox(height: 8),
        Text(studio.hardware.description, style: noteStyle),
      ];
    } else {
      final primaryLabel = st.ready
          ? 'START'
          : (st.missing.isEmpty
                ? 'INSTALL ${(f.runtime['name'] ?? 'ENGINE').toString().toUpperCase()}'
                : (st.needBytes > 0 ? 'DOWNLOAD ${formatBytes(st.needBytes)}' : 'CHECK FILES'));
      final primaryEnabled = accepted && !setup.running;
      body = [
        section('Model', [
          if (studio.registry.models.length > 1)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final x in studio.registry.models)
                  Cell(
                    shrink: true,
                    selected: x.id == m.id,
                    frame: true,
                    onTap: setup.running ? null : () => studio.selectModel(x.id),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Text(x.name, style: valueStyle),
                  ),
              ],
            )
          else
            Text(m.name, style: titleStyle),
          const SizedBox(height: 6),
          Text('${m.summary}${m.by.isNotEmpty ? ' By ${m.by}.' : ''}', style: noteStyle),
        ]),
        const Rule(color: Sleeve.ruleFaint),
        section('Licence', [
          Text(m.licence.name, style: titleStyle),
          const SizedBox(height: 4),
          Text(m.licence.summary, style: noteStyle.copyWith(color: Sleeve.ink)),
          const SizedBox(height: 4),
          SelectableText(
            m.licence.url,
            style: noteStyle.copyWith(decoration: TextDecoration.underline, decorationColor: Sleeve.inkMute),
          ),
          const SizedBox(height: 10),
          Cell(
            frame: false,
            onTap: accepted ? null : setup.acceptLicence,
            alignment: Alignment.centerLeft,
            semanticLabel: 'I accept the model licence',
            child: Row(
              children: [
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    border: Border.all(color: Sleeve.ink, width: Sleeve.hair),
                  ),
                  child: accepted ? const GlyphIcon(Glyph.check, size: 20) : null,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text('I accept the model licence', style: noteStyle.copyWith(color: Sleeve.ink, fontSize: 15)),
                ),
              ],
            ),
          ),
        ]),
        const Rule(color: Sleeve.ruleFaint),
        section('Engine', [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(e.label, style: titleStyle)),
              if (studio.availableEngines.length > 1)
                Cell(
                  frame: false,
                  minHeight: 32,
                  onTap: setup.running ? null : () => setState(() => _engines = !_engines),
                  semanticLabel: 'Change engine',
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Etched(_engines ? 'done' : 'change', size: 11, color: Sleeve.inkSoft),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text('${studio.hardware.description} · ${e.speedHint}', style: noteStyle),
          if (_engines) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final x in studio.availableEngines)
                  Cell(
                    shrink: true,
                    selected: x.id == e.id,
                    frame: true,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    onTap: setup.running
                        ? null
                        : () async {
                            await studio.selectEngineOverride(x.id == studio.recommendedEngine?.id ? '' : x.id);
                            await setup.refresh();
                          },
                    child: Text(x.label, style: SleeveType.value(u, size: 13, color: x.id == e.id ? Sleeve.ink : Sleeve.inkMute)),
                  ),
              ],
            ),
          ],
        ]),
        const Rule(color: Sleeve.ruleFaint),
        section('Weights', [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final x in f.variants)
                Cell(
                  shrink: true,
                  selected: x.id == v.id,
                  frame: true,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  onTap: setup.running
                      ? null
                      : () async {
                          studio.selectVariant(x.id);
                          await setup.refresh();
                        },
                  child: Text(
                    '${x.name} · ${formatBytes(x.bytes)}',
                    style: SleeveType.value(u, size: 13, color: x.id == v.id ? Sleeve.ink : Sleeve.inkMute),
                  ),
                ),
            ],
          ),
          if (v.note.isNotEmpty) ...[const SizedBox(height: 6), Text(v.note, style: noteStyle)],
          const SizedBox(height: 10),
          Text(
            (st.ready
                    ? 'Installed'
                    : [
                        if (!st.runtimeInstalled) '${f.runtime['name'] ?? 'engine'} to install',
                        if (st.missing.isNotEmpty)
                          st.needBytes > 0 ? '${formatBytes(st.needBytes)} to download' : 'files to check',
                      ].join(' · ')) +
                (st.freeBytes != null ? ' · ${formatBytes(st.freeBytes!)} free' : ''),
            style: SleeveType.etched(u, size: 12, color: st.ready ? Sleeve.ink : Sleeve.inkSoft),
          ),
          if (!Platform.isAndroid && !st.ready) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: Cell(
                frame: false,
                minHeight: 44,
                onTap: setup.running
                    ? null
                    : () async {
                        final d = await getDirectoryPath();
                        if (d != null) await setup.useExistingRuntime(d);
                      },
                child: Etched('Use an existing ${f.runtime['name'] ?? 'engine'} folder…', size: 11, color: Sleeve.inkSoft),
              ),
            ),
          ],
        ]),
        const Rule(),
        const SizedBox(height: 18),
        if (setup.running) ...[
          Text((setup.task ?? '').toUpperCase(), style: SleeveType.etched(u, size: 12, color: Sleeve.ink)),
          const SizedBox(height: 10),
          _Bar(setup.progress),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(setup.progressText, maxLines: 2, style: SleeveType.value(u, size: 12, color: Sleeve.inkSoft)),
              ),
              Cell(
                onTap: setup.cancel,
                minHeight: 44,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Etched('Pause', size: 12, color: Sleeve.ink),
              ),
            ],
          ),
        ] else
          SizedBox(
            height: 56,
            child: Cell(
              block: primaryEnabled,
              onTap: primaryEnabled
                  ? () async {
                      if (st.ready) {
                        await setup.complete();
                        nav.openSetup(false);
                      } else {
                        await setup.install();
                      }
                    }
                  : null,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.only(left: 18),
              semanticLabel: primaryLabel,
              child: Text(
                primaryLabel,
                style: SleeveType.etched(u, size: 15, color: primaryEnabled ? Sleeve.ink : Sleeve.inkMute, weight: FontWeight.w500),
              ),
            ),
          ),
        if (!accepted && !setup.running) ...[
          const SizedBox(height: 8),
          Etched('Accept the licence to continue', size: 11, color: Sleeve.inkMute),
        ],
        if (setup.error != null) ...[
          const SizedBox(height: 14),
          ErrorLine(shortError(setup.error!), detail: setup.error, action: setup.running ? null : 'Retry', onAction: setup.install),
        ],
        if (setup.log.isNotEmpty && !Platform.isAndroid) ...[
          const SizedBox(height: 14),
          Cell(
            frame: false,
            minHeight: 44,
            alignment: Alignment.centerLeft,
            onTap: () => setState(() => _log = !_log),
            child: Row(
              children: [
                Etched('Log', size: 11, color: Sleeve.inkMute),
                const SizedBox(width: 8),
                GlyphIcon(_log ? Glyph.minus : Glyph.plus, size: 14, color: Sleeve.inkMute),
              ],
            ),
          ),
          if (_log)
            Container(
              height: 220,
              decoration: const BoxDecoration(border: Border.fromBorderSide(BorderSide(color: Sleeve.ruleFaint))),
              padding: const EdgeInsets.all(10),
              child: ListView(
                reverse: true,
                children: [
                  for (final l in setup.log.reversed.take(300)) Text(l, style: SleeveType.value(1, size: 11, color: Sleeve.inkSoft)),
                ],
              ),
            ),
        ],
      ];
    }

    final pad = MediaQuery.paddingOf(context);
    return Scaffold(
      body: SleeveScale(
        u: u,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: EdgeInsets.fromLTRB(side, pad.top + 12, side, pad.bottom + 32),
              children: [
                Row(
                  children: [
                    Image.asset('assets/brand/icon-master-1024.png', width: 52, height: 52, filterQuality: FilterQuality.medium),
                    const SizedBox(width: 16),
                    Expanded(child: Etched(appName, size: 13, color: Sleeve.ink, maxLines: 2)),
                    if (canClose) GlyphButton(Glyph.close, tooltip: 'Close', size: 20, onTap: () => nav.openSetup(false)),
                  ],
                ),
                const SizedBox(height: 16),
                const Rule(),
                ...body,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar(this.value);
  final double? value;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 10,
    child: Stack(
      alignment: Alignment.centerLeft,
      children: [
        const Rule(color: Sleeve.ruleFaint),
        if (value != null)
          FractionallySizedBox(
            widthFactor: value!.clamp(0.0, 1.0),
            child: Container(height: 3, color: Sleeve.ink),
          ),
        if (value == null) const LinearProgressIndicator(minHeight: 1),
      ],
    ),
  );
}
