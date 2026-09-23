import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/game_stream_page.dart';
import 'package:fushi/src/pages/implementations/game_stream_settings_sheet.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';

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
    await tester.tap(find.text('720p'));
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
}
