// 导入目录的归属与残留（BUG-4841 / BUG-4837）。
//
//  - BUG-4841：解析失败时 `.tmp-*` 暂存目录要收掉；上个进程留下的 `.tmp-*` /
//    `.bak-*` 在首次导入前清扫，`.bak-*` 不能盲删。
//  - BUG-4837：并发导入同名书，「重取快照 → 挪目录 → 插行」在落位锁内串行，谁也
//    不会把别人的书目录换掉 / 删掉。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';
import 'package:path/path.dart' as p;

Uint8List _minimalEpub(String title, {String body = 'Hello.'}) {
  final Archive archive = Archive();
  void add(String name, String content) {
    final List<int> bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('mimetype', 'application/epub+zip');
  add('META-INF/container.xml', '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''');
  add('OEBPS/content.opf', '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>$title</dc:title>
  </metadata>
  <manifest>
    <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="chapter"/>
  </spine>
</package>
''');
  add('OEBPS/chapter.xhtml', '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>Chapter</title></head>
  <body><p>$body</p></body>
</html>
''');

  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  late Directory tempRoot;
  late String booksRoot;
  late FushiDatabase db;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('epub_dir_ownership_');
    EpubStorage.debugBaseDirectoryOverride = tempRoot.path;
    booksRoot = p.join(tempRoot.path, 'fushi_books');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    EpubStorage.debugBaseDirectoryOverride = null;
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  List<String> rootNames() => Directory(booksRoot).existsSync()
      ? (Directory(booksRoot)
            .listSync(followLinks: false)
            .map((FileSystemEntity e) => p.basename(e.path))
            .toList()
          ..sort())
      : <String>[];

  void writeFile(String rel, String content) {
    final File f = File(p.join(booksRoot, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  String readFile(String rel) =>
      File(p.join(booksRoot, rel)).readAsStringSync();

  group('BUG-4841 解析失败不留暂存目录', () {
    test('importFromPath：不是 zip 的文件解析失败后书库根下没有 .tmp-*', () async {
      final File bad = File(p.join(tempRoot.path, 'bad.epub'))
        ..writeAsStringSync('this is not a zip archive');

      await expectLater(
        EpubImporter.importFromPath(
          db: db,
          filePath: bad.path,
          fileName: 'bad.epub',
        ),
        throwsA(isA<Object>()),
      );

      expect(rootNames(), isEmpty);
      expect(await db.getAllEpubBooks(), isEmpty);
    });

    test('import(bytes)：zip 里没有 container.xml，解析失败后没有 .tmp-*', () async {
      final Archive archive = Archive();
      final List<int> junk = utf8.encode('junk');
      archive.addFile(ArchiveFile('readme.txt', junk.length, junk));
      final Uint8List bytes = Uint8List.fromList(ZipEncoder().encode(archive)!);

      await expectLater(
        EpubImporter.import(db: db, bytes: bytes, fileName: 'junk.epub'),
        throwsA(isA<Object>()),
      );

      expect(rootNames(), isEmpty);
      expect(await db.getAllEpubBooks(), isEmpty);
    });
  });

  group('BUG-4841 导入残留清扫', () {
    test('.tmp-* 直接删；本进程自己建的暂存目录不碰', () async {
      writeFile(p.join('.tmp-1-0', 'x.txt'), 'stale');
      final String own = await EpubStorage.createStagingDirectory();
      File(p.join(own, 'x.txt')).writeAsStringSync('in flight');

      await EpubStorage.sweepImportResidue(
        booksRoot: booksRoot,
        liveExtractDirs: const <String>[],
      );

      expect(rootNames(), <String>[p.basename(own)]);
      expect(File(p.join(own, 'x.txt')).readAsStringSync(), 'in flight');
    });

    test('目标在场 → 删 bak；目标不在 → bak 改回目标（唯一副本不能丢）', () async {
      writeFile(p.join('在场', 'new.txt'), 'new');
      writeFile(p.join('在场.bak-1700000000100', 'old.txt'), 'old');
      writeFile(p.join('丢了.bak-1700000000100', 'only.txt'), 'only copy');

      await EpubStorage.sweepImportResidue(
        booksRoot: booksRoot,
        liveExtractDirs: const <String>[],
      );

      expect(rootNames(), <String>['丢了', '在场']);
      expect(readFile(p.join('在场', 'new.txt')), 'new');
      expect(readFile(p.join('丢了', 'only.txt')), 'only copy');
    });

    test('目标带未完成标记（拷贝回退拷到一半）→ 丢掉半成品，bak 改回去', () async {
      writeFile(p.join('书', EpubStorage.kIncompleteMarkerFileName), '');
      writeFile(p.join('书', 'half.txt'), 'half');
      writeFile(p.join('书.bak-1700000000100', 'full.txt'), 'full');

      await EpubStorage.sweepImportResidue(
        booksRoot: booksRoot,
        // 就地重建的目标正是活行自己的目录：照样要还原。
        liveExtractDirs: <String>[p.join(booksRoot, '书')],
      );

      expect(rootNames(), <String>['书']);
      expect(readFile(p.join('书', 'full.txt')), 'full');
      expect(File(p.join(booksRoot, '书', 'half.txt')).existsSync(), isFalse);
    });

    test('同一目标多份 bak：最新那份改回去，其余删掉', () async {
      writeFile(p.join('书.bak-1700000000100', 'v.txt'), 'older');
      writeFile(p.join('书.bak-1700000000200', 'v.txt'), 'newest');

      await EpubStorage.sweepImportResidue(
        booksRoot: booksRoot,
        liveExtractDirs: const <String>[],
      );

      expect(rootNames(), <String>['书']);
      expect(readFile(p.join('书', 'v.txt')), 'newest');
    });

    test('活行的目录哪怕名字长成 x.bak-<13 位毫秒戳> 也不动', () async {
      writeFile(p.join('x.bak-1700000000123', 'book.txt'), 'a real book');

      await EpubStorage.sweepImportResidue(
        booksRoot: booksRoot,
        liveExtractDirs: <String>[p.join(booksRoot, 'x.bak-1700000000123')],
      );

      expect(rootNames(), <String>['x.bak-1700000000123']);
    });

    test('带未完成标记、没有 bak 的无主目录删掉；普通孤儿目录不动', () async {
      writeFile(p.join('半本', EpubStorage.kIncompleteMarkerFileName), '');
      writeFile(p.join('半本', 'half.txt'), 'half');
      writeFile(p.join('孤儿', 'book.txt'), 'recoverable');

      await EpubStorage.sweepImportResidue(
        booksRoot: booksRoot,
        liveExtractDirs: const <String>[],
      );

      expect(rootNames(), <String>['孤儿']);
    });

    test('活行的目录名以 .tmp- 开头（书名如此）不当暂存删', () async {
      // 书名净化不处理前导点：`.tmp-notes` / `.tmp-1-0` 都可以是真书的 bookKey。
      writeFile(p.join('.tmp-notes', 'book.txt'), 'a real book');
      writeFile(p.join('.tmp-1-0', 'book.txt'), 'another real book');
      writeFile(p.join('.tmp-2-0', 'x.txt'), 'stale staging');

      final List<String> actions = await EpubStorage.sweepImportResidue(
        booksRoot: booksRoot,
        liveExtractDirs: <String>[
          p.join(booksRoot, '.tmp-notes'),
          p.join(booksRoot, '.tmp-1-0'),
        ],
      );

      expect(actions, <String>['deleteStaging .tmp-2-0']);
      expect(rootNames(), <String>['.tmp-1-0', '.tmp-notes']);
      expect(readFile(p.join('.tmp-notes', 'book.txt')), 'a real book');
      expect(readFile(p.join('.tmp-1-0', 'book.txt')), 'another real book');
    });

    test('只是以 .tmp- 开头、不是暂存名形状的无主目录不删', () async {
      writeFile(p.join('.tmp-notes', 'book.txt'), 'orphan');

      final List<String> actions = await EpubStorage.sweepImportResidue(
        booksRoot: booksRoot,
        liveExtractDirs: const <String>[],
      );

      expect(actions, isEmpty);
      expect(rootNames(), <String>['.tmp-notes']);
    });

    test('书名以 .bak-<短数字> 结尾的孤儿目录不当 bak：不删、不改名', () async {
      // 让位用的 bak 一律是 13 位毫秒戳；`X.bak-2` 是一本书名如此的孤儿书。
      writeFile(p.join('X', 'book.txt'), 'x');
      writeFile(p.join('X.bak-2', 'book.txt'), 'orphan named X.bak-2');
      writeFile(p.join('Y.bak-2', 'book.txt'), 'orphan named Y.bak-2');

      final List<String> actions = await EpubStorage.sweepImportResidue(
        booksRoot: booksRoot,
        liveExtractDirs: const <String>[],
      );

      expect(actions, isEmpty);
      expect(rootNames(), <String>['X', 'X.bak-2', 'Y.bak-2']);
      expect(readFile(p.join('X.bak-2', 'book.txt')), 'orphan named X.bak-2');
    });

    test('两趟清扫同时发起：排队跑，每样残留只处置一次', () async {
      writeFile(p.join('.tmp-1-0', 'a', 'x.txt'), 'stale');
      writeFile(p.join('在场', 'new.txt'), 'new');
      writeFile(p.join('在场.bak-1700000000100', 'old.txt'), 'old');
      writeFile(p.join('丢了.bak-1700000000100', 'only.txt'), 'only copy');
      writeFile(p.join('半本', EpubStorage.kIncompleteMarkerFileName), '');
      writeFile(p.join('半本', 'sub', 'half.txt'), 'half');

      final Future<List<String>> first = EpubStorage.sweepImportResidue(
        booksRoot: booksRoot,
        liveExtractDirs: const <String>[],
      );
      final Future<List<String>> second = EpubStorage.sweepImportResidue(
        booksRoot: booksRoot,
        liveExtractDirs: const <String>[],
      );

      expect((await first).toSet(), <String>{
        'deleteStaging .tmp-1-0',
        'deleteBak 在场.bak-1700000000100',
        'restoreBak 丢了.bak-1700000000100',
        'deleteIncomplete 半本',
      });
      expect(await second, isEmpty, reason: '第二趟看到的是第一趟收完之后的书库根');
      expect(rootNames(), <String>['丢了', '在场']);
      expect(readFile(p.join('丢了', 'only.txt')), 'only copy');
    });

    test('清扫不在调用栈里同步递归删：返回 Future 时残留还在', () async {
      writeFile(p.join('.tmp-1-0', 'x.txt'), 'stale');

      final Future<List<String>> sweep = EpubStorage.sweepImportResidue(
        booksRoot: booksRoot,
        liveExtractDirs: const <String>[],
      );

      expect(rootNames(), <String>['.tmp-1-0']);
      await sweep;
      expect(rootNames(), isEmpty);
    });

    test('首次导入之前自动清扫一次', () async {
      writeFile(p.join('.tmp-1-0', 'x.txt'), 'stale');
      writeFile(p.join('旧书.bak-1700000000100', 'only.txt'), 'only copy');
      final File epub = File(p.join(tempRoot.path, 'book.epub'))
        ..writeAsBytesSync(_minimalEpub('新书'));

      await EpubImporter.importFromPath(
        db: db,
        filePath: epub.path,
        fileName: 'book.epub',
      );

      expect(rootNames(), <String>['新书', '旧书']);
      expect(readFile(p.join('旧书', 'only.txt')), 'only copy');
    });

    test('拷贝回退落位完成后不留未完成标记', () {
      writeFile(p.join('.tmp-9-9', 'a', 'b.txt'), 'content');

      final String placed = EpubStorage.moveDirIntoPlace(
        srcDir: Directory(p.join(booksRoot, '.tmp-9-9')),
        targetDir: p.join(booksRoot, '书'),
        liveExtractDirs: const <String>[],
        forceCopyFallback: true,
      );

      expect(
        File(
          p.join(placed, EpubStorage.kIncompleteMarkerFileName),
        ).existsSync(),
        isFalse,
      );
      expect(readFile(p.join('书', 'a', 'b.txt')), 'content');
      expect(rootNames(), <String>['书']);
    });
  });

  group('BUG-4837 并发导入同名书', () {
    Future<void> expectIntactBook(EpubBookRow row, String body) async {
      expect(
        Directory(row.extractDir).existsSync(),
        isTrue,
        reason: '${row.bookKey} 的行指向的目录必须还在',
      );
      expect(
        File(
          p.join(row.extractDir, 'OEBPS', 'chapter.xhtml'),
        ).readAsStringSync(),
        contains(body),
        reason: '${row.bookKey} 的目录里必须是它自己那一份内容',
      );
    }

    test('suffix 策略：两本都入库，各占各的目录、内容不串', () async {
      const String title = '同名の本';
      final File a = File(p.join(tempRoot.path, 'a.epub'))
        ..writeAsBytesSync(_minimalEpub(title, body: 'AAA'));
      final File b = File(p.join(tempRoot.path, 'b.epub'))
        ..writeAsBytesSync(_minimalEpub(title, body: 'BBB'));

      final List<String> keys = await Future.wait(<Future<String>>[
        EpubImporter.importFromPath(db: db, filePath: a.path, fileName: 'a'),
        EpubImporter.importFromPath(db: db, filePath: b.path, fileName: 'b'),
      ]);

      expect(keys.toSet(), hasLength(2));
      final List<EpubBookRow> rows = await db.getAllEpubBooks();
      expect(rows, hasLength(2));
      expect(
        rows.map((EpubBookRow r) => p.canonicalize(r.extractDir)).toSet(),
        hasLength(2),
      );
      for (final EpubBookRow row in rows) {
        await expectIntactBook(row, row.epubPath == 'a' ? 'AAA' : 'BBB');
      }
      expect(
        rootNames().where((String n) => n.startsWith('.')),
        isEmpty,
        reason: '不留 .tmp-* / .bak-*',
      );
    });

    test('skip 策略：一本入库、另一本按重复跳过，赢家的目录原封不动', () async {
      const String title = '同名の本';
      final File a = File(p.join(tempRoot.path, 'a.epub'))
        ..writeAsBytesSync(_minimalEpub(title, body: 'AAA'));
      final File b = File(p.join(tempRoot.path, 'b.epub'))
        ..writeAsBytesSync(_minimalEpub(title, body: 'BBB'));

      Future<Object?> run(File f, String name) async {
        try {
          return await EpubImporter.importFromPath(
            db: db,
            filePath: f.path,
            fileName: name,
            policy: const DuplicatePolicy.skip(),
          );
        } on DuplicateImportCancelledException catch (e) {
          return e;
        }
      }

      final List<Object?> results = await Future.wait(<Future<Object?>>[
        run(a, 'a'),
        run(b, 'b'),
      ]);

      expect(results.whereType<String>(), hasLength(1));
      expect(
        results.whereType<DuplicateImportCancelledException>(),
        hasLength(1),
      );
      final List<EpubBookRow> rows = await db.getAllEpubBooks();
      expect(rows, hasLength(1));
      await expectIntactBook(
        rows.single,
        rows.single.epubPath == 'a' ? 'AAA' : 'BBB',
      );
      expect(rootNames(), <String>[sanitizeTtuFilename(title)]);
    });

    test('ask 策略：同名弹窗不在落位锁里——没人点的弹窗不卡住别的导入', () async {
      const String title = '既にある本';
      final File first = File(p.join(tempRoot.path, 'first.epub'))
        ..writeAsBytesSync(_minimalEpub(title));
      await EpubImporter.importFromPath(
        db: db,
        filePath: first.path,
        fileName: 'first',
      );

      final Completer<DuplicateChoice> answer = Completer<DuplicateChoice>();
      final Completer<void> asked = Completer<void>();
      final Future<String> interactive = EpubImporter.importFromPath(
        db: db,
        filePath: first.path,
        fileName: 'again',
        policy: DuplicatePolicy.ask((String proposed) {
          asked.complete();
          return answer.future;
        }),
      );
      await asked.future;

      // 弹窗还开着：后台的另一本书照常导入完成。
      final File other = File(p.join(tempRoot.path, 'other.epub'))
        ..writeAsBytesSync(_minimalEpub('別の本'));
      final String otherKey = await EpubImporter.importFromPath(
        db: db,
        filePath: other.path,
        fileName: 'other',
      ).timeout(const Duration(seconds: 30));
      expect(otherKey, sanitizeTtuFilename('別の本'));

      answer.complete(DuplicateChoice.suffix);
      expect(await interactive, sanitizeTtuFilename('$title (2)'));
      expect(await db.getAllEpubBooks(), hasLength(3));
    });

    test('锁外定下的书名键在拿到锁之前被别人占了：锁内重取快照发现，重新定夺', () async {
      // 不靠两个 isolate 的时序碰运气：A 进了 place（持锁）就停住，B 此时取到的
      // 快照里还没有 A 的行，于是也定下同一个书名键、排在锁后面。A 插行放锁后，
      // B 必须在锁内看见 A 的行并改用「(2)」，而不是拿着过期结论去挪目录。
      final Completer<void> aInPlace = Completer<void>();
      final Completer<void> releaseA = Completer<void>();
      final List<String> placedKeys = <String>[];

      Future<String> run({required bool hold}) =>
          EpubImporter.placeUnderResolvedTitle<String>(
            db: db,
            proposedTitle: '同名',
            policy: const DuplicatePolicy.suffix(),
            format: BookFormat.epub.dbValue,
            // 两本书的书目录都真实落盘（见下），同名行内容完好，不该走就地恢复。
            restore: (EpubBookRow existing) async =>
                fail('content of ${existing.bookKey} is intact; no restore'),
            place:
                (
                  String storedTitle,
                  String bookKey,
                  List<EpubBookMeta> liveBooks,
                ) async {
                  if (hold) {
                    aInPlace.complete();
                    await releaseA.future;
                  }
                  placedKeys.add(bookKey);
                  // 书目录落成一本完好的 EPUB 解压树：否则这行在后来者眼里是「内容
                  // 已丢的同名书」，会被就地恢复而不是加后缀（UXtYShn4Yj）。
                  final String dir = p.join(booksRoot, bookKey);
                  File(p.join(dir, 'META-INF', 'container.xml'))
                    ..createSync(recursive: true)
                    ..writeAsStringSync('<container/>');
                  return db.insertEpubBook(
                    EpubBooksCompanion.insert(
                      bookKey: bookKey,
                      title: storedTitle,
                      epubPath: 'x.epub',
                      extractDir: p.join(booksRoot, bookKey),
                      chapterCount: 1,
                      chaptersJson: '[]',
                      importedAt: 1,
                    ),
                  );
                },
          );

      final Future<String> a = run(hold: true);
      await aInPlace.future;
      final Future<String> b = run(hold: false);
      // 让 B 跑完锁外的定夺、停在锁上。
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(placedKeys, isEmpty);
      releaseA.complete();

      expect(await a, '同名');
      expect(await b, '同名 (2)');
      expect(placedKeys, <String>['同名', '同名 (2)']);
    });

    test('withBookPlacementLock 串行执行，前一个抛异常也会放锁', () async {
      final List<String> log = <String>[];
      final Completer<void> gate = Completer<void>();
      final Future<void> first = EpubStorage.withBookPlacementLock(() async {
        log.add('first:start');
        await gate.future;
        log.add('first:end');
        throw StateError('boom');
      });
      final Future<void> second = EpubStorage.withBookPlacementLock(() async {
        log.add('second');
      });
      await Future<void>.delayed(Duration.zero);
      expect(log, <String>['first:start']);
      gate.complete();
      await expectLater(first, throwsStateError);
      await second;
      expect(log, <String>['first:start', 'first:end', 'second']);
    });
  });

  group('落位锁与清扫队列不依赖上一个调用方的 zone', () {
    // widget 测试里每条用例一个 fake-async zone，用例结束后它不再跑微任务。排队若靠
    // 「上一个调用留下的 Future」，下一条用例里的导入就永远等不到轮次（PR #3693 的
    // CI：book_import_dialog_real_carrier_memo_test 第二次真实导入超时）。这里用一个
    // 手动泵微任务的 zone 复现「上一个调用方的 zone 停转」。
    test('前一个 zone 停转后，新的落位 / 清扫 / 首次清扫照常跑完', () async {
      Directory(booksRoot).createSync(recursive: true);
      final List<void Function()> parked = <void Function()>[];
      final Zone stalling = Zone.current.fork(
        specification: ZoneSpecification(
          scheduleMicrotask:
              (Zone self, ZoneDelegate parent, Zone zone, void Function() f) {
                parked.add(() => zone.run(f));
              },
        ),
      );

      int finishedInStallingZone = 0;
      stalling.run(() {
        unawaited(
          EpubStorage.withBookPlacementLock(() async {}).then((void _) {
            finishedInStallingZone += 1;
          }),
        );
        unawaited(
          EpubStorage.sweepImportResidue(
            booksRoot: booksRoot,
            liveExtractDirs: const <String>[],
          ).then((List<String> _) {
            finishedInStallingZone += 1;
          }),
        );
        unawaited(
          EpubStorage.ensureImportResidueSwept(
            () async => const <String>[],
          ).then((void _) {
            finishedInStallingZone += 1;
          }),
        );
      });
      while (parked.isNotEmpty) {
        parked.removeAt(0)();
      }
      expect(finishedInStallingZone, 3, reason: '前置：三个调用都在那个 zone 里跑完了');
      // 从这里起 `stalling` 不再泵微任务：之后排进 `parked` 的回调永远不会跑。

      const Duration limit = Duration(seconds: 10);
      bool placed = false;
      await EpubStorage.withBookPlacementLock(() async {
        placed = true;
      }).timeout(limit);
      expect(placed, isTrue);

      writeFile(p.join('.tmp-1-0', 'x.txt'), 'stale');
      expect(
        await EpubStorage.sweepImportResidue(
          booksRoot: booksRoot,
          liveExtractDirs: const <String>[],
        ).timeout(limit),
        <String>['deleteStaging .tmp-1-0'],
      );

      // 同一个书库根的首次清扫已经在停转的 zone 里做过：这里直接返回，不再去等它。
      await EpubStorage.ensureImportResidueSwept(
        () async => const <String>[],
      ).timeout(limit);
    });
  });
}
