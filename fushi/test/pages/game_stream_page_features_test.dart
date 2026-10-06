import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/game_stream_page.dart';
import 'package:fushi/src/pages/implementations/game_stream_settings_sheet.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';

Future<(List<GameStreamInputEvent>, Rect)> _pumpMousePage(
  WidgetTester tester, {
  List<String> features = GameStreamFeature.all,
}) async {
  final List<GameStreamInputEvent> sent = <GameStreamInputEvent>[];
  final GameStreamInputComposer composer = GameStreamInputComposer(
    sessionId: 's1',
    clientId: 'c1',
    sender: (GameStreamInputEvent event) async {
      sent.add(event);
      return GameStreamInputAck(sequence: event.sequence, accepted: true);
    },
  );
  await tester.pumpWidget(
    MaterialApp(
      home: GameStreamPage(
        sessionId: 's1',
        clientId: 'c1',
        inputComposer: composer,
        videoPlaceholder: const Text('remote frame'),
        session: GameStreamSession.create(
          sessionId: 's1',
          now: DateTime.utc(2026, 9, 23),
          features: features,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (sent, tester.getRect(find.byKey(GameStreamPage.videoKey)));
}

String _describe(GameStreamInputEvent e) =>
    '${e.action.name}:${e.button ?? e.dy ?? ''}';

void main() {
  test('host mine details become actionable receiver messages', () {
    expect(
      gameStreamMineMessage(
        const GameStreamMineResult(ok: false, detail: 'duplicate'),
      ),
      t.game_stream_mine_duplicate,
    );
    expect(
      gameStreamMineMessage(
        const GameStreamMineResult(ok: false, detail: 'line_snapshot_missing'),
      ),
      t.game_stream_mine_snapshot_missing,
    );
    expect(
      gameStreamMineMessage(
        const GameStreamMineResult(ok: false, detail: 'host_error'),
      ),
      t.game_stream_mine_host_error,
    );
    expect(
      gameStreamMineMessage(const GameStreamMineResult(ok: true)),
      t.game_stream_mine_success,
    );
  });

  test('hardware keys and controller buttons map to host input', () {
    expect(gameStreamHostKeyName(LogicalKeyboardKey.keyQ), 'Q');
    expect(gameStreamHostKeyName(LogicalKeyboardKey.digit7), '7');
    expect(gameStreamHostKeyName(LogicalKeyboardKey.f11), 'F11');
    expect(gameStreamHostKeyName(LogicalKeyboardKey.arrowLeft), 'Left');
    expect(gameStreamHostKeyName(LogicalKeyboardKey.numpadEnter), 'Enter');
    expect(gameStreamHostKeyName(LogicalKeyboardKey.capsLock), isNull);
    expect(
      gameStreamPadButtonFor(LogicalKeyboardKey.gameButtonA),
      GameStreamVirtualButton.confirm,
    );
    expect(
      gameStreamPadButtonFor(LogicalKeyboardKey.gameButtonRight1),
      GameStreamVirtualButton.shoulderRight,
    );
  });

  testWidgets('settings sheet returns the edited parameters', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    GameStreamVideoSettings? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async {
              saved = await showGameStreamSettingsSheet(
                context,
                initial: const GameStreamVideoSettings(),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // 分辨率档位多于分段控件能容纳的数量，MD3 下按统一判据退成「点行 → 弹出
    // 菜单选值」：先点开分辨率行，再在菜单里选 720p。
    await tester.tap(find.text(t.game_stream_settings_resolution));
    await tester.pumpAndSettle();
    await tester.tap(find.text('720p').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(GameStreamSettingsSheet.saveKey));
    await tester.pumpAndSettle();
    expect(saved?.maxHeight, 720);
    expect(
      saved?.bitrateKbps,
      GameStreamVideoSettings.recommendedBitrateKbps(
        maxHeight: 720,
        maxFps: 60,
      ),
      reason: 'An untouched bitrate follows the recommended table',
    );
  });

  testWidgets('two-finger tap right-clicks on a host that supports it', (
    WidgetTester tester,
  ) async {
    final List<GameStreamInputEvent> sent = <GameStreamInputEvent>[];
    final GameStreamInputComposer composer = GameStreamInputComposer(
      sessionId: 's1',
      clientId: 'c1',
      sender: (GameStreamInputEvent event) async {
        sent.add(event);
        return GameStreamInputAck(sequence: event.sequence, accepted: true);
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: GameStreamPage(
          sessionId: 's1',
          clientId: 'c1',
          inputComposer: composer,
          videoPlaceholder: const Text('remote frame'),
          session: GameStreamSession.create(
            sessionId: 's1',
            now: DateTime.utc(2026, 9, 23),
            features: GameStreamFeature.all,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final Rect video = tester.getRect(find.byKey(GameStreamPage.videoKey));
    final Offset at = video.topLeft + Offset(video.width / 2, 100);
    final TestGesture first = await tester.startGesture(at, pointer: 1);
    final TestGesture second = await tester.startGesture(
      at + const Offset(40, 0),
      pointer: 2,
    );
    await second.up();
    await first.up();
    await tester.pump();
    expect(
      sent.map((GameStreamInputEvent e) => '${e.action.name}:${e.button}'),
      <String>['down:null', 'up:null', 'down:right', 'up:right'],
    );
  });

  testWidgets(
    'a desktop mouse sends its own buttons, drags and wheel',
    (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      final List<GameStreamInputEvent> sent = <GameStreamInputEvent>[];
      final GameStreamInputComposer composer = GameStreamInputComposer(
        sessionId: 's1',
        clientId: 'c1',
        sender: (GameStreamInputEvent event) async {
          sent.add(event);
          return GameStreamInputAck(sequence: event.sequence, accepted: true);
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: GameStreamPage(
            sessionId: 's1',
            clientId: 'c1',
            inputComposer: composer,
            videoPlaceholder: const Text('remote frame'),
            session: GameStreamSession.create(
              sessionId: 's1',
              now: DateTime.utc(2026, 9, 23),
              features: GameStreamFeature.all,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final Rect video = tester.getRect(find.byKey(GameStreamPage.videoKey));
      final Offset at = video.topLeft + Offset(video.width / 2, 100);
      String describe(GameStreamInputEvent e) =>
          '${e.action.name}:${e.button ?? e.dy ?? ''}';

      // A right press is a right press -- not the touch path's left tap.
      final TestGesture right = await tester.startGesture(
        at,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await right.up();
      await tester.pump();
      expect(sent.map(describe), <String>['down:right', 'up:right']);

      // A left drag presses, moves, releases.
      sent.clear();
      final TestGesture left = await tester.startGesture(
        at,
        kind: PointerDeviceKind.mouse,
      );
      await left.moveBy(const Offset(30, 0));
      await left.up();
      await tester.pump();
      expect(sent.map(describe), <String>['down:', 'move:', 'up:']);

      // One detent (Windows: 100 px at 100% scale) is one host notch -- a VN
      // advances one line, not two.
      sent.clear();
      final TestPointer wheel = TestPointer(9, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(wheel.hover(at));
      await tester.sendEventToBinding(wheel.scroll(const Offset(0, 100)));
      await tester.pump();
      expect(sent.map(describe), <String>['wheel:1.0']);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('a press cut off by a layout change does not click again', (
    WidgetTester tester,
  ) async {
    final (List<GameStreamInputEvent> sent, Rect video) = await _pumpMousePage(
      tester,
    );
    final Offset at = video.topLeft + Offset(video.width / 2, 100);
    final TestGesture drag = await tester.startGesture(
      at,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    // The window resizes mid-drag: the held press is released on the host.
    tester.view.physicalSize = const Size(2700, 1800);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpAndSettle();
    expect(sent.map(_describe), <String>['down:', 'up:']);

    // The button is still physically down. Before the fix this move became a
    // fresh press -- a click the user never made.
    await drag.moveBy(const Offset(20, 0));
    await drag.up();
    await tester.pump();
    expect(sent.map(_describe), <String>['down:', 'up:']);

    // The next real press works normally.
    final TestGesture again = await tester.startGesture(
      at,
      kind: PointerDeviceKind.mouse,
    );
    await again.up();
    await tester.pump();
    expect(sent.map(_describe), <String>['down:', 'up:', 'down:', 'up:']);
  });

  testWidgets('a host without buttons or wheel gets neither from a mouse', (
    WidgetTester tester,
  ) async {
    final (List<GameStreamInputEvent> sent, Rect video) = await _pumpMousePage(
      tester,
      features: const <String>[],
    );
    final Offset at = video.topLeft + Offset(video.width / 2, 100);
    final TestGesture right = await tester.startGesture(
      at,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await right.up();
    final TestPointer wheel = TestPointer(9, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(wheel.hover(at));
    await tester.sendEventToBinding(wheel.scroll(const Offset(0, 500)));
    await tester.pump();
    expect(
      sent.where(
        (GameStreamInputEvent e) =>
            e.button == 'right' || e.action == GameStreamInputAction.wheel,
      ),
      isEmpty,
      reason: 'not a left click in disguise, and no wheel the host rejects',
    );
    expect(
      sent.where(
        (GameStreamInputEvent e) => e.action != GameStreamInputAction.move,
      ),
      isEmpty,
    );
  });
}
