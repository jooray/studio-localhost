import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/library/catalogue.dart';
import '../theme.dart';

/// A 1 px rule.
class Rule extends StatelessWidget {
  const Rule({super.key, this.vertical = false, this.color = Sleeve.rule, this.indent = 0});

  final bool vertical;
  final Color color;
  final double indent;

  @override
  Widget build(BuildContext context) => vertical
      ? Container(width: Sleeve.hair, color: color)
      : Padding(
          padding: EdgeInsets.symmetric(horizontal: indent),
          child: Container(height: Sleeve.hair, color: color),
        );
}

/// The song's five-block colour code.
class CodeStripView extends StatelessWidget {
  const CodeStripView(this.seed, {super.key, this.height = 41, this.gap = 0});

  final int seed;
  final double height;
  final double gap;

  @override
  Widget build(BuildContext context) {
    final blocks = codeStrip(seed);
    return Semantics(
      label: 'Colour code',
      child: SizedBox(
        height: height,
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var i = 0; i < blocks.length; i++) ...[
            if (i > 0 && gap > 0) SizedBox(width: gap),
            Expanded(flex: blocks[i].weight, child: ColoredBox(color: Sleeve.code[blocks[i].colour])),
          ],
        ]),
      ),
    );
  }
}

/// A hairline-framed cell: the one control shape of this world. [block] adds the red block at the
/// right end (armed primary action); [active] frames the cell in red (the one current entry).
class Cell extends StatefulWidget {
  const Cell({
    super.key,
    required this.child,
    this.onTap,
    this.active = false,
    this.selected = false,
    this.block = false,
    this.frame = true,
    this.sides = const CellSides.all(),
    this.padding = EdgeInsets.zero,
    this.minHeight = 48,
    this.tooltip,
    this.semanticLabel,
    this.alignment = Alignment.center,
    this.shrink = false,
    this.onLongPress,
  });

  final Widget child;
  final VoidCallback? onTap;
  final bool active;
  final bool selected;
  final bool block;
  final bool frame;
  final CellSides sides;
  final EdgeInsets padding;
  final double minHeight;
  final String? tooltip;
  final String? semanticLabel;
  final Alignment alignment;

  /// Size to the content instead of filling the width (cells in a Wrap).
  final bool shrink;

  /// Long-press (touch) or right-click (pointer): a secondary action such as rename.
  final VoidCallback? onLongPress;

  @override
  State<Cell> createState() => _CellState();
}

class CellSides {
  const CellSides({this.left = true, this.top = true, this.right = true, this.bottom = true});
  const CellSides.all() : left = true, top = true, right = true, bottom = true;
  const CellSides.none() : left = false, top = false, right = false, bottom = false;
  final bool left, top, right, bottom;
}

class _CellState extends State<Cell> {
  bool _hover = false;
  bool _focus = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final frameColor = widget.active ? Sleeve.red : (widget.selected ? Sleeve.ink : Sleeve.rule);
    BorderSide side(bool on) => on && widget.frame ? BorderSide(color: frameColor, width: Sleeve.hair) : BorderSide.none;
    final fill = _down
        ? const Color(0x1AFFFFFF)
        : (_hover && enabled ? const Color(0x0DFFFFFF) : Colors.transparent);
    Widget body = Container(
      constraints: BoxConstraints(minHeight: widget.minHeight),
      decoration: BoxDecoration(
        color: fill,
        border: Border(
          left: side(widget.sides.left),
          top: side(widget.sides.top),
          right: side(widget.sides.right),
          bottom: side(widget.sides.bottom),
        ),
      ),
      foregroundDecoration: _focus
          ? BoxDecoration(border: Border.all(color: widget.active ? Sleeve.red : Sleeve.ink, width: 2))
          : null,
      child: widget.block
          ? IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(child: Padding(padding: widget.padding, child: Align(alignment: widget.alignment, child: widget.child))),
                Container(width: 30, color: Sleeve.red),
              ]),
            )
          : Padding(
              padding: widget.padding,
              child: Align(alignment: widget.alignment, widthFactor: widget.shrink ? 1 : null, heightFactor: widget.shrink ? 1 : null, child: widget.child),
            ),
    );
    if (enabled) {
      body = FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (v) => setState(() => _hover = v),
        onShowFocusHighlight: (v) => setState(() => _focus = v),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            widget.onTap!();
            return null;
          }),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _down = true),
          onTapCancel: () => setState(() => _down = false),
          onTapUp: (_) => setState(() => _down = false),
          onTap: () {
            HapticFeedback.selectionClick();
            widget.onTap!();
          },
          onLongPress: widget.onLongPress == null
              ? null
              : () {
                  HapticFeedback.mediumImpact();
                  widget.onLongPress!();
                },
          onSecondaryTap: widget.onLongPress,
          child: body,
        ),
      );
    }
    body = Semantics(button: enabled, enabled: enabled, label: widget.semanticLabel, child: body);
    if (widget.tooltip != null) body = Tooltip(message: widget.tooltip!, child: body);
    return body;
  }
}

