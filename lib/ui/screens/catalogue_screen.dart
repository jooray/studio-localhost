import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/library/catalogue.dart';
import '../../core/library/envelopes.dart';
import '../../core/library/song.dart';
import '../../core/paths.dart';
import '../../core/player.dart';
import '../../state/library_view.dart';
import '../frame.dart';
import '../routes.dart';
import '../theme.dart';
import '../widgets/polar_plot.dart';
import '../widgets/sleeve.dart';

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
            child: songs.isEmpty
                ? Padding(
                    padding: EdgeInsets.all(25 * u),
                    child: Etched(v.filter.isEmpty ? 'No entries yet. Record one from the studio.' : 'Nothing matches.', size: 12, maxLines: 3),
                  )
                : ListView.builder(
                    itemCount: songs.length,
                    itemExtent: 104,
                    itemBuilder: (_, i) => CatalogueRow(songs[i], key: ValueKey(songs[i].dir)),
                  ),
          ),
        ]);
      }),
    );
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
          semanticLabel: '${Catalogue.format(n)}, ${song.style}',
          padding: EdgeInsets.only(left: 18 * u, right: 4 * u),
          child: Row(children: [
            SizedBox.square(
              dimension: 76,
              child: PolarPlot(envelope: env, mini: true, seed: song.codeSeed),
            ),
            SizedBox(width: 18 * u),
            Expanded(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text(Catalogue.format(n), style: SleeveType.value(u, size: 15, color: running ? Sleeve.red : Sleeve.ink)),
                  SizedBox(width: 14 * u),
                  SizedBox(width: 56, child: CodeStripView(song.codeSeed, height: 7)),
                ]),
                const SizedBox(height: 8),
                Text(
                  song.style.isEmpty ? song.title : song.style,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SleeveType.body(u, color: Sleeve.inkSoft).copyWith(fontSize: 15, height: 1.2),
                ),
              ]),
            ),
            SizedBox(width: 10 * u),
            Text(status, style: SleeveType.etched(u, size: 12, color: song.status == SongStatus.failed ? Sleeve.red : Sleeve.inkSoft)),
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
