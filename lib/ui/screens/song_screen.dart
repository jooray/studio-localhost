import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/library/catalogue.dart';
import '../../core/library/envelopes.dart';
import '../../core/library/song.dart';
import '../../core/paths.dart';
import '../../core/player.dart';
import '../../state/generate_form.dart';
import '../../state/library_view.dart';
import '../../state/seeds.dart';
import '../frame.dart';
import '../routes.dart';
import '../theme.dart';
import '../widgets/polar_plot.dart';
import '../widgets/sleeve.dart';
import '../widgets/song_actions.dart';
import '../widgets/title_editor.dart';
import 'record_sheet.dart';
import 'studio_screen.dart' show shortError;

/// One catalogue entry: the plot large, its number and code, playback, actions and the
/// transmission data (format, length, seed, steps, model and licence in one quiet line).
class SongScreen extends StatelessWidget {
  const SongScreen(this.songId, {super.key, this.startRename = false});

  final String songId;

  /// Open with the title already in edit (captures).
  final bool startRename;

  @override
  Widget build(BuildContext context) {
    final v = context.watch<LibraryView>();
    final song = v.library.byId(songId);
    if (song == null) {
      return const SleevePage(title: 'Entry', child: Padding(padding: EdgeInsets.all(24), child: Etched('This entry is gone.', size: 12)));
    }
    return SleevePage(
      title: Catalogue.format(v.library.number(song)),
      child: LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth >= 820;
        final u = SleeveScale.of(context);
        final plot = _SongPlot(song);
        final details = _Details(song, startRename: startRename);
        if (wide) {
          return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(flex: 10, child: Padding(padding: const EdgeInsets.all(32), child: Center(child: AspectRatio(aspectRatio: 1, child: plot)))),
            const Rule(vertical: true),
            Expanded(flex: 9, child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(32, 28, 32, 32), child: details)),
          ]);
        }
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(25 * u, 16, 25 * u, 32 + MediaQuery.paddingOf(context).bottom),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(padding: EdgeInsets.symmetric(horizontal: 30 * u), child: AspectRatio(aspectRatio: 1, child: plot)),
            const SizedBox(height: 20),
            details,
          ]),
        );
      }),
    );
  }
}

class _SongPlot extends StatelessWidget {
  const _SongPlot(this.song);
  final Song song;

  @override
  Widget build(BuildContext context) {
    final env = context.watch<Envelopes>().of(song);
    final pl = context.watch<AudioPlayerModel>();
    final mine = song.audioPath != null && pl.path == song.audioPath;
    final d = pl.duration.inMilliseconds;
    return PolarPlot(
      envelope: env,
      seed: song.codeSeed,
      arc: mine && d > 0 ? pl.position.inMilliseconds / d : null,
      grow: env == null && song.active ? 0.05 : null,
      live: song.status == SongStatus.running,
      onSeek: song.hasAudio
          ? (f) async {
              if (!mine) await pl.play(song.audioPath!, title: context.read<LibraryView>().library.fileTitle(song));
              final dd = pl.duration;
              if (dd > Duration.zero) await pl.seek(dd * f);
            }
          : null,
      semanticLabel: 'Plot, tap the ring to play from there',
    );
  }
}

class _Details extends StatefulWidget {
  const _Details(this.song, {this.startRename = false});
  final Song song;
  final bool startRename;

  @override
  State<_Details> createState() => _DetailsState();
}

