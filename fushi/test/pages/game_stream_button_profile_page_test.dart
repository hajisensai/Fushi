import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/game_stream_button_profile.dart';
import 'package:fushi/src/pages/implementations/game_stream_page.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';

void main() {
  testWidgets('default profile: A presses the pad confirm, R2 holds Control', (
    WidgetTester tester,
  ) async {
    final List<GameStreamInputEvent> sent = <GameStreamInputEvent>[];
    await _pumpPage(tester, sent);

    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.gameButtonA,
      platform: 'android',
    );
    await tester.sendKeyUpEvent(
      LogicalKeyboardKey.gameButtonA,
      platform: 'android',
    );
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.gameButtonRight2,
      platform: 'android',
    );
    await tester.sendKeyUpEvent(
      LogicalKeyboardKey.gameButtonRight2,
      platform: 'android',
    );
    await tester.pump();

    expect(
      sent.map(
        (GameStreamInputEvent e) =>
            '${e.kind.name}:${e.action.name}:'
            '${e.button ?? e.key}',
      ),
      <String>[
        'gamepad:down:confirm',
        'gamepad:up:confirm',
        'key:down:Control',
        'key:up:Control',
      ],
    );
  });

  testWidgets('a custom profile sends its own action', (
    WidgetTester tester,
  ) async {
    final List<GameStreamInputEvent> sent = <GameStreamInputEvent>[];
    await _pumpPage(
      tester,
      sent,
      profile: const GameStreamButtonProfile().withAction(
        GameStreamPhysicalButton.a,
        const GameStreamHostKeyAction('Space'),
      ),
    );

    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.gameButtonA,
      platform: 'android',
    );
    await tester.sendKeyUpEvent(
      LogicalKeyboardKey.gameButtonA,
      platform: 'android',
    );
    await tester.pump();

    expect(sent.map((GameStreamInputEvent e) => e.key), <String?>[
      'Space',
      'Space',
    ]);
    expect(sent.map((GameStreamInputEvent e) => e.action), <Object>[
      GameStreamInputAction.down,
      GameStreamInputAction.up,
    ]);
  });

  testWidgets('right click and wheel need the host features', (
    WidgetTester tester,
  ) async {
    final List<GameStreamInputEvent> sent = <GameStreamInputEvent>[];
    // Default X = right click, L2 = wheel up.
    await _pumpPage(tester, sent);
    for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
      LogicalKeyboardKey.gameButtonX,
      LogicalKeyboardKey.gameButtonLeft2,
    ]) {
      await tester.sendKeyDownEvent(key, platform: 'android');
      await tester.sendKeyUpEvent(key, platform: 'android');
    }
    await tester.pump();
    expect(sent, isEmpty, reason: 'An older host cannot run these actions');

    await _pumpPage(
      tester,
      sent,
      features: <String>[
        GameStreamFeature.pointerButtons,
        GameStreamFeature.wheel,
      ],
    );
    for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
      LogicalKeyboardKey.gameButtonX,
      LogicalKeyboardKey.gameButtonLeft2,
    ]) {
      await tester.sendKeyDownEvent(key, platform: 'android');
      await tester.sendKeyUpEvent(key, platform: 'android');
    }
    await tester.pump();
    expect(
      sent.map(
        (GameStreamInputEvent e) =>
            '${e.action.name}:${e.button ?? ''}:${e.dy ?? ''}',
      ),
      <String>['move::', 'down:right:', 'up:right:', 'wheel::-1.0'],
    );
  });

  testWidgets('Y toggles the lookup panel without sending input', (
    WidgetTester tester,
  ) async {
    final List<GameStreamInputEvent> sent = <GameStreamInputEvent>[];
    await _pumpPage(tester, sent);
    expect(find.byKey(GameStreamPage.transcriptKey), findsOneWidget);

    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.gameButtonY,
      platform: 'android',
    );
    await tester.sendKeyUpEvent(
      LogicalKeyboardKey.gameButtonY,
      platform: 'android',
    );
    await tester.pumpAndSettle();

    expect(find.byKey(GameStreamPage.transcriptKey), findsNothing);
    expect(sent, isEmpty);
  });

  testWidgets('keyboard arrows outside the video do not reach the game', (
    WidgetTester tester,
  ) async {
    final List<GameStreamInputEvent> sent = <GameStreamInputEvent>[];
    await _pumpPage(tester, sent);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(sent, isEmpty);
  });

  testWidgets('the controls sheet saves a rebound controller button', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final List<GameStreamButtonProfile> saved = <GameStreamButtonProfile>[];
    await _pumpPage(
      tester,
      <GameStreamInputEvent>[],
      onProfileChanged: saved.add,
    );

    await tester.tap(find.byTooltip(t.game_stream_keys));
    await tester.pumpAndSettle();
    final Finder dropdown = find.byKey(
      const ValueKey<String>('game-stream-controller-action-a'),
    );
    await tester.scrollUntilVisible(
      dropdown,
      200,
      scrollable: find.descendant(
        of: find.byType(ListView).last,
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.game_stream_action_key(key: 'Space')).last);
    await tester.pumpAndSettle();

    expect(saved, hasLength(1));
    expect(
      saved.single.actionFor(GameStreamPhysicalButton.a),
      const GameStreamHostKeyAction('Space'),
    );
  });
}

Future<void> _pumpPage(
  WidgetTester tester,
  List<GameStreamInputEvent> sent, {
  GameStreamButtonProfile profile = const GameStreamButtonProfile(),
  List<String> features = const <String>[],
  ValueChanged<GameStreamButtonProfile>? onProfileChanged,
}) async {
  final GameStreamInputComposer composer = GameStreamInputComposer(
    sessionId: 's1',
    clientId: 'c1',
    sender: (GameStreamInputEvent event) async {
      sent.add(event);
      return GameStreamInputAck(sequence: event.sequence, accepted: true);
    },
  );
  addTearDown(composer.dispose);
  await tester.pumpWidget(
    MaterialApp(
      // A new key per pump: a second pump starts a fresh page and profile.
      home: GameStreamPage(
        key: UniqueKey(),
        sessionId: 's1',
        clientId: 'c1',
        inputComposer: composer,
        session: GameStreamSession.create(
          sessionId: 's1',
          now: DateTime.utc(2026, 11, 2),
          features: features,
        ),
        buttonProfile: profile,
        onButtonProfileChanged: onProfileChanged,
        videoPlaceholder: const Text('frame'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
