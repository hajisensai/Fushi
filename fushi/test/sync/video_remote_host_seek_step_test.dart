import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_models.dart';
import 'package:fushi/src/sync/video_remote_host.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/video_remote_service.dart';

/// 视频遥控 `seekStep` 命令（手机短 / 长步进由电脑按自己的配置执行）：能力声明、
/// 参数校验、转给播放器；以及手机侧对新旧电脑的兼容（旧电脑不声明能力时回退成
/// 固定步长的绝对 `seek`）。
void main() {
  late FushiDatabase db;
  late VideoRemoteHost host;
  late Map<String, Object?> snapshot;
  int serial = 0;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    host = VideoRemoteHost(favorites: () => FavoriteSentenceRepository(db));
  });
  tearDown(() async {
    await host.dispose();
    await db.close();
  });

  Future<Map<String, Object?>> seekStep(Object? step, Object? size) =>
      host.handle('command', <String, dynamic>{
        'sessionId': snapshot['sessionId'],
        'subtitleVersion': snapshot['subtitleVersion'],
        'requestId': 'request_${++serial}',
        'action': 'seekStep',
        'step': step,
        'size': size,
      }, 'phone');

  Matcher remoteError(int status, String code) => isA<VideoRemoteException>()
      .having((VideoRemoteException e) => e.status, 'status', status)
      .having((VideoRemoteException e) => e.code, 'code', code);

  Future<_FakePlayer> connect({required bool seekStep}) async {
    final _FakePlayer player = _FakePlayer(seekStep: seekStep);
    host.register(player.binding());
    snapshot = await host.handle('snapshot', <String, dynamic>{}, 'phone');
    return player;
  }

  test('seekStep is a known protocol action', () {
    expect(videoRemoteCommandActions, contains('seekStep'));
    expect(videoRemoteSeekSteps, <String>{'back', 'forward'});
    expect(videoRemoteSeekStepSizes, <String>{'short', 'long'});
  });

  test('a player without seek steps neither advertises nor answers', () async {
    await connect(seekStep: false);
    expect(
      snapshot['capabilities'],
      isNot(contains(videoRemoteCapabilitySeekStep)),
    );
    await expectLater(
      seekStep('forward', 'short'),
      throwsA(remoteError(409, videoRemoteActionUnsupported)),
    );
  });

  test(
    'steps reach the player; the snapshot carries its step lengths',
    () async {
      final _FakePlayer player = await connect(seekStep: true);
      expect(snapshot['capabilities'], contains(videoRemoteCapabilitySeekStep));
      expect(snapshot['seekSeconds'], 3);
      expect(snapshot['longSeekSeconds'], 45);

      expect(await seekStep('back', 'short'), <String, Object?>{'ok': true});
      await seekStep('forward', 'short');
      await seekStep('back', 'long');
      await seekStep('forward', 'long');
      expect(player.steps, <String>[
        'back short',
        'forward short',
        'back long',
        'forward long',
      ]);
    },
  );

  test('malformed steps are rejected before reaching the player', () async {
    final _FakePlayer player = await connect(seekStep: true);
    for (final (Object?, Object?) bad in <(Object?, Object?)>[
      (null, 'short'),
      ('forward', null),
      ('left', 'short'),
      ('forward', 'huge'),
      (1, 'long'),
    ]) {
      await expectLater(
        seekStep(bad.$1, bad.$2),
        throwsA(remoteError(400, 'invalid_argument')),
        reason: '$bad',
      );
    }
    expect(player.steps, isEmpty);
  });

  group('phone side: new vs old computers', () {
    const Set<String> newHost = <String>{videoRemoteCapabilitySeekStep};
    const Set<String> oldHost = <String>{videoRemoteCapabilityVolume};

    test('a computer with seekStep gets the command and owns the lengths', () {
      expect(
        videoRemoteSeekStepCommand(newHost, forward: false, long: true),
        <String, dynamic>{'step': 'back', 'size': 'long'},
      );
      expect(
        videoRemoteSeekStepCommand(newHost, forward: true, long: false),
        <String, dynamic>{'step': 'forward', 'size': 'short'},
      );
      final Map<String, dynamic> state = <String, dynamic>{
        'seekSeconds': 3,
        'longSeekSeconds': 120,
      };
      expect(videoRemoteSeekStepSeconds(state, newHost, long: false), 3);
      expect(videoRemoteSeekStepSeconds(state, newHost, long: true), 120);
    });

    test('an older computer gets no seekStep; the phone falls back to its '
        'fixed 10 / 30 s', () {
      expect(
        videoRemoteSeekStepCommand(oldHost, forward: true, long: true),
        isNull,
      );
      // 即使快照里碰巧有同名字段，没声明能力就不信它（不会发电脑不认的命令）。
      final Map<String, dynamic> state = <String, dynamic>{
        'seekSeconds': 3,
        'longSeekSeconds': 120,
      };
      expect(
        videoRemoteSeekStepSeconds(state, oldHost, long: false),
        kVideoRemoteLegacySeekSeconds,
      );
      expect(
        videoRemoteSeekStepSeconds(state, oldHost, long: true),
        kVideoRemoteLegacyLongSeekSeconds,
      );
      expect(kVideoRemoteLegacySeekSeconds, 10);
      expect(kVideoRemoteLegacyLongSeekSeconds, 30);
    });

    test('garbage lengths from a new computer fall back too', () {
      for (final Object? bad in <Object?>[null, 0, -5, '3', 2.5]) {
        expect(
          videoRemoteSeekStepSeconds(
            <String, dynamic>{'seekSeconds': bad},
            newHost,
            long: false,
          ),
          kVideoRemoteLegacySeekSeconds,
          reason: '$bad',
        );
      }
    });
  });
}

final class _FakePlayer {
  _FakePlayer({required this.seekStep});

  final bool seekStep;
  final List<VoidCallback> listeners = <VoidCallback>[];
  final List<String> steps = <String>[];

  VideoRemotePlaybackBinding binding() => VideoRemotePlaybackBinding(
    identity: () => 'video-one',
    title: () => 'Video',
    bookUid: () => 'book',
    sectionIndex: () => 0,
    cues: () => const <VideoRemoteCue>[],
    state: () => <String, Object?>{
      'playing': false,
      'positionMs': 0,
      if (seekStep) 'seekSeconds': 3,
      if (seekStep) 'longSeekSeconds': 45,
    },
    command: (String action, Map<String, dynamic> body) async {},
    mine:
        (
          VideoRemoteCue cue,
          Map<String, dynamic> fields,
          VideoRemoteMineSelection selection,
        ) async => <String, Object?>{'success': true},
    openFavorite: (FavoriteSentence favorite) async {},
    addListener: listeners.add,
    removeListener: listeners.remove,
    seekStep: seekStep
        ? ({required bool forward, required bool long}) async {
            steps.add(
              '${forward ? 'forward' : 'back'} ${long ? 'long' : 'short'}',
            );
          }
        : null,
  );
}
