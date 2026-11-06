import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/video_remote_cover.dart';
import 'package:fushi/src/sync/video_remote_host.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/video_remote_service.dart';

/// 手机遥控「选集封面」（`episodeCover`）与「关闭视频」（`closeVideo`）的协议层
/// （PR #2469 移植）：能力声明、会话校验、错误码，以及旧绑定明确回
/// `action_unsupported`。
void main() {
  late FushiDatabase db;
  late VideoRemoteHost host;
  late Map<String, Object?> snapshot;
  int serial = 0;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    host = VideoRemoteHost(
      favorites: () => FavoriteSentenceRepository(db),
      now: () => DateTime(2026, 10, 25),
    );
  });
  tearDown(() async {
    await host.dispose();
    await db.close();
  });

  Future<Map<String, Object?>> call(
    String operation, [
    Map<String, dynamic> data = const <String, dynamic>{},
  ]) => host.handle(operation, <String, dynamic>{
    'sessionId': snapshot['sessionId'],
    'subtitleVersion': snapshot['subtitleVersion'],
    'requestId': 'request_${++serial}',
    ...data,
  }, 'phone');

  Future<void> connect(_FakePlayer player) async {
    host.register(player.binding());
    snapshot = await host.handle('snapshot', <String, dynamic>{}, 'phone');
  }

  Matcher remoteError(int status, String code) => isA<VideoRemoteException>()
      .having((VideoRemoteException e) => e.status, 'status', status)
      .having((VideoRemoteException e) => e.code, 'code', code);

  test('新操作已登记进协议（服务端按这张表放行路由）', () {
    expect(videoRemoteOperations, contains('episodeCover'));
    expect(videoRemoteOperations, contains('closeVideo'));
  });

  group('旧播放器绑定（无封面 / 关闭回调）', () {
    setUp(() => connect(_FakePlayer(full: false)));

    test('不声明 closeVideo 能力，两个操作都回 action_unsupported', () async {
      expect(
        snapshot['capabilities'],
        isNot(contains(videoRemoteCapabilityCloseVideo)),
      );
      await expectLater(
        call('episodeCover', <String, dynamic>{'episodeIndex': 0}),
        throwsA(remoteError(409, videoRemoteActionUnsupported)),
      );
      await expectLater(
        call('closeVideo'),
        throwsA(remoteError(409, videoRemoteActionUnsupported)),
      );
    });

    test('playbackOptions 的集不带 hasCover', () async {
      final Map<String, Object?> options = await call('playbackOptions');
      for (final Object? episode in options['episodes']! as List<Object?>) {
        expect(
          (episode! as Map<String, Object?>).containsKey('hasCover'),
          isFalse,
        );
      }
    });
  });

  group('新播放器绑定', () {
    late _FakePlayer player;
    setUp(() async {
      player = _FakePlayer(full: true);
      await connect(player);
    });

    test('快照声明 closeVideo；集列表按有无封面带 hasCover', () async {
      expect(
        snapshot['capabilities'],
        contains(videoRemoteCapabilityCloseVideo),
      );
      final Map<String, Object?> options = await call('playbackOptions');
      final List<Map<String, Object?>> episodes = <Map<String, Object?>>[
        for (final Object? e in options['episodes']! as List<Object?>)
          e! as Map<String, Object?>,
      ];
      expect(episodes[0]['hasCover'], isTrue);
      expect(episodes[1].containsKey('hasCover'), isFalse);
    });

    test('episodeCover：小封面原样返回 base64 + mime', () async {
      final Map<String, Object?> cover = await call(
        'episodeCover',
        <String, dynamic>{'episodeIndex': 0},
      );
      expect(cover['mime'], 'image/png');
      expect(base64Decode(cover['data']! as String), _tinyPng);
      expect(player.coverRequests, <int>[0]);
    });

    test('episodeCover：没有封面 → 404 cover_missing；参数非法 → 400', () async {
      await expectLater(
        call('episodeCover', <String, dynamic>{'episodeIndex': 1}),
        throwsA(remoteError(404, 'cover_missing')),
      );
      // 不是图片的字节同样按「没有封面」回，不把垃圾发给手机。
      await expectLater(
        call('episodeCover', <String, dynamic>{'episodeIndex': 2}),
        throwsA(remoteError(404, 'cover_missing')),
      );
      for (final Object? bad in <Object?>[null, -1, '0', 1.5]) {
        await expectLater(
          call('episodeCover', <String, dynamic>{'episodeIndex': bad}),
          throwsA(remoteError(400, 'invalid_number')),
          reason: '$bad',
        );
      }
    });

    test('episodeCover：取图期间换了视频 → session_changed', () async {
      player.onCover = () {
        player.identity = 'video-two';
        player.notifyListeners();
      };
      await expectLater(
        call('episodeCover', <String, dynamic>{'episodeIndex': 0}),
        throwsA(remoteError(409, 'session_changed')),
      );
    });

    test('closeVideo：调绑定的关闭；手机看的是旧会话则拒绝、不关', () async {
      await expectLater(
        call('closeVideo', <String, dynamic>{'sessionId': 'stale'}),
        throwsA(remoteError(409, 'session_changed')),
      );
      expect(player.closed, 0);
      // 字幕版本变了不算换视频：照常关。
      await call('closeVideo', <String, dynamic>{'subtitleVersion': -1});
      expect(player.closed, 1);
    });

    test('closeVideo：页面关不掉时把 host_busy 原样回给手机', () async {
      player.closeError = const VideoRemoteException(409, 'host_busy');
      await expectLater(
        call('closeVideo'),
        throwsA(remoteError(409, 'host_busy')),
      );
    });

    test('closeVideo：电脑上没开视频 → no_video', () async {
      host.unregister(player.lastBinding!);
      await expectLater(
        call('closeVideo'),
        throwsA(remoteError(409, 'no_video')),
      );
    });
  });

  group('videoRemoteCoverMime', () {
    test('按魔数识别 JPEG / PNG / GIF / WebP，其它为 null', () {
      expect(
        videoRemoteCoverMime(Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0])),
        'image/jpeg',
      );
      expect(videoRemoteCoverMime(_tinyPng), 'image/png');
      expect(
        videoRemoteCoverMime(Uint8List.fromList(utf8.encode('GIF89a'))),
        'image/gif',
      );
      expect(
        videoRemoteCoverMime(
          Uint8List.fromList(utf8.encode('RIFF0000WEBPVP8')),
        ),
        'image/webp',
      );
      expect(videoRemoteCoverMime(Uint8List.fromList(<int>[1, 2, 3])), isNull);
    });
  });
}

