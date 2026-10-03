import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/source_library/book_library_prune.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/library_scanner.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 服务端书 / 漫画根的扫描对账（BUG-2816）：用户删掉源 EPUB / 漫画卷后重扫，要回收
/// 对应条目；此前书 / 漫画根完全不对账（导入把正文拷进 `fushi_books/`，行里记不住
/// 源文件），删掉的书在客户端永远列得出来。
void _writeEpub(String path, String title) {
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
  <body><p>Hello.</p></body>
</html>
''');
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(ZipEncoder().encode(archive)!);
}

/// 最小 mokuro 卷（`.mokuro` + `images/` 页图）。
void _writeMokuro(String dir, String title) {
  File(p.join(dir, 'images', 'p001.jpg'))
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(<int>[1, 2, 3]);
  File(p.join(dir, '$title.mokuro')).writeAsStringSync(
    jsonEncode(<String, Object?>{
      'version': '0.2.0',
      'title': title,
      'pages': <Object?>[
        <String, Object?>{
          'img_width': 800,
          'img_height': 1200,
          'img_path': 'images/p001.jpg',
          'blocks': <Object?>[],
        },
      ],
    }),
  );
}

void main() {
  late Directory tmp;
  late Directory libraryRoot;
  late FushiDatabase db;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_server_book_prune_');
    libraryRoot = Directory(p.join(tmp.path, 'library'))..createSync();
    final ServerPaths paths = ServerPaths(p.join(tmp.path, 'data'));
    await paths.ensureLayout();
    enginePaths = paths;
    EpubStorage.debugBaseDirectoryOverride = null;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    EpubStorage.debugBaseDirectoryOverride = null;
    enginePaths = const UninstalledEnginePaths();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<ScanSummary> scan(String kind, {bool prune = true}) =>
      LibraryScanner(
        db: db,
        subtitleLanguage: 'ja',
        extractCovers: false,
        pruneMissing: prune,
      ).scanAll(<LibraryRootConfig>[
        LibraryRootConfig(id: kind, path: libraryRoot.path, kind: kind),
      ]);

  Future<List<String>> titles() async =>
      (await db.getAllEpubBooks()).map((EpubBookRow b) => b.title).toList()
        ..sort();

  test('删掉源 EPUB 后重扫：回收该书与正文副本，其它书与源文件不动', () async {
    _writeEpub(p.join(libraryRoot.path, 'keep.epub'), 'Keep');
    _writeEpub(p.join(libraryRoot.path, 'sub', 'drop.epub'), 'Drop');

    final ScanSummary first = await scan('book');
    expect(first.errors, isEmpty);
    expect(first.booksAdded, 2);
    final EpubBookRow drop = (await db.getEpubBook('Drop'))!;
    final int sourceId = drop.sourceId!;
    expect(
      (await db.getMediaSourceById(sourceId))!.mediaKind,
      'book',
      reason: '书根要登记成 book 来源、行带 sourceId（与 app 源库扫描同构）',
    );

    // 重扫不重新导入已认领的源。
    final ScanSummary again = await scan('book');
    expect(again.booksAdded, 0);
    expect(again.booksSkipped, 2);
    expect(again.booksPruned, 0);

    Directory(p.join(libraryRoot.path, 'sub')).deleteSync(recursive: true);
    final ScanSummary second = await scan('book');

    expect(second.errors, isEmpty);
    expect(second.booksPruned, 1);
    expect(await titles(), <String>['Keep']);
    expect(Directory(drop.extractDir).existsSync(), isFalse);
    expect(File(p.join(libraryRoot.path, 'keep.epub')).existsSync(), isTrue);
    expect((await BookSourceIndex.load(db, sourceId)).entries.keys, <String>[
      'keep.epub',
    ]);
  });

  test('删掉源漫画卷后重扫：回收该卷', () async {
    _writeMokuro(p.join(libraryRoot.path, 'vol-a'), 'VolA');
    _writeMokuro(p.join(libraryRoot.path, 'vol-b'), 'VolB');

    expect((await scan('manga')).mangaAdded, 2);
    Directory(p.join(libraryRoot.path, 'vol-b')).deleteSync(recursive: true);

    final ScanSummary second = await scan('manga');

    expect(second.errors, isEmpty);
    expect(second.mangaPruned, 1);
    expect(await titles(), <String>['VolA']);
  });

  test('存量行（旧版扫描进来、没记来源）：重扫时按标题 + 源文件名认领，之后照常回收', () async {
    final String legacy = p.join(libraryRoot.path, 'legacy.epub');
    _writeEpub(legacy, 'Legacy');
    _writeEpub(p.join(libraryRoot.path, 'keep.epub'), 'Keep');
    // 模拟旧版服务端扫描：同样的导入调用，但不带 sourceId。
    for (final String f in <String>[
      legacy,
      p.join(libraryRoot.path, 'keep.epub'),
    ]) {
      await EpubImporter.importFromPath(
        db: db,
        filePath: f,
        fileName: p.basename(f),
        policy: const DuplicatePolicy.skip(),
      );
    }
    expect((await db.getEpubBook('Legacy'))!.sourceId, isNull);

    final ScanSummary adopt = await scan('book');
    expect(adopt.booksAdded, 0);
    expect(adopt.booksSkipped, 2);
    expect((await db.getEpubBook('Legacy'))!.sourceId, isNotNull);

    File(legacy).deleteSync();
    final ScanSummary second = await scan('book');

    expect(second.booksPruned, 1);
    expect(await titles(), <String>['Keep']);
  });

  test('同名书是客户端上传的（源文件名不同）：不认领，删源文件也不回收它', () async {
    final String upload = p.join(tmp.path, 'uploads', 'uploaded-copy.epub');
    _writeEpub(upload, 'Shared');
    await EpubImporter.importFromPath(
      db: db,
      filePath: upload,
      fileName: p.basename(upload),
    );
    final String inRoot = p.join(libraryRoot.path, 'shared.epub');
    _writeEpub(inRoot, 'Shared');
    _writeEpub(p.join(libraryRoot.path, 'keep.epub'), 'Keep');

    await scan('book');
    expect((await db.getEpubBook('Shared'))!.sourceId, isNull);
    File(inRoot).deleteSync();

    final ScanSummary second = await scan('book');

    expect(second.booksPruned, 0);
    expect(await titles(), <String>['Keep', 'Shared']);
  });

  test('用户在客户端删了书、源文件还在：重扫重新导入（不被旧索引挡住）', () async {
    _writeEpub(p.join(libraryRoot.path, 'a.epub'), 'Alpha');
    await scan('book');
    await db.deleteEpubBook('Alpha');

    final ScanSummary second = await scan('book');

    expect(second.booksAdded, 1);
    expect(await titles(), <String>['Alpha']);
  });

  test('关掉对账（--no-prune）：删掉的源不回收', () async {
    _writeEpub(p.join(libraryRoot.path, 'keep.epub'), 'Keep');
    _writeEpub(p.join(libraryRoot.path, 'drop.epub'), 'Drop');
    await scan('book');
    File(p.join(libraryRoot.path, 'drop.epub')).deleteSync();

    final ScanSummary second = await scan('book', prune: false);

    expect(second.booksPruned, 0);
    expect(await titles(), <String>['Drop', 'Keep']);
  });

  test('护栏：书根被清空（空挂载点）→ 不回收并留说明', () async {
    _writeEpub(p.join(libraryRoot.path, 'a.epub'), 'Alpha');
    await scan('book');
    File(p.join(libraryRoot.path, 'a.epub')).deleteSync();

    final ScanSummary second = await scan('book');

    expect(second.booksPruned, 0);
    expect(second.pruneSkipped, 1);
    expect(second.pruneNotes.single, contains('no book files'));
    expect(await titles(), <String>['Alpha']);
  });
}
