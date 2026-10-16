import 'package:flutter/widgets.dart';

/// Lyrics with section tags ([Verse], [Chorus]) shown in caps; the text itself stays as typed.
class LyricController extends TextEditingController {
  LyricController({super.text});

  static final _tag = RegExp(r'\[[^\]\n]*\]');

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final t = text;
    final spans = <TextSpan>[];
    var last = 0;
    final composing = value.composing;
    for (final m in _tag.allMatches(t)) {
      // Keep the composing region untouched (IME input inside a tag).
      if (withComposing && composing.isValid && composing.start < m.end && composing.end > m.start) continue;
      if (m.start > last) spans.add(TextSpan(text: t.substring(last, m.start)));
      spans.add(TextSpan(text: t.substring(m.start, m.end).toUpperCase()));
      last = m.end;
    }
    if (last < t.length) spans.add(TextSpan(text: t.substring(last)));
    return TextSpan(style: style, children: spans);
  }
}

