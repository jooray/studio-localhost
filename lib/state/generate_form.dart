import 'package:flutter/widgets.dart';

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
    steps = (f['steps'] as num?)?.toInt() ?? 32;
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
    final p = s.params;
    style.text = s.style;
    lyrics.text = s.lyrics;
    title.clear();
    if (stepChoices.contains(s.steps)) steps = s.steps!;
    if (s.precision != null && precisions.contains(s.precision)) precision = s.precision!;
    final max = p['max_seconds'];
    if (max is num && max < maxLength) {
      limitLength = true;
      maxSeconds = max.toDouble();
    } else {
      limitLength = false;
    }
    if (modes.contains(s.mode)) mode = s.mode;
    instrumental = s.instrumental;
    // A score only travels when the user wrote it (it is in the request, not planned by the model).
    final userAbc = p['abc'];
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
      studio.engine != null && (style.text.trim().isNotEmpty || lyrics.text.trim().isNotEmpty);

  /// The etched one-line summary of the recording settings.
  String get summary => [
        '$steps STEPS',
        limitLength ? formatDuration(maxSeconds) : 'FULL',
        if (variants > 1) '×$variants',
      ].join(' · ');

  void randomizeSeed() => update(() => seed.text = '${randomSeed()}');

  /// Queue the song (or [variants] songs with consecutive seeds). Returns a short message.
  Future<String> submit() async {
    final s0 = (sameSeed ? reuseSeed : null) ?? int.tryParse(seed.text.trim()) ?? randomSeed();
    // A title typed before recording is the user's; otherwise one is derived from the words.
    final named = title.text.trim().isNotEmpty;
    final base = named
        ? title.text.trim()
        : (deriveTitle(lyrics: lyrics.text, style: style.text, instrumental: instrumental) ?? 'Untitled');
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
    for (var i = 0; i < n; i++) {
      final s = s0 + i;
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