class _DetailsState extends State<_Details> {
  final _title = GlobalKey<TitleEditorState>();

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final v = context.read<LibraryView>();
    final u = SleeveScale.of(context);
    final n = v.library.number(song);
    final stages = Map<String, dynamic>.from(song.timing['stages'] as Map? ?? {});
    final section = song.section;
    final audio = song.audioPath;
    final format = audio == null ? '–' : '${audio.split('.').last.toUpperCase()} · ${(v.studio.model?.limits.sampleRate ?? 48000) ~/ 1000} kHz stereo';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // The title leads, set large in Geist; tap it to rename. The number sits beside the code.
      TitleEditor(
        song,
        key: _title,
        startEditing: widget.startRename,
        style: SleeveType.display(u).copyWith(fontSize: 44 * u + 4, height: 1.1, letterSpacing: -0.5),
      ),
      const SizedBox(height: 14),
      Row(children: [
        Text(Catalogue.format(n), style: SleeveType.value(u, size: 16, color: song.status == SongStatus.running ? Sleeve.red : Sleeve.ink)),
        const SizedBox(width: 16),
        SizedBox(width: 200 * u, child: CodeStripView(song.codeSeed, height: 12)),
      ]),
      const SizedBox(height: 22),
      const Rule(),
      _PlayLine(song),
      const Rule(),
      if (song.status == SongStatus.failed || song.status == SongStatus.interrupted || song.status == SongStatus.cancelled) ...[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: ErrorLine(
            song.error != null ? shortError(song.error!) : 'Stopped before the end',
            detail: song.error,
            action: song.resumable ? 'Resume' : null,
            onAction: () => v.resume(song),
          ),
        ),
        const Rule(color: Sleeve.ruleFaint),
      ],
      if (song.truncationWarning) ...[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: ErrorLine(song.truncated['abc'] == true ? 'Score cut off: the song may lose its plan' : 'Hit the length cap without an ending'),
        ),
        const Rule(color: Sleeve.ruleFaint),
      ],
      const SizedBox(height: 14),
      _Actions(song, onRename: () => _title.currentState?.edit()),
      const SizedBox(height: 26),
      Etched('Transmission data', size: 12, color: Sleeve.inkMute),
      const SizedBox(height: 6),
      const Rule(),
      DataList([
        ('Format', format),
        if (song.seconds > 0) ('Length', formatDuration(song.seconds)),
        ('Seed', '${song.seed ?? '–'}'),
        ('Steps', '${song.steps ?? '–'}${song.precision != null ? ' · ${song.precision}' : ''}'),
        if (song.mode.isNotEmpty) ('Plan', song.mode),
        ('Made', _date(song.created)),
        if (song.kind != 'generate') ('Kind', song.kind),
        if (section != null)
          ('From', '${(section['start_seconds'] as num? ?? 0).toStringAsFixed(1)} s · +${((section['new_frames'] as num? ?? 0) / 25).toStringAsFixed(1)} s new'),
        if (song.timing['total_seconds'] is num) ('Took', formatDuration(song.timing['total_seconds'] as num)),
        if (stages.isNotEmpty)
          ('Stages', stages.entries.map((e) => '${e.key} ${(e.value as num).toStringAsFixed(0)}s').join(' · ')),
      ]),
      const SizedBox(height: 12),
      Text(v.modelLine(song), style: SleeveType.etched(u, size: 11, color: Sleeve.inkMute)),
      if (song.style.isNotEmpty) ...[
        const SizedBox(height: 28),
        Etched('Style', size: 12, color: Sleeve.inkMute),
        const SizedBox(height: 8),
        SelectableText(song.style, style: SleeveType.body(u).copyWith(fontSize: 17, height: 1.35)),
      ],
      if (song.lyrics.trim().isNotEmpty) ...[
        const SizedBox(height: 24),
        Etched('Lyrics', size: 12, color: Sleeve.inkMute),
        const SizedBox(height: 8),
        SelectableText(_capsTags(song.lyrics.trim()), style: SleeveType.body(u).copyWith(fontSize: 17, height: 1.35)),
      ],
      if (song.abc != null) ...[const SizedBox(height: 24), _Score(song.abc!)],
    ]);
  }
}

String _capsTags(String s) => s.replaceAllMapped(RegExp(r'\[[^\]\n]*\]'), (m) => m[0]!.toUpperCase());

