// 拍板 83Fe7zQbhv：「一包书」的定性（按条目名）与整批导入（真 ArchiveUnpacker 解包：
// 明文 zip、AES 加密 zip、分卷 zip；口令取消；包里没有书；单本失败不拖垮整包）。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:fushi_engine/media/book_archive/book_archive_import.dart';
import 'package:fushi_engine/utils/archive/archive_unpacker.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const String _password = 'fushi-pw';

/// 依次作答的口令来源（null = 用户取消）。
final class _ScriptedPasswords implements ArchivePasswordProvider {
  _ScriptedPasswords(this.answers);

  final List<ArchivePasswordAnswer?> answers;
  int asked = 0;

  @override
  Future<ArchivePasswordAnswer?> ask(ArchivePasswordRequest request) async {
    asked++;
    return answers.isEmpty ? null : answers.removeAt(0);
  }

  @override
  Future<void> forget(String fingerprint) async {}

  @override
  Future<void> remember(String fingerprint, String password) async {}

  @override
  Future<String?> remembered(String fingerprint) async => null;
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('book_archive_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File writeZip(String name, Map<String, String> entries, {String? password}) {
    final Archive archive = Archive();
    entries.forEach((String entry, String content) {
      final List<int> bytes = utf8.encode(content);
      archive.addFile(ArchiveFile(entry, bytes.length, bytes));
    });
    final List<int> encoded = ZipEncoder(password: password).encode(archive)!;
    return File(p.join(tmp.path, name))..writeAsBytesSync(encoded);
  }

  group('bookArchiveNamesHaveBooks', () {
    test('EPUB / PDF 合集是书；带一两张封面的 TXT 合集也是书', () {
      expect(bookArchiveNamesHaveBooks(<String>['a.epub', 'b.epub']), isTrue);
      expect(bookArchiveNamesHaveBooks(<String>['x/scan.pdf']), isTrue);
      expect(
        bookArchiveNamesHaveBooks(<String>['1.txt', '2.txt', 'cover.jpg']),
        isTrue,
      );
    });

    test('漫画包夹一份 readme.txt 不是书；词典包不是书；只有 mac 元数据不是书', () {
      expect(
        bookArchiveNamesHaveBooks(<String>[
          for (int i = 0; i < 20; i++) 'p$i.png',
          'readme.txt',
        ]),
        isFalse,
      );
      expect(
        bookArchiveNamesHaveBooks(<String>[
          'index.json',
          'term_bank_1.json',
          'notes.txt',
        ]),
        isFalse,
      );
      expect(
        bookArchiveNamesHaveBooks(<String>['__MACOSX/._a.epub', '._b.txt']),
        isFalse,
      );
      expect(bookArchiveNamesHaveBooks(<String>['readme.html']), isFalse);
    });
  });

