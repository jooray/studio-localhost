import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/paths.dart';
import '../../core/player.dart';

class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context) {
    final pl = context.watch<AudioPlayerModel>();
    if (pl.path == null) return const SizedBox.shrink();
    final total = pl.duration.inMilliseconds.toDouble();
    final pos = pl.position.inMilliseconds.clamp(0, total > 0 ? total : 0).toDouble();
    final cs = Theme.of(context).colorScheme;
    const tab = TextStyle(fontFeatures: [FontFeature.tabularFigures()], fontSize: 12);
    return Material(
      color: cs.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Row(children: [
            IconButton(
              icon: Icon(pl.playing ? Icons.pause : Icons.play_arrow),
              onPressed: () => pl.toggle(pl.path!, title: pl.title),
            ),
            Flexible(flex: 2, child: Text(pl.title ?? '', maxLines: 1, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 8),
            Text(formatDuration(pl.position.inSeconds), style: tab),
            Expanded(
              flex: 5,
              child: Slider(
                value: total > 0 ? pos : 0,
                max: total > 0 ? total : 1,
                onChanged: total > 0 ? (v) => pl.seek(Duration(milliseconds: v.round())) : null,
              ),
            ),
            Text(formatDuration(pl.duration.inSeconds), style: tab),
            if (pl.error != null) Tooltip(message: pl.error!, child: Icon(Icons.warning, color: cs.error)),
          ]),
        ),
      ),
    );
  }
}
