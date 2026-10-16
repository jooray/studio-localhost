import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/audio/envelope.dart';
import '../theme.dart';

/// The polar pulse plot: concentric hairline rings, radial spokes and the song's own waveform as a
/// white burst around a centre hole (360° = the whole song, clockwise from the top). The outer
/// ring carries a progress arc (recording or playback). Without audio it draws a sparse burst
/// that grows with [grow] (token progress) or stays empty.
class PolarPlot extends StatefulWidget {
  const PolarPlot({
    super.key,
    this.envelope,
    this.arc,
    this.grow,
    this.seed = 0,
    this.live = false,
    this.mini = false,
    this.section,
    this.onSeek,
    this.semanticLabel,
  });

  final Envelope? envelope;

  /// 0..1 progress arc on the outer ring, null for none.
  final double? arc;

  /// Placeholder burst while no audio exists: 0..1 of it drawn, null for none.
  final double? grow;
  final int seed;

  /// Recording: the burst breathes slowly.
  final bool live;

  /// Small catalogue plot: fewer rings, no arc head.
  final bool mini;

  /// A highlighted sector (0..1 start, 0..1 end), e.g. the section an extension continues from.
  final (double, double)? section;

  /// Tap or drag around the plot to seek (0..1).
  final ValueChanged<double>? onSeek;
  final String? semanticLabel;

  @override
  State<PolarPlot> createState() => _PolarPlotState();
}

