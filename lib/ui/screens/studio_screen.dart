import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/jobs/job_queue.dart';
import '../../core/library/catalogue.dart';
import '../../core/library/song.dart';
import '../../core/paths.dart';
import '../../core/player.dart';
import '../../core/studio.dart';
import '../../state/generate_form.dart';
import '../../state/take.dart';
import '../frame.dart';
import '../routes.dart';
import '../theme.dart';
import '../widgets/polar_plot.dart';
import '../widgets/sleeve.dart';
import '../widgets/song_actions.dart';
import 'record_sheet.dart';

/// The main screen: the take as a living polar plot, its status line, the style and lyric sheet
/// for the next song, its colour code, the catalogue index and Record.
class StudioScreen extends StatelessWidget {
  const StudioScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, c) {
          if (c.maxWidth < 600) return const _PhoneStudio();
          return AdaptiveFrame(child: _WideStudio(width: c.maxWidth));
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------- phone

/// Asks the phone studio to scroll to the end (captures of long lyrics).
final studioScrollToEnd = ValueNotifier<bool>(false);

/// Phone: the page scrolls as one sheet (plot, status, style, lyrics, queue); the status line
/// pins as a compact header once the plot has scrolled away. The colour code, the index and
/// Record stay pinned at the bottom. In the first viewport this is the approved comp.
class _PhoneStudio extends StatefulWidget {
  const _PhoneStudio();

  @override
  State<_PhoneStudio> createState() => _PhoneStudioState();
}

class _PhoneStudioState extends State<_PhoneStudio> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeEnd());
  }

  void _maybeEnd() {
    if (!studioScrollToEnd.value || !_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final pad = mq.padding;
    final u = (mq.size.width / 576).clamp(0.55, 1.25);
    final side = 25 * u;
    final typing = mq.viewInsets.bottom > 0;
    final indexH = math.max(52 * u, 48.0);
    final recordH = math.max(54 * u, 48.0);
    return SleeveScale(
      u: u,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: pad.top),
          Expanded(
            child: CustomScrollView(
              controller: _scroll,
              slivers: [
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 465 * u,
                    child: Stack(
                      children: [
                        Positioned(left: 90 * u, top: 35 * u, width: 396 * u, height: 396 * u, child: const TakePlot()),
                        Positioned(left: 8 * u, top: 4 * u, child: const _AllButton()),
                      ],
                    ),
                  ),
                ),
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _StatusHeader(u: u, side: side),
                ),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 50 * u,
                    child: Padding(padding: EdgeInsets.fromLTRB(55 * u, 0, 40 * u, 0), child: const SheetHeader()),
                  ),
                ),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 107 * u,
                    child: Padding(padding: EdgeInsets.fromLTRB(55 * u, 0, 55 * u, 0), child: const StyleBlock()),
                  ),
                ),
                SliverToBoxAdapter(child: Rule(indent: side)),
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(55 * u, 13 * u, 40 * u, 16 * u),
                    child: const Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [LyricsBlock(grow: true), _PhoneQueue()]),
                  ),
                ),
              ],
            ),
          ),
          Rule(indent: side),
          if (!typing) ...[
            Padding(padding: EdgeInsets.fromLTRB(55 * u, 15 * u, 55 * u, 15 * u), child: const CurrentStrip(height: 41)),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: side),
              child: SizedBox(height: indexH, child: const IndexBar()),
            ),
          ],
          Padding(
            padding: EdgeInsets.symmetric(horizontal: side),
            child: SizedBox(
              height: recordH,
              child: RecordRow(joined: !typing),
            ),
          ),
          SizedBox(height: typing ? 0 : pad.bottom),
        ],
      ),
    );
  }
}

/// The status line between its rules, pinned at the top while the page scrolls.
class _StatusHeader extends SliverPersistentHeaderDelegate {
  _StatusHeader({required this.u, required this.side});
  final double u;
  final double side;

  double get _h => 48 * u;

  @override
  double get minExtent => _h;
  @override
  double get maxExtent => _h;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) => ColoredBox(
    color: Sleeve.ground,
    child: Column(
      children: [
        Rule(indent: side),
        Expanded(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: side),
            child: const StatusLine(),
          ),
        ),
        Rule(indent: side),
      ],
    ),
  );

  @override
  bool shouldRebuild(_StatusHeader old) => old.u != u || old.side != side;
}

