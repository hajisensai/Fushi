import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/second_screen_main.dart';
import 'package:fushi/src/second_screen/game_stream_panel_host.dart';
import 'package:fushi/src/second_screen/second_screen_host.dart';
import 'package:fushi/src/sync/game_stream_companion_bridge.dart';

import 'fake_second_screen_platform.dart';

const SecondScreenPanelMode _companion = SecondScreenPanelMode.companion;
const SecondScreenPanelMode _stream = SecondScreenPanelMode.gameStream;

void main() {
  late FakeSecondScreenPlatform platform;
  late SecondScreenHost host;

  setUp(() async {
    platform = FakeSecondScreenPlatform(
      displays: <SecondScreenDisplayInfo>[thorBottomScreen],
    );
    host = SecondScreenHost(platform);
    await host.start();
  });

  tearDown(() => host.dispose());

  test('start lists displays; a request puts the panel up', () async {
    expect(host.displays.value, <SecondScreenDisplayInfo>[thorBottomScreen]);
    await host.request(_companion, 4);
    expect(platform.calls, <String>['show:4:companion']);
    expect(
      host.panel.value,
      const SecondScreenPanelPlacement(mode: _companion, displayId: 4),
    );
    await host.request(_companion, 4);
    expect(platform.calls, hasLength(1), reason: 'already placed');
  });

  test('the game stream takes the screen and gives it back', () async {
    await host.request(_companion, 4);
    await host.request(_stream, 4);
    expect(host.panel.value?.mode, _stream);
    // The companion asking again while the stream holds it changes nothing.
    await host.request(_companion, 4);
    expect(host.panel.value?.mode, _stream);
    await host.request(_stream, null);
    expect(host.panel.value?.mode, _companion);
    expect(platform.calls, <String>[
      'show:4:companion',
      'show:4:gameStream',
      'show:4:companion',
    ]);
    await host.request(_companion, null);
    expect(host.panel.value, isNull);
    expect(platform.calls.last, 'dismiss');
  });

  test('messages are tagged and posts gated by the panel mode', () async {
    final List<SecondScreenPanelMessage> received =
        <SecondScreenPanelMessage>[];
    final StreamSubscription<SecondScreenPanelMessage> sub = host.messages
        .listen(received.add);
    addTearDown(sub.cancel);
    await host.request(_stream, 4);
    platform.emit(const SecondScreenPanelMessageReceived('{"type":"ready"}'));
    await pumpEventQueue();
    expect(received.single.mode, _stream);
    expect(await host.post(_companion, 'x'), isFalse);
    expect(await host.post(_stream, 'y'), isTrue);
    expect(platform.sent, <String>['y']);
  });

  test(
    'after the panel went away the next request reaches the platform',
    () async {
      await host.request(_companion, 4);
      platform.detach(); // Crashed, or the host Activity stopped.
      await host.request(_companion, 4);
      expect(platform.calls, <String>['show:4:companion', 'show:4:companion']);

      // Stopped host: the platform side still wants the panel back on start, so
      // a dismiss now must reach it although nothing is attached.
      platform.attachOnShow = false;
      platform.detach();
      await host.request(_companion, null);
      expect(platform.calls.last, 'dismiss');
    },
  );

  test('a launch that could not start is asked again', () async {
    platform.launchWorks = false;
    await host.request(_companion, 4);
    platform.launchWorks = true;
    await host.request(_companion, 4);
    expect(platform.calls, <String>['show:4:companion', 'show:4:companion']);
    expect(host.panel.value?.mode, _companion);
  });

  test('hostReset voids the placement even with no attached edge', () async {
    int resets = 0;
    host.resets.addListener(() => resets++);
    platform.attachOnShow = false;
    await host.request(_stream, 4);
    platform.emit(
      const SecondScreenHostReset(<SecondScreenDisplayInfo>[hdmiScreen]),
    );
    expect(resets, 1);
    expect(host.panel.value, isNull);
    expect(host.displays.value.single.id, 7);
    await host.request(_stream, 4);
    expect(platform.calls, <String>['show:4:gameStream', 'show:4:gameStream']);
  });

  group('method channel decoding', () {
    test('panelAttached, hostReset, displaysChanged and unknown calls', () {
      final Map<String, Object?> raw = <String, Object?>{
        'id': 4,
        'name': 'Screen-2',
        'widthPx': 1080,
        'heightPx': 1240,
        'widthDp': 468.3,
        'heightDp': 537.7,
        'densityDpi': 369,
      };
      final SecondScreenPlatformEvent? attached =
          MethodChannelSecondScreenPlatform.decode(
            const MethodCall('panelAttached', <String, Object?>{
              'mode': 'gameStream',
              'displayId': 4,
            }),
          );
      expect(
        (attached! as SecondScreenPanelAttached).placement,
        const SecondScreenPanelPlacement(mode: _stream, displayId: 4),
      );
      expect(
        (MethodChannelSecondScreenPlatform.decode(
                  const MethodCall('panelAttached'),
                )!
                as SecondScreenPanelAttached)
            .placement,
        isNull,
      );
      final SecondScreenPlatformEvent? reset =
          MethodChannelSecondScreenPlatform.decode(
            MethodCall('hostReset', <Object?>[raw, 'junk']),
          );
      expect(
        (reset! as SecondScreenHostReset).displays,
        <SecondScreenDisplayInfo>[thorBottomScreen],
      );
      expect(thorBottomScreen.fingerprint, 'Screen-2|468x538');
      final SecondScreenPlatformEvent? changed =
          MethodChannelSecondScreenPlatform.decode(
            const MethodCall('displaysChanged', <Object?>[]),
          );
      expect((changed! as SecondScreenDisplaysChanged).displays, isEmpty);
      expect(
        MethodChannelSecondScreenPlatform.decode(const MethodCall('nope')),
        isNull,
      );
    });

    test('the panel entry point reads its mode and rejects others', () {
      expect(
        secondScreenPanelModeOf(<String, Object?>{'mode': 'gameStream'}),
        _stream,
      );
      expect(
        secondScreenPanelModeOf(<String, Object?>{'mode': 'companion'}),
        _companion,
      );
      expect(() => secondScreenPanelModeOf(null), throwsStateError);
    });
  });

  group('game stream client', () {
    late Directory spills;
    late SecondScreenGameStreamPanelHost stream;

    setUp(() {
      spills = Directory.systemTemp.createTempSync('gs_spill');
      stream = SecondScreenGameStreamPanelHost(host, spillRoot: spills);
    });

    tearDown(() {
      if (spills.existsSync()) spills.deleteSync(recursive: true);
    });

    test('attached and messages only follow the game stream panel', () async {
      await stream.start();
      final List<GameStreamCompanionMessage> received =
          <GameStreamCompanionMessage>[];
      final StreamSubscription<GameStreamCompanionMessage> sub = stream.messages
          .listen(received.add);
      addTearDown(sub.cancel);

      await host.request(_companion, 4);
      expect(stream.attached.value, isFalse);
      platform.emit(
        SecondScreenPanelMessageReceived(
          const GameStreamCompanionReady().encode(),
        ),
      );
      await pumpEventQueue();
      expect(received, isEmpty, reason: 'a companion message');
      await expectLater(
        stream.send(const GameStreamCompanionResult(revision: 1)),
        throwsStateError,
        reason: 'the companion panel is up, not the stream panel',
      );

      await stream.show(4);
      expect(stream.attached.value, isTrue);
      platform.emit(
        SecondScreenPanelMessageReceived(
          const GameStreamCompanionReady().encode(),
        ),
      );
      await pumpEventQueue();
      expect(received.single, isA<GameStreamCompanionReady>());
      await stream.send(const GameStreamCompanionResult(revision: 1));
      expect(platform.sent, hasLength(1));
    });

    test(
      'disposing the session gives the screen back to the companion',
      () async {
        await stream.start();
        await host.request(_companion, 4);
        await stream.show(4);
        stream.dispose();
        await pumpEventQueue();
        expect(host.panel.value?.mode, _companion);
        expect(platform.calls.last, 'show:4:companion');
      },
    );
  });
}
