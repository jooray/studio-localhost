import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/library/song.dart';
import '../../core/paths.dart';
import '../../core/player.dart';
import '../../state/library_view.dart';
import '../../state/nav.dart';
import '../../state/seeds.dart';
import '../layout.dart';
import '../widgets/common.dart';

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final v = context.watch<LibraryView>();
    final nav = context.watch<AppNav>();
    final songs = v.songs;
    final twoPane = windowSizeOf(context) != WindowSize.compact;
    final selected = v.library.byId(nav.selectedSongId) ?? (twoPane && songs.isNotEmpty ? songs.first : null);
    final list = Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        child: TextField(
          decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Filter', isDense: true, border: OutlineInputBorder()),
          onChanged: v.setFilter,
        ),
      ),
      Expanded(
        child: songs.isEmpty
            ? const Center(child: Text('No songs yet'))
            : ListView.builder(
                itemCount: songs.length,
                itemBuilder: (_, i) => SongTile(
                  songs[i],
                  selected: twoPane && songs[i].id == selected?.id,
                  onTap: () {
                    nav.select(songs[i].id);
                    if (!twoPane) {
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => Scaffold(appBar: AppBar(), body: SongDetails(songs[i].id, popOnDelete: true)),
                      ));
                    }
                  },
                ),
              ),
      ),
    ]);
    return ScreenFrame(
      title: 'Library',
      actions: [IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: v.library.refresh)],
      child: twoPane
          ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(width: windowSizeOf(context) == WindowSize.expanded ? 380 : 300, child: list),
              const VerticalDivider(width: 1),
              Expanded(child: selected == null ? const SizedBox.shrink() : SongDetails(selected.id, key: ValueKey(selected.id))),
            ])
          : list,
    );
  }
}

class SongTile extends StatelessWidget {
  const SongTile(this.song, {super.key, required this.selected, required this.onTap});

  final Song song;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pl = context.watch<AudioPlayerModel>();
    final v = context.read<LibraryView>();
    final cs = Theme.of(context).colorScheme;
    final playing = song.audioPath != null && pl.path == song.audioPath && pl.playing;
    final sub = song.status == SongStatus.done
        ? '${formatDuration(song.seconds)} · ${song.kind} · ${_date(song.created)}'
        : '${song.status.name} · ${_date(song.created)}';
    return ListTile(
      selected: selected,
      selectedTileColor: cs.secondaryContainer.withValues(alpha: 0.5),
      onTap: onTap,
      leading: IconButton(
        icon: Icon(playing ? Icons.pause_circle : Icons.play_circle),
        color: cs.primary,
        iconSize: 30,
        onPressed: song.hasAudio ? () => v.toggle(song) : null,
      ),
      title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: song.readOnly ? const Icon(Icons.lock_outline, size: 16) : null,
    );
  }
}