class _PhoneQueue extends StatelessWidget {
  const _PhoneQueue();

  @override
  Widget build(BuildContext context) {
    final q = context.watch<JobQueue>();
    if (q.queued.isEmpty && q.recentSongs.isEmpty) return const SizedBox.shrink();
    final u = SleeveScale.of(context);
    return Padding(
      padding: EdgeInsets.only(top: 28 * u, right: 15 * u),
      child: const QueueList(),
    );
  }
}

// ---------------------------------------------------------------------------------------- wide

class _WideStudio extends StatelessWidget {
  const _WideStudio({required this.width});

  final double width;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final h = mq.size.height - mq.padding.vertical;
    final contentW = width - indexColumnWidth(width);
    final twoCol = contentW >= 760;
    final u = twoCol ? (math.min(contentW / 1240, h / 860)).clamp(0.62, 1.0) : (contentW / 640).clamp(0.6, 1.0);
    final side = 32 * u;
    final bandH = math.max(56 * u, 48.0);
    final style = SizedBox(
      height: wideTopBand,
      child: Padding(padding: EdgeInsets.fromLTRB(side, 18, side, 8), child: const StyleBlock(lines: 2, inlineHeader: true)),
    );
    final lyrics = Padding(padding: EdgeInsets.fromLTRB(side, 22 * u, side, 12 * u), child: const LyricsBlock());
    final status = Padding(
      padding: EdgeInsets.symmetric(horizontal: side),
      child: const StatusLine(inset: 0),
    );
    // The primary action keeps its framed cell (and red end-block when ready) inside the band.
    final record = Padding(
      padding: EdgeInsets.symmetric(horizontal: side, vertical: 7 * u),
      child: const RecordRow(joined: false),
    );
    final strip = Padding(padding: EdgeInsets.fromLTRB(side, 20 * u, side, 24 * u), child: const CurrentStrip(height: 34));
    final Widget body;
    if (twoCol) {
      // Two rows of columns: [plot | style, lyrics, queue] over [status | record], then the strip.
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 11,
                  child: Padding(
                    padding: EdgeInsets.all(28 * u),
                    child: const Center(child: AspectRatio(aspectRatio: 1, child: TakePlot())),
                  ),
                ),
                const Rule(vertical: true),
                Expanded(
                  flex: 10,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      style,
                      const Rule(),
                      Expanded(child: lyrics),
                      const _WideQueue(),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Rule(),
          SizedBox(
            height: bandH,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 11, child: status),
                const Rule(vertical: true),
                Expanded(flex: 10, child: record),
              ],
            ),
          ),
          const Rule(),
          Row(
            children: [
              Expanded(flex: 11, child: strip),
              const SizedBox(width: 1),
              const Expanded(flex: 10, child: SizedBox()),
            ],
          ),
        ],
      );
    } else {
      // One column, same reading order as desktop: plot, status, then the writing together.
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Same band height as the index header on every wide layout, so the first rules align.
          SizedBox(
            height: wideTopBand,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: side),
              child: const Align(
                alignment: Alignment.centerLeft,
                child: Etched('Studio', size: 13, color: Sleeve.ink),
              ),
            ),
          ),
          const Rule(),
          SizedBox(
            height: 340 * u,
            child: Padding(
              padding: EdgeInsets.all(16 * u),
              child: const Center(child: AspectRatio(aspectRatio: 1, child: TakePlot())),
            ),
          ),
          const Rule(),
          SizedBox(height: bandH, child: status),
          const Rule(),
          Padding(padding: EdgeInsets.fromLTRB(side, 18, side, 14), child: const StyleBlock(lines: 2, inlineHeader: true)),
          const Rule(),
          Expanded(child: lyrics),
          const _WideQueue(),
          strip,
          SizedBox(height: bandH, child: record),
          SizedBox(height: 14 * u),
        ],
      );
    }
    return SleeveScale(
      u: u,
      child: SafeArea(left: false, child: body),
    );
  }
}

