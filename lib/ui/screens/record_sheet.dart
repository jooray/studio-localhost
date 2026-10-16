import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/paths.dart';
import '../../core/studio.dart';
import '../../state/generate_form.dart';
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
    final lengths = [30.0, 60.0, 120.0, 180.0, 240.0].where((s) => s < f.maxLength).toList();
    final planning = f.modes.isNotEmpty && !f.instrumental;
    return SleeveScale(
      u: u,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(25 * u, 8, 25 * u, 24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Expanded(child: Etched('Recording', size: 12, color: Sleeve.inkMute)),
              GlyphButton(Glyph.close, tooltip: 'Close', size: 18, onTap: () => Navigator.pop(context)),
            ]),
            const Rule(),
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
            ChoiceRow<double>(
              label: 'Length',
              values: [...lengths, -1],
              selected: f.limitLength ? f.maxSeconds : -1,
              text: (v) => v < 0 ? 'full' : formatDuration(v),
              onSelect: (v) => f.update(() {
                f.limitLength = v > 0;
                if (v > 0) f.maxSeconds = v;
              }),
            ),
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
          ]),
        ),
      ),
    );
  }
}

class ChoiceRow<T> extends StatelessWidget {
  const ChoiceRow({super.key, required this.label, required this.values, required this.selected, required this.text, required this.onSelect});

  final String label;
  final List<T> values;
  final T selected;
  final String Function(T) text;
  final ValueChanged<T> onSelect;

  @override
  Widget build(BuildContext context) {
    final u = SleeveScale.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: EdgeInsets.symmetric(vertical: 10 * u),
        child: Row(children: [
          SizedBox(width: 120 * u, child: Etched(label, size: 12, color: Sleeve.inkMute)),
          Expanded(
            child: Wrap(spacing: 0, runSpacing: 6, children: [
              for (final v in values)
                SizedBox(
                  width: 74 * u + 8,
                  height: 48,
                  child: Cell(
                    selected: v == selected,
                    frame: v == selected,
                    onTap: () => onSelect(v),
                    semanticLabel: '$label ${text(v)}',
                    child: Text(text(v).toUpperCase(),
                        style: SleeveType.etched(u, size: 13, color: v == selected ? Sleeve.ink : Sleeve.inkMute)),
                  ),
                ),
            ]),
          ),
        ]),
      ),
      const Rule(color: Sleeve.ruleFaint),
    ]);
  }
}

class _SeedRow extends StatelessWidget {
  const _SeedRow(this.f);
  final GenerateForm f;

  @override
  Widget build(BuildContext context) {
    final u = SleeveScale.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: EdgeInsets.symmetric(vertical: 4 * u),
        child: Row(children: [
          SizedBox(width: 120 * u, child: Etched('Seed', size: 12, color: Sleeve.inkMute)),
          Expanded(
            child: SleeveField(controller: f.seed, style: SleeveType.value(u, size: 16), maxLines: 1, keyboardType: TextInputType.number, semanticLabel: 'Seed'),
          ),
          GlyphButton(Glyph.dice, tooltip: 'New seed', size: 20, onTap: f.randomizeSeed),
        ]),
      ),
      const Rule(color: Sleeve.ruleFaint),
    ]);
  }
}

class _TitleRow extends StatelessWidget {
  const _TitleRow(this.f);
  final GenerateForm f;

  @override
  Widget build(BuildContext context) {
    final u = SleeveScale.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: EdgeInsets.symmetric(vertical: 14 * u),
        child: Row(children: [
          SizedBox(width: 120 * u, child: Etched('Title', size: 12, color: Sleeve.inkMute)),
          Expanded(
            child: SleeveField(controller: f.title, style: SleeveType.body(u).copyWith(fontSize: 17 * u + 1), maxLines: 1, hint: 'from the style', semanticLabel: 'Title'),
          ),
        ]),
      ),
      const Rule(color: Sleeve.ruleFaint),
    ]);
  }
}

class _ScoreRow extends StatelessWidget {
  const _ScoreRow(this.f);
  final GenerateForm f;

  @override
  Widget build(BuildContext context) {
    final u = SleeveScale.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
    ]);
  }
}
