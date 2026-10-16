import 'package:flutter/material.dart';

class SectionCard extends StatelessWidget {
  const SectionCard({super.key, this.title, required this.child, this.trailing});

  final String? title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: cs.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: cs.outlineVariant)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (title != null || trailing != null) ...[
            Row(children: [
              Expanded(child: Text(title ?? '', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600))),
              ?trailing,
            ]),
            const SizedBox(height: 12),
          ],
          child,
        ]),
      ),
    );
  }
}

class KeyValueTable extends StatelessWidget {
  const KeyValueTable(this.rows, {super.key});

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (k, v) in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 120, child: Text(k, style: t.bodySmall?.copyWith(color: muted))),
            Expanded(child: SelectableText(v, style: t.bodySmall)),
          ]),
        ),
    ]);
  }
}

class Label extends StatelessWidget {
  const Label(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6, top: 4),
        child: Text(text, style: Theme.of(context).textTheme.labelLarge),
      );
}

/// A screen with a title row and a body.
class ScreenFrame extends StatelessWidget {
  const ScreenFrame({super.key, required this.title, this.actions = const [], required this.child});

  final String title;
  final List<Widget> actions;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 12, 8),
        child: Row(children: [
          Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600))),
          ...actions,
        ]),
      ),
      const Divider(height: 1),
      Expanded(child: child),
    ]);
  }
}

void showSnack(BuildContext context, String text, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(text),
    backgroundColor: error ? Theme.of(context).colorScheme.error : null,
    behavior: SnackBarBehavior.floating,
  ));
}

String stageName(String stage) => switch (stage) {
      'load' => 'Loading',
      'plan' => 'Score',
      'semantic' => 'Tokens',
      'nar' => 'Synthesis',
      'vae' => 'Decoding',
      'post' => 'Saving',
      _ => stage.isEmpty ? 'Waiting' : stage,
    };
