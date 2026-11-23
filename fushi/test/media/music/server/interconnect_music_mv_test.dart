// 互联 host 曲目的 MV（design-imusic-q7 / q8 / q9）：歌词页背景按需签画面流票、用完释放；曲目本身是
// MV 视频时另签原样画面流（两条连接）；MV 页的 host 绑定（YouTube 走本机音源、微调写回 host、曲库
// 音轨请 host 截好这一首）；请 host 重新匹配 / 候选 / 绑定 / 解绑的请求形状；iOS 不出 YouTube 绑定。

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/metadata/music_video_service.dart';
import 'package:fushi/src/media/music/server/interconnect_music_client.dart';
import 'package:fushi/src/pages/implementations/music/music_lyrics_mv_backdrop.dart';
import 'package:fushi/src/pages/implementations/music/music_mv_page.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/metadata/music_video_match.dart'
    show MusicVideoKind;
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:fushi_engine/sync/library_media_streams.dart'
    show kLibraryMediaStreamReleasePath;
import 'package:fushi_engine/sync/remote_music_dto.dart';

typedef _Call = ({
  String method,
  String path,
  Map<String, String> query,
  Object? json,
});

class _Host implements InterconnectMusicTransport {
  _Host({this.videos = const <Map<String, Object?>>[], this.isVideo = false});

  final List<Map<String, Object?>> videos;
  final bool isVideo;
  final List<_Call> calls = <_Call>[];
  int _tickets = 0;

  @override
  Future<InterconnectMusicResponse> send(
    String method,
    String path, {
    Map<String, String> query = const <String, String>{},
    Object? json,
    required Duration timeout,
  }) async {
    calls.add((method: method, path: path, query: query, json: json));
    Object? body = const <String, Object?>{};
    int status = 200;
    if (path == '/api/library/media/streamurl') {
      final int n = ++_tickets;
      body = <String, Object?>{
        'url': 'https://h/api/library/media/stream?token=t$n',
        'ticket': 't$n',
        if ((json! as Map<String, Object?>)['options'] != null)
          'segmentApplied': true,
      };
    } else if (path.endsWith('/videos') && method == 'GET') {
      body = <String, Object?>{'items': videos};
    } else if (path.endsWith('/videos/rematch')) {
      body = <String, Object?>{'bound': 2};
    } else if (path.endsWith('/videos/candidates')) {
      body = <String, Object?>{
        'items': <Object?>[
          const RemoteMusicVideoCandidate(
            kind: MusicVideoKind.youtube,
            ref: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
            title: 'YT',
          ).toJson(),
        ],
      };
    } else if (path.contains('/tracks/') && method == 'GET') {
      body = <String, Object?>{
        'id': 'u1',
        'title': 'Song',
        'cueStartMs': 5000,
        if (isVideo) 'isVideo': true,
      };
    } else if (method == 'DELETE') {
      status = 204;
      body = null;
    }
    return (
      status: status,
      bytes: Uint8List.fromList(
        utf8.encode(body == null ? '' : jsonEncode(body)),
      ),
      json: body is Map<String, Object?> ? body : null,
      resolve: (String p, Map<String, String> q) => Uri(
        scheme: 'https',
        host: 'h',
        path: p,
        queryParameters: q.isEmpty ? null : q,
      ),
      pin: null,
    );
  }

  @override
  void close() {}

  List<String> get released => <String>[
    for (final _Call c in calls)
      if (c.path == kLibraryMediaStreamReleasePath) c.query['ticket']!,
  ];
}

InterconnectMusicBrowser _browser(_Host host, {bool canMatch = true}) =>
    InterconnectMusicBrowser(
      serverId: 'pc',
      displayName: 'PC',
      transport: host,
      canMatchVideos: canMatch,
    );

