import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/collections/collection_episode_slot.dart';
import 'package:fushi/src/media/video/dandanplay_client.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/collection_season_groups.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_database_store.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:fushi_engine/sync/video_metadata_manifest.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

/// iPad 经互联看电脑上的视频，与「下载到本机再看」的三处差异（反馈 _sZllpFQWm）：
///
/// - BUG-3613：host 刮削把 `VideoBooks.title` 改成分集名后，client 按标题解析季号
///   落空（几十集排一列）；独立作品的资料本机落不了库、远端卡点开直接播放。
/// - BUG-3614：远端流播本机没有文件，算不出弹弹play 指纹，弹幕整条短路。
/// - BUG-3615：host 上「下载字幕」存在 `<appDocs>/video_subtitles/`，远端下发只扫
///   视频旁 sidecar，看不到它。
///
/// 走真 `LocalLibraryHostService` + 内存 DB + 真 HTTP（`FushiSyncServer`）。
void main() {
  late Directory tmp;
  late FushiDatabase db;
  late LocalLibraryHostService svc;
  late FushiSyncServer server;
  late String base;
  const String token = 'test-token-parity';

  Future<({int status, Object? json})> get(String path) async {
    final HttpClient c = HttpClient();
    try {
      final HttpClientRequest req = await c.getUrl(Uri.parse('$base$path'));
      req.headers.set(
        'authorization',
        'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
      );
      final HttpClientResponse res = await req.close();
      final String text = await res.transform(utf8.decoder).join();
      Object? json;
      try {
        json = text.isEmpty ? null : jsonDecode(text);
      } on FormatException {
        json = text;
      }
      return (status: res.statusCode, json: json);
    } finally {
      c.close();
    }
  }

  File writeVideo(String relative, int size) {
    final File f = File(p.join(tmp.path, relative))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(List<int>.generate(size, (int i) => i % 251));
    return f;
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('hbk_ic_parity');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final Directory dictRoot = Directory(p.join(tmp.path, 'dicts'))
      ..createSync(recursive: true);
    svc = LocalLibraryHostService(
      db: db,
      dictionaryResourceRoot: dictRoot,
      packages: SyncAssetPackageService(db: db),
      refreshDictionaryCache: () async {},
      runExclusive: (Future<void> Function() body) => body(),
      scrapeController: () async => null,
    );
    server = FushiSyncServer(
      syncDataDir: tmp.path,
      port: 0,
      token: token,
      allowLan: false,
      libraryService: svc,
    );
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDown(() async {
    await server.stop();
    await db.close();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('BUG-3613 分季：host 下发文件名', () {
    test('刮削改过标题后清单仍带 basename（不带目录），client 按它分季', () async {
      final File s1 = writeVideo('K-ON/S1/[K-ON] S01E01.mkv', 32);
      final File s2 = writeVideo('K-ON/S2/[K-ON] S02E01.mkv', 32);
      // 标题是刮削后的分集名：按标题解析不出季号。
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'video/kon-s1e1',
          title: '冬日！',
          videoPath: s1.path,
        ),
      );
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'video/kon-s2e1',
          title: '企划会议！',
          videoPath: s2.path,
        ),
      );

      final List<RemoteVideoInfo> listed = await svc.listVideos();
      final Map<String, RemoteVideoInfo> byId = <String, RemoteVideoInfo>{
        for (final RemoteVideoInfo v in listed) v.id: v,
      };
      expect(byId['video/kon-s1e1']!.fileName, '[K-ON] S01E01.mkv');
      expect(byId['video/kon-s2e1']!.fileName, '[K-ON] S02E01.mkv');

      // 经 HTTP：wire 上有 fileName，绝不带目录。
      final ({int status, Object? json}) res = await get('/api/library/videos');
      expect(res.status, 200);
      final List<RemoteVideoInfo> wire = <RemoteVideoInfo>[
        for (final Object? raw in res.json! as List<Object?>)
          RemoteVideoInfo.fromJson((raw! as Map).cast<String, Object?>()),
      ];
      for (final RemoteVideoInfo v in wire) {
        expect(v.fileName, isNot(contains('K-ON/')));
        expect(v.fileName, isNot(contains(r'\')));
      }

      // client 的分季判据：远端槽的解析输入是文件名，两季落进两个分组。
      final Set<String> keys = <String>{
        for (final RemoteVideoInfo v in wire)
          collectionGroupKeyForFilename(
            CollectionEpisodeSlot.remote(v).filename,
          ),
      };
      expect(keys, hasLength(2));
      // 改动前的口径（按标题）分不开——这正是反馈里「几十集排一列」。
      final Set<String> legacyKeys = <String>{
        for (final RemoteVideoInfo v in wire)
          collectionGroupKeyForFilename(v.title),
      };
      expect(legacyKeys, hasLength(1));
    });

    test('旧 host 不带 fileName：解析输入回落标题（行为不变）', () {
      final RemoteVideoInfo old = RemoteVideoInfo.fromJson(<String, Object?>{
        'id': 'v',
        'title': 'Show S01E02',
      });
      expect(old.fileName, isNull);
      expect(CollectionEpisodeSlot.remote(old).filename, 'Show S01E02');
      final RemoteVideoInfo fresh = RemoteVideoInfo.fromJson(
        const RemoteVideoInfo(
          id: 'v',
          title: '集名',
          fileName: 'Show S01E02.mkv',
        ).toJson(),
      );
      expect(fresh.fileName, 'Show S01E02.mkv');
      expect(fresh.parseName, 'Show S01E02.mkv');
    });

    test('本地与远端同集归并按远端文件名识别（标题已是集名）', () async {
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'local-e2',
          title: 'Show S01E02',
          videoPath: '/videos/Show/Show S01E02.mkv',
        ),
      );
      final VideoBookRow local = (await db.getVideoBookByBookUid('local-e2'))!;
      final Map<String, String> pairs = pairRemoteEpisodesWithLocal(
        local: <VideoBookRow>[local],
        remote: const <RemoteVideoInfo>[
          RemoteVideoInfo(
            id: 'remote-e2',
            title: '第二话 标题',
            fileName: 'Show S01E02.mkv',
          ),
        ],
      );
      expect(pairs, <String, String>{'remote-e2': 'local-e2'});
    });
  });

  group('BUG-3613 远端独立作品资料：按 bookUid 只回这一部', () {
    test('GET /api/library/metadata?bookUid= 只回该视频的作品', () async {
      for (final String uid in <String>['video/movie-a', 'video/movie-b']) {
        final File f = writeVideo('$uid.mkv', 16);
        await db.upsertVideoBook(
          VideoBooksCompanion.insert(
            bookUid: uid,
            title: uid,
            videoPath: f.path,
          ),
        );
        final VideoBookRow row = (await db.getVideoBookByBookUid(uid))!;
        await VideoMetadataDatabaseStore(db).apply(
          VideoSourceScrapeWork(
            source: null,
            title: uid,
            members: <VideoBookRow>[row],
          ),
          VideoMetadataWork(
            provider: VideoMetadataProviderKind.tmdb,
            kind: VideoMetadataMediaKind.movie,
            title: 'Title of $uid',
            plot: 'Plot of $uid',
            year: 2021,
            ids: <VideoMetadataId>[
              VideoMetadataId(type: 'tmdb', value: uid.hashCode.toString()),
            ],
          ),
        );
      }

      final ({int status, Object? json}) all = await get(
        '/api/library/metadata',
      );
      expect(((all.json! as Map)['works'] as List<Object?>), hasLength(2));

      final ({int status, Object? json}) one = await get(
        '/api/library/metadata?bookUid=${Uri.encodeQueryComponent('video/movie-b')}',
      );
      expect(one.status, 200);
      final List<Object?> works = (one.json! as Map)['works'] as List<Object?>;
      expect(works, hasLength(1));
      final VideoMetadataWorkEntry entry = VideoMetadataWorkEntry.fromJson(
        works.single,
      );
      expect(entry.key.bookUid, 'video/movie-b');
      expect(entry.work.title, 'Title of video/movie-b');
      expect(entry.work.plot, 'Plot of video/movie-b');
      expect(entry.work.year, 2021);

      final ({int status, Object? json}) none = await get(
        '/api/library/metadata?bookUid=video%2Funknown',
      );
      expect((none.json! as Map)['works'], isEmpty);
    });
  });

  group('BUG-3614 远端弹幕：host 出弹弹play 指纹', () {
    test('danmakukey 与本机对同一文件算出的指纹一致，client 拿它去匹配', () async {
      final File video = writeVideo('Show/Episode 01.mkv', 4096);
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'video/ep01',
          title: '刮削后的集名',
          videoPath: video.path,
        ),
      );

      final ({int status, Object? json}) res = await get(
        '/api/library/videos/${Uri.encodeComponent('video/ep01')}/danmakukey',
      );
      expect(res.status, 200);
      final DandanplayFileKey? key = DandanplayFileKey.fromJson(res.json);
      final DandanplayFileKey local = await dandanplayFileKeyOf(video);
      expect(key, isNotNull);
      expect(key!.fileName, 'Episode 01');
      expect(key.fileHash, local.fileHash);
      expect(key.fileSize, 4096);

      // client 拿 host 给的指纹问弹弹play：请求体与「下载到本机再算」逐字段相同。
      final DandanplayClient client = DandanplayClient(
        httpClient: MockClient((http.Request request) async {
          if (request.url.path == '/api/v2/match') {
            final Map<String, dynamic> body =
                jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['fileName'], local.fileName);
            expect(body['fileHash'], local.fileHash);
            expect(body['fileSize'], local.fileSize);
            return http.Response(
              jsonEncode(<String, dynamic>{
                'success': true,
                'isMatched': true,
                'matches': <Map<String, dynamic>>[
                  <String, dynamic>{'episodeId': 7, 'animeTitle': 'Demo'},
                ],
              }),
              200,
            );
          }
          expect(request.url.path, '/api/v2/comment/7');
          return http.Response(
            jsonEncode(<String, dynamic>{
              'count': 1,
              'comments': <Map<String, dynamic>>[
                <String, dynamic>{'p': '1.00,1,16777215,1', 'm': 'hello'},
              ],
            }),
            200,
          );
        }),
      );
      try {
        final DandanplayFetchResult result = await client
            .fetchBestDanmakuForKey(key);
        expect(result.status, DandanplayFetchStatus.hit);
        expect(result.items, hasLength(1));
        expect(result.match?.episodeId, 7);
      } finally {
        client.close();
      }
    });

    test('未知视频 / 网络流没有指纹 → 404', () async {
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'video/stream',
          title: 'Stream',
          videoPath: 'https://example.com/a.mp4',
        ),
      );
      expect(
        (await get('/api/library/videos/video%2Fstream/danmakukey')).status,
        404,
      );
      expect(
        (await get('/api/library/videos/video%2Fnope/danmakukey')).status,
        404,
      );
    });
  });

  group('BUG-3615 host 已下载的字幕', () {
    test('subtitleSource 指向 app 字幕目录的文件：清单与字幕端点都下发它', () async {
      final File video = writeVideo('Show/Ep01.mkv', 16);
      final File downloaded =
          File(p.join(tmp.path, 'appdocs', 'video_subtitles', 'Ep01.ja.ass'))
            ..parent.createSync(recursive: true)
            ..writeAsStringSync('[Script Info]\nTitle: downloaded\n');
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'video/ep01',
          title: 'Ep01',
          videoPath: video.path,
          subtitleSource: Value<String?>(downloaded.path),
        ),
      );

      final RemoteVideoInfo info = (await svc.listVideos()).single;
      expect(info.hasSubtitle, isTrue);
      expect(info.subtitleFileName, 'Ep01.ja.ass');

      final File? resolved = await svc.resolveVideoSubtitle('video/ep01');
      expect(resolved?.path, downloaded.path);

      final HttpClient c = HttpClient();
      try {
        final HttpClientRequest req = await c.getUrl(
          Uri.parse(
            '$base/api/library/videos/${Uri.encodeComponent('video/ep01')}/subtitle',
          ),
        );
        req.headers.set(
          'authorization',
          'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
        );
        final HttpClientResponse res = await req.close();
        expect(res.statusCode, 200);
        expect(
          await res.transform(utf8.decoder).join(),
          contains('Title: downloaded'),
        );
      } finally {
        c.close();
      }
    });

    test('持久化选择优先于同目录 sidecar；文件不在了回落 sidecar', () async {
      final File video = writeVideo('Show/Ep02.mkv', 16);
      final File sidecar = File(p.join(video.parent.path, 'Ep02.srt'))
        ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nside\n');
      final File downloaded =
          File(p.join(tmp.path, 'appdocs', 'video_subtitles', 'Ep02-dl.srt'))
            ..parent.createSync(recursive: true)
            ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\ndl\n');
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'video/ep02',
          title: 'Ep02',
          videoPath: video.path,
          subtitleSource: Value<String?>(downloaded.path),
        ),
      );
      expect(
        (await svc.resolveVideoSubtitle('video/ep02'))?.path,
        downloaded.path,
      );
      downloaded.deleteSync();
      expect(
        (await svc.resolveVideoSubtitle('video/ep02'))?.path,
        sidecar.path,
      );
      expect((await svc.listVideos()).single.subtitleFileName, 'Ep02.srt');
    });

    test('内嵌轨 / 关闭哨兵 / 多集播放列表行不改变原有 sidecar 口径', () async {
      final File video = writeVideo('Show/Ep03.mkv', 16);
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'video/ep03',
          title: 'Ep03',
          videoPath: video.path,
          subtitleSource: const Value<String?>('embedded:0'),
        ),
      );
      expect(await svc.resolveVideoSubtitle('video/ep03'), isNull);
      expect((await svc.listVideos()).single.hasSubtitle, isFalse);

      final File other = writeVideo('Show/Ep04.mkv', 16);
      final File downloaded =
          File(p.join(tmp.path, 'appdocs', 'video_subtitles', 'Ep04.srt'))
            ..parent.createSync(recursive: true)
            ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nx\n');
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'video/playlist',
          title: 'Playlist',
          videoPath: video.path,
          subtitleSource: Value<String?>(downloaded.path),
          playlistJson: Value<String?>(
            jsonEncode(<Map<String, String>>[
              <String, String>{'path': video.path, 'title': 'a'},
              <String, String>{'path': other.path, 'title': 'b'},
            ]),
          ),
        ),
      );
      expect(await svc.resolveVideoSubtitle('video/playlist'), isNull);
    });
  });
}
