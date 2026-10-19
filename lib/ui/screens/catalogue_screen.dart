import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/library/catalogue.dart';
import '../../core/library/envelopes.dart';
import '../../core/library/song.dart';
import '../../core/paths.dart';
import '../../core/player.dart';
import '../../state/generate_form.dart';
import '../../state/library_view.dart';
import '../../state/take.dart';
import '../frame.dart';
import '../routes.dart';
import '../theme.dart';
import '../widgets/polar_plot.dart';
import '../widgets/sleeve.dart';
import '../widgets/song_actions.dart';

/// Every song as a numbered entry: its plot, number, style in one line, length and code strip.
class CatalogueScreen extends StatefulWidget {
  const CatalogueScreen({super.key});

  @override
  State<CatalogueScreen> createState() => _CatalogueScreenState();
}

class _CatalogueScreenState extends State<CatalogueScreen> {
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = context.watch<LibraryView>();
    final songs = v.songs;
    return SleevePage(
      title: 'Catalogue · ${songs.length}',
      actions: [GlyphButton(Glyph.rerender, tooltip: 'Rescan', size: 20, color: Sleeve.inkSoft, onTap: v.library.refresh)],
      child: Builder(builder: (context) {
        final u = SleeveScale.of(context);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: EdgeInsets.fromLTRB(25 * u, 14, 25 * u, 12),
            child: SleeveField(
              controller: _filter,
              style: SleeveType.value(u, size: 15),
              maxLines: 1,
              hint: 'FIND  ·  number, style or title',
              semanticLabel: 'Find',
              onChanged: v.setFilter,
            ),
          ),
          const Rule(color: Sleeve.ruleFaint),
          Expanded(
            child: Builder(builder: (context) {
              // The next number already has its sleeve: an empty disc at the head of the list.
              final blank = v.filter.isEmpty;
              final lead = blank ? 1 : 0;
              if (!blank && songs.isEmpty) {
                return Padding(padding: EdgeInsets.all(25 * u), child: Etched('Nothing matches.', size: 12, maxLines: 3));
              }
              return ListView.builder(
                // The page header already clears the status bar.
                padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
                itemCount: songs.length + lead,
                itemExtent: 104,
                itemBuilder: (_, i) => blank && i == 0 ? const NewEntryRow() : CatalogueRow(songs[i - lead], key: ValueKey(songs[i - lead].dir)),
              );
            }),
          ),
        ]);
      }),
    );
  }
}

/// The next catalogue number as an unrecorded sleeve: opens the studio on the draft.
class NewEntryRow extends StatelessWidget {
  const NewEntryRow({super.key});

  @override
  Widget build(BuildContext context) {
    final take = context.watch<TakeState>();
    final form = context.watch<GenerateForm>();
    final u = SleeveScale.of(context);
    final n = Catalogue.format(take.nextNumber);
    final seed = int.tryParse(form.seed.text) ?? 0;
    return Column(children: [
      Expanded(
        child: Cell(
          frame: false,
          onTap: () {
            take.draft();
            openStudio(context);
          },
          semanticLabel: 'New entry, $n',
          padding: EdgeInsets.only(left: 18 * u, right: 16 * u),
          child: Row(children: [
            SizedBox.square(dimension: 76, child: PolarPlot(envelope: null, mini: true, seed: seed)),
            SizedBox(width: 18 * u),
            Expanded(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  'New entry',
                  maxLines: 1,
                  style: SleeveType.body(u).copyWith(fontSize: 17, height: 1.2, fontWeight: FontWeight.w400),
                ),
                const SizedBox(height: 6),
                Row(children: [
                  Text(n, style: SleeveType.value(u, size: 12, color: Sleeve.inkSoft)),
                  SizedBox(width: 12 * u),
                  SizedBox(width: 48, child: CodeStripView(seed, height: 6)),
                  SizedBox(width: 12 * u),
                  Expanded(
                    child: Text(
                      form.hasWords ? 'draft in the studio' : 'blank',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: SleeveType.body(u, color: Sleeve.inkMute).copyWith(fontSize: 13, height: 1.2),
                    ),
                  ),
                ]),
              ]),
            ),
            GlyphIcon(Glyph.plus, size: 20, color: Sleeve.ink),
          ]),
        ),
      ),
      const Rule(color: Sleeve.ruleFaint),
    ]);
  }
}

class CatalogueRow extends StatelessWidget {
  const CatalogueRow(this.song, {super.key});

  final Song song;

  @override
  Widget build(BuildContext context) {
    final v = context.read<LibraryView>();
    final env = context.watch<Envelopes>().of(song);
    final pl = context.watch<AudioPlayerModel>();
    final u = SleeveScale.of(context);
    final n = v.library.number(song);
    final playing = song.audioPath != null && pl.path == song.audioPath && pl.playing;
    final running = song.status == SongStatus.running;
    final status = switch (song.status) {
      SongStatus.done => formatDuration(song.seconds),
      SongStatus.running => 'REC',
      SongStatus.queued => 'QUEUED',
      SongStatus.failed => 'FAILED',
      _ => 'STOPPED',
    };
    return Column(children: [
      Expanded(
        child: Cell(
          frame: running,
          active: running,
          onTap: () => openSong(context, song),
          onLongPress: () => songMenu(context, song),
          semanticLabel: '${v.titleOf(song)}, ${Catalogue.format(n)}',
          padding: EdgeInsets.only(left: 18 * u, right: 4 * u),
          child: Row(children: [
            SizedBox.square(
              dimension: 76,
              child: PolarPlot(envelope: env, mini: true, seed: song.codeSeed),
            ),
            SizedBox(width: 18 * u),
            Expanded(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                // Title leads in Geist; number and code follow in mono; the style is the quiet line.
                Text(
                  v.titleOf(song),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SleeveType.body(u).copyWith(fontSize: 17, height: 1.2, fontWeight: FontWeight.w400),
                ),
                const SizedBox(height: 6),
                Row(children: [
                  Text(Catalogue.format(n), style: SleeveType.value(u, size: 12, color: running ? Sleeve.red : Sleeve.inkSoft)),
                  SizedBox(width: 12 * u),
                  SizedBox(width: 48, child: CodeStripView(song.codeSeed, height: 6)),
                  SizedBox(width: 12 * u),
                  Expanded(
                    child: Text(
                      song.style,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: SleeveType.body(u, color: Sleeve.inkMute).copyWith(fontSize: 13, height: 1.2),
                    ),
                  ),
                ]),
              ]),
            ),
            SizedBox(width: 10 * u),
            if (song.status == SongStatus.failed) ...[const HollowMark(), const SizedBox(width: 6)],
            Text(status, style: SleeveType.etched(u, size: 12, color: song.status == SongStatus.failed ? Sleeve.inkMute : Sleeve.inkSoft)),
            GlyphButton(
              playing ? Glyph.pause : Glyph.play,
              tooltip: playing ? 'Pause' : 'Play',
              size: 20,
              onTap: song.hasAudio ? () => v.toggle(song) : null,
            ),
          ]),
        ),
      ),
      const Rule(color: Sleeve.ruleFaint),
    ]);
  }
}
