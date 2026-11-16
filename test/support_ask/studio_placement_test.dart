// Studio's own placement of the support ask (the shared module is tested by the synced *_test.dart files
// beside this one): the strip appears only on the song page of the take that was just heard for the
// first time, leaves with that page, and a permanent "Support the project" entry works even after
// "don't ask again".
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:studio_localhost/src/support/support_controller.dart';
import 'package:studio_localhost/src/support/support_engine.dart';
import 'package:studio_localhost/src/support/support_launch.dart';
import 'package:studio_localhost/src/support/support_store.dart';
import 'package:studio_localhost/ui/support_ask.dart';

class FakeLauncher implements SupportLauncher {
  final opened = <Uri>[];

  @override
  Future<bool> open(Uri uri) async {
    opened.add(uri);
    return true;
  }
}

StudioSupport due(FakeLauncher launcher, {SupportState? from}) => StudioSupport(SupportController(
      config: studioSupport,
      store: MemorySupportStore(from ?? const SupportState(activeDays: 3, actions: 4)),
      launcher: launcher,
    ));

/// A stand-in for the song page: the slot under the actions, for [songId], or nothing.
Future<void> pumpPage(WidgetTester tester, StudioSupport support, String? songId) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Column(children: [
        const Text('ACTIONS'),
        if (songId != null) SupportSlot(key: ValueKey(songId), support: support, songId: songId, u: 1),
      ]),
    ),
  ));
  await tester.pump();
}

const askText = 'Localhost Recording Studio is free and open source. Support it and get an e-book.';

void main() {
  testWidgets('a due listener sees the ask on the page of the take just heard, with no price', (tester) async {
    final support = due(FakeLauncher());
    await pumpPage(tester, support, 'take-5');
    expect(find.text(askText), findsNothing);

    await support.takeHeard('take-5');
    await tester.pump();

    expect(find.text(askText), findsOneWidget);
    expect(find.text('SUPPORT'), findsOneWidget);
    expect(find.text('NOT NOW'), findsOneWidget);
    expect(find.text("Don't ask again"), findsOneWidget);
    expect(find.textContaining('€'), findsNothing);
    expect(find.textContaining(r'$'), findsNothing);
  });

  testWidgets('a take heard elsewhere is counted but asks nothing', (tester) async {
    final support = due(FakeLauncher());
    await pumpPage(tester, support, 'take-1');

    await support.takeHeard('take-5');
    await tester.pump();

    expect(find.text(askText), findsNothing);
    expect(support.controller.state.actions, 5);
    expect(support.controller.state.asks, 0);
  });

  testWidgets('leaving the song page takes the ask away', (tester) async {
    final support = due(FakeLauncher());
    await pumpPage(tester, support, 'take-5');
    await support.takeHeard('take-5');
    await tester.pump();
    expect(find.text(askText), findsOneWidget);

    await pumpPage(tester, support, null);
    expect(support.controller.visible, isFalse);

    await pumpPage(tester, support, 'take-5');
    expect(find.text(askText), findsNothing);
  });

  testWidgets('Support opens the dark checkout with this placement', (tester) async {
    final launcher = FakeLauncher();
    final support = due(launcher);
    await pumpPage(tester, support, 'take-5');
    await support.takeHeard('take-5');
    await tester.pump();

    await tester.tap(find.text('SUPPORT'));
    await tester.pump();

    expect(launcher.opened.single.toString(),
        'https://hackyourself.io/support/s/studio-localhost?theme=dark&ref=after-first-listen');
    expect(find.text(askText), findsNothing);
  });

  testWidgets('the Settings entry still works after "don\'t ask again"', (tester) async {
    final launcher = FakeLauncher();
    final support = due(launcher, from: const SupportState(activeDays: 9, actions: 20, declined: true));

    await support.takeHeard('take-5');
    expect(await support.openFromMenu(), isTrue);

    expect(launcher.opened.single.queryParameters, {'theme': 'dark', 'ref': 'menu'});
    expect(support.controller.visible, isFalse);
  });
}
