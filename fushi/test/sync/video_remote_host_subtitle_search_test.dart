import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/video_remote_host.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/video_remote_service.dart';

/// 视频遥控「在线搜索字幕」协议层（假播放器绑定）：能力声明、参数校验、会话
/// 校验、下载命令转给播放器并让字幕版本前进。
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

  Future<Map<String, Object?>> call(
    String operation, [
    Map<String, dynamic> data = const <String, dynamic>{},
  ]) => host.handle(operation, <String, dynamic>{
    'sessionId': snapshot['sessionId'],
    'subtitleVersion': snapshot['subtitleVersion'],
    'requestId': 'request_${++serial}',
    ...data,
  }, 'phone');

  Matcher remoteError(int status, String code) => isA<VideoRemoteException>()
      .having((VideoRemoteException e) => e.status, 'status', status)
      .having((VideoRemoteException e) => e.code, 'code', code);

  Future<_FakePlayer> connect({required bool search}) async {
    final _FakePlayer player = _FakePlayer(search: search);
    host.register(player.binding());
    snapshot = await host.handle('snapshot', <String, dynamic>{}, 'phone');
    return player;
  }

  test('a player without search neither advertises nor answers', () async {
    await connect(search: false);
    expect(
      snapshot['capabilities'],
      isNot(contains(videoRemoteCapabilitySubtitleSearch)),
    );
    await expectLater(
      call('subtitleSearch'),
      throwsA(remoteError(409, videoRemoteActionUnsupported)),
    );
    await expectLater(
      call('command', <String, dynamic>{
        'action': 'subtitleDownload',
        'candidateId': '1.0',
      }),
      throwsA(remoteError(409, videoRemoteActionUnsupported)),
    );
  });

  test('search forwards the phone query and returns the hits', () async {
    final _FakePlayer player = await connect(search: true);
    expect(
      snapshot['capabilities'],
      contains(videoRemoteCapabilitySubtitleSearch),
    );

    final Map<String, Object?> defaults = await call('subtitleSearch');
    expect(player.searches, <(String?, int?)>[(null, null)]);
    expect(defaults['query'], 'Frieren');
    expect(defaults['episode'], 3);
    expect(defaults['candidates'], <Map<String, Object?>>[
      <String, Object?>{
        'id': '1.0',
        'fileName': 'frieren_03.ja.srt',
        'provider': 'jimaku',
        'language': 'ja',
        'episode': 3,
        'aiTranslated': false,
        'hearingImpaired': false,
      },
    ]);

    await call('subtitleSearch', <String, dynamic>{
      'query': 'Sousou no Frieren',
      'episode': 4,
    });
    expect(player.searches.last, ('Sousou no Frieren', 4));
  });

  test('search validates its arguments and the session', () async {
    await connect(search: true);
    await expectLater(
      call('subtitleSearch', <String, dynamic>{'query': 3}),
      throwsA(remoteError(400, 'invalid_argument')),
    );
    await expectLater(
      call('subtitleSearch', <String, dynamic>{'query': 'x' * 201}),
      throwsA(remoteError(400, 'invalid_argument')),
    );
    await expectLater(
      call('subtitleSearch', <String, dynamic>{'episode': -1}),
      throwsA(remoteError(400, 'invalid_number')),
    );
    await expectLater(
      host.handle('subtitleSearch', <String, dynamic>{
        'sessionId': 'stale',
        'subtitleVersion': snapshot['subtitleVersion'],
      }, 'phone'),
      throwsA(remoteError(409, 'session_changed')),
    );
  });

  test(
    'download hands the candidate to the player and surfaces its errors',
    () async {
      final _FakePlayer player = await connect(search: true);
      expect(
        await call('command', <String, dynamic>{
          'action': 'subtitleDownload',
          'candidateId': '1.0',
        }),
        <String, Object?>{'ok': true},
      );
      expect(player.downloads, <String>['1.0']);

      await expectLater(
        call('command', <String, dynamic>{'action': 'subtitleDownload'}),
        throwsA(remoteError(400, 'invalid_argument')),
      );
      player.downloadError = const VideoRemoteException(
        404,
        'subtitle_candidate_missing',
      );
      await expectLater(
        call('command', <String, dynamic>{
          'action': 'subtitleDownload',
          'candidateId': '0.9',
        }),
        throwsA(remoteError(404, 'subtitle_candidate_missing')),
      );
    },
  );
}

final class _FakePlayer {
  _FakePlayer({required this.search});

  final bool search;
  final List<VoidCallback> listeners = <VoidCallback>[];
  final List<(String?, int?)> searches = <(String?, int?)>[];
  final List<String> downloads = <String>[];
  VideoRemoteException? downloadError;

  VideoRemotePlaybackBinding binding() => VideoRemotePlaybackBinding(
    identity: () => 'video-one',
    title: () => 'Video',
    bookUid: () => 'book',
    sectionIndex: () => 0,
    cues: () => const <VideoRemoteCue>[],
    state: () => <String, Object?>{'playing': false, 'positionMs': 0},
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
    searchSubtitles: search
        ? (String? query, int? episode) async {
            searches.add((query, episode));
            return VideoRemoteOnlineSubtitleSearch(
              query: query ?? 'Frieren',
              episode: episode ?? 3,
              candidates: const <VideoRemoteOnlineSubtitle>[
                VideoRemoteOnlineSubtitle(
                  id: '1.0',
                  fileName: 'frieren_03.ja.srt',
                  provider: 'jimaku',
                  language: 'ja',
                  episode: 3,
                ),
              ],
            );
          }
        : null,
    downloadSubtitle: search
        ? (String id) async {
            final VideoRemoteException? error = downloadError;
            if (error != null) throw error;
            downloads.add(id);
          }
        : null,
  );
}
