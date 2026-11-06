import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/manga/manga_chapter_storage.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/manga_sync_package.dart';
import 'package:fushi_engine/sync/online_manga_host_reader.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// 互联漫画源的 host 实现层：真 DB + 真磁盘。
///
/// 端点那一层（路由/鉴权/404）在 `fushi_sync_server_manga_library_test.dart`；这里
/// 钉的是**页表怎么从 manga.json 推出来**、以及**页图路径解析这道穿越守卫**。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late Directory tmp;
  late LocalLibraryHostService svc;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    tmp = Directory.systemTemp.createTempSync('hbk_host_manga');
    svc = LocalLibraryHostService(
      db: db,
      dictionaryResourceRoot: Directory.systemTemp,
      packages: SyncAssetPackageService(db: db),
      refreshDictionaryCache: () async {},
      runExclusive: (Future<void> Function() body) => body(),
    );
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 一本真漫画：`<dir>/manga.json` + `<dir>/images/**`，与导入器落盘布局一致。
  Future<String> insertManga({
    required String bookKey,
    List<String> pageUrls = const <String>['images/p1.jpg', 'images/p2.jpg'],
    bool writeImages = true,
    String? readingMode,
  }) async {
    final Directory dir = Directory(p.join(tmp.path, bookKey))
      ..createSync(recursive: true);
    final List<Map<String, Object?>> pages = <Map<String, Object?>>[];
    for (int i = 0; i < pageUrls.length; i++) {
      if (writeImages) {
        final File image = File(
          p.joinAll(<String>[dir.path, ...pageUrls[i].split('/')]),
        );
        image.parent.createSync(recursive: true);
        image.writeAsBytesSync(<int>[0xFF, 0xD8, 0xFF, i]);
      }
      pages.add(<String, Object?>{
        'url': pageUrls[i],
        'width': 800,
        'height': 1200,
        'blocks': <Object?>[],
      });
    }
    File(
      p.join(dir.path, kMangaPackageMarker),
    ).writeAsStringSync(jsonEncode(<String, Object?>{'pages': pages}));
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: bookKey,
        epubPath: kMangaPackageMarker,
        extractDir: dir.path,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
        format: Value(BookFormat.manga.dbValue),
        mangaReadingMode: Value(readingMode),
      ),
    );
    return dir.path;
  }

  test('页表按 manga.json 顺序给出页序、尺寸与阅读模式', () async {
    await insertManga(bookKey: 'vol1', readingMode: 'webtoon');
    final RemoteMangaManifest manifest = await svc.mangaManifest('vol1');
    expect(manifest.bookKey, 'vol1');
    expect(manifest.readingMode, 'webtoon');
    expect(manifest.pages.map((RemoteMangaPageInfo e) => e.index), <int>[0, 1]);
    // `images/` 前缀被剥掉：name 是相对 images 根的路径，与阅读器读本地时同一口径。
    expect(manifest.pages.map((RemoteMangaPageInfo e) => e.name), <String>[
      'p1.jpg',
      'p2.jpg',
    ]);
    expect(manifest.pages.first.width, 800);
    expect(manifest.pages.first.height, 1200);
  });

  test('页图按 index 解析到真实文件，字节与页序对应', () async {
    await insertManga(bookKey: 'vol1');
    expect((await svc.mangaPageFile('vol1', 0)).readAsBytesSync(), <int>[
      0xFF,
      0xD8,
      0xFF,
      0,
    ]);
    expect((await svc.mangaPageFile('vol1', 1)).readAsBytesSync(), <int>[
      0xFF,
      0xD8,
      0xFF,
      1,
    ]);
  });

  test('子目录结构保留：同名不同目录的两页不塌成一页', () async {
    await insertManga(
      bookKey: 'vol1',
      pageUrls: const <String>['images/a/p1.jpg', 'images/b/p1.jpg'],
    );
    final RemoteMangaManifest manifest = await svc.mangaManifest('vol1');
    expect(manifest.pages.map((RemoteMangaPageInfo e) => e.name), <String>[
      'a/p1.jpg',
      'b/p1.jpg',
    ]);
    final File first = await svc.mangaPageFile('vol1', 0);
    final File second = await svc.mangaPageFile('vol1', 1);
    expect(first.path, isNot(second.path));
  });

  test('页图路径逃出 images/ 一律 StateError（→ 端点 404），绝不 serve', () async {
    await insertManga(
      bookKey: 'vol1',
      pageUrls: const <String>['../../secret.txt'],
      writeImages: false,
    );
    File(p.join(tmp.path, 'secret.txt')).writeAsStringSync('nope');
    await expectLater(svc.mangaPageFile('vol1', 0), throwsA(isA<StateError>()));
  });

  test('越界页 StateError', () async {
    await insertManga(bookKey: 'vol1');
    await expectLater(svc.mangaPageFile('vol1', 5), throwsA(isA<StateError>()));
    await expectLater(
      svc.mangaPageFile('vol1', -1),
      throwsA(isA<StateError>()),
    );
  });

  test('非漫画的书不给页表（EPUB 行不该经漫画通道泄出内容）', () async {
    final Directory dir = Directory(p.join(tmp.path, 'novel'))
      ..createSync(recursive: true);
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'novel',
        title: 'novel',
        epubPath: 'original.epub',
        extractDir: dir.path,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await expectLater(svc.mangaManifest('novel'), throwsA(isA<StateError>()));
  });

  test('占位空合集不给页表——与清单的 hasMangaContent 判据同源（BUG-2400）', () async {
    await insertManga(
      bookKey: 'empty',
      pageUrls: const <String>[],
      writeImages: false,
    );
    await expectLater(svc.mangaManifest('empty'), throwsA(isA<StateError>()));
    // 清单侧对同一本的结论必须一致，否则就是「列表说有、点开说没有」。
    final RemoteBookInfo row = (await svc.listBooks()).firstWhere(
      (RemoteBookInfo b) => b.bookKey == 'empty',
    );
    expect(row.hasMangaContent, isFalse);
  });

  test('缺页图的书不给页表（清单也不会声称有内容）', () async {
    await insertManga(bookKey: 'missing', writeImages: false);
    await expectLater(svc.mangaManifest('missing'), throwsA(isA<StateError>()));
    final RemoteBookInfo row = (await svc.listBooks()).firstWhere(
      (RemoteBookInfo b) => b.bookKey == 'missing',
    );
    expect(row.hasMangaContent, isFalse);
  });

  test('穿越形状的 bookKey 一律 ArgumentError', () async {
    await expectLater(
      svc.mangaManifest('../etc/passwd'),
      throwsA(isA<ArgumentError>()),
    );
    await expectLater(
      svc.mangaPageFile('../etc/passwd', 0),
      throwsA(isA<ArgumentError>()),
    );
  });

  /// 一条在线书架条目（Mihon / Aidoku 加入书架的形状）：根 `manga.json` 是占位
  /// `{"pages":[]}`，章表在 `chaptersJson`，已下载的章在 `chapters/<digest>/`。
  Future<String> insertOnlineManga({
    required String bookKey,
    required List<String> chapterKeys,
    required Set<String> downloaded,
    Set<String> halfDownloaded = const <String>{},
  }) async {
    final Directory dir = Directory(p.join(tmp.path, bookKey))
      ..createSync(recursive: true);
    File(
      p.join(dir.path, kMangaPackageMarker),
    ).writeAsStringSync('{"pages":[]}');
    for (final String key in chapterKeys) {
      if (!downloaded.contains(key) && !halfDownloaded.contains(key)) continue;
      final Directory chapterDir = mangaChapterDirectory(dir.path, key)
        ..createSync(recursive: true);
      final List<Map<String, Object?>> pages = <Map<String, Object?>>[];
      for (int i = 0; i < 2; i++) {
        final String url = 'images/page-00000${i + 1}.jpg';
        if (downloaded.contains(key)) {
          final File image = File(
            p.join(chapterDir.path, 'images', 'page-00000${i + 1}.jpg'),
          )..parent.createSync(recursive: true);
          image.writeAsBytesSync(<int>[0xFF, 0xD8, key.length, i]);
        }
        pages.add(<String, Object?>{
          'url': url,
          'width': 700,
          'height': 1000,
          'blocks': <Object?>[],
        });
      }
      mangaChapterJsonFile(
        chapterDir,
      ).writeAsStringSync(jsonEncode(<String, Object?>{'pages': pages}));
    }
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: bookKey,
        epubPath: kMangaPackageMarker,
        extractDir: dir.path,
        chapterCount: chapterKeys.length,
        chaptersJson: jsonEncode(<Map<String, Object?>>[
          for (int i = 0; i < chapterKeys.length; i++)
            <String, Object?>{
              'key': chapterKeys[i],
              'name': 'Chapter ${i + 1}',
              'number': i + 1,
              'scanlator': i == 0 ? 'group' : null,
              'raw': <String, Object?>{'url': chapterKeys[i]},
            },
        ]),
        importedAt: DateTime.now().millisecondsSinceEpoch,
        format: Value(BookFormat.manga.dbValue),
        sourceMetadata: const Value<String?>('{"type":"online"}'),
      ),
    );
    return dir.path;
  }

  group('章节式在线漫画（BUG-2474）', () {
    test('清单：占位根目录不算 hasMangaContent，但有已下载的章即 hasMangaChapters', () async {
      await insertOnlineManga(
        bookKey: 'mihon-abc',
        chapterKeys: const <String>['/c/1', '/c/2'],
        downloaded: const <String>{'/c/1'},
      );
      await insertOnlineManga(
        bookKey: 'mihon-none',
        chapterKeys: const <String>['/c/1'],
        downloaded: const <String>{},
      );
      final List<RemoteBookInfo> books = await svc.listBooks();
      final RemoteBookInfo withChapters = books.firstWhere(
        (RemoteBookInfo b) => b.bookKey == 'mihon-abc',
      );
      expect(withChapters.hasMangaContent, isFalse);
      expect(withChapters.hasMangaChapters, isTrue);
      expect(withChapters.toJson()['hasMangaChapters'], isTrue);
      final RemoteBookInfo none = books.firstWhere(
        (RemoteBookInfo b) => b.bookKey == 'mihon-none',
      );
      expect(none.hasMangaChapters, isFalse);
      // 旧 wire 字节不变：没下载任何章的行不写这个键。
      expect(none.toJson().containsKey('hasMangaChapters'), isFalse);
    });

    test('页表：只列**完整**下载的章（半成品与未下载都不出现），页表为空', () async {
      await insertOnlineManga(
        bookKey: 'mihon-abc',
        chapterKeys: const <String>['/c/1', '/c/2', '/c/3'],
        downloaded: const <String>{'/c/1', '/c/3'},
        halfDownloaded: const <String>{'/c/2'},
      );
      final RemoteMangaManifest manifest = await svc.mangaManifest('mihon-abc');
      expect(manifest.pages, isEmpty);
      expect(manifest.hasChapters, isTrue);
      expect(
        manifest.chapters.map((RemoteMangaChapterInfo c) => c.key),
        <String>['/c/1', '/c/3'],
      );
      final RemoteMangaChapterInfo first = manifest.chapters.first;
      expect(first.name, 'Chapter 1');
      expect(first.number, 1);
      expect(first.scanlator, 'group');
      expect(first.pageCount, 2);
      // 经 wire 往返不丢字段。
      final RemoteMangaManifest roundTrip = RemoteMangaManifest.fromJson(
        manifest.toJson(),
      );
      expect(roundTrip.chapters.length, 2);
      expect(roundTrip.chapters.last.key, '/c/3');
      expect(roundTrip.chapters.last.scanlator, isNull);
    });

    test('一章都没完整下载 → 页表 StateError（与清单 hasMangaChapters 同源）', () async {
      await insertOnlineManga(
        bookKey: 'mihon-half',
        chapterKeys: const <String>['/c/1'],
        downloaded: const <String>{},
        halfDownloaded: const <String>{'/c/1'},
      );
      await expectLater(
        svc.mangaManifest('mihon-half'),
        throwsA(isA<StateError>()),
      );
    });

    test('按章页表 + 按章页图：digest 与 app 侧目录名同算法', () async {
      await insertOnlineManga(
        bookKey: 'mihon-abc',
        chapterKeys: const <String>['/c/1'],
        downloaded: const <String>{'/c/1'},
      );
      final String digest = mangaChapterDigest('/c/1');
      final RemoteMangaManifest chapter = await svc.mangaChapterManifest(
        'mihon-abc',
        digest,
      );
      expect(chapter.bookKey, 'mihon-abc');
      expect(chapter.pages.map((RemoteMangaPageInfo e) => e.index), <int>[
        0,
        1,
      ]);
      expect(chapter.pages.first.name, 'page-000001.jpg');
      final File page = await svc.mangaChapterPageFile('mihon-abc', digest, 1);
      expect(page.readAsBytesSync(), <int>[0xFF, 0xD8, 4, 1]);
      await expectLater(
        svc.mangaChapterPageFile('mihon-abc', digest, 2),
        throwsA(isA<StateError>()),
      );
      // 单卷通道对章节式条目不给页：根 manga.json 是占位。
      await expectLater(
        svc.mangaPageFile('mihon-abc', 0),
        throwsA(isA<StateError>()),
      );
    });

    test('未下载的章是 404 形状；不成形的 digest 是 403 形状', () async {
      await insertOnlineManga(
        bookKey: 'mihon-abc',
        chapterKeys: const <String>['/c/1', '/c/2'],
        downloaded: const <String>{'/c/1'},
      );
      await expectLater(
        svc.mangaChapterManifest('mihon-abc', mangaChapterDigest('/c/2')),
        throwsA(isA<StateError>()),
      );
      final List<String> bad = <String>['..', 'ABCDEF', '../../x', '0' * 23];
      for (final String digest in bad) {
        await expectLater(
          svc.mangaChapterManifest('mihon-abc', digest),
          throwsA(isA<ArgumentError>()),
          reason: digest,
        );
        await expectLater(
          svc.mangaChapterPageFile('mihon-abc', digest, 0),
          throwsA(isA<ArgumentError>()),
          reason: digest,
        );
      }
    });
  });

  group('host 运行时按需取页（未下载的在线漫画也给对端看）', () {
    late _FakeOnlineReader reader;
    late LocalLibraryHostService online;

    setUp(() {
      // 现取页的临时缓存按 bookKey 定位在系统临时目录；先清掉上次残留，免得命中旧页。
      final Directory pageCache = Directory(
        p.join(
          Directory.systemTemp.path,
          'fushi_interconnect_manga',
          mangaChapterDigest('mihon-none'),
        ),
      );
      if (pageCache.existsSync()) pageCache.deleteSync(recursive: true);
      reader = _FakeOnlineReader();
      online = LocalLibraryHostService(
        db: db,
        dictionaryResourceRoot: Directory.systemTemp,
        packages: SyncAssetPackageService(db: db),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(),
        onlineMangaReader: reader,
      );
    });

    test('一章没下的在线条目出现在清单，页表列出全部章', () async {
      await insertOnlineManga(
        bookKey: 'mihon-none',
        chapterKeys: const <String>['/c/1', '/c/2'],
        downloaded: const <String>{'/c/2'},
      );
      final RemoteBookInfo book = (await online.listBooks()).firstWhere(
        (RemoteBookInfo b) => b.bookKey == 'mihon-none',
      );
      expect(book.hasMangaChapters, isTrue);
      final RemoteMangaManifest manifest = await online.mangaManifest(
        'mihon-none',
      );
      expect(
        manifest.chapters.map((RemoteMangaChapterInfo c) => c.key),
        <String>['/c/1', '/c/2'],
      );
      // 已下载的章报真实页数，没下载的报 0（打开那章才知道）。
      expect(
        manifest.chapters.map((RemoteMangaChapterInfo c) => c.pageCount),
        <int>[0, 2],
      );
    });

    test('未下载的章：页表与页图经运行时现取，同页不重复取', () async {
      await insertOnlineManga(
        bookKey: 'mihon-none',
        chapterKeys: const <String>['/c/1'],
        downloaded: const <String>{},
      );
      final String digest = mangaChapterDigest('/c/1');
      final RemoteMangaManifest chapter = await online.mangaChapterManifest(
        'mihon-none',
        digest,
      );
      expect(chapter.pages.map((RemoteMangaPageInfo e) => e.index), <int>[
        0,
        1,
        2,
      ]);
      final File page = await online.mangaChapterPageFile(
        'mihon-none',
        digest,
        1,
      );
      expect(p.extension(page.path), '.png');
      expect(page.readAsBytesSync(), _FakeOnlineReader.pageBytes(1));
      final File again = await online.mangaChapterPageFile(
        'mihon-none',
        digest,
        1,
      );
      expect(again.path, page.path);
      expect(reader.pageFetches, 1);
      expect(reader.lastChapter?['key'], '/c/1');
      await expectLater(
        online.mangaChapterPageFile('mihon-none', digest, 3),
        throwsA(isA<StateError>()),
      );
    });

    test('并发请求同一未下载页：两路都成功、只打一次源站、落同一个文件', () async {
      await insertOnlineManga(
        bookKey: 'mihon-none',
        chapterKeys: const <String>['/c/1'],
        downloaded: const <String>{},
      );
      final String digest = mangaChapterDigest('/c/1');
      // 阅读器显示 + 预取（或两台对端）同时要同一页：两路都要在取页那一步挂住，
      // 才会真正并发地落盘 / 改名。
      final Completer<void> gate = Completer<void>();
      reader.gate = gate;
      final Future<File> first = online.mangaChapterPageFile(
        'mihon-none',
        digest,
        2,
      );
      final Future<File> second = online.mangaChapterPageFile(
        'mihon-none',
        digest,
        2,
      );
      await pumpEventQueue();
      gate.complete();
      final List<File> files = await Future.wait(<Future<File>>[first, second]);
      expect(files[0].path, files[1].path);
      expect(files[0].readAsBytesSync(), _FakeOnlineReader.pageBytes(2));
      expect(reader.pageFetches, 1);
      // 不留下改名失败的暂存文件。
      expect(
        files[0].parent.listSync().where(
          (FileSystemEntity e) => e.path.endsWith('.part'),
        ),
        isEmpty,
      );
    });

    test('现取页缓存按章有界：只留最近的章，当前章必留，删空的书目录', () {
      final Directory root = Directory(p.join(tmp.path, 'page_cache'));
      final DateTime base = DateTime(2026, 1, 1);
      Directory chapter(String book, String name, int minute) {
        final Directory dir = Directory(p.join(root.path, book, name))
          ..createSync(recursive: true);
        File(p.join(dir.path, '0.png'))
          ..writeAsBytesSync(<int>[1])
          ..setLastModifiedSync(base.add(Duration(minutes: minute)));
        return dir;
      }

      // 书 a 的两章最旧，书 b 的六章较新；当前章 = a 的最旧一章。新近度看页文件
      // 的写入时间：倒序建目录，按目录创建先后排就会删错。
      for (int i = 5; i >= 0; i--) {
        chapter('b', 'c$i', 10 + i);
      }
      chapter('a', 'c1', 1);
      final Directory current = chapter('a', 'c0', 0);
      pruneOnlineMangaPageCache(root, keep: current, keepChapters: 4);
      List<String> remaining(String book) {
        final Directory dir = Directory(p.join(root.path, book));
        if (!dir.existsSync()) return const <String>[];
        return dir
            .listSync()
            .map((FileSystemEntity e) => p.basename(e.path))
            .toList()
          ..sort();
      }

      expect(remaining('a'), <String>['c0']);
      expect(remaining('b'), <String>['c3', 'c4', 'c5']);

      // 当前章换到书 b 后，书 a 删空即整目录删掉。
      final Directory next = chapter('b', 'c6', 20);
      pruneOnlineMangaPageCache(root, keep: next, keepChapters: 3);
      expect(Directory(p.join(root.path, 'a')).existsSync(), isFalse);
      expect(remaining('b'), <String>['c4', 'c5', 'c6']);
    });

    test('运行时不认领的条目（iOS host / 二跳互联）照旧只给已下载的章', () async {
      reader.serves = false;
      await insertOnlineManga(
        bookKey: 'mihon-none',
        chapterKeys: const <String>['/c/1'],
        downloaded: const <String>{},
      );
      final RemoteBookInfo book = (await online.listBooks()).firstWhere(
        (RemoteBookInfo b) => b.bookKey == 'mihon-none',
      );
      expect(book.hasMangaChapters, isFalse);
      await expectLater(
        online.mangaChapterManifest('mihon-none', mangaChapterDigest('/c/1')),
        throwsA(isA<StateError>()),
      );
      expect(reader.pageFetches, 0);
    });
  });
}

class _FakeOnlineReader implements OnlineMangaHostReader {
  bool serves = true;
  int pageFetches = 0;
  Completer<void>? gate;
  Map<String, Object?>? lastChapter;

  static List<int> pageBytes(int index) => <int>[
    0x89,
    0x50,
    0x4e,
    0x47,
    0x0d,
    0x0a,
    0x1a,
    0x0a,
    index,
  ];

  @override
  bool canServe(String sourceMetadata) => serves;

  @override
  Future<int> chapterPageCount({
    required String bookKey,
    required String sourceMetadata,
    required Map<String, Object?> chapter,
  }) async {
    lastChapter = chapter;
    return 3;
  }

  @override
  Future<Uint8List> chapterPage({
    required String bookKey,
    required String sourceMetadata,
    required Map<String, Object?> chapter,
    required int index,
  }) async {
    lastChapter = chapter;
    RangeError.checkValidIndex(index, const <int>[0, 1, 2], 'index');
    pageFetches++;
    await gate?.future;
    return Uint8List.fromList(pageBytes(index));
  }
}
