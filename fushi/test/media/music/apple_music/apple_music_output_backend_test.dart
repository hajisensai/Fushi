import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi_engine/media/music/apple_music/apple_music_library_client.dart'
    show AppleMusicUserCredentials;

import 'package:fushi/src/media/music/apple_music/apple_music_bridge.dart';
import 'package:fushi/src/media/music/apple_music/apple_music_native_bridge.dart';
import 'package:fushi/src/media/music/apple_music/apple_music_output_backend.dart';
import 'package:fushi/src/media/music/apple_music/apple_music_web_bridge.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/music_routing_backend.dart';

/// 记录调用、由测试手动推事件的桥。
class _FakeBridge implements AppleMusicBridge {
  final StreamController<AppleMusicPlayerEvent> ctrl =
      StreamController<AppleMusicPlayerEvent>.broadcast(sync: true);
  final List<String> calls = <String>[];
  Exception? playError;
  Completer<void>? playGate;

  /// 按曲目卡住 play（模拟原生 / 网页 setQueue 的完成顺序与下发顺序不同）。
  final Map<String, Completer<void>> gateFor = <String, Completer<void>>{};

  /// 最后一个落地的 play（桥里实际排着的那首）。
  String? applied;

  @override
  Stream<AppleMusicPlayerEvent> get events => ctrl.stream;

  @override
  Future<void> play(
    String songId, {
    int startMs = 0,
    bool autoplay = true,
  }) async {
    calls.add('play:$songId:$autoplay');
    await playGate?.future;
    await gateFor[songId]?.future;
    final Exception? e = playError;
    if (e != null) throw e;
    applied = songId;
  }

  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> resume() async => calls.add('resume');
  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Future<void> seek(int positionMs) async => calls.add('seek:$positionMs');
  @override
  Future<void> setVolume(double volume) async => calls.add('volume:$volume');
  @override
  Future<AppleMusicAccountState> accountState() async =>
      AppleMusicAccountState.signedOut;
  @override
  Future<AppleMusicAccountState> authorize(BuildContext context) async =>
      AppleMusicAccountState.signedOut;
  @override
  Future<void> unauthorize() async {}
  @override
  Future<AppleMusicUserCredentials?> userCredentials() async => null;
  @override
  Future<void> dispose() async {}
}

MusicPlayItem _item(String id, {int? durationMs = 200000}) => MusicPlayItem(
  trackUid: 'uid-$id',
  path: 'fushi-apple-music://song/$id',
  title: 'Song $id',
  durationMs: durationMs,
);

