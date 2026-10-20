import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/video_remote_cover.dart';
import 'package:fushi/src/sync/video_remote_host.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/video_remote_service.dart';

/// 视频遥控（用户 2026-10-21）：选集 / 点播的封面预览、在线字幕搜索与下载、
/// 从手机关闭电脑上的视频——协议层（假播放器绑定 + 假视频库）。
void main() {
  late FushiDatabase db;
  late VideoRemoteHost host;
  late Map<String, Object?> snapshot;
  late _FakeLibrary library;
  int serial = 0;

  /// JPEG 魔数开头的小字节串：不必解码，按原样回给手机。
  final Uint8List jpeg = Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 1, 2, 3]);

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    library = _FakeLibrary(jpeg);
    host = VideoRemoteHost(
      favorites: () => FavoriteSentenceRepository(db),
      library: library.library(),
      now: () => DateTime(2026, 10, 21),
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

  Future<void> connect([_FakePlayer? player]) async {
    if (player != null) host.register(player.binding());
    snapshot = await host.handle('snapshot', <String, dynamic>{}, 'phone');
  }

  Matcher remoteError(int status, String code) => isA<VideoRemoteException>()
      .having((VideoRemoteException e) => e.status, 'status', status)
      .having((VideoRemoteException e) => e.code, 'code', code);

  group('能力声明', () {
    test('有视频：声明在线字幕与关闭视频；没视频：只有点播', () async {
      final VideoRemotePlaybackBinding binding = _FakePlayer(jpeg).binding();
      host.register(binding);
      await connect();
      expect(
        snapshot['capabilities'],
        containsAll(<String>[
          videoRemoteCapabilitySubtitleSearch,
          videoRemoteCapabilityCloseVideo,
          videoRemoteCapabilityOpenVideo,
        ]),
      );
      host.unregister(binding);
      await connect();
      expect(snapshot['capabilities'], <String>[
        videoRemoteCapabilityOpenVideo,
      ]);
    });

    test('旧播放器绑定（无在线字幕回调）不声明、命令回 action_unsupported', () async {
      await connect(_FakePlayer(jpeg, full: false));
      expect(
        snapshot['capabilities'],
        isNot(contains(videoRemoteCapabilitySubtitleSearch)),
      );
      await expectLater(
        call('command', <String, dynamic>{
          'action': 'subtitleDownload',
          'handle': 'h',
        }),
        throwsA(remoteError(409, videoRemoteActionUnsupported)),
      );
      await expectLater(
        call('subtitleSearch'),
        throwsA(remoteError(409, videoRemoteActionUnsupported)),
      );
    });
  });

  group('封面', () {
    test('点播清单条目带 hasCover，按 bookUid 取封面原样回给手机', () async {
      await connect();
      final Map<String, Object?> page = await call('library');
      final List<Object?> items = page['items']! as List<Object?>;
      expect((items.first! as Map<String, Object?>)['hasCover'], isTrue);
      expect(
        (items.last! as Map<String, Object?>).containsKey('hasCover'),
        isFalse,
      );
      final Map<String, Object?> cover = await call('cover', <String, dynamic>{
        'bookUid': 'with-cover',
      });
      expect(cover['mime'], 'image/jpeg');
      expect(base64Decode(cover['data']! as String), jpeg);
      expect(library.coverRequests, <String>['with-cover']);
    });

    test('没有封面 404 cover_missing；坏参数 400', () async {
      await connect();
      await expectLater(
        call('cover', <String, dynamic>{'bookUid': 'no-cover'}),
        throwsA(remoteError(404, 'cover_missing')),
      );
      await expectLater(
        call('cover', <String, dynamic>{'bookUid': ''}),
        throwsA(remoteError(400, 'invalid_argument')),
      );
    });

    test('选集封面按会话取；集数带 hasCover；会话变了 409', () async {
      final _FakePlayer player = _FakePlayer(jpeg);
      await connect(player);
      final Map<String, Object?> options = await call('playbackOptions');
      final List<Object?> episodes = options['episodes']! as List<Object?>;
      expect((episodes[0]! as Map<String, Object?>)['hasCover'], isTrue);
      expect(
        (episodes[1]! as Map<String, Object?>).containsKey('hasCover'),
        isFalse,
      );
      final Map<String, Object?> cover = await call('cover', <String, dynamic>{
        'episodeIndex': 0,
      });
      expect(base64Decode(cover['data']! as String), jpeg);
      await expectLater(
        call('cover', <String, dynamic>{'episodeIndex': 1}),
        throwsA(remoteError(404, 'cover_missing')),
      );
      await expectLater(
        call('cover', <String, dynamic>{
          'episodeIndex': 0,
          'sessionId': 'stale',
        }),
        throwsA(remoteError(409, 'session_changed')),
      );
      expect(player.coverRequests, <int>[0, 1]);
    });

    test('封面类型按魔数判（JPEG / PNG / WebP / GIF），其余为 null', () {
      expect(videoRemoteCoverMime(jpeg), 'image/jpeg');
      expect(
        videoRemoteCoverMime(
          Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D]),
        ),
        'image/png',
      );
      expect(
        videoRemoteCoverMime(
          Uint8List.fromList(<int>[
            ...ascii.encode('RIFF'),
            0,
            0,
            0,
            0,
            ...ascii.encode('WEBP'),
          ]),
        ),
        'image/webp',
      );
      expect(videoRemoteCoverMime(Uint8List.fromList(<int>[1, 2, 3])), isNull);
    });
  });

  group('在线字幕', () {
    late _FakePlayer player;
    setUp(() async {
      player = _FakePlayer(jpeg);
      await connect(player);
    });

    test('不带词：用电脑预填；带词：去空白后转给播放器', () async {
      final Map<String, Object?> prefill = await call('subtitleSearch');
      expect(player.searches.last, (query: null, episode: null));
      expect(prefill['query'], 'Show');
      expect(prefill['episode'], 3);
      final List<Object?> candidates = prefill['candidates']! as List<Object?>;
      expect((candidates.single! as Map<String, Object?>)['handle'], 'h1');

      await call('subtitleSearch', <String, dynamic>{
        'query': '  Other  ',
        'episode': 5,
      });
      expect(player.searches.last, (query: 'Other', episode: 5));
      await call('subtitleSearch', <String, dynamic>{'query': '   '});
      expect(player.searches.last, (query: null, episode: null));
    });

    test('坏参数 400 invalid_argument', () async {
      for (final Map<String, dynamic> body in <Map<String, dynamic>>[
        <String, dynamic>{'query': 3},
        <String, dynamic>{'episode': '2'},
        <String, dynamic>{'episode': -1},
      ]) {
        await expectLater(
          call('subtitleSearch', body),
          throwsA(remoteError(400, 'invalid_argument')),
          reason: '$body',
        );
      }
    });

    test('subtitleDownload 把句柄交给播放器；缺句柄 400；播放器的失败原样回', () async {
      await call('command', <String, dynamic>{
        'action': 'subtitleDownload',
        'handle': 'h1',
      });
      expect(player.downloads, <String>['h1']);
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
          'handle': 'gone',
        }),
        throwsA(remoteError(404, 'subtitle_candidate_missing')),
      );
    });
  });

  group('关闭视频', () {
    test('有视频时转给视频库的 close', () async {
      await connect(_FakePlayer(jpeg));
      await call('closeVideo');
      expect(library.closed, 1);
    });

    test('没视频 409 no_video，不调 close', () async {
      await connect();
      await expectLater(
        call('closeVideo'),
        throwsA(remoteError(409, 'no_video')),
      );
      expect(library.closed, 0);
    });

    test('电脑关不掉（host_busy）原样回给手机', () async {
      library.closeError = const VideoRemoteException(409, 'host_busy');
      await connect(_FakePlayer(jpeg));
      await expectLater(
        call('closeVideo'),
        throwsA(remoteError(409, 'host_busy')),
      );
    });
  });
}

