/// 远端视频「导入 / 重定时的字幕自动上传 host 并设为默认」+「远端视频也能对轴 /
/// 重定时」守卫。
///
/// 1. 纯函数：[defaultSidecarSubtitleSuffix] / [sidecarSuffixesDisplacedBy] /
///    [clipVideoAudioTimeout]。
/// 2. host [LocalLibraryHostService.importDefaultVideoSubtitle]：按 host 学习语言定
///    后缀、压过它的旧 sidecar 改名 `.fushi-bak` 让位（原始文件只备份一次）、落库。
/// 3. 端到端（真实 server/host/client）：client 带 `asDefault` 上传后 host 首选字幕
///    就是它；不带时仍按 client 报的后缀落盘（live push 旧语义不变）。
/// 4. 源码守卫：视频页远端导入会上传、对轴 / 重定时入口不再只认本地文件。
library;

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

    test('asDefault：host 按自己的学习语言定后缀并成为首选字幕', () async {
      final File oldJa = File(p.join(vidDir.path, 'movie.ja.srt'))
        ..writeAsStringSync(_srtOriginal);
      final InterconnectSyncBackend backend =
          await _clientBackend(base: base, token: token);
      final File sub = File(p.join(work.path, 'picked.srt'))
        ..writeAsStringSync(_srtUploaded);

      // client 的学习语言（en）与 host（ja）不同：后缀以 host 为准。
      expect(
          await backend.putRemoteVideoSubtitle('video/movie', sub,
              suffix: '.en.srt', asDefault: true),
          isTrue);

      expect(oldJa.readAsStringSync(), _srtUploaded);
      expect(File(p.join(vidDir.path, 'movie.en.srt')).existsSync(), isFalse);
      expect(File('${oldJa.path}$kDisplacedSidecarBackupSuffix').existsSync(),
          isTrue);
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
      expect(body(part, 'Future<void> _uploadRemoteSubtitleToHost('),
          contains('asDefault: true'));
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