class _WideQueue extends StatelessWidget {
  const _WideQueue();

  @override
  Widget build(BuildContext context) {
    final q = context.watch<JobQueue>();
    if (q.queued.isEmpty && q.recentSongs.isEmpty) return const SizedBox.shrink();
    final u = SleeveScale.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: 260 * u),
      child: SingleChildScrollView(padding: EdgeInsets.fromLTRB(32 * u, 12 * u, 32 * u, 12 * u), child: const QueueList()),
    );
  }
}

// ---------------------------------------------------------------------------------------- parts

/// The current take's polar plot.
class TakePlot extends StatelessWidget {
  const TakePlot({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.watch<TakeState>();
    final s = t.current;
    final env = t.envelope;
    final recording = t.mode == TakeMode.recording;
    final number = Catalogue.format(t.number(s));
    return PolarPlot(
      envelope: env,
      arc: t.arc,
      grow: env == null && recording ? math.max(0.04, t.tokenProgress) : null,
      seed: s?.codeSeed ?? 0,
      live: recording,
      onSeek: switch (t.mode) {
        TakeMode.playing => (f) => _seek(context, f),
        // Touching the plot of the last song plays it from there.
        TakeMode.idle when s?.audioPath != null => (f) => _play(context, t, s!, f),
        _ => null,
      },
      onCenterTap: (t.mode == TakeMode.playing || t.mode == TakeMode.idle) && s?.audioPath != null
          ? () => context.read<AudioPlayerModel>().toggle(s!.audioPath!, title: t.library.fileTitle(s))
          : null,
      semanticLabel: s == null ? 'Empty plot' : 'Plot of $number',
    );
  }

  Future<void> _play(BuildContext context, TakeState t, Song s, double f) async {
    final p = context.read<AudioPlayerModel>();
    final seconds = t.envelope?.seconds ?? 0;
    await p.play(s.audioPath!, title: t.library.fileTitle(s));
    if (seconds > 0) await p.seek(Duration(milliseconds: (seconds * f * 1000).round()));
  }

  void _seek(BuildContext context, double f) {
    final p = context.read<AudioPlayerModel>();
    final d = p.duration;
    if (d > Duration.zero) p.seek(d * f);
  }
}

/// The engraved status line. Idle: the last song with a play affordance; recording: progress.
class StatusLine extends StatelessWidget {
  const StatusLine({super.key, this.inset = 30});

  /// Text inset from the rule's start, in comp px (the phone comp sets the text 30 px in).
  final double inset;

