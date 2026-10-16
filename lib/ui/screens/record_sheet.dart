import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/paths.dart';
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
    final planning = f.modes.isNotEmpty && !f.instrumental;
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
                      ChoiceRow<int>(
                        label: 'Steps',
                        values: f.stepChoices,
                        selected: f.steps,
                        text: (v) => '$v',
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
                      if (features?.instrumental ?? false)
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
                      _SeedRow(f),
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