String _date(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// Play/pause and a hairline scrub rule.
class _PlayLine extends StatelessWidget {
  const _PlayLine(this.song);
  final Song song;

  @override
  Widget build(BuildContext context) {
    final pl = context.watch<AudioPlayerModel>();
    final v = context.read<LibraryView>();
    final u = SleeveScale.of(context);
    final mine = song.audioPath != null && pl.path == song.audioPath;
    final playing = mine && pl.playing;
    final total = mine && pl.duration > Duration.zero ? pl.duration.inMilliseconds / 1000 : song.seconds;
    final pos = mine ? pl.position.inMilliseconds / 1000 : 0.0;
    final f = total > 0 ? (pos / total).clamp(0.0, 1.0) : 0.0;
    return SizedBox(
      height: 56,
      child: Row(children: [
        GlyphButton(playing ? Glyph.pause : Glyph.play, tooltip: playing ? 'Pause' : 'Play', size: 22, onTap: song.hasAudio ? () => v.toggle(song) : null),
        const SizedBox(width: 8),
        Text(mine ? '${formatDuration(pos)} / ${formatDuration(total)}' : formatDuration(total),
            style: SleeveType.status(u).copyWith(fontSize: 20)),
        const SizedBox(width: 18),
        Expanded(
          child: LayoutBuilder(builder: (context, c) {
            Future<void> seek(double x) async {
              if (!song.hasAudio) return;
              if (!mine) await pl.play(song.audioPath!, title: context.read<LibraryView>().library.fileTitle(song));
              final d = pl.duration;
              if (d > Duration.zero) await pl.seek(d * (x / c.maxWidth).clamp(0.0, 1.0));
            }

            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => seek(d.localPosition.dx),
              onHorizontalDragUpdate: (d) => seek(d.localPosition.dx),
              child: Semantics(
                slider: true,
                value: '${(f * 100).round()}%',
                label: 'Position',
                child: SizedBox(
                  height: 48,
                  child: Stack(alignment: Alignment.centerLeft, children: [
                    const Rule(color: Sleeve.ruleFaint),
                    FractionallySizedBox(widthFactor: f, child: const Rule(color: Sleeve.ink)),
                    Align(alignment: Alignment(f * 2 - 1, 0), child: Container(width: 2, height: 14, color: Sleeve.ink)),
                  ]),
                ),
              ),
            );
          }),
        ),
      ]),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions(this.song, {required this.onRename});
  final Song song;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    final v = context.read<LibraryView>();
    final u = SleeveScale.of(context);
    Widget act(Glyph g, String label, VoidCallback? onTap) => SizedBox(
          height: 48,
          child: Cell(
            shrink: true,
            onTap: onTap,
            semanticLabel: label,
            padding: EdgeInsets.symmetric(horizontal: 14 * u),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              GlyphIcon(g, size: 18, color: Sleeve.ink),
              const SizedBox(width: 10),
              Text(label.toUpperCase(), style: SleeveType.etched(u, size: 12, color: Sleeve.ink)),
            ]),
          ),
        );
    return Wrap(spacing: 8, runSpacing: 8, children: [
      act(Glyph.rename, 'Rename', onRename),
      if (song.hasAudio) act(Platform.isAndroid ? Glyph.share : Glyph.share, Platform.isAndroid ? 'Share' : 'Export', () => _export(context, v, song)),
      if (v.canExtend(song)) act(Glyph.extend, 'Extend', () => openExtend(context, song)),
      if (song.style.isNotEmpty || song.lyrics.isNotEmpty) act(Glyph.reuse, 'Reuse', () => reuseSong(context, song)),
      if (v.canRerender(song)) act(Glyph.rerender, 'Re-render', () => showRerenderSheet(context, v, song)),
      if (song.resumable) act(Glyph.rerender, 'Resume', () => v.resume(song)),
      if (song.active) act(Glyph.close, 'Stop', () => v.cancel(song)),
      if (Platform.isMacOS || Platform.isLinux) act(Glyph.folder, 'Folder', () => AppPaths.reveal(song.audioPath ?? song.dir)),
      if (!song.active) act(Glyph.delete, song.readOnly ? 'Remove' : 'Delete', () => _delete(context, v, song)),
    ]);
  }
}