  @override
  Widget build(BuildContext context) {
    final t = context.watch<TakeState>();
    final u = SleeveScale.of(context);
    final style = SleeveType.status(u);
    final parts = t.status;
    final mode = t.mode;
    final s = t.current;
    final fault = t.engineFault;
    if (fault != null && mode != TakeMode.recording) {
      return Center(
        child: ErrorLine('Engine stopped', action: 'Setup', detail: fault, onAction: () => openSetup(context)),
      );
    }
    // A title leads; without one, the state word does (RECORDING), so it gives way first and the
    // number and times always stay readable.
    final lead = t.lead ?? (parts.length >= 3 ? parts.first : null);
    final rest = t.lead == null && lead != null ? parts.sublist(1) : parts;
    final spans = engravedSpans(rest, style);
    // Engraved spacing: every space sits tighter than a full mono cell.
    final gap = TextSpan(
      text: ' ',
      style: style.copyWith(fontSize: style.fontSize! * 0.42),
    );
    final Widget text;
    if (lead == null) {
      text = Text.rich(TextSpan(style: style, children: spans), maxLines: 1, overflow: TextOverflow.fade, softWrap: false);
    } else if (t.lead == null) {
      // A state word is whole or absent (the sheet header repeats it): never "RECO…".
      final scaler = MediaQuery.textScalerOf(context);
      double width(InlineSpan span) =>
          (TextPainter(text: span, textDirection: TextDirection.ltr, maxLines: 1, textScaler: scaler)..layout()).width;
      final full = TextSpan(style: style, children: [TextSpan(text: lead.toUpperCase()), gap, const TextSpan(text: '·'), gap, ...spans]);
      final short = TextSpan(style: style, children: spans);
      text = LayoutBuilder(
        builder: (_, c) => Text.rich(width(full) <= c.maxWidth ? full : short, maxLines: 1, overflow: TextOverflow.fade, softWrap: false),
      );
    } else {
      text = Row(children: [
        Flexible(child: Text(lead.toUpperCase(), style: style, maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false)),
        Text.rich(TextSpan(style: style, children: [gap, const TextSpan(text: '·'), gap, ...spans]), maxLines: 1, softWrap: false),
      ]);
    }
    Widget? action;
    VoidCallback? onTap;
    switch (mode) {
      case TakeMode.idle:
      case TakeMode.playing:
        final player = context.read<AudioPlayerModel>();
        final playing = mode == TakeMode.playing && player.playing;
        onTap = () {
          final a = s?.audioPath;
          if (a != null) player.toggle(a, title: t.library.fileTitle(s!));
        };
        action = GlyphIcon(playing ? Glyph.pause : Glyph.play, size: 22 * u);
      case TakeMode.failed:
        onTap = () => context.read<JobQueue>().resume(s!);
        action = Etched('Retry', size: 13, color: Sleeve.ink);
      case TakeMode.recording:
        // Partway through mixing the engine leaves a preview: play it to judge the song early.
        final preview = s?.previewPath;
        if (preview != null) {
          final player = context.read<AudioPlayerModel>();
          final on = player.path == preview && player.playing;
          onTap = () => player.toggle(preview, title: '${t.library.fileTitle(s!)} (preview)');
          action = GlyphIcon(on ? Glyph.pause : Glyph.play, size: 22 * u);
        } else {
          onTap = () => openSong(context, s!);
        }
      default:
        break;
    }
    return Cell(
      frame: false,
      onTap: onTap,
      minHeight: 0,
      semanticLabel: [?lead, ...parts, if (mode == TakeMode.recording && s?.previewPath != null) 'play preview'].join(', '),
      padding: EdgeInsets.only(left: inset * u, right: 12 * u),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          if (mode == TakeMode.failed) ...[Container(width: 10 * u, height: 10 * u, color: Sleeve.red), SizedBox(width: 12 * u)],
          Expanded(child: text),
          if (action != null) ...[SizedBox(width: 8 * u), action],
        ],
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(child: Text(text, style: SleeveType.label(SleeveScale.of(context))));
}

/// Whose words the sheet holds: the next number while drafting, else the shown song.
class SheetHeader extends StatelessWidget {
  const SheetHeader({super.key, this.inline = false});

  /// Sits on the STYLE row (wide layouts) instead of its own band.
  final bool inline;

  @override
  Widget build(BuildContext context) {
    final t = context.watch<TakeState>();
    // The draft's provenance: the song it was reused from, or the recording it covers.
    final from = context.select<GenerateForm, String?>(
        (f) => f.covering ? 'Cover of ${f.coverLabel}' : f.fromLabel);
    final s = t.sheetSong;
    final size = inline ? 11.0 : 13.0;
    final Widget lead;
    if (s == null) {
      lead = Etched('Next · ${Catalogue.format(t.nextNumber)}', size: size, color: Sleeve.ink, weight: FontWeight.w500);
    } else {
      // The status line above already names the song; this says what the words are to it.
      lead = Etched('${Catalogue.format(t.number(s))} · ${t.sheetNote(s)}', size: size, color: Sleeve.inkMute);
    }
    // Quiet provenance of a reused prompt, until the user records or edits.
    final provenance = s == null && from != null ? Etched(from, size: 11, color: Sleeve.inkMute) : null;
    if (inline) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (provenance != null) ...[Flexible(child: provenance), SizedBox(width: 12 * SleeveScale.of(context))],
          lead,
        ],
      );
    }
    if (provenance == null) return Row(children: [Flexible(child: lead)]);
    // The number leads in full; the provenance gives way first.
    return Row(
      children: [
        lead,
        SizedBox(width: 12 * SleeveScale.of(context)),
        Expanded(child: Align(alignment: Alignment.centerRight, child: provenance)),
      ],
    );
  }
}

