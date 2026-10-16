import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/library/catalogue.dart';
import '../../core/library/envelopes.dart';
import '../../core/paths.dart';
import '../../state/extend_form.dart';
import '../frame.dart';
import '../theme.dart';
import '../widgets/polar_plot.dart';
import '../widgets/sleeve.dart';
import 'record_sheet.dart';
import 'studio_screen.dart' show shortError;

/// Continue a song from a section of its timeline (default: the last 30 s), drawn on its plot.
class ExtendScreen extends StatefulWidget {
  const ExtendScreen({super.key, required this.sourceId});

  final String sourceId;

  @override
  State<ExtendScreen> createState() => _ExtendScreenState();
}

class _ExtendScreenState extends State<ExtendScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final f = context.read<ExtendForm>();
      final s = f.library.byId(widget.sourceId);
      if (s != null && f.sourceId != s.id) f.pick(s);
    });
  }

  @override
  Widget build(BuildContext context) {
    final f = context.watch<ExtendForm>();
    final src = f.source;
    final n = src == null ? null : f.library.number(src);
    return SleevePage(
      title: 'Extend ${Catalogue.format(n)}',
      child: src == null || src.id != widget.sourceId
          ? const SizedBox.shrink()
          : LayoutBuilder(builder: (context, c) {
              final wide = c.maxWidth >= 820;
              final u = SleeveScale.of(context);
              final plot = _SectionPlot(f);
              final form = _ExtendForm(f);
              if (wide) {
                return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(flex: 10, child: Padding(padding: const EdgeInsets.all(32), child: Center(child: AspectRatio(aspectRatio: 1, child: plot)))),
                  const Rule(vertical: true),
                  Expanded(flex: 10, child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(32, 24, 32, 32), child: form)),
                ]);
              }
              return SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(25 * u, 12, 25 * u, 32 + MediaQuery.paddingOf(context).bottom),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Padding(padding: EdgeInsets.symmetric(horizontal: 50 * u), child: AspectRatio(aspectRatio: 1, child: plot)),
                  const SizedBox(height: 16),
                  form,
                ]),
              );
            }),
    );
  }
}

class _SectionPlot extends StatelessWidget {
  const _SectionPlot(this.f);
  final ExtendForm f;

  @override
  Widget build(BuildContext context) {
    final s = f.source!;
    final d = math.max(s.seconds, 0.001);
    return PolarPlot(
      envelope: context.watch<Envelopes>().of(s),
      seed: s.codeSeed,
      section: (f.sectionStart / d, f.sectionEnd / d),
      semanticLabel: 'Section from ${formatDuration(f.sectionStart)} to ${formatDuration(f.sectionEnd)}',
    );
  }
}

class _ExtendForm extends StatelessWidget {
  const _ExtendForm(this.f);
  final ExtendForm f;

  @override
  Widget build(BuildContext context) {
    final s = f.source!;
    final u = SleeveScale.of(context);
    final env = context.watch<Envelopes>().of(s);
    final canExternal = f.studio.engine?.canTokenizeAudio ?? false;
    final remaining = (f.studio.model?.limits.maxSeconds ?? 360) - f.sectionStart - f.sectionLength;
    final adds = [15.0, 30.0, 60.0, 120.0].where((a) => a <= remaining).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Etched('Continue from', size: 12, color: Sleeve.inkMute),
      const SizedBox(height: 10),
      _Timeline(f, rms: env?.resample(160).rms),
      const SizedBox(height: 6),
      Row(children: [
        Text('${formatDuration(f.sectionStart)} – ${formatDuration(f.sectionEnd)}', style: SleeveType.value(u, size: 14)),
        const Spacer(),
        for (final secs in const [10.0, 30.0, 60.0])
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: SizedBox(
              width: 64,
              height: 44,
              child: Cell(
                frame: (f.sectionLength - math.min(secs, s.seconds)).abs() < 0.5 && (f.sectionEnd - s.seconds).abs() < 0.1,
                selected: true,
                onTap: () => f.lastSeconds(secs),
                semanticLabel: 'Last ${secs.round()} seconds',
                child: Text('${secs.round()}S', style: SleeveType.etched(u, size: 12, color: Sleeve.ink)),
              ),
            ),
          ),
      ]),
      const SizedBox(height: 10),
      const Rule(color: Sleeve.ruleFaint),
      ChoiceRow<double>(
        label: 'Add',
        values: [...adds, -1],
        selected: f.natural ? -1 : f.add,
        text: (v) => v < 0 ? 'to end' : '+${v.round()}s',
        onSelect: (v) => f.update(() {
          f.natural = v < 0;
          if (v > 0) f.add = v;
        }),
      ),
      if (f.stepChoices.length > 1)
        ChoiceRow<int>(label: 'Steps', values: f.stepChoices, selected: f.steps, text: (v) => '$v', onSelect: (v) => f.update(() => f.steps = v)),
      if (f.precisions.isNotEmpty)
        ChoiceRow<String>(
          label: 'Precision',
          values: f.precisions,
          selected: f.precisions.contains(f.precision) ? f.precision : f.precisions.first,
          text: (v) => v,
          onSelect: (v) => f.update(() => f.precision = v),
        ),
      const SizedBox(height: 18),
      Etched('Style', size: 12, color: Sleeve.inkMute),
      const SizedBox(height: 8),
      SleeveField(controller: f.style, style: SleeveType.body(u).copyWith(fontSize: 18, height: 1.3), maxLines: 3, minLines: 1, semanticLabel: 'Style'),
      const SizedBox(height: 14),
      const Rule(color: Sleeve.ruleFaint),
      const SizedBox(height: 14),
      Etched('Lyrics to continue with', size: 12, color: Sleeve.inkMute),
      const SizedBox(height: 8),
      SizedBox(
        height: 200,
        child: SleeveField(controller: f.lyrics, style: SleeveType.body(u).copyWith(fontSize: 18, height: 1.3), expands: true, semanticLabel: 'Lyrics'),
      ),
      const SizedBox(height: 14),
      const Rule(),
      const SizedBox(height: 16),
      Row(children: [
        Text(formatDuration(s.seconds), style: SleeveType.status(u).copyWith(fontSize: 20, color: Sleeve.inkSoft)),
        const SizedBox(width: 10),
        const GlyphIcon(Glyph.back, size: 18, color: Sleeve.inkMute),
        const SizedBox(width: 10),
        Text(f.natural ? 'until it ends' : formatDuration(f.finalLength),
            style: SleeveType.status(u).copyWith(fontSize: 20)),
      ]),
      const SizedBox(height: 14),
      SizedBox(
        height: 56,
        child: Cell(
          block: true,
          onTap: () async {
            try {
              await f.submit();
              if (context.mounted) {
                showLine(context, 'Extension queued');
                Navigator.of(context).maybePop();
              }
            } catch (e) {
              if (context.mounted) showLine(context, 'Could not queue: ${shortError(e)}', error: true);
            }
          },
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.only(left: 18),
          semanticLabel: 'Extend',
          child: Text('EXTEND → ${Catalogue.format(f.library.catalogue.next)}',
              style: SleeveType.etched(u, size: 15, color: Sleeve.ink, weight: FontWeight.w500)),
        ),
      ),
      if (canExternal) ...[
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: Cell(
            frame: false,
            minHeight: 44,
            onTap: () async {
              final file = await openFile(acceptedTypeGroups: [const XTypeGroup(label: 'Audio', extensions: ['wav', 'flac', 'mp3', 'ogg', 'm4a'])]);
              if (file == null) return;
              final msg = await f.submitExternal(file.path);
              if (context.mounted) showLine(context, msg);
            },
            child: Etched('Continue an outside recording…', size: 11, color: Sleeve.inkSoft),
          ),
        ),
      ],
    ]);
  }
}

