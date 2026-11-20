// BUG-4840：漫画导入的书目录归属。
//
// 页图先备进书库根下本次独占的 `.tmp-*`，落位锁内才挪进 `<bookKey>/` 并插行；
// 失败回滚只删本次自己建的目录。此前是直接往 `<bookKey>/` 里写（存在即复用）、
// 失败无条件整个删掉。
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/manga_importer.dart';
import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  late Directory appDocDir;
  late Directory srcRoot;
  late String booksRoot;
  late FushiDatabase db;

  setUp(() {
    appDocDir = Directory.systemTemp.createTempSync('manga_dir_owner_app_');
    srcRoot = Directory.systemTemp.createTempSync('manga_dir_owner_src_');
    EpubStorage.debugBaseDirectoryOverride = appDocDir.path;
    booksRoot = p.join(appDocDir.path, 'fushi_books');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    EpubStorage.debugBaseDirectoryOverride = null;
    for (final Directory d in <Directory>[appDocDir, srcRoot]) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  });

  List<String> rootNames() => Directory(booksRoot).existsSync()
      ? (Directory(booksRoot)
            .listSync(followLinks: false)
            .map((FileSystemEntity e) => p.basename(e.path))
            .toList()
          ..sort())
      : <String>[];

  /// 一个两页的页图文件夹；[width] 让不同来源的页图字节可区分。
  String pageFolder(String name, {required int width}) {
    final Directory dir = Directory(p.join(srcRoot.path, name))..createSync();
    for (final String page in <String>['001.png', '002.png']) {
      File(
        p.join(dir.path, page),
      ).writeAsBytesSync(img.encodePng(img.Image(width: width, height: 20)));
    }
    return dir.path;
  }

  Uint8List firstPage(String dir) =>
      File(p.join(dir, 'images', '001.png')).readAsBytesSync();

  test('并发导入同名漫画：两本都入库，各占各的目录、页图不串', () async {
    final String a = pageFolder('a', width: 10);
    final String b = pageFolder('b', width: 30);

    final List<String> keys = await Future.wait(<Future<String>>[
      MangaImporter.importFromImageFolder(
        db: db,
        imageDirPath: a,
        title: '同名漫画',
      ),
      MangaImporter.importFromImageFolder(
        db: db,
        imageDirPath: b,
        title: '同名漫画',
      ),
    ]);

    expect(keys.toSet(), hasLength(2));
    final List<EpubBookRow> rows = await db.getAllEpubBooks();
    expect(rows, hasLength(2));
    final Set<int> widths = <int>{};
    for (final EpubBookRow row in rows) {
      expect(Directory(row.extractDir).existsSync(), isTrue);
      expect(
        File(
          p.join(row.extractDir, MangaStorage.kMangaJsonFileName),
        ).existsSync(),
        isTrue,
      );
      widths.add(img.decodePng(firstPage(row.extractDir))!.width);
    }
    expect(widths, <int>{10, 30}, reason: '每本书目录里是自己那一份页图');
    expect(rootNames().where((String n) => n.startsWith('.')), isEmpty);
  });

  test('并发导入同名漫画（skip）：输家按重复跳过，赢家的目录原封不动', () async {
    final String a = pageFolder('a', width: 10);
    final String b = pageFolder('b', width: 30);

    Future<Object?> run(String dir) async {
      try {
        return await MangaImporter.importFromImageFolder(
          db: db,
          imageDirPath: dir,
          title: '同名漫画',
          policy: const DuplicatePolicy.skip(),
        );
      } on DuplicateImportCancelledException catch (e) {
        return e;
      }
    }

    final List<Object?> results = await Future.wait(<Future<Object?>>[
      run(a),
      run(b),
    ]);

    expect(results.whereType<String>(), hasLength(1));
    expect(
      results.whereType<DuplicateImportCancelledException>(),
      hasLength(1),
    );
    final EpubBookRow row = (await db.getAllEpubBooks()).single;
    expect(
      File(p.join(row.extractDir, 'images', '002.png')).existsSync(),
      true,
    );
    expect(rootNames(), <String>['同名漫画']);
  });

  test('拷图期间书目录还不存在：页图在书库根下的 .tmp-* 里', () async {
    final String src = pageFolder('a', width: 10);
    final List<List<String>> seen = <List<String>>[];

    await MangaImporter.importFromImageFolder(
      db: db,
      imageDirPath: src,
      title: '暂存中',
      onProgress: (int done, int total) => seen.add(rootNames()),
    );

    expect(seen, hasLength(2));
    for (final List<String> names in seen) {
      expect(names, hasLength(1));
      expect(names.single, startsWith(EpubStorage.kStagingDirPrefix));
    }
    expect(rootNames(), <String>['暂存中']);
  });

  test('拷图中途失败：暂存目录收掉，不留书目录、不留行', () async {
    final String src = pageFolder('a', width: 10);

    await expectLater(
      MangaImporter.importFromImageFolder(
        db: db,
        imageDirPath: src,
        title: '失败的导入',
        onProgress: (int done, int total) => throw StateError('disk full'),
      ),
      throwsStateError,
    );

    expect(rootNames(), isEmpty);
    expect(await db.getAllEpubBooks(), isEmpty);
  });

  test('拷图中途失败：同名的孤儿目录（可在「找回书库」恢复）原封不动', () async {
    final String orphan = p.join(booksRoot, '孤儿漫画');
    Directory(orphan).createSync(recursive: true);
    File(p.join(orphan, 'keep.txt')).writeAsStringSync('recoverable');
    final String src = pageFolder('a', width: 10);

    await expectLater(
      MangaImporter.importFromImageFolder(
        db: db,
        imageDirPath: src,
        title: '孤儿漫画',
        onProgress: (int done, int total) => throw StateError('disk full'),
      ),
      throwsStateError,
    );

    expect(rootNames(), <String>['孤儿漫画']);
    expect(File(p.join(orphan, 'keep.txt')).readAsStringSync(), 'recoverable');
    expect(
      Directory(p.join(orphan, 'images')).existsSync(),
      isFalse,
      reason: '失败的导入没往孤儿目录里写过东西',
    );
  });

  test('导入成功时同名孤儿目录被整体替换，不与新书混写', () async {
    final String orphan = p.join(booksRoot, '孤儿漫画');
    Directory(p.join(orphan, 'images')).createSync(recursive: true);
    File(p.join(orphan, 'images', '999.png')).writeAsStringSync('stale page');
    final String src = pageFolder('a', width: 10);

    final String key = await MangaImporter.importFromImageFolder(
      db: db,
      imageDirPath: src,
      title: '孤儿漫画',
    );

    final EpubBookRow row = (await db.getEpubBook(key))!;
    expect(p.equals(row.extractDir, orphan), isTrue);
    expect(File(p.join(orphan, 'images', '999.png')).existsSync(), isFalse);
    expect(File(p.join(orphan, 'images', '001.png')).existsSync(), isTrue);
    expect(rootNames(), <String>['孤儿漫画']);
  });

  test('插行失败的回滚只删自己落位的目录，活行占着的目录不动', () async {
    // 活行的 extract_dir 正是新书按书名键会落到的目录；它的标题不同，所以书名判重
    // 放行，而主键（bookKey）相撞——插行必然失败，逼出「落位之后」的回滚。
    final String liveDir = p.join(booksRoot, '撞键');
    Directory(liveDir).createSync(recursive: true);
    File(p.join(liveDir, 'live.txt')).writeAsStringSync('live book');
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: '撞键',
        title: '另一个标题',
        epubPath: MangaStorage.kMangaJsonFileName,
        extractDir: liveDir,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1,
      ),
    );
    final String src = pageFolder('a', width: 10);

    await expectLater(
      MangaImporter.importFromImageFolder(
        db: db,
        imageDirPath: src,
        title: '撞键',
      ),
      throwsA(isA<Object>()),
    );

    expect(rootNames(), <String>['撞键'], reason: '自己落位的 ~2 与暂存都收掉了');
    expect(File(p.join(liveDir, 'live.txt')).readAsStringSync(), 'live book');
    expect(Directory(p.join(liveDir, 'images')).existsSync(), isFalse);
    expect(await db.getAllEpubBooks(), hasLength(1));
  });
}