/// A song's own words in the sheet: read-only, a step quieter than a draft. Touching them
/// starts a new draft from this song (Reuse).
class _SheetWords extends StatelessWidget {
  const _SheetWords(this.song, this.text, {this.style, this.maxLines, this.label = 'Words'});
  final Song song;
  final String text;
  final TextStyle? style;
  final int? maxLines;
  final String label;

  @override
  Widget build(BuildContext context) {
    final u = SleeveScale.of(context);
    return Semantics(
      button: true,
      label: '$label of ${Catalogue.format(context.read<TakeState>().number(song))}',
      hint: 'Write a new song from these words',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => reuseSong(context, song),
        child: ExcludeSemantics(
          child: text.trim().isEmpty
              ? Etched('none', size: 12, color: Sleeve.inkMute)
              : Text(
                  text.trim(),
                  maxLines: maxLines,
                  overflow: maxLines == null ? null : TextOverflow.ellipsis,
                  style: style ?? SleeveType.body(u, color: Sleeve.inkSoft),
                ),
        ),
      ),
    );
  }
}

class StyleBlock extends StatelessWidget {
  const StyleBlock({super.key, this.lines = 2, this.inlineHeader = false});
  final int lines;

  /// Wide layouts carry the sheet header on the STYLE row.
  final bool inlineHeader;

  @override
  Widget build(BuildContext context) {
    final f = context.read<GenerateForm>();
    final song = context.select<TakeState, Song?>((t) => t.sheetSong);
    final u = SleeveScale.of(context);
    final body = SleeveType.body(u);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const _FieldLabel('STYLE'),
            if (inlineHeader) const Expanded(child: SheetHeader(inline: true)),
          ],
        ),
        SizedBox(height: 7 * u),
        if (song != null)
          _SheetWords(song, song.style, maxLines: lines, label: 'Style')
        else
          SleeveField(
            controller: f.style,
            style: body,
            maxLines: lines,
            minLines: 1,
            hint: 'genre, mood, instruments, voice',
            semanticLabel: 'Style',
          ),
      ],
    );
  }
}

class LyricsBlock extends StatelessWidget {
  const LyricsBlock({super.key, this.grow = false});

  /// The field grows with its text and the page scrolls (phone); otherwise it fills its box.
  final bool grow;

  @override
  Widget build(BuildContext context) {
    final f = context.read<GenerateForm>();
    final u = SleeveScale.of(context);
    final song = context.select<TakeState, Song?>((t) => t.sheetSong);
    final draftInstrumental = context.select<GenerateForm, bool>((f) => f.instrumental);
    final instrumental = song?.instrumental ?? draftInstrumental;
    if (song != null) {
      final words = _SheetWords(
        song,
        song.lyrics,
        label: 'Lyrics',
        style: SleeveType.body(u, color: instrumental ? Sleeve.inkMute : Sleeve.inkSoft),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const _FieldLabel('LYRICS'),
              if (instrumental) ...[SizedBox(width: 16 * u), Etched('instrumental', size: 12, color: Sleeve.inkMute)],
            ],
          ),
          SizedBox(height: 10 * u),
          if (grow) words else Expanded(child: SingleChildScrollView(child: words)),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const _FieldLabel('LYRICS'),
            if (instrumental) ...[SizedBox(width: 16 * u), Etched('instrumental', size: 12, color: Sleeve.inkMute)],
          ],
        ),
        SizedBox(height: 10 * u),
        if (grow)
          SleeveField(
            controller: f.lyrics,
            style: SleeveType.body(u, color: instrumental ? Sleeve.inkMute : Sleeve.ink),
            maxLines: null,
            minLines: 1,
            keyboardType: TextInputType.multiline,
            hint: '[Verse]\nfirst line\n\n[Chorus]\n…',
            semanticLabel: 'Lyrics',
          )
        else
          Expanded(
            child: SleeveField(
              controller: f.lyrics,
              style: SleeveType.body(u, color: instrumental ? Sleeve.inkMute : Sleeve.ink),
              expands: true,
              hint: '[Verse]\nfirst line\n\n[Chorus]\n…',
              semanticLabel: 'Lyrics',
            ),
          ),
      ],
    );
  }
}

