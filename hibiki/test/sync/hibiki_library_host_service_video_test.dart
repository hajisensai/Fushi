import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/ffmpeg_backend.dart';
import 'package:hibiki/src/sync/app_model_library_host_service.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/sync_asset_package_service.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

/// 最小 AppModelLibraryHostService 实例（不需要词典/书籍功能）。
AppModelLibraryHostService _makeService({
  required HibikiDatabase db,
  required Directory tmp,
  String langCode = 'ja',
}) {
  final Directory dictRoot = Directory(p.join(tmp.path, 'dicts'))
    ..createSync(recursive: true);
  return AppModelLibraryHostService(
    db: db,
    dictionaryResourceRoot: dictRoot,
    packages: SyncAssetPackageService(db: db),
    refreshDictionaryCache: () async {},
    runExclusive: (Future<void> Function() body) => body(),
    videoSubtitleLangCode: langCode,
  );
}

void main() {
  late Directory tmp;
  late HibikiDatabase db;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hbk_video_svc_test');
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    setFfmpegBackendForTesting(null);
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  // ── listVideos ────────────────────────────────────────────────────────────────

  group('listVideos', () {
    test('空库返回空列表', () async {
      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      final List<RemoteVideoInfo> list = await svc.listVideos();
      expect(list, isEmpty);
    });

    test('返回已插入的视频条目，字段正确', () async {
      // 建一个真实视频文件（内容任意）供 stat 拿大小
      final File videoFile = File(p.join(tmp.path, 'film.mp4'))
        ..writeAsBytesSync(List<int>.filled(1024, 0));

      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/film',
        title: 'Film Title',
        videoPath: videoFile.path,
      ));

      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      final List<RemoteVideoInfo> list = await svc.listVideos();
      expect(list.length, 1);
      expect(list[0].id, 'video/film');
      expect(list[0].title, 'Film Title');
      expect(list[0].sizeBytes, 1024);
      expect(list[0].hasSubtitle, isFalse); // 无 sidecar
      expect(list[0].durationMs, isNull); // DB 无 duration 列
    });

    test('返回视频条目时标记已有本地封面可供对端展示', () async {
      final File videoFile = File(p.join(tmp.path, 'covered.mp4'))
        ..writeAsBytesSync(<int>[0]);
      final File coverFile = File(p.join(tmp.path, 'covered.png'))
        ..writeAsBytesSync(<int>[1, 2, 3, 4]);

      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/covered',
        title: 'Covered Video',
        videoPath: videoFile.path,
        coverPath: Value<String?>(coverFile.path),
      ));

      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      final List<RemoteVideoInfo> list = await svc.listVideos();

      expect(list.single.toJson()['hasCover'], isTrue);
    });

    test('视频文件不存在时 sizeBytes 为 null', () async {
      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/ghost',
        title: 'Ghost',
        videoPath: p.join(tmp.path, 'nonexistent.mp4'),
      ));

      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      final List<RemoteVideoInfo> list = await svc.listVideos();
      expect(list[0].sizeBytes, isNull);
    });

    test('有 sidecar 字幕时 hasSubtitle = true', () async {
      final String videoPath = p.join(tmp.path, 'show.mkv');
      File(videoPath).writeAsBytesSync(<int>[0]);
      // 创建 ja.srt sidecar
      File(p.join(tmp.path, 'show.ja.srt'))
          .writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nHello\n');

      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/show',
        title: 'Show',
        videoPath: videoPath,
      ));

      final AppModelLibraryHostService svc =
          _makeService(db: db, tmp: tmp, langCode: 'ja');
      final List<RemoteVideoInfo> list = await svc.listVideos();
      expect(list[0].hasSubtitle, isTrue);
    });

    test('sidecar 字幕文件名保留真实扩展名', () async {
      final String videoPath = p.join(tmp.path, 'show.mkv');
      File(videoPath).writeAsBytesSync(<int>[0]);
      File(p.join(tmp.path, 'show.ja.vtt')).writeAsStringSync(
        'WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nHello\n',
      );

      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/show',
        title: 'Show',
        videoPath: videoPath,
      ));

      final AppModelLibraryHostService svc =
          _makeService(db: db, tmp: tmp, langCode: 'ja');
      final List<RemoteVideoInfo> list = await svc.listVideos();

      expect(list.single.hasSubtitle, isTrue);
      expect(list.single.subtitleFileName, 'show.ja.vtt');
      expect(list.single.toJson()['subtitleFileName'], 'show.ja.vtt');
    });

    test(
        'embedded text subtitle tracks are exposed and graphic tracks are marked unsupported',
        () async {
      setFfmpegBackendForTesting(const _EmbeddedSubtitleProbeBackend());
      final String videoPath = p.join(tmp.path, 'embedded.mkv');
      File(videoPath).writeAsBytesSync(<int>[0, 1, 2, 3]);

      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/embedded',
        title: 'Embedded',
        videoPath: videoPath,
      ));

      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      final List<RemoteVideoInfo> list = await svc.listVideos();

      expect(list.single.hasSubtitle, isTrue);
      expect(list.single.subtitleFileName, isNull);
      expect(list.single.embeddedSubtitleTracks, hasLength(3));
      expect(
        list.single.embeddedSubtitleTracks
            .map((RemoteVideoEmbeddedSubtitleTrack track) => track.codec),
        <String>['subrip', 'mov_text', 'hdmv_pgs_subtitle'],
      );
      expect(list.single.embeddedSubtitleTracks[0].isText, isTrue);
      expect(list.single.embeddedSubtitleTracks[1].isText, isTrue);
      expect(list.single.embeddedSubtitleTracks[2].isText, isFalse);

      final RemoteVideoInfo restored =
          RemoteVideoInfo.fromJson(list.single.toJson());
      expect(restored.embeddedSubtitleTracks[1].language, 'eng');
      expect(restored.embeddedSubtitleTracks[2].isText, isFalse);
    });

    test('toJson/fromJson 往返一致', () {
      const RemoteVideoInfo info = RemoteVideoInfo(
        id: 'video/test',
        title: 'Test',
        sizeBytes: 2048,
        hasSubtitle: true,
        subtitleFileName: 'test.ja.ass',
        embeddedSubtitleTracks: <RemoteVideoEmbeddedSubtitleTrack>[
          RemoteVideoEmbeddedSubtitleTrack(
            streamIndex: 0,
            codec: 'ass',
            language: 'jpn',
            isText: true,
          ),
        ],
        durationMs: null,
      );
      final Map<String, Object?> json = info.toJson();
      final RemoteVideoInfo restored = RemoteVideoInfo.fromJson(json);
      expect(restored.id, info.id);
      expect(restored.title, info.title);
      expect(restored.sizeBytes, info.sizeBytes);
      expect(restored.hasSubtitle, info.hasSubtitle);
      expect(restored.subtitleFileName, info.subtitleFileName);
      expect(restored.embeddedSubtitleTracks, hasLength(1));
      expect(restored.embeddedSubtitleTracks.single.codec, 'ass');
      expect(restored.durationMs, info.durationMs);
    });

    test('toJson 中 durationMs=null 不出现在 JSON', () {
      const RemoteVideoInfo info = RemoteVideoInfo(
        id: 'video/x',
        title: 'X',
      );
      final Map<String, Object?> json = info.toJson();
      expect(json.containsKey('durationMs'), isFalse);
    });
  });

  // ── resolveVideoFile ──────────────────────────────────────────────────────────

  group('resolveVideoFile', () {
    test('已知 id + 文件存在 → 返回 File', () async {
      final File videoFile = File(p.join(tmp.path, 'clip.mp4'))
        ..writeAsBytesSync(<int>[1, 2, 3]);
      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/clip',
        title: 'Clip',
        videoPath: videoFile.path,
      ));

      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      final File? f = await svc.resolveVideoFile('video/clip');
      expect(f, isNotNull);
      expect(f!.path, videoFile.path);
    });

    test('未知 id → null', () async {
      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      final File? f = await svc.resolveVideoFile('video/does_not_exist');
      expect(f, isNull);
    });

    test('已知 id 但文件不存在 → null', () async {
      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/vanished',
        title: 'Vanished',
        videoPath: p.join(tmp.path, 'vanished.mp4'), // 不创建文件
      ));

      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      final File? f = await svc.resolveVideoFile('video/vanished');
      expect(f, isNull);
    });

    test('外部路径不能直接 resolve（必须先入库）', () async {
      // 文件确实存在，但 id 不在 DB → null（防路径穿越关键用例）
      final File sneaky = File(p.join(tmp.path, 'secret.mp4'))
        ..writeAsBytesSync(<int>[0xff]);

      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      // 传的是文件路径而非 bookUid，DB 中查不到 → null
      final File? f = await svc.resolveVideoFile(sneaky.path);
      expect(f, isNull);
    });
  });

  // ── resolveVideoSubtitle ──────────────────────────────────────────────────────

  group('resolveVideoSubtitle', () {
    test('有 sidecar → 返回字幕 File', () async {
      final String videoPath = p.join(tmp.path, 'ep01.mkv');
      File(videoPath).writeAsBytesSync(<int>[0]);
      final File subFile = File(p.join(tmp.path, 'ep01.ja.srt'))
        ..writeAsStringSync('sub');

      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/ep01',
        title: 'Ep01',
        videoPath: videoPath,
      ));

      final AppModelLibraryHostService svc =
          _makeService(db: db, tmp: tmp, langCode: 'ja');
      final File? f =
          await svc.resolveVideoSubtitle('video/ep01', langCode: 'ja');
      expect(f, isNotNull);
      expect(f!.path, subFile.path);
    });

    test('无 sidecar → null', () async {
      final String videoPath = p.join(tmp.path, 'nosub.mkv');
      File(videoPath).writeAsBytesSync(<int>[0]);

      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/nosub',
        title: 'NoSub',
        videoPath: videoPath,
      ));

      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      final File? f = await svc.resolveVideoSubtitle('video/nosub');
      expect(f, isNull);
    });

    test('未知 id → null', () async {
      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      final File? f = await svc.resolveVideoSubtitle('video/unknown');
      expect(f, isNull);
    });
  });

  // ── getVideoPosition 向后兼容（TODO-816 断点②）─────────────────────────────────
  group('getVideoPosition host-local backward compat', () {
    test('falls back to VideoBooks.lastPositionMs when no prefs', () async {
      // host 本机播放只写 lastPositionMs（旧数据，无 video_remote_position prefs）。
      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/local',
        title: 'Local',
        videoPath: '/tmp/local.mp4',
        lastPositionMs: const Value(360000),
      ));
      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);

      final ({int positionMs, int updatedAtMs}) progress =
          await svc.getVideoPosition('video/local');
      expect(progress.positionMs, 360000,
          reason:
              'host self-play progress must be readable via getVideoPosition');
      // 旧数据无时间戳：返回 0，任何带时间戳的远端进度都能盖过它。
      expect(progress.updatedAtMs, 0);
    });

    test('prefs progress wins over lastPositionMs', () async {
      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/both',
        title: 'Both',
        videoPath: '/tmp/both.mp4',
        lastPositionMs: const Value(100000),
      ));
      await db.setPrefTyped<int>(
          videoRemotePositionPrefKey('video/both'), 800000);
      await db.setPrefTyped<int>(
          videoRemotePositionAtPrefKey('video/both'), 7000);
      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);

      final ({int positionMs, int updatedAtMs}) progress =
          await svc.getVideoPosition('video/both');
      expect(progress.positionMs, 800000);
      expect(progress.updatedAtMs, 7000);
    });

    test('unknown id returns zero', () async {
      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      final ({int positionMs, int updatedAtMs}) progress =
          await svc.getVideoPosition('video/missing');
      expect(progress.positionMs, 0);
      expect(progress.updatedAtMs, 0);
    });
  });
}

class _EmbeddedSubtitleProbeBackend implements FfmpegBackend {
  const _EmbeddedSubtitleProbeBackend();

  @override
  Future<FfmpegRunResult> run(List<String> args, Duration timeout) async {
    if (args.contains('-hide_banner')) {
      return const FfmpegRunResult(returnCode: 1, output: '''
  Stream #0:0: Video: h264
  Stream #0:1(jpn): Subtitle: subrip (srt) (default)
  Stream #0:2(eng): Subtitle: mov_text (tx3g)
  Stream #0:3(jpn): Subtitle: hdmv_pgs_subtitle
''');
    }
    return const FfmpegRunResult(returnCode: 0, output: '');
  }
}
