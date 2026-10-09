/// 互联 host 的视频字幕管理：清字幕（`DELETE .../subtitle?which=`）与立即补字幕
/// （`POST .../subtitle/backfill`）。
///
/// 1. host [LocalLibraryHostService.clearVideoSubtitle]：清 DB 字幕源 + 主字幕 cue；
///    只把**本视频自己的** sidecar（同目录、`<stem><字幕后缀>`）改名备份，别处文件 /
///    同目录别的视频的字幕 / 视频本体一律不碰；备份名不覆盖旧备份。
/// 2. 真实 [FushiSyncServer] 上的两条路由：参数校验、404、能力位。
/// 3. 单视频补字幕的身份构造（[libraryVideoSubtitleTarget] / [backfillLibraryVideoSubtitle]）：
///    身份取自已落库的刮削结论，没刮过不猜。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/video/subtitle/library_video_subtitle_backfill.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_backfill.dart';

const String _srt = '1\n00:00:01,000 --> 00:00:02,000\nまちがい\n';

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

LocalLibraryHostService _hostService(FushiDatabase db, Directory work) =>
    LocalLibraryHostService(
      db: db,
      dictionaryResourceRoot: work,
      packages: SyncAssetPackageService(db: db),
      refreshDictionaryCache: () async {},
      runExclusive: (Future<void> Function() body) => body(),
      videoSubtitleLangCode: 'ja',
    );

/// `<dir>/movie.mkv` + 指向 `movie.ja.srt` 的主字幕源 + 一条 cue。
Future<File> _seedVideo(
  FushiDatabase db,
  Directory dir, {
  String? subtitleSource,
  String? secondarySubtitleSource,
}) async {
  final File video = File(p.join(dir.path, 'movie.mkv'))
    ..writeAsBytesSync(<int>[1, 2, 3]);
  await db.upsertVideoBook(
    VideoBooksCompanion.insert(
      bookUid: 'video/movie',
      title: 'Movie',
      videoPath: video.path,
      subtitleSource: Value<String?>(subtitleSource),
      subtitleFormat: Value<String?>(subtitleSource == null ? null : 'srt'),
      secondarySubtitleSource: Value<String?>(secondarySubtitleSource),
    ),
  );
  await db.replaceCuesForBook('video/movie', <AudioCuesCompanion>[
    AudioCuesCompanion.insert(
      bookKey: 'video/movie',
      chapterHref: '',
      sentenceIndex: 0,
      textFragmentId: 'c0',
      cueText: 'まちがい',
      startMs: 1000,
      endMs: 2000,
      audioFileIndex: 0,
    ),
  ]);
  return video;
}

