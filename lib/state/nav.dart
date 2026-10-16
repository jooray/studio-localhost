import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/library/song.dart';

enum Dest { generate, library, extend, settings }

/// Navigation state: the current destination plus hand-offs between screens.
class AppNav extends ChangeNotifier {
  /// STUDIO_PAGE=generate|library|extend|settings picks the start screen (screenshots).
  Dest current = Dest.values.firstWhere((d) => d.name == Platform.environment['STUDIO_PAGE'], orElse: () => Dest.generate);

  /// Song the Extend screen should start from.
  String? extendSourceId;

  /// Song selected in the Library.
  String? selectedSongId;

  /// The model setup flow is open (also on top of a finished setup, from Settings).
  bool setupOpen = false;

  void go(Dest d) {
    current = d;
    notifyListeners();
  }

  void extend(Song s) {
    extendSourceId = s.id;
    go(Dest.extend);
  }

  void openSong(Song s) {
    selectedSongId = s.id;
    go(Dest.library);
  }

  void select(String? id) {
    selectedSongId = id;
    notifyListeners();
  }

  void openSetup(bool open) {
    setupOpen = open;
    notifyListeners();
  }
}