void main() {
  group('AppleMusicOutputBackend', () {
    late _FakeBridge bridge;
    late AppleMusicOutputBackend backend;
    late List<MusicBackendEvent> events;

    setUp(() {
      bridge = _FakeBridge();
      backend = AppleMusicOutputBackend(bridge);
      events = <MusicBackendEvent>[];
      backend.events.listen(events.add);
    });

    tearDown(() => backend.dispose());

    test('openPair plays the catalog id and forwards progress', () async {
      await backend.openPair(_item('1'), null, play: true);
      expect(bridge.calls, <String>['play:1:true']);
      bridge.ctrl.add(const AppleMusicProgress(positionMs: 1500, songId: '1'));
      bridge.ctrl.add(const AppleMusicPlayingChanged(true, songId: '1'));
      await Future<void>.delayed(Duration.zero);
      final MusicBackendPosition pos = events
          .whereType<MusicBackendPosition>()
          .last;
      expect(pos.position, const Duration(milliseconds: 1500));
      // 桥没给时长时取播放项的。
      expect(pos.duration, const Duration(milliseconds: 200000));
      expect(events.whereType<MusicBackendPlaying>().single.playing, isTrue);
    });

    test(
      'ended without next completes; with next plays it and advances',
      () async {
        await backend.openPair(_item('1'), null, play: true);
        bridge.ctrl.add(const AppleMusicEnded(songId: '1'));
        await Future<void>.delayed(Duration.zero);
        expect(events.whereType<MusicBackendCompleted>(), hasLength(1));

        await backend.openPair(_item('1'), _item('2'), play: true);
        bridge.ctrl.add(const AppleMusicEnded(songId: '1'));
        await Future<void>.delayed(Duration.zero);
        expect(bridge.calls.last, 'play:2:true');
        expect(
          events.whereType<MusicBackendAdvanced>().single.trackUid,
          'uid-2',
        );
      },
    );

    test('replaceNext changes what plays after the current song', () async {
      await backend.openPair(_item('1'), _item('2'), play: true);
      await backend.replaceNext(_item('3'));
      bridge.ctrl.add(const AppleMusicEnded(songId: '1'));
      await Future<void>.delayed(Duration.zero);
      expect(bridge.calls.last, 'play:3:true');
      expect(events.whereType<MusicBackendAdvanced>().single.trackUid, 'uid-3');
    });

    test('events for another song are stale and dropped', () async {
      await backend.openPair(_item('2'), null, play: true);
      bridge.ctrl.add(const AppleMusicEnded(songId: '1'));
      bridge.ctrl.add(const AppleMusicProgress(positionMs: 9, songId: '1'));
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<MusicBackendCompleted>(), isEmpty);
      expect(
        events.whereType<MusicBackendPosition>().map(
          (MusicBackendPosition p) => p.position,
        ),
        <Duration>[Duration.zero],
      );
    });

    test(
      'open failure throws MusicTrackOpenException for this track',
      () async {
        bridge.playError = const AppleMusicBridgeException('play', 'not found');
        await expectLater(
          backend.openPair(_item('9'), null, play: true),
          throwsA(
            isA<MusicTrackOpenException>()
                .having(
                  (MusicTrackOpenException e) => e.failure.trackUid,
                  'trackUid',
                  'uid-9',
                )
                .having(
                  (MusicTrackOpenException e) => e.failure.reason,
                  'reason',
                  MusicPlaybackFailure.trackUnavailable,
                ),
          ),
        );
      },
    );

    test('a newer openPair voids an in-flight one', () async {
      final Completer<void> gate = Completer<void>();
      bridge.playGate = gate;
      final Future<void> first = backend.openPair(_item('1'), null, play: true);
      bridge.playGate = null;
      final Future<void> second = backend.openPair(
        _item('2'),
        null,
        play: true,
      );
      gate.complete();
      await first;
      await second;
      bridge.ctrl.add(const AppleMusicProgress(positionMs: 5, songId: '2'));
      await Future<void>.delayed(Duration.zero);
      expect(
        events.whereType<MusicBackendPosition>().last.position,
        const Duration(milliseconds: 5),
      );
    });

    test(
      'rapid switches are issued one at a time and the last one wins',
      () async {
        // A 的 setQueue 卡住：B、C 不能在它落地前并发下发（否则 A 晚落地会把队列换回 A）；
        // A 落地后只下发最后一首 C，B 已被作废不再下发。
        final Completer<void> gateA = Completer<void>();
        bridge.gateFor['1'] = gateA;
        final Future<void> a = backend.openPair(_item('1'), null, play: true);
        final Future<void> b = backend.openPair(_item('2'), null, play: true);
        final Future<void> c = backend.openPair(_item('3'), null, play: true);
        await Future<void>.delayed(Duration.zero);
        expect(bridge.calls, <String>['play:1:true']);
        gateA.complete();
        await Future.wait(<Future<void>>[a, b, c]);
        expect(bridge.calls, <String>['play:1:true', 'play:3:true']);
        expect(bridge.applied, '3');
        // 后端认定的当前曲与桥里实际那首一致：C 的进度照常转发。
        bridge.ctrl.add(const AppleMusicProgress(positionMs: 42, songId: '3'));
        await Future<void>.delayed(Duration.zero);
        expect(
          events.whereType<MusicBackendPosition>().last.position,
          const Duration(milliseconds: 42),
        );
      },
    );

    test(
      'stop waits for an in-flight open so the late open cannot resume',
      () async {
        final Completer<void> gate = Completer<void>();
        bridge.gateFor['1'] = gate;
        final Future<void> open = backend.openPair(
          _item('1'),
          null,
          play: true,
        );
        final Future<void> stop = backend.stop();
        await Future<void>.delayed(Duration.zero);
        expect(bridge.calls, <String>['play:1:true']);
        gate.complete();
        await open;
        await stop;
        expect(bridge.calls, <String>['play:1:true', 'stop']);
      },
    );

    test('a lost bridge session fails the current track', () async {
      await backend.openPair(_item('1'), null, play: true);
      bridge.ctrl.add(const AppleMusicSessionLost('renderer_gone'));
      await Future<void>.delayed(Duration.zero);
      final MusicBackendFailed f = events
          .whereType<MusicBackendFailed>()
          .single;
      expect(f.trackUid, 'uid-1');
      expect(f.reason, MusicPlaybackFailure.appleMusicSessionLost);
      // 当前曲已放下：传输命令不再对着桥发。
      await backend.play();
      await backend.seek(const Duration(seconds: 1));
      expect(bridge.calls, <String>['play:1:true']);
    });

    test('signing out fails the current track; signing in does not', () async {
      await backend.openPair(_item('1'), null, play: true);
      bridge.ctrl.add(
        const AppleMusicAccountChanged(
          AppleMusicAccountState(
            status: AppleMusicAuthStatus.authorized,
            canPlayCatalogContent: true,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<MusicBackendFailed>(), isEmpty);
      bridge.ctrl.add(
        const AppleMusicAccountChanged(AppleMusicAccountState.signedOut),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        events.whereType<MusicBackendFailed>().single.reason,
        MusicPlaybackFailure.appleMusicSignedOut,
      );
    });

    test('playback errors fail the current track as unavailable', () async {
      await backend.openPair(_item('1'), null, play: true);
      bridge.ctrl.add(const AppleMusicPlaybackError('DRM', songId: '1'));
      await Future<void>.delayed(Duration.zero);
      final MusicBackendFailed f = events
          .whereType<MusicBackendFailed>()
          .single;
      expect(f.trackUid, 'uid-1');
      expect(f.reason, MusicPlaybackFailure.trackUnavailable);
    });

    test(
      'transport and volume go to the bridge; no signal path or devices',
      () async {
        await backend.openPair(_item('1'), null, play: false);
        await backend.pause();
        await backend.play();
        await backend.seek(const Duration(seconds: 3));
        await backend.applySettings(
          const MusicOutputSettings(
            gapless: true,
            replayGain: MusicReplayGainMode.off,
            volume: 50,
          ),
        );
        await backend.stop();
        expect(bridge.calls, <String>[
          'play:1:false',
          'pause',
          'resume',
          'seek:3000',
          'volume:0.5',
          'stop',
        ]);
        expect(await backend.readSignalPath(), isNull);
        expect(await backend.listAudioDevices(), isEmpty);
      },
    );
  });

  group('engine over the Apple Music backend', () {
    late _FakeBridge bridge;
    late MusicPlayerEngine engine;
    late List<MusicBackendFailed> failures;

    setUp(() {
      bridge = _FakeBridge();
      failures = <MusicBackendFailed>[];
      engine = MusicPlayerEngine(
        backendFactory: () => AppleMusicOutputBackend(bridge),
      )..onPlaybackFailed = failures.add;
    });
    tearDown(() => engine.dispose());

    Future<void> settle() async {
      for (int i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    for (final (
          String name,
          AppleMusicPlayerEvent lost,
          MusicPlaybackFailure reason,
        )
        in <(String, AppleMusicPlayerEvent, MusicPlaybackFailure)>[
          (
            'bridge session lost',
            const AppleMusicSessionLost('reauthorized'),
            MusicPlaybackFailure.appleMusicSessionLost,
          ),
          (
            'signed out',
            const AppleMusicAccountChanged(AppleMusicAccountState.signedOut),
            MusicPlaybackFailure.appleMusicSignedOut,
          ),
        ]) {
      test('$name: engine stops, tells the user, and play reopens', () async {
        await engine.playQueue(<MusicPlayItem>[_item('1'), _item('2')]);
        await settle();
        expect(engine.isPlaying, isTrue);
        expect(bridge.calls, <String>['play:1:true']);

        bridge.ctrl.add(lost);
        await settle();
        expect(engine.isPlaying, isFalse);
        expect(engine.current?.trackUid, 'uid-1', reason: '不自动跳到下一首');
        expect(failures.single.reason, reason);

        await engine.play();
        await settle();
        // 走 openPair 重新 setQueue，而不是对着已经没了的那一代发 resume。
        expect(bridge.calls, <String>['play:1:true', 'play:1:true']);
        expect(bridge.calls, isNot(contains('resume')));
        expect(engine.isPlaying, isTrue);
      });
    }
  });

  test(
    'route claims only Apple Music paths and declares reduced capabilities',
    () {
      final MusicBackendRoute route = appleMusicBackendRoute(_FakeBridge.new);
      expect(route.handles(_item('1')), isTrue);
      expect(
        route.handles(
          const MusicPlayItem(
            trackUid: 'x',
            path: 'https://audio.example/1.m4a',
            title: 'x',
          ),
        ),
        isFalse,
      );
      expect(route.capabilities.signalPath, isFalse);
      expect(route.capabilities.abLoop, isFalse);
    },
  );

  group('native bridge events', () {
    test('parses progress / playing / ended / error / account', () {
      final AppleMusicProgress p =
          parseAppleMusicNativeEvent(<String, Object?>{
                'type': 'progress',
                'positionMs': 1200.4,
                'durationMs': 0,
                'songId': '7',
              })!
              as AppleMusicProgress;
      expect(p.positionMs, 1200);
      expect(p.durationMs, isNull);
      expect(p.songId, '7');
      expect(
        parseAppleMusicNativeEvent(<String, Object?>{
          'type': 'ended',
          'songId': '7',
        }),
        isA<AppleMusicEnded>(),
      );
      final AppleMusicAccountChanged a =
          parseAppleMusicNativeEvent(<String, Object?>{
                'type': 'account',
                'status': 'authorized',
                'canPlayCatalogContent': true,
                'storefront': 'JP',
              })!
              as AppleMusicAccountChanged;
      expect(a.state.canPlayFullTracks, isTrue);
      expect(a.state.storefront, 'jp');
      expect(
        parseAppleMusicNativeEvent(<String, Object?>{'type': 'x'}),
        isNull,
      );
      expect(parseAppleMusicNativeEvent('nope'), isNull);
    });
  });

  group('web bridge events', () {
    test('maps MusicKit playback states to playing edges and a single end', () {
      ({AppleMusicPlayerEvent? event, int? state}) r = parseAppleMusicWebEvent(
        <String, Object?>{
          'type': 'state',
          'state': MusicKitPlaybackState.loading,
        },
      );
      expect(r.event, isNull);
      r = parseAppleMusicWebEvent(<String, Object?>{
        'type': 'state',
        'state': MusicKitPlaybackState.playing,
        'songId': '1',
      }, lastState: r.state);
      expect((r.event! as AppleMusicPlayingChanged).playing, isTrue);
      // 过渡态不改出声判断。
      r = parseAppleMusicWebEvent(<String, Object?>{
        'type': 'state',
        'state': MusicKitPlaybackState.waiting,
      }, lastState: r.state);
      expect(r.event, isNull);
      expect(r.state, MusicKitPlaybackState.playing);
      r = parseAppleMusicWebEvent(<String, Object?>{
        'type': 'state',
        'state': MusicKitPlaybackState.paused,
      }, lastState: r.state);
      expect((r.event! as AppleMusicPlayingChanged).playing, isFalse);
      r = parseAppleMusicWebEvent(<String, Object?>{
        'type': 'state',
        'state': MusicKitPlaybackState.ended,
        'songId': '1',
      }, lastState: r.state);
      expect(r.event, isA<AppleMusicEnded>());
      // 同一状态重复上报不再发。
      r = parseAppleMusicWebEvent(<String, Object?>{
        'type': 'item',
        'state': MusicKitPlaybackState.ended,
      }, lastState: r.state);
      expect(r.event, isNull);
    });

    test('time, error and auth events', () {
      final AppleMusicProgress p =
          parseAppleMusicWebEvent(<String, Object?>{
                'type': 'time',
                'positionMs': 3000,
                'durationMs': 210000,
                'songId': '1',
              }).event!
              as AppleMusicProgress;
      expect(p.durationMs, 210000);
      final AppleMusicPlaybackError e =
          parseAppleMusicWebEvent(<String, Object?>{
                'type': 'error',
                'name': 'MEDIA_KEY',
                'message': 'license failed',
              }).event!
              as AppleMusicPlaybackError;
      expect(e.message, 'MEDIA_KEY: license failed');
      final AppleMusicAccountChanged a =
          parseAppleMusicWebEvent(<String, Object?>{
                'type': 'auth',
                'authorized': false,
              }).event!
              as AppleMusicAccountChanged;
      expect(a.state.isAuthorized, isFalse);
      expect(
        parseAppleMusicWebEvent(<String, Object?>{'type': 'ready'}).event,
        isNull,
      );
    });
  });

  test('macOS major version parsing gates the native bridge', () {
    expect(macOSMajorVersion('Version 14.5 (Build 23F79)'), 14);
    expect(macOSMajorVersion('Version 13.6.1 (Build 22G313)'), 13);
    expect(macOSMajorVersion('Version 27.0 (Build 27A1)'), 27);
    expect(macOSMajorVersion('garbage'), 0);
  });
}
