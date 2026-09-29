/// 远端视频「导入 / 重定时的字幕自动上传 host 并设为默认」+「远端视频也能对轴 /
/// 重定时」守卫。
///
/// 1. 纯函数：[defaultSidecarSubtitleSuffix] / [sidecarSuffixesDisplacedBy] /
///    [clipVideoAudioTimeout]。
/// 2. host [LocalLibraryHostService.importDefaultVideoSubtitle]：按 host 学习语言定
///    后缀、压过它的旧 sidecar 改名 `.fushi-bak` 让位（原始文件只备份一次）、落库。
/// 3. 端到端（真实 server/host/client）：client 带 `asDefault` 上传后 host 首选字幕
///    就是它；不带时仍按 client 报的后缀落盘（live push 旧语义不变）；新 host 的
///    capabilities 声明 `liveLibrary.videoSubtitleDefault`。
/// 3b. 混版本（BUG-2728）：假老 host 如实模拟「按后缀覆盖、无备份」，client 探到能力位
///    缺失 / false / 端点 404 时一个 PUT 都不发，host 原字幕字节不变，能力位只探一次。
/// 4. 源码守卫：视频页远端导入会上传、设置「导入的字幕自动上传到服务端」关掉时
///    不上传也不提示、对轴 / 重定时入口不再只认本地文件。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/video_sidecar.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

const String _srtOriginal = '1\n'
    '00:00:01,000 --> 00:00:02,000\n'
    'もとの字幕\n';

const String _srtUploaded = '1\n'
    '00:00:05,000 --> 00:00:06,000\n'
    'こんにちは\n'
    '\n'
    '2\n'
    '00:00:07,000 --> 00:00:08,000\n'
    'さようなら\n';

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

LocalLibraryHostService _hostService({
  required FushiDatabase db,
  required Directory work,
}) =>
    LocalLibraryHostService(
      db: db,
      dictionaryResourceRoot: work,
      packages: SyncAssetPackageService(db: db),
      refreshDictionaryCache: () async {},
      runExclusive: (Future<void> Function() body) => body(),
      videoSubtitleLangCode: 'ja',
    );

Future<InterconnectSyncBackend> _clientBackend({
  required String base,
  required String token,
}) async {
  final FushiDatabase db = _memDb();
  final SyncRepository repo = SyncRepository(db);
  await repo.setFushiClientUrls(<FushiClientUrl>[
    FushiClientUrl(url: base, enabled: true),
  ]);
  await repo.setFushiClientToken(token);
  final InterconnectSyncBackend backend =
      InterconnectSyncBackend.withProbe((String u, String t) async => true);
  await backend.restoreAuth(repo);
  await backend.authenticate(repo: repo);
  return backend;
}

Future<File> _seedVideo(FushiDatabase db, Directory dir) async {
  final File vid = File(p.join(dir.path, 'movie.mp4'))
    ..writeAsBytesSync(<int>[1, 2, 3]);
  await db.upsertVideoBook(VideoBooksCompanion.insert(
    bookUid: 'video/movie',
    title: 'Movie',
    videoPath: vid.path,
  ));
  return vid;
}

