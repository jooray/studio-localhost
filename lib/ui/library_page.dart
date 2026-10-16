import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../core/jobs.dart';
import '../core/library.dart';
import '../core/paths.dart';
import '../core/player.dart';
import '../core/settings.dart';
import '../core/sidecar.dart';
import 'generate_page.dart' show randomSeed;
import 'widgets.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  String? _selected;
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<Library>();
    final songs = lib.songs
        .where((s) => _filter.isEmpty || '${s.title} ${s.style}'.toLowerCase().contains(_filter.toLowerCase()))
        .toList();
    final selected = (_selected == null ? null : lib.byDir(_selected!)) ?? (songs.isNotEmpty ? songs.first : null);
    return PageScaffold(
      title: 'Library',
      subtitle: '${lib.songs.length} songs · ${context.read<Settings>().importRoots.length} imported folder(s), read-only',
      actions: [
        IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: lib.refresh),
      ],
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 400,
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                child: TextField(
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Filter', isDense: true, border: OutlineInputBorder()),
                  onChanged: (v) => setState(() => _filter = v),
                ),
              ),
              Expanded(
                child: songs.isEmpty
                    ? const Center(child: Text('No songs yet. Generate one on the first tab.'))
                    : ListView.builder(
                        itemCount: songs.length,
                        itemBuilder: (_, i) => _SongTile(
                          songs[i],
                          selected: songs[i].dir == selected?.dir,
                          onTap: () => setState(() => _selected = songs[i].dir),
                        ),
                      ),
              ),
            ]),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: selected == null
                ? const Center(child: Text('Select a song'))
                : _SongDetails(selected, key: ValueKey(selected.dir), onDeleted: () => setState(() => _selected = null)),
          ),
        ],
      ),
    );
  }
}

class _SongTile extends StatelessWidget {
  const _SongTile(this.song, {required this.selected, required this.onTap});

  final Song song;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pl = context.watch<AudioPlayerModel>();
    final cs = Theme.of(context).colorScheme;
    final playing = pl.path == song.audioPath && pl.playing;
    return ListTile(
      selected: selected,
      selectedTileColor: cs.secondaryContainer.withValues(alpha: 0.5),
      onTap: onTap,
      leading: IconButton(
        icon: Icon(playing ? Icons.pause_circle : Icons.play_circle),
        color: cs.primary,
        iconSize: 30,
        onPressed: () => pl.toggle(song.audioPath, title: song.title),
      ),
      title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${formatDuration(song.seconds)} · ${song.kind} · ${_date(song.modified)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (song.truncationWarning) const Tooltip(message: 'Truncated', child: Icon(Icons.warning_amber, color: Colors.orange, size: 18)),
        if (song.readOnly) const Tooltip(message: 'Imported (read-only)', child: Icon(Icons.lock_outline, size: 16)),
      ]),
    );
  }
}

