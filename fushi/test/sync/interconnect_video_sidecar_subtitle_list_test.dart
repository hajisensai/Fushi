/// 反馈 -CaVsioFhG：互联 host 上一集有多条外挂字幕，client 只看得到默认那一条。
///
/// 1. 纯函数 / wire：[sidecarSubtitleLanguageTag]、[RemoteVideoSidecarSubtitle] 与
///    [RemoteVideoStreamUrls.sidecarSubtitles] 的 JSON 往返（坏条目丢弃、老 host 不带
///    该键 → 空表）。
/// 2. host [LocalLibraryHostService.listVideoSidecarSubtitles]：同目录多条 sidecar
///    全部列出（只认这个视频自己的、只认字幕扩展名、按名排序）。
/// 3. 端到端（真实 server / host / client）：`/streamurl` 下发全部外挂字幕、默认那条
///    标 isDefault 且与旧单值字段一致；client 按文件名逐条下载拿到各自的字节；
///    host 没列出的名字（含路径穿越）一律 404；能力位声明。
/// 4. 混版本：不实现 [VideoSidecarSubtitleListHost] 的老 host 不发列表、`?sidecar=`
///    落 404，旧单值字段照旧可用（新 client 退回旧行为）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_sidecar.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:path/path.dart' as p;

const String _token = 'sidecar-list-token';

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

LocalLibraryHostService _hostService({
  required FushiDatabase db,
  required Directory work,
}) => LocalLibraryHostService(
  db: db,
  dictionaryResourceRoot: work,
  packages: SyncAssetPackageService(db: db),
  refreshDictionaryCache: () async {},
  runExclusive: (Future<void> Function() body) => body(),
  videoSubtitleLangCode: 'ja',
);

Future<InterconnectSyncBackend> _clientBackend(String base) async {
  final FushiDatabase db = _memDb();
  final SyncRepository repo = SyncRepository(db);
  await repo.setFushiClientUrls(<FushiClientUrl>[
    FushiClientUrl(url: base, enabled: true),
  ]);
  await repo.setFushiClientToken(_token);
  final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe(
    (String u, String t) async => true,
  );
  await backend.restoreAuth(repo);
  await backend.authenticate(repo: repo);
  return backend;
}

/// 带 Basic 鉴权 GET [url]，返回 (状态码, 正文)。
Future<(int, String)> _get(String url) async {
  final HttpClient http = HttpClient();
  try {
    final HttpClientRequest req = await http.getUrl(Uri.parse(url));
    req.headers.set(
      HttpHeaders.authorizationHeader,
      'Basic ${base64Encode(utf8.encode('fushi:$_token'))}',
    );
    final HttpClientResponse res = await req.close();
    return (res.statusCode, await res.transform(utf8.decoder).join());
  } finally {
    http.close(force: true);
  }
}

String _srt(String text) => '1\n00:00:01,000 --> 00:00:02,000\n$text\n';

/// 视频 `movie.mp4` 旁放四条自己的 sidecar + 一条别的视频的 + 一个非字幕文件。
Future<Directory> _seedMovieWithSidecars(
  FushiDatabase db,
  Directory work,
) async {
  final Directory dir = Directory(p.join(work.path, 'vids'))
    ..createSync(recursive: true);
  final File vid = File(p.join(dir.path, 'movie.mp4'))
    ..writeAsBytesSync(<int>[1, 2, 3]);
  File(p.join(dir.path, 'movie.ja.srt')).writeAsStringSync(_srt('日本語'));
  File(p.join(dir.path, 'movie.zh.ass')).writeAsStringSync('[Script Info]\n');
  File(p.join(dir.path, 'movie.en.vtt')).writeAsStringSync('WEBVTT\n');
  File(p.join(dir.path, 'movie.srt')).writeAsStringSync(_srt('plain'));
  File(p.join(dir.path, 'other.ja.srt')).writeAsStringSync(_srt('other'));
  File(p.join(dir.path, 'movie.nfo')).writeAsStringSync('<movie/>');
  await db.upsertVideoBook(
    VideoBooksCompanion.insert(
      bookUid: 'video/movie',
      title: 'Movie',
      videoPath: vid.path,
    ),
  );
  return dir;
}