/// Engraved caps text (labels, etched lines).
class Etched extends StatelessWidget {
  const Etched(this.text, {super.key, this.size = 13, this.color = Sleeve.inkSoft, this.weight = FontWeight.w400, this.maxLines = 1, this.align});

  final String text;
  final double size;
  final Color color;
  final FontWeight weight;
  final int maxLines;
  final TextAlign? align;

  @override
  Widget build(BuildContext context) {
    final u = SleeveScale.of(context);
    return Text(text.toUpperCase(),
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        textAlign: align,
        style: SleeveType.etched(u, size: size, color: color, weight: weight));
  }
}

enum Glyph { rename, reuse, catalogue, menu, play, pause, close, back, plus, minus, check, dice, up, share, extend, rerender, delete, folder, copy }

/// Authored icons: one 1.25 px stroke, square caps, drawn on a 24 unit grid.
class GlyphIcon extends StatelessWidget {
  const GlyphIcon(this.glyph, {super.key, this.size = 24, this.color = Sleeve.ink});

  final Glyph glyph;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) =>
      SizedBox.square(dimension: size, child: CustomPaint(painter: _GlyphPainter(glyph, color)));
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.glyph, this.color);
  final Glyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide / 24;
    canvas.scale(s);
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.25 / s * (s < 1 ? 1 : 1.0)
      ..strokeCap = StrokeCap.square
      ..isAntiAlias = true;
    final fill = Paint()..color = color;
    void l(double x1, double y1, double x2, double y2) => canvas.drawLine(Offset(x1, y1), Offset(x2, y2), p);
    switch (glyph) {
      case Glyph.catalogue:
        // A tiny polar plot: ring, hub, spokes.
        canvas.drawCircle(const Offset(12, 12), 9, p);
        canvas.drawCircle(const Offset(12, 12), 4.5, p);
        for (var k = 0; k < 8; k++) {
          final a = k * math.pi / 4;
          canvas.drawLine(Offset(12 + 4.5 * math.sin(a), 12 - 4.5 * math.cos(a)),
              Offset(12 + (k.isEven ? 9 : 7) * math.sin(a), 12 - (k.isEven ? 9 : 7) * math.cos(a)), p);
        }
      case Glyph.rename:
        // A pen over a baseline.
        l(5, 19, 19, 19);
        l(7, 15, 15, 7);
        l(15, 7, 17, 9);
        l(17, 9, 9, 17);
        l(9, 17, 6.5, 17.5);
      case Glyph.reuse:
        // A sheet with an arrow coming back into it: start again from these words.
        canvas.drawRect(const Rect.fromLTWH(9, 9, 11, 11), p);
        canvas.drawArc(const Rect.fromLTWH(4, 4, 10, 10), math.pi, math.pi * 1.2, false, p);
        l(4, 9, 4, 13);
        l(4, 13, 7.5, 11);
      case Glyph.menu:
        l(4, 7, 20, 7);
        l(4, 12, 20, 12);
        l(4, 17, 20, 17);
      case Glyph.play:
        canvas.drawPath(Path()
          ..moveTo(7, 5)
          ..lineTo(19, 12)
          ..lineTo(7, 19)
          ..close(), fill);
      case Glyph.pause:
        canvas.drawRect(const Rect.fromLTWH(7, 5, 3.5, 14), fill);
        canvas.drawRect(const Rect.fromLTWH(13.5, 5, 3.5, 14), fill);
      case Glyph.close:
        l(6, 6, 18, 18);
        l(18, 6, 6, 18);
      case Glyph.back:
        l(5, 12, 19, 12);
        l(5, 12, 11, 6);
        l(5, 12, 11, 18);
      case Glyph.plus:
        l(5, 12, 19, 12);
        l(12, 5, 12, 19);
      case Glyph.minus:
        l(5, 12, 19, 12);
      case Glyph.check:
        l(5, 12.5, 10, 17.5);
        l(10, 17.5, 19, 7);
      case Glyph.dice:
        canvas.drawRect(const Rect.fromLTWH(5, 5, 14, 14), p);
        for (final o in const [Offset(9, 9), Offset(15, 15), Offset(12, 12)]) {
          canvas.drawCircle(o, 1.2, fill);
        }
      case Glyph.up:
        l(12, 5, 12, 19);
        l(12, 5, 6, 11);
        l(12, 5, 18, 11);
      case Glyph.share:
        l(12, 4, 12, 15);
        l(12, 4, 8, 8);
        l(12, 4, 16, 8);
        canvas.drawPath(Path()
          ..moveTo(6, 11)
          ..lineTo(6, 20)
          ..lineTo(18, 20)
          ..lineTo(18, 11), p);
      case Glyph.extend:
        canvas.drawArc(const Rect.fromLTWH(4, 4, 16, 16), -math.pi / 2, math.pi * 1.5, false, p);
        l(4, 12, 4, 12);
        l(12, 4, 20, 4);
        l(20, 4, 20, 12);
      case Glyph.rerender:
        canvas.drawArc(const Rect.fromLTWH(5, 5, 14, 14), 0, math.pi * 1.6, false, p);
        l(19, 12, 19, 6);
        l(19, 12, 14, 10);
      case Glyph.delete:
        l(5, 7, 19, 7);
        l(10, 4, 14, 4);
        canvas.drawPath(Path()
          ..moveTo(7, 7)
          ..lineTo(8, 20)
          ..lineTo(16, 20)
          ..lineTo(17, 7), p);
      case Glyph.folder:
        canvas.drawPath(Path()
          ..moveTo(4, 7)
          ..lineTo(10, 7)
          ..lineTo(12, 9)
          ..lineTo(20, 9)
          ..lineTo(20, 18)
          ..lineTo(4, 18)
          ..close(), p);
      case Glyph.copy:
        canvas.drawRect(const Rect.fromLTWH(8, 8, 11, 11), p);
        canvas.drawPath(Path()
          ..moveTo(5, 15)
          ..lineTo(5, 5)
          ..lineTo(15, 5), p);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter o) => o.glyph != glyph || o.color != color;
}

