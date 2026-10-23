import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/video_remote_host.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/video_remote_service.dart';

/// 视频遥控 `caret` 命令（手机触控板驱动电脑上的字幕选词光标）：能力声明、参数
/// 校验、转给播放器并回报光标落在哪。
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

  Future<Map<String, Object?>> caret(Object? step) =>
      host.handle('command', <String, dynamic>{
        'sessionId': snapshot['sessionId'],
        'subtitleVersion': snapshot['subtitleVersion'],
        'requestId': 'request_${++serial}',
        'action': 'caret',
        'caret': step,
      }, 'phone');

  Matcher remoteError(int status, String code) => isA<VideoRemoteException>()
      .having((VideoRemoteException e) => e.status, 'status', status)
      .having((VideoRemoteException e) => e.code, 'code', code);

  Future<_FakePlayer> connect({required bool caret}) async {
    final _FakePlayer player = _FakePlayer(caret: caret);
    host.register(player.binding());
    snapshot = await host.handle('snapshot', <String, dynamic>{}, 'phone');
    return player;
  }

  test('a player without the cursor neither advertises nor answers', () async {
    await connect(caret: false);
    expect(
      snapshot['capabilities'],
      isNot(contains(videoRemoteCapabilityCaret)),
    );
    await expectLater(
      caret('enter'),
      throwsA(remoteError(409, videoRemoteActionUnsupported)),
    );
  });

  test('steps reach the player and the answer names the surface', () async {
    final _FakePlayer player = await connect(caret: true);
    expect(snapshot['capabilities'], contains(videoRemoteCapabilityCaret));
    expect(snapshot['caret'], 'none');

    expect(await caret('enter'), <String, Object?>{
      'ok': true,
      'caret': 'video',
    });
    expect(await caret('right'), containsPair('caret', 'video'));
    expect(await caret('activate'), containsPair('caret', 'popup'));
    expect(await caret('back'), containsPair('caret', 'video'));
    expect(player.steps, <String>['enter', 'right', 'activate', 'back']);

    final Map<String, Object?> state = await host.handle(
      'snapshot',
      <String, dynamic>{},
      'phone',
    );
    expect(state['caret'], 'video');
  });

  test('unknown steps are rejected before reaching the player', () async {
    final _FakePlayer player = await connect(caret: true);
    for (final Object? step in <Object?>[null, 3, 'jump', '']) {
      await expectLater(
        caret(step),
        throwsA(remoteError(400, 'invalid_argument')),
        reason: '$step',
      );
    }
    expect(player.steps, isEmpty);
  });
}

final class _FakePlayer {
  _FakePlayer({required this.caret});

  final bool caret;
  final List<VoidCallback> listeners = <VoidCallback>[];
  final List<String> steps = <String>[];
  String surface = 'none';

  VideoRemotePlaybackBinding binding() => VideoRemotePlaybackBinding(
    identity: () => 'video-one',
    title: () => 'Video',
    bookUid: () => 'book',
    sectionIndex: () => 0,
    cues: () => const <VideoRemoteCue>[],
    state: () => <String, Object?>{
      'playing': false,
      'positionMs': 0,
      'caret': surface,
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
    caret: caret
        ? (String step) async {
            steps.add(step);
            surface = switch (step) {
              'enter' => 'video',
              'activate' => 'popup',
              'back' => surface == 'popup' ? 'video' : 'none',
              _ => surface,
            };
            return surface;
          }
        : null,
  );
}