class _FakeLibrary {
  _FakeLibrary(this.cover);

  final Uint8List cover;
  final List<String> coverRequests = <String>[];
  int closed = 0;
  VideoRemoteException? closeError;

  VideoRemoteLibrary library() => VideoRemoteLibrary(
    list: () async => const <VideoRemoteLibraryItem>[
      VideoRemoteLibraryItem(bookUid: 'with-cover', title: 'A', hasCover: true),
      VideoRemoteLibraryItem(bookUid: 'no-cover', title: 'B'),
    ],
    open: (String bookUid) async {},
    cover: (String bookUid) async {
      coverRequests.add(bookUid);
      return bookUid == 'with-cover' ? cover : null;
    },
    close: () async {
      final VideoRemoteException? error = closeError;
      if (error != null) throw error;
      closed++;
    },
  );
}

class _FakePlayer {
  _FakePlayer(this.cover, {this.full = true});

  final Uint8List cover;
  final bool full;
  final List<VoidCallback> listeners = <VoidCallback>[];
  final List<int> coverRequests = <int>[];
  final List<({String? query, int? episode})> searches =
      <({String? query, int? episode})>[];
  final List<String> downloads = <String>[];
  VideoRemoteException? downloadError;

  VideoRemotePlaybackBinding binding() => VideoRemotePlaybackBinding(
    identity: () => 'video-one',
    title: () => 'Video',
    bookUid: () => 'book',
    sectionIndex: () => 0,
    cues: () => const <VideoRemoteCue>[
      VideoRemoteCue(
        id: 'c1',
        text: '一',
        startMs: 0,
        endMs: 1000,
        delayMs: 0,
        track: 'primary',
      ),
    ],
    state: () => <String, Object?>{
      'playing': false,
      'positionMs': 0,
      'speed': 1.0,
      'controlRevision': 0,
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
      VideoRemoteEpisode(
        index: 0,
        title: 'Ep 1',
        current: true,
        hasCover: true,
      ),
      const VideoRemoteEpisode(index: 1, title: 'Ep 2', current: false),
    ],
    switchEpisode: (int index) async {},
    episodeCover: (int index) async {
      coverRequests.add(index);
      return index == 0 ? cover : null;
    },
    searchSubtitles: full
        ? ({String? query, int? episode}) async {
            searches.add((query: query, episode: episode));
            return VideoRemoteSubtitleSearchResult(
              query: query ?? 'Show',
              episode: episode ?? (query == null ? 3 : null),
              candidates: const <VideoRemoteSubtitleCandidate>[
                VideoRemoteSubtitleCandidate(
                  handle: 'h1',
                  provider: 'jimaku',
                  fileName: 'Show - 03.srt',
                  language: 'ja',
                  episode: 3,
                ),
              ],
            );
          }
        : null,
    downloadSubtitle: full
        ? (String handle) async {
            final VideoRemoteException? error = downloadError;
            if (error != null) throw error;
            downloads.add(handle);
          }
        : null,
  );
}
