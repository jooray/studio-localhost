import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_info.dart';
import '../../core/paths.dart';
import '../../core/setup/model_setup.dart';
import '../../core/studio.dart';
import '../../state/nav.dart';
import '../widgets/common.dart';

/// The one place that explains the model: licence, sizes, engine and expected speed.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
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
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final m = studio.model;
    final e = studio.engineDescriptor;
    final f = studio.format;
    final v = studio.variant;
    final accepted = studio.licenceAccepted;
    final st = setup.status;
    final canClose = studio.settings.setupComplete && !studio.needsSetup;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(padding: const EdgeInsets.all(20), children: [
              Row(children: [
                Image.asset('assets/icon-macos-1024.png', width: 48, height: 48),
                const SizedBox(width: 12),
                Expanded(child: Text(appName, style: t.titleLarge)),
                if (canClose) IconButton(icon: const Icon(Icons.close), onPressed: () => nav.openSetup(false)),
              ]),
              const SizedBox(height: 16),
              if (m == null || e == null || f == null || v == null)
                Text('No engine for this device: ${studio.hardware.description}', style: t.bodyLarge)
              else ...[
                SectionCard(
                  title: 'Model',
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (studio.registry.models.length > 1)
                      DropdownButton<String>(
                        value: m.id,
                        isExpanded: true,
                        items: [for (final x in studio.registry.models) DropdownMenuItem(value: x.id, child: Text(x.name))],
                        onChanged: setup.running ? null : (id) => studio.selectModel(id!),
                      )
                    else
                      Text(m.name, style: t.titleMedium),
                    Text('${m.summary} ${m.by.isNotEmpty ? 'By ${m.by}.' : ''}', style: t.bodySmall),
                  ]),
                ),
                const SizedBox(height: 12),
                SectionCard(
                  title: 'Licence',
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text('${m.licence.name} (${m.licence.spdx})', style: t.bodyMedium),
                    Text(m.licence.summary, style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                    if (f.licenceNote != null) Text(f.licenceNote!, style: t.bodySmall),
                    SelectableText(m.licence.url, style: t.bodySmall?.copyWith(color: cs.primary)),
                    Text('This app is free software ($appLicence). The model has its own licence.', style: t.bodySmall),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: accepted,
                      onChanged: accepted ? null : (_) => setup.acceptLicence(),
                      title: const Text('I accept the model licence'),
                    ),
                  ]),
                ),
                const SizedBox(height: 12),
                SectionCard(
                  title: 'Engine',
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (studio.availableEngines.length > 1)
                      DropdownButton<String>(
                        value: e.id,
                        isExpanded: true,
                        items: [
                          for (final x in studio.availableEngines)
                            DropdownMenuItem(value: x.id, child: Text('${x.label}${x.id == studio.recommendedEngine?.id ? ' (recommended)' : ''}')),
                        ],
                        onChanged: setup.running
                            ? null
                            : (id) async {
                                await studio.selectEngineOverride(id == studio.recommendedEngine?.id ? '' : id!);
                                await setup.refresh();
                              },
                      )
                    else
                      Text(e.label, style: t.titleSmall),
                    Text(studio.hardware.description, style: t.bodySmall),
                    const SizedBox(height: 4),
                    Text(e.speedHint, style: t.bodySmall),
                    Text(e.background, style: t.bodySmall),
                  ]),
                ),
                const SizedBox(height: 12),
                SectionCard(
                  title: 'Weights',
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final x in f.variants)
                        ChoiceChip(
                          label: Text('${x.name} · ${formatBytes(x.bytes)}'),
                          selected: x.id == v.id,
                          onSelected: setup.running
                              ? null
                              : (_) async {
                                  studio.selectVariant(x.id);
                                  await setup.refresh();
                                },
                        ),
                    ]),
                    if (v.note.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(v.note, style: t.bodySmall)),
                    const SizedBox(height: 8),
                    Text(
                      st.ready
                          ? 'Installed'
                          : [
                              if (!st.runtimeInstalled) '${f.runtime['name'] ?? 'Engine'} will be installed',
                              if (st.missing.isNotEmpty) '${formatBytes(st.needBytes)} to download',
                              if (st.freeBytes != null) '${formatBytes(st.freeBytes!)} free',
                            ].join(' · '),
                      style: t.bodyMedium,
                    ),
                    if (!Platform.isAndroid && !st.ready)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: setup.running
                              ? null
                              : () async {
                                  final d = await getDirectoryPath();
                                  if (d != null) await setup.useExistingRuntime(d);
                                },
                          child: Text('Use an existing ${f.runtime['name'] ?? 'engine'} folder…'),
                        ),
                      ),
                  ]),
                ),
                const SizedBox(height: 16),
                if (setup.running) ...[
                  Text(setup.task ?? '', style: t.bodyMedium),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(value: setup.progress),
                  if (setup.progressText.isNotEmpty) Text(setup.progressText, style: t.bodySmall),
                  Align(alignment: Alignment.centerRight, child: TextButton(onPressed: setup.cancel, child: const Text('Pause'))),
                ] else if (st.ready)
                  FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    onPressed: accepted
                        ? () async {
                            await setup.complete();
                            nav.openSetup(false);
                          }
                        : null,
                    child: const Text('Start'),
                  )
                else
                  FilledButton(
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    onPressed: accepted ? setup.install : null,
                    child: Text(st.missing.isEmpty ? 'Install engine' : 'Download ${formatBytes(st.needBytes)}'),
                  ),
                if (setup.error != null) Padding(padding: const EdgeInsets.only(top: 8), child: SelectableText(setup.error!, style: TextStyle(color: cs.error))),
                if (setup.log.isNotEmpty && !Platform.isAndroid)
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Log'),
                    children: [
                      Container(
                        height: 200,
                        padding: const EdgeInsets.all(8),
                        color: Colors.black87,
                        child: ListView(reverse: true, children: [
                          for (final l in setup.log.reversed.take(300))
                            Text(l, style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.white70)),
                        ]),
                      ),
                    ],
                  ),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}