  group('looksLikeBookArchive', () {
    test('zip 读条目名定性（含加密 zip：条目名是明文）', () async {
      final File books = writeZip('books.zip', <String, String>{
        'a.epub': 'epub',
        'sub/b.txt': '本文',
      });
      final File enc = writeZip('enc.zip', <String, String>{
        'a.txt': '本文',
      }, password: _password);
      final File pages = writeZip('pages.zip', <String, String>{
        '001.png': 'png',
        '002.png': 'png',
      });
      expect(await looksLikeBookArchive(books.path), isTrue);
      expect(await looksLikeBookArchive(enc.path), isTrue);
      expect(await looksLikeBookArchive(pages.path), isFalse);
    });

    test('坏 zip 判不出 → false；7z 与分卷第一卷解开后再定性 → true', () async {
      final File junk = File(p.join(tmp.path, 'junk.zip'))
        ..writeAsStringSync('nope');
      expect(await looksLikeBookArchive(junk.path), isFalse);
      expect(await looksLikeBookArchive('/x/a.7z'), isTrue);
      expect(await looksLikeBookArchive('/x/a.zip.001'), isTrue);
      expect(await looksLikeBookArchive('/x/a.epub'), isFalse);
    });

    test('rar 经 7-Zip 列目录定性；没有 7-Zip 列不出名字 → 交解包后定性', () async {
      const String listing =
          '7-Zip\n\n--\nPath = x.rar\nType = Rar\n\n----------\n'
          'Path = 合集\nFolder = +\n\nPath = 合集\\一.txt\nFolder = -\n\n'
          'Path = 合集\\二.txt\nFolder = -\n';
      final ArchiveUnpacker unpacker = ArchiveUnpacker(
        sevenZipOverride: 'fake-7z',
        runProcess: (String exe, List<String> args, {String? stdin}) async =>
            ProcessResult(1, 0, listing, ''),
      );
      expect(await unpacker.listEntryNamesWithCli('/x/x.rar'), <String>[
        '合集\\一.txt',
        '合集\\二.txt',
      ]);
      expect(
        await looksLikeBookArchive('/x/x.rar', unpacker: unpacker),
        isTrue,
      );
      expect(
        await looksLikeBookArchive(
          '/x/x.rar',
          unpacker: ArchiveUnpacker(sevenZipOverride: ''),
        ),
        isTrue,
      );
    });

    test('rar 列目录时 7-Zip 子进程起不来（ProcessException）：不抛，按列不出名字交解包后定性', () async {
      final ArchiveUnpacker unpacker = ArchiveUnpacker(
        sevenZipOverride: r'C:\gone\7z.exe',
        runProcess: (String exe, List<String> args, {String? stdin}) async =>
            throw const ProcessException(
              r'C:\gone\7z.exe',
              <String>['l'],
              'The system cannot find the file specified.',
              2,
            ),
      );
      expect(await unpacker.listEntryNamesWithCli('/x/x.rar'), isNull);
      expect(
        await looksLikeBookArchive('/x/x.rar', unpacker: unpacker),
        isTrue,
      );
    });
  });