void main() {
  late Directory work;
  late FushiDatabase db;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('subtitle_manage_');
    db = _memDb();
  });

  tearDown(() async {
    await db.close();
    if (work.existsSync()) await work.delete(recursive: true);
  });

  group('host clearVideoSubtitle', () {
    test('primary：清 DB 源与 cue，本视频 sidecar 改名备份，视频不动', () async {
      final File sidecar = File(p.join(work.path, 'movie.ja.srt'))
        ..writeAsStringSync(_srt);
      final File video = await _seedVideo(
        db,
        work,
        subtitleSource: sidecar.path,
        secondarySubtitleSource: 'embedded:2',
      );

      final VideoSubtitleClearResult result = await _hostService(
        db,
        work,
      ).clearVideoSubtitle('video/movie');

      final VideoBookRow row = (await db.getVideoBookByBookUid('video/movie'))!;
      expect(row.subtitleSource, isNull);
      expect(row.subtitleFormat, isNull);
      expect(
        row.secondarySubtitleSource,
        'embedded:2',
        reason: 'which=primary 不碰副字幕',
      );
      expect(
        await db.getCuesForBook('video/movie'),
        isEmpty,
        reason: '旧字幕的 cue 留着会让句子列表继续显示错字幕',
      );
      expect(sidecar.existsSync(), isFalse);
      final File backup = File('${sidecar.path}.fushi-bak');
      expect(backup.readAsStringSync(), _srt, reason: '是改名备份不是删除');
      expect(video.existsSync(), isTrue);
      expect(result.clearedSources, <String, String?>{'primary': sidecar.path});
      expect(result.backedUpFiles, <String, String>{sidecar.path: backup.path});
      expect(result.remainingSidecars, isEmpty);
    });

    test('只动本视频自己的 sidecar：别处文件 / 同目录别人的字幕只清 DB', () async {
      final Directory elsewhere = Directory(p.join(work.path, 'other'))
        ..createSync();
      // 与视频同名但不在同目录：不是它的 sidecar。
      final File outside = File(p.join(elsewhere.path, 'movie.ja.srt'))
        ..writeAsStringSync(_srt);
      // 同目录但属于别的视频（stem 不同）。
      final File neighbour = File(p.join(work.path, 'other_movie.srt'))
        ..writeAsStringSync(_srt);
      await _seedVideo(
        db,
        work,
        subtitleSource: outside.path,
        secondarySubtitleSource: neighbour.path,
      );

      final VideoSubtitleClearResult result = await _hostService(
        db,
        work,
      ).clearVideoSubtitle('video/movie', which: VideoSubtitleClearScope.all);

      final VideoBookRow row = (await db.getVideoBookByBookUid('video/movie'))!;
      expect(row.subtitleSource, isNull);
      expect(row.secondarySubtitleSource, isNull);
      expect(outside.existsSync(), isTrue);
      expect(neighbour.existsSync(), isTrue);
      expect(result.backedUpFiles, isEmpty);
    });

    test('allSidecars：视频旁全部 sidecar 都挪走，备份名不覆盖旧备份', () async {
      final File ja = File(p.join(work.path, 'movie.ja.srt'))
        ..writeAsStringSync(_srt);
      final File en = File(p.join(work.path, 'movie.en.ass'))
        ..writeAsStringSync('en');
      final File oldBackup = File('${ja.path}.fushi-bak')
        ..writeAsStringSync('older');
      await _seedVideo(db, work, subtitleSource: ja.path);

      final LocalLibraryHostService host = _hostService(db, work);
      final VideoSubtitleClearResult partial = await host.clearVideoSubtitle(
        'video/movie',
      );
      expect(partial.remainingSidecars, <String>[
        'movie.en.ass',
      ], reason: '剩下的 sidecar 要报出来：它们会挡住自动补字幕');
      expect(oldBackup.readAsStringSync(), 'older', reason: '旧备份不能被覆盖');
      expect(File('${ja.path}.2.fushi-bak').readAsStringSync(), _srt);

      final VideoSubtitleClearResult all = await host.clearVideoSubtitle(
        'video/movie',
        allSidecars: true,
      );
      expect(all.backedUpFiles.keys, <String>[en.path]);
      expect(en.existsSync(), isFalse);
      expect(all.remainingSidecars, isEmpty);
    });

    test('sidecar 改名失败：已挪的改回、DB 不动，抛带错误码的 VideoSubtitleSidecarBusy', () async {
      final File ja = File(p.join(work.path, 'movie.ja.srt'))
        ..writeAsStringSync(_srt);
      final File en = File(p.join(work.path, 'movie.en.ass'))
        ..writeAsStringSync('en');
      // 备份名被一个目录占着：文件改名到目录上在所有平台都失败（等同 Windows 上
      // 文件被占用时 rename 抛 FileSystemException），而且不受 root 权限影响。
      Directory('${en.path}.fushi-bak').createSync();
      await _seedVideo(db, work, subtitleSource: ja.path);

      await expectLater(
        _hostService(
          db,
          work,
        ).clearVideoSubtitle('video/movie', allSidecars: true),
        throwsA(
          isA<VideoSubtitleSidecarBusy>()
              .having((VideoSubtitleSidecarBusy e) => e.path, 'path', en.path)
              .having(
                (VideoSubtitleSidecarBusy e) => e.toJson()['error'],
                'error',
                'subtitle_sidecar_busy',
              )
              .having(
                (VideoSubtitleSidecarBusy e) => e.notRestored,
                'notRestored',
                isEmpty,
              ),
        ),
      );

      expect(ja.readAsStringSync(), _srt, reason: '先挪走的主字幕要改回原名');
      expect(File('${ja.path}.fushi-bak').existsSync(), isFalse);
      expect(en.readAsStringSync(), 'en');
      final VideoBookRow row = (await db.getVideoBookByBookUid('video/movie'))!;
      expect(row.subtitleSource, ja.path, reason: '文件没挪成就不能先清 DB');
      expect(row.subtitleFormat, 'srt');
      expect(await db.getCuesForBook('video/movie'), hasLength(1));
    });

    test('未知视频 StateError；路径穿越 id ArgumentError', () async {
      final LocalLibraryHostService host = _hostService(db, work);
      await expectLater(
        host.clearVideoSubtitle('video/ghost'),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        host.clearVideoSubtitle('../x'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('互联路由', () {
    late FushiSyncServer server;
    late HttpClient http;
    final List<(String, String?)> backfillCalls = <(String, String?)>[];

    Future<(int, String)> send(
      String method,
      String path, {
      Object? body,
    }) async {
      final HttpClientRequest req = await http.openUrl(
        method,
        Uri.parse('http://127.0.0.1:${server.port}$path'),
      );
      req.headers.set(
        HttpHeaders.authorizationHeader,
        'Basic ${base64Encode(utf8.encode('fushi:tok'))}',
      );
      if (body != null) req.write(jsonEncode(body));
      final HttpClientResponse res = await req.close();
      return (res.statusCode, await res.transform(utf8.decoder).join());
    }

    setUp(() async {
      backfillCalls.clear();
      server = FushiSyncServer(
        syncDataDir: p.join(work.path, 'sync'),
        port: 0,
        token: 'tok',
        libraryService: _hostService(db, work),
      );
      await server.start();
      http = HttpClient();
    });

    tearDown(() async {
      http.close(force: true);
      await server.stop();
    });

    test('DELETE subtitle：which 校验、未知视频 404、成功回 JSON', () async {
      final File sidecar = File(p.join(work.path, 'movie.ja.srt'))
        ..writeAsStringSync(_srt);
      await _seedVideo(db, work, subtitleSource: sidecar.path);

      expect(
        (await send(
          'DELETE',
          '/api/library/videos/video%2Fmovie/subtitle?which=bogus',
        )).$1,
        400,
      );
      expect(
        (await send(
          'DELETE',
          '/api/library/videos/video%2Fmovie/subtitle?sidecars=some',
        )).$1,
        400,
      );
      expect(
        (await send('DELETE', '/api/library/videos/video%2Fghost/subtitle')).$1,
        404,
      );
      final (int status, String body) = await send(
        'DELETE',
        '/api/library/videos/video%2Fmovie/subtitle',
      );
      expect(status, 200, reason: body);
      expect(jsonDecode(body)['clearedSources'], <String, Object?>{
        'primary': sidecar.path,
      });
      expect(sidecar.existsSync(), isFalse);
    });

    test(
      'DELETE subtitle：sidecar 被占用 → 409 + subtitle_sidecar_busy，DB 不动',
      () async {
        final File sidecar = File(p.join(work.path, 'movie.ja.srt'))
          ..writeAsStringSync(_srt);
        Directory('${sidecar.path}.fushi-bak').createSync();
        await _seedVideo(db, work, subtitleSource: sidecar.path);

        final (int status, String body) = await send(
          'DELETE',
          '/api/library/videos/video%2Fmovie/subtitle',
        );
        expect(status, 409, reason: body);
        final Map<String, Object?> json =
            (jsonDecode(body) as Map<String, Object?>);
        expect(json['error'], 'subtitle_sidecar_busy');
        expect(json['path'], sidecar.path);
        expect(sidecar.existsSync(), isTrue);
        expect(
          (await db.getVideoBookByBookUid('video/movie'))!.subtitleSource,
          sidecar.path,
        );
      },
    );

    test('POST subtitle/backfill：未接线 501；接线后透传语言，未知视频 404', () async {
      expect(
        (await send(
          'POST',
          '/api/library/videos/video%2Fmovie/subtitle/backfill',
        )).$1,
        501,
        reason: '无头服务端不接补字幕服务',
      );

      server.videoSubtitleBackfill = (String id, {String? language}) async {
        backfillCalls.add((id, language));
        if (id != 'video/movie') return null;
        return const VideoSubtitleBackfillReport(
          outcome: 'installed',
          installedPath: '/x/movie.ja.srt',
          language: 'ja',
        );
      };
      final (int status, String body) = await send(
        'POST',
        '/api/library/videos/video%2Fmovie/subtitle/backfill',
        body: <String, Object?>{'language': 'ja'},
      );
      expect(status, 200, reason: body);
      expect(jsonDecode(body), <String, Object?>{
        'outcome': 'installed',
        'installed': true,
        'installedPath': '/x/movie.ja.srt',
        'language': 'ja',
      });
      expect(backfillCalls.single, ('video/movie', 'ja'));
      expect(
        (await send(
          'POST',
          '/api/library/videos/video%2Fghost/subtitle/backfill',
        )).$1,
        404,
      );
      expect(
        (await send(
          'POST',
          '/api/library/videos/video%2Fmovie/subtitle/backfill',
          body: <String, Object?>{'language': '../etc'},
        )).$1,
        400,
      );
      expect(
        (await send(
          'GET',
          '/api/library/videos/video%2Fmovie/subtitle/backfill',
        )).$1,
        405,
      );
    });

    test('能力位声明两条新端点', () async {
      final Map<String, Object?> live =
          (jsonDecode(
                (await send('GET', '/api/capabilities')).$2,
              )['liveLibrary']
              as Map<String, Object?>);
      expect(live['videoSubtitleClear'], isTrue);
      expect(live['videoSubtitleBackfill'], isFalse);
      server.videoSubtitleBackfill = (String id, {String? language}) async =>
          null;
      final Map<String, Object?> after =
          (jsonDecode(
                (await send('GET', '/api/capabilities')).$2,
              )['liveLibrary']
              as Map<String, Object?>);
      expect(after['videoSubtitleBackfill'], isTrue);
    });
  });

  group('单视频补字幕的身份', () {
    Future<void> scrape(String bookUid, {required String provider}) async {
      final int workId = await db.upsertVideoMetadataWork(
        VideoMetadataWorksCompanion.insert(
          bookUid: Value<String?>(bookUid),
          mediaType: 'movie',
          title: 'ドラえもん のび太とアニマル惑星',
          originalTitle: const Value<String?>('ドラえもん のび太とアニマル惑星'),
          year: const Value<int?>(1990),
          runtimeMinutes: const Value<int?>(100),
          updatedAt: 1,
        ),
      );
      await db.replaceVideoMetadataProviderIdentities(
        workId: workId,
        identities: <VideoMetadataProviderIdentitiesCompanion>[
          VideoMetadataProviderIdentitiesCompanion.insert(
            identityKey: 'work:$bookUid:$provider',
            workId: Value<int?>(workId),
            provider: provider,
            externalId: '12345',
            isPrimary: const Value<bool>(true),
            updatedAt: 1,
          ),
        ],
      );
    }

    test('同一 provider 多行（大小写不同的旧行）→ 保留主身份的 id，不被后写顶掉', () async {
      await _seedVideo(db, work);
      final VideoBookRow book = (await db.getVideoBookByBookUid(
        'video/movie',
      ))!;
      final int workId = await db.upsertVideoMetadataWork(
        VideoMetadataWorksCompanion.insert(
          bookUid: const Value<String?>('video/movie'),
          mediaType: 'movie',
          title: 'リズと青い鳥',
          updatedAt: 1,
        ),
      );
      await db.replaceVideoMetadataProviderIdentities(
        workId: workId,
        identities: <VideoMetadataProviderIdentitiesCompanion>[
          VideoMetadataProviderIdentitiesCompanion.insert(
            identityKey: 'work:video/movie:tmdb',
            workId: Value<int?>(workId),
            provider: 'TMDB',
            externalId: '12345',
            isPrimary: const Value<bool>(true),
            updatedAt: 1,
          ),
          VideoMetadataProviderIdentitiesCompanion.insert(
            identityKey: 'work:video/movie:tmdb-legacy',
            workId: Value<int?>(workId),
            provider: 'tmdb',
            externalId: '62564',
            updatedAt: 1,
          ),
        ],
      );

      final SubtitleBackfillTarget target = (await libraryVideoSubtitleTarget(
        db,
        book,
      )).target!;
      expect(target.media.tmdbId, 12345, reason: '主身份优先，旧的非主行不能覆盖它');
      expect(
        libraryWorkExternalIds(
          await db.getVideoMetadataProviderIdentities(workId: workId),
        ),
        <String, String>{'tmdb': '12345'},
      );
    });

    test('刮过的视频：身份取落库的作品 + provider id；没刮过 → 不猜', () async {
      await _seedVideo(db, work);
      final VideoBookRow book = (await db.getVideoBookByBookUid(
        'video/movie',
      ))!;
      final ({SubtitleBackfillTarget? target, String? reason}) unscraped =
          await libraryVideoSubtitleTarget(db, book);
      expect(unscraped.target, isNull);
      expect(unscraped.reason, contains('not been scraped'));

      await scrape('video/movie', provider: 'tmdb');
      final ({SubtitleBackfillTarget? target, String? reason}) built =
          await libraryVideoSubtitleTarget(db, book, explicitLanguage: 'ja');
      final SubtitleBackfillTarget target = built.target!;
      expect(target.media.tmdbId, 12345);
      expect(target.media.mediaKind, VideoMetadataMediaKind.movie);
      expect(target.media.originalTitle, 'ドラえもん のび太とアニマル惑星');
      expect(target.media.year, 1990);
      expect(target.scrapedRuntimeMinutes, 100);
      expect(target.explicitLanguage, 'ja');
      expect(target.hasExistingSubtitle, isFalse);
    });

    test('backfillLibraryVideoSubtitle：未知视频 null；没配字幕来源 unavailable', () async {
      await _seedVideo(db, work);
      final VideoSubtitleBackfillService empty = VideoSubtitleBackfillService(
        registry: VideoSubtitleRegistry(const <VideoSubtitleProvider>[]),
      );
      expect(
        await backfillLibraryVideoSubtitle(
          database: db,
          service: empty,
          videoId: 'video/ghost',
        ),
        isNull,
      );
      expect(
        (await backfillLibraryVideoSubtitle(
          database: db,
          service: empty,
          videoId: 'video/movie',
        ))!.outcome,
        'unavailable',
      );
      expect(
        (await backfillLibraryVideoSubtitle(
          database: db,
          service: null,
          videoId: 'video/movie',
        ))!.outcome,
        'unavailable',
      );
    });
  });
}
