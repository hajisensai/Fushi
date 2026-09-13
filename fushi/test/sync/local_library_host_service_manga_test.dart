import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/manga/manga_chapter_storage.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/manga_sync_package.dart';
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
    await expectLater(
      svc.mangaPageFile('vol1', 0),
      throwsA(isA<StateError>()),
    );
  });

  test('越界页 StateError', () async {
    await insertManga(bookKey: 'vol1');
    await expectLater(svc.mangaPageFile('vol1', 5), throwsA(isA<StateError>()));
    await expectLater(
        svc.mangaPageFile('vol1', -1), throwsA(isA<StateError>()));
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
    await expectLater(
      svc.mangaManifest('novel'),
      throwsA(isA<StateError>()),
    );
  });

  test('占位空合集不给页表——与清单的 hasMangaContent 判据同源（BUG-2400）', () async {
    await insertManga(
      bookKey: 'empty',
      pageUrls: const <String>[],
      writeImages: false,
    );
    await expectLater(
      svc.mangaManifest('empty'),
      throwsA(isA<StateError>()),
    );
    // 清单侧对同一本的结论必须一致，否则就是「列表说有、点开说没有」。
    final RemoteBookInfo row = (await svc.listBooks()).firstWhere(
      (RemoteBookInfo b) => b.bookKey == 'empty',
    );
    expect(row.hasMangaContent, isFalse);
  });

  test('缺页图的书不给页表（清单也不会声称有内容）', () async {
    await insertManga(bookKey: 'missing', writeImages: false);
    await expectLater(
      svc.mangaManifest('missing'),
      throwsA(isA<StateError>()),
    );
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
    File(p.join(dir.path, kMangaPackageMarker))
        .writeAsStringSync('{"pages":[]}');
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
      mangaChapterJsonFile(chapterDir)
          .writeAsStringSync(jsonEncode(<String, Object?>{'pages': pages}));
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
    test('清单：占位根目录不算 hasMangaContent，但有已下载的章即 hasMangaChapters',
        () async {
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
      final RemoteBookInfo withChapters =
          books.firstWhere((RemoteBookInfo b) => b.bookKey == 'mihon-abc');
      expect(withChapters.hasMangaContent, isFalse);
      expect(withChapters.hasMangaChapters, isTrue);
      expect(withChapters.toJson()['hasMangaChapters'], isTrue);
      final RemoteBookInfo none =
          books.firstWhere((RemoteBookInfo b) => b.bookKey == 'mihon-none');
      expect(none.hasMangaChapters, isFalse);
      // 旧 wire 字节不变：没下载任何章的行不写这个键。
      expect(none.toJson().containsKey('hasMangaChapters'), isFalse);
    });

    test('页表：只列**完整**下载的章（半成品与未下载都不出现），页表为空',
        () async {
      await insertOnlineManga(
        bookKey: 'mihon-abc',
        chapterKeys: const <String>['/c/1', '/c/2', '/c/3'],
        downloaded: const <String>{'/c/1', '/c/3'},
        halfDownloaded: const <String>{'/c/2'},
      );
      final RemoteMangaManifest manifest =
          await svc.mangaManifest('mihon-abc');
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
      final RemoteMangaManifest roundTrip =
          RemoteMangaManifest.fromJson(manifest.toJson());
      expect(roundTrip.chapters.length, 2);
      expect(roundTrip.chapters.last.key, '/c/3');
      expect(roundTrip.chapters.last.scanlator, isNull);
    });

    test('一章都没完整下载 → 页表 StateError（与清单 hasMangaChapters 同源）',
        () async {
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
      final RemoteMangaManifest chapter =
          await svc.mangaChapterManifest('mihon-abc', digest);
      expect(chapter.bookKey, 'mihon-abc');
      expect(
        chapter.pages.map((RemoteMangaPageInfo e) => e.index),
        <int>[0, 1],
      );
      expect(chapter.pages.first.name, 'page-000001.jpg');
      final File page =
          await svc.mangaChapterPageFile('mihon-abc', digest, 1);
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
}
