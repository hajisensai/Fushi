import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/epub/epub_image_index_cache.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';

/// BUG-3433：插图表算一次落盘，之后按章节文件指纹（大小 + 修改时间）读回，不再整书
/// 解析 XHTML；章节文件换掉就重算，缓存坏了退回现算，无盘上文件的书不缓存。
void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('epub-image-index-'));
  tearDown(() => dir.deleteSync(recursive: true));

  File chapterFile(int i) => File('${dir.path}/ch$i.xhtml');

  // 书的解压目录是 dir/book；缓存目录与它分开（生产在 support 根下）。
  String bookDir() => '${dir.path}/book';

  File cacheFileFor() =>
      epubImageIndexCacheFile(Directory('${dir.path}/cache'), bookDir());

  test('the cache lives outside the book directory, one file per book', () {
    final File a = cacheFileFor();
    expect(
      a.path.startsWith(bookDir()),
      isFalse,
      reason: 'the extract dir is repackaged into .epub for sync peers',
    );
    expect(
      epubImageIndexCacheFile(
        Directory('${dir.path}/cache'),
        '${dir.path}/other',
      ).path,
      isNot(a.path),
    );
  });

  void writeChapter(int i, String body) =>
      chapterFile(i).writeAsStringSync('<html><body>$body</body></html>');

  EpubBook lazyBook(int chapters) => EpubBook(
    title: 'T',
    chapters: <EpubChapter>[
      for (int i = 0; i < chapters; i++)
        EpubChapter.lazy(
          id: 'c$i',
          href: 'ch$i.xhtml',
          mediaType: 'application/xhtml+xml',
          filePath: chapterFile(i).path,
        ),
    ],
  );

  List<String> srcs(List<EpubImageRef> refs) =>
      refs.map((EpubImageRef r) => r.src).toList();

  /// 正常路径：缓存读写不该有任何失败。
  List<EpubImageRef> loadImages(EpubBook book, File cache) {
    final EpubImageIndexLoad load = loadEpubImagesWithCache(book, cache);
    expect(
      load.failures.map((EpubImageIndexCacheFailure f) => f.error),
      isEmpty,
    );
    return load.images;
  }

  test('first load scans and writes the cache; the next book reads it back '
      'without parsing', () {
    writeChapter(0, '<img src="a.png"/><p>文字</p><img src="b.png"/>');
    writeChapter(1, '<p>本文</p><img src="c.png"/>');
    final File cache = cacheFileFor();

    final List<EpubImageRef> first = loadImages(lazyBook(2), cache);
    expect(srcs(first), <String>['a.png', 'b.png', 'c.png']);
    expect(cache.existsSync(), isTrue);

    // 换成同字节数、同修改时间的内容：指纹不变，能读出旧图名就说明没有重新解析。
    final DateTime mtime = chapterFile(0).lastModifiedSync();
    writeChapter(0, '<img src="x.png"/><p>文字</p><img src="y.png"/>');
    chapterFile(0).setLastModifiedSync(mtime);

    final EpubBook reopened = lazyBook(2);
    final List<EpubImageRef> second = loadImages(reopened, cache);
    expect(srcs(second), <String>['a.png', 'b.png', 'c.png']);
    expect(reopened.hasImages, isTrue, reason: 'adopted into the instance');
    for (int i = 0; i < first.length; i++) {
      expect(second[i].chapterIndex, first[i].chapterIndex);
      expect(second[i].orderInBook, first[i].orderInBook);
      expect(second[i].revealKey, first[i].revealKey);
      expect(second[i].normCharOffset, first[i].normCharOffset);
      expect(second[i].charOffset, first[i].charOffset);
      expect(second[i].sharesLineWithText, first[i].sharesLineWithText);
    }
  });

  test('a replaced chapter file invalidates the cache', () {
    writeChapter(0, '<img src="a.png"/>');
    final File cache = cacheFileFor();
    expect(srcs(loadImages(lazyBook(1), cache)), <String>['a.png']);

    // 在线小说占位页 → 正文：文件内容与大小都变了。
    writeChapter(0, '<p>正文已经到了</p><img src="real.png"/>');
    expect(srcs(loadImages(lazyBook(1), cache)), <String>['real.png']);
  });

  test('a corrupt cache falls back to scanning and is rewritten', () {
    writeChapter(0, '<img src="a.png"/>');
    final File cache = cacheFileFor();
    cache.parent.createSync(recursive: true);
    cache.writeAsStringSync('{not json');
    final EpubImageIndexLoad load = loadEpubImagesWithCache(lazyBook(1), cache);
    expect(srcs(load.images), <String>['a.png']);
    expect(cache.readAsStringSync(), contains('a.png'));
    // 损坏不是静默的：原因随结果带回，供根 isolate 记日志。
    expect(
      load.failures.map((EpubImageIndexCacheFailure f) => f.stage),
      <String>['read'],
    );
    expect(load.failures.single.error, contains(cache.path));
  });

  test('a write that cannot land is reported, never fatal, and leaves no '
      'temp file behind', () {
    writeChapter(0, '<img src="a.png"/>');
    final File cache = cacheFileFor();
    // 目标路径被一个目录占着：rename 必失败。
    Directory(cache.path).createSync(recursive: true);
    final EpubImageIndexLoad load = loadEpubImagesWithCache(lazyBook(1), cache);
    expect(srcs(load.images), <String>['a.png']);
    expect(
      load.failures.map((EpubImageIndexCacheFailure f) => f.stage),
      <String>['write'],
    );
    expect(
      cache.parent.listSync().whereType<File>().where(
        (File f) => f.path.endsWith('.tmp'),
      ),
      isEmpty,
    );
  });

  test('isolates writing the same book cache concurrently do not clobber '
      'each other', () async {
    for (int i = 0; i < 6; i++) {
      writeChapter(i, '<p>第$i章</p><img src="i$i.png"/><p>本文</p>');
    }
    final File cache = cacheFileFor();
    final String cachePath = cache.path;
    final List<String> chapterPaths = <String>[
      for (int i = 0; i < 6; i++) chapterFile(i).path,
    ];
    // 每个 isolate 各自从零构造书、各自写同一份缓存（插图册 / 歌词模式 / 书架插图库
    // / 兄弟卷预览同时打开同一本书的形态）。
    final List<List<String>> results = await Future.wait(<Future<List<String>>>[
      for (int n = 0; n < 8; n++)
        Isolate.run(() {
          final EpubBook book = EpubBook(
            title: 'T',
            chapters: <EpubChapter>[
              for (int i = 0; i < chapterPaths.length; i++)
                EpubChapter.lazy(
                  id: 'c$i',
                  href: 'ch$i.xhtml',
                  mediaType: 'application/xhtml+xml',
                  filePath: chapterPaths[i],
                ),
            ],
          );
          final EpubImageIndexLoad load = loadEpubImagesWithCache(
            book,
            File(cachePath),
          );
          return <String>[
            ...load.images.map((EpubImageRef r) => r.src),
            // 只有 Windows 上「目标正被另一 isolate 读」时 rename 可能被拒，那只是
            // 这一次没写进去；共用 .tmp 时的截断 / 互删在任何平台都会出现。
            for (final EpubImageIndexCacheFailure f in load.failures)
              if (f.stage != 'write' || !Platform.isWindows) 'FAIL ${f.error}',
          ];
        }),
    ]);
    final List<String> expected = <String>[
      for (int i = 0; i < 6; i++) 'i$i.png',
    ];
    for (final List<String> r in results) {
      expect(r, expected);
    }
    expect(
      cache.parent.listSync().whereType<File>().where(
        (File f) => f.path.endsWith('.tmp'),
      ),
      isEmpty,
      reason: 'every writer used its own temp file and cleaned it up',
    );
    // 留下来的缓存完整可读。
    expect(srcs(loadImages(lazyBook(6), cache)), expected);
  });

  group('production cache location', () {
    late EnginePaths previous;

    setUp(() => previous = enginePaths);
    tearDown(() => enginePaths = previous);

    test('no cache file without installed engine paths', () async {
      enginePaths = const UninstalledEnginePaths();
      expect(await epubImageIndexCacheFileFor(bookDir()), isNull);
    });

    test('deleting a book also deletes its illustration-index cache', () async {
      final Directory support = Directory('${dir.path}/support')..createSync();
      enginePaths = FixedEnginePaths(
        documents: Directory('${dir.path}/docs'),
        support: support,
        temp: Directory('${dir.path}/tmp'),
      );
      Directory(bookDir()).createSync(recursive: true);
      writeChapter(0, '<img src="a.png"/>');
      final File? cache = await epubImageIndexCacheFileFor(bookDir());
      expect(cache, isNotNull);
      expect(cache!.path, startsWith(support.path));
      loadImages(lazyBook(1), cache);
      expect(cache.existsSync(), isTrue);

      await EpubStorage.deleteBookDir(bookDir());

      expect(Directory(bookDir()).existsSync(), isFalse);
      expect(cache.existsSync(), isFalse, reason: 'orphaned cache file');
    });
  });

  test('a book without on-disk chapters is never cached', () {
    final EpubBook eager = EpubBook(
      title: 'T',
      chapters: <EpubChapter>[
        EpubChapter(
          id: 'c0',
          href: 'ch0.xhtml',
          mediaType: 'application/xhtml+xml',
          html: '<html><body><img src="a.png"/></body></html>',
        ),
      ],
    );
    expect(epubImageIndexFingerprint(eager), isNull);
    final File cache = cacheFileFor();
    expect(srcs(loadImages(eager, cache)), <String>['a.png']);
    expect(cache.existsSync(), isFalse);
  });

  test('the fingerprint carries the scan version', () {
    writeChapter(0, '<img src="a.png"/>');
    expect(
      epubImageIndexFingerprint(lazyBook(1)),
      startsWith('v$kEpubImageIndexCacheVersion|'),
    );
  });
}