/// The song's timeline as hairline bars; drag the handles or the section.
class _Timeline extends StatefulWidget {
  const _Timeline(this.f, {this.rms});
  final ExtendForm f;
  final List<double>? rms;

  @override
  State<_Timeline> createState() => _TimelineState();
}

class _TimelineState extends State<_Timeline> {
  int _drag = 0; // 1 start, 2 end, 3 both

  @override
  Widget build(BuildContext context) {
    final f = widget.f;
    final total = math.max(f.source!.seconds, 0.001);
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      double toS(double x) => (x / w).clamp(0.0, 1.0) * total;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (d) {
          final x = d.localPosition.dx;
          final xs = f.sectionStart / total * w, xe = f.sectionEnd / total * w;
          _drag = (x - xs).abs() < 24 ? 1 : ((x - xe).abs() < 24 ? 2 : (x > xs && x < xe ? 3 : 1));
        },
        onHorizontalDragUpdate: (d) {
          final t = toS(d.localPosition.dx);
          switch (_drag) {
            case 1:
              f.setSection(math.min(t, f.sectionEnd - 1), f.sectionEnd);
            case 2:
              f.setSection(f.sectionStart, math.max(t, f.sectionStart + 1));
            case 3:
              final len = f.sectionLength;
              final a = (f.sectionStart + d.delta.dx / w * total).clamp(0.0, total - len);
              f.setSection(a, a + len);
          }
        },
        child: Semantics(
          label: 'Section to continue from',
          child: SizedBox(
            height: 64,
            child: CustomPaint(painter: _TimelinePainter(widget.rms, f.sectionStart / total, f.sectionEnd / total)),
          ),
        ),
      );
    });
  }
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter(this.rms, this.a, this.b);
  final List<double>? rms;
  final double a, b;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    final r = rms;
    final dim = Paint()
      ..color = Sleeve.grid
      ..strokeWidth = 1;
    final lit = Paint()
      ..color = Sleeve.ink
      ..strokeWidth = 1;
    if (r != null && r.isNotEmpty) {
      final mx = r.reduce(math.max);
      for (var i = 0; i < r.length; i++) {
        final x = (i + 0.5) / r.length * size.width;
        final h = math.max(1.0, (r[i] / (mx == 0 ? 1 : mx)) * (size.height / 2 - 6));
        final f = x / size.width;
        canvas.drawLine(Offset(x, mid - h), Offset(x, mid + h), f >= a && f <= b ? lit : dim);
      }
    } else {
      canvas.drawLine(Offset(0, mid), Offset(size.width, mid), dim);
    }
    final red = Paint()
      ..color = Sleeve.ink
      ..strokeWidth = 2;
    final xa = a * size.width, xb = b * size.width;
    canvas.drawLine(Offset(xa, 0), Offset(xa, size.height), red);
    canvas.drawLine(Offset(xb, 0), Offset(xb, size.height), red);
    canvas.drawLine(Offset(xa, 0), Offset(xb, 0), red);
    canvas.drawLine(Offset(xa, size.height), Offset(xb, size.height), red);
  }

  @override
  bool shouldRepaint(_TimelinePainter o) => o.a != a || o.b != b || !identical(o.rms, rms);
}
