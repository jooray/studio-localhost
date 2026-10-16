import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/jobs/job_queue.dart';
import '../../core/library/song.dart';
import '../../core/paths.dart';
import 'common.dart';

/// One song in the queue: running, waiting or just finished.
class JobTile extends StatelessWidget {
  const JobTile(this.song, {super.key, this.dense = false});

  final Song song;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final q = context.read<JobQueue>();
    final live = context.watch<JobQueue>().live[song.id];
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final st = song.status;
    final icon = switch (st) {
      SongStatus.queued => Icons.schedule,
      SongStatus.running => Icons.graphic_eq,
      SongStatus.done => Icons.check_circle,
      SongStatus.failed => Icons.error,
      SongStatus.cancelled || SongStatus.interrupted => Icons.pause_circle,
    };
    final color = switch (st) {
      SongStatus.done => Colors.green,
      SongStatus.failed => cs.error,
      SongStatus.running => cs.primary,
      _ => cs.onSurfaceVariant,
    };
    String line;
    if (st == SongStatus.running && live != null) {
      line = '${stageName(live.stage)}'
          '${live.done != null && live.total != null ? ' ${live.done}/${live.total}' : ''}'
          ' · ${formatDuration(live.elapsed.inSeconds)}'
          '${live.eta != null ? ' · ${live.etaUpperBound ? '≤' : '~'}${formatDuration(live.eta!.inSeconds)} left' : ''}';
    } else if (st == SongStatus.running) {
      line = 'Running';
    } else if (st == SongStatus.queued) {
      line = 'Queued';
    } else {
      final total = (song.timing['total_seconds'] as num?) ?? 0;
      line = '${st.name[0].toUpperCase()}${st.name.substring(1)}${total > 0 ? ' · ${formatDuration(total)}' : ''}';
    }
    return Padding(
      padding: EdgeInsets.symmetric(vertical: dense ? 2 : 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              Text(line, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            ]),
          ),
          if (st == SongStatus.running)
            IconButton(tooltip: 'Cancel', icon: const Icon(Icons.stop_circle_outlined), onPressed: () => q.cancel(song)),
          if (st == SongStatus.queued) ...[
            IconButton(tooltip: 'Move up', icon: const Icon(Icons.arrow_upward, size: 18), onPressed: () => q.moveUp(song)),
            IconButton(tooltip: 'Cancel', icon: const Icon(Icons.close, size: 18), onPressed: () => q.cancel(song)),
          ],
          if (song.resumable)
            IconButton(tooltip: 'Resume', icon: const Icon(Icons.play_arrow, size: 18), onPressed: () => q.resume(song)),
          if (!song.active && !dense)
            IconButton(tooltip: 'Dismiss', icon: const Icon(Icons.close, size: 18), onPressed: () => q.dismiss(song)),
        ]),
        if (st == SongStatus.running)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 26),
            child: LinearProgressIndicator(value: live?.fraction, minHeight: 4),
          ),
        if (song.error != null && st == SongStatus.failed && !dense)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 26),
            child: SelectableText(song.error!, maxLines: 4, style: t.bodySmall?.copyWith(color: cs.error)),
          ),
      ]),
    );
  }
}

/// The queue: running, waiting, and what finished in this session.
class QueuePanel extends StatelessWidget {
  const QueuePanel({super.key});

  @override
  Widget build(BuildContext context) {
    final q = context.watch<JobQueue>();
    final items = [?q.running, ...q.queued, ...q.recentSongs];
    if (items.isEmpty) return const SizedBox.shrink();
    return SectionCard(
      title: 'Queue',
      trailing: q.recent.isNotEmpty ? TextButton(onPressed: q.clearRecent, child: const Text('Clear')) : null,
      child: Column(children: [for (final s in items) JobTile(s, key: ValueKey(s.id))]),
    );
  }
}

/// Bottom strip with the running job, shown on every screen.
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        child: Row(children: [
          Expanded(child: r != null ? JobTile(r, dense: true) : Text('${q.queued.length} waiting')),
          if (r != null && q.queued.isNotEmpty) Text('+${q.queued.length}'),
        ]),
      ),
    );
  }
}
