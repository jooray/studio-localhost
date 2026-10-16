import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/library/catalogue.dart';
import '../../core/library/library.dart';
import '../../core/library/song.dart';
import '../theme.dart';
import 'sleeve.dart';

/// A song's title, editable in place: tap to edit in a hairline frame; Enter or Done saves,
/// Esc or Back cancels, an empty value goes back to the derived title.
class TitleEditor extends StatefulWidget {
  const TitleEditor(this.song, {super.key, required this.style, this.startEditing = false, this.maxLines = 3, this.onClosed});

  final Song song;
  final TextStyle style;
  final bool startEditing;
  final int maxLines;

  /// Called when editing ends (saved or cancelled).
  final VoidCallback? onClosed;

  @override
  State<TitleEditor> createState() => TitleEditorState();
}

class TitleEditorState extends State<TitleEditor> {
  late final _c = TextEditingController();
  final _focus = FocusNode();
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    if (widget.startEditing) WidgetsBinding.instance.addPostFrameCallback((_) => edit());
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  void edit() {
    final lib = context.read<Library>();
    _c.text = lib.titleOf(widget.song);
    _c.selection = TextSelection(baseOffset: 0, extentOffset: _c.text.length);
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  Future<void> _save() async {
    final lib = context.read<Library>();
    final fresh = lib.byId(widget.song.id) ?? widget.song;
    final t = _c.text.trim();
    // Saving the derived title unchanged does not make it the user's.
    final derived = fresh.derivedTitle ?? Catalogue.format(lib.number(fresh));
    if (!(t == derived && !lib.hasUserTitle(fresh))) await lib.rename(fresh, t);
    if (mounted) setState(() => _editing = false);
    widget.onClosed?.call();
  }

  void _cancel() {
    setState(() => _editing = false);
    widget.onClosed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<Library>();
    final song = lib.byId(widget.song.id) ?? widget.song;
    final title = lib.titleOf(song);
    if (!_editing) {
      return Cell(
        frame: false,
        onTap: edit,
        alignment: Alignment.centerLeft,
        minHeight: 48,
        tooltip: 'Rename',
        semanticLabel: 'Title $title, rename',
        child: Text(title, style: widget.style, maxLines: widget.maxLines, overflow: TextOverflow.ellipsis),
      );
    }
    final u = SleeveScale.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): _cancel},
        child: Container(
          decoration: BoxDecoration(border: Border.all(color: Sleeve.ink, width: Sleeve.hair)),
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Expanded(
              child: SleeveField(
                controller: _c,
                focusNode: _focus,
                // Edit at a working size; the display size returns on save.
                style: widget.style.copyWith(fontSize: (widget.style.fontSize ?? 20).clamp(11.0, 26.0), height: 1.25),
                maxLines: 1,
                hint: song.derivedTitle ?? Catalogue.format(lib.number(song)),
                semanticLabel: 'Title',
                onSubmitted: (_) => _save(),
              ),
            ),
            SizedBox(width: 8 * u),
            GlyphButton(Glyph.close, tooltip: 'Cancel', size: 18, color: Sleeve.inkSoft, onTap: _cancel),
            SizedBox(
              height: 44,
              child: Cell(
                shrink: true,
                onTap: _save,
                semanticLabel: 'Save title',
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: const Etched('Done', size: 12, color: Sleeve.ink),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Rename from a row (long-press or right-click): a small in-world dialog with the same field.
Future<void> renameSong(BuildContext context, Song song) => showDialog<void>(
      context: context,
      barrierColor: const Color(0xB3000000),
      builder: (ctx) {
        final lib = ctx.read<Library>();
        return Dialog(
          child: SizedBox(
            width: 520,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Etched('Rename ${Catalogue.format(lib.number(song))}', size: 12, color: Sleeve.inkMute),
                const SizedBox(height: 12),
                TitleEditor(
                  song,
                  startEditing: true,
                  maxLines: 1,
                  style: SleeveType.body(1).copyWith(fontSize: 20, height: 1.25),
                  onClosed: () => WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (Navigator.of(ctx).canPop()) Navigator.of(ctx).pop();
                  }),
                ),
                const SizedBox(height: 8),
                const Etched('Empty goes back to the title from the lyrics', size: 11, color: Sleeve.inkMute, maxLines: 2),
              ]),
            ),
          ),
        );
      },
    );