void main() {
  group('纯函数', () {
    test('defaultSidecarSubtitleSuffix 取学习语言标记组，非字幕格式为 null', () {
      expect(defaultSidecarSubtitleSuffix('srt', langCode: 'ja'), '.ja.srt');
      expect(defaultSidecarSubtitleSuffix('.ASS', langCode: 'ja'), '.ja.ass');
      expect(defaultSidecarSubtitleSuffix('.vtt', langCode: ''), '.vtt');
      expect(defaultSidecarSubtitleSuffix('.txt', langCode: 'ja'), isNull);
      expect(defaultSidecarSubtitleSuffix('', langCode: 'ja'), isNull);
    });

    test('sidecarSuffixesDisplacedBy 返回优先级不低于自身的全部后缀', () {
      expect(sidecarSuffixesDisplacedBy('.ja.srt', langCode: 'ja'),
          <String>['.ja.srt']);
      expect(sidecarSuffixesDisplacedBy('.ja.ass', langCode: 'ja'),
          <String>['.ja.srt', '.ja.ass']);
      // 不在优先级表里（别的语言标记）：只让位同名文件。
      expect(sidecarSuffixesDisplacedBy('.en.srt', langCode: 'ja'),
          <String>['.en.srt']);
    });

    test('clipVideoAudioTimeout：句子片段 120s，整集按 10 倍速放大', () {
      expect(clipVideoAudioTimeout(8000), const Duration(seconds: 120));
      expect(
          clipVideoAudioTimeout(24 * 60 * 1000), const Duration(seconds: 144));
      expect(clipVideoAudioTimeout(2 * 60 * 60 * 1000),
          const Duration(seconds: 720));
    });
  });

  group('host importDefaultVideoSubtitle', () {
    late Directory work;
    late FushiDatabase db;

    setUp(() async {
      work = await Directory.systemTemp.createTemp('default_subtitle_');
      db = _memDb();
    });

    tearDown(() async {
      await db.close();
      if (work.existsSync()) await work.delete(recursive: true);
    });

    test('高优先级旧 sidecar 让位备份，新字幕成为首选并落库', () async {
      final Directory vidDir = Directory(p.join(work.path, 'vids'))
        ..createSync(recursive: true);
      await _seedVideo(db, vidDir);
      final File oldJa = File(p.join(vidDir.path, 'movie.ja.srt'))
        ..writeAsStringSync(_srtOriginal);
      final File plain = File(p.join(vidDir.path, 'Movie.srt'))
        ..writeAsStringSync(_srtOriginal);
      final File upload = File(p.join(work.path, 'upload.tmp'))
        ..writeAsStringSync(_srtUploaded);

      final LocalLibraryHostService svc = _hostService(db: db, work: work);
      final String placed = await svc.importDefaultVideoSubtitle(upload,
          id: 'video/movie', format: '.ass');

      expect(placed, '.ja.ass');
      final File landed = File(p.join(vidDir.path, 'movie.ja.ass'));
      expect(landed.readAsStringSync(), _srtUploaded);
      expect(oldJa.existsSync(), isFalse,
          reason: '.ja.srt 优先级高于 .ja.ass，不让位的话 host 仍会选旧档');
      expect(
          File('${oldJa.path}$kDisplacedSidecarBackupSuffix')
              .readAsStringSync(),
          _srtOriginal,
          reason: '让位是改名备份，不是删除');
      expect(plain.existsSync(), isTrue, reason: '低优先级 sidecar 不动');

      expect(
          (await svc.resolveVideoSubtitle('video/movie'))?.path, landed.path);
      final VideoBookRow row = (await db.getVideoBookByBookUid('video/movie'))!;
      expect(row.subtitleSource, landed.path);
      expect(row.subtitleFormat, 'ass');
    });

    test('连续上传：原始文件只备份一次，之前的上传产物直接替换', () async {
      final Directory vidDir = Directory(p.join(work.path, 'vids'))
        ..createSync(recursive: true);
      await _seedVideo(db, vidDir);
      final File jaSrt = File(p.join(vidDir.path, 'movie.ja.srt'))
        ..writeAsStringSync(_srtOriginal);
      final LocalLibraryHostService svc = _hostService(db: db, work: work);

      for (int i = 0; i < 2; i++) {
        final File upload = File(p.join(work.path, 'upload$i.tmp'))
          ..writeAsStringSync('$_srtUploaded\n$i\n');
        await svc.importDefaultVideoSubtitle(upload,
            id: 'video/movie', format: 'srt');
      }

      expect(jaSrt.readAsStringSync(), '$_srtUploaded\n1\n');
      expect(
          File('${jaSrt.path}$kDisplacedSidecarBackupSuffix')
              .readAsStringSync(),
          _srtOriginal,
          reason: '第二次上传不能用第一次的上传产物覆盖掉原始备份');
      expect(
          vidDir
              .listSync()
              .map((FileSystemEntity e) => p.basename(e.path))
              .where((String n) => n.endsWith(kDisplacedSidecarBackupSuffix)),
          hasLength(1));
      expect((await db.getCuesForBook('video/movie')).length, 2);
    });

    test('未知视频 StateError；非字幕格式 ArgumentError', () async {
      final File upload = File(p.join(work.path, 'upload.tmp'))
        ..writeAsStringSync(_srtUploaded);
      final LocalLibraryHostService svc = _hostService(db: db, work: work);
      expect(
          () => svc.importDefaultVideoSubtitle(upload,
              id: 'video/nope', format: 'srt'),
          throwsStateError);
      expect(
          () => svc.importDefaultVideoSubtitle(upload,
              id: 'video/movie', format: 'exe'),
          throwsArgumentError);
    });
  });

  group('端到端 PUT /subtitle', () {
    late Directory work;
    late FushiSyncServer server;
    late FushiDatabase hostDb;
    late Directory vidDir;
    late String base;
    const String token = 'default-subtitle-token';

    setUp(() async {
      work = await Directory.systemTemp.createTemp('default_subtitle_e2e_');
      hostDb = _memDb();
      vidDir = Directory(p.join(work.path, 'vids'))
        ..createSync(recursive: true);
      await _seedVideo(hostDb, vidDir);
      server = FushiSyncServer(
        syncDataDir: p.join(work.path, 'server_data'),
        port: 0,
        token: token,
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

    test('新 host 的 capabilities 声明 liveLibrary.videoSubtitleDefault', () async {
      final HttpClient http = HttpClient();
      try {
        final HttpClientRequest req =
            await http.getUrl(Uri.parse('$base/api/capabilities'));
        req.headers.set(HttpHeaders.authorizationHeader,
            'Basic ${base64Encode(utf8.encode('fushi:$token'))}');
        final HttpClientResponse res = await req.close();
        final String body = await res.transform(utf8.decoder).join();
        expect(res.statusCode, 200, reason: body);
        final Map<String, dynamic> json =
            jsonDecode(body) as Map<String, dynamic>;
        expect(
            (json['liveLibrary']
                as Map<String, dynamic>)['videoSubtitleDefault'],
            isTrue);
      } finally {
        http.close(force: true);
      }
      final InterconnectSyncBackend backend =
          await _clientBackend(base: base, token: token);
      expect(await backend.hostSupportsVideoSubtitleDefault(), isTrue);
    });

    test('asDefault：host 按自己的学习语言定后缀、旧档备份让位并成为首选字幕', () async {
      final File oldJa = File(p.join(vidDir.path, 'movie.ja.srt'))
        ..writeAsStringSync(_srtOriginal);
      final InterconnectSyncBackend backend =
          await _clientBackend(base: base, token: token);
      final File sub = File(p.join(work.path, 'picked.srt'))
        ..writeAsStringSync(_srtUploaded);

      // client 的学习语言（en）与 host（ja）不同：后缀以 host 为准。
      expect(
          await backend.putRemoteVideoSubtitleAsDefault('video/movie', sub,
              suffix: '.en.srt'),
          RemoteSubtitleDefaultUpload.applied);

      expect(oldJa.readAsStringSync(), _srtUploaded);
      expect(File(p.join(vidDir.path, 'movie.en.srt')).existsSync(), isFalse);
      expect(
          File('${oldJa.path}$kDisplacedSidecarBackupSuffix')
              .readAsStringSync(),
          _srtOriginal);
      final VideoBookRow row =
          (await hostDb.getVideoBookByBookUid('video/movie'))!;
      expect(row.subtitleSource, oldJa.path);
    });

    test('不带 asDefault：仍按 client 报的后缀落盘（live push 语义不变）', () async {
      final InterconnectSyncBackend backend =
          await _clientBackend(base: base, token: token);
      final File sub = File(p.join(work.path, 'picked.srt'))
        ..writeAsStringSync(_srtUploaded);
      expect(
          await backend.putRemoteVideoSubtitle('video/movie', sub,
              suffix: '.en.srt'),
          isTrue);
      expect(File(p.join(vidDir.path, 'movie.en.srt')).existsSync(), isTrue);
    });
  });

  // BUG-2728 混版本：老 host 不认 X-Hibiki-Subtitle-Default，PUT 走 live push 旧路径
  // 按 client 报的后缀 `rename` 覆盖同名旧字幕、不留备份。假 host 如实模拟这个覆盖
  // 语义，client 必须先看能力位、不支持就一个 PUT 都不发。
  group('老 host（无 videoSubtitleDefault 能力位）', () {
    late Directory work;
    late HttpServer fake;
    late File hostJa;
    late String base;
    late int capabilityProbes;
    late int subtitlePuts;
    // null = /api/capabilities 整个端点 404（更老的 host）。
    Map<String, dynamic>? capabilities;

    setUp(() async {
      work = await Directory.systemTemp.createTemp('default_subtitle_old_');
      hostJa = File(p.join(work.path, 'movie.ja.srt'))
        ..writeAsStringSync(_srtOriginal);
      capabilityProbes = 0;
      subtitlePuts = 0;
      fake = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      fake.listen((HttpRequest req) async {
        final HttpResponse res = req.response;
        if (req.uri.path == '/api/capabilities') {
          capabilityProbes++;
          final Map<String, dynamic>? caps = capabilities;
          if (caps == null) {
            res.statusCode = 404;
          } else {
            res.headers.contentType = ContentType.json;
            res.write(jsonEncode(caps));
          }
        } else if (req.method == 'PUT' && req.uri.path.endsWith('/subtitle')) {
          subtitlePuts++;
          // 老 host 的 importVideoSubtitle：按 client 报的后缀直接覆盖，无备份。
          final String suffix = Uri.decodeComponent(
              req.headers.value('x-hibiki-subtitle-suffix') ?? '');
          final List<int> body = <int>[];
          await req.forEach(body.addAll);
          File(p.join(work.path, 'movie$suffix')).writeAsBytesSync(body);
        } else {
          res.statusCode = 404;
        }
        await res.close();
      });
      base = 'http://127.0.0.1:${fake.port}';
    });

    tearDown(() async {
      await fake.close(force: true);
      if (work.existsSync()) await work.delete(recursive: true);
    });

    for (final (String label, Map<String, dynamic>? caps)
        in <(String, Map<String, dynamic>?)>[
      (
        '能力位缺失',
        <String, dynamic>{
          'liveLibrary': <String, dynamic>{'videos': true},
        },
      ),
      (
        '能力位为 false',
        <String, dynamic>{
          'liveLibrary': <String, dynamic>{
            'videos': true,
            'videoSubtitleDefault': false,
          },
        },
      ),
      ('capabilities 端点 404', null),
    ]) {
      test('$label：不发上传请求，host 原字幕字节不变', () async {
        capabilities = caps;
        final List<int> before = hostJa.readAsBytesSync();
        final InterconnectSyncBackend backend =
            await _clientBackend(base: base, token: 'old-host-token');
        final File sub = File(p.join(work.path, 'picked.srt'))
          ..writeAsStringSync(_srtUploaded);

        for (int i = 0; i < 2; i++) {
          expect(
              await backend.putRemoteVideoSubtitleAsDefault('video/movie', sub,
                  suffix: '.ja.srt'),
              RemoteSubtitleDefaultUpload.hostUnsupported);
        }

        expect(subtitlePuts, 0, reason: '老 host 会按 .ja.srt 覆盖旧字幕，一个 PUT 都不能发');
        expect(hostJa.readAsBytesSync(), before);
        expect(capabilityProbes, 1, reason: '同一 host 基址的能力位只探一次（缓存）');
      });
    }

    test('能力位为 true 时才上传（假 host 的覆盖语义证明门确实在 PUT 之前）', () async {
      capabilities = <String, dynamic>{
        'liveLibrary': <String, dynamic>{'videoSubtitleDefault': true},
      };
      final InterconnectSyncBackend backend =
          await _clientBackend(base: base, token: 'old-host-token');
      final File sub = File(p.join(work.path, 'picked.srt'))
        ..writeAsStringSync(_srtUploaded);
      // 假 host 回 200 但没有 x-hibiki-subtitle-suffix：不能报「已设为默认」。
      expect(
          await backend.putRemoteVideoSubtitleAsDefault('video/movie', sub,
              suffix: '.ja.srt'),
          RemoteSubtitleDefaultUpload.hostUnsupported);
      expect(subtitlePuts, 1);
    });
  });

  group('视频页接线（源码守卫）', () {
    final String part =
        File('lib/src/pages/implementations/video_fushi/subtitle.part.dart')
            .readAsStringSync();
    final String page =
        File('lib/src/pages/implementations/video_fushi_page.dart')
            .readAsStringSync();

    String body(String source, String signature) {
      final int start = source.indexOf(signature);
      expect(start, isNonNegative, reason: '找不到 $signature');
      final int end = source.indexOf('\n  }\n', start);
      return source.substring(start, end);
    }

    test('远端导入字幕在应用成功后上传 host', () {
      expect(body(part, 'Future<void> _pickAndImportRemoteSubtitle('),
          contains('_uploadRemoteSubtitleToHost('));
      final String upload =
          body(part, 'Future<void> _uploadRemoteSubtitleToHost(');
      // BUG-2728：必须走带能力位门的 AsDefault 入口，不能直接调 live push 的
      // putRemoteVideoSubtitle（老 host 上会覆盖同名旧字幕）。
      expect(upload, contains('putRemoteVideoSubtitleAsDefault('));
      expect(upload, isNot(contains('putRemoteVideoSubtitle(')));
      // 「已设为默认」只在 host 确认新语义生效时提示；不支持时如实说只留本机。
      final int applied = upload.indexOf('RemoteSubtitleDefaultUpload.applied');
      final int unsupported =
          upload.indexOf('RemoteSubtitleDefaultUpload.hostUnsupported');
      expect(applied, isNonNegative);
      expect(unsupported, greaterThan(applied));
      expect(upload.substring(applied, unsupported),
          contains('video_subtitle_host_upload_done'));
      expect(upload.substring(unsupported),
          contains('video_subtitle_host_upload_unsupported'));
    });

    test('开关关掉时不上传：进场门在任何上传调用之前', () {
      final String upload =
          body(part, 'Future<void> _uploadRemoteSubtitleToHost(');
      const String gate =
          'if (!appModel.videoSubtitleAutoUploadToHost) return;';
      final int gateAt = upload.indexOf(gate);
      expect(gateAt, isNonNegative, reason: '「导入的字幕自动上传到服务端」关掉时必须直接返回');
      expect(gateAt, lessThan(upload.indexOf('_remoteHostVideoTarget()')));
      expect(
          gateAt, lessThan(upload.indexOf('putRemoteVideoSubtitleAsDefault(')));
      // 门之前不许有任何提示：关掉时既不上传也不提示「已设为默认」。
      expect(upload.substring(0, gateAt), isNot(contains('_showOsd(')));
      // 页面里只有这一处调上传入口，导入与重定时两条路径都经过同一道门。
      final String pageSources = Directory('lib/src/pages/implementations')
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => f.path.endsWith('.dart'))
          .map((File f) => f.readAsStringSync())
          .join('\n');
      expect(
          RegExp(r'\.putRemoteVideoSubtitleAsDefault\(')
              .allMatches(pageSources)
              .length,
          1);
    });

    test('对轴 / 重定时入口不再只认本地视频文件', () {
      expect(part, isNot(contains('!_isRemote && _currentVideoPath != null')));
      for (final String fn in <String>[
        'Future<int?> _autoAlignSubtitle(',
        'Future<List<double>> _loadSubtitleWaveformEnvelope(',
        'Future<void> _retimeSubtitleWithSpeechModel(',
      ]) {
        expect(body(part, fn), contains('_resolveSubtitleTimingAudio()'),
            reason: '$fn 要经统一音源解析，远端才拿得到 host 裁的整集音轨');
      }
      expect(RegExp('_canResolveSubtitleTimingAudio').allMatches(page).length,
          greaterThanOrEqualTo(2),
          reason: '快速设置面板的自动对轴与波形入口都要用新判据');
    });
  });
}
