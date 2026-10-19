import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../core/jobs/job_queue.dart';
import '../core/library/catalogue.dart';
import '../core/library/song.dart';
import '../core/paths.dart';
import '../core/studio.dart';
import 'lyric_controller.dart';
import 'seeds.dart';

/// Generate screen state: the form values and submitting them as one or more queued songs.
class GenerateForm extends ChangeNotifier {
  GenerateForm(this.studio, this.queue) {
    final f = studio.settings.lastForm;
    title.text = f['title'] as String? ?? '';
    style.text = f['style'] as String? ?? 'pop, upbeat, female vocal, synthesizer, catchy melody, bright';
    lyrics.text = f['lyrics'] as String? ??
        '[Verse]\nCity lights are humming low\nEvery window starts to glow\n\n[Chorus]\nSing it out, the night is young\nEvery song is still unsung\n';
    instrumental = f['instrumental'] as bool? ?? false;
    mode = f['mode'] as String? ?? 'full';
    precision = f['precision'] as String? ?? '8bit';
    steps = (f['steps'] as num?)?.toInt() ?? studio.model?.limits.defaultSteps ?? 32;
    // A phone takes hours per song at full quality: slow devices start on the sketch preset
    // (once, so a later choice of the user sticks).
    // Decided once the engine is known (it may not be yet at the very first start).
    final engine = studio.engineDescriptor;
    if (!studio.settings.presetsIntroduced && engine != null && stepChoices.isNotEmpty) {
      if (engine.runtime != 'mlx') steps = stepChoices.first;
      studio.settings.presetsIntroduced = true;
    }
    limitLength = f['limitLength'] as bool? ?? true;
    maxSeconds = (f['maxSeconds'] as num?)?.toDouble() ?? 120;
    seed.text = '${f['seed'] ?? randomSeed()}';
    abc.text = f['abc'] as String? ?? '';
    showAbc = abc.text.isNotEmpty;
    _baseline();
    for (final c in [style, lyrics]) {
      c.addListener(_edited);
    }
  }

  /// "From LRS-010": the song this draft was reused from, until the user records or edits.
  String? fromLabel;

  /// The source song's seed, for the "same seed" choice in the record sheet.
  int? reuseSeed;
  bool sameSeed = false;

  String _baseStyle = '', _baseLyrics = '';

  void _baseline() {
    _baseStyle = style.text;
    _baseLyrics = lyrics.text;
  }

  void _edited() {
    if (fromLabel != null && (style.text != _baseStyle || lyrics.text != _baseLyrics)) {
      fromLabel = null;
      reuseSeed = null;
      sameSeed = false;
    }
    notifyListeners();
  }

  /// The words differ from what was last recorded or reused (an unsaved draft).
  bool get hasDraft => style.text != _baseStyle || lyrics.text != _baseLyrics;

  /// Start a new song from another one's prompt: words and settings, a new seed, no title.
  void reuse(Song s, {required String label}) {
    final params = s.params;
    style.text = s.style;
    lyrics.text = s.lyrics;
    title.clear();
    if (stepChoices.contains(s.steps)) steps = s.steps!;
    if (s.precision != null && precisions.contains(s.precision)) precision = s.precision!;
    final max = params['max_seconds'];
    if (max is num && max < maxLength) {
      limitLength = true;
      maxSeconds = max.toDouble();
    } else {
      limitLength = false;
    }
    if (modes.contains(s.mode)) mode = s.mode;
    instrumental = s.instrumental;
    // A cover brings its recording along (the copy in its folder) and what it kept of it.
    final source = s.kind == 'cover' ? s.coverSourcePath : null;
    if (source != null && File(source).existsSync()) {
      coverPath = source;
      coverName = s.cover['source_name'] as String? ?? p.basename(source);
      coverMode = params['mode'] == 'melody' ? 'melody' : 'full';
      coverStyle = s.styleStrength;
    } else {
      coverPath = coverName = null;
    }
    // A score only travels when the user wrote it (it is in the request, not planned by the model).
    final userAbc = params['abc'];
    abc.text = userAbc is String ? userAbc : '';
    showAbc = abc.text.trim().isNotEmpty;
    final m = s.modelId;
    if (m != null && studio.registry.byId(m) != null && studio.model?.id != m) studio.selectModel(m);
    seed.text = '${randomSeed()}';
    reuseSeed = s.seed;
    sameSeed = false;
    fromLabel = label;
    _baseline();
    notifyListeners();
  }

