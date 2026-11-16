import 'dart:async';

import 'package:flutter/material.dart';

import '../core/app_info.dart';
import '../src/support/support_controller.dart';
import '../src/support/support_copy.dart';
import '../src/support/support_engine.dart';
import '../src/support/support_strip.dart';
import 'theme.dart';

/// Studio's side of the support ask.
///
/// `lib/src/support/` is a synced copy of a shared module (see lib/src/support/README.md); this file is the
/// app's own: its numbers, its placement and its look. Change words or rules in the shared module, and only
/// the look, the numbers or the placement here.
///
/// The app makes no network request for this: tapping Support hands a link to the system browser.
const studioSupport = SupportConfig(
  appId: 'studio-localhost',
  // The placement: the song page, under the actions of a take heard for the first time.
  ref: 'after-first-listen',
  // A take costs minutes to record: three days of use and five takes heard before the first ask.
  trigger: SupportTrigger(minDays: 3, minActions: 5),
);

/// The ask's state for the whole app, and the one place that knows which song page could host the strip.
class StudioSupport {
  StudioSupport([SupportController? controller]) : controller = controller ?? SupportController(config: studioSupport);

  final SupportController controller;

  /// The song page on screen right now (its song id), the only surface the strip appears on.
  String? _host;

  /// The app came to the foreground (start and every resume).
  void launch() => unawaited(controller.launch());

  /// A finished take was heard for the first time (its final mix started playing, or it was liked
  /// first). That is the action counted, and the moment of value when its own page is on screen.
  Future<void> takeHeard(String songId) async {
    await controller.recordAction();
    if (_host == songId) await controller.evaluate(momentOfValue: true);
  }

  /// The permanent Support entry in Settings; works after "Don't ask again" too.
  Future<bool> openFromMenu() => controller.openCheckout(dark: true);

  void _attach(String songId) => _host = songId;

  void _detach(String songId) {
    if (_host != songId) return;
    _host = null;
    controller.surfaceGone();
  }
}

/// The catalogue-sleeve voice: the strip is a hairline frame on the matte ground with square corners, no
/// fill and no red (red means "live now"). The words are engraved in Geist Mono like every other app
/// sentence (Geist light is for what the user wrote). Support is a framed cell in ink, Not now and Don't
/// ask again are frameless in muted ink.
SupportStyle studioSupportStyle(double u) => SupportStyle(
      ground: Sleeve.ground,
      border: Sleeve.rule,
      ink: Sleeve.ink,
      mid: Sleeve.inkSoft,
      faint: Sleeve.inkMute,
      focus: Sleeve.ink,
      body: SleeveType.value(u, size: 14, color: Sleeve.ink).copyWith(height: 1.45),
      label: SleeveType.etched(u, size: 12, color: Sleeve.ink),
      small: SleeveType.etched(u, size: 11, color: Sleeve.inkMute).copyWith(letterSpacing: 0.6),
      buttonBorder: Sleeve.hair,
      buttonBorderColor: Sleeve.ink,
    );

/// The strip's slot on the song page. Takes no space until the ask is shown, and tells [StudioSupport]
/// which song page is open so the ask appears only on the page of the take that was just heard.
class SupportSlot extends StatefulWidget {
  const SupportSlot({super.key, required this.support, required this.songId, required this.u});

  final StudioSupport support;
  final String songId;
  final double u;

  @override
  State<SupportSlot> createState() => _SupportSlotState();
}

class _SupportSlotState extends State<SupportSlot> {
  @override
  void initState() {
    super.initState();
    widget.support._attach(widget.songId);
  }

  @override
  void didUpdateWidget(SupportSlot old) {
    super.didUpdateWidget(old);
    if (old.songId != widget.songId) {
      old.support._detach(old.songId);
      widget.support._attach(widget.songId);
    }
  }

  @override
  void dispose() {
    widget.support._detach(widget.songId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.support.controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        if (!c.visible) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 22),
          child: SupportStrip(
            controller: c,
            // The studio is English-only and always dark; the checkout follows the browser's language.
            copy: SupportCopy.forLanguage('en', appName),
            style: studioSupportStyle(widget.u),
            brightness: Brightness.dark,
          ),
        );
      },
    );
  }
}
