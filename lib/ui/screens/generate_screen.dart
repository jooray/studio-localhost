import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../state/generate_form.dart';
import '../layout.dart';
import '../widgets/common.dart';
import '../widgets/jobs.dart';

class GenerateScreen extends StatelessWidget {
  const GenerateScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final f = context.watch<GenerateForm>();
    final wide = windowSizeOf(context) == WindowSize.expanded;
    final text = _TextInputs(f);
    final options = _Options(f);
    return ScreenFrame(
      title: 'Generate',
      child: wide
          ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: ListView(padding: const EdgeInsets.all(20), children: [text])),
              const VerticalDivider(width: 1),
              SizedBox(width: 380, child: ListView(padding: const EdgeInsets.all(20), children: [options, const SizedBox(height: 16), const QueuePanel()])),
            ])
          : ListView(padding: const EdgeInsets.all(16), children: [text, const SizedBox(height: 12), options, const SizedBox(height: 16), const QueuePanel()]),
    );
  }
}

class _TextInputs extends StatelessWidget {
  const _TextInputs(this.f);
  final GenerateForm f;

  @override
  Widget build(BuildContext context) {
    final features = f.studio.model?.features;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(controller: f.title, decoration: const InputDecoration(labelText: 'Title', border: OutlineInputBorder())),
      const SizedBox(height: 12),
      TextField(controller: f.style, minLines: 2, maxLines: 4, decoration: const InputDecoration(labelText: 'Style', border: OutlineInputBorder())),
      const SizedBox(height: 12),
      TextField(
        controller: f.lyrics,
        minLines: 8,
        maxLines: 22,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.35),
        decoration: InputDecoration(
          labelText: f.instrumental ? 'Structure' : 'Lyrics',
          hintText: features?.lyricsSections == true ? '[Verse] [Chorus] [Bridge]' : null,
          border: const OutlineInputBorder(),
          alignLabelWithHint: true,
        ),
      ),
      if (features?.abcScore == true) ...[
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: Icon(f.showAbc ? Icons.expand_less : Icons.expand_more),
            label: const Text('Score (ABC)'),
            onPressed: () => f.update(() => f.showAbc = !f.showAbc),
          ),
        ),
        if (f.showAbc)
          TextField(
            controller: f.abc,
            enabled: f.effectiveMode != 'off',
            minLines: 5,
            maxLines: 14,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(labelText: 'ABC score', border: OutlineInputBorder(), alignLabelWithHint: true),
          ),
      ],
    ]);
  }
}

class _Options extends StatelessWidget {
  const _Options(this.f);
  final GenerateForm f;

  @override
  Widget build(BuildContext context) {
    final features = f.studio.model?.features;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (features?.instrumental == true)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Instrumental'),
          value: f.instrumental,
          onChanged: (v) => f.update(() => f.instrumental = v),
        ),
      if (f.modes.length > 1) ...[
        const Label('Score planning'),
        SegmentedButton<String>(
          segments: [for (final m in f.modes) ButtonSegment(value: m, label: Text(m))],
          selected: {f.effectiveMode},
          onSelectionChanged: f.instrumental ? null : (s) => f.update(() => f.mode = s.first),
        ),
      ],
      const Label('Seed'),
      Row(children: [
        Expanded(
          child: TextField(
            controller: f.seed,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
          ),
        ),
        IconButton(tooltip: 'Random seed', icon: const Icon(Icons.casino_outlined), onPressed: f.randomizeSeed),
      ]),
      if (f.precisions.isNotEmpty) ...[
        const Label('Precision'),
        SegmentedButton<String>(
          segments: [for (final p in f.precisions) ButtonSegment(value: p, label: Text(p))],
          selected: {f.precisions.contains(f.precision) ? f.precision : f.precisions.first},
          onSelectionChanged: (s) => f.update(() => f.precision = s.first),
        ),
      ],
      const Label('Steps'),
      SegmentedButton<int>(
        segments: [for (final s in f.stepChoices) ButtonSegment(value: s, label: Text('$s'))],
        selected: {f.stepChoices.contains(f.steps) ? f.steps : f.stepChoices.last},
        onSelectionChanged: (s) => f.update(() => f.steps = s.first),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(f.limitLength ? 'Up to ${f.maxSeconds.round()} s' : 'Until the song ends'),
        value: f.limitLength,
        onChanged: (v) => f.update(() => f.limitLength = v),
      ),
      if (f.limitLength)
        Slider(
          value: f.maxSeconds.clamp(10, f.maxLength),
          min: 10,
          max: f.maxLength,
          divisions: ((f.maxLength - 10) / 5).round(),
          label: '${f.maxSeconds.round()} s',
          onChanged: (v) => f.update(() => f.maxSeconds = v),
        ),
      Row(children: [
        const Text('Variants'),
        Expanded(
          child: Slider(
            value: f.variants.toDouble(),
            min: 1,
            max: 8,
            divisions: 7,
            label: '${f.variants}',
            onChanged: (v) => f.update(() => f.variants = v.round()),
          ),
        ),
        SizedBox(width: 24, child: Text('${f.variants}')),
      ]),
      const SizedBox(height: 8),
      FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        icon: const Icon(Icons.auto_awesome),
        label: Text(f.variants > 1 ? 'Generate ${f.variants}' : 'Generate'),
        onPressed: f.canSubmit
            ? () async {
                final msg = await f.submit();
                if (context.mounted) showSnack(context, msg);
              }
            : null,
      ),
    ]);
  }
}