  /// Blank the words for a new song from scratch. Returns what was there, for undo.
  Map<String, String> clearWords() {
    final was = {'title': title.text, 'style': style.text, 'lyrics': lyrics.text, 'abc': abc.text};
    for (final c in [title, style, lyrics, abc]) {
      c.clear();
    }
    fromLabel = null;
    reuseSeed = null;
    sameSeed = false;
    notifyListeners();
    return was;
  }

  void restoreWords(Map<String, String> was) {
    title.text = was['title'] ?? '';
    style.text = was['style'] ?? '';
    lyrics.text = was['lyrics'] ?? '';
    abc.text = was['abc'] ?? '';
    showAbc = abc.text.trim().isNotEmpty;
    notifyListeners();
  }

  final Studio studio;
  final JobQueue queue;
  final title = TextEditingController();
  final style = TextEditingController();
  final lyrics = LyricController();
  final abc = TextEditingController();
  final seed = TextEditingController();
  bool instrumental = false;
  String mode = 'full';
  String precision = '8bit';
  int steps = 32;
  bool limitLength = true;
  double maxSeconds = 120;
  int variants = 1;
  bool showAbc = false;

  /// A cover: the recording whose tune the next song takes (null: a song from the words alone).
  String? coverPath;

  /// The recording's own name (a reused cover's copy is called work/cover-source.*).
  String? coverName;

  String? get coverLabel => coverPath == null ? null : (coverName ?? p.basename(coverPath!));

  /// full: the recording's melody and chords; melody: its melody alone.
  String coverMode = 'full';

  /// A cover's style strength: how hard the style and words pull against the recording's score
  /// (1: evenly; the engine's classifier-free guidance scale).
  double coverStyle = 1.0;
  static const coverStyleRange = (min: 0.5, max: 2.0);

  bool get covering => coverPath != null;

  void update(void Function() f) {
    f();
    notifyListeners();
  }

  List<String> get modes => studio.model?.features.planningModes ?? const [];
  List<int> get stepChoices => studio.model?.limits.steps ?? const [32];
  List<String> get precisions => studio.engineDescriptor?.precisions ?? const [];
  double get maxLength => studio.model?.limits.maxSeconds ?? 360;

  String get effectiveMode => instrumental ? 'off' : (modes.contains(mode) ? mode : (modes.isEmpty ? '' : modes.first));
  /// There is something to record (style or lyrics).
  bool get hasWords => style.text.trim().isNotEmpty || lyrics.text.trim().isNotEmpty;

  bool get canSubmit =>
      studio.engine != null && (style.text.trim().isNotEmpty || lyrics.text.trim().isNotEmpty) && (!covering || studio.coverReady);

  /// Quality presets over the model's step choices: fewest steps a sketch, most the final.
  String? presetOf(int s) {
    final c = stepChoices;
    final i = c.indexOf(s);
    if (c.length < 2 || i < 0) return null;
    return i == 0 ? 'sketch' : (i == c.length - 1 ? 'final' : 'standard');
  }

  /// The length that will be recorded (the cap, or the model's full length).
  double get lengthSeconds => limitLength ? maxSeconds : maxLength;

  /// How long recording at [s] steps would take on this device (all takes).
  Duration estimateFor(int s) =>
      queue.estimate(
        seconds: lengthSeconds,
        steps: s,
        precision: precisions.contains(precision) ? precision : null,
        guided: covering && (coverStyle - 1).abs() > 1e-6,
      ) *
      variants;

