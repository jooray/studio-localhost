import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/jobs.dart';
import '../core/paths.dart';
import '../core/player.dart';

/// Shared navigation state (page index plus hand-offs between pages).
class AppNav extends ChangeNotifier {
  /// YUE2_STUDIO_PAGE=0..4 picks the start page (handy for screenshots).
  int index = (int.tryParse(Platform.environment['YUE2_STUDIO_PAGE'] ?? '') ?? 0).clamp(0, 4);
  String? extendSourceDir;

  void go(int i) {
    index = i;
    notifyListeners();
  }

  void extend(String dir) {
    extendSourceDir = dir;
    go(2);
  }
}

class PageScaffold extends StatelessWidget {
  const PageScaffold({super.key, required this.title, this.subtitle, this.actions = const [], required this.child});

  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 18, 16, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
                    if (subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(subtitle!, style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                      ),
                  ],
                ),
              ),
              ...actions,
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: child),
      ],
    );
  }
}

class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: cs.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: cs.outlineVariant)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(child: Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600))),
              ?trailing,
            ]),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class KeyValueTable extends StatelessWidget {
  const KeyValueTable(this.rows, {super.key});

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (k, v) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 150, child: Text(k, style: t.bodySmall?.copyWith(color: muted))),
                Expanded(child: SelectableText(v, style: t.bodySmall)),
              ],
            ),
          ),
      ],
    );
  }
}

class Badge2 extends StatelessWidget {
  const Badge2(this.text, {super.key, this.color, this.icon});

  final String text;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.secondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 12, color: c), const SizedBox(width: 3)],
        Text(text, style: TextStyle(fontSize: 11, color: c, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

String stageName(String stage) => switch (stage) {
      'load' => 'Loading',
      'plan' => 'Score (ABC)',
      'semantic' => 'Semantic tokens (AR)',
      'nar' => 'Flow matching (NAR)',
      'vae' => 'VAE decode',
      'post' => 'Saving',
      _ => stage.isEmpty ? 'Waiting' : stage,
    };

class JobTile extends StatelessWidget {
  const JobTile(this.job, {super.key, this.dense = false});

  final Job job;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final q = context.read<JobQueue>();
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final icon = switch (job.status) {
      JobStatus.queued => Icons.schedule,
      JobStatus.running => Icons.graphic_eq,
      JobStatus.done => Icons.check_circle,
      JobStatus.failed => Icons.error,
      JobStatus.cancelled => Icons.cancel,
    };
    final color = switch (job.status) {
      JobStatus.done => Colors.green,
      JobStatus.failed => cs.error,
      JobStatus.running => cs.primary,
      _ => cs.onSurfaceVariant,
    };
    final progress = job.status == JobStatus.running
        ? '${stageName(job.stage)}${job.done != null && job.total != null ? ' · ${job.done}/${job.total} ${job.unit ?? ''}' : ''}'
        : job.status == JobStatus.queued
            ? 'Queued · ${job.kind}'
            : '${job.label} · ${formatDuration(job.elapsed.inSeconds)}';
    return Padding(
      padding: EdgeInsets.symmetric(vertical: dense ? 4 : 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(job.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                Text(progress, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ]),
            ),
            if (job.status == JobStatus.running) ...[
              Text(
                'elapsed ${formatDuration(job.elapsed.inSeconds)}'
                '${job.eta != null ? ' · ETA ${job.etaUpperBound ? '≤ ' : '~'}${formatDuration(job.eta!.inSeconds)}' : ''}',
                style: t.bodySmall,
              ),
              const SizedBox(width: 6),
              IconButton(tooltip: 'Cancel', icon: const Icon(Icons.stop_circle_outlined), onPressed: () => q.cancel(job)),
            ],
            if (job.status == JobStatus.queued) ...[
              IconButton(tooltip: 'Move up', icon: const Icon(Icons.arrow_upward, size: 18), onPressed: () => q.moveUp(job)),
              IconButton(tooltip: 'Remove from queue', icon: const Icon(Icons.close, size: 18), onPressed: () => q.remove(job)),
            ],
            if (!job.active && !dense)
              IconButton(tooltip: 'Dismiss', icon: const Icon(Icons.close, size: 18), onPressed: () => q.remove(job)),
          ]),
          if (job.status == JobStatus.running)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 26),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(value: job.fraction, minHeight: 5),
              ),
            ),
          if (job.error != null && job.status == JobStatus.failed)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 26),
              child: SelectableText(job.error!, maxLines: 6, style: t.bodySmall?.copyWith(color: cs.error)),
            ),
        ],
      ),
    );
  }
}

/// Bottom strip: the running job (if any) and how many wait behind it.
class JobStrip extends StatelessWidget {
  const JobStrip({super.key});

  @override
  Widget build(BuildContext context) {
    final q = context.watch<JobQueue>();
    final r = q.running;
    if (r == null && q.queued.isEmpty) return const SizedBox.shrink();
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        child: Row(children: [
          Expanded(child: r != null ? JobTile(r, dense: true) : const Text('Waiting for the engine…')),
          if (q.queued.isNotEmpty) Padding(padding: const EdgeInsets.only(left: 12), child: Badge2('${q.queued.length} queued')),
        ]),
      ),
    );
  }
}

class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context) {
    final pl = context.watch<AudioPlayerModel>();
    if (pl.path == null) return const SizedBox.shrink();
    final total = pl.duration.inMilliseconds.toDouble();
    final pos = pl.position.inMilliseconds.clamp(0, total > 0 ? total : 0).toDouble();
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(children: [
          IconButton.filledTonal(
            icon: Icon(pl.playing ? Icons.pause : Icons.play_arrow),
            onPressed: () => pl.toggle(pl.path!, title: pl.title),
          ),
          const SizedBox(width: 8),
          SizedBox(width: 220, child: Text(pl.title ?? '', maxLines: 1, overflow: TextOverflow.ellipsis)),
          Text(formatDuration(pl.position.inSeconds), style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
          Expanded(
            child: Slider(
              value: total > 0 ? pos : 0,
              max: total > 0 ? total : 1,
              onChanged: total > 0 ? (v) => pl.seek(Duration(milliseconds: v.round())) : null,
            ),
          ),
          Text(formatDuration(pl.duration.inSeconds), style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
          if (pl.error != null) Padding(padding: const EdgeInsets.only(left: 8), child: Tooltip(message: pl.error!, child: Icon(Icons.warning, color: cs.error))),
        ]),
      ),
    );
  }
}

void showSnack(BuildContext context, String text, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(text),
    backgroundColor: error ? Theme.of(context).colorScheme.error : null,
    behavior: SnackBarBehavior.floating,
    width: 560,
  ));
}
