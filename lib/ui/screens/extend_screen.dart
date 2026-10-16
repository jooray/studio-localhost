import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/paths.dart';
import '../../core/player.dart';
import '../../state/extend_form.dart';
import '../../state/nav.dart';
import '../widgets/common.dart';

class ExtendScreen extends StatefulWidget {
  const ExtendScreen({super.key});

  @override
  State<ExtendScreen> createState() => _ExtendScreenState();
}

class _ExtendScreenState extends State<ExtendScreen> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nav = context.watch<AppNav>();
    final f = context.read<ExtendForm>();
    final handoff = nav.extendSourceId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      f.ensureSource(handoff);
      if (handoff != null) nav.extendSourceId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final f = context.watch<ExtendForm>();
    final source = f.source;
    final t = Theme.of(context).textTheme;
    final canExternal = f.studio.engine?.canTokenizeAudio ?? false;
    return ScreenFrame(
      title: 'Extend',
      child: ListView(padding: const EdgeInsets.all(16), children: [
        DropdownButtonFormField<String>(
          initialValue: source?.id,
          isExpanded: true,
          decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Song'),
          items: [
            for (final s in f.candidates)
              DropdownMenuItem(value: s.id, child: Text('${s.title} · ${formatDuration(s.seconds)}', overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (id) {
            final s = f.library.byId(id);
            if (s != null) f.pick(s);
          },
        ),
        if (canExternal)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.audio_file_outlined),
              label: const Text('Extend a recording…'),
              onPressed: () async {
                final file = await openFile(acceptedTypeGroups: [const XTypeGroup(label: 'Audio', extensions: ['wav', 'flac', 'mp3', 'm4a', 'ogg'])]);
                if (file == null) return;
                final msg = await f.submitExternal(file.path);
                if (context.mounted) showSnack(context, msg);
              },
            ),
          ),
        if (source == null)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('No finished songs yet')))
        else ...[
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: Text('From ${f.sectionStart.toStringAsFixed(1)} s to ${f.sectionEnd.toStringAsFixed(1)} s of ${formatDuration(source.seconds)}', style: t.bodyMedium),
            ),
            IconButton(
              tooltip: 'Play',
              icon: const Icon(Icons.play_circle),
              onPressed: () => context.read<AudioPlayerModel>().play(source.audioPath!, title: source.title),
            ),
          ]),
          RangeSlider(
            values: RangeValues(f.sectionStart.clamp(0, source.seconds), f.sectionEnd.clamp(0, source.seconds)),
            min: 0,
            max: math.max(source.seconds, 0.1),
            divisions: math.max(1, (source.seconds * 2).round()),
            onChanged: (v) => f.setSection(v.start, v.end),
          ),
          Wrap(spacing: 8, children: [
            for (final s in [10, 20, 30, 60]) ActionChip(label: Text('last $s s'), onPressed: () => f.lastSeconds(s.toDouble())),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(f.natural ? 'Until the song ends' : 'Add ${f.add.round()} s'),
            value: !f.natural,
            onChanged: (v) => f.update(() => f.natural = !v),
          ),
          if (!f.natural) Slider(value: f.add, min: 5, max: 240, divisions: 47, label: '${f.add.round()} s', onChanged: (v) => f.update(() => f.add = v)),
          Text('Result ≈ ${formatDuration(f.finalLength)}', style: t.bodySmall),
          const SizedBox(height: 12),
          TextField(controller: f.style, minLines: 2, maxLines: 4, decoration: const InputDecoration(labelText: 'Style', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(
            controller: f.lyrics,
            minLines: 5,
            maxLines: 14,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: const InputDecoration(labelText: 'Lyrics', border: OutlineInputBorder(), alignLabelWithHint: true),
          ),
          if (f.modes.length > 1) ...[
            const Label('Score planning'),
            SegmentedButton<String>(
              segments: [for (final m in f.modes) ButtonSegment(value: m, label: Text(m))],
              selected: {f.modes.contains(f.mode) ? f.mode : f.modes.last},
              onSelectionChanged: (s) => f.update(() => f.mode = s.first),
            ),
            if (f.mode != 'off' && source.abc != null)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: f.reuseScore,
                onChanged: (v) => f.update(() => f.reuseScore = v ?? true),
                title: const Text('Keep the song\'s score'),
              ),
          ],
          const Label('Steps'),
          SegmentedButton<int>(
            segments: [for (final s in f.stepChoices) ButtonSegment(value: s, label: Text('$s'))],
            selected: {f.stepChoices.contains(f.steps) ? f.steps : f.stepChoices.last},
            onSelectionChanged: (s) => f.update(() => f.steps = s.first),
          ),
          if (f.precisions.isNotEmpty) ...[
            const Label('Precision'),
            SegmentedButton<String>(
              segments: [for (final p in f.precisions) ButtonSegment(value: p, label: Text(p))],
              selected: {f.precisions.contains(f.precision) ? f.precision : f.precisions.first},
              onSelectionChanged: (s) => f.update(() => f.precision = s.first),
            ),
          ],
          Row(children: [
            Expanded(child: TextField(controller: f.seed, decoration: const InputDecoration(labelText: 'Seed', border: OutlineInputBorder(), isDense: true))),
            const SizedBox(width: 12),
            const Text('Crossfade'),
            Expanded(
              child: Slider(value: f.crossfade, min: 0.5, max: 4, divisions: 7, label: '${f.crossfade.toStringAsFixed(1)} s', onChanged: (v) => f.update(() => f.crossfade = v)),
            ),
          ]),
          const SizedBox(height: 12),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            icon: const Icon(Icons.queue_music),
            label: const Text('Extend'),
            onPressed: () async {
              final msg = await f.submit();
              if (context.mounted) showSnack(context, msg);
            },
          ),
        ],
      ]),
    );
  }
}