String _date(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

class _SongDetails extends StatelessWidget {
  const _SongDetails(this.song, {super.key, required this.onDeleted});

  final Song song;
  final VoidCallback onDeleted;

  @override
  Widget build(BuildContext context) {
    final pl = context.watch<AudioPlayerModel>();
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final playing = pl.path == song.audioPath && pl.playing;
    final timing = song.timing;
    final sem = timing['semantic'] is Map ? Map<String, dynamic>.from(timing['semantic'] as Map) : <String, dynamic>{};
    String secs(dynamic v) => v is num ? '${v.toStringAsFixed(1)} s' : '–';
    final section = song.studio['section'] is Map ? Map<String, dynamic>.from(song.studio['section'] as Map) : null;
    final seam = song.studio['seam'] is Map ? Map<String, dynamic>.from(song.studio['seam'] as Map) : null;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(children: [
          Expanded(child: Text(song.title, style: t.headlineSmall)),
          if (!song.readOnly)
            IconButton(tooltip: 'Rename', icon: const Icon(Icons.edit_outlined), onPressed: () => _rename(context)),
        ]),
        const SizedBox(height: 4),
        Wrap(spacing: 6, runSpacing: 6, children: [
          Badge2(song.kind),
          Badge2(song.backend),
          Badge2('cot ${song.cot}'),
          if (song.instrumental) const Badge2('instrumental'),
          if (song.readOnly) const Badge2('imported · read-only', icon: Icons.lock_outline),
        ]),
        const SizedBox(height: 14),
        if (song.truncationWarning)
          _Banner(
            color: Colors.orange,
            icon: Icons.warning_amber,
            text: song.truncated['abc'] == true
                ? 'The ABC score was truncated (planner hit its token cap). The song may follow an incomplete plan.'
                : 'The semantic stream hit the 9000-token cap without an end token: the song was cut off, not finished.',
          ),
        if (!song.truncationWarning && song.stoppedAtRequestedLength)
          const _Banner(
            color: Colors.blueGrey,
            icon: Icons.info_outline,
            text: 'Stopped at the requested maximum length (no natural ending). Extend it to continue.',
          ),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(
            icon: Icon(playing ? Icons.pause : Icons.play_arrow),
            label: Text(playing ? 'Pause' : 'Play'),
            onPressed: () => pl.toggle(song.audioPath, title: song.title),
          ),
          if (song.renderPath != null)
            OutlinedButton.icon(
              icon: const Icon(Icons.play_arrow),
              label: const Text('Play raw re-render'),
              onPressed: () => pl.play(song.renderPath!, title: '${song.title} (raw re-render)'),
            ),
          OutlinedButton.icon(
            icon: const Icon(Icons.folder_open),
            label: Text(Platform.isMacOS ? 'Reveal in Finder' : 'Show in folder'),
            onPressed: () => AppPaths.reveal(song.audioPath),
          ),
          MenuAnchor(
            builder: (_, c, _) => OutlinedButton.icon(
              icon: const Icon(Icons.ios_share),
              label: const Text('Export'),
              onPressed: () => c.isOpen ? c.close() : c.open(),
            ),
            menuChildren: [
              for (final f in ['mp3', 'flac', 'wav'])
                MenuItemButton(onPressed: () => _export(context, f), child: Text(f.toUpperCase())),
            ],
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.replay),
            label: const Text('Re-render…'),
            onPressed: song.hasSemantic ? () => _rerender(context) : null,
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.queue_music),
            label: const Text('Extend…'),
            onPressed: song.hasSemantic ? () => context.read<AppNav>().extend(song.dir) : null,
          ),
          OutlinedButton.icon(
            icon: Icon(Icons.delete_outline, color: cs.error),
            label: Text(song.readOnly ? 'Remove from library' : 'Delete', style: TextStyle(color: cs.error)),
            onPressed: () => _delete(context),
          ),
        ]),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Parameters',
          child: KeyValueTable([
            ('Duration', formatDuration(song.seconds)),
            ('Created', _date(song.modified)),
            ('Mode (cot)', song.cot),
            ('Seed', '${song.seed ?? '–'}'),
            ('ODE steps', '${song.steps ?? '–'}'),
            ('AR precision', song.precision ?? '–'),
            if (song.params['max_seconds'] != null) ('Max length', '${song.params['max_seconds']} s'),
            ('Truncated', 'abc: ${song.truncated['abc'] ?? false}, semantic: ${song.truncated['semantic'] ?? false}'),
            ('Style', song.style),
            ('Folder', song.dir),
            if (song.studio['source'] != null) ('Source', '${song.studio['source']}'),
          ]),
        ),
        if (section != null) ...[
          const SizedBox(height: 12),
          SectionCard(
            title: 'Extension',
            child: KeyValueTable([
              ('Source section', '${(section['start_seconds'] as num).toStringAsFixed(1)} – ${(section['end_seconds'] as num).toStringAsFixed(1)} s'),
              ('New frames', '${section['new_frames']} (${((section['new_frames'] as num? ?? 0) / 25).toStringAsFixed(1)} s)'),
              ('Requested addition', section['add_seconds'] == null ? 'natural end' : '${section['add_seconds']} s'),
              if (seam != null) ('Splice', seam['used'] == 'splice'
                  ? 'original up to ${((seam['seam_sample'] as num) / 48000).toStringAsFixed(2)} s, ${((seam['crossfade_samples'] as num) / 48000).toStringAsFixed(1)} s equal-power crossfade'
                  : 'whole re-render (section started at 0)'),
            ]),
          ),
        ],
        const SizedBox(height: 12),
        SectionCard(
          title: 'Timings',
          child: KeyValueTable([
            if (sem.isNotEmpty) ('Semantic (AR)', '${sem['output_tokens'] ?? '–'} tokens in ${secs(sem['seconds'])}${sem['output_tps'] is num ? ' (${(sem['output_tps'] as num).toStringAsFixed(1)} tok/s)' : ''}'),
            if (timing['abc'] is Map && (timing['abc'] as Map)['seconds'] is num) ('Score (ABC)', secs((timing['abc'] as Map)['seconds'])),
            if (timing['nar_seconds'] != null) ('Flow matching', secs(timing['nar_seconds'])),
            if (timing['vae_seconds'] != null) ('VAE', secs(timing['vae_seconds'])),
            ('End to end', secs(timing['e2e_seconds'])),
          ]),
        ),
        if (song.lyrics.trim().isNotEmpty) ...[
          const SizedBox(height: 12),
          SectionCard(title: 'Lyrics', child: SelectableText(song.lyrics, style: const TextStyle(fontFamily: 'monospace', fontSize: 12))),
        ],
        if (song.abc != null) ...[
          const SizedBox(height: 12),
          SectionCard(
            title: 'ABC score',
            trailing: IconButton(
              tooltip: 'Copy',
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () => Clipboard.setData(ClipboardData(text: song.abc!)),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: SingleChildScrollView(child: SelectableText(song.abc!, style: const TextStyle(fontFamily: 'monospace', fontSize: 12))),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _rename(BuildContext context) async {
    final c = TextEditingController(text: song.title);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(controller: c, autofocus: true, onSubmitted: (v) => Navigator.pop(ctx, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save')),
        ],
      ),
    );
    if (v != null && v.trim().isNotEmpty && context.mounted) await context.read<Library>().rename(song, v.trim());
  }

  Future<void> _export(BuildContext context, String fmt) async {
    final base = song.title.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');
    final loc = await getSaveLocation(suggestedName: '$base.$fmt', acceptedTypeGroups: [XTypeGroup(label: fmt.toUpperCase(), extensions: [fmt])]);
    if (loc == null || !context.mounted) return;
    final settings = context.read<Settings>();
    final ffmpeg = AppPaths.ffmpeg(settings.ffmpegPath);
    try {
      if (ffmpeg != null) {
        final codec = switch (fmt) {
          'mp3' => ['-codec:a', 'libmp3lame', '-b:a', '256k'],
          'flac' => ['-codec:a', 'flac'],
          _ => ['-codec:a', 'pcm_s24le'],
        };
        final r = await Process.run(ffmpeg, ['-hide_banner', '-loglevel', 'error', '-y', '-i', song.audioPath, ...codec, loc.path]);
        if (r.exitCode != 0) throw Exception(r.stderr);
      } else if (fmt == 'flac') {
        await File(song.audioPath).copy(loc.path);
      } else {
        final sc = context.read<Sidecar>();
        await sc.ensureStarted();
        await sc.request('export', {'source': song.audioPath, 'destination': loc.path, 'format': fmt});
      }
      if (context.mounted) showSnack(context, 'Exported ${p.basename(loc.path)}');
    } catch (e) {
      if (context.mounted) showSnack(context, 'Export failed: $e', error: true);
    }
  }

  Future<void> _rerender(BuildContext context) async {
    final settings = context.read<Settings>();
    final seed = TextEditingController(text: '${randomSeed()}');
    var steps = song.steps == 32 ? 8 : 32;
    var precision = song.precision ?? 'bf16';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Re-render'),
          content: SizedBox(
            width: 440,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('Reuses this song\'s score and semantic tokens (no AR stage), so only the flow matching '
                  'and the VAE run again: a new noise seed or a different number of steps.'),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(child: TextField(controller: seed, decoration: const InputDecoration(labelText: 'Noise seed', border: OutlineInputBorder()))),
                IconButton(icon: const Icon(Icons.casino_outlined), onPressed: () => seed.text = '${randomSeed()}'),
              ]),
              const SizedBox(height: 12),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 8, label: Text('8 steps')),
                  ButtonSegment(value: 16, label: Text('16')),
                  ButtonSegment(value: 32, label: Text('32 steps')),
                ],
                selected: {steps},
                onSelectionChanged: (s) => setS(() => steps = s.first),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Queue re-render')),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    final s = int.tryParse(seed.text) ?? randomSeed();
    context.read<JobQueue>().add('rerender', '${song.title} (re-render $steps steps, seed $s)', {
      'source_dir': song.dir,
      'seed': s,
      'steps': steps,
      'precision': settings.backend == 'mlx' ? precision : null,
      'source_seconds': song.seconds,
    });
    showSnack(context, 'Re-render queued');
  }

  Future<void> _delete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(song.readOnly ? 'Remove from library?' : 'Delete song?'),
        content: Text(song.readOnly
            ? '"${song.title}" is an imported folder. It is hidden from the library; nothing is deleted on disk.'
            : '"${song.title}" and its folder will be deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(song.readOnly ? 'Remove' : 'Delete')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await context.read<AudioPlayerModel>().stopIf(song.dir);
    if (!context.mounted) return;
    await context.read<Library>().delete(song);
    onDeleted();
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.color, required this.icon, required this.text});

  final Color color;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10), border: Border.all(color: color.withValues(alpha: 0.5))),
        child: Row(children: [Icon(icon, color: color), const SizedBox(width: 10), Expanded(child: Text(text))]),
      );
}
