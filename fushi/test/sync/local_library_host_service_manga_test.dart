import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/manga/manga_chapter_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart'
    show parseMangaJson;
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

  late _CountingDatabase db;
  late Directory tmp;
  late LocalLibraryHostService svc;

  setUp(() {
    db = _CountingDatabase();
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
    // 页身份（audit-035）：已落盘的页按文件名 + 尺寸认，过 wire 原样往返。
    expect(manifest.pages.first.key, 'file\u0000p1.jpg\u0000800x1200');
    expect(
      RemoteMangaPageInfo.fromJson(manifest.pages.first.toJson()).key,
      manifest.pages.first.key,
    );
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

  // 对端每翻一页打一次 mangaPageFile / mangaChapterPageFile：不能回回全表读书库、
  // 整份重读重解析 manga.json、再对整卷 / 整章逐页 stat。
  group('逐页请求不重复做整卷的活', () {
    /// 把 [json] 换成 [content]，但修改时间保持 [modified]（与原文件大小相同时，
    /// 缓存键「路径 + 修改时间 + 大小」完全不变）。
    void rewriteKeepingMtime(File json, String content, DateTime modified) {
      json.writeAsStringSync(content);
      json.setLastModifiedSync(modified);
    }

    String pagesJson(List<String> urls) => jsonEncode(<String, Object?>{
      'pages': <Object?>[
        for (final String url in urls)
          <String, Object?>{
            'url': url,
            'width': 800,
            'height': 1200,
            'blocks': <Object?>[],
          },
      ],
    });

    test('按主键取行：bookKey 命中时不读全表；传书名才回落全表找', () async {
      await insertManga(bookKey: 'vol1');
      await insertManga(bookKey: 'vol2');
      await (db.update(db.epubBooks)
            ..where(($EpubBooksTable t) => t.bookKey.equals('vol2')))
          .write(const EpubBooksCompanion(title: Value<String>('第二巻')));
      db.allBookReads = 0;

      await svc.mangaPageFile('vol1', 0);
      await svc.mangaPageFile('vol1', 1);
      await svc.mangaManifest('vol1');
      expect(db.allBookReads, 0, reason: 'bookKey 命中主键，不该读全表');

      final File byTitle = await svc.mangaPageFile('第二巻', 0);
      expect(byTitle.path, contains('vol2'));
      expect(db.allBookReads, 1, reason: '书名只能回落全表找');
    });

    test('单卷：manga.json 没变就用上次的解析结果；修改时间或大小一变即重读', () async {
      final String dir = await insertManga(bookKey: 'vol1');
      final File json = File(p.join(dir, kMangaPackageMarker));
      final DateTime modified = json.lastModifiedSync();
      expect((await svc.mangaPageFile('vol1', 0)).readAsBytesSync().last, 0);

      // 同大小、同修改时间，内容里两页对调：缓存键没变 → 仍按上次解析的页序给。
      rewriteKeepingMtime(
        json,
        pagesJson(const <String>['images/p2.jpg', 'images/p1.jpg']),
        modified,
      );
      expect((await svc.mangaPageFile('vol1', 0)).readAsBytesSync().last, 0);

      // 修改时间变了 → 重读，页序换成盘上的。
      json.setLastModifiedSync(modified.add(const Duration(seconds: 2)));
      expect((await svc.mangaPageFile('vol1', 0)).readAsBytesSync().last, 1);

      // 大小变了（修改时间保持）→ 重读：只剩一页，第 1 页越界。
      rewriteKeepingMtime(
        json,
        pagesJson(const <String>['images/p1.jpg']),
        modified.add(const Duration(seconds: 2)),
      );
      expect((await svc.mangaPageFile('vol1', 0)).readAsBytesSync().last, 0);
      await expectLater(
        svc.mangaPageFile('vol1', 1),
        throwsA(isA<StateError>()),
      );
    });

    test('单卷：缓存命中后只核对被请求的那一页', () async {
      final String dir = await insertManga(bookKey: 'vol1');
      await svc.mangaPageFile('vol1', 0);
      File(p.join(dir, 'images', 'p2.jpg')).deleteSync();
      // 被删的那页 404 形状；没被删的照给（没缓存时整卷判「缺页图」，见上面的用例）。
      expect((await svc.mangaPageFile('vol1', 0)).existsSync(), isTrue);
      await expectLater(
        svc.mangaPageFile('vol1', 1),
        throwsA(isA<StateError>()),
      );
    });

    test('章节式：章 manga.json 没变就不重读；被请求页不在则回到完整判定', () async {
      final String dir = await insertOnlineManga(
        bookKey: 'mihon-abc',
        chapterKeys: const <String>['/c/1'],
        downloaded: const <String>{'/c/1'},
      );
      final String digest = mangaChapterDigest('/c/1');
      final Directory chapterDir = mangaChapterDirectory(dir, '/c/1');
      final File json = mangaChapterJsonFile(chapterDir);
      final DateTime modified = json.lastModifiedSync();
      expect(
        (await svc.mangaChapterPageFile(
          'mihon-abc',
          digest,
          0,
        )).readAsBytesSync().last,
        0,
      );

      // 同大小、同修改时间，两页对调：缓存命中 → 仍是上次解析的页序。
      rewriteKeepingMtime(
        json,
        jsonEncode(<String, Object?>{
          'pages': <Object?>[
            for (final int i in const <int>[2, 1])
              <String, Object?>{
                'url': 'images/page-00000$i.jpg',
                'width': 700,
                'height': 1000,
                'blocks': <Object?>[],
              },
          ],
        }),
        modified,
      );
      expect(
        (await svc.mangaChapterPageFile(
          'mihon-abc',
          digest,
          0,
        )).readAsBytesSync().last,
        0,
      );

      // 被请求的页图没了：回到完整判定——这章不再算「完整下载」，本机又没有
      // 运行时可现取 → 与没有缓存时同一个 404 形状。
      File(p.join(chapterDir.path, 'images', 'page-000001.jpg')).deleteSync();
      await expectLater(
        svc.mangaChapterPageFile('mihon-abc', digest, 0),
        throwsA(isA<StateError>()),
      );
      // 另一页也不再给：完整判定没过关，缓存已清。
      await expectLater(
        svc.mangaChapterPageFile('mihon-abc', digest, 1),
        throwsA(isA<StateError>()),
      );
    });
  });

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
      // 带页身份取（HBK-AUDIT-205）：对得上照给，对不上拒。
      final File checked = await svc.mangaChapterPageFile(
        'mihon-abc',
        digest,
        1,
        expectedKeyDigest: remoteMangaPageKeyDigest(chapter.pages[1].key!),
      );
      expect(checked.path, page.path);
      await expectLater(
        svc.mangaChapterPageFile(
          'mihon-abc',
          digest,
          1,
          expectedKeyDigest: remoteMangaPageKeyDigest(chapter.pages[0].key!),
        ),
        throwsA(isA<MangaPageChanged>()),
      );
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
      // 现取章报运行时给的源端页身份；给不出的页不报（audit-035）。
      expect(chapter.pages.map((RemoteMangaPageInfo e) => e.key), <String?>[
        'source\u0000https://cdn.example/0.png',
        null,
        'source\u0000https://cdn.example/2.png',
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

    test('现取页缓存按页身份定名：源端换了页就不再端旧版缓存（audit-035）', () async {
      await insertOnlineManga(
        bookKey: 'mihon-none',
        chapterKeys: const <String>['/c/1'],
        downloaded: const <String>{},
      );
      final String digest = mangaChapterDigest('/c/1');
      final File before = await online.mangaChapterPageFile(
        'mihon-none',
        digest,
        0,
      );
      expect(reader.pageFetches, 1);
      reader.keys = const <String?>[
        'https://cdn.example/0-v2.png',
        null,
        'https://cdn.example/2.png',
      ];
      final File after = await online.mangaChapterPageFile(
        'mihon-none',
        digest,
        0,
      );
      expect(after.path, isNot(before.path));
      expect(reader.pageFetches, 2, reason: '换了身份的页重新现取');
      await online.mangaChapterPageFile('mihon-none', digest, 2);
      await online.mangaChapterPageFile('mihon-none', digest, 2);
      expect(reader.pageFetches, 3, reason: '身份没变的页照旧复用缓存');
    });

    test('取页带页身份：host 此刻那一页换了就拒（HBK-AUDIT-205）', () async {
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
      final String expected0 = remoteMangaPageKeyDigest(chapter.pages[0].key!);
      // 身份对得上：照常给页，并把身份交给运行时在同一份页表上再核一次。
      final File page = await online.mangaChapterPageFile(
        'mihon-none',
        digest,
        0,
        expectedKeyDigest: expected0,
      );
      expect(page.readAsBytesSync(), _FakeOnlineReader.pageBytes(0));
      expect(reader.expectedKeys, <String?>['https://cdn.example/0.png']);

      // host 重启 / 页表被淘汰后重解析出 [B, A, C]：同一页序已是另一页。
      reader.keys = const <String?>[
        'https://cdn.example/2.png',
        null,
        'https://cdn.example/0.png',
      ];
      await expectLater(
        online.mangaChapterPageFile(
          'mihon-none',
          digest,
          0,
          expectedKeyDigest: expected0,
        ),
        throwsA(isA<MangaPageChanged>()),
      );
      // 认不出身份的页（第 1 页）带着身份来取也拒：核不了就不能当成同一页。
      await expectLater(
        online.mangaChapterPageFile(
          'mihon-none',
          digest,
          1,
          expectedKeyDigest: expected0,
        ),
        throwsA(isA<MangaPageChanged>()),
      );
      expect(reader.pageFetches, 1);
    });

    test('对端读到一半 host 下完这章：页身份不变，旧页表照取已下载的页'
        '（review-interconnect-page-id-on-download）', () async {
      final String bookDir = await insertOnlineManga(
        bookKey: 'mihon-none',
        chapterKeys: const <String>['/c/1'],
        downloaded: const <String>{},
      );
      final String digest = mangaChapterDigest('/c/1');
      final RemoteMangaManifest before = await online.mangaChapterManifest(
        'mihon-none',
        digest,
      );

      // host 的下载服务把这章下完：页图 + 源端页身份旁注 + manga.json（与
      // MangaDownloadService 同一组引擎 helper）。
      final Directory chapterDir = mangaChapterDirectory(bookDir, '/c/1');
      final List<Map<String, Object?>> pages = <Map<String, Object?>>[];
      for (int i = 0; i < 3; i++) {
        File(p.join(chapterDir.path, 'images', 'page-00000${i + 1}.png'))
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(<int>[0x89, 0x50, 0x4e, 0x47, 0x40 + i]);
        pages.add(<String, Object?>{
          'url': 'images/page-00000${i + 1}.png',
          'width': 700 + i,
          'height': 1000,
          'blocks': <Object?>[],
        });
      }
      final String json = jsonEncode(<String, Object?>{'pages': pages});
      mangaChapterSourcePagesFile(chapterDir).writeAsStringSync(
        encodeMangaChapterSourcePages(
          mangaChapterSourcePagesOf(parseMangaJson(json), reader.keys),
        ),
      );
      mangaChapterJsonFile(chapterDir).writeAsStringSync(json);

      // 下载后的页表：源端认得的页报与下载前同一个身份，认不得的页按文件认。
      final RemoteMangaManifest after = await online.mangaChapterManifest(
        'mihon-none',
        digest,
      );
      expect(after.pages[0].key, before.pages[0].key);
      expect(after.pages[1].key, 'file\u0000page-000002.png\u0000701x1000');
      expect(after.pages[2].key, before.pages[2].key);

      // 拿着下载前的页表来取：给的是已下载的文件，不再打运行时。
      final File page = await online.mangaChapterPageFile(
        'mihon-none',
        digest,
        2,
        expectedKeyDigest: remoteMangaPageKeyDigest(before.pages[2].key!),
      );
      expect(p.isWithin(chapterDir.path, page.path), isTrue);
      expect(page.readAsBytesSync().last, 0x42);
      // 按文件认页的身份（旧 host 报的页表）照样认。
      final File byFile = await online.mangaChapterPageFile(
        'mihon-none',
        digest,
        1,
        expectedKeyDigest: remoteMangaPageKeyDigest(after.pages[1].key!),
      );
      expect(byFile.readAsBytesSync().last, 0x41);
      expect(reader.pageFetches, 0);

      // 另一页的源端身份不冒充这一页。
      await expectLater(
        online.mangaChapterPageFile(
          'mihon-none',
          digest,
          0,
          expectedKeyDigest: remoteMangaPageKeyDigest(before.pages[2].key!),
        ),
        throwsA(isA<MangaPageChanged>()),
      );

      // manga.json 换成另一份内容（第 3 页尺寸变了）：旁注对不上这一页，旧的
      // 源端身份不再认，保守地 409。
      pages[2] = <String, Object?>{...pages[2], 'width': 9000};
      mangaChapterJsonFile(
        chapterDir,
      ).writeAsStringSync(jsonEncode(<String, Object?>{'pages': pages}));
      await expectLater(
        online.mangaChapterPageFile(
          'mihon-none',
          digest,
          2,
          expectedKeyDigest: remoteMangaPageKeyDigest(before.pages[2].key!),
        ),
        throwsA(isA<MangaPageChanged>()),
      );
    });

    test('取完页身份、取图之前页表换了：运行时拒取，不落到旧身份的缓存名下', () async {
      await insertOnlineManga(
        bookKey: 'mihon-none',
        chapterKeys: const <String>['/c/1'],
        downloaded: const <String>{},
      );
      final String digest = mangaChapterDigest('/c/1');
      reader.racingKeys = () => 'https://cdn.example/other.png';
      await expectLater(
        online.mangaChapterPageFile('mihon-none', digest, 0),
        throwsA(isA<MangaPageChanged>()),
      );
      reader.racingKeys = null;
      final File page = await online.mangaChapterPageFile(
        'mihon-none',
        digest,
        0,
      );
      expect(page.readAsBytesSync(), _FakeOnlineReader.pageBytes(0));
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
  Future<List<String?>> chapterPageKeys({
    required String bookKey,
    required String sourceMetadata,
    required Map<String, Object?> chapter,
  }) async {
    lastChapter = chapter;
    return keys;
  }

  /// [chapterPage] 收到的 expectedPageKey（按调用顺序）。
  final List<String?> expectedKeys = <String?>[];

  /// 非空时 [chapterPage] 核对身份用它给的值：模拟 host 取完页身份、真正取图之前
  /// 页表被淘汰并重解析成换了页的一份。
  String? Function()? racingKeys;

  /// 运行时报的页身份（第 1 页认不出）；测试改它模拟源端换页。
  List<String?> keys = const <String?>[
    'https://cdn.example/0.png',
    null,
    'https://cdn.example/2.png',
  ];

  @override
  Future<Uint8List> chapterPage({
    required String bookKey,
    required String sourceMetadata,
    required Map<String, Object?> chapter,
    required int index,
    required String? expectedPageKey,
  }) async {
    lastChapter = chapter;
    RangeError.checkValidIndex(index, const <int>[0, 1, 2], 'index');
    expectedKeys.add(expectedPageKey);
    // 与真实运行时同一约定：在取图所用的页表上核对身份。
    final String? current = racingKeys?.call() ?? keys[index];
    if (expectedPageKey != null && current != expectedPageKey) {
      throw MangaPageChanged('page $index changed');
    }
    pageFetches++;
    await gate?.future;
    return Uint8List.fromList(pageBytes(index));
  }
}

/// 数全表读书库的次数（逐页请求不该走全表）。
class _CountingDatabase extends FushiDatabase {
  _CountingDatabase() : super.forTesting(NativeDatabase.memory());

  int allBookReads = 0;

  @override
  Future<List<EpubBookRow>> getAllEpubBooks() {
    allBookReads += 1;
    return super.getAllEpubBooks();
  }
}
