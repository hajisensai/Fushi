// BUG-564: EpubImporter._persistParsed used a bare `srcDir.renameSync(realDir)`
// to move the freshly-extracted `.tmp-<ts>` dir to the key-named book dir.
// When the target dir already exists non-empty (orphan leftover of a crashed
// import or of a failed post-delete disk cleanup), Linux rename(2) throws
// ENOTEMPTY (errno 39) and the whole import fails -- the reported symptom is
// Android failing to download a remote peer book it had before.
//
// Covered here at two levels:
//  (1) [EpubImporter.moveExtractedDirIntoPlace] unit semantics: plain rename /
//      atomic replace of an unowned dir / interrupted replace rolls back /
//      dirs owned by a live row are never touched (new book -> `~n` sibling).
//  (2) End-to-end through the real [EpubImporter.importFromPath] with an
//      in-memory DB: a stale orphan dir at the target key no longer fails the
//      import (the original failure path of BUG-564).

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/epub/epub_importer.dart';
import 'package:hibiki/src/epub/epub_storage.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

HibikiDatabase _memDb() => HibikiDatabase.forTesting(NativeDatabase.memory());

Uint8List _encodeArchive(List<ArchiveFile> files) {
  final Archive archive = Archive();
  for (final ArchiveFile f in files) {
    archive.addFile(f);
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

ArchiveFile _textFile(String name, String content) {
  final List<int> bytes = utf8.encode(content);
  return ArchiveFile(name, bytes.length, bytes);
}

const String _containerXml = '<?xml version="1.0" encoding="UTF-8"?>'
    '<container version="1.0" '
    'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
    '<rootfiles><rootfile full-path="OEBPS/content.opf" '
    'media-type="application/oebps-package+xml"/></rootfiles></container>';

String _contentOpf(String title) => '<?xml version="1.0" encoding="UTF-8"?>'
    '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
    'unique-identifier="book-id">'
    '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
    '<dc:title>$title</dc:title></metadata>'
    '<manifest><item id="chapter" href="chapter.xhtml" '
    'media-type="application/xhtml+xml"/></manifest>'
    '<spine><itemref idref="chapter"/></spine></package>';

const String _chapterXhtml = '<?xml version="1.0" encoding="UTF-8"?>'
    '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>C</title></head>'
    '<body><p>Hello world.</p></body></html>';

void _writeEpub(String path, String title) {
  final Uint8List bytes = _encodeArchive(<ArchiveFile>[
    _textFile('META-INF/container.xml', _containerXml),
    _textFile('OEBPS/content.opf', _contentOpf(title)),
    _textFile('OEBPS/chapter.xhtml', _chapterXhtml),
  ]);
  File(path).writeAsBytesSync(bytes);
}

/// Creates a directory containing one marker file, returning the marker path.
String _seedDir(String dir, String marker) {
  Directory(dir).createSync(recursive: true);
  final String markerPath = p.join(dir, marker);
  File(markerPath).writeAsStringSync(marker);
  return markerPath;
}

List<String> _bakSiblings(String targetDir) {
  final Directory parent = Directory(p.dirname(targetDir));
  return parent
      .listSync()
      .map((FileSystemEntity e) => e.path)
      .where((String path) => p.basename(path).contains('.bak-'))
      .toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EpubImporter.moveExtractedDirIntoPlace (BUG-564)', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bug564_move_');
    });
    tearDown(() {
      try {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('target missing: plain rename', () {
      final String src = p.join(tmp.path, '.tmp-1');
      _seedDir(src, 'fresh.txt');
      final String target = p.join(tmp.path, 'Book');

      final String result = EpubImporter.moveExtractedDirIntoPlace(
        srcDir: Directory(src),
        targetDir: target,
        liveExtractDirs: const <String>[],
      );

      expect(result, target);
      expect(File(p.join(target, 'fresh.txt')).existsSync(), isTrue);
      expect(Directory(src).existsSync(), isFalse);
    });

    test('unowned non-empty target: atomically replaced, no .bak leftover', () {
      final String src = p.join(tmp.path, '.tmp-1');
      _seedDir(src, 'fresh.txt');
      final String target = p.join(tmp.path, 'Book');
      _seedDir(target, 'stale.txt');

      final String result = EpubImporter.moveExtractedDirIntoPlace(
        srcDir: Directory(src),
        targetDir: target,
        // A live row pointing elsewhere must not protect this orphan.
        liveExtractDirs: <String>[p.join(tmp.path, 'OtherBook'), ''],
      );

      expect(result, target);
      expect(File(p.join(target, 'fresh.txt')).existsSync(), isTrue,
          reason: 'fresh download content must win');
      expect(File(p.join(target, 'stale.txt')).existsSync(), isFalse,
          reason: 'orphan leftover content must be gone');
      expect(_bakSiblings(target), isEmpty,
          reason: 'the .bak staging dir must be cleaned up');
    });

    test('interrupted replace rolls the previous dir back', () {
      // Simulate the move failing mid-replace: the source dir vanishes after
      // the existence check (renameSync throws). The pre-existing target must
      // be restored from its .bak, not lost.
      final String src = p.join(tmp.path, '.tmp-1');
      final String target = p.join(tmp.path, 'Book');
      _seedDir(target, 'stale.txt');

      expect(
        () => EpubImporter.moveExtractedDirIntoPlace(
          srcDir: Directory(src), // does not exist -> rename throws
          targetDir: target,
          liveExtractDirs: const <String>[],
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(File(p.join(target, 'stale.txt')).existsSync(), isTrue,
          reason: 'rollback must restore the previous directory');
      expect(_bakSiblings(target), isEmpty,
          reason: 'rollback must not leave the .bak behind');
    });

    test('target owned by a live row: untouched, new book gets ~n sibling', () {
      final String src = p.join(tmp.path, '.tmp-1');
      _seedDir(src, 'fresh.txt');
      final String target = p.join(tmp.path, 'Book');
      _seedDir(target, 'owned.txt');

      final String result = EpubImporter.moveExtractedDirIntoPlace(
        srcDir: Directory(src),
        targetDir: target,
        // The extract_dir column is the truth: some live book lives in the
        // key-named dir (legacy naming) -> never replace it.
        liveExtractDirs: <String>[target],
      );

      expect(result, '$target~2');
      expect(File(p.join(target, 'owned.txt')).existsSync(), isTrue,
          reason: 'a live book directory must never be touched');
      expect(File(p.join('$target~2', 'fresh.txt')).existsSync(), isTrue);
    });

    test('owned target with ~2 already taken falls through to ~3', () {
      final String src = p.join(tmp.path, '.tmp-1');
      _seedDir(src, 'fresh.txt');
      final String target = p.join(tmp.path, 'Book');
      _seedDir(target, 'owned.txt');
      _seedDir('$target~2', 'other.txt');

      final String result = EpubImporter.moveExtractedDirIntoPlace(
        srcDir: Directory(src),
        targetDir: target,
        liveExtractDirs: <String>[target],
      );

      expect(result, '$target~3');
      expect(File(p.join('$target~3', 'fresh.txt')).existsSync(), isTrue);
    });
  });

  // TODO-1286: the `.tmp-<ts>` -> book-dir move must survive a platform that
  // rejects rename(2) (Android fuse/sdcardfs / custom data root on another
  // volume). moveExtractedDirIntoPlace routes every move through the
  // copy+delete fallback; `forceCopyFallback: true` exercises that branch
  // deterministically (real rename failures are not portably reproducible).
  group(
      'EpubImporter.moveExtractedDirIntoPlace copy+delete fallback (TODO-1286)',
      () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('todo1286_move_');
    });
    tearDown(() {
      try {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('target missing: recursive copy moves content and deletes source', () {
      final String src = p.join(tmp.path, '.tmp-1');
      _seedDir(src, 'top.txt');
      // A nested subdirectory + file to prove the copy recurses.
      _seedDir(p.join(src, 'OEBPS'), 'chapter.xhtml');
      final String target = p.join(tmp.path, 'Book');

      final String result = EpubImporter.moveExtractedDirIntoPlace(
        srcDir: Directory(src),
        targetDir: target,
        liveExtractDirs: const <String>[],
        forceCopyFallback: true,
      );

      expect(result, target);
      expect(File(p.join(target, 'top.txt')).existsSync(), isTrue);
      expect(
          File(p.join(target, 'OEBPS', 'chapter.xhtml')).existsSync(), isTrue,
          reason: 'nested content must be copied recursively');
      expect(Directory(src).existsSync(), isFalse,
          reason: 'source .tmp dir must be deleted after copy');
    });

    test('unowned non-empty target: replaced via copy, no .bak leftover', () {
      final String src = p.join(tmp.path, '.tmp-1');
      _seedDir(src, 'fresh.txt');
      final String target = p.join(tmp.path, 'Book');
      _seedDir(target, 'stale.txt');

      final String result = EpubImporter.moveExtractedDirIntoPlace(
        srcDir: Directory(src),
        targetDir: target,
        liveExtractDirs: <String>[p.join(tmp.path, 'OtherBook'), ''],
        forceCopyFallback: true,
      );

      expect(result, target);
      expect(File(p.join(target, 'fresh.txt')).existsSync(), isTrue,
          reason: 'fresh download content must win');
      expect(File(p.join(target, 'stale.txt')).existsSync(), isFalse,
          reason: 'orphan leftover content must be gone');
      expect(Directory(src).existsSync(), isFalse);
      expect(_bakSiblings(target), isEmpty,
          reason: 'the .bak staging dir must be cleaned up');
    });

    test('target owned by a live row: new book gets ~2 sibling via copy', () {
      final String src = p.join(tmp.path, '.tmp-1');
      _seedDir(src, 'fresh.txt');
      final String target = p.join(tmp.path, 'Book');
      _seedDir(target, 'owned.txt');

      final String result = EpubImporter.moveExtractedDirIntoPlace(
        srcDir: Directory(src),
        targetDir: target,
        liveExtractDirs: <String>[target],
        forceCopyFallback: true,
      );

      expect(result, '$target~2');
      expect(File(p.join(target, 'owned.txt')).existsSync(), isTrue,
          reason: 'a live book directory must never be touched');
      expect(File(p.join('$target~2', 'fresh.txt')).existsSync(), isTrue);
      expect(Directory(src).existsSync(), isFalse);
    });
  });

  group('EpubImporter.importFromPath onto existing target dir (BUG-564)', () {
    late Directory tmp;
    late Directory pp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bug564_import_');
      pp = Directory.systemTemp.createTempSync('bug564_pp_');
      // Pin EpubStorage's process-global cached base dir to this test.
      EpubStorage.debugBaseDirectoryOverride = pp.path;
    });
    tearDown(() {
      EpubStorage.debugBaseDirectoryOverride = null;
      for (final Directory d in <Directory>[tmp, pp]) {
        try {
          if (d.existsSync()) d.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    testWidgets('orphan leftover dir at the key no longer fails the import',
        (WidgetTester tester) async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);

      const String title = 'OrphanNovel';
      _writeEpub(p.join(tmp.path, '$title.epub'), title);

      // The reported failure path: the key-named dir exists non-empty on disk
      // (previous copy's leftover) while no DB row owns the key.
      final String realDir = p.join(pp.path, 'hoshi_books', title);
      _seedDir(realDir, 'stale.txt');

      // Real isolate (compute) -> drive inside runAsync.
      final String bookKey = await tester.runAsync(() async {
        return EpubImporter.importFromPath(
          db: db,
          filePath: p.join(tmp.path, '$title.epub'),
          fileName: '$title.epub',
        );
      }) as String;

      expect(bookKey, title);
      final List<EpubBookRow> books = await db.getAllEpubBooks();
      expect(books, hasLength(1));
      expect(p.canonicalize(books.single.extractDir), p.canonicalize(realDir));
      expect(File(p.join(realDir, 'stale.txt')).existsSync(), isFalse,
          reason: 'orphan content replaced by the fresh extraction');
      expect(
          File(p.join(realDir, 'OEBPS', 'chapter.xhtml')).existsSync(), isTrue);
      expect(_bakSiblings(realDir), isEmpty);
    });

    testWidgets('key dir owned by another live row is preserved',
        (WidgetTester tester) async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);

      const String title = 'SharedDirNovel';
      _writeEpub(p.join(tmp.path, '$title.epub'), title);

      // A live row whose extract_dir (the truth column) points at the new
      // book's key-named dir while having a different title/key.
      final String realDir = p.join(pp.path, 'hoshi_books', title);
      _seedDir(realDir, 'owned.txt');
      await db.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: 'SomeOtherKey',
        title: 'SomeOtherTitle',
        epubPath: 'other.epub',
        extractDir: realDir,
        chapterCount: 1,
        chaptersJson: '[]',
        tocJson: const Value.absent(),
        importedAt: 1,
      ));

      final String bookKey = await tester.runAsync(() async {
        return EpubImporter.importFromPath(
          db: db,
          filePath: p.join(tmp.path, '$title.epub'),
          fileName: '$title.epub',
        );
      }) as String;

      expect(bookKey, title);
      expect(File(p.join(realDir, 'owned.txt')).existsSync(), isTrue,
          reason: "the live row's directory must never be replaced");
      final List<EpubBookRow> books = await db.getAllEpubBooks();
      final EpubBookRow imported =
          books.singleWhere((EpubBookRow b) => b.bookKey == title);
      expect(p.canonicalize(imported.extractDir), p.canonicalize('$realDir~2'));
      expect(
          File(p.join(imported.extractDir, 'OEBPS', 'chapter.xhtml'))
              .existsSync(),
          isTrue);
    });
  });
}
