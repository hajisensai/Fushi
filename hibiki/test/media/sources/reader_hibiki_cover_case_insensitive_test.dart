import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/media.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// TODO-1319 / BUG-612: a book cover is detected at import (coverPath persisted)
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

  group('resolveCaseInsensitive 纯函数逐段大小写不敏感解析 (BUG-612)', () {
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

  group('书架封面 case-insensitive 兜底真实解析链 (BUG-612 端到端)', () {
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
      final FushiDatabase db =
          FushiDatabase.forTesting(NativeDatabase.memory());
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
          reason: '封面在盘上存在，只是 coverPath 大小写不符——不得塌成 null(BUG-612)');
      final String resolvedPath = Uri.parse(item.imageUrl!).toFilePath();
      // 跨平台不变量：imageUrl 必须指向磁盘上真实存在的封面文件。
      // case-sensitive 平台(Linux CI)修复前直接探测按大小写落空 -> imageUrl==null
      // -> 此断言红(回归守卫)；修复后 case-insensitive 兜底命中真实文件 -> 绿。
      // case-insensitive 平台(Windows/macOS)直接探测即命中，恒绿。
      expect(File(resolvedPath).existsSync(), isTrue,
          reason: '解析出的 imageUrl 必须指向磁盘上真实存在的封面文件(BUG-612)');
    });
  });

  // TODO-1388 / BUG-703: 制卡(mining)路径过去只有裸
  // `File(p.join(extractDir, coverHref)).existsSync()`，对大小写不敏感。coverHref
  // 在大小写不敏感宿主(Windows/macOS)导入时被 p.canonicalize 小写化，解压文件却保留
  // 真实大小写(TODO-739)；到 Android/Linux(大小写敏感 FS)后裸探测按小写落空 →
  // coverPath=null → 制出的卡无封面(书架却因 case-insensitive 兜底正常显示)。修复:
  // 制卡复用书架同一个 [ReaderHibikiSource.resolveCoverFilePath]，两条路径对封面
  // 文件解析对称。下面既守护解析行为(真机/CI 端到端)，也守护接线(源码扫描)。
  group('resolveCoverFilePath 制卡封面 case-insensitive 解析对称 (TODO-1388/BUG-703)',
      () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('hibiki_mine_cover_');
    });
    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test(
        'coverHref 大小写失配(小写)时解析到磁盘上大小写保留的真实封面文件('
        '制卡路径不得塌成 null)', () {
      // 磁盘上真实大小写保留的封面(模拟 TODO-739 大小写保留解压)。
      final String extractDir = p.join(tempDir.path, 'Book');
      final String realCover =
          p.join(extractDir, 'OEBPS', 'Images', 'Cover.jpg');
      File(realCover)
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[0xFF, 0xD8, 0xFF]);

      // mining 拿到的 coverHref 是被大小写不敏感宿主小写化过的相对路径。
      final String? resolved = ReaderHibikiSource.resolveCoverFilePath(
        extractDir: extractDir,
        coverPath: 'oebps/images/cover.jpg',
      );

      expect(resolved, isNotNull,
          reason: '封面在盘上存在，只是大小写不符——制卡不得解析成 null(TODO-1388/BUG-703)');
      expect(File(resolved!).existsSync(), isTrue,
          reason: '解析出的 coverPath 必须指向磁盘上真实存在的封面文件');
      // 判别 case-insensitive 兜底确实跑过(而非裸 existsSync)：返回的是磁盘真实
      // 大小写(Cover.jpg)，不是请求里的小写(cover.jpg)。裸 existsSync 在大小写不敏感
      // 平台会返回请求的小写路径；这里断言真实大小写，跨平台都能证明兜底生效。
      expect(p.basename(resolved), 'Cover.jpg',
          reason: 'resolveCoverFilePath 必须返回磁盘真实大小写文件名，证明走了 '
              'case-insensitive 逐段解析而非裸大小写敏感探测');
    });

    test('coverHref 为 null 时回落 cover.jpg 约定兜底(与书架对称)', () {
      final String extractDir = p.join(tempDir.path, 'NoDeclaredCover');
      final String conventional = p.join(extractDir, 'cover.jpg');
      File(conventional)
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[0xFF, 0xD8, 0xFF]);

      final String? resolved = ReaderHibikiSource.resolveCoverFilePath(
        extractDir: extractDir,
        coverPath: null,
      );

      expect(resolved, isNotNull,
          reason: '无声明封面但存在约定 cover.jpg 时，制卡应与书架一样命中约定兜底');
      expect(p.basename(resolved!), 'cover.jpg');
    });

    test('全部候选都不存在时返回 null(不虚构封面)', () {
      final String extractDir = p.join(tempDir.path, 'Empty');
      Directory(extractDir).createSync(recursive: true);

      final String? resolved = ReaderHibikiSource.resolveCoverFilePath(
        extractDir: extractDir,
        coverPath: 'oebps/images/cover.jpg',
      );

      expect(resolved, isNull);
    });
  });

  group('模拟大小写敏感 FS: 声明封面按小写探测落空→case-insensitive 兜底命中 (BUG-703)', () {
    // case-preserved 树，模拟大小写敏感设备(Android/Linux)上解压的真实文件。
    // 裸大小写敏感查找'oebps/images/cover.jpg'会按段落空；resolveCaseInsensitive
    // (resolveCoverFilePath 的核心)先精确后不敏感逐段匹配到真实文件。
    final Map<String, List<String>> tree = <String, List<String>>{
      '/dev/Book': <String>['/dev/Book/OEBPS'],
      '/dev/Book/OEBPS': <String>['/dev/Book/OEBPS/Images'],
      '/dev/Book/OEBPS/Images': <String>['/dev/Book/OEBPS/Images/Cover.jpg'],
    };
    List<String> listDir(String d) => tree[d] ?? const <String>[];

    test('小写声明 href 在大小写敏感 FS 上仍解析到真实大小写文件', () {
      final String? r = ReaderHibikiSource.resolveCaseInsensitive(
        extractDir: '/dev/Book',
        relPaths: <String>['oebps/images/cover.jpg'],
        listDir: listDir,
      );
      expect(r, '/dev/Book/OEBPS/Images/Cover.jpg',
          reason: '这正是 resolveCoverFilePath 内部用来给制卡兜底封面的解析核心');
    });
  });

  group('制卡路径接线守卫: mining 复用 resolveCoverFilePath 而非裸 existsSync (BUG-703)',
      () {
    // 源码扫描守卫: 无论平台大小写敏感与否恒定判定——若有人把制卡封面解析改回裸
    // `File(p.join(_extractDir!, coverHref)).existsSync()`(对大小写不敏感、Android
    // 上会丢封面)，此测试立即变红。这是修复本质(制卡与显示对称)的最强可落地守卫。
    test('mining.part.dart 调用 ReaderHibikiSource.resolveCoverFilePath', () {
      final String src =
          File('lib/src/pages/implementations/reader_hibiki/mining.part.dart')
              .readAsStringSync();
      expect(src, contains('ReaderHibikiSource.resolveCoverFilePath('),
          reason: '制卡封面必须复用书架同一个 case-insensitive 兜底解析');
      expect(
          src, isNot(contains('File(p.join(_extractDir!, _book!.coverHref))')),
          reason: '不得回退到裸大小写敏感 existsSync 探测(Android 上会丢封面)');
    });

    test('书架 _resolveCoverUrl 也经 resolveCoverFilePath(两条路径同源)', () {
      final String src = File('lib/src/media/sources/reader_hibiki_source.dart')
          .readAsStringSync();
      expect(src, contains('resolveCoverFilePath('),
          reason: '书架与制卡必须共享同一封面解析，避免两份漂移');
    });
  });
}
