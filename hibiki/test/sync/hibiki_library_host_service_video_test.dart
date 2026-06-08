import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
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

    test('toJson/fromJson 往返一致', () {
      const RemoteVideoInfo info = RemoteVideoInfo(
        id: 'video/test',
        title: 'Test',
        sizeBytes: 2048,
        hasSubtitle: true,
        durationMs: null,
      );
      final Map<String, Object?> json = info.toJson();
      final RemoteVideoInfo restored = RemoteVideoInfo.fromJson(json);
      expect(restored.id, info.id);
      expect(restored.title, info.title);
      expect(restored.sizeBytes, info.sizeBytes);
      expect(restored.hasSubtitle, info.hasSubtitle);
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
}