/// A square glyph button with a 48 px target.
class GlyphButton extends StatelessWidget {
  const GlyphButton(this.glyph, {super.key, required this.onTap, required this.tooltip, this.size = 24, this.frame = false, this.color = Sleeve.ink});

  final Glyph glyph;
  final VoidCallback? onTap;
  final String tooltip;
  final double size;
  final bool frame;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: math.max(48, size + 20),
        child: Cell(
          onTap: onTap,
          frame: frame,
          tooltip: tooltip,
          semanticLabel: tooltip,
          minHeight: 0,
          child: GlyphIcon(glyph, size: size, color: onTap == null ? Sleeve.inkMute : color),
        ),
      );
}

/// An in-world text field: no box, no underline; the hairlines around it are the frame.
class SleeveField extends StatelessWidget {
  const SleeveField({
    super.key,
    required this.controller,
    required this.style,
    this.hint,
    this.maxLines,
    this.minLines,
    this.expands = false,
    this.focusNode,
    this.keyboardType,
    this.semanticLabel,
    this.onChanged,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final TextStyle style;
  final String? hint;
  final int? maxLines;
  final int? minLines;
  final bool expands;
  final FocusNode? focusNode;
  final TextInputType? keyboardType;
  final String? semanticLabel;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) => Semantics(
        textField: true,
        label: semanticLabel,
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          style: style,
          maxLines: expands ? null : maxLines,
          minLines: expands ? null : minLines,
          expands: expands,
          keyboardType: keyboardType ?? (maxLines == 1 ? TextInputType.text : TextInputType.multiline),
          textAlignVertical: TextAlignVertical.top,
          cursorColor: Sleeve.ink,
          cursorWidth: 1.5,
          cursorHeight: style.fontSize! * 1.05,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          decoration: InputDecoration(
            isCollapsed: true,
            border: InputBorder.none,
            hintText: hint,
            hintStyle: style.copyWith(color: Sleeve.inkMute),
          ),
        ),
      );
}

