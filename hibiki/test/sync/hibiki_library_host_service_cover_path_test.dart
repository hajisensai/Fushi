import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/app_model_library_host_service.dart';
import 'package:fushi/src/sync/hibiki_library_host_service.dart';
import 'package:fushi/src/sync/sync_asset_package_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// [AppModelLibraryHostService.videoCoverPath] / [bookCoverPath] 单行直查行为
/// （BUG-937 封面 O(N²) 根修的服务层）：结果必须与 listVideos()/listBooks()
/// 清单里对应条目的 coverPath 一致，但只做单行 DB 查询 + stat。
AppModelLibraryHostService _makeService({
  required HibikiDatabase db,
  required Directory tmp,
}) {
  final Directory dictRoot = Directory(p.join(tmp.path, 'dicts'))
    ..createSync(recursive: true);
  return AppModelLibraryHostService(
    db: db,
    dictionaryResourceRoot: dictRoot,
    packages: SyncAssetPackageService(db: db),
    refreshDictionaryCache: () async {},
    runExclusive: (Future<void> Function() body) => body(),
    videoSubtitleLangCode: 'ja',
  );
}

void main() {
  late Directory tmp;
  late HibikiDatabase db;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hbk_cover_path_test');
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  group('videoCoverPath', () {
    test('已有封面 → 返回磁盘路径，与 listVideos 一致', () async {
      final File cover = File(p.join(tmp.path, 'c.jpg'))
        ..writeAsBytesSync(<int>[1]);
      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/a',
        title: 'A',
        videoPath: p.join(tmp.path, 'a.mp4'),
        coverPath: Value(cover.path),
      ));
      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      expect(await svc.videoCoverPath('video/a'), cover.path);
      final RemoteVideoInfo listed = (await svc.listVideos())
          .singleWhere((RemoteVideoInfo v) => v.id == 'video/a');
      expect(listed.coverPath, cover.path, reason: '单查与清单必须同源同值');
    });

    test('封面文件不存在 / 未知 id → null', () async {
      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/gone',
        title: 'Gone',
        videoPath: p.join(tmp.path, 'g.mp4'),
        coverPath: Value(p.join(tmp.path, 'missing.jpg')),
      ));
      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      expect(await svc.videoCoverPath('video/gone'), isNull);
      expect(await svc.videoCoverPath('video/unknown'), isNull);
    });
  });

  group('bookCoverPath', () {
    test('按 bookKey 直查；title 兜底；未知 → null', () async {
      final Directory extract = Directory(p.join(tmp.path, 'book'))
        ..createSync(recursive: true);
      File(p.join(extract.path, 'cover.jpg')).writeAsBytesSync(<int>[2]);
      await db.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: 'book-key-1',
        title: 'Book Title',
        epubPath: p.join(extract.path, 'original.epub'),
        extractDir: extract.path,
        chapterCount: 1,
        chaptersJson: '["ch1"]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
      ));
      final AppModelLibraryHostService svc = _makeService(db: db, tmp: tmp);
      final String expected = p.join(extract.path, 'cover.jpg');
      expect(await svc.bookCoverPath('book-key-1'), expected);
      expect(await svc.bookCoverPath('Book Title'), expected,
          reason: '旧 client 用 title 当 downloadId 的兼容路径');
      expect(await svc.bookCoverPath('nope'), isNull);
    });
  });
}