/// 改动前的 host：只有单值默认字幕，不实现 [VideoSidecarSubtitleListHost]。
class _LegacyHost implements FushiLibraryHostService {
  _LegacyHost({required this.video, required this.subtitle});

  final File video;
  final File subtitle;

  @override
  Future<File?> resolveVideoFile(String id, {int episodeIndex = 0}) async =>
      id == 'video/movie' ? video : null;

  @override
  Future<File?> resolveVideoSubtitle(
    String id, {
    String langCode = '',
    int episodeIndex = 0,
  }) async => id == 'video/movie' ? subtitle : null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

void main() {
  group('纯函数 / wire', () {
    test('sidecarSubtitleLanguageTag 取 stem 与扩展名之间的标记', () {
      expect(sidecarSubtitleLanguageTag('movie', 'movie.ja.srt'), 'ja');
      expect(
        sidecarSubtitleLanguageTag('movie', 'Movie.zh-Hans.ASS'),
        'zh-Hans',
      );
      expect(sidecarSubtitleLanguageTag('movie', 'movie.srt'), isNull);
      expect(sidecarSubtitleLanguageTag('movie', 'other.ja.srt'), isNull);
      expect(sidecarSubtitleLanguageTag('movie', 'movie.ja.txt'), isNull);
    });

    test('RemoteVideoSidecarSubtitle JSON 往返', () {
      const RemoteVideoSidecarSubtitle full = RemoteVideoSidecarSubtitle(
        fileName: 'movie.ja.srt',
        format: 'srt',
        language: 'ja',
        sizeBytes: 42,
        isDefault: true,
        url:
            'http://h/api/library/videos/video/movie/subtitle?sidecar=movie.ja.srt',
      );
      final RemoteVideoSidecarSubtitle back =
          RemoteVideoSidecarSubtitle.fromJson(
            jsonDecode(jsonEncode(full.toJson())),
          )!;
      expect(back.fileName, full.fileName);
      expect(back.format, full.format);
      expect(back.language, full.language);
      expect(back.sizeBytes, full.sizeBytes);
      expect(back.isDefault, isTrue);
      expect(back.url, full.url);

      const RemoteVideoSidecarSubtitle bare = RemoteVideoSidecarSubtitle(
        fileName: 'movie.srt',
        format: 'srt',
      );
      // 缺省值不上 wire（与 embeddedSubtitleTracks 同一写法）。
      expect(bare.toJson(), <String, Object?>{
        'fileName': 'movie.srt',
        'format': 'srt',
      });
      final RemoteVideoSidecarSubtitle bareBack =
          RemoteVideoSidecarSubtitle.fromJson(bare.toJson())!;
      expect(bareBack.isDefault, isFalse);
      expect(bareBack.language, isNull);
      expect(bareBack.sizeBytes, isNull);
    });

    test('RemoteVideoStreamUrls 读 sidecarSubtitles：坏条目丢弃，老 host 不带 → 空表', () {
      final RemoteVideoStreamUrls urls = RemoteVideoStreamUrls.fromJson(
        <String, Object?>{
          'url': 'http://h/stream',
          'subtitleUrl': 'http://h/subtitle',
          'subtitleFileName': 'movie.ja.srt',
          'sidecarSubtitles': <Object?>[
            <String, Object?>{
              'fileName': 'movie.ja.srt',
              'format': 'srt',
              'isDefault': true,
            },
            <String, Object?>{'fileName': 'movie.zh.ass', 'format': 'ASS'},
            <String, Object?>{'fileName': '../etc/passwd', 'format': 'srt'},
            <String, Object?>{'fileName': r'a\b.srt', 'format': 'srt'},
            <String, Object?>{'fileName': 'movie.en.vtt'},
            'garbage',
          ],
        },
      );
      expect(
        urls.sidecarSubtitles.map((RemoteVideoSidecarSubtitle s) => s.fileName),
        <String>['movie.ja.srt', 'movie.zh.ass'],
      );
      expect(urls.sidecarSubtitles[1].format, 'ass');
      // 旧单值字段照旧可读（新 client 仍兼容老 host）。
      expect(urls.subtitleFileName, 'movie.ja.srt');

      final RemoteVideoStreamUrls legacy =
          RemoteVideoStreamUrls.fromJson(<String, Object?>{
            'url': 'http://h/stream',
            'subtitleUrl': 'http://h/subtitle',
            'subtitleFileName': 'movie.ja.srt',
          });
      expect(legacy.sidecarSubtitles, isEmpty);
      expect(legacy.subtitleUrl, 'http://h/subtitle');
    });
  });

  group('host listVideoSidecarSubtitles', () {
    late Directory work;
    late FushiDatabase db;

    setUp(() async {
      work = await Directory.systemTemp.createTemp('sidecar_list_host_');
      db = _memDb();
    });

    tearDown(() async {
      await db.close();
      if (work.existsSync()) await work.delete(recursive: true);
    });

    test('同目录多条 sidecar 全部列出，不含别的视频 / 非字幕文件，按名排序', () async {
      await _seedMovieWithSidecars(db, work);
      final LocalLibraryHostService svc = _hostService(db: db, work: work);
      expect(svc, isA<VideoSidecarSubtitleListHost>());
      final List<File> files = await svc.listVideoSidecarSubtitles(
        'video/movie',
      );
      expect(files.map((File f) => p.basename(f.path)), <String>[
        'movie.en.vtt',
        'movie.ja.srt',
        'movie.srt',
        'movie.zh.ass',
      ]);
      // 默认字幕（ja 学习语言 → movie.ja.srt）就在列表里。
      final File? def = await svc.resolveVideoSubtitle('video/movie');
      expect(files.any((File f) => p.equals(f.path, def!.path)), isTrue);
    });

    test('未知视频 → 空表', () async {
      final LocalLibraryHostService svc = _hostService(db: db, work: work);
      expect(await svc.listVideoSidecarSubtitles('video/nope'), isEmpty);
    });
  });

  group('端到端：新 host + 新 client', () {
    late Directory work;
    late FushiDatabase hostDb;
    late FushiSyncServer server;
    late String base;

    setUp(() async {
      work = await Directory.systemTemp.createTemp('sidecar_list_e2e_');
      hostDb = _memDb();
      await _seedMovieWithSidecars(hostDb, work);
      server = FushiSyncServer(
        syncDataDir: p.join(work.path, 'server_data'),
        port: 0,
        token: _token,
        allowLan: false,
        libraryService: _hostService(db: hostDb, work: work),
      );
      await server.start();
      base = 'http://127.0.0.1:${server.port}';
    });

    tearDown(() async {
      await server.stop();
      await hostDb.close();
      if (work.existsSync()) await work.delete(recursive: true);
    });

    test('capabilities 声明 videoSidecarSubtitles', () async {
      final (int status, String body) = await _get('$base/api/capabilities');
      expect(status, 200, reason: body);
      final Map<String, dynamic> json =
          jsonDecode(body) as Map<String, dynamic>;
      expect(
        (json['liveLibrary']
            as Map<String, dynamic>)[kVideoSidecarSubtitlesCapability],
        isTrue,
      );
    });

    test('/streamurl 列出全部外挂字幕，默认那条与旧单值字段一致', () async {
      final (int status, String body) = await _get(
        '$base/api/library/videos/video/movie/streamurl',
      );
      expect(status, 200, reason: body);
      final RemoteVideoStreamUrls urls = RemoteVideoStreamUrls.fromJson(
        jsonDecode(body) as Map<String, Object?>,
      );
      expect(
        urls.sidecarSubtitles.map((RemoteVideoSidecarSubtitle s) => s.fileName),
        <String>['movie.en.vtt', 'movie.ja.srt', 'movie.srt', 'movie.zh.ass'],
      );
      // 老 client 读的单值字段照发。
      expect(urls.subtitleFileName, 'movie.ja.srt');
      expect(urls.subtitleUrl, isNotNull);
      final List<RemoteVideoSidecarSubtitle> defaults = urls.sidecarSubtitles
          .where((RemoteVideoSidecarSubtitle s) => s.isDefault)
          .toList();
      expect(defaults, hasLength(1));
      expect(defaults.single.fileName, urls.subtitleFileName);
      final RemoteVideoSidecarSubtitle zh = urls.sidecarSubtitles.last;
      expect(zh.format, 'ass');
      expect(zh.language, 'zh');
      expect(zh.sizeBytes, '[Script Info]\n'.length);
      expect(
        urls.sidecarSubtitles
            .firstWhere(
              (RemoteVideoSidecarSubtitle s) => s.fileName == 'movie.srt',
            )
            .language,
        isNull,
      );
      expect(
        Uri.parse(zh.url!).queryParameters[kVideoSidecarSubtitleQueryParam],
        'movie.zh.ass',
      );
    });

    test('client 按文件名逐条下载，拿到的是各自的字节', () async {
      final InterconnectSyncBackend backend = await _clientBackend(base);
      final Directory out = Directory(p.join(work.path, 'client'))
        ..createSync(recursive: true);
      for (final (String name, String content) in <(String, String)>[
        ('movie.ja.srt', _srt('日本語')),
        ('movie.zh.ass', '[Script Info]\n'),
        ('movie.en.vtt', 'WEBVTT\n'),
        ('movie.srt', _srt('plain')),
      ]) {
        final File dest = File(p.join(out.path, name));
        await backend.getRemoteVideoSidecarSubtitle(
          'video/movie',
          dest,
          fileName: name,
        );
        expect(await dest.readAsString(), content, reason: name);
      }
    });

    test('host 没列出的名字一律 404：别的视频的字幕 / 路径穿越 / 不存在', () async {
      for (final String name in <String>[
        'other.ja.srt',
        '../vids/movie.ja.srt',
        'movie.nfo',
        'movie.fr.srt',
      ]) {
        final String url =
            Uri.parse('$base/api/library/videos/video/movie/subtitle')
                .replace(
                  queryParameters: <String, String>{
                    kVideoSidecarSubtitleQueryParam: name,
                  },
                )
                .toString();
        final (int status, _) = await _get(url);
        expect(status, 404, reason: name);
      }
    });
  });

  group('混版本：老 host（无 VideoSidecarSubtitleListHost）', () {
    late Directory work;
    late FushiSyncServer server;
    late String base;

    setUp(() async {
      work = await Directory.systemTemp.createTemp('sidecar_list_legacy_');
      final File video = File(p.join(work.path, 'movie.mp4'))
        ..writeAsBytesSync(<int>[1, 2, 3]);
      final File subtitle = File(p.join(work.path, 'movie.ja.srt'))
        ..writeAsStringSync(_srt('legacy'));
      File(p.join(work.path, 'movie.zh.srt')).writeAsStringSync(_srt('zh'));
      server = FushiSyncServer(
        syncDataDir: p.join(work.path, 'server_data'),
        port: 0,
        token: _token,
        allowLan: false,
        libraryService: _LegacyHost(video: video, subtitle: subtitle),
      );
      await server.start();
      base = 'http://127.0.0.1:${server.port}';
    });

    tearDown(() async {
      await server.stop();
      if (work.existsSync()) await work.delete(recursive: true);
    });

    test('不发列表、?sidecar= 落 404；旧单值默认字幕照旧可下', () async {
      final (int status, String body) = await _get(
        '$base/api/library/videos/video/movie/streamurl',
      );
      expect(status, 200, reason: body);
      final Map<String, Object?> json =
          jsonDecode(body) as Map<String, Object?>;
      expect(json.containsKey('sidecarSubtitles'), isFalse);
      final RemoteVideoStreamUrls urls = RemoteVideoStreamUrls.fromJson(json);
      expect(urls.sidecarSubtitles, isEmpty);
      expect(urls.subtitleFileName, 'movie.ja.srt');

      final (int sidecarStatus, _) = await _get(
        '$base/api/library/videos/video/movie/subtitle?'
        '$kVideoSidecarSubtitleQueryParam=movie.zh.srt',
      );
      expect(sidecarStatus, 404);

      final InterconnectSyncBackend backend = await _clientBackend(base);
      final File dest = File(p.join(work.path, 'dl.srt'));
      await backend.getRemoteVideoSubtitle('video/movie', dest);
      expect(await dest.readAsString(), _srt('legacy'));
    });
  });
}
