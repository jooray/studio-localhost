import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/jobs.dart';
import '../core/paths.dart';
import '../core/settings.dart';
import '../core/setup.dart';
import '../core/sidecar.dart';
import 'widgets.dart';

class ModelsPage extends StatefulWidget {
  const ModelsPage({super.key});

  @override
  State<ModelsPage> createState() => _ModelsPageState();
}

class _ModelsPageState extends State<ModelsPage> {
  Map<String, dynamic>? _doctor;
  bool _doctorRunning = false;
  int? _free;
  String? _infoError;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final settings = context.read<Settings>();
    final sc = context.read<Sidecar>();
    final queue = context.read<JobQueue>();
    final free = await AppPaths.freeBytes(settings.backend == 'mlx' ? settings.mlxEngineDir : AppPaths.instance.dataDir);
    if (mounted) setState(() => _free = free);
    try {
      await sc.ensureStarted();
      if (sc.configuredBackend != settings.backend && queue.running == null) await sc.configure();
      await sc.refreshInfo();
      if (mounted) setState(() => _infoError = null);
    } catch (e) {
      if (mounted) setState(() => _infoError = e.toString());
    }
  }

  Future<void> _runDoctor() async {
    setState(() => _doctorRunning = true);
    try {
      final sc = context.read<Sidecar>();
      await sc.ensureStarted();
      final r = await sc.request('doctor');
      if (mounted) setState(() => _doctor = r);
    } catch (e) {
      if (mounted) setState(() => _doctor = {'status': 'error', 'error': e.toString()});
    } finally {
      if (mounted) setState(() => _doctorRunning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<Settings>();
    final sc = context.watch<Sidecar>();
    final setup = context.watch<EngineSetup>();
    final info = sc.info;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final venvOk = info?['venv_ok'] == true;
    final weights = (info?['weights'] as List?)?.cast<Map>() ?? const [];
    return PageScaffold(
      title: 'Models & Engine',
      subtitle: 'Backend: ${settings.backend}${settings.backendOverride.isEmpty ? ' (automatic for this platform)' : ' (set in Settings)'}',
      actions: [
        IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _refresh),
      ],
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          SectionCard(
            title: 'Status',
            trailing: _statusChip(sc, venvOk),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              KeyValueTable([
                ('Backend', settings.backend),
                if (settings.backend == 'mlx') ('Engine path', settings.mlxEngineDir),
                if (settings.backend == 'mlx') ('Model dir', settings.mlxModelDir),
                if (settings.backend == 'mlx') ('VAE dir', settings.mlxVaeDir),
                if (settings.backend == 'yue2cpp') ('yue2.cpp binaries', settings.yue2cppBinDir),
                if (settings.backend == 'yue2cpp') ('Backbone GGUF', settings.ggufModel),
                if (settings.backend == 'yue2cpp') ('VAE GGUF', settings.ggufVae),
                ('Sidecar Python', settings.sidecarPython),
                ('Python env', info == null ? (sc.error ?? 'not started') : (venvOk ? 'OK' : 'broken: ${info['venv_error'] ?? 'yue-synth missing'}')),
                if (info?['versions'] is Map) ('Versions', (info!['versions'] as Map).entries.map((e) => '${e.key} ${e.value}').join(', ')),
                if (info?['yue_synth'] != null) ('yue-synth', '${info!['yue_synth']}'),
                ('Pipeline resident', info?['resident'] == true ? 'yes (weights stay loaded between jobs)' : 'no'),
                ('Free disk', _free == null ? '…' : formatBytes(_free!)),
                ('App data', AppPaths.instance.dataDir),
              ]),
              if (_infoError != null) Padding(padding: const EdgeInsets.only(top: 8), child: SelectableText(_infoError!, style: TextStyle(color: cs.error))),
              const SizedBox(height: 10),
              Wrap(spacing: 8, children: [
                OutlinedButton.icon(
                  icon: _doctorRunning ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.health_and_safety_outlined),
                  label: Text(settings.backend == 'mlx' ? 'Run mlx-yue doctor' : 'Check engine'),
                  onPressed: _doctorRunning || context.watch<JobQueue>().running != null ? null : _runDoctor,
                ),
                OutlinedButton.icon(icon: const Icon(Icons.restart_alt), label: const Text('Restart engine'), onPressed: () async {
                  await sc.restart();
                  _refresh();
                }),
                OutlinedButton.icon(icon: const Icon(Icons.memory), label: const Text('Unload models'), onPressed: () => sc.request('unload')),
              ]),
              if (_doctor != null) ...[const SizedBox(height: 10), _DoctorSummary(_doctor!)],
            ]),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Weights',
            child: weights.isEmpty
                ? Text('Start the engine to inspect the weights.', style: t.bodySmall)
                : Column(children: [
                    for (final w in weights)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(w['present'] == true ? Icons.check_circle : Icons.radio_button_unchecked,
                            color: w['present'] == true ? Colors.green : cs.onSurfaceVariant),
                        title: Text('${w['name']}'),
                        subtitle: Text('${w['path']}', maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: Text(w['present'] == true ? formatBytes(w['bytes'] as num) : 'missing'),
                      ),
                  ]),
          ),
          const SizedBox(height: 12),
          _SetupCard(setup: setup, settings: settings),
          const SizedBox(height: 12),
          SectionCard(
            title: 'License',
            child: Text(
              'YuE2 model weights (m-a-p/YuE2-3B, YuE2-Vae and the converted MLX / GGUF files) are licensed '
              'CC BY-NC 4.0: non-commercial use only, with attribution to M-A-P. Songs you generate inherit '
              'that restriction. mlx-Yue (vanch007) is Apache-2.0; yue2.cpp (ServeurpersoCom) is MIT.',
              style: t.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusChip(Sidecar sc, bool venvOk) {
    final (text, color) = switch (sc.state) {
      SidecarState.ready => venvOk ? ('Ready', Colors.green) : ('Engine incomplete', Colors.orange),
      SidecarState.starting => ('Starting', Colors.blueGrey),
      SidecarState.failed => ('Failed', Colors.red),
      SidecarState.stopped => ('Stopped', Colors.blueGrey),
    };
    return Badge2(text, color: color);
  }
}

class _DoctorSummary extends StatelessWidget {
  const _DoctorSummary(this.r);

  final Map<String, dynamic> r;

  @override
  Widget build(BuildContext context) {
    final checks = r['checks'] is Map ? Map<String, dynamic>.from(r['checks'] as Map) : <String, dynamic>{};
    final pass = r['status'] == 'pass';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: (pass ? Colors.green : Colors.orange).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Doctor: ${r['status']}', style: const TextStyle(fontWeight: FontWeight.w600)),
        if (checks.isNotEmpty) Text(checks.entries.map((e) => '${e.key}: ${e.value == true ? 'ok' : 'FAIL'}').join(' · ')),
        if (r['platform'] != null) Text('${r['platform']}'),
        if (r['memory_gib'] is num) Text('Memory: ${(r['memory_gib'] as num).toStringAsFixed(0)} GiB'),
        if (r['error'] != null || r['stderr'] != null) SelectableText('${r['error'] ?? r['stderr']}'),
      ]),
    );
  }
}

