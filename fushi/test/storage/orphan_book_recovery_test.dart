import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/card_source_router.dart';
import 'package:fushi/src/pages/implementations/library_recovery_page.dart';
import 'package:fushi/src/storage/orphan_book_recovery.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/pdf_book_layout.dart';
import 'package:path/path.dart' as p;

import '../sync/temp_dir_cleanup.dart';

/// BUG-4701：覆盖导入后书目录成孤儿，按目录名（= bookKey）重新登记，卡片来源
/// 重新连上；不能还原 bookKey / 来源的目录列为不可恢复。
void main() {
  late Directory tmp;
  late String booksRoot;
  late FushiDatabase db;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_orphan_');
    booksRoot = p.join(tmp.path, 'fushi_books');
    Directory(booksRoot).createSync();
    final Directory dbDir = Directory(p.join(tmp.path, 'db'))..createSync();
    db = FushiDatabase(dbDir.path);
  });

  tearDown(() async {
    await db.close();
    await cleanupTempDir(tmp);
  });

  void writeFile(String rel, String content) {
    final File f = File(p.join(booksRoot, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  void writeEpub(String dir, String title) {
    writeFile(
      p.join(dir, 'META-INF', 'container.xml'),
      '<?xml version="1.0"?>'
      '<container version="1.0" '
      'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
      '<rootfiles><rootfile full-path="OEBPS/content.opf" '
      'media-type="application/oebps-package+xml"/></rootfiles></container>',
    );
    writeFile(
      p.join(dir, 'OEBPS', 'content.opf'),
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
      'unique-identifier="id">'
      '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<dc:title>$title</dc:title><dc:creator>作者</dc:creator>'
      '<dc:language>ja</dc:language><dc:identifier id="id">x</dc:identifier>'
      '</metadata>'
      '<manifest><item id="c1" href="c1.xhtml" '
      'media-type="application/xhtml+xml"/></manifest>'
      '<spine><itemref idref="c1"/></spine></package>',
    );
    writeFile(
      p.join(dir, 'OEBPS', 'c1.xhtml'),
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>c</title>'
      '</head><body><p>吾輩は猫である。</p></body></html>',
    );
  }

  void writeManga(String dir) {
    writeFile(p.join(dir, 'images', 'p1.png'), 'png');
    writeFile(
      p.join(dir, 'manga.json'),
      jsonEncode(<String, Object?>{
        'pages': <Object?>[
          <String, Object?>{
            'url': 'images/p1.png',
            'width': 100,
            'height': 200,
            'blocks': <Object?>[],
          },
        ],
      }),
    );
  }

  test('scan classifies orphan directories; restore keeps bookKey and '
      'card sources resolve again', () async {
    // 活书：目录名 = 已登记的 bookKey，不算孤儿。
    writeEpub('活着的书', '活着的书');
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: '活着的书',
        title: '活着的书',
        epubPath: 'x.epub',
        extractDir: p.join(booksRoot, '活着的书'),
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1,
      ),
    );
    // 可恢复：EPUB（标题含净化字符）+ 本地漫画。
    writeEpub('猫%3F 物語', '猫? 物語');
    writeManga('漫画卷一');
    // 不可恢复。
    writeManga('12'); // 旧整数 id 目录（漫画无标题可核对）
    writeManga('mihon-0123456789abcdef0123456789abcdef');
    writeFile(
      p.join('mihon-0123456789abcdef0123456789abcdef', 'chapters', 'a', 'x'),
      'x',
    );
    Directory(p.join(booksRoot, '空目录')).createSync();
    writeFile(p.join('杂物', 'readme.txt'), 'hello');
    // 点开头的暂存目录不列（上个进程留下的导入残留，扫描前顺手收掉）。
    writeEpub('.tmp-1-1', 'tmp');

    final OrphanBookRecovery recovery = OrphanBookRecovery(
      database: db,
      booksRoot: booksRoot,
      registrars: libraryRecoveryRegistrars(),
    );
    final OrphanBookScan scan = await recovery.scan();

    expect(
      <String, OrphanBookKind>{
        for (final RecoverableOrphanBook b in scan.recoverable)
          b.bookKey: b.kind,
      },
      <String, OrphanBookKind>{
        '漫画卷一': OrphanBookKind.manga,
        '猫%3F 物語': OrphanBookKind.epub,
      },
    );
    expect(
      scan.recoverable.firstWhere((b) => b.kind == OrphanBookKind.epub).title,
      '猫? 物語',
    );
    expect(
      <String, OrphanBookIssue>{
        for (final UnrecoverableOrphanDirectory d in scan.unrecoverable)
          d.name: d.issue,
      },
      <String, OrphanBookIssue>{
        '12': OrphanBookIssue.legacyNumericDirectory,
        'mihon-0123456789abcdef0123456789abcdef': OrphanBookIssue.onlineManga,
        '空目录': OrphanBookIssue.emptyDirectory,
        '杂物': OrphanBookIssue.unrecognizedContent,
      },
    );

    final OrphanBookRestoreResult result = await recovery.restore(
      scan.recoverable,
    );
    expect(result.failures, isEmpty);
    expect(result.restored.toSet(), <String>{'漫画卷一', '猫%3F 物語'});

    final EpubBookRow epub = (await db.getEpubBook('猫%3F 物語'))!;
    expect(epub.title, '猫? 物語');
    expect(epub.format, 'epub');
    expect(epub.author, '作者');
    expect(epub.chapterCount, 1);
    expect(p.equals(epub.extractDir, p.join(booksRoot, '猫%3F 物語')), isTrue);
    final EpubBookRow manga = (await db.getEpubBook('漫画卷一'))!;
    expect(manga.format, 'manga');
    expect(manga.chapterCount, 1);
    expect(manga.coverPath, 'images/p1.png');

    // 卡片里存的 uid 随旧库丢失（导入时新生成的 uid 对不上），按 bookKey 回退找回。
    for (final String key in <String>['猫%3F 物語', '漫画卷一']) {
      final EpubBookRow? resolved = await resolveCardSourceBook(
        db,
        CardSourceLink(
          kind: CardSourceKind.book,
          uid: 'book_1_0',
          sourceId: CardSourceLink.newSourceId(),
          chapterIndex: 0,
          charOffset: 0,
          bookKey: key,
        ),
      );
      expect(resolved?.bookKey, key);
    }

    // 再扫一遍：已登记的不再出现。
    final OrphanBookScan again = await recovery.scan();
    expect(again.recoverable, isEmpty);
    expect(again.unrecoverable, hasLength(4));
  });

  test('BUG-4841：替换到一半留下的 .bak-* 先改回原名，再按正确的 bookKey 列出', () async {
    // 进程死在「旧树改名 bak」与「新树就位」之间：bak 是这本书唯一的副本。
    writeEpub('被打断的书.bak-1700000000000', '被打断的书');
    // 新树已就位、bak 只是没删掉：bak 是多余的。
    writeEpub('换好的书', '换好的书');
    writeEpub('换好的书.bak-1700000000000', '换好的书');

    final OrphanBookScan scan = await OrphanBookRecovery(
      database: db,
      booksRoot: booksRoot,
      registrars: libraryRecoveryRegistrars(),
    ).scan();

    expect(
      scan.recoverable.map((RecoverableOrphanBook b) => b.bookKey).toSet(),
      <String>{'被打断的书', '换好的书'},
      reason: '不能把 bak 当成一本名叫「xxx.bak-123」的书列出来',
    );
    expect(scan.unrecoverable, isEmpty);
    expect(
      Directory(
        booksRoot,
      ).listSync().map((FileSystemEntity e) => p.basename(e.path)).toSet(),
      <String>{'被打断的书', '换好的书'},
    );
  });

  test('numeric directory is accepted when the EPUB title is that number; '
      'tombstoned books are flagged', () async {
    writeEpub('1984', '1984');
    writeEpub('51', 'Not the number');
    await db.insertBookTombstone('1984');

    final OrphanBookScan scan = await OrphanBookRecovery(
      database: db,
      booksRoot: booksRoot,
      registrars: libraryRecoveryRegistrars(),
    ).scan();

    expect(scan.recoverable.single.bookKey, '1984');
    expect(scan.recoverable.single.previouslyDeleted, isTrue);
    expect(
      scan.unrecoverable.single.issue,
      OrphanBookIssue.legacyNumericDirectory,
    );
  });

  test('a directory holding the PDF book-layout file is recognised as a PDF '
      'book and restored through the injected PDF registrar', () async {
    writeFile(p.join('扫描本', PdfBookLayout.pdfFileName), '%PDF-1.4');
    final List<String> registered = <String>[];
    final OrphanBookRecovery recovery = OrphanBookRecovery(
      database: db,
      booksRoot: booksRoot,
      registrars: <OrphanBookKind, OrphanBookRegistrar>{
        OrphanBookKind.pdf:
            ({
              required FushiDatabase db,
              required String bookKey,
              required String title,
              required String bookDir,
            }) async {
              registered.add(bookKey);
              return bookKey;
            },
      },
    );

    final OrphanBookScan scan = await recovery.scan();
    expect(scan.recoverable.single.kind, OrphanBookKind.pdf);
    expect(scan.unrecoverable, isEmpty);

    final OrphanBookRestoreResult result = await recovery.restore(
      scan.recoverable,
    );
    expect(result.restored, <String>['扫描本']);
    expect(registered, <String>['扫描本']);
  });

  test('a per-book failure does not abort the batch', () async {
    writeManga('好的');
    writeManga('坏的');
    final OrphanBookRecovery recovery = OrphanBookRecovery(
      database: db,
      booksRoot: booksRoot,
      registrars: libraryRecoveryRegistrars(),
    );
    final OrphanBookScan scan = await recovery.scan();
    File(p.join(booksRoot, '坏的', 'manga.json')).writeAsStringSync('{');

    final OrphanBookRestoreResult result = await recovery.restore(
      scan.recoverable,
    );
    expect(result.restored, <String>['好的']);
    expect(result.failures.keys, <String>['坏的']);
    expect(await db.getEpubBook('坏的'), isNull);
  });
}