void main() {
  group('歌词页背景（q7 / q8）', () {
    test('取第一条有 host 字节的绑定签画面票；YouTube 绑定不当背景；release 还票', () async {
      final _Host host = _Host(
        videos: <Map<String, Object?>>[
          const RemoteMusicVideo(
            videoId: 1,
            kind: MusicVideoKind.youtube,
            offsetMs: 0,
            youtubeRef: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
          ).toJson(),
          const RemoteMusicVideo(
            videoId: 7,
            kind: MusicVideoKind.local,
            offsetMs: 1200,
          ).toJson(),
        ],
      );
      final MusicMvBackdropSource? src = await resolveFushiHostMusicMvBackdrop(
        _browser(host),
        'u1',
      );
      expect(src?.path, 'https://h/api/library/media/stream?token=t1');
      expect(src?.offsetMs, 1200);
      final _Call issue = host.calls.firstWhere(
        (_Call c) => c.path == '/api/library/media/streamurl',
      );
      expect(issue.json, <String, Object?>{'kind': 'musicVideo', 'id': '7'});
      await src!.release!();
      await src.release!();
      expect(host.released, <String>['t1']);
    });

    test('没有绑定、曲目本身是 MV 视频：另签一条原样画面流，偏移 = CUE 起点', () async {
      final _Host host = _Host(isVideo: true);
      final MusicMvBackdropSource? src = await resolveFushiHostMusicMvBackdrop(
        _browser(host),
        'u1',
      );
      expect(src?.offsetMs, 5000);
      final _Call issue = host.calls.lastWhere(
        (_Call c) => c.path == '/api/library/media/streamurl',
      );
      // 原样：不带码率上限 / segment。
      expect(issue.json, <String, Object?>{'kind': 'musicTrack', 'id': 'u1'});
      expect(
        await resolveFushiHostMusicMvBackdrop(_browser(_Host()), 'u1'),
        isNull,
      );
    });
  });

  group('MV 页的 host 绑定（q7）', () {
    test('画面签票；曲库音轨请 host 截好这一首；微调写回 host', () async {
      final _Host host = _Host();
      final InterconnectMusicBrowser b = _browser(host);
      const MusicServerVideo v = MusicServerVideo(
        id: '7',
        kind: MusicVideoKind.local,
        offsetMs: 300,
      );
      final MusicKaraokeHostBinding binding = MusicKaraokeHostBinding(
        browser: b,
        trackUid: 'u1',
        video: v,
      );
      final MusicKaraokeTrack track = musicHostKaraokeTrack(
        b,
        const MusicServerTrack(id: 'u1', title: 'Song', coverRef: 'a:x'),
      );
      expect(track.path, fushiHostMusicTrackPath('pc', 'u1'));
      expect(track.cueStartMs, isNull);
      expect(track.coverPath, fushiHostMusicCoverPath('pc', 'a:x'));
      expect(
        await binding.libraryAudio(track),
        'https://h/api/library/media/stream?token=t1',
      );
      expect(
        host.calls
            .firstWhere((_Call c) => c.path == '/api/library/media/streamurl')
            .json,
        <String, Object?>{
          'kind': 'musicTrack',
          'id': 'u1',
          'options': <String, Object?>{'segment': true},
        },
      );
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      await binding.setOffset(db, 400);
      final _Call put = host.calls.lastWhere((_Call c) => c.method == 'PUT');
      expect(put.path, '/api/library/music/videos/7/offset');
      expect((put.json! as Map<String, Object?>)['offsetMs'], 400);
    });

    test('iOS（本机没有 YouTube 音源）不出 YouTube 绑定', () {
      const List<MusicServerVideo> all = <MusicServerVideo>[
        MusicServerVideo(id: '1', kind: MusicVideoKind.local, offsetMs: 0),
        MusicServerVideo(
          id: '2',
          kind: MusicVideoKind.youtube,
          offsetMs: 0,
          youtubeRef: 'https://youtu.be/dQw4w9WgXcQ',
        ),
      ];
      expect(
        musicHostVisibleVideos(all, youtubeAvailable: false).single.id,
        '1',
      );
      expect(musicHostVisibleVideos(all, youtubeAvailable: true), hasLength(2));
    });
  });

  group('请 host 重新匹配 / 绑定（q9）', () {
    test('请求形状', () async {
      final _Host host = _Host();
      final InterconnectMusicBrowser b = _browser(host);
      expect(await b.rematchVideos('u 1'), 2);
      expect(host.calls.last.method, 'POST');
      expect(
        host.calls.last.path,
        '/api/library/music/tracks/u%201/videos/rematch',
      );
      final List<RemoteMusicVideoCandidate> c = await b.videoCandidates(
        'u1',
        RemoteMusicVideoCandidateSource.online,
      );
      expect(host.calls.last.query, <String, String>{'source': 'online'});
      await b.bindVideo('u1', c.single);
      expect(host.calls.last.path, '/api/library/music/tracks/u1/videos');
      expect(
        (host.calls.last.json! as Map<String, Object?>)['ref'],
        c.single.ref,
      );
      await b.unbindVideo(
        'u1',
        const MusicServerVideo(
          id: '9',
          kind: MusicVideoKind.local,
          offsetMs: 0,
        ),
      );
      expect(host.calls.last.method, 'DELETE');
      expect(host.calls.last.path, '/api/library/music/tracks/u1/videos/9');
    });

    test('host 侧匹配器：在线候选受 host 的 YouTube 门约束，绑定转给 MV 服务', () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final _FakeService service = _FakeService(db);
      bool online = false;
      final AppMusicHostVideoMatcher m = AppMusicHostVideoMatcher(
        () => service,
        online: () => online,
      );
      expect(
        await m.candidates('u1', RemoteMusicVideoCandidateSource.online),
        isEmpty,
      );
      online = true;
      expect(
        (await m.candidates(
          'u1',
          RemoteMusicVideoCandidateSource.online,
        )).single.title,
        'YT',
      );
      expect(
        (await m.candidates(
          'u1',
          RemoteMusicVideoCandidateSource.anime,
        )).single.kind,
        MusicVideoKind.animeEpisode,
      );
      expect(await m.rematch('u1'), 0);
      await m.bind(
        'u1',
        const RemoteMusicVideoCandidate(
          kind: MusicVideoKind.youtube,
          ref: 'r',
          title: 'T',
          offsetMs: 40,
        ),
      );
      expect(service.bound.single.ref, 'r');
      expect(service.bound.single.offsetMs, 40);
      expect(service.alignedOnline, isTrue);
    });
  });
}

class _FakeService extends MusicVideoService {
  _FakeService(FushiDatabase db) : super(database: db);

  final List<MusicVideoCandidate> bound = <MusicVideoCandidate>[];
  bool? alignedOnline;

  @override
  Future<List<MusicLocalVideoMatch>> matchLocal(String trackUid) async =>
      const <MusicLocalVideoMatch>[
        MusicLocalVideoMatch(path: '/v.mkv', nameScore: 0.9),
      ];

  @override
  Future<List<MusicVideoCandidate>> onlineCandidates(
    String trackUid,
  ) async => const <MusicVideoCandidate>[
    MusicVideoCandidate(kind: MusicVideoKind.youtube, ref: 'y', title: 'YT'),
  ];

  @override
  Future<List<MusicVideoCandidate>> animeCandidates(String trackUid) async =>
      const <MusicVideoCandidate>[
        MusicVideoCandidate(
          kind: MusicVideoKind.animeEpisode,
          ref: 'anime:b#0',
          title: 'OP',
        ),
      ];

  @override
  Future<MusicVideoRow?> bind(
    String trackUid,
    MusicVideoCandidate c, {
    bool alignOnline = true,
  }) async {
    bound.add(c);
    alignedOnline = alignOnline;
    return null;
  }
}