class _SetupCard extends StatefulWidget {
  const _SetupCard({required this.setup, required this.settings});

  final EngineSetup setup;
  final Settings settings;

  @override
  State<_SetupCard> createState() => _SetupCardState();
}

class _SetupCardState extends State<_SetupCard> {
  String _quant = 'Q8_0';
  bool _weights = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.setup;
    final t = Theme.of(context).textTheme;
    final busy = s.running;
    return SectionCard(
      title: 'Set up engine',
      trailing: busy ? TextButton(onPressed: s.cancel, child: const Text('Stop')) : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(
          'Everything is installed under ${AppPaths.instance.engineDir} with uv-managed virtual environments; '
          'nothing is installed system-wide. Downloads check free disk first and keep 6 GB free.',
          style: t.bodySmall,
        ),
        const SizedBox(height: 10),
        Text('uv: ${s.uv ?? 'not found'} · git: ${s.git ?? 'not found'}', style: t.bodySmall),
        const SizedBox(height: 12),
        if (Platform.isMacOS) ...[
          Text('mlx (Apple Silicon)', style: t.titleSmall),
          const SizedBox(height: 6),
          Row(children: [
            FilledButton.tonalIcon(
              icon: const Icon(Icons.download),
              label: const Text('Install mlx-Yue engine'),
              onPressed: busy ? null : () => s.setupMlx(downloadWeights: _weights),
            ),
            const SizedBox(width: 12),
            Checkbox(value: _weights, onChanged: busy ? null : (v) => setState(() => _weights = v ?? false)),
            const Flexible(child: Text('also download the MLX weights (8bit AR + NAR + VAE, ≈ 8 GB)')),
          ]),
          Text('git clone vanch007/mlx-Yue (pinned) + uv sync --frozen --no-dev', style: t.bodySmall),
          const SizedBox(height: 16),
        ],
        Text('yue2.cpp (${Platform.isMacOS ? 'Metal' : 'CUDA › Vulkan › CPU, auto-detected: ${EngineSetup.buildScript()}'})', style: t.titleSmall),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          FilledButton.tonalIcon(icon: const Icon(Icons.build), label: const Text('Build yue2.cpp'), onPressed: busy ? null : s.setupYue2cpp),
          FilledButton.tonalIcon(icon: const Icon(Icons.terminal), label: const Text('Create sidecar venv'), onPressed: busy ? null : s.setupSidecarVenv),
          DropdownButton<String>(
            value: _quant,
            items: [
              for (final q in ['Q8_0', 'Q6_K'])
                DropdownMenuItem(value: q, child: Text('$q (${formatBytes(ggufCatalog[q]!.size)}) + VAE F32')),
            ],
            onChanged: busy ? null : (v) => setState(() => _quant = v ?? 'Q8_0'),
          ),
          FilledButton.tonalIcon(icon: const Icon(Icons.cloud_download), label: const Text('Download GGUFs'), onPressed: busy ? null : () => s.downloadGguf(_quant)),
        ]),
        if (busy || s.log.isNotEmpty) ...[
          const SizedBox(height: 12),
          if (busy) Row(children: [Expanded(child: LinearProgressIndicator(value: s.progress)), const SizedBox(width: 8), Text(s.task ?? '')]),
          const SizedBox(height: 8),
          Container(
            height: 220,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(8)),
            child: ListView(
              reverse: true,
              children: [
                for (final l in s.log.reversed.take(400))
                  Text(l, style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.white70)),
              ],
            ),
          ),
        ],
      ]),
    );
  }
}
