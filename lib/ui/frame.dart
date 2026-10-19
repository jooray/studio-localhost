import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/library/catalogue.dart';
import '../core/library/library.dart';
import '../core/library/song.dart';
import '../core/paths.dart';
import '../state/nav.dart';
import '../state/take.dart';
import 'routes.dart';
import 'theme.dart';
import 'widgets/sleeve.dart';
import 'widgets/song_actions.dart';

double indexColumnWidth(double width) => width >= 840 ? 300 : 232;

/// Height of the band above the first cross-column rule on the wide studio; the index column's
/// header matches it so the rules line up. Secondary pages use [pageHeaderHeight].
const double wideTopBand = 124;
const double pageHeaderHeight = 64;

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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: indexColumnWidth(w),
          child: IndexColumn(studio: studio, header: studio ? wideTopBand : pageHeaderHeight),
        ),
        const Rule(vertical: true),
        Expanded(child: child),
      ],
    );
  }
}

class IndexColumn extends StatelessWidget {
  const IndexColumn({super.key, required this.studio, this.header = pageHeaderHeight});
  final bool studio;

  /// Header height, matching the first rule of the page beside it.
  final double header;

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<Library>();
    final nav = context.watch<AppNav>();
    final take = context.watch<TakeState>();
    final songs = lib.byCatalogue;
    final pad = MediaQuery.paddingOf(context);
    return SleeveScale(
      u: 1,
      child: Padding(
        padding: EdgeInsets.only(top: pad.top, bottom: pad.bottom, left: pad.left),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: header,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: pageHeaderHeight,
                    child: Row(
                      children: [
                        const SizedBox(width: 12),
                        GlyphButton(
                          Glyph.catalogue,
                          tooltip: 'Catalogue',
                          size: 22,
                          color: Sleeve.inkSoft,
                          onTap: () => openCatalogue(context),
                        ),
                        const SizedBox(width: 4),
                        const Expanded(child: Etched('Index', size: 12, color: Sleeve.inkMute)),
                        GlyphButton(Glyph.menu, tooltip: 'Settings', size: 22, color: Sleeve.inkSoft, onTap: () => openSettings(context)),
                        const SizedBox(width: 8),
                      ],
                    ),
                  ),
                  if (header > pageHeaderHeight)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 6, 16, 0),
                      child: Etched(
                        '${songs.length} entries · next ${Catalogue.format(lib.catalogue.next)}',
                        size: 11,
                        color: Sleeve.inkMute,
                      ),
                    ),
                ],
              ),
            ),
            const Rule(),
            Expanded(
              child: songs.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Etched('No entries yet', size: 12, color: Sleeve.inkMute),
                    )
                  : ListView.builder(
                      itemCount: songs.length,
                      itemExtent: 64,
                      itemBuilder: (_, i) => _IndexEntry(
                        songs[i],
                        number: lib.number(songs[i]),
                        title: lib.titleOf(songs[i]),
                        selected: studio ? songs[i].id == take.current?.id : songs[i].id == nav.selectedSongId,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IndexEntry extends StatelessWidget {
  const _IndexEntry(this.song, {required this.number, required this.title, required this.selected});

  final Song song;
  final int? number;
  final String title;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final running = song.status == SongStatus.running;
    final queued = song.status == SongStatus.queued;
    final failed = song.status == SongStatus.failed || song.status == SongStatus.interrupted || song.status == SongStatus.cancelled;
    final numColor = running ? Sleeve.red : Sleeve.inkMute;
    final named = title != Catalogue.format(number);
    return Cell(
      active: running,
      selected: selected,
      frame: running || selected,
      onTap: () => openSong(context, song),
      onLongPress: () => songMenu(context, song),
      semanticLabel: '$title, ${Catalogue.format(number)}',
      minHeight: 0,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // The title leads (Geist); the number, code and length follow in mono.
        Text(
          named ? title : Catalogue.format(number),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: named
              ? SleeveType.body(1, color: queued || failed ? Sleeve.inkMute : Sleeve.ink).copyWith(fontSize: 15, height: 1.2)
              : SleeveType.value(1, size: 14, color: running ? Sleeve.red : Sleeve.ink),
        ),
        const SizedBox(height: 5),
        Row(children: [
          if (named) ...[Text(Catalogue.format(number), style: SleeveType.value(1, size: 11, color: numColor)), const SizedBox(width: 10)],
          SizedBox(width: 48, child: CodeStripView(song.codeSeed, height: 5)),
          const Spacer(),
          if (failed) ...[const HollowMark(), const SizedBox(width: 6)],
          Text(switch (song.status) {
            SongStatus.done => formatDuration(song.seconds),
            SongStatus.running => 'REC',
            SongStatus.queued => 'QUEUED',
            SongStatus.failed => 'FAILED',
            _ => 'STOPPED',
          }, style: SleeveType.etched(1, size: 11, color: running ? Sleeve.red : Sleeve.inkMute)),
        ]),
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
    // Whether this page has one below it (the navigator as a whole can pop even on the first page).
    final canPop = ModalRoute.of(context)?.canPop ?? false;
    Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: w < 600 ? pad.top : 0),
        SizedBox(
          height: 64,
          child: Row(
            children: [
              SizedBox(width: 6 * u),
              if (canPop) GlyphButton(Glyph.back, tooltip: 'Back', size: 22, onTap: () => Navigator.of(context).maybePop()),
              SizedBox(width: canPop ? 4 : 24 * u),
              Expanded(child: Etched(title, size: 13, color: Sleeve.ink)),
              ...actions,
              SizedBox(width: 6 * u),
            ],
          ),
        ),
        const Rule(),
        Expanded(child: child),
      ],
    );
    if (maxWidth != null) {
      content = Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth!),
          child: content,
        ),
      );
    }
    return Scaffold(
      body: SleeveScale(
        u: u,
        child: AdaptiveFrame(studio: false, child: w < 600 ? content : SafeArea(left: false, child: content)),
      ),
    );
  }
}
