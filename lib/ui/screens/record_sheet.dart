import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../core/paths.dart';
import '../../core/setup/model_setup.dart';
import '../../core/studio.dart';
import '../../state/generate_form.dart';
import '../routes.dart';
import '../theme.dart';
import '../widgets/sleeve.dart';

/// The etched settings, opened from the cell beside Record. Only what the model supports.
Future<void> showRecordSheet(BuildContext context) => showModalBottomSheet(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  barrierColor: const Color(0xB3000000),
  constraints: const BoxConstraints(maxWidth: 720),
  builder: (_) => const _RecordSheet(),
);

class _RecordSheet extends StatelessWidget {
  const _RecordSheet();

  @override
  Widget build(BuildContext context) {
    final f = context.watch<GenerateForm>();
    final studio = context.watch<Studio>();
    final features = studio.model?.features;
    final u = (MediaQuery.sizeOf(context).width / 576).clamp(0.7, 1.0);
    final planning = f.modes.isNotEmpty && !f.instrumental && !f.covering;
    return SleeveScale(
      u: u,
      child: ConstrainedBox(
        // Fits the window: header and footer stay, the rows between scroll.
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.86),
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(25 * u, 8, 25 * u, 0),
                child: Row(
                  children: [
                    Expanded(child: Etched('Recording', size: 12, color: Sleeve.inkMute)),
                    GlyphButton(Glyph.close, tooltip: 'Close', size: 18, onTap: () => Navigator.pop(context)),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 25 * u),
                child: const Rule(),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(25 * u, 0, 25 * u, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      QualityRow(
                        choices: f.stepChoices,
                        selected: f.steps,
                        preset: f.presetOf,
                        estimate: f.estimateFor,
                        onSelect: (v) => f.update(() => f.steps = v),
                      ),
                      if (f.precisions.isNotEmpty)
                        ChoiceRow<String>(
                          label: 'Precision',
                          values: f.precisions,
                          selected: f.precisions.contains(f.precision) ? f.precision : f.precisions.first,
                          text: (v) => v,
                          onSelect: (v) => f.update(() => f.precision = v),
                        ),
                      _LengthRow(f),
                      ChoiceRow<int>(
                        label: 'Takes',
                        values: const [1, 2, 4, 8],
                        selected: f.variants,
                        text: (v) => '×$v',
                        onSelect: (v) => f.update(() => f.variants = v),
                      ),
                      if (studio.coverAddon != null) _CoverRow(f),
                      if ((features?.instrumental ?? false) && !f.covering)
                        ChoiceRow<bool>(
                          label: 'Vocals',
                          values: const [false, true],
                          selected: f.instrumental,
                          text: (v) => v ? 'none' : 'sung',
                          onSelect: (v) => f.update(() => f.instrumental = v),
                        ),
                      if (planning)
                        ChoiceRow<String>(
                          label: 'Plan',
                          values: f.modes,
                          selected: f.effectiveMode,
                          text: (v) => v,
                          onSelect: (v) => f.update(() => f.mode = v),
                        ),
                      if (f.reuseSeed != null)
              ChoiceRow<bool>(
                label: 'Source seed',
                values: const [false, true],
                selected: f.sameSeed,
                text: (v) => v ? 'same' : 'new',
                onSelect: (v) => f.update(() => f.sameSeed = v),
              ),
            if (!f.sameSeed) _SeedRow(f),
                      _TitleRow(f),
                      if ((features?.abcScore ?? false) && planning && f.effectiveMode != 'off') _ScoreRow(f),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 25 * u),
                child: const Rule(),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(25 * u, 10, 25 * u, 16),
                child: Row(
                  children: [
                    Cell(
                      frame: false,
                      shrink: true,
                      minHeight: 48,
                      onTap: () {
                        Navigator.pop(context);
                        openSettings(context);
                      },
                      semanticLabel: 'Studio settings',
                      child: Etched('Studio settings', size: 12, color: Sleeve.inkSoft),
                    ),
                    const Spacer(),
                    SizedBox(
                      width: 140,
                      height: 48,
                      child: Cell(
                        onTap: () => Navigator.pop(context),
                        semanticLabel: 'Done',
                        child: Etched('Done', size: 13, color: Sleeve.ink),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Quality as presets over the step choices, each with its time on this device for the current
/// length (the estimate learns from every finished song).
class QualityRow extends StatelessWidget {
  const QualityRow({
    super.key,
    required this.choices,
    required this.selected,
    required this.preset,
    required this.estimate,
    required this.onSelect,
    this.note,
  });

  final List<int> choices;
  final int selected;
  final String? Function(int steps) preset;
  final Duration Function(int steps) estimate;
  final ValueChanged<int> onSelect;

  /// A quiet line under the choices (what the time covers).
  final String? note;

  @override
  Widget build(BuildContext context) {
    final u = SleeveScale.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.only(top: 12 * u, bottom: 8 * u),
          child: Etched('Quality', size: 12, color: Sleeve.inkMute),
        ),
        Row(
          children: [
            for (final v in choices)
              Expanded(
                child: Cell(
                  selected: v == selected,
                  frame: v == selected,
                  onTap: () => onSelect(v),
                  semanticLabel: '${preset(v) ?? '$v steps'}, $v steps, ${formatEstimate(estimate(v))}',
                  minHeight: 64,
                  padding: EdgeInsets.symmetric(horizontal: 6 * u, vertical: 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        (preset(v) ?? '$v steps').toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: SleeveType.etched(u, size: 13, color: v == selected ? Sleeve.ink : Sleeve.inkSoft, weight: FontWeight.w500),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        '$v · ${formatEstimate(estimate(v))}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: SleeveType.etched(u, size: 11, color: v == selected ? Sleeve.inkSoft : Sleeve.inkMute),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        if (note != null) ...[SizedBox(height: 8 * u), Etched(note!, size: 11, color: Sleeve.inkMute, maxLines: 2)],
        SizedBox(height: 10 * u),
        const Rule(color: Sleeve.ruleFaint),
      ],
    );
  }
}

class ChoiceRow<T> extends StatelessWidget {
  const ChoiceRow({
    super.key,
    required this.label,
    required this.values,
    required this.selected,
    required this.text,
    required this.onSelect,
  });

  final String label;
  final List<T> values;
  final T selected;
  final String Function(T) text;
  final ValueChanged<T> onSelect;

  @override
  Widget build(BuildContext context) {
    final u = SleeveScale.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 10 * u),
          child: Row(
            children: [
              SizedBox(
                width: 120 * u,
                child: Etched(label, size: 12, color: Sleeve.inkMute),
              ),
              Expanded(
                child: Wrap(
                  spacing: 0,
                  runSpacing: 6,
                  children: [
                    for (final v in values)
                      SizedBox(
                        width: 74 * u + 8,
                        height: 48,
                        child: Cell(
                          selected: v == selected,
                          frame: v == selected,
                          onTap: () => onSelect(v),
                          semanticLabel: '$label ${text(v)}',
                          child: Text(
                            text(v).toUpperCase(),
                            style: SleeveType.etched(u, size: 13, color: v == selected ? Sleeve.ink : Sleeve.inkMute),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const Rule(color: Sleeve.ruleFaint),
      ],
    );
  }
}

class _SeedRow extends StatelessWidget {
  const _SeedRow(this.f);
  final GenerateForm f;

  @override
  Widget build(BuildContext context) {
    final u = SleeveScale.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 4 * u),
          child: Row(
            children: [
              SizedBox(
                width: 120 * u,
                child: Etched('Seed', size: 12, color: Sleeve.inkMute),
              ),
              Expanded(
                child: SleeveField(
                  controller: f.seed,
                  style: SleeveType.value(u, size: 16),
                  maxLines: 1,
                  keyboardType: TextInputType.number,
                  semanticLabel: 'Seed',
                ),
              ),
              GlyphButton(Glyph.dice, tooltip: 'New seed', size: 20, onTap: f.randomizeSeed),
            ],
          ),
        ),
        const Rule(color: Sleeve.ruleFaint),
      ],
    );
  }
}

class _TitleRow extends StatelessWidget {
  const _TitleRow(this.f);
  final GenerateForm f;

  @override
  Widget build(BuildContext context) {
    final u = SleeveScale.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 14 * u),
          child: Row(
            children: [
              SizedBox(
                width: 120 * u,
                child: Etched('Title', size: 12, color: Sleeve.inkMute),
              ),
              Expanded(
                child: SleeveField(
                  controller: f.title,
                  style: SleeveType.body(u).copyWith(fontSize: 17 * u + 1),
                  maxLines: 1,
                  hint: 'from the style',
                  semanticLabel: 'Title',
                ),
              ),
            ],
          ),
        ),
        const Rule(color: Sleeve.ruleFaint),
      ],
    );
  }
}

class _ScoreRow extends StatelessWidget {
  const _ScoreRow(this.f);
  final GenerateForm f;

  @override
  Widget build(BuildContext context) {
    final u = SleeveScale.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ChoiceRow<bool>(
          label: 'Score',
          values: const [false, true],
          selected: f.showAbc,
          text: (v) => v ? 'mine' : 'model',
          onSelect: (v) => f.update(() => f.showAbc = v),
        ),
        if (f.showAbc)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 10 * u),
            child: SizedBox(
              height: 160,
              child: SleeveField(
                controller: f.abc,
                expands: true,
                style: SleeveType.value(u, size: 13),
                hint: 'X:1\nK:C\n…  (ABC notation)',
                semanticLabel: 'ABC score',
              ),
            ),
          ),
      ],
    );
  }
}

/// Cover: the next song takes the tune of a recording (its score, transcribed by the engine)
/// and sings these words over it. The transcriber is an optional download, offered here.
class _CoverRow extends StatelessWidget {
  const _CoverRow(this.f);
  final GenerateForm f;

  // yue2.cpp decodes these itself; the desktop engine goes through FFmpeg and takes more.
  static List<String> get _extensions =>
      Platform.isAndroid ? const ['mp3', 'wav', 'flac'] : const ['mp3', 'wav', 'flac', 'm4a', 'aac', 'ogg', 'opus', 'aiff'];

  Future<void> _pick(BuildContext context) async {
    final file = await openFile(acceptedTypeGroups: [XTypeGroup(label: 'Audio', extensions: _extensions, uniformTypeIdentifiers: const ['public.audio'])]);
    if (file == null || !context.mounted) return;
    final ext = p.extension(file.path).replaceFirst('.', '').toLowerCase();
    if (!_extensions.contains(ext)) {
      showLine(context, 'Pick ${_extensions.take(_extensions.length - 1).map((e) => e.toUpperCase()).join(', ')} or ${_extensions.last.toUpperCase()}', error: true);
      return;
    }
    f.update(() {
      f.coverPath = file.path;
      f.coverName = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final u = SleeveScale.of(context);
    final studio = context.watch<Studio>();
    final setup = context.watch<ModelSetup>();
    final addon = studio.coverAddon!;
    final ready = studio.coverReady;
    final installing = setup.task != null && setup.task!.contains('transcri');
    Widget cell(String text, {required bool on, VoidCallback? onTap, String? semantic}) => Cell(
          selected: on,
          frame: on,
          onTap: onTap,
          semanticLabel: semantic ?? text,
          padding: EdgeInsets.symmetric(horizontal: 10 * u),
          child: Text(text.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: SleeveType.etched(u, size: 13, color: on ? Sleeve.ink : Sleeve.inkMute)),
        );
    final String source;
    VoidCallback? onSource;
    if (f.covering) {
      source = f.coverLabel!;
      onSource = () => _pick(context);
    } else if (ready) {
      source = 'a recording…';
      onSource = () => _pick(context);
    } else if (installing) {
      source = setup.progress == null ? 'installing…' : 'downloading ${(setup.progress! * 100).floor()}%';
    } else {
      source = 'add · ${formatBytes(addon.bytes)}';
      onSource = setup.running ? null : () => setup.installCover();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 10 * u),
          child: Row(
            children: [
              SizedBox(width: 120 * u, child: Etched('Cover', size: 12, color: Sleeve.inkMute)),
              SizedBox(
                width: 74 * u + 8,
                height: 48,
                child: cell('none', on: !f.covering, onTap: () => f.update(() => f.coverPath = f.coverName = null), semantic: 'No cover'),
              ),
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: cell(source, on: f.covering, onTap: onSource,
                      semantic: f.covering ? 'Cover of $source, pick another' : (ready ? 'Cover a recording' : 'Download the transcriber, ${formatBytes(addon.bytes)}')),
                ),
              ),
            ],
          ),
        ),
        if (!ready && !f.covering)
          Padding(
            padding: EdgeInsets.only(left: 120 * u, bottom: 10 * u),
            child: Etched(
              setup.error != null && !installing
                  ? setup.error!
                  : 'Sing new words to the tune of any song. Needs the transcriber, a one-time download.',
              size: 11,
              color: Sleeve.inkMute,
              maxLines: 3,
            ),
          ),
        const Rule(color: Sleeve.ruleFaint),
        if (f.covering)
          ChoiceRow<String>(
            label: 'Keep',
            values: const ['full', 'melody'],
            selected: f.coverMode,
            text: (v) => v == 'full' ? 'score' : 'melody',
            onSelect: (v) => f.update(() => f.coverMode = v),
          ),
        if (f.covering) _StyleStrengthRow(f),
      ],
    );
  }
}

