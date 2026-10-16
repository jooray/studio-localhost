import 'package:flutter/foundation.dart';

/// Navigation state shared across screens: the selected song (index column highlight) and the
/// model setup flow (shown on first run and from Settings).
class AppNav extends ChangeNotifier {
  /// Song selected in the catalogue (framed in the index column).
  String? selectedSongId;

  /// The model setup flow is open (also on top of a finished setup, from Settings).
  bool setupOpen = false;

  void select(String? id) {
    selectedSongId = id;
    notifyListeners();
  }

  void openSetup(bool open) {
    setupOpen = open;
    notifyListeners();
  }
}
