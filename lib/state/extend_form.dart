import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../core/jobs/job_queue.dart';
import '../core/library/library.dart';
import '../core/library/song.dart';
import '../core/studio.dart';
import 'seeds.dart';

/// Extend screen state: the source song, the section to continue from and the prompt.
class ExtendForm extends ChangeNotifier {
  ExtendForm(this.studio, this.queue, this.library);

  final Studio studio;
  final JobQueue queue;
  final Library library;
  String? sourceId;
  double sectionStart = 0;
  double sectionEnd = 1;
  bool natural = false;
  double add = 30;
  final style = TextEditingController();
  final lyrics = TextEditingController();
  final seed = TextEditingController(text: '${randomSeed()}');
  String mode = 'off';
  bool reuseScore = true;
  int steps = 32;
  String precision = '8bit';
  double crossfade = 2.0;

  void update(void Function() f) {
    f();
    notifyListeners();
  }

  List<Song> get candidates => library.songs.where((s) => s.status == SongStatus.done && s.hasTokens && s.hasAudio).toList();
  Song? get source => library.byId(sourceId);
  List<String> get modes => studio.model?.features.planningModes ?? const [];
  List<int> get stepChoices => studio.model?.limits.steps ?? const [32];
  List<String> get precisions => studio.engineDescriptor?.precisions ?? const [];
  double get sectionLength => sectionEnd - sectionStart;
  double get finalLength => source == null ? 0 : sectionStart + sectionLength + (natural ? 0 : add);

  void pick(Song s) {
    final dur = s.seconds;
    sourceId = s.id;
    sectionStart = math.max(0, dur - 30);
    sectionEnd = dur;
    style.text = s.style;
    lyrics.text = s.lyrics;
    mode = modes.contains(s.mode) ? s.mode : (modes.isEmpty ? '' : modes.last);
    reuseScore = s.abc != null;
    steps = stepChoices.contains(s.steps) ? s.steps! : stepChoices.last;
    precision = s.precision ?? precision;
    notifyListeners();
  }

  /// Pick up a hand-off from the Library, or default to the newest song.
  void ensureSource(String? handoff) {
    if (handoff != null && handoff != sourceId) {
      final s = library.byId(handoff);
      if (s != null) pick(s);
      return;
    }
    if (source == null && candidates.isNotEmpty) pick(candidates.first);
  }

  void setSection(double a, double b) => update(() {
        if (b - a >= 1) {
          sectionStart = a;
          sectionEnd = b;
        }
      });

  void lastSeconds(double s) => update(() {
        final d = source?.seconds ?? 0;
        sectionStart = math.max(0, d - s);
        sectionEnd = d;
      });

  Future<String> submit() async {
    final s = source!;
    final sd = int.tryParse(seed.text) ?? randomSeed();
    final atEnd = (sectionEnd - s.seconds).abs() < 0.05;
    await queue.submit('${s.title.replaceAll(RegExp(r' \((extended|re-render)\)$'), '')} (extended)', {
      'kind': 'extend',
      'parent': s.id,
      'source_dir': s.dir,
      'params': {
        'style': style.text,
        'lyrics': lyrics.text,
        'mode': mode,
        'reuse_score': reuseScore,
        'seed': sd,
        'steps': steps,
        if (precisions.isNotEmpty) 'precision': precisions.contains(precision) ? precision : precisions.first,
      },
      'extend': {
        'section_start': double.parse(sectionStart.toStringAsFixed(2)),
        'section_end': atEnd ? null : double.parse(sectionEnd.toStringAsFixed(2)),
        'section_seconds': double.parse(sectionLength.toStringAsFixed(2)),
        'add_seconds': natural ? null : add.round(),
        'crossfade': crossfade,
      },
    });
    update(() => seed.text = '${sd + 1}');
    return 'Extension queued';
  }

  /// Desktop engines that can tokenize audio: continue an outside recording (its last 30 s).
  Future<String> submitExternal(String path) async {
    final sd = int.tryParse(seed.text) ?? randomSeed();
    await queue.submit('${p.basenameWithoutExtension(path)} (extended)', {
      'kind': 'extend',
      'params': {'style': style.text, 'lyrics': lyrics.text, 'mode': 'off', 'seed': sd, 'steps': steps},
      'extend': {'source_audio': path, 'section_seconds': 30, 'add_seconds': natural ? null : add.round(), 'crossfade': crossfade},
    });
    return 'External extension queued';
  }

  @override
  void dispose() {
    style.dispose();
    lyrics.dispose();
    seed.dispose();
    super.dispose();
  }
}
