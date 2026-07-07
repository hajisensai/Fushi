import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

/// TODO-1319 / BUG-608: a book cover is detected at import (coverPath persisted)
/// yet never renders on a case-SENSITIVE device (Android/Linux). Root cause:
/// coverPath is a relative href persisted verbatim and read back disk-direct
/// (shelf coverCandidatePaths / mining File(join(extractDir, coverHref))). A
/// book imported or backed up on a case-INSENSITIVE host (Windows/macOS) stored
/// the href AFTER p.canonicalize lower-cased it (epub_parser _itemRelHref),
/// while the extracted files keep their real case (TODO-739). Delivered to a
/// case-sensitive device via backup restore / raw data copy (both persist
/// coverPath verbatim, no re-parse), File(join(extractDir,
/// "oebps/images/cover.jpg")) misses the real "OEBPS/Images/Cover.jpg" -> cover
/// gone. Fix: resolve the declared cover case-insensitively against the real
/// extracted files as a last resort ([ReaderHibikiSource.resolveCaseInsensitive]
/// wired into _resolveCoverUrl).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('resolveCaseInsensitive 纯函数逐段大小写不敏感解析 (BUG-608)', () {
    // Mock case-preserved tree:
    //   /x/Book/OEBPS/Images/Cover.jpg  (+ /x/Book/cover.jpg fallback)
    final Map<String, List<String>> tree = <String, List<String>>{
      '/x/Book': <String>['/x/Book/OEBPS', '/x/Book/cover.jpg'],
      '/x/Book/OEBPS': <String>['/x/Book/OEBPS/Images'],
      '/x/Book/OEBPS/Images': <String>['/x/Book/OEBPS/Images/Cover.jpg'],
    };
    List<String> listDir(String d) => tree[d] ?? const <String>[];

    test('小写声明 href 解析到大小写保留的真实文件', () {
      final String? r = ReaderHibikiSource.resolveCaseInsensitive(
        extractDir: '/x/Book',
        relPaths: <String>['oebps/images/cover.jpg'],
        listDir: listDir,
      );
      expect(r, '/x/Book/OEBPS/Images/Cover.jpg');
    });

    test('声明封面优先于 cover 兜底(首个能解析的候选取胜)', () {
      final String? r = ReaderHibikiSource.resolveCaseInsensitive(
        extractDir: '/x/Book',
        relPaths: <String>['oebps/images/cover.jpg', 'cover.jpg'],
        listDir: listDir,
      );
      expect(r, '/x/Book/OEBPS/Images/Cover.jpg');
    });

    test('声明封面无法解析时回落 cover 兜底', () {
      final String? r = ReaderHibikiSource.resolveCaseInsensitive(
        extractDir: '/x/Book',
        relPaths: <String>['oebps/images/missing.jpg', 'cover.jpg'],
        listDir: listDir,
      );
      expect(r, '/x/Book/cover.jpg');
    });

    test('全部候选都不存在返回 null', () {
      final String? r = ReaderHibikiSource.resolveCaseInsensitive(
        extractDir: '/x/Book',
        relPaths: <String>['nope/none.png'],
        listDir: listDir,
      );
      expect(r, isNull);
    });

    test('绝对路径候选被跳过(仅解析相对 href)', () {
      final String? r = ReaderHibikiSource.resolveCaseInsensitive(
        extractDir: '/x/Book',
        relPaths: <String>['/etc/passwd'],
        listDir: listDir,
      );
      expect(r, isNull);
    });
  });

  group('书架封面 case-insensitive 兜底真实解析链 (BUG-608 端到端)', () {
    late Directory tempDir;

    setUp(() {
      ReaderHibikiSource.debugResetCoverCache();
      tempDir = Directory.systemTemp.createTempSync('hibiki_cover_ci_');
    });
    tearDown(() {
      ReaderHibikiSource.debugResetCoverCache();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test(
        'coverPath 大小写与磁盘不符(小写)时，书架仍解析出磁盘上大小写保留的真实'
        '封面文件(case-sensitive 平台上修复前 imageUrl 会塌成 null)', () async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);

      // 磁盘上真实大小写保留的封面(模拟 TODO-739 大小写保留解压)。
      final String extractDir = p.join(tempDir.path, 'CaseBook');
      final String realCover =
          p.join(extractDir, 'OEBPS', 'Images', 'Cover.jpg');
      File(realCover)
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[0xFF, 0xD8, 0xFF]);

      // DB 里存的是被大小写不敏感宿主(Windows)小写化过的 coverPath。
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'CaseBook',
          title: 'CaseBook',
          epubPath: p.join(tempDir.path, 'CaseBook.epub'),
          extractDir: extractDir,
          coverPath: const Value('oebps/images/cover.jpg'),
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );

      final MediaItem? item =
          await ReaderHibikiSource.instance.mediaItemForBookKey('CaseBook');
      expect(item, isNotNull);
      expect(item!.imageUrl, isNotNull,
          reason: '封面在盘上存在，只是 coverPath 大小写不符——不得塌成 null(BUG-608)');
      final String resolvedPath = Uri.parse(item.imageUrl!).toFilePath();
      // 跨平台不变量：imageUrl 必须指向磁盘上真实存在的封面文件。
      // case-sensitive 平台(Linux CI)修复前直接探测按大小写落空 -> imageUrl==null
      // -> 此断言红(回归守卫)；修复后 case-insensitive 兜底命中真实文件 -> 绿。
      // case-insensitive 平台(Windows/macOS)直接探测即命中，恒绿。
      expect(File(resolvedPath).existsSync(), isTrue,
          reason: '解析出的 imageUrl 必须指向磁盘上真实存在的封面文件(BUG-608)');
    });
  });
}
