import 'package:flutter/foundation.dart';

import '../core/export.dart';
import '../core/jobs/job_queue.dart';
import '../core/library/catalogue.dart';
import '../core/library/library.dart';
import '../core/library/song.dart';
import '../core/player.dart';
import '../core/studio.dart';

/// Library screen state and song actions.
class LibraryView extends ChangeNotifier {
  LibraryView(this.studio, this.library, this.queue, this.player) : exporter = Exporter(studio);

  final Studio studio;
  final Library library;
  final JobQueue queue;
  final AudioPlayerModel player;
  final Exporter exporter;
  String filter = '';

  void setFilter(String v) {
    filter = v;
    notifyListeners();
  }

  List<Song> get songs => library.songs
      .where((s) =>
          filter.isEmpty ||
          '${library.titleOf(s)} ${Catalogue.format(library.number(s))} ${library.number(s) ?? ''} ${s.style}'
              .toLowerCase()
              .contains(filter.toLowerCase()))
      .toList();

  bool canExtend(Song s) => (studio.model?.features.extend ?? false) && s.status == SongStatus.done && s.hasTokens && s.hasAudio;
  bool canRerender(Song s) => (studio.model?.features.rerender ?? false) && s.status == SongStatus.done && s.hasTokens;

  /// One quiet line: the model and its licence.
  String modelLine(Song s) {
    final m = studio.registry.byId(s.modelId);
    final name = m?.name ?? s.modelId ?? 'unknown model';
    final lic = s.licenceId ?? m?.licence.spdx;
    return lic == null ? name : '$name · $lic';
  }

  /// Refine a finished mix: its saved latents pulled back a quarter of the way to noise, then the
  /// rest of a [steps] schedule (a quarter of the steps). Same seed: the path starts from the
  /// song's own noise.
  Future<void> refine(Song s, {required int steps}) => queue.submit(
        '${library.titleOf(s).replaceAll(RegExp(r' \((extended|re-render|refined)\)$'), '')} (refined)',
        {
          'kind': 'rerender',
          'title_user': library.hasUserTitle(s),
          'parent': s.id,
          'source_dir': s.dir,
          'params': {...s.params, 'steps': steps, 'refine': true, 'refine_t': refineT},
        },
      );

  static const refineT = 0.25;

  bool canRefine(Song s) => canRerender(s) && s.hasLatents && (s.steps ?? 32) < (studio.model?.limits.steps.last ?? 32);

  Future<void> rerender(Song s, {required int steps, required int seed}) => queue.submit(
        '${library.titleOf(s).replaceAll(RegExp(r' \((extended|re-render)\)$'), '')} (re-render)',
        {
          'kind': 'rerender',
          'title_user': library.hasUserTitle(s),
          'parent': s.id,
          'source_dir': s.dir,
          'params': {
            ...s.params,
            'seed': seed,
            'steps': steps,
            'refine': false,
          },
        },
      );

  Future<void> delete(Song s) async {
    await player.stopIf(s.dir);
    await library.delete(s);
  }

  Future<void> rename(Song s, String title) => library.rename(s, title);
  String titleOf(Song s) => library.titleOf(s);
  Future<void> resume(Song s) => queue.resume(s);
  Future<void> cancel(Song s) => queue.cancel(s);

  /// The heart: flip it. Liking also retires NEW for good, so unliking never brings it back.
  Future<void> like(Song s) => library.patch(s, {'liked': !s.liked, if (!s.played) 'played': true});

  void toggle(Song s) {
    final a = s.audioPath;
    if (a != null) player.toggle(a, title: library.fileTitle(s));
  }
}
