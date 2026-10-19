import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/library/song.dart';
import '../state/nav.dart';
import 'screens/extend_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/song_screen.dart';
import 'screens/studio_screen.dart';

/// Navigation between the screens. One stack on every size; on wide windows each page carries
/// the index column itself, so only the content steps in.
Future<void> _push(BuildContext context, Widget page, String name) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page, settings: RouteSettings(name: name)));

void openSong(BuildContext context, Song s) {
  final nav = context.read<AppNav>();
  nav.select(s.id);
  // Replace a song page with another one instead of stacking them.
  final route = ModalRoute.of(context)?.settings.name;
  if (route == '/song') {
    Navigator.of(context).pushReplacement(PageRouteBuilder(
      settings: const RouteSettings(name: '/song'),
      pageBuilder: (_, _, _) => SongScreen(s.id),
      transitionDuration: Duration.zero,
    ));
    return;
  }
  _push(context, SongScreen(s.id), '/song');
}

/// The catalogue is the first page; the studio opens on top of it, so back from the studio
/// lands on the whole catalogue and back from there leaves the app.
void openCatalogue(BuildContext context) => Navigator.of(context).popUntil((r) => r.isFirst);
void openSettings(BuildContext context) => _push(context, const SettingsScreen(), '/settings');
void openExtend(BuildContext context, Song s) => _push(context, ExtendScreen(sourceId: s.id), '/extend');
void openSetup(BuildContext context) {
  // Setup replaces the first page; anything stacked above it would cover it.
  Navigator.of(context).popUntil((r) => r.isFirst);
  context.read<AppNav>().openSetup(true);
}

/// The studio, one step above the catalogue (and nothing else).
Route<void> studioRoute({bool instant = false}) => instant
    ? PageRouteBuilder(
        settings: const RouteSettings(name: '/studio'),
        pageBuilder: (_, _, _) => const StudioScreen(),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: const Duration(milliseconds: 300),
      )
    : MaterialPageRoute(builder: (_) => const StudioScreen(), settings: const RouteSettings(name: '/studio'));

/// Back to the studio, right above the catalogue.
void openStudio(BuildContext context) {
  final nav = Navigator.of(context);
  var onStudio = false;
  nav.popUntil((r) {
    if (r.settings.name == '/studio') onStudio = true;
    return r.isFirst || r.settings.name == '/studio';
  });
  if (!onStudio) nav.push(studioRoute());
}
