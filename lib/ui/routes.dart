import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/library/song.dart';
import '../state/nav.dart';
import 'screens/catalogue_screen.dart';
import 'screens/extend_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/song_screen.dart';

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

void openCatalogue(BuildContext context) => _push(context, const CatalogueScreen(), '/catalogue');
void openSettings(BuildContext context) => _push(context, const SettingsScreen(), '/settings');
void openExtend(BuildContext context, Song s) => _push(context, ExtendScreen(sourceId: s.id), '/extend');
void openSetup(BuildContext context) => context.read<AppNav>().openSetup(true);

/// Back to the studio (the first page).
void openStudio(BuildContext context) => Navigator.of(context).popUntil((r) => r.isFirst);
