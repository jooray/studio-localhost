import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/jobs.dart';
import '../core/settings.dart';
import 'widgets.dart';

final _rng = Random();
int randomSeed() => _rng.nextInt(1 << 31);

class GeneratePage extends StatefulWidget {
  const GeneratePage({super.key});

  @override
  State<GeneratePage> createState() => _GeneratePageState();
}

class _GeneratePageState extends State<GeneratePage> {
  final _title = TextEditingController();
  final _style = TextEditingController();
  final _lyrics = TextEditingController();
  final _abc = TextEditingController();
  final _seed = TextEditingController();
  bool _instrumental = false;
  String _mode = 'full';
  String _precision = 'bf16';
  int _steps = 32;
  bool _limitLength = true;
  double _maxSeconds = 120;
  int _variants = 1;
  bool _showAbc = false;

  @override
  void initState() {
    super.initState();
    final f = context.read<Settings>().lastForm;
    _title.text = f['title'] as String? ?? '';
    _style.text = f['style'] as String? ?? 'pop, upbeat, female vocal, synthesizer, catchy melody, bright';
    _lyrics.text = f['lyrics'] as String? ??
        '[Verse]\nCity lights are humming low\nEvery window starts to glow\n\n[Chorus]\nSing it out, the night is young\nEvery song is still unsung\n';
    _instrumental = f['instrumental'] as bool? ?? false;
    _mode = f['mode'] as String? ?? 'full';
    _precision = f['precision'] as String? ?? 'bf16';
    _steps = (f['steps'] as num?)?.toInt() ?? 32;
    _limitLength = f['limitLength'] as bool? ?? true;
    _maxSeconds = (f['maxSeconds'] as num?)?.toDouble() ?? 120;
    _seed.text = '${f['seed'] ?? randomSeed()}';
    _abc.text = f['abc'] as String? ?? '';
    _showAbc = _abc.text.isNotEmpty;
  }

  @override
  void dispose() {
    for (final c in [_title, _style, _lyrics, _abc, _seed]) {
      c.dispose();
    }
    super.dispose();
  }

  String get _effectiveMode => _instrumental ? 'off' : _mode;

