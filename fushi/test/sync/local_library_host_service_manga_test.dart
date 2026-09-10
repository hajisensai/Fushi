import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
