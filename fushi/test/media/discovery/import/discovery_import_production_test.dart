import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/discovery/import/discovery_import_plan.dart';
import 'package:fushi/src/media/discovery/import/discovery_import_executor.dart';
import 'package:fushi/src/media/discovery/import/discovery_import_production.dart';
import 'package:fushi/src/mining/galgame_repository.dart';
import 'package:path/path.dart' as p;

Uint8List _minimalEpub(String title) {
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

  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late FushiDatabase db;
  late DiscoveryDomainImporters importers;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('discovery_production_');
    EpubStorage.debugBaseDirectoryOverride = tempRoot.path;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    importers = buildProductionDiscoveryImporters(
      db: db,
      srtBookRepo: SrtBookRepository(db),
      audiobookRepo: AudiobookRepository(db),
      galgameRepo: GalgameRepository(db),
    );
  });

  tearDown(() async {
    await db.close();
    EpubStorage.debugBaseDirectoryOverride = null;
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  // BUG-2775：有声书包里的 EPUB 与库中已有书同名时，自动入库不附着音频。以前
  // 返回 null 被当成「0 条新增」，任务行只剩一句 import failed；现在必须以
  // 稳定原因码报出，UI 才能告诉用户去已有书里手动导入有声书。
  test(
      'audiobook whose EPUB is already in the library is blocked with a '
      'stable reason', () async {
    final File epub = File(p.join(tempRoot.path, '秒速5センチメートル.epub'))
      ..writeAsBytesSync(_minimalEpub('秒速5センチメートル'));
    expect(await importers.importEpub(epub.path), isNotNull);

    final AlignAudiobookPlan plan = AlignAudiobookPlan(
      contentPath: epub.path,
      subtitlePath: p.join(tempRoot.path, 'book.srt'),
      audioPaths: <String>[p.join(tempRoot.path, '01.mp3')],
    );

    await expectLater(
      importers.importAudiobook(plan),
      throwsA(
        isA<DiscoveryImportBlockedException>().having(
          (DiscoveryImportBlockedException e) => e.blocker,
          'blocker',
          DiscoveryImportBlocker.audiobookBookAlreadyInLibrary,
        ),
      ),
    );
  });
}
