import 'package:flutter/widgets.dart';

import '../core/jobs/job_queue.dart';
import '../core/studio.dart';
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
    for (final c in [style, lyrics]) {
      c.addListener(notifyListeners);
    }
  }

  final Studio studio;
  final JobQueue queue;
  final title = TextEditingController();
  final style = TextEditingController();
  final lyrics = TextEditingController();
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
  bool get canSubmit =>
      studio.engine != null && (style.text.trim().isNotEmpty || lyrics.text.trim().isNotEmpty);

  void randomizeSeed() => update(() => seed.text = '${randomSeed()}');

  /// Queue the song (or [variants] songs with consecutive seeds). Returns a short message.
  Future<String> submit() async {
    final s0 = int.tryParse(seed.text.trim()) ?? randomSeed();
    final base = title.text.trim().isNotEmpty
        ? title.text.trim()
        : (style.text.split(',').first.trim().isEmpty ? 'Song' : style.text.split(',').first.trim());
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
    update(() => seed.text = '${s0 + n}');
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