/// A cover's style strength, stepped by 0.1: how hard the style and words pull against the
/// recording's score.
class _StyleStrengthRow extends StatelessWidget {
  const _StyleStrengthRow(this.f);
  final GenerateForm f;

  @override
  Widget build(BuildContext context) {
    final u = SleeveScale.of(context);
    final r = GenerateForm.coverStyleRange;
    void step(int dir) => f.update(() => f.coverStyle = ((f.coverStyle * 10).round() + dir).clamp(r.min * 10, r.max * 10) / 10);
    final v = f.coverStyle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 10 * u),
          child: Row(
            children: [
              SizedBox(width: 120 * u, child: Etched('Style', size: 12, color: Sleeve.inkMute)),
              SizedBox(
                width: 48,
                height: 48,
                child: Cell(
                  onTap: v > r.min ? () => step(-1) : null,
                  semanticLabel: 'Less style',
                  child: const GlyphIcon(Glyph.minus, size: 16),
                ),
              ),
              SizedBox(
                width: 92 * u + 8,
                child: Text(v.toStringAsFixed(1), textAlign: TextAlign.center, style: SleeveType.value(u, size: 16)),
              ),
              SizedBox(
                width: 48,
                height: 48,
                child: Cell(
                  onTap: v < r.max ? () => step(1) : null,
                  semanticLabel: 'More style',
                  child: const GlyphIcon(Glyph.plus, size: 16),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.only(left: 120 * u, bottom: 10 * u),
          child: Etched(
            v == 1.0
                ? 'The style and the recording count evenly.'
                : v > 1.0
                    ? 'Your style and words pull harder than the recording. Composing takes about twice as long.'
                    : 'Leans on the recording; your style and words count less. Composing takes about twice as long.',
            size: 11,
            color: Sleeve.inkMute,
            maxLines: 3,
          ),
        ),
        const Rule(color: Sleeve.ruleFaint),
      ],
    );
  }
}

