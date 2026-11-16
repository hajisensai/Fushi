import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/interconnect/interconnect_manga_source.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_reshelf.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/library/online_manga_shelf_sidecar.dart';
import 'package:fushi/src/storage/data_root_migrator.dart';
import 'package:fushi/src/storage/directory_move.dart';
import 'package:fushi/src/storage/download_layout.dart';
import 'package:fushi/src/storage/download_root_migrator.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:path/path.dart' as p;

/// 统一下载根（BUG-4702）：路径派生、在线漫画跟随下载根、旧位置搬家、改根搬移、
/// 保留文件后重新入库、备份带走下载根里的漫画。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late FushiDatabase db;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('fushi-download-root-');
    EpubStorage.debugBaseDirectoryOverride = p.join(temp.path, 'docs');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    DownloadRoot.install(null);
    EpubStorage.debugBaseDirectoryOverride = null;
    await db.close();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  OnlineMangaLibraryEntry entry(String seriesKey) => OnlineMangaLibraryEntry(
    runtime: OnlineMangaRuntimeKind.mihon,
    extensionPackage: 'org.example.fixture',
    sourceId: '42',
    series: OnlineMangaSeries(
      key: seriesKey,
      title: 'Series $seriesKey',
      raw: <String, Object?>{'url': seriesKey},
    ),
    chapters: const <OnlineMangaChapter>[
      OnlineMangaChapter(
        key: '/c/1',
        name: 'Chapter 1',
        number: 1,
        uploadedAt: 1,
        raw: <String, Object?>{'url': '/c/1'},
      ),
    ],
  );

  OnlineMangaLibraryService serviceAt(String root) => OnlineMangaLibraryService(
    database: db,
    rootDirectory: Directory(p.join(temp.path, 'runtime')),
    adapter: _NoCoverAdapter(),
    downloadLayout: () async => DownloadLayout(root: root),
  );

  group('DownloadLayout', () {
    test('各域路径从一个下载根派生', () {
      final String root = p.join(temp.path, 'dl');
      final DownloadLayout layout = DownloadLayout(root: root);
      expect(layout.mangaRoot, p.join(root, 'manga'));
      expect(layout.mangaBookPath('k'), p.join(root, 'manga', 'k'));
      expect(layout.musicRoot, p.join(root, 'music'));
      expect(layout.discoveryPath('novel'), p.join(root, 'discovery', 'novel'));
    });

    test('旧根去重、剔除当前根；allMangaRoots 覆盖全部根', () {
      final String a = p.join(temp.path, 'a');
      final String b = p.join(temp.path, 'b');
      final DownloadLayout layout = DownloadLayout(
        root: a,
        legacyRoots: <String>[b, a, b, ''],
      );
      expect(layout.legacyRoots, <String>[p.normalize(b)]);
      expect(layout.allMangaRoots, <String>[
        p.join(p.normalize(a), 'manga'),
        p.join(p.normalize(b), 'manga'),
      ]);
    });

    test('isMangaBookDirectory 按下载布局形状判，旧位置不算', () {
      expect(
        DownloadLayout.isMangaBookDirectory(
          p.join(temp.path, 'any', 'manga', 'k'),
          'k',
        ),
        isTrue,
      );
      expect(
        DownloadLayout.isMangaBookDirectory(
          p.join(temp.path, 'fushi_books', 'k'),
          'k',
        ),
        isFalse,
      );
      expect(
        DownloadLayout.isMangaBookDirectory(
          p.join(temp.path, 'library', 'k'),
          'k',
        ),
        isFalse,
      );
      expect(
        DownloadLayout.isMangaBookDirectory(
          p.join(temp.path, 'manga', 'other'),
          'k',
        ),
        isFalse,
      );
    });

    test('没装解析器时默认根 = <documents>/anime_downloads/content', () async {
      final DownloadLayout layout = await DownloadRoot.current();
      expect(
        layout.root,
        p.join(temp.path, 'docs', 'anime_downloads', 'content'),
        reason: '与 torrent 默认根逐字节一致，存量任务不受影响',
      );
    });
  });

  group('在线漫画跟随下载根', () {
    test('入库落 <用户下载根>/manga/<bookKey> 并写侧车', () async {
      final String root = p.join(temp.path, 'custom-dl');
      final EpubBookRow row = await serviceAt(root).add(entry('/s/1'));
      expect(row.extractDir, p.join(root, 'manga', row.bookKey));
      final OnlineMangaShelfSidecar? sidecar =
          await OnlineMangaShelfSidecar.read(row.extractDir);
      expect(sidecar, isNotNull);
      expect(sidecar!.bookKey, row.bookKey);
      expect(sidecar.uid, row.uid);
      expect(sidecar.entry.series.key, '/s/1');
    });

    test('fushi_books 里的存量条目首次访问时搬进下载根，bookKey/uid 不变', () async {
      final String root = p.join(temp.path, 'dl');
      final OnlineMangaLibraryService service = serviceAt(root);
      final EpubBookRow added = await service.add(entry('/s/2'));
      final String legacy = p.join(
        await EpubStorage.baseDirectory(),
        added.bookKey,
      );
      Directory(legacy).parent.createSync(recursive: true);
      Directory(added.extractDir).renameSync(legacy);
      File(p.join(legacy, 'chapters', 'x', 'page.jpg'))
        ..createSync(recursive: true)
        ..writeAsStringSync('page');
      File(
        p.join(legacy, kOnlineMangaShelfSidecarFileName),
      ).deleteSync(); // 存量目录没有侧车
      await db.updateEpubBookContentPaths(added.bookKey, extractDir: legacy);

      final EpubBookRow moved = await service.ensureBookDirectory(
        (await db.getEpubBook(added.bookKey))!,
      );
      expect(moved.extractDir, p.join(root, 'manga', added.bookKey));
      expect(moved.uid, added.uid);
      expect(Directory(legacy).existsSync(), isFalse);
      expect(
        File(
          p.join(moved.extractDir, 'chapters', 'x', 'page.jpg'),
        ).readAsStringSync(),
        'page',
      );
      expect(
        File(
          p.join(moved.extractDir, kOnlineMangaShelfSidecarFileName),
        ).existsSync(),
        isTrue,
        reason: '搬家时补写侧车',
      );
    });

    test('已在旧下载根布局里的条目不被搬到新根（用户选了只用于新下载）', () async {
      final String oldRoot = p.join(temp.path, 'old');
      final EpubBookRow added = await serviceAt(oldRoot).add(entry('/s/3'));
      final OnlineMangaLibraryService newService = serviceAt(
        p.join(temp.path, 'new'),
      );
      final EpubBookRow same = await newService.ensureBookDirectory(added);
      expect(same.extractDir, added.extractDir);
      expect(Directory(added.extractDir).existsSync(), isTrue);
    });

    test('改根迁移中断在「已改名、库未改写」：按目录事实把行指回当前根', () async {
      final String oldRoot = p.join(temp.path, 'old');
      final String newRoot = p.join(temp.path, 'new');
      final EpubBookRow added = await serviceAt(oldRoot).add(entry('/s/4'));
      Directory(p.join(newRoot, 'manga')).createSync(recursive: true);
      Directory(
        added.extractDir,
      ).renameSync(p.join(newRoot, 'manga', added.bookKey));
      final EpubBookRow healed = await serviceAt(
        newRoot,
      ).ensureBookDirectory(added);
      expect(healed.extractDir, p.join(newRoot, 'manga', added.bookKey));
      expect(
        (await db.getEpubBook(added.bookKey))!.extractDir,
        healed.extractDir,
      );
    });
  });

  group('重新入库', () {
    test('只认侧车身份与目录名、推导键三者一致的目录；缺侧车的列为无法重建', () async {
      final String root = p.join(temp.path, 'dl');
      DownloadRoot.install(() async => DownloadLayout(root: root));
      final EpubBookRow row = await serviceAt(root).add(entry('/s/5'));
      // 模拟「删书保留文件」：只删行。
      await db.deleteEpubBook(row.bookKey, tombstone: true);
      // 一个没有侧车的孤儿目录 + 一个侧车被拷错目录的目录。
      Directory(p.join(root, 'manga', 'mihon-orphan')).createSync();
      final Directory wrong = Directory(p.join(root, 'manga', 'mihon-wrong'))
        ..createSync();
      File(
        p.join(row.extractDir, kOnlineMangaShelfSidecarFileName),
      ).copySync(p.join(wrong.path, kOnlineMangaShelfSidecarFileName));

      final OnlineMangaReshelf reshelf = OnlineMangaReshelf(database: db);
      final OnlineMangaReshelfScan scan = await reshelf.scan();
      expect(
        scan.recoverable.map((RecoverableOnlineManga r) => r.bookKey),
        <String>[row.bookKey],
      );
      expect(scan.unrecognizedDirectories.map(p.basename).toSet(), <String>{
        'mihon-orphan',
        'mihon-wrong',
      });

      final EpubBookRow back = await reshelf.reshelve(scan.recoverable.single);
      expect(back.bookKey, row.bookKey);
      expect(back.uid, row.uid);
      expect(back.extractDir, row.extractDir);
      expect(back.format, 'manga');
      expect(back.chapterCount, 1);
      expect(
        OnlineMangaLibraryEntry.tryParse(back.sourceMetadata)?.series.key,
        '/s/5',
      );
    });

    test('重新入库互联漫画与入库同一个建行口：清掉「从所有设备删除」写的对端键墓碑', () async {
      final String root = p.join(temp.path, 'dl');
      DownloadRoot.install(() async => DownloadLayout(root: root));
      final OnlineMangaLibraryEntry remote = InterconnectMangaCatalog.entryFor(
        const RemoteBookInfo(
          title: 'Remote manga',
          bookKey: 'host-manga-key',
          hasContent: false,
          hasMangaChapters: true,
          format: 'manga',
        ),
      );
      final EpubBookRow row = await serviceAt(root).add(remote);
      // 删书框「从所有设备删除」+ 保留已下载章节：行删掉、对端键墓碑待推。
      await db.deleteEpubBook(row.bookKey);
      await db.writeSyncDeletionTombstone(
        SyncTombstoneKind.book.dbValue,
        'host-manga-key',
        100,
      );

      final OnlineMangaReshelf reshelf = OnlineMangaReshelf(database: db);
      final EpubBookRow back = await reshelf.reshelve(
        (await reshelf.scan()).recoverable.single,
      );

      expect(back.uid, row.uid);
      expect(
        await db.getSyncDeletionTombstonesOfType(
          SyncTombstoneKind.book.dbValue,
        ),
        isEmpty,
        reason: '对端键墓碑留着，下一轮同步就把刚重新入库的书从 host 删掉',
      );
    });

    test('旧下载根里保留的漫画也扫得到', () async {
      final String oldRoot = p.join(temp.path, 'old');
      final String newRoot = p.join(temp.path, 'new');
      final EpubBookRow row = await serviceAt(oldRoot).add(entry('/s/6'));
      await db.deleteEpubBook(row.bookKey);
      final OnlineMangaReshelf reshelf = OnlineMangaReshelf(
        database: db,
        downloadLayout: () async =>
            DownloadLayout(root: newRoot, legacyRoots: <String>[oldRoot]),
      );
      expect(
        (await reshelf.scan()).recoverable.single.directory,
        row.extractDir,
      );
    });

    test('discard 删掉目录；已回到书架的拒绝删', () async {
      final String root = p.join(temp.path, 'dl');
      DownloadRoot.install(() async => DownloadLayout(root: root));
      final EpubBookRow row = await serviceAt(root).add(entry('/s/7'));
      await db.deleteEpubBook(row.bookKey);
      final OnlineMangaReshelf reshelf = OnlineMangaReshelf(database: db);
      final RecoverableOnlineManga item =
          (await reshelf.scan()).recoverable.single;
      await reshelf.reshelve(item);
      await expectLater(reshelf.discard(item), throwsStateError);
      expect(Directory(row.extractDir).existsSync(), isTrue);
      await db.deleteEpubBook(row.bookKey);
      await reshelf.discard(item);
      expect(Directory(row.extractDir).existsSync(), isFalse);
    });
  });

  group('copyTreeMerging', () {
    test('合并进已有目标：覆盖半截文件、忽略 .fushi-part 残留、保留目标多余文件', () async {
      final Directory src = Directory(p.join(temp.path, 'src'))..createSync();
      final Directory dst = Directory(p.join(temp.path, 'dst'))..createSync();
      File(p.join(src.path, 'a', 'b.bin'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(Uint8List.fromList(<int>[1, 2, 3, 4]));
      File(p.join(src.path, 'junk.fushi-part')).writeAsStringSync('x');
      File(p.join(dst.path, 'a', 'b.bin'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(Uint8List.fromList(<int>[1])); // 上次中断的半截
      File(p.join(dst.path, 'extra.txt')).writeAsStringSync('keep');

      await copyTreeMerging(src, dst);

      expect(File(p.join(dst.path, 'a', 'b.bin')).readAsBytesSync(), <int>[
        1,
        2,
        3,
        4,
      ]);
      expect(File(p.join(dst.path, 'extra.txt')).existsSync(), isTrue);
      expect(File(p.join(dst.path, 'junk.fushi-part')).existsSync(), isFalse);
      expect(
        File(p.join(dst.path, 'a', 'b.bin.fushi-part')).existsSync(),
        isFalse,
      );
      expect(src.existsSync(), isTrue, reason: '只复制不删源');
    });
  });

  group('DownloadRootMigrator', () {
    Future<void> insertBook(String key, String extractDir) => db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: key,
        title: key,
        epubPath: 'manga.json',
        extractDir: extractDir,
        chapterCount: 0,
        chaptersJson: '[]',
        importedAt: 0,
      ),
    );

    test('搬 manga 与 music 域、改写库路径；torrent 分类目录与域外行不动', () async {
      final String oldRoot = p.join(temp.path, 'old');
      final String newRoot = p.join(temp.path, 'new');
      final String mangaDir = p.join(oldRoot, 'manga', 'k1');
      File(p.join(mangaDir, 'manga.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{}');
      File(p.join(oldRoot, 'music', 'p', 'a.flac'))
        ..createSync(recursive: true)
        ..writeAsStringSync('flac');
      File(p.join(oldRoot, 'fushi', 'video.mkv'))
        ..createSync(recursive: true)
        ..writeAsStringSync('seed');
      final String booksDir = p.join(temp.path, 'docs', 'fushi_books', 'k2');
      await insertBook('k1', mangaDir);
      await insertBook('k2', booksDir);

      final DownloadRootMigrator real = DownloadRootMigrator(database: db);
      expect(await real.hasMovableContent(oldRoot), isTrue);
      final DownloadRootMoveReport report = await real.move(
        oldRoot: oldRoot,
        newRoot: newRoot,
      );

      expect(report.succeeded, isTrue, reason: report.detail);
      expect(report.movedDomains, <String>['manga', 'music']);
      expect(
        File(p.join(newRoot, 'manga', 'k1', 'manga.json')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(newRoot, 'music', 'p', 'a.flac')).existsSync(),
        isTrue,
      );
      expect(Directory(p.join(oldRoot, 'manga')).existsSync(), isFalse);
      expect(
        File(p.join(oldRoot, 'fushi', 'video.mkv')).existsSync(),
        isTrue,
        reason: 'torrent 分类目录不搬（做种中的任务握着句柄）',
      );
      expect(
        (await db.getEpubBook('k1'))!.extractDir,
        p.join(newRoot, 'manga', 'k1'),
      );
      expect((await db.getEpubBook('k2'))!.extractDir, booksDir);
    });

    test('目标已有部分内容（上次中断）：走合并复制，删源，路径改写', () async {
      final String oldRoot = p.join(temp.path, 'old');
      final String newRoot = p.join(temp.path, 'new');
      final String mangaDir = p.join(oldRoot, 'manga', 'k1');
      File(p.join(mangaDir, 'a.jpg'))
        ..createSync(recursive: true)
        ..writeAsStringSync('A');
      File(p.join(newRoot, 'manga', 'k1', 'a.jpg'))
        ..createSync(recursive: true)
        ..writeAsStringSync('half');
      await insertBook('k1', mangaDir);

      final DownloadRootMoveReport report = await DownloadRootMigrator(
        database: db,
      ).move(oldRoot: oldRoot, newRoot: newRoot);

      expect(report.succeeded, isTrue);
      expect(
        File(p.join(newRoot, 'manga', 'k1', 'a.jpg')).readAsStringSync(),
        'A',
      );
      expect(Directory(p.join(oldRoot, 'manga')).existsSync(), isFalse);
      expect(
        (await db.getEpubBook('k1'))!.extractDir,
        p.join(newRoot, 'manga', 'k1'),
      );
    });

    test('有下载任务在写 / 新旧目录嵌套：拒绝且什么都不动', () async {
      final String oldRoot = p.join(temp.path, 'old');
      final String mangaDir = p.join(oldRoot, 'manga', 'k1');
      File(p.join(mangaDir, 'a.jpg'))
        ..createSync(recursive: true)
        ..writeAsStringSync('A');
      await insertBook('k1', mangaDir);
      final DownloadRootMigrator migrator = DownloadRootMigrator(database: db);

      final DownloadRootMoveReport busy = await migrator.move(
        oldRoot: oldRoot,
        newRoot: p.join(temp.path, 'new'),
        busyReason: 'running',
      );
      expect(busy.failure, DownloadRootMoveFailure.busy);

      final DownloadRootMoveReport nested = await migrator.move(
        oldRoot: oldRoot,
        newRoot: p.join(oldRoot, 'manga', 'inner'),
      );
      expect(nested.failure, DownloadRootMoveFailure.nested);

      expect(File(p.join(mangaDir, 'a.jpg')).existsSync(), isTrue);
      expect((await db.getEpubBook('k1'))!.extractDir, mangaDir);
    });

    /// 旧根下 manga 与 music 都有内容；manga 先落地，music 失败时不能把 manga 留在
    /// 新根（调用方失败时不切根，留下的 manga 就在一个谁都不扫的目录里）。
    Future<({String oldRoot, String newRoot, String mangaDir})>
    twoDomains() async {
      final String oldRoot = p.join(temp.path, 'old');
      final String newRoot = p.join(temp.path, 'new');
      final String mangaDir = p.join(oldRoot, 'manga', 'k1');
      File(p.join(mangaDir, 'manga.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{}');
      // 删书保留下来的无行目录：也必须跟着撤回，否则扫描找不回它。
      File(p.join(oldRoot, 'manga', 'kept', 'fushi_shelf.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{}');
      File(p.join(oldRoot, 'music', 'p', 'a.flac'))
        ..createSync(recursive: true)
        ..writeAsStringSync('flac');
      await insertBook('k1', mangaDir);
      return (oldRoot: oldRoot, newRoot: newRoot, mangaDir: mangaDir);
    }

    void expectUntouched(
      ({String oldRoot, String newRoot, String mangaDir}) fx,
    ) {
      expect(File(p.join(fx.mangaDir, 'manga.json')).existsSync(), isTrue);
      expect(
        File(
          p.join(fx.oldRoot, 'manga', 'kept', 'fushi_shelf.json'),
        ).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(fx.oldRoot, 'music', 'p', 'a.flac')).existsSync(),
        isTrue,
      );
      expect(Directory(p.join(fx.newRoot, 'manga')).existsSync(), isFalse);
    }

    test('第二个域复制失败：已落地的第一个域一并撤回，书库不动', () async {
      final ({String oldRoot, String newRoot, String mangaDir}) fx =
          await twoDomains();
      // music 目标已存在 → 走合并复制；目标里同名位置是目录 → 文件改名失败。
      Directory(
        p.join(fx.newRoot, 'music', 'p', 'a.flac'),
      ).createSync(recursive: true);

      final DownloadRootMoveReport report = await DownloadRootMigrator(
        database: db,
      ).move(oldRoot: fx.oldRoot, newRoot: fx.newRoot);

      expect(report.failure, DownloadRootMoveFailure.copyFailed);
      expect(report.movedDomains, isEmpty);
      expectUntouched(fx);
      expect((await db.getEpubBook('k1'))!.extractDir, fx.mangaDir);
    });

    test('改书库失败：事务回滚，全部域撤回', () async {
      final ({String oldRoot, String newRoot, String mangaDir}) fx =
          await twoDomains();
      DataRootMigrator.debugFailMidRebase = true;
      addTearDown(() => DataRootMigrator.debugFailMidRebase = false);

      final DownloadRootMoveReport report = await DownloadRootMigrator(
        database: db,
      ).move(oldRoot: fx.oldRoot, newRoot: fx.newRoot);

      expect(report.failure, DownloadRootMoveFailure.databaseFailed);
      expectUntouched(fx);
      expect(Directory(p.join(fx.newRoot, 'music')).existsSync(), isFalse);
      expect((await db.getEpubBook('k1'))!.extractDir, fx.mangaDir);
    });
  });

  test('备份带走下载根里的在线漫画，恢复到本机下载根并改写 extractDir', () async {
    final String srcDbDir = p.join(temp.path, 'src-db');
    final String srcBooks = p.join(temp.path, 'src-books');
    final String srcManga = p.join(temp.path, 'src-dl', 'manga', 'mihon-k');
    Directory(srcDbDir).createSync(recursive: true);
    Directory(srcBooks).createSync(recursive: true);
    File(p.join(srcManga, 'chapters', 'c', 'manga.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"pages":[]}');
    File(p.join(srcManga, 'manga.json')).writeAsStringSync('{"pages":[]}');
    final FushiDatabase srcDb = FushiDatabase(srcDbDir);
    await srcDb.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'mihon-k',
        title: 'Online',
        epubPath: 'manga.json',
        extractDir: srcManga,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 0,
        format: const Value<String>('manga'),
      ),
    );
    final String zipPath = p.join(temp.path, 'backup.zip');
    await BackupService(
      db: srcDb,
      dbDirectory: srcDbDir,
      appVersion: '1.0.0',
      booksRootDirectory: srcBooks,
    ).createBackup(zipPath);
    await srcDb.close();

    final InputFileStream input = InputFileStream(zipPath);
    final Archive archive = ZipDecoder().decodeBuffer(input);
    expect(
      archive.findFile('download_manga/mihon-k/chapters/c/manga.json'),
      isNotNull,
    );
    await input.close();

    // 换机：源设备的下载根在本机不存在（同机恢复时原路径有效，行不改写）。
    Directory(p.join(temp.path, 'src-dl')).deleteSync(recursive: true);
    final String dstDbDir = p.join(temp.path, 'dst-db');
    final String dstRoot = p.join(temp.path, 'dst-dl');
    Directory(dstDbDir).createSync(recursive: true);
    DownloadRoot.install(() async => DownloadLayout(root: dstRoot));
    await BackupRestoreService.restoreBackup(
      dbDirectory: dstDbDir,
      zipPath: zipPath,
      booksRootDirectory: p.join(temp.path, 'dst-books'),
    );

    final String expected = p.join(dstRoot, 'manga', 'mihon-k');
    expect(
      File(p.join(expected, 'chapters', 'c', 'manga.json')).existsSync(),
      isTrue,
    );
    final FushiDatabase dstDb = FushiDatabase(dstDbDir);
    try {
      expect((await dstDb.getEpubBook('mihon-k'))!.extractDir, expected);
    } finally {
      await dstDb.close();
    }
  });
}

class _NoCoverAdapter implements OnlineMangaRuntimeAdapter {
  @override
  OnlineMangaRuntimeKind get kind => OnlineMangaRuntimeKind.mihon;

  @override
  bool get isSupportedOnThisPlatform => true;

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async => 'Fixture';

  @override
  Future<OnlineMangaRefreshResult> refresh(
    OnlineMangaLibraryEntry entry,
  ) async =>
      OnlineMangaRefreshResult(series: entry.series, chapters: entry.chapters);

  @override
  Future<List<OnlineMangaPageRef>> resolveChapterPages({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  }) => throw UnimplementedError();

  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) =>
      throw UnimplementedError();

  @override
  Future<List<int>> fetchCover(OnlineMangaLibraryEntry entry, String url) =>
      throw UnimplementedError();
}