Future<void> _export(BuildContext context, LibraryView v, Song song) async {
  final ex = v.exporter;
  final fmt = await showModalBottomSheet<String>(
    context: context,
    useSafeArea: true,
    barrierColor: const Color(0xB3000000),
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (ctx) => Padding(
      padding: const EdgeInsets.fromLTRB(25, 8, 25, 24),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Etched(Platform.isAndroid ? 'Share as' : 'Export as', size: 12, color: Sleeve.inkMute)),
          GlyphButton(Glyph.close, tooltip: 'Close', size: 18, onTap: () => Navigator.pop(ctx)),
        ]),
        const Rule(),
        const SizedBox(height: 14),
        Row(children: [
          for (final f in ex.formats) ...[
            Expanded(
              child: Cell(onTap: () => Navigator.pop(ctx, f), child: Text(f.toUpperCase(), style: SleeveType.etched(1, size: 14, color: Sleeve.ink))),
            ),
            if (f != ex.formats.last) const SizedBox(width: 8),
          ],
        ]),
      ]),
    ),
  );
  if (fmt == null || !context.mounted) return;
  try {
    if (Platform.isAndroid) {
      await ex.share(song, fmt: fmt);
    } else {
      final loc = await getSaveLocation(suggestedName: ex.suggestedName(song, fmt), acceptedTypeGroups: [XTypeGroup(label: fmt.toUpperCase(), extensions: [fmt])]);
      if (loc == null) return;
      await ex.exportTo(song, fmt, loc.path);
      if (context.mounted) showLine(context, 'Exported ${fmt.toUpperCase()}');
    }
  } catch (e) {
    if (context.mounted) showLine(context, 'Export failed: ${shortError(e)}', error: true);
  }
}

Future<void> showRerenderSheet(BuildContext context, LibraryView v, Song song) async {
  final choices = v.studio.model?.limits.steps ?? const [32];
  var steps = song.steps == choices.last ? choices.first : choices.last;
  final seed = TextEditingController(text: '${randomSeed()}');
  // A sketch with a saved mix is refined by default: a quarter of the final steps on top of it.
  final canRefine = v.canRefine(song);
  var refine = canRefine;
  final refineSteps = (choices.last * LibraryView.refineT).round();
  final ok = await showModalBottomSheet<bool>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    barrierColor: const Color(0xB3000000),
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => SleeveScale(
        u: 1,
        child: Padding(
          padding: EdgeInsets.fromLTRB(25, 8, 25, 24 + MediaQuery.viewInsetsOf(ctx).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const Expanded(child: Etched('Re-render', size: 12, color: Sleeve.inkMute)),
              GlyphButton(Glyph.close, tooltip: 'Close', size: 18, onTap: () => Navigator.pop(ctx)),
            ]),
            const Rule(),
            if (canRefine) ...[
              const SizedBox(height: 12),
              Cell(
                selected: refine,
                frame: refine,
                onTap: () => set(() => refine = true),
                semanticLabel: 'Refine this mix, $refineSteps steps',
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Etched('Refine this mix', size: 13, color: refine ? Sleeve.ink : Sleeve.inkSoft, weight: FontWeight.w500),
                  const SizedBox(height: 5),
                  Etched(
                    '$refineSteps steps · ${formatEstimate(v.queue.estimate(seconds: song.seconds, steps: refineSteps, precision: song.precision, compose: false))} · builds on this mix',
                    size: 11,
                    color: refine ? Sleeve.inkSoft : Sleeve.inkMute,
                    maxLines: 2,
                  ),
                ]),
              ),
              const SizedBox(height: 4),
            ],
            QualityRow(
              choices: choices,
              selected: refine ? -1 : steps,
              preset: ctx.read<GenerateForm>().presetOf,
              estimate: (s) => v.queue.estimate(seconds: song.seconds, steps: s, precision: song.precision, compose: false),
              onSelect: (s) => set(() {
                steps = s;
                refine = false;
              }),
              note: 'Mixes again from scratch: same melody and words, a new sound.',
            ),
            if (!refine) Row(children: [
              const SizedBox(width: 120, child: Etched('Seed', size: 12, color: Sleeve.inkMute)),
              Expanded(child: SleeveField(controller: seed, style: SleeveType.value(1, size: 16), maxLines: 1, keyboardType: TextInputType.number)),
              GlyphButton(Glyph.dice, tooltip: 'New seed', size: 20, onTap: () => seed.text = '${randomSeed()}'),
            ]),
            const Rule(color: Sleeve.ruleFaint),
            const SizedBox(height: 16),
            SizedBox(
              height: 52,
              child: Cell(
                block: true,
                onTap: () => Navigator.pop(ctx, true),
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.only(left: 18),
                child: Text('${refine ? 'REFINE' : 'RE-RENDER'} ${Catalogue.format(v.library.catalogue.next)}', style: SleeveType.etched(1, size: 14, color: Sleeve.ink, weight: FontWeight.w500)),
              ),
            ),
          ]),
        ),
      ),
    ),
  );
  if (ok != true) return;
  if (refine) {
    await v.refine(song, steps: choices.last);
    if (context.mounted) showLine(context, 'Refine queued');
    return;
  }
  await v.rerender(song, steps: steps, seed: int.tryParse(seed.text) ?? randomSeed());
  if (context.mounted) showLine(context, 'Re-render queued');
}