String _date(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

class SongDetails extends StatelessWidget {
  const SongDetails(this.songId, {super.key, this.popOnDelete = false});

  final String songId;
  final bool popOnDelete;

  @override
  Widget build(BuildContext context) {
    final v = context.watch<LibraryView>();
    final song = v.library.byId(songId);
    if (song == null) return const SizedBox.shrink();
    final pl = context.watch<AudioPlayerModel>();
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final playing = song.audioPath != null && pl.path == song.audioPath && pl.playing;
    final stages = Map<String, dynamic>.from(song.timing['stages'] as Map? ?? {});
    final section = song.section;
    return ListView(padding: const EdgeInsets.all(20), children: [
      Row(children: [
        Expanded(child: Text(song.title, style: t.headlineSmall)),
        if (!song.readOnly) IconButton(tooltip: 'Rename', icon: const Icon(Icons.edit_outlined), onPressed: () => _rename(context, v, song)),
      ]),
      Text(v.modelLine(song), style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
      const SizedBox(height: 12),
      if (song.status != SongStatus.done)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text('${song.status.name}${song.error != null ? ': ${song.error}' : ''}', style: t.bodyMedium?.copyWith(color: song.status == SongStatus.failed ? cs.error : null)),
        ),
      if (song.truncationWarning)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(song.truncated['abc'] == true ? 'The score was cut off; the song may follow an incomplete plan.' : 'The song hit the length cap without an ending.',
              style: t.bodyMedium?.copyWith(color: Colors.orange)),
        ),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (song.hasAudio)
          FilledButton.icon(icon: Icon(playing ? Icons.pause : Icons.play_arrow), label: Text(playing ? 'Pause' : 'Play'), onPressed: () => v.toggle(song)),
        if (song.renderPath != null)
          OutlinedButton(onPressed: () => pl.play(song.renderPath!, title: '${song.title} (render)'), child: const Text('Play render')),
        if (song.hasAudio) _ExportButton(song),
        if (v.canRerender(song)) OutlinedButton(onPressed: () => _rerender(context, v, song), child: const Text('Re-render')),
        if (v.canExtend(song)) OutlinedButton(onPressed: () => context.read<AppNav>().extend(song), child: const Text('Extend')),
        if (song.resumable) FilledButton.tonal(onPressed: () => v.resume(song), child: const Text('Resume')),
        if (song.active) OutlinedButton(onPressed: () => v.cancel(song), child: const Text('Cancel')),
        if (Platform.isMacOS || Platform.isLinux)
          IconButton(tooltip: 'Show in folder', icon: const Icon(Icons.folder_open), onPressed: () => AppPaths.reveal(song.audioPath ?? song.dir)),
        if (!song.active)
          IconButton(tooltip: song.readOnly ? 'Remove' : 'Delete', icon: Icon(Icons.delete_outline, color: cs.error), onPressed: () => _delete(context, v, song)),
      ]),
      const SizedBox(height: 16),
      SectionCard(
        child: KeyValueTable([
          if (song.seconds > 0) ('Length', formatDuration(song.seconds)),
          ('Created', _date(song.created)),
          if (song.mode.isNotEmpty) ('Planning', song.mode),
          ('Seed', '${song.seed ?? '–'}'),
          ('Steps', '${song.steps ?? '–'}'),
          if (song.precision != null) ('Precision', song.precision!),
          if (song.model['variant'] != null) ('Weights', '${song.model['variant']}'),
          if (song.engineId != null) ('Engine', song.engineId!),
          ('Style', song.style),
          if (section != null)
            ('Extended from', '${(section['start_seconds'] as num? ?? 0).toStringAsFixed(1)} s, +${((section['new_frames'] as num? ?? 0) / 25).toStringAsFixed(1)} s new'),
          if (song.timing['total_seconds'] is num) ('Time', formatDuration(song.timing['total_seconds'] as num)),
          if (stages.isNotEmpty) ('Stages', stages.entries.map((e) => '${stageName(e.key)} ${(e.value as num).toStringAsFixed(1)} s').join(' · ')),
        ]),
      ),
      if (song.lyrics.trim().isNotEmpty) ...[
        const SizedBox(height: 12),
        SectionCard(title: 'Lyrics', child: SelectableText(song.lyrics, style: const TextStyle(fontFamily: 'monospace', fontSize: 12))),
      ],
      if (song.abc != null) ...[
        const SizedBox(height: 12),
        SectionCard(
          title: 'Score',
          trailing: IconButton(icon: const Icon(Icons.copy, size: 18), onPressed: () => Clipboard.setData(ClipboardData(text: song.abc!))),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 280),
            child: SingleChildScrollView(child: SelectableText(song.abc!, style: const TextStyle(fontFamily: 'monospace', fontSize: 12))),
          ),
        ),
      ],
    ]);
  }

  Future<void> _rename(BuildContext context, LibraryView v, Song song) async {
    final c = TextEditingController(text: song.title);
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(controller: c, autofocus: true, onSubmitted: (x) => Navigator.pop(ctx, x)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save')),
        ],
      ),
    );
    if (r != null && r.trim().isNotEmpty) await v.rename(song, r.trim());
  }

  Future<void> _rerender(BuildContext context, LibraryView v, Song song) async {
    final seed = TextEditingController(text: '${randomSeed()}');
    final choices = v.studio.model?.limits.steps ?? const [32];
    var steps = song.steps == choices.last ? choices.first : choices.last;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Re-render'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: TextField(controller: seed, decoration: const InputDecoration(labelText: 'Seed', border: OutlineInputBorder()))),
              IconButton(icon: const Icon(Icons.casino_outlined), onPressed: () => seed.text = '${randomSeed()}'),
            ]),
            const SizedBox(height: 12),
            SegmentedButton<int>(
              segments: [for (final s in choices) ButtonSegment(value: s, label: Text('$s steps'))],
              selected: {steps},
              onSelectionChanged: (s) => setS(() => steps = s.first),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Re-render')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await v.rerender(song, steps: steps, seed: int.tryParse(seed.text) ?? randomSeed());
    if (context.mounted) showSnack(context, 'Re-render queued');
  }

  Future<void> _delete(BuildContext context, LibraryView v, Song song) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(song.readOnly ? 'Remove from library?' : 'Delete song?'),
        content: Text(song.title),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(song.readOnly ? 'Remove' : 'Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await v.delete(song);
    if (popOnDelete && context.mounted) Navigator.of(context).maybePop();
  }
}

class _ExportButton extends StatelessWidget {
  const _ExportButton(this.song);
  final Song song;

  @override
  Widget build(BuildContext context) {
    final v = context.read<LibraryView>();
    final ex = v.exporter;
    return MenuAnchor(
      builder: (_, c, _) => OutlinedButton.icon(
        icon: Icon(Platform.isAndroid ? Icons.share : Icons.ios_share),
        label: Text(Platform.isAndroid ? 'Share' : 'Export'),
        onPressed: () => c.isOpen ? c.close() : c.open(),
      ),
      menuChildren: [
        for (final f in ex.formats)
          MenuItemButton(
            child: Text(f.toUpperCase()),
            onPressed: () async {
              try {
                if (Platform.isAndroid) {
                  await ex.share(song, fmt: f);
                } else {
                  final loc = await getSaveLocation(
                      suggestedName: ex.suggestedName(song, f), acceptedTypeGroups: [XTypeGroup(label: f.toUpperCase(), extensions: [f])]);
                  if (loc == null) return;
                  await ex.exportTo(song, f, loc.path);
                  if (context.mounted) showSnack(context, 'Exported');
                }
              } catch (e) {
                if (context.mounted) showSnack(context, 'Failed: $e', error: true);
              }
            },
          ),
      ],
    );
  }
}