class _PolarPlotState extends State<PolarPlot> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 3200));
  List<double>? _peaks;
  List<double>? _rms;
  Envelope? _source;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(PolarPlot old) {
    super.didUpdateWidget(old);
    _syncPulse();
  }

  void _syncPulse() {
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (widget.live && !reduce) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else if (_pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  void _prepare() {
    final e = widget.envelope;
    if (identical(e, _source)) return;
    _source = e;
    if (e == null || e.bins == 0) {
      _peaks = _rms = null;
      return;
    }
    final env = widget.mini && e.bins > 240 ? e.resample(240) : e;
    // Perceptual compression so quiet passages still draw and the loudest bin reaches the rim.
    var top = 0.0;
    for (final v in env.peak) {
      if (v > top) top = v;
    }
    if (top <= 0) top = 1;
    _peaks = [for (final v in env.peak) math.pow(v / top, 0.7).toDouble()];
    _rms = [for (final v in env.rms) math.pow((v / top).clamp(0.0, 1.0), 0.6).toDouble()];
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  void _seek(Offset local, Size size) {
    final c = size.center(Offset.zero);
    final d = local - c;
    if (d.distance < size.shortestSide * 0.12) return;
    var a = math.atan2(d.dx, -d.dy); // 0 at top, clockwise
    if (a < 0) a += 2 * math.pi;
    widget.onSeek?.call(a / (2 * math.pi));
  }

  @override
  Widget build(BuildContext context) {
    _prepare();
    Widget plot = AnimatedBuilder(
      animation: _pulse,
      builder: (_, _) => CustomPaint(
        painter: _PlotPainter(
          peaks: _peaks,
          rms: _rms,
          arc: widget.arc,
          grow: widget.grow,
          seed: widget.seed,
          pulse: widget.live ? math.sin(_pulse.value * 2 * math.pi) : 0,
          mini: widget.mini,
          section: widget.section,
        ),
        size: Size.infinite,
      ),
    );
    if (widget.onSeek != null) {
      final face = plot;
      plot = LayoutBuilder(
        builder: (_, c) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => _seek(d.localPosition, c.biggest),
          onPanUpdate: (d) => _seek(d.localPosition, c.biggest),
          child: face,
        ),
      );
    }
    return Semantics(label: widget.semanticLabel, image: true, child: RepaintBoundary(child: plot));
  }
}

class _PlotPainter extends CustomPainter {
  _PlotPainter({
    required this.peaks,
    required this.rms,
    required this.arc,
    required this.grow,
    required this.seed,
    required this.pulse,
    required this.mini,
    required this.section,
  });

  final List<double>? peaks;
  final List<double>? rms;
  final double? arc;
  final double? grow;
  final int seed;
  final double pulse;
  final bool mini;
  final (double, double)? section;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final arcW = mini ? 1.5 : math.max(2.0, size.shortestSide * 0.0085);
    final r = size.shortestSide / 2 - arcW;
    final hair = mini ? 0.75 : 1.0;
    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = hair
      ..color = Sleeve.grid
      ..isAntiAlias = true;

    // Rings: even spacing; the outer one a touch brighter.
    final rings = mini ? 6 : 16;
    for (var k = 1; k <= rings; k++) {
      canvas.drawCircle(c, r * k / rings, k == rings ? (Paint.from(grid)..color = Sleeve.inkMute) : grid);
    }
    // Spokes every 15° (30° on small plots).
    final spokes = mini ? 12 : 24;
    for (var k = 0; k < spokes; k++) {
      final a = k * 2 * math.pi / spokes;
      canvas.drawLine(c, c + Offset(math.sin(a), -math.cos(a)) * r, grid);
    }

    final hole = r * 0.30;
    final span = r * 0.54;
    final scale = 1 + pulse * 0.012;

    if (peaks != null && peaks!.isNotEmpty) {
      _burst(canvas, c, hole, span * scale, peaks!, rms!);
    } else if (grow != null) {
      _sparse(canvas, c, hole, span, grow!.clamp(0.0, 1.0));
    }

    // Centre spindle: a small dot, like the comp's hub.
    canvas.drawCircle(c, mini ? 1.2 : 2.2, Paint()..color = Sleeve.ink);

    if (section != null) {
      final (s0, s1) = section!;
      final sec = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = arcW * 2.2
        ..strokeCap = StrokeCap.butt
        ..color = Sleeve.ink;
      canvas.drawArc(Rect.fromCircle(center: c, radius: r - arcW * 3), -math.pi / 2 + s0 * 2 * math.pi,
          (s1 - s0).clamp(0.002, 1.0) * 2 * math.pi, false, sec);
      for (final s in [s0, s1]) {
        final a = s * 2 * math.pi;
        canvas.drawLine(c + Offset(math.sin(a), -math.cos(a)) * hole, c + Offset(math.sin(a), -math.cos(a)) * r,
            Paint()
              ..color = Sleeve.ink
              ..strokeWidth = hair * 1.5);
      }
    }

    if (arc != null && arc! > 0) {
      final p = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = arcW
        ..strokeCap = StrokeCap.butt
        ..color = Sleeve.ink;
      canvas.drawArc(Rect.fromCircle(center: c, radius: r), -math.pi / 2, arc!.clamp(0.0, 1.0) * 2 * math.pi, false, p);
    }
  }

  /// The waveform burst: outer edge follows each bin's peak, inner edge bites in by its RMS.
  void _burst(Canvas canvas, Offset c, double hole, double span, List<double> pk, List<double> rm) {
    final n = pk.length;
    final outer = ui.Path();
    final inner = ui.Path();
    for (var i = 0; i < n; i++) {
      final a = i * 2 * math.pi / n;
      final dir = Offset(math.sin(a), -math.cos(a));
      // Body from the RMS, needles from the peaks; the inner edge bites into the hole on hits.
      final body = 0.20 + 0.45 * rm[i];
      final spike = math.pow(pk[i], 3.2).toDouble();
      final ro = hole + span * math.max(body, spike);
      final ri = hole * (1 - 0.22 * math.pow(pk[i], 4).toDouble());
      final po = c + dir * ro, pi = c + dir * ri;
      if (i == 0) {
        outer.moveTo(po.dx, po.dy);
        inner.moveTo(pi.dx, pi.dy);
      } else {
        outer.lineTo(po.dx, po.dy);
        inner.lineTo(pi.dx, pi.dy);
      }
    }
    outer.close();
    inner.close();
    final ring = ui.Path.combine(ui.PathOperation.difference, outer, inner);
    canvas.drawPath(ring, Paint()..color = Sleeve.ink);
  }

  /// No audio yet: needles placed by the seed, revealed clockwise as tokens arrive.
  void _sparse(Canvas canvas, Offset c, double hole, double span, double g) {
    final rnd = math.Random(seed);
    const n = 120;
    final p = Paint()
      ..color = Sleeve.ink
      ..strokeWidth = mini ? 0.75 : 1.2;
    for (var i = 0; i < n; i++) {
      final len = 0.15 + 0.85 * math.pow(rnd.nextDouble(), 1.8);
      if (i / n > g) continue;
      final a = i * 2 * math.pi / n;
      final dir = Offset(math.sin(a), -math.cos(a));
      canvas.drawLine(c + dir * hole, c + dir * (hole + span * 0.7 * len), p);
    }
    canvas.drawCircle(c, hole, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = mini ? 0.75 : 1.2
      ..color = Sleeve.ink);
  }

  @override
  bool shouldRepaint(_PlotPainter o) =>
      !identical(o.peaks, peaks) || o.arc != arc || o.grow != grow || o.pulse != pulse || o.section != section || o.seed != seed;
}
