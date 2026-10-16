import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/library/catalogue.dart';
import '../../core/library/library.dart';
import '../../core/library/song.dart';
import '../../state/generate_form.dart';
import '../routes.dart';
import '../theme.dart';
import 'sleeve.dart';
import 'title_editor.dart';

/// Reuse a song's prompt: back to the studio with its words and settings, a new seed.
/// An unsaved draft in the studio is replaced only after one in-world question.
Future<void> reuseSong(BuildContext context, Song song) async {
  final form = context.read<GenerateForm>();
  final lib = context.read<Library>();
  final n = Catalogue.format(lib.number(song));
  final same = form.style.text == song.style && form.lyrics.text == song.lyrics;
  if (form.hasDraft && !same) {
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: const Color(0xB3000000),
      builder: (ctx) => Dialog(
        child: SizedBox(
          width: 420,
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Etched('Replace current draft?', size: 13, color: Sleeve.ink),
              const SizedBox(height: 8),
              Etched('The studio gets the words and settings of $n.', size: 11, color: Sleeve.inkMute, maxLines: 2),
              const SizedBox(height: 18),
              Row(children: [
                Expanded(child: Cell(onTap: () => Navigator.pop(ctx, false), child: const Etched('Cancel', size: 12, color: Sleeve.ink))),
                const SizedBox(width: 8),
                Expanded(child: Cell(selected: true, onTap: () => Navigator.pop(ctx, true), child: const Etched('Replace', size: 12, color: Sleeve.ink))),
              ]),
            ]),
          ),
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
  }
  form.reuse(song, label: 'From $n');
  if (context.mounted) openStudio(context);
}

/// Long-press (touch) or right-click (pointer) on a catalogue or index row.
Future<void> songMenu(BuildContext context, Song song) => showDialog<void>(
      context: context,
      barrierColor: const Color(0xB3000000),
      builder: (ctx) {
        final lib = ctx.read<Library>();
        Widget item(Glyph g, String label, VoidCallback onTap) => SizedBox(
              height: 52,
              child: Cell(
                sides: const CellSides(left: false, right: false, top: false),
                onTap: onTap,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                semanticLabel: label,
                child: Row(children: [
                  GlyphIcon(g, size: 18),
                  const SizedBox(width: 14),
                  Etched(label, size: 12, color: Sleeve.ink),
                ]),
              ),
            );
        return Dialog(
          child: SizedBox(
            width: 320,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
                child: Text(lib.titleOf(song), maxLines: 1, overflow: TextOverflow.ellipsis, style: SleeveType.body(1).copyWith(fontSize: 17)),
              ),
              const Rule(),
              item(Glyph.rename, 'Rename', () {
                Navigator.pop(ctx);
                renameSong(context, song);
              }),
              item(Glyph.reuse, 'Reuse prompt', () {
                Navigator.pop(ctx);
                reuseSong(context, song);
              }),
            ]),
          ),
        );
      },
    );