  group('BookArchiveImporter', () {
    late List<String> calls;
    late List<String> stagingDirs;

    BookArchiveImporter importer({ArchivePasswordProvider? passwords}) {
      int staging = 0;
      return BookArchiveImporter(
        importEpub: (String path) async {
          calls.add('epub:${p.basename(path)}');
          return 'key-${p.basename(path)}';
        },
        importText: (String path) async {
          calls.add('text:${p.basename(path)}');
          // 同名已在库：跳过。
          if (p.basename(path) == 'dup.txt') return null;
          return 'key-${p.basename(path)}';
        },
        importPdf: (String path) async {
          calls.add('pdf:${p.basename(path)}');
          // 与生产同形：`PdfImporter` 对零页 PDF 抛的是 StateError（Error，不是 Exception）。
          throw StateError('broken pdf');
        },
        createStagingDir: () async {
          final Directory dir = Directory(
            p.join(tmp.path, 'library', '.tmp-${staging++}'),
          )..createSync(recursive: true);
          stagingDirs.add(dir.path);
          return dir.path;
        },
        unpacker: ArchiveUnpacker(passwords: passwords),
      );
    }

    setUp(() {
      calls = <String>[];
      stagingDirs = <String>[];
    });

    void expectStagingCleaned() {
      for (final String dir in stagingDirs) {
        expect(Directory(dir).existsSync(), isFalse, reason: dir);
      }
    }

    test('一包多本：逐本导入、按路径排序、跳过附件与 mac 元数据，一份汇总', () async {
      final File zip = writeZip('合集.zip', <String, String>{
        'b/dup.txt': '重复',
        'a.epub': 'epub',
        'c.pdf': 'pdf',
        'readme.html': '<p>x</p>',
        '__MACOSX/._a.epub': 'meta',
        'cover.jpg': 'jpg',
      });
      final File loose = File(p.join(tmp.path, 'single.txt'))
        ..writeAsStringSync('本文');
      final List<BookArchiveImportProgress> progress =
          <BookArchiveImportProgress>[];
      final BookArchiveImportSummary summary = await importer().importAll(
        <String>[zip.path, loose.path],
        onProgress: progress.add,
      );
      expect(calls, <String>[
        'epub:a.epub',
        'text:dup.txt',
        'pdf:c.pdf',
        'text:single.txt',
      ]);
      expect(summary.importedCount, 2);
      expect(summary.skippedCount, 1);
      expect(summary.failedCount, 1);
      expect(summary.failedItems.single.name, p.join('合集.zip', 'c.pdf'));
      expect(summary.failedItems.single.error, contains('broken pdf'));
      expect(summary.hasProblems, isTrue);
      expect(progress.first.stage, BookArchiveImportStage.unpacking);
      expect(progress.last.done, 1);
      expect(progress.last.total, 2);
      expectStagingCleaned();
    });

    test('加密 zip：经口令来源要口令后解开导入', () async {
      final File zip = writeZip('enc.zip', <String, String>{
        'a.epub': 'epub',
      }, password: _password);
      final _ScriptedPasswords passwords = _ScriptedPasswords(
        <ArchivePasswordAnswer?>[const ArchivePasswordAnswer(_password)],
      );
      final BookArchiveImportSummary summary = await importer(
        passwords: passwords,
      ).importAll(<String>[zip.path]);
      expect(passwords.asked, 1);
      expect(calls, <String>['epub:a.epub']);
      expect(summary.importedCount, 1);
      expect(summary.hasProblems, isFalse);
      expectStagingCleaned();
    });

    test('口令取消 → 整包记进 unpackFailures，不导任何书', () async {
      final File zip = writeZip('enc.zip', <String, String>{
        'a.epub': 'epub',
      }, password: _password);
      final BookArchiveImportSummary summary = await importer(
        passwords: _ScriptedPasswords(<ArchivePasswordAnswer?>[]),
      ).importAll(<String>[zip.path]);
      expect(calls, isEmpty);
      expect(summary.unpackFailures.single.archiveName, 'enc.zip');
      expect(
        summary.unpackFailures.single.failure,
        ArchiveUnpackFailure.passwordCancelled,
      );
      expectStagingCleaned();
    });

    test('分卷 zip：从第一卷解开', () async {
      final File zip = writeZip('vol.zip', <String, String>{
        'a.txt': '本文' * 2000,
      });
      final List<int> bytes = zip.readAsBytesSync();
      zip.deleteSync();
      final int half = bytes.length ~/ 2;
      final String first = p.join(tmp.path, 'vol.zip.001');
      File(first).writeAsBytesSync(bytes.sublist(0, half));
      File(
        p.join(tmp.path, 'vol.zip.002'),
      ).writeAsBytesSync(bytes.sublist(half));
      final BookArchiveImportSummary summary = await importer().importAll(
        <String>[first],
      );
      expect(calls, <String>['text:a.txt']);
      expect(summary.importedCount, 1);
      expectStagingCleaned();
    });

    test('包里既没有书也没有页图 → archivesWithoutBooks', () async {
      final File zip = writeZip('misc.zip', <String, String>{
        'readme.html': '<p>x</p>',
        'index.json': '{}',
      });
      final BookArchiveImportSummary summary = await importer().importAll(
        <String>[zip.path],
      );
      expect(calls, isEmpty);
      expect(summary.archivesWithoutBooks, <String>['misc.zip']);
      expect(summary.mangaHandoffs, isEmpty);
      expect(summary.hasProblems, isTrue);
      expectStagingCleaned();
    });

    test('分卷第一卷解开是一包页图（夹一份 readme.txt）→ 交漫画导入：目录以包名命名、解一次、'
        '暂存归交接方删', () async {
      final File zip = writeZip('第1巻.zip', <String, String>{
        for (int i = 1; i <= 12; i++)
          'pages/${i.toString().padLeft(3, '0')}.jpg': 'jpg$i',
        'readme.txt': 'scan by x',
      });
      final List<int> bytes = zip.readAsBytesSync();
      zip.deleteSync();
      final int half = bytes.length ~/ 2;
      final String first = p.join(tmp.path, '第1巻.zip.001');
      File(first).writeAsBytesSync(bytes.sublist(0, half));
      File(
        p.join(tmp.path, '第1巻.zip.002'),
      ).writeAsBytesSync(bytes.sublist(half));

      int extracts = 0;
      final ArchiveUnpacker unpacker = ArchiveUnpacker();
      final BookArchiveImporter counting = BookArchiveImporter(
        importEpub: (String path) async => fail('not a book: $path'),
        importText: (String path) async => fail('not a book: $path'),
        importPdf: (String path) async => fail('not a book: $path'),
        createStagingDir: () async {
          extracts++;
          final Directory dir = Directory(
            p.join(tmp.path, 'library', '.tmp-$extracts'),
          )..createSync(recursive: true);
          stagingDirs.add(dir.path);
          return dir.path;
        },
        unpacker: unpacker,
      );
      final BookArchiveImportSummary summary = await counting.importAll(
        <String>[first],
      );

      expect(extracts, 1, reason: '只解一次');
      expect(summary.items, isEmpty);
      expect(summary.archivesWithoutBooks, isEmpty);
      expect(summary.hasProblems, isFalse);
      expect(summary.onlyMangaHandoffs, isTrue);
      final BookArchiveMangaHandoff handoff = summary.mangaHandoffs.single;
      expect(handoff.archiveName, '第1巻.zip.001');
      expect(p.basename(handoff.directory), '第1巻');
      expect(p.isWithin(handoff.stagingRoot, handoff.directory), isTrue);
      final List<String> pages = <String>[
        for (final FileSystemEntity e in Directory(
          handoff.directory,
        ).listSync(recursive: true))
          if (e is File) p.basename(e.path),
      ]..sort();
      expect(pages.where((String n) => n.endsWith('.jpg')), hasLength(12));
      // 交接后暂存还在（漫画导入要从这里拷页图），交接方 discard 才删。
      expect(Directory(handoff.directory).existsSync(), isTrue);
      await handoff.discard();
      expectStagingCleaned();
    });

    test('已交接一包漫画后中途抛出（下一个包建暂存失败）：汇总到不了调用方，'
        '已交接的暂存就地删掉再抛', () async {
      final File zip = writeZip('第2巻.zip', <String, String>{
        for (int i = 1; i <= 4; i++)
          'p/${i.toString().padLeft(3, '0')}.jpg': 'jpg$i',
      });
      final List<int> bytes = zip.readAsBytesSync();
      zip.deleteSync();
      final int half = bytes.length ~/ 2;
      final String first = p.join(tmp.path, '第2巻.zip.001');
      File(first).writeAsBytesSync(bytes.sublist(0, half));
      File(
        p.join(tmp.path, '第2巻.zip.002'),
      ).writeAsBytesSync(bytes.sublist(half));

      int created = 0;
      final BookArchiveImporter failing = BookArchiveImporter(
        importEpub: (String path) async => fail('not a book: $path'),
        importText: (String path) async => fail('not a book: $path'),
        importPdf: (String path) async => fail('not a book: $path'),
        createStagingDir: () async {
          if (created++ > 0) {
            throw const FileSystemException('disk full');
          }
          final Directory dir = Directory(p.join(tmp.path, 'library', '.tmp-0'))
            ..createSync(recursive: true);
          stagingDirs.add(dir.path);
          return dir.path;
        },
        unpacker: ArchiveUnpacker(),
      );

      await expectLater(
        failing.importAll(<String>[first, p.join(tmp.path, 'next.7z')]),
        throwsA(isA<FileSystemException>()),
      );
      expect(created, 2);
      expect(stagingDirs, hasLength(1));
      expectStagingCleaned();
    });
  });
}
