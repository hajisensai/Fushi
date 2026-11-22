import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/media/sources/book_cover_file_resolver.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import '../../helpers/source_guard.dart';

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
/// extracted files as a last resort ([ReaderFushiSource.resolveCaseInsensitive]
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
      final String? r = ReaderFushiSource.resolveCaseInsensitive(
        extractDir: '/x/Book',
        relPaths: <String>['oebps/images/cover.jpg'],
        listDir: listDir,
      );
      expect(r, '/x/Book/OEBPS/Images/Cover.jpg');
    });

    test('声明封面优先于 cover 兜底(首个能解析的候选取胜)', () {
      final String? r = ReaderFushiSource.resolveCaseInsensitive(
        extractDir: '/x/Book',
        relPaths: <String>['oebps/images/cover.jpg', 'cover.jpg'],
        listDir: listDir,
      );
      expect(r, '/x/Book/OEBPS/Images/Cover.jpg');
    });

    test('声明封面无法解析时回落 cover 兜底', () {
      final String? r = ReaderFushiSource.resolveCaseInsensitive(
        extractDir: '/x/Book',
        relPaths: <String>['oebps/images/missing.jpg', 'cover.jpg'],
        listDir: listDir,
      );
      expect(r, '/x/Book/cover.jpg');
    });

    test('全部候选都不存在返回 null', () {
      final String? r = ReaderFushiSource.resolveCaseInsensitive(
        extractDir: '/x/Book',
        relPaths: <String>['nope/none.png'],
        listDir: listDir,
      );
      expect(r, isNull);
    });

    test('绝对路径候选被跳过(仅解析相对 href)', () {
      final String? r = ReaderFushiSource.resolveCaseInsensitive(
        extractDir: '/x/Book',
        relPaths: <String>['/etc/passwd'],
        listDir: listDir,
      );
      expect(r, isNull);
    });

    test('一次调用内同一目录只列一次 (novel-9)', () {
      final Map<String, int> calls = <String, int>{};
      List<String> countingListDir(String d) {
        calls[d] = (calls[d] ?? 0) + 1;
        return listDir(d);
      }

      // 书架对无封面书的真实候选：声明封面 + cover.jpg/jpeg/png 三个兜底，
      // 全部落空时每个候选都要从 extractDir 起走。
      final String? r = ReaderFushiSource.resolveCaseInsensitive(
        extractDir: '/x/Book',
        relPaths: <String>[
          'oebps/images/missing.jpg',
          'Cover.jpeg',
          'cover.png',
          'oebps/images/none.png',
        ],
        listDir: countingListDir,
      );
      expect(r, isNull);
      expect(calls, <String, int>{
        '/x/Book': 1,
        '/x/Book/OEBPS/Images': 1,
        '/x/Book/OEBPS': 1,
      });
    });
  });

  group('书架封面 case-insensitive 兜底真实解析链 (BUG-612 端到端)', () {
    late Directory tempDir;

    setUp(() {
      ReaderFushiSource.debugResetCoverCache();
      tempDir = Directory.systemTemp.createTempSync('fushi_cover_ci_');
    });
    tearDown(() {
      ReaderFushiSource.debugResetCoverCache();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('coverPath 大小写与磁盘不符(小写)时，书架仍解析出磁盘上大小写保留的真实'
        '封面文件(case-sensitive 平台上修复前 imageUrl 会塌成 null)', () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      MediaSource.setDatabase(db);

      // 磁盘上真实大小写保留的封面(模拟 TODO-739 大小写保留解压)。
      final String extractDir = p.join(tempDir.path, 'CaseBook');
      final String realCover = p.join(
        extractDir,
        'OEBPS',
        'Images',
        'Cover.jpg',
      );
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

      final MediaItem? item = await ReaderFushiSource.instance
          .mediaItemForBookKey('CaseBook');
      expect(item, isNotNull);
      expect(
        item!.imageUrl,
        isNotNull,
        reason: '封面在盘上存在，只是 coverPath 大小写不符——不得塌成 null(BUG-612)',
      );
      final String resolvedPath = Uri.parse(item.imageUrl!).toFilePath();
      // 跨平台不变量：imageUrl 必须指向磁盘上真实存在的封面文件。
      // case-sensitive 平台(Linux CI)修复前直接探测按大小写落空 -> imageUrl==null
      // -> 此断言红(回归守卫)；修复后 case-insensitive 兜底命中真实文件 -> 绿。
      // case-insensitive 平台(Windows/macOS)直接探测即命中，恒绿。
      expect(
        File(resolvedPath).existsSync(),
        isTrue,
        reason: '解析出的 imageUrl 必须指向磁盘上真实存在的封面文件(BUG-612)',
      );
    });
  });

  // TODO-1388 / BUG-703: 制卡(mining)路径过去只有裸
  // `File(p.join(extractDir, coverHref)).existsSync()`，对大小写不敏感。coverHref
  // 在大小写不敏感宿主(Windows/macOS)导入时被 p.canonicalize 小写化，解压文件却保留
  // 真实大小写(TODO-739)；到 Android/Linux(大小写敏感 FS)后裸探测按小写落空 →
  // coverPath=null → 制出的卡无封面(书架却因 case-insensitive 兜底正常显示)。修复:
  // 制卡复用书架同一个 [ReaderFushiSource.resolveCoverFilePath]，两条路径对封面
  // 文件解析对称。下面既守护解析行为(真机/CI 端到端)，也守护接线(源码扫描)。
  group(
    'resolveCoverFilePath 制卡封面 case-insensitive 解析对称 (TODO-1388/BUG-703)',
    () {
      late Directory tempDir;

      setUp(() {
        tempDir = Directory.systemTemp.createTempSync('fushi_mine_cover_');
      });
      tearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      test('coverHref 大小写失配(小写)时解析到磁盘上大小写保留的真实封面文件('
          '制卡路径不得塌成 null)', () {
        // 磁盘上真实大小写保留的封面(模拟 TODO-739 大小写保留解压)。
        final String extractDir = p.join(tempDir.path, 'Book');
        final String realCover = p.join(
          extractDir,
          'OEBPS',
          'Images',
          'Cover.jpg',
        );
        File(realCover)
          ..createSync(recursive: true)
          ..writeAsBytesSync(<int>[0xFF, 0xD8, 0xFF]);

        // mining 拿到的 coverHref 是被大小写不敏感宿主小写化过的相对路径。
        final String? resolved = ReaderFushiSource.resolveCoverFilePath(
          extractDir: extractDir,
          coverPath: 'oebps/images/cover.jpg',
        );

        expect(
          resolved,
          isNotNull,
          reason: '封面在盘上存在，只是大小写不符——制卡不得解析成 null(TODO-1388/BUG-703)',
        );
        expect(
          File(resolved!).existsSync(),
          isTrue,
          reason: '解析出的 coverPath 必须指向磁盘上真实存在的封面文件',
        );
        // 判别 case-insensitive 兜底确实跑过(而非裸 existsSync)：返回的是磁盘真实
        // 大小写(Cover.jpg)，不是请求里的小写(cover.jpg)。裸 existsSync 在大小写不敏感
        // 平台会返回请求的小写路径；这里断言真实大小写，跨平台都能证明兜底生效。
        expect(
          p.basename(resolved),
          'Cover.jpg',
          reason:
              'resolveCoverFilePath 必须返回磁盘真实大小写文件名，证明走了 '
              'case-insensitive 逐段解析而非裸大小写敏感探测',
        );
      });

      test('阅读器制卡的封面入口 resolveReaderBookCoverFilePath 同样大小写不敏感'
          '(BUG-4913 起制卡经它取封面)', () {
        final String extractDir = p.join(tempDir.path, 'ReaderEntry');
        File(p.join(extractDir, 'OEBPS', 'Images', 'Cover.jpg'))
          ..createSync(recursive: true)
          ..writeAsBytesSync(<int>[0xFF, 0xD8, 0xFF]);

        // 没有配对字幕书封面：落到 EPUB 自己的封面，coverHref 被小写化过。
        final String? resolved = resolveReaderBookCoverFilePath(
          extractDir: extractDir,
          coverHref: 'oebps/images/cover.jpg',
        );

        expect(resolved, isNotNull, reason: '大小写失配不得让制卡封面塌成 null');
        expect(
          p.basename(resolved!),
          'Cover.jpg',
          reason: '必须走 case-insensitive 逐段解析，返回磁盘真实大小写',
        );
      });

      test('coverHref 为 null 时回落 cover.jpg 约定兜底(与书架对称)', () {
        final String extractDir = p.join(tempDir.path, 'NoDeclaredCover');
        final String conventional = p.join(extractDir, 'cover.jpg');
        File(conventional)
          ..createSync(recursive: true)
          ..writeAsBytesSync(<int>[0xFF, 0xD8, 0xFF]);

        final String? resolved = ReaderFushiSource.resolveCoverFilePath(
          extractDir: extractDir,
          coverPath: null,
        );

        expect(
          resolved,
          isNotNull,
          reason: '无声明封面但存在约定 cover.jpg 时，制卡应与书架一样命中约定兜底',
        );
        expect(p.basename(resolved!), 'cover.jpg');
      });

      test('全部候选都不存在时返回 null(不虚构封面)', () {
        final String extractDir = p.join(tempDir.path, 'Empty');
        Directory(extractDir).createSync(recursive: true);

        final String? resolved = ReaderFushiSource.resolveCoverFilePath(
          extractDir: extractDir,
          coverPath: 'oebps/images/cover.jpg',
        );

        expect(resolved, isNull);
      });
    },
  );

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
      final String? r = ReaderFushiSource.resolveCaseInsensitive(
        extractDir: '/dev/Book',
        relPaths: <String>['oebps/images/cover.jpg'],
        listDir: listDir,
      );
      expect(
        r,
        '/dev/Book/OEBPS/Images/Cover.jpg',
        reason: '这正是 resolveCoverFilePath 内部用来给制卡兜底封面的解析核心',
      );
    });
  });

  group(
    '制卡路径接线守卫: mining 复用 resolveCoverFilePath 而非裸 existsSync (BUG-703)',
    () {
      // 源码扫描守卫: 无论平台大小写敏感与否恒定判定——若有人把制卡封面解析改回裸
      // `File(p.join(_extractDir!, coverHref)).existsSync()`(对大小写不敏感、Android
      // 上会丢封面)，此测试立即变红。这是修复本质(制卡与显示对称)的最强可落地守卫。
      // 接线链：mining.part.dart 的 coverPath 取 `_bookCoverFilePath`（BUG-4913：配对
      // 字幕书封面与 EPUB 封面同序合成）→ 页面 getter 调 resolveReaderBookCoverFilePath
      // → 它的 EPUB 腿调 resolveBookCoverFilePath，也就是书架
      // ReaderFushiSource.resolveCoverFilePath 转发到的同一个 case-insensitive 解析。
      // 链上任何一环改回裸探测或另起一份解析，下面对应那条就红。
      test('mining.part.dart 的书封取阅读器共享封面入口，不裸探测', () {
        final String src = File(
          'lib/src/pages/implementations/reader_fushi/mining.part.dart',
        ).readAsStringSync();
        final String? cover = initializerExpression(src, 'coverPath');
        expect(
          cover,
          isNotNull,
          reason: '_prepareMiningContext 必须声明 coverPath',
        );
        expect(
          containsIdentifier(cover!, '_bookCoverFilePath'),
          isTrue,
          reason: '制卡封面必须取阅读器共享的 _bookCoverFilePath（与书架同源解析）',
        );
        expect(
          maskComments(src),
          isNot(contains('File(p.join(_extractDir!')),
          reason: '不得回退到裸大小写敏感 existsSync 探测(Android 上会丢封面)',
        );
      });

      test('_bookCoverFilePath → resolveReaderBookCoverFilePath → '
          'resolveBookCoverFilePath（与书架同一个解析）', () {
        final String getter = methodBody(
          File(
            'lib/src/pages/implementations/reader_fushi_page.dart',
          ).readAsStringSync(),
          'String? get _bookCoverFilePath',
        );
        expect(
          containsIdentifierCall(getter, 'resolveReaderBookCoverFilePath'),
          isTrue,
          reason: '阅读器封面 getter 必须走共享入口 resolveReaderBookCoverFilePath',
        );
        final String resolver = File(
          'lib/src/media/sources/book_cover_file_resolver.dart',
        ).readAsStringSync();
        final String readerEntry = methodBody(
          resolver,
          'String? resolveReaderBookCoverFilePath(',
        );
        expect(
          containsIdentifierCall(readerEntry, 'resolveBookCoverFilePath'),
          isTrue,
          reason: 'EPUB 封面腿必须走书架同一个 case-insensitive 解析',
        );
        final String shelfEntry = methodBody(
          File(
            'lib/src/media/sources/reader_fushi_source.dart',
          ).readAsStringSync(),
          'static String? resolveCoverFilePath(',
        );
        expect(
          containsIdentifierCall(shelfEntry, 'resolveBookCoverFilePath'),
          isTrue,
          reason: '书架入口与制卡入口必须落到同一个解析函数',
        );
      });

      test('书架 _resolveCoverUrl 也经 resolveCoverFilePath(两条路径同源)', () {
        final String src = File(
          'lib/src/media/sources/reader_fushi_source.dart',
        ).readAsStringSync();
        expect(
          src,
          contains('resolveCoverFilePath('),
          reason: '书架与制卡必须共享同一封面解析，避免两份漂移',
        );
      });
    },
  );
}