/// 1×1 透明 PNG。
final Uint8List _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
  '60e6kgAAAABJRU5ErkJggg==',
);

final class _FakePlayer {
  _FakePlayer({required this.full});

  final bool full;
  final List<VoidCallback> listeners = <VoidCallback>[];
  final List<int> coverRequests = <int>[];
  String identity = 'video-one';
  int closed = 0;
  VideoRemoteException? closeError;
  VoidCallback? onCover;
  VideoRemotePlaybackBinding? lastBinding;

  void notifyListeners() {
    for (final VoidCallback listener in List<VoidCallback>.of(listeners)) {
      listener();
    }
  }

  VideoRemotePlaybackBinding binding() =>
      lastBinding = VideoRemotePlaybackBinding(
        identity: () => identity,
        title: () => 'Video',
        bookUid: () => 'book',
        sectionIndex: () => 0,
        cues: () => const <VideoRemoteCue>[
          VideoRemoteCue(
            id: 'c1',
            text: '一番',
            startMs: 0,
            endMs: 1000,
            delayMs: 0,
            track: 'primary',
          ),
        ],
        state: () => <String, Object?>{
          'playing': true,
          'positionMs': 0,
          'speed': 1.0,
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
        episodes: () => <VideoRemoteEpisode>[
          for (int i = 0; i < 3; i++)
            VideoRemoteEpisode(
              index: i,
              title: 'Ep ${i + 1}',
              current: i == 0,
              hasCover: full && i != 1,
            ),
        ],
        switchEpisode: (int index) async {},
        episodeCover: full
            ? (int index) async {
                coverRequests.add(index);
                onCover?.call();
                return switch (index) {
                  0 => _tinyPng,
                  2 => Uint8List.fromList(<int>[1, 2, 3]),
                  _ => null,
                };
              }
            : null,
        close: full
            ? () async {
                final VideoRemoteException? error = closeError;
                if (error != null) throw error;
                closed++;
              }
            : null,
      );
}
