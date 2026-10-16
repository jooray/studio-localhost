import 'package:flutter/widgets.dart';

/// Layout class by window width (not by platform): phone, unfolded foldable/tablet, desktop.
enum WindowSize { compact, medium, expanded }

WindowSize windowSizeFor(double width) =>
    width < 600 ? WindowSize.compact : (width < 840 ? WindowSize.medium : WindowSize.expanded);

WindowSize windowSizeOf(BuildContext context) => windowSizeFor(MediaQuery.sizeOf(context).width);
