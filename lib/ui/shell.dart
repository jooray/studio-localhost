import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/jobs/job_queue.dart';
import '../core/studio.dart';
import '../state/nav.dart';
import 'layout.dart';
import 'screens/about.dart';
import 'screens/extend_screen.dart';
import 'screens/generate_screen.dart';
import 'screens/library_screen.dart';
import 'screens/settings_screen.dart';
import 'widgets/jobs.dart';
import 'widgets/player_bar.dart';

/// Adaptive shell: bottom bar on compact windows, a rail on medium, an extended rail on
/// expanded ones. Chosen by window width, not by platform.
class Shell extends StatelessWidget {
  const Shell({super.key});

  static const _icons = {
    Dest.generate: (Icons.auto_awesome_outlined, Icons.auto_awesome, 'Generate'),
    Dest.library: (Icons.library_music_outlined, Icons.library_music, 'Library'),
    Dest.extend: (Icons.queue_music_outlined, Icons.queue_music, 'Extend'),
    Dest.settings: (Icons.settings_outlined, Icons.settings, 'Settings'),
  };

  Widget _screen(Dest d) => switch (d) {
        Dest.generate => const GenerateScreen(),
        Dest.library => const LibraryScreen(),
        Dest.extend => const ExtendScreen(),
        Dest.settings => const SettingsScreen(),
      };

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<AppNav>();
    final studio = context.watch<Studio>();
    final busy = context.select<JobQueue, bool>((q) => q.running != null);
    final dests = [
      Dest.generate,
      Dest.library,
      if (studio.model?.features.extend ?? false) Dest.extend,
      Dest.settings,
    ];
    final index = dests.contains(nav.current) ? dests.indexOf(nav.current) : 0;
    final size = windowSizeOf(context);
    Widget icon(Dest d, bool selected) {
      final (o, s, _) = _icons[d]!;
      return Badge(isLabelVisible: d == Dest.generate && busy, child: Icon(selected ? s : o));
    }

    final body = Column(children: [
      Expanded(child: IndexedStack(index: index, children: [for (final d in dests) _screen(d)])),
      const JobStrip(),
      const PlayerBar(),
    ]);
    if (size == WindowSize.compact) {
      return Scaffold(
        body: SafeArea(bottom: false, child: body),
        bottomNavigationBar: NavigationBar(
          selectedIndex: index,
          onDestinationSelected: (i) => nav.go(dests[i]),
          destinations: [
            for (final d in dests) NavigationDestination(icon: icon(d, false), selectedIcon: icon(d, true), label: _icons[d]!.$3),
          ],
        ),
      );
    }
    final extended = size == WindowSize.expanded;
    return Scaffold(
      body: SafeArea(
        child: Row(children: [
          NavigationRail(
            selectedIndex: index,
            extended: extended,
            labelType: extended ? NavigationRailLabelType.none : NavigationRailLabelType.all,
            onDestinationSelected: (i) => nav.go(dests[i]),
            leading: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: InkWell(
                onTap: () => showAboutStudio(context),
                child: Image.asset('assets/icon-macos-1024.png', width: 44, height: 44),
              ),
            ),
            destinations: [
              for (final d in dests) NavigationRailDestination(icon: icon(d, false), selectedIcon: icon(d, true), label: Text(_icons[d]!.$3)),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: body),
        ]),
      ),
    );
  }
}