/// Length: any value, stepped (10 s steps up to a minute, 30 s after), or the model's full length.
class _LengthRow extends StatelessWidget {
  const _LengthRow(this.f);
  final GenerateForm f;

  @override
  Widget build(BuildContext context) {
    final u = SleeveScale.of(context);
    final max = f.maxLength;
    double step(double v, int dir) {
      final s = (dir > 0 ? v >= 60 : v > 60) ? 30.0 : 10.0;
      final n = ((v + dir * s) / s).round() * s;
      return n.clamp(10.0, max);
    }

    final value = f.limitLength ? f.maxSeconds : max;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 10 * u),
          child: Row(
            children: [
              SizedBox(
                width: 120 * u,
                child: Etched('Length', size: 12, color: Sleeve.inkMute),
              ),
              SizedBox(
                width: 48,
                height: 48,
                child: Cell(
                  onTap: () => f.update(() {
                    f.limitLength = true;
                    f.maxSeconds = step(value, -1);
                  }),
                  semanticLabel: 'Shorter',
                  child: const GlyphIcon(Glyph.minus, size: 16),
                ),
              ),
              SizedBox(
                width: 92 * u + 8,
                child: Text(
                  f.limitLength ? formatDuration(f.maxSeconds) : 'FULL',
                  textAlign: TextAlign.center,
                  style: SleeveType.value(u, size: 16),
                ),
              ),
              SizedBox(
                width: 48,
                height: 48,
                child: Cell(
                  onTap: () => f.update(() {
                    f.limitLength = true;
                    f.maxSeconds = step(value, 1);
                  }),
                  semanticLabel: 'Longer',
                  child: const GlyphIcon(Glyph.plus, size: 16),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 74 * u + 8,
                height: 48,
                child: Cell(
                  selected: !f.limitLength,
                  frame: !f.limitLength,
                  onTap: () => f.update(() => f.limitLength = !f.limitLength),
                  semanticLabel: 'Full length',
                  child: Text('FULL', style: SleeveType.etched(u, size: 13, color: f.limitLength ? Sleeve.inkMute : Sleeve.ink)),
                ),
              ),
            ],
          ),
        ),
        const Rule(color: Sleeve.ruleFaint),
      ],
    );
  }
}
