import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/discovery/import/discovery_engine_importers.dart'
    show isDuplicateDiscoveryAudiobookContent;
import 'package:fushi_engine/media/discovery/import/discovery_import_plan.dart';
import 'package:fushi_engine/media/discovery/import/discovery_import_executor.dart';
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
      transcribeAudiobook: (TranscribeAudiobookPlan plan) async =>
          throw const DiscoveryImportBlockedException(
        DiscoveryImportBlocker.audiobookMissingSubtitle,
      ),
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

  // 自动转录入队前的查重必须与 importDiscoveryAudiobook 的判据逐项一致:不一致
  // 就会要么白跑几个小时转录再失败,要么把能入库的书挡在门外。
  test('isDuplicateDiscoveryAudiobookContent 与导入器同一判据', () async {
    final File inLibrary = File(p.join(tempRoot.path, 'a', 'whatever.epub'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(_minimalEpub('銀河鉄道の夜'));
    expect(await importers.importEpub(inLibrary.path), isNotNull);

    // 文件名不同、OPF 标题相同 → 撞(导入器按 OPF 标题判)。
    final File sameTitle = File(p.join(tempRoot.path, 'b', 'other-name.epub'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(_minimalEpub('銀河鉄道の夜'));
    expect(await isDuplicateDiscoveryAudiobookContent(db, sameTitle.path),
        isTrue);
    // 交叉核对:导入器对它确实会挡下(同名书已在库)。
    await expectLater(
      importers.importAudiobook(AlignAudiobookPlan(
        contentPath: sameTitle.path,
        subtitlePath: p.join(tempRoot.path, 'x.srt'),
        audioPaths: <String>[p.join(tempRoot.path, 'x.mp3')],
      )),
      throwsA(isA<DiscoveryImportBlockedException>()),
    );

    final File fresh = File(p.join(tempRoot.path, 'c', 'fresh.epub'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(_minimalEpub('風の又三郎'));
    expect(await isDuplicateDiscoveryAudiobookContent(db, fresh.path), isFalse);

    // 纯文本正文按文件名判(importDiscoveryText 拿文件名当书名)。
    final File txt = File(p.join(tempRoot.path, 'd', '銀河鉄道の夜.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('本文');
    expect(await isDuplicateDiscoveryAudiobookContent(db, txt.path), isTrue);
  });

  group('独立字幕书(字幕 + 音频、无正文)', () {
    late EnginePaths previousPaths;
    late Future<Directory> Function()? previousDocsRoot;

    setUp(() {
      previousPaths = enginePaths;
      previousDocsRoot = AudiobookStorage.documentsRootResolver;
      enginePaths = FixedEnginePaths(
        documents: tempRoot,
        support: tempRoot,
        temp: tempRoot,
      );
      AudiobookStorage.documentsRootResolver = () async => tempRoot;
    });

    tearDown(() {
      enginePaths = previousPaths;
      AudiobookStorage.documentsRootResolver = previousDocsRoot;
    });

    test('落一条带音频与 cue 的字幕书;同名再来一次被跳过', () async {
      final File srt = File(p.join(tempRoot.path, 'src', '銀河鉄道の夜.srt'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          '1\n00:00:00,000 --> 00:00:02,000\nジョバンニは走った。\n\n'
          '2\n00:00:02,000 --> 00:00:04,000\nカムパネルラもいた。\n',
        );
      final File mp3 = File(p.join(tempRoot.path, 'src', '01.mp3'))
        ..writeAsBytesSync(<int>[0, 1, 2, 3]);
      final SubtitleAudiobookPlan plan = SubtitleAudiobookPlan(
        subtitlePath: srt.path,
        audioPaths: <String>[mp3.path],
      );

      final String? key = await importers.importSubtitleAudiobook(plan);
      expect(key, isNotNull);

      final SrtBookRepository repo = SrtBookRepository(db);
      final List<SrtBook> books = await repo.listAll();
      expect(books, hasLength(1));
      final SrtBook book = books.single;
      expect(book.title, '銀河鉄道の夜');
      expect(book.bookKey, key);
      expect(book.audioPaths, hasLength(1));
      expect(File(book.audioPaths!.single).existsSync(), isTrue);
      expect(await repo.cuesFor(book.uid), hasLength(2));
      expect(await db.getEpubBook(key!), isNotNull);

      // 同一份字幕再下一次：正文 EPUB 同名 → skip，不落第二条壳行。
      expect(await importers.importSubtitleAudiobook(plan), isNull);
      expect(await repo.listAll(), hasLength(1));
    });
  });
}