  void _submit() {
    final settings = context.read<Settings>();
    final q = context.read<JobQueue>();
    final seed = int.tryParse(_seed.text.trim()) ?? randomSeed();
    final base = _title.text.trim().isNotEmpty
        ? _title.text.trim()
        : (_style.text.split(',').first.trim().isEmpty ? 'Song' : _style.text.split(',').first.trim());
    settings.lastForm = {
      'title': _title.text,
      'style': _style.text,
      'lyrics': _lyrics.text,
      'instrumental': _instrumental,
      'mode': _mode,
      'precision': _precision,
      'steps': _steps,
      'limitLength': _limitLength,
      'maxSeconds': _maxSeconds,
      'seed': seed,
      'abc': _abc.text,
    };
    for (var i = 0; i < _variants; i++) {
      final s = seed + i;
      q.add('generate', _variants > 1 ? '$base #${i + 1} (seed $s)' : base, {
        'style': _style.text.trim(),
        'lyrics': _lyrics.text,
        'instrumental': _instrumental,
        'mode': _effectiveMode,
        'seed': s,
        'precision': _precision,
        'steps': _steps,
        if (_limitLength) 'max_seconds': _maxSeconds.round(),
        if (_showAbc && _abc.text.trim().isNotEmpty && _effectiveMode != 'off') 'abc': _abc.text,
      });
    }
    setState(() => _seed.text = '${seed + _variants}');
    showSnack(context, _variants > 1 ? 'Queued $_variants variants (seeds $seed…${seed + _variants - 1})' : 'Queued "$base"');
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<Settings>();
    final isMlx = settings.backend == 'mlx';
    return PageScaffold(
      title: 'Generate',
      subtitle: 'Style and lyrics in, a 48 kHz stereo song out. Engine: ${settings.backend}',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 3,
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                TextField(controller: _title, decoration: const InputDecoration(labelText: 'Title (optional)', border: OutlineInputBorder())),
                const SizedBox(height: 14),
                TextField(
                  controller: _style,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Style tags',
                    helperText: 'Comma-separated genre, mood, instruments, vocal type',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _lyrics,
                  minLines: 10,
                  maxLines: 22,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.35),
                  decoration: InputDecoration(
                    labelText: _instrumental ? 'Structure (instrumental: section tags only)' : 'Lyrics',
                    helperText: 'Section tags like [Intro] [Verse] [Chorus] [Bridge] [Outro]',
                    border: const OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  TextButton.icon(
                    icon: Icon(_showAbc ? Icons.expand_less : Icons.expand_more),
                    label: const Text('ABC score input (optional)'),
                    onPressed: () => setState(() => _showAbc = !_showAbc),
                  ),
                ]),
                if (_showAbc)
                  TextField(
                    controller: _abc,
                    enabled: _effectiveMode != 'off',
                    minLines: 6,
                    maxLines: 16,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    decoration: InputDecoration(
                      labelText: 'ABC score',
                      helperText: _effectiveMode == 'off'
                          ? 'A supplied score needs mode full or melody'
                          : 'Replaces the planning stage: the model realises this score instead of writing its own',
                      border: const OutlineInputBorder(),
                      alignLabelWithHint: true,
                    ),
                  ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          SizedBox(
            width: 400,
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Instrumental'),
                  subtitle: const Text('Adds "Instrumental … no vocals, no singing" and plans with cot=off'),
                  value: _instrumental,
                  onChanged: (v) => setState(() => _instrumental = v),
                ),
                const SizedBox(height: 8),
                _label('Score planning (mode)'),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'full', label: Text('full')),
                    ButtonSegment(value: 'melody', label: Text('melody')),
                    ButtonSegment(value: 'off', label: Text('off')),
                  ],
                  selected: {_effectiveMode},
                  onSelectionChanged: _instrumental ? null : (s) => setState(() => _mode = s.first),
                ),
                _hint(_effectiveMode == 'off'
                    ? 'off: no score; the token stage runs two guided branches.'
                    : 'The model first writes an ABC score, then the audio tokens.'),
                const SizedBox(height: 14),
                _label('Seed'),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _seed,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: 'Random seed',
                    icon: const Icon(Icons.casino_outlined),
                    onPressed: () => setState(() => _seed.text = '${randomSeed()}'),
                  ),
                ]),
                const SizedBox(height: 14),
                if (isMlx) ...[
                  _label('AR precision'),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'bf16', label: Text('bf16')),
                      ButtonSegment(value: '8bit', label: Text('8bit (faster)')),
                    ],
                    selected: {_precision},
                    onSelectionChanged: (s) => setState(() => _precision = s.first),
                  ),
                  const SizedBox(height: 14),
                ] else
                  _hint('Precision comes from the GGUF quant (${settings.ggufQuant}).'),
                _label('Flow matching (NAR) steps'),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 8, label: Text('8 fast')),
                    ButtonSegment(value: 16, label: Text('16')),
                    ButtonSegment(value: 32, label: Text('32 standard')),
                  ],
                  selected: {_steps},
                  onSelectionChanged: (s) => setState(() => _steps = s.first),
                ),
                const SizedBox(height: 14),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(_limitLength ? 'Max length: ${_maxSeconds.round()} s' : 'Length: until the model ends (≤ 6 min)'),
                  subtitle: Text(_limitLength ? '${(_maxSeconds * 25).round()} semantic tokens max; the model may end sooner' : '9000 semantic tokens max'),
                  value: _limitLength,
                  onChanged: (v) => setState(() => _limitLength = v),
                ),
                if (_limitLength)
                  Slider(
                    value: _maxSeconds,
                    min: 10,
                    max: 360,
                    divisions: 70,
                    label: '${_maxSeconds.round()} s',
                    onChanged: (v) => setState(() => _maxSeconds = v),
                  ),
                const SizedBox(height: 8),
                _label('Batch: variants with consecutive seeds'),
                Row(children: [
                  Expanded(
                    child: Slider(
                      value: _variants.toDouble(),
                      min: 1,
                      max: 8,
                      divisions: 7,
                      label: '$_variants',
                      onChanged: (v) => setState(() => _variants = v.round()),
                    ),
                  ),
                  SizedBox(width: 28, child: Text('$_variants')),
                ]),
                const SizedBox(height: 12),
                FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  icon: const Icon(Icons.auto_awesome),
                  label: Text(_variants > 1 ? 'Queue $_variants songs' : 'Generate'),
                  onPressed: _style.text.trim().isEmpty && _lyrics.text.trim().isEmpty ? null : _submit,
                ),
                const SizedBox(height: 18),
                const _QueuePanel(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(s, style: Theme.of(context).textTheme.labelLarge),
      );

  Widget _hint(String s) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(s, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
}

class _QueuePanel extends StatelessWidget {
  const _QueuePanel();

  @override
  Widget build(BuildContext context) {
    final q = context.watch<JobQueue>();
    return SectionCard(
      title: 'Queue',
      trailing: q.jobs.any((j) => !j.active)
          ? TextButton(onPressed: q.clearFinished, child: const Text('Clear finished'))
          : null,
      child: q.jobs.isEmpty
          ? Text('Nothing queued. One job runs at a time; the rest wait here.', style: Theme.of(context).textTheme.bodySmall)
          : Column(children: [for (final j in q.jobs.reversed) JobTile(j)]),
    );
  }
}
