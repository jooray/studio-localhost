import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../core/jobs.dart';
import '../core/library.dart';
import '../core/paths.dart';
import '../core/player.dart';
import '../core/settings.dart';
import '../core/sidecar.dart';
import 'generate_page.dart' show randomSeed;
import 'widgets.dart';

class ExtendPage extends StatefulWidget {
  const ExtendPage({super.key});

  @override
  State<ExtendPage> createState() => _ExtendPageState();
}

class _ExtendPageState extends State<ExtendPage> {
  String? _sourceDir;
  RangeValues _section = const RangeValues(0, 1);
  bool _natural = false;
  double _add = 30;
  final _style = TextEditingController();
  final _lyrics = TextEditingController();
  final _seed = TextEditingController(text: '${randomSeed()}');
  String _mode = 'off';
  bool _reuseScore = true;
  int _steps = 32;
  String _precision = 'bf16';
  double _crossfade = 2.0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nav = context.read<AppNav>();
    if (nav.extendSourceDir != null && nav.extendSourceDir != _sourceDir) {
      final s = context.read<Library>().byDir(nav.extendSourceDir!);
      nav.extendSourceDir = null;
      if (s != null) _pick(s);
    }
  }

  void _pick(Song s) {
    final dur = s.seconds;
    setState(() {
      _sourceDir = s.dir;
      _section = RangeValues(math.max(0, dur - 30), dur);
      _style.text = s.style;
      _lyrics.text = s.lyrics;
      _mode = s.cot;
      _reuseScore = s.abc != null;
      _steps = s.steps ?? 32;
      _precision = s.precision ?? 'bf16';
    });
  }

  @override
  void dispose() {
    _style.dispose();
    _lyrics.dispose();
    _seed.dispose();
    super.dispose();
  }

  void _submit(Song s) {
    final seed = int.tryParse(_seed.text) ?? randomSeed();
    final atEnd = (_section.end - s.seconds).abs() < 0.05;
    context.read<JobQueue>().add('extend', '${s.title} (extended${_natural ? '' : ' +${_add.round()} s'})', {
      'source_dir': s.dir,
      'section_start': double.parse(_section.start.toStringAsFixed(2)),
      'section_end': atEnd ? null : double.parse(_section.end.toStringAsFixed(2)),
      'section_seconds': _section.end - _section.start,
      'add_seconds': _natural ? null : _add.round(),
      'style': _style.text,
      'lyrics': _lyrics.text,
      'mode': _mode,
      'reuse_score': _reuseScore,
      'seed': seed,
      'steps': _steps,
      'precision': _precision,
      'crossfade': _crossfade,
    });
    setState(() => _seed.text = '${seed + 1}');
    showSnack(context, 'Extension queued');
  }

  Future<void> _extendExternal() async {
    final f = await openFile(acceptedTypeGroups: [
      const XTypeGroup(label: 'Audio', extensions: ['wav', 'flac', 'mp3', 'm4a', 'ogg']),
    ]);
    if (f == null || !mounted) return;
    final seed = int.tryParse(_seed.text) ?? randomSeed();
    context.read<JobQueue>().add('extend', '${p.basenameWithoutExtension(f.path)} (extended +${_add.round()} s)', {
      'source_audio': f.path,
      'add_seconds': _natural ? null : _add.round(),
      'section_seconds': 30,
      'style': _style.text,
      'lyrics': _lyrics.text,
      'mode': 'off',
      'seed': seed,
      'steps': _steps,
      'precision': _precision,
      'crossfade': _crossfade,
    });
    showSnack(context, 'External extension queued (last 30 s of the recording)');
  }

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<Library>();
    final settings = context.watch<Settings>();
    final sc = context.watch<Sidecar>();
    final candidates = lib.songs.where((s) => s.hasSemantic).toList();
    final source = _sourceDir == null ? null : lib.byDir(_sourceDir!);
    if (source == null && candidates.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _sourceDir == null) _pick(candidates.first);
      });
    }
    final t = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final caps = sc.info?['capabilities'] as Map?;
    final canTokenize = caps?['tokenize_audio'] == true;
    final sectionLen = _section.end - _section.start;
    final finalLen = source == null ? 0 : _section.start + sectionLen + (_natural ? 0 : _add);
    return PageScaffold(
      title: 'Extend',
      subtitle: 'Continue a song from a section of it: the section\'s semantic codes open the prompt and the model writes on.',
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          SectionCard(
            title: 'Source',
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              DropdownButtonFormField<String>(
                initialValue: source?.dir,
                isExpanded: true,
                decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Song from the library'),
                items: [
                  for (final s in candidates)
                    DropdownMenuItem(value: s.dir, child: Text('${s.title}  ·  ${formatDuration(s.seconds)}  ·  ${s.kind}', overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (d) {
                  final s = d == null ? null : lib.byDir(d);
                  if (s != null) _pick(s);
                },
              ),
              const SizedBox(height: 10),
              Row(children: [
                Tooltip(
                  message: canTokenize
                      ? 'Tokenize an external recording into semantic codes, then extend it'
                      : (caps?['tokenize_reason'] as String? ?? 'Needs the RealAudio tokenizer weights, which are not installed'),
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.audio_file_outlined),
                    label: const Text('Extend external audio…'),
                    onPressed: canTokenize ? _extendExternal : null,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    canTokenize
                        ? 'Tokenizer available.'
                        : 'External audio: disabled. ${caps?['tokenize_reason'] ?? 'The RealAudio tokenizer weights are not installed; nothing is downloaded automatically.'}',
                    style: t.bodySmall?.copyWith(color: muted),
                  ),
                ),
              ]),
            ]),
          ),
          if (source != null) ...[
            const SizedBox(height: 12),
            SectionCard(
              title: 'Section and length',
              trailing: IconButton(
                tooltip: 'Play source',
                icon: const Icon(Icons.play_circle),
                onPressed: () => context.read<AudioPlayerModel>().play(source.audioPath, title: source.title),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('Section ${_section.start.toStringAsFixed(1)} – ${_section.end.toStringAsFixed(1)} s (${sectionLen.toStringAsFixed(1)} s) of ${formatDuration(source.seconds)}',
                    style: t.bodyMedium),
                RangeSlider(
                  values: _section,
                  min: 0,
                  max: math.max(source.seconds, 0.1),
                  divisions: math.max(1, (source.seconds * 2).round()),
                  labels: RangeLabels('${_section.start.toStringAsFixed(1)} s', '${_section.end.toStringAsFixed(1)} s'),
                  onChanged: (v) => setState(() => _section = v.end - v.start < 1 ? _section : v),
                ),
                Wrap(spacing: 8, children: [
                  for (final s in [10, 20, 30, 60])
                    ActionChip(
                      label: Text('last $s s'),
                      onPressed: () => setState(() => _section = RangeValues(math.max(0, source.seconds - s), source.seconds)),
                    ),
                  ActionChip(label: const Text('whole song'), onPressed: () => setState(() => _section = RangeValues(0, source.seconds))),
                ]),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Natural end'),
                  subtitle: const Text('Let the model write until its end token (capped at 9000 tokens, 6 min, including the section)'),
                  value: _natural,
                  onChanged: (v) => setState(() => _natural = v),
                ),
                if (!_natural) ...[
                  Text('Add ${_add.round()} s after the section', style: t.bodyMedium),
                  Slider(value: _add, min: 5, max: 240, divisions: 47, label: '${_add.round()} s', onChanged: (v) => setState(() => _add = v)),
                ],
                Text(
                  _natural
                      ? 'Final file: original up to ${_section.start.toStringAsFixed(1)} s, then the continuation.'
                      : 'AR target ${(sectionLen + _add).toStringAsFixed(0)} s (section + addition) · final file ≈ ${formatDuration(finalLen)}',
                  style: t.bodySmall?.copyWith(color: muted),
                ),
                if (_section.start > 0)
                  Text('The original audio is kept up to the section start; the new render takes over there with a '
                      '${_crossfade.toStringAsFixed(1)} s equal-power crossfade. The raw re-render is kept too.',
                      style: t.bodySmall?.copyWith(color: muted))
                else
                  Text('The section starts at 0, so the whole re-render is used.', style: t.bodySmall?.copyWith(color: muted)),
              ]),
            ),
            const SizedBox(height: 12),
            SectionCard(
              title: 'Prompt',
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                TextField(controller: _style, minLines: 2, maxLines: 4, decoration: const InputDecoration(labelText: 'Style tags', border: OutlineInputBorder())),
                const SizedBox(height: 12),
                TextField(
                  controller: _lyrics,
                  minLines: 6,
                  maxLines: 16,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  decoration: const InputDecoration(labelText: 'Lyrics', border: OutlineInputBorder(), alignLabelWithHint: true),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'full', label: Text('full')),
                      ButtonSegment(value: 'melody', label: Text('melody')),
                      ButtonSegment(value: 'off', label: Text('off')),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (s) => setState(() => _mode = s.first),
                  ),
                  const SizedBox(width: 16),
                  if (_mode != 'off')
                    Expanded(
                      child: CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _reuseScore && source.abc != null,
                        onChanged: source.abc == null ? null : (v) => setState(() => _reuseScore = v ?? true),
                        title: Text(source.abc == null ? 'No source score: a new one is planned' : 'Reuse the source\'s ABC score'),
                      ),
                    ),
                ]),
              ]),
            ),
            const SizedBox(height: 12),
            SectionCard(
              title: 'Render',
              child: Wrap(spacing: 18, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
                SizedBox(
                  width: 220,
                  child: Row(children: [
                    Expanded(child: TextField(controller: _seed, decoration: const InputDecoration(labelText: 'Seed', border: OutlineInputBorder(), isDense: true))),
                    IconButton(icon: const Icon(Icons.casino_outlined), onPressed: () => setState(() => _seed.text = '${randomSeed()}')),
                  ]),
                ),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 8, label: Text('8 fast')),
                    ButtonSegment(value: 16, label: Text('16')),
                    ButtonSegment(value: 32, label: Text('32 standard')),
                  ],
                  selected: {_steps},
                  onSelectionChanged: (s) => setState(() => _steps = s.first),
                ),
                if (settings.backend == 'mlx')
                  SegmentedButton<String>(
                    segments: const [ButtonSegment(value: 'bf16', label: Text('bf16')), ButtonSegment(value: '8bit', label: Text('8bit'))],
                    selected: {_precision},
                    onSelectionChanged: (s) => setState(() => _precision = s.first),
                  ),
                SizedBox(
                  width: 260,
                  child: Row(children: [
                    const Text('Crossfade'),
                    Expanded(
                      child: Slider(value: _crossfade, min: 0.5, max: 4, divisions: 7, label: '${_crossfade.toStringAsFixed(1)} s', onChanged: (v) => setState(() => _crossfade = v)),
                    ),
                  ]),
                ),
              ]),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size(260, 48)),
                icon: const Icon(Icons.queue_music),
                label: const Text('Extend'),
                onPressed: () => _submit(source),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