/// A short in-world message with a way out: "ENGINE STOPPED  ·  RESTART".
class ErrorLine extends StatelessWidget {
  const ErrorLine(this.message, {super.key, this.action, this.onAction, this.detail});

  final String message;
  final String? action;
  final VoidCallback? onAction;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final u = SleeveScale.of(context);
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      HollowMark(size: 10 * u),
      SizedBox(width: 12 * u),
      Expanded(
        child: Tooltip(
          message: detail ?? '',
          child: Text(message.toUpperCase(), maxLines: 2, overflow: TextOverflow.ellipsis, style: SleeveType.etched(u, color: Sleeve.ink, size: 13)),
        ),
      ),
      if (action != null)
        Cell(
          onTap: onAction,
          minHeight: 40,
          padding: EdgeInsets.symmetric(horizontal: 14 * u),
          child: Text(action!.toUpperCase(), style: SleeveType.etched(u, color: Sleeve.ink, size: 13)),
        ),
    ]);
  }
}

/// "TRANSMISSION DATA" style rows: engraved key, mono value.
class DataList extends StatelessWidget {
  const DataList(this.rows, {super.key, this.keyWidth = 150});

  final List<(String, String)> rows;
  final double keyWidth;

  @override
  Widget build(BuildContext context) {
    final u = SleeveScale.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (k, v) in rows) ...[
        Padding(
          padding: EdgeInsets.symmetric(vertical: 9 * u),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: keyWidth * u, child: Etched(k, size: 12, color: Sleeve.inkMute)),
            Expanded(child: SelectableText(v, style: SleeveType.value(u, size: 14))),
          ]),
        ),
        const Rule(color: Sleeve.ruleFaint),
      ],
    ]);
  }
}

/// Toast-like feedback in the world's voice.
void showLine(BuildContext context, String text, {bool error = false}) {
  final m = ScaffoldMessenger.maybeOf(context);
  m?.hideCurrentSnackBar();
  m?.showSnackBar(SnackBar(
    content: Row(children: [
      if (error) ...[const HollowMark(size: 8), const SizedBox(width: 10)],
      Expanded(child: Text(text.toUpperCase())),
    ]),
    duration: Duration(seconds: error ? 6 : 3),
  ));
}

/// A small hollow square: marks a stopped or failed entry without spending the one red.
class HollowMark extends StatelessWidget {
  const HollowMark({super.key, this.size = 7});
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(border: Border.all(color: Sleeve.inkMute, width: Sleeve.hair)),
      );
}
