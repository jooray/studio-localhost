import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/jobs/job_queue.dart';
import '../core/library/catalogue.dart';
import '../core/library/library.dart';
import '../core/library/song.dart';
import '../core/paths.dart';
import '../state/nav.dart';
import 'routes.dart';
import 'theme.dart';
import 'widgets/sleeve.dart';

double indexColumnWidth(double width) => width >= 840 ? 300 : 232;

/// Wide windows (unfolded foldable, tablet, desktop): the catalogue index as a left column of
/// numbered entries, the page beside it. Phones get the page alone.
class AdaptiveFrame extends StatelessWidget {
  const AdaptiveFrame({super.key, required this.child, this.studio = true});

  final Widget child;

  /// The studio is the page (the Record entry is framed).
  final bool studio;

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    if (w < 600) return child;
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(width: indexColumnWidth(w), child: IndexColumn(studio: studio)),
      const Rule(vertical: true),
      Expanded(child: child),
    ]);
  }
}

class IndexColumn extends StatelessWidget {
  const IndexColumn({super.key, required this.studio});
  final bool studio;

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<Library>();
    final q = context.watch<JobQueue>();
    final nav = context.watch<AppNav>();
    final songs = lib.byCatalogue;
    final pad = MediaQuery.paddingOf(context);
    return SleeveScale(
      u: 1,
      child: Padding(
        padding: EdgeInsets.only(top: pad.top, bottom: pad.bottom, left: pad.left),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            height: 64,
            child: Row(children: [
              const SizedBox(width: 12),
              GlyphButton(Glyph.catalogue, tooltip: 'Catalogue', size: 22, color: Sleeve.inkSoft, onTap: () => openCatalogue(context)),
              const SizedBox(width: 4),
              const Expanded(child: Etched('Index', size: 12, color: Sleeve.inkMute)),
              GlyphButton(Glyph.menu, tooltip: 'Settings', size: 22, color: Sleeve.inkSoft, onTap: () => openSettings(context)),
              const SizedBox(width: 8),
            ]),
          ),
          const Rule(),
          Cell(
            sides: const CellSides(top: false, left: false, right: false),
            selected: studio,
            frame: studio,
            onTap: studio ? null : () => openStudio(context),
            minHeight: 56,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.only(left: 24, right: 12),
            semanticLabel: 'Studio',
            child: Text('${q.running != null ? 'QUEUE' : 'RECORD'} ${Catalogue.format(lib.catalogue.next)}',
                style: SleeveType.etched(1, size: 13, color: Sleeve.ink, weight: FontWeight.w500)),
          ),
          Expanded(
            child: songs.isEmpty
                ? const Padding(padding: EdgeInsets.all(24), child: Etched('No entries yet', size: 12, color: Sleeve.inkMute))
                : ListView.builder(
                    itemCount: songs.length,
                    itemExtent: 60,
                    itemBuilder: (_, i) => _IndexEntry(
                      songs[i],
                      number: lib.number(songs[i]),
                      selected: !studio && songs[i].id == nav.selectedSongId,
                    ),
                  ),
          ),
        ]),
      ),
    );
  }
}

class _IndexEntry extends StatelessWidget {
  const _IndexEntry(this.song, {required this.number, required this.selected});

  final Song song;
  final int? number;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final running = song.status == SongStatus.running;
    final queued = song.status == SongStatus.queued;
    final failed = song.status == SongStatus.failed || song.status == SongStatus.interrupted || song.status == SongStatus.cancelled;
    final color = running ? Sleeve.red : (queued || failed ? Sleeve.inkMute : Sleeve.ink);
    return Cell(
      active: running,
      selected: selected,
      frame: running || selected,
      onTap: () => openSong(context, song),
      semanticLabel: Catalogue.format(number),
      minHeight: 0,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(children: [
        SizedBox(width: 92, child: Text(Catalogue.format(number), style: SleeveType.value(1, size: 15, color: color))),
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(width: 64, child: CodeStripView(song.codeSeed, height: 7)),
          ),
        ),
        Text(
          switch (song.status) {
            SongStatus.done => formatDuration(song.seconds),
            SongStatus.running => 'REC',
            SongStatus.queued => 'QUEUED',
            _ => 'STOPPED',
          },
          style: SleeveType.etched(1, size: 11, color: running ? Sleeve.red : Sleeve.inkMute),
        ),
      ]),
    );
  }
}

/// A secondary page: back, an engraved title, optional actions, a rule, the content.
class SleevePage extends StatelessWidget {
  const SleevePage({super.key, required this.title, required this.child, this.actions = const [], this.maxWidth});

  final String title;
  final Widget child;
  final List<Widget> actions;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    final w = MediaQuery.sizeOf(context).width;
    final u = w < 600 ? (w / 576).clamp(0.62, 1.0) : 1.0;
    final canPop = Navigator.of(context).canPop();
    Widget content = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(height: w < 600 ? pad.top : 0),
      SizedBox(
        height: 64,
        child: Row(children: [
          SizedBox(width: 6 * u),
          if (canPop) GlyphButton(Glyph.back, tooltip: 'Back', size: 22, onTap: () => Navigator.of(context).maybePop()),
          SizedBox(width: canPop ? 4 : 24 * u),
          Expanded(child: Etched(title, size: 13, color: Sleeve.ink)),
          ...actions,
          SizedBox(width: 6 * u),
        ]),
      ),
      const Rule(),
      Expanded(child: child),
    ]);
    if (maxWidth != null) {
      content = Align(alignment: Alignment.topLeft, child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth!), child: content));
    }
    return Scaffold(
      body: SleeveScale(
        u: u,
        child: AdaptiveFrame(studio: false, child: w < 600 ? content : SafeArea(left: false, child: content)),
      ),
    );
  }
}