  /// The etched summary of the recording settings: quality, then length and time.
  String get summary => [
        if (covering) 'COVER',
        if (covering && coverStyle != 1.0) 'STYLE ${coverStyle.toStringAsFixed(1)}',
        presetOf(steps)?.toUpperCase() ?? '$steps STEPS',
        limitLength ? formatDuration(maxSeconds) : 'FULL',
        formatEstimate(estimateFor(steps)),
        if (variants > 1) '×$variants',
      ].join(' · ');

  void randomizeSeed() => update(() => seed.text = '${randomSeed()}');

  /// Queue the song (or [variants] songs with consecutive seeds). Returns a short message.
  Future<String> submit() async {
    final s0 = (sameSeed ? reuseSeed : null) ?? int.tryParse(seed.text.trim()) ?? randomSeed();
    // A title typed before recording is the user's; otherwise one is derived from the words.
    final named = title.text.trim().isNotEmpty;
    final cover = coverPath;
    final base = named
        ? title.text.trim()
        : (deriveTitle(lyrics: lyrics.text, style: style.text, instrumental: instrumental && cover == null) ??
            (cover != null ? '${p.basenameWithoutExtension(coverLabel!)} (cover)' : 'Untitled'));
    studio.settings.lastForm = {
      'title': title.text,
      'style': style.text,
      'lyrics': lyrics.text,
      'instrumental': instrumental,
      'mode': mode,
      'precision': precision,
      'steps': steps,
      'limitLength': limitLength,
      'maxSeconds': maxSeconds,
      'seed': s0,
      'abc': abc.text,
    };
    final features = studio.model!.features;
    final n = variants;
    // A cover sings the recording's score with these words: its copy goes into the song folder,
    // where the engine transcribes it (once; a stopped job keeps the score).
    final coverSource = cover == null ? null : 'work/cover-source${p.extension(cover).toLowerCase()}';
    final transcriber = studio.coverAddon?.file('transcriber');
    // Takes of one cover share one transcription: the later ones take the first one's score.
    String? scoreFrom;
    for (var i = 0; i < n; i++) {
      final s = s0 + i;
      if (cover != null) {
        final song = await queue.submit(n > 1 ? '$base #${i + 1}' : base, {
          'kind': 'cover',
          'title_user': named,
          'params': {
            'style': style.text.trim(),
            'lyrics': lyrics.text,
            'mode': coverMode,
            'cfg_scale': coverStyle,
            'seed': s,
            'steps': steps,
            if (precisions.isNotEmpty) 'precision': precisions.contains(precision) ? precision : precisions.first,
            'max_seconds': limitLength ? maxSeconds.round() : maxLength.round(),
          },
          'cover': {
            'source_audio': coverSource,
            'source_name': coverLabel,
            if (transcriber != null) 'transcriber': studio.modelFilePath(transcriber),
            'score_from': ?scoreFrom,
          },
        }, prepare: (song) async {
          final dest = File(p.join(song.dir, coverSource!));
          await dest.parent.create(recursive: true);
          await File(cover).copy(dest.path);
        });
        scoreFrom ??= song.dir;
        continue;
      }
      await queue.submit(n > 1 ? '$base #${i + 1}' : base, {
        'kind': 'generate',
        'title_user': named,
        'params': {
          'style': style.text.trim(),
          'lyrics': lyrics.text,
          'instrumental': instrumental && features.instrumental,
          'mode': effectiveMode,
          'seed': s,
          'steps': steps,
          if (precisions.isNotEmpty) 'precision': precisions.contains(precision) ? precision : precisions.first,
          'max_seconds': limitLength ? maxSeconds.round() : maxLength.round(),
          if (features.abcScore && showAbc && abc.text.trim().isNotEmpty && effectiveMode != 'off') 'abc': abc.text,
        },
      });
    }
    update(() {
      seed.text = '${s0 + n}';
      title.clear();
      coverPath = coverName = null;
      fromLabel = null;
      reuseSeed = null;
      sameSeed = false;
      _baseline();
    });
    return n > 1 ? 'Queued $n variants' : 'Queued "$base"';
  }

  @override
  void dispose() {
    for (final c in [title, style, lyrics, abc, seed]) {
      c.dispose();
    }
    super.dispose();
  }
}
