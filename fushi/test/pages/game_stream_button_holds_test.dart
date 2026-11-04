import 'dart:ui' show KeyEventDeviceType;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/game_stream_button_profile.dart';
import 'package:fushi/src/pages/implementations/game_stream_page.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';

/// What one controller press holds on the host, and when it is lifted.
void main() {
  testWidgets('a controller D-pad runs its profile action, keyboard arrows '
      'do not', (WidgetTester tester) async {
    final List<GameStreamInputEvent> sent = <GameStreamInputEvent>[];
    final GameStreamInputComposer composer = _composer(sent);
    await _pump(tester, composer);

    // Android reports a handheld's D-pad as arrow keys from a gamepad source
    // (MainActivity narrows the combined source so the engine names it).
    _key(tester, _down(LogicalKeyboardKey.arrowUp, KeyEventDeviceType.gamepad));
    _key(tester, _up(LogicalKeyboardKey.arrowUp, KeyEventDeviceType.gamepad));
    _key(
      tester,
      _down(LogicalKeyboardKey.arrowDown, KeyEventDeviceType.keyboard),
    );
    _key(
      tester,
      _up(LogicalKeyboardKey.arrowDown, KeyEventDeviceType.keyboard),
    );
    await tester.pump();

    expect(_describe(sent), <String>[
      'gamepad:down:dpad_up',
      'gamepad:up:dpad_up',
    ]);
  });

  testWidgets('two buttons on one host key send one down and one up', (
    WidgetTester tester,
  ) async {
    final List<GameStreamInputEvent> sent = <GameStreamInputEvent>[];
    final GameStreamInputComposer composer = _composer(sent);
    await _pump(
      tester,
      composer,
      profile: const GameStreamButtonProfile()
          .withAction(
            GameStreamPhysicalButton.a,
            const GameStreamHostKeyAction('Enter'),
          )
          .withAction(
            GameStreamPhysicalButton.b,
            const GameStreamHostKeyAction('Enter'),
          ),
    );

    await _press(tester, LogicalKeyboardKey.gameButtonA);
    await _press(tester, LogicalKeyboardKey.gameButtonB);
    await _lift(tester, LogicalKeyboardKey.gameButtonA);
    expect(_describe(sent), <String>[
      'key:down:Enter',
    ], reason: 'B still holds Enter');
    await _lift(tester, LogicalKeyboardKey.gameButtonB);
    expect(_describe(sent), <String>['key:down:Enter', 'key:up:Enter']);
  });

  testWidgets('a held key is lifted on the session that saw its down', (
    WidgetTester tester,
  ) async {
    final List<GameStreamInputEvent> oldSent = <GameStreamInputEvent>[];
    final List<GameStreamInputEvent> newSent = <GameStreamInputEvent>[];
    final GameStreamInputComposer oldComposer = _composer(oldSent);
    final GameStreamInputComposer newComposer = _composer(newSent);
    await _pump(tester, oldComposer);

    // R2 holds Control by default.
    await _press(tester, LogicalKeyboardKey.gameButtonRight2);
    await _pump(tester, newComposer);
    await _lift(tester, LogicalKeyboardKey.gameButtonRight2);

    expect(_describe(oldSent), <String>['key:down:Control', 'key:up:Control']);
    expect(newSent, isEmpty);
  });

  testWidgets('leaving the page lifts a held key', (WidgetTester tester) async {
    final List<GameStreamInputEvent> sent = <GameStreamInputEvent>[];
    final GameStreamInputComposer composer = _composer(sent);
    await _pump(tester, composer);

    await _press(tester, LogicalKeyboardKey.gameButtonRight2);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(_describe(sent), <String>['key:down:Control', 'key:up:Control']);
  });

  testWidgets('a controller click lands where the host cursor last went', (
    WidgetTester tester,
  ) async {
    final List<GameStreamInputEvent> sent = <GameStreamInputEvent>[];
    final GameStreamInputComposer composer = _composer(sent);
    await _pump(
      tester,
      composer,
      features: <String>[GameStreamFeature.pointerButtons],
    );
    // A direct-mode tap (or the desktop mouse) left the cursor here.
    await composer.pointer(
      action: GameStreamInputAction.move,
      normalized: const Offset(.2, .3),
    );
    sent.clear();

    // X is right click by default.
    await _press(tester, LogicalKeyboardKey.gameButtonX);
    await _lift(tester, LogicalKeyboardKey.gameButtonX);

    expect(
      sent.map(
        (GameStreamInputEvent e) =>
            '${e.action.name}:${e.button}:${e.x},${e.y}',
      ),
      <String>['down:right:0.2,0.3', 'up:right:0.2,0.3'],
    );
  });
}

GameStreamInputComposer _composer(List<GameStreamInputEvent> sent) {
  final GameStreamInputComposer composer = GameStreamInputComposer(
    sessionId: 's1',
    clientId: 'c1',
    sender: (GameStreamInputEvent event) async {
      sent.add(event);
      return GameStreamInputAck(sequence: event.sequence, accepted: true);
    },
  );
  addTearDown(composer.dispose);
  return composer;
}

const Key _pageKey = ValueKey<String>('page');

Future<void> _pump(
  WidgetTester tester,
  GameStreamInputComposer composer, {
  GameStreamButtonProfile profile = const GameStreamButtonProfile(),
  List<String> features = const <String>[],
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: GameStreamPage(
        key: _pageKey,
        sessionId: 's1',
        clientId: 'c1',
        inputComposer: composer,
        session: GameStreamSession.create(
          sessionId: 's1',
          now: DateTime.utc(2026, 11, 2),
          features: features,
        ),
        buttonProfile: profile,
        videoPlaceholder: const Text('frame'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(key, platform: 'android');
  await tester.pump();
}

Future<void> _lift(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyUpEvent(key, platform: 'android');
  await tester.pump();
}

/// The page's own key handler, fed an event with an explicit device type
/// (the test key simulator cannot set one).
void _key(WidgetTester tester, KeyEvent event) {
  final Focus focus = tester.widget<Focus>(
    find
        .descendant(
          of: find.byKey(_pageKey),
          matching: find.byWidgetPredicate(
            (Widget widget) =>
                widget is Focus &&
                widget.autofocus &&
                widget.onKeyEvent != null,
          ),
        )
        .first,
  );
  focus.onKeyEvent!(FocusNode(), event);
}

KeyDownEvent _down(LogicalKeyboardKey key, KeyEventDeviceType device) =>
    KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.arrowUp,
      logicalKey: key,
      timeStamp: Duration.zero,
      deviceType: device,
    );

KeyUpEvent _up(LogicalKeyboardKey key, KeyEventDeviceType device) => KeyUpEvent(
  physicalKey: PhysicalKeyboardKey.arrowUp,
  logicalKey: key,
  timeStamp: Duration.zero,
  deviceType: device,
);

List<String> _describe(List<GameStreamInputEvent> sent) => <String>[
  for (final GameStreamInputEvent e in sent)
    '${e.kind.name}:${e.action.name}:${e.button ?? e.key}',
];