/// Colour code of the current take; before the first song, the next one's.
class CurrentStrip extends StatelessWidget {
  const CurrentStrip({super.key, required this.height});
  final double height;

  @override
  Widget build(BuildContext context) {
    final t = context.watch<TakeState>();
    final f = context.watch<GenerateForm>();
    final u = SleeveScale.of(context);
    // The strip belongs to the sheet: the shown song's code, or the next one's while drafting.
    final seed = (t.drafting ? null : t.current?.codeSeed) ?? int.tryParse(f.seed.text) ?? 0;
    return AnimatedSwitcher(
      duration: MediaQuery.of(context).disableAnimations ? Duration.zero : Sleeve.step,
      switchInCurve: Sleeve.ease,
      transitionBuilder: (child, a) => FadeTransition(
        opacity: a,
        child: SizeTransition(sizeFactor: a, axis: Axis.horizontal, alignment: Alignment.centerLeft, child: child),
      ),
      child: CodeStripView(seed, key: ValueKey(seed), height: height * u),
    );
  }
}

/// The catalogue index: the last four numbers in hairline cells, current one framed.
class IndexBar extends StatelessWidget {
  const IndexBar({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.watch<TakeState>();
    final u = SleeveScale.of(context);
    final entries = t.index;
    final recording = t.mode == TakeMode.recording;
    final reduce = MediaQuery.of(context).disableAnimations;
    final cells = <Widget>[];
    for (var i = 0; i < 4; i++) {
      IndexEntry? at(int k) => k < 4 - entries.length || k > 3 ? null : entries[k - (4 - entries.length)];
      final e = at(i);
      final n = at(i + 1);
      final nextFramed = n != null && (n.running || n.current);
      final active = e != null && (e.running || (e.current && recording));
      final selected = e != null && e.current && !active;
      final color = active ? Sleeve.red : (e == null ? Sleeve.ruleFaint : (e.queued ? Sleeve.inkMute : Sleeve.ink));
      cells.add(
        Expanded(
          child: Cell(
            active: active,
            selected: selected,
            sides: CellSides(left: active || selected, top: true, bottom: true, right: (i < 3 && !nextFramed) || active || selected),
            onTap: e?.song == null ? null : () => openSong(context, e!.song!),
            semanticLabel: e == null ? null : Catalogue.format(e.number),
            minHeight: 0,
            child: AnimatedSwitcher(
              duration: reduce ? Duration.zero : Sleeve.step,
              switchInCurve: Sleeve.ease,
              transitionBuilder: (c, a) => FadeTransition(
                opacity: a,
                child: SlideTransition(
                  position: Tween(begin: const Offset(0.25, 0), end: Offset.zero).animate(a),
                  child: c,
                ),
              ),
              child: Text(
                e == null ? '···' : Catalogue.short(e.number),
                key: ValueKey(e?.number),
                style: SleeveType.index(u, color: color),
              ),
            ),
          ),
        ),
      );
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: cells);
  }
}

/// Record (joined under the index) and the etched settings cell.
class RecordRow extends StatelessWidget {
  const RecordRow({super.key, this.joined = true, this.framed = true});

  /// Joined under the index bar (shares its bottom rule).
  final bool joined;

  /// Hairline frame around the cells (off when the row sits in a ruled band).
  final bool framed;