Future<void> _delete(BuildContext context, LibraryView v, Song song) async {
  final n = Catalogue.format(v.library.number(song));
  final ok = await showDialog<bool>(
    context: context,
    barrierColor: const Color(0xB3000000),
    builder: (ctx) => Dialog(
      child: SizedBox(
        width: 380,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(song.readOnly ? 'Remove $n from the catalogue?' : 'Delete $n?', style: SleeveType.value(1, size: 16)),
            const SizedBox(height: 8),
            Etched(song.readOnly ? 'The imported folder stays on disk.' : 'The folder and its audio are deleted.', size: 11, color: Sleeve.inkMute, maxLines: 2),
            const SizedBox(height: 20),
            Row(children: [
              Expanded(child: Cell(onTap: () => Navigator.pop(ctx, false), child: const Etched('Keep', size: 13, color: Sleeve.ink))),
              const SizedBox(width: 8),
              Expanded(
                child: Cell(
                  selected: true,
                  onTap: () => Navigator.pop(ctx, true),
                  child: Etched('${song.readOnly ? 'Remove' : 'Delete'} $n — confirm', size: 12, color: Sleeve.ink, maxLines: 2, align: TextAlign.center),
                ),
              ),
            ]),
          ]),
        ),
      ),
    ),
  );
  if (ok != true) return;
  await v.delete(song);
  if (context.mounted) Navigator.of(context).maybePop();
}

class _Score extends StatefulWidget {
  const _Score(this.abc);
  final String abc;

  @override
  State<_Score> createState() => _ScoreState();
}

class _ScoreState extends State<_Score> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final u = SleeveScale.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
          child: Cell(
            frame: false,
            onTap: () => setState(() => _open = !_open),
            alignment: Alignment.centerLeft,
            minHeight: 44,
            semanticLabel: _open ? 'Hide score' : 'Show score',
            child: Row(children: [
              Etched('Score (ABC)', size: 12, color: Sleeve.inkMute),
              const SizedBox(width: 10),
              GlyphIcon(_open ? Glyph.minus : Glyph.plus, size: 14, color: Sleeve.inkMute),
            ]),
          ),
        ),
        if (_open)
          GlyphButton(Glyph.copy, tooltip: 'Copy', size: 18, onTap: () {
            Clipboard.setData(ClipboardData(text: widget.abc));
            showLine(context, 'Score copied');
          }),
      ]),
      AnimatedSize(
        duration: MediaQuery.of(context).disableAnimations ? Duration.zero : Sleeve.step,
        curve: Sleeve.ease,
        alignment: Alignment.topCenter,
        child: _open
            ? Container(
                constraints: const BoxConstraints(maxHeight: 320),
                decoration: const BoxDecoration(border: Border.fromBorderSide(BorderSide(color: Sleeve.ruleFaint))),
                padding: const EdgeInsets.all(14),
                child: SingleChildScrollView(child: SelectableText(widget.abc, style: SleeveType.value(u, size: 12, color: Sleeve.inkSoft))),
              )
            : const SizedBox(width: double.infinity),
      ),
    ]);
  }
}