  @override
  Widget build(BuildContext context) {
    final t = context.watch<TakeState>();
    final f = context.watch<GenerateForm>();
    final u = SleeveScale.of(context);
    final busy = t.mode == TakeMode.recording || t.mode == TakeMode.waiting;
    final shown = t.sheetSong;
    // Ready whenever there is something to record; without an engine, Record routes to setup.
    final ready = f.hasWords;
    final next = Catalogue.format(t.nextNumber);
    final n = f.variants;
    // While a song is shown, the first cell opens the draft; while drafting, it records it.
    final label = shown != null ? 'NEW $next' : '${busy ? 'QUEUE' : 'RECORD'} ${n > 1 ? '$next +${n - 1}' : next}';
    final sides = framed ? CellSides(top: !joined) : const CellSides.none();
    final summary = f.summary.split(' · ');
    final small = SleeveType.etched(u, size: 11, color: Sleeve.inkSoft);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 2,
          child: Cell(
            block: shown == null && ready && !busy,
            sides: sides,
            onTap: shown != null ? t.draft : () => record(context),
            semanticLabel: shown != null ? 'New song, $next' : label,
            alignment: Alignment.centerLeft,
            padding: EdgeInsets.only(left: 18 * u, right: 8 * u),
            minHeight: 0,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: SleeveType.etched(u, size: 15, color: ready || shown != null ? Sleeve.ink : Sleeve.inkMute, weight: FontWeight.w500),
            ),
          ),
        ),
        Expanded(
          flex: 1,
          child: Cell(
            sides: framed ? CellSides(top: !joined, left: false) : const CellSides(left: true, top: false, right: false, bottom: false),
            onTap: () => showRecordSheet(context),
            tooltip: 'Recording settings',
            semanticLabel: 'Recording settings: ${f.summary}',
            minHeight: 0,
            padding: EdgeInsets.symmetric(horizontal: 6 * u),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Quality, then length and time: shrinks to fit rather than losing the time.
                FittedBox(fit: BoxFit.scaleDown, child: Text(summary.first, maxLines: 1, softWrap: false, style: small)),
                FittedBox(fit: BoxFit.scaleDown, child: Text(summary.skip(1).join(' · '), maxLines: 1, softWrap: false, style: small)),
              ],
            ),
          ),
        ),
        // Reuse the shown song's words, or clear the draft for a song from scratch.
        Expanded(
          flex: 1,
          child: Cell(
            sides: framed ? CellSides(top: !joined, left: false) : const CellSides(left: true, top: false, right: false, bottom: false),
            onTap: shown != null ? () => reuseSong(context, shown) : (ready ? () => clearDraft(context) : null),
            tooltip: shown != null ? 'Write a new song from these words' : 'Clear the sheet',
            semanticLabel: shown != null ? 'Reuse' : 'Clear',
            minHeight: 0,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                GlyphIcon(shown != null ? Glyph.reuse : Glyph.close, size: math.max(16, 20 * u), color: Sleeve.inkSoft),
                SizedBox(width: 8 * u),
                Text(
                  shown != null ? 'REUSE' : 'CLEAR',
                  style: SleeveType.etched(u, size: 13, color: shown != null || ready ? Sleeve.ink : Sleeve.inkMute),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Queue the song(s) from the sheet, or say what is missing and where to fix it.
Future<void> record(BuildContext context) async {
  final f = context.read<GenerateForm>();
  final studio = context.read<Studio>();
  if (studio.engine == null) {
    showLine(context, 'No engine yet · open setup', error: true);
    openSetup(context);
    return;
  }
  if (!f.canSubmit) {
    showLine(context, 'Write a style or lyrics first', error: true);
    return;
  }
  try {
    await f.submit();
    if (context.mounted) context.read<TakeState>().listen();
  } catch (e) {
    if (context.mounted) showLine(context, 'Could not queue: ${shortError(e)}', error: true);
  }
}

/// Blank the draft for a song from scratch, with a way back.
void clearDraft(BuildContext context) {
  final f = context.read<GenerateForm>();
  final was = f.clearWords();
  showLine(context, 'Sheet cleared', action: 'Undo', onAction: () => f.restoreWords(was));
}

/// Phone: back to the whole catalogue, which sits under the studio (the back gesture goes there too).
class _AllButton extends StatelessWidget {
  const _AllButton();

  @override
  Widget build(BuildContext context) {
    final u = SleeveScale.of(context);
    return Cell(
      frame: false,
      onTap: () => openCatalogue(context),
      tooltip: 'Whole catalogue',
      semanticLabel: 'All songs',
      padding: EdgeInsets.only(left: 4 * u, right: 12 * u),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlyphIcon(Glyph.back, size: 22, color: Sleeve.inkSoft),
          SizedBox(width: 2 * u),
          Text('ALL', style: SleeveType.etched(u, size: 13, color: Sleeve.ink)),
        ],
      ),
    );
  }
}

/// The queue as a ruled list, ranked by time. A row's state restyles it in place.
class QueueList extends StatelessWidget {
  const QueueList({super.key});

  @override
  Widget build(BuildContext context) {
    final q = context.watch<JobQueue>();
    final lib = context.read<TakeState>().library;
    final u = SleeveScale.of(context);
    final items = [?q.running, ...q.queued, ...q.recentSongs];
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Etched('Queue', size: 12, color: Sleeve.inkMute)),
            if (q.recent.isNotEmpty)
              Cell(
                frame: false,
                onTap: q.clearRecent,
                minHeight: 40,
                padding: EdgeInsets.symmetric(horizontal: 8 * u),
                child: Etched('Clear', size: 12, color: Sleeve.inkSoft),
              ),
          ],
        ),
        SizedBox(height: 6 * u),
        const Rule(),
        for (final s in items) ...[
          _QueueRow(s, number: lib.number(s), title: lib.titleOf(s), live: q.live[s.id], key: ValueKey(s.id)),
          const Rule(color: Sleeve.ruleFaint),
        ],
      ],
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow(this.song, {super.key, required this.number, required this.title, required this.live});

  final String title;

  final Song song;
  final int? number;
  final LiveJob? live;

  @override
  Widget build(BuildContext context) {
    final q = context.read<JobQueue>();
    final u = SleeveScale.of(context);
    final st = song.status;
    final running = st == SongStatus.running;
    final failed = st == SongStatus.failed || st == SongStatus.interrupted || st == SongStatus.cancelled;
    final state = switch (st) {
      SongStatus.running => live?.fraction != null ? '${(live!.fraction! * 100).round()}%' : 'REC',
      SongStatus.queued => 'QUEUED',
      SongStatus.done => formatDuration(song.seconds),
      SongStatus.failed => 'FAILED',
      SongStatus.cancelled => 'STOPPED',
      SongStatus.interrupted => 'STOPPED',
    };
    Widget? act;
    if (st == SongStatus.queued) {
      act = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlyphButton(Glyph.up, tooltip: 'Earlier', size: 18, onTap: () => q.moveUp(song)),
          GlyphButton(Glyph.close, tooltip: 'Remove from queue', size: 18, onTap: () => q.cancel(song)),
        ],
      );
    } else if (running) {
      act = GlyphButton(Glyph.close, tooltip: 'Stop', size: 18, onTap: () => q.cancel(song));
    } else if (song.resumable) {
      act = GlyphButton(Glyph.rerender, tooltip: 'Resume', size: 18, onTap: () => q.resume(song));
    } else {
      act = GlyphButton(Glyph.minus, tooltip: 'Dismiss', size: 18, color: Sleeve.inkMute, onTap: () => q.dismiss(song));
    }
    return Cell(
      frame: false,
      onTap: song.status == SongStatus.done ? () => openSong(context, song) : null,
      minHeight: 52,
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          SizedBox(
            width: 96 * u + 24,
            child: Text(
              Catalogue.format(number),
              style: SleeveType.value(u, size: 14, color: running ? Sleeve.red : (failed ? Sleeve.inkMute : Sleeve.ink)),
            ),
          ),
          Expanded(
            child: Tooltip(
              message: song.error ?? '',
              child: Text(
                failed && song.error != null ? shortError(song.error!) : title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: SleeveType.body(u, color: failed ? Sleeve.inkSoft : Sleeve.ink).copyWith(fontSize: 15 * u + 2),
              ),
            ),
          ),
          SizedBox(width: 12 * u),
          SizedBox(
            width: 70 * u + 12,
            child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            if (failed) ...[const HollowMark(), const SizedBox(width: 6)],
            Flexible(child: Text(state, textAlign: TextAlign.right, style: SleeveType.etched(u, size: 12, color: failed ? Sleeve.inkMute : Sleeve.inkSoft))),
          ]),
          ),
          act,
        ],
      ),
    );
  }
}

/// The first line of an engine error, without stack noise, short enough for one row.
String shortError(Object e) {
  var s = e.toString().replaceFirst(RegExp(r'^(Exception|StateError|Bad state|SidecarError)[: ]+'), '').trim();
  final nl = s.indexOf('\n');
  if (nl > 0) s = s.substring(0, nl);
  return s.length > 90 ? '${s.substring(0, 87)}…' : s;
}
