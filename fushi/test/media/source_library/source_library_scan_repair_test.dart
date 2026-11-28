// BUG-5569：来源扫描遇到已入库的书 / 有声书时，受管内容（解包书目录、有声书持久目录
// 里的音频与字幕副本）丢了就拿来源原件按**原条目**就地重建：不删行、不重导，bookKey /
// uid / 阅读进度 / 有声书播放进度原样保留。此前 `_importBookItems` 认出已入库（索引
// 命中或按标题判重复）就直接拿 bookKey 走人，`_attachAudiobook` 见到有声书行就 return，
// 丢了内容的书永远修不回来。

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

FushiDatabase _memDb() => FushiDatabase.forTesting(NativeDatabase.memory());

ArchiveFile _textFile(String name, String content) {
  final List<int> bytes = utf8.encode(content);
  return ArchiveFile(name, bytes.length, bytes);
}

const String _containerXml =
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<container version="1.0" '
    'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
    '<rootfiles><rootfile full-path="OEBPS/content.opf" '
    'media-type="application/oebps-package+xml"/></rootfiles></container>';

/// 标题 [title]、[chapters] 章的最小 EPUB（章文件 `c<i>.xhtml`）。
void _writeEpub(String path, String title, {int chapters = 1}) {
  final StringBuffer manifest = StringBuffer();
  final StringBuffer spine = StringBuffer();
  final List<ArchiveFile> files = <ArchiveFile>[
    _textFile('META-INF/container.xml', _containerXml),
  ];
  for (int i = 0; i < chapters; i++) {
    manifest.write(
      '<item id="c$i" href="c$i.xhtml" media-type="application/xhtml+xml"/>',
    );
    spine.write('<itemref idref="c$i"/>');
    files.add(
      _textFile(
        'OEBPS/c$i.xhtml',
        '<?xml version="1.0" encoding="UTF-8"?>'
            '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>C</title>'
            '</head><body><p>hello</p><p>Chapter $i text.</p></body></html>',
      ),
    );
  }
  files.add(
    _textFile(
      'OEBPS/content.opf',
      '<?xml version="1.0" encoding="UTF-8"?>'
          '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
          'unique-identifier="book-id">'
          '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
          '<dc:title>$title</dc:title></metadata>'
          '<manifest>$manifest</manifest><spine>$spine</spine></package>',
    ),
  );
  final Archive archive = Archive();
  for (final ArchiveFile f in files) {
    archive.addFile(f);
  }
  File(
    path,
  ).writeAsBytesSync(Uint8List.fromList(ZipEncoder().encode(archive)!));
}

const String _srt = '1\n00:00:01,000 --> 00:00:02,000\nhello\n';

/// [dir] 下写一份最小合法 mokuro 卷（`<title>.mokuro` + `images/` 页图）。
void _writeMokuro(String dir, {required String title, int pages = 1}) {
  final Directory images = Directory(p.join(dir, 'images'))
    ..createSync(recursive: true);
  final List<Object?> payloadPages = <Object?>[];
  for (int i = 0; i < pages; i++) {
    File(p.join(images.path, 'p$i.jpg')).writeAsBytesSync(<int>[1, 2, 3, i]);
    payloadPages.add(<String, Object?>{
      'img_width': 800,
      'img_height': 1200,
      'img_path': 'images/p$i.jpg',
      'blocks': <Object?>[],
    });
  }
  File(p.join(dir, '$title.mokuro')).writeAsStringSync(
    jsonEncode(<String, Object?>{
      'version': '0.2.0',
      'title': title,
      'pages': payloadPages,
    }),
  );
}

/// [pages] 页 PNG 的 `.cbz` 漫画包。
void _writeCbz(String path, {int pages = 2}) {
  final List<int> png = img.encodePng(img.Image(width: 20, height: 40));
  final Archive archive = Archive();
  for (int i = 1; i <= pages; i++) {
    archive.addFile(ArchiveFile('00$i.png', png.length, png));
  }
  File(path).writeAsBytesSync(ZipEncoder().encode(archive)!);
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  group('pure helpers', () {
    test('audiobookPersistedNameMatches 容忍持久化撞名后缀与转码扩展名', () {
      expect(
        audiobookPersistedNameMatches('/a/01.mp3', '/src/CD1/01.mp3'),
        true,
      );
      expect(
        audiobookPersistedNameMatches('/a/01 _1.mp3', '/src/CD2/01.mp3'),
        true,
      );
      expect(
        audiobookPersistedNameMatches('/a/Book.flac', '/s/book.aiff'),
        true,
      );
      expect(audiobookPersistedNameMatches('/a/02.mp3', '/s/01.mp3'), false);
    });

    test('sameChapterHrefs 只比 href 序列', () {
      const String a = '[{"href":"x.xhtml","characters":1}]';
      const String b = '[{"href":"x.xhtml","characters":9}]';
      const String c = '[{"href":"y.xhtml","characters":1}]';
      expect(sameChapterHrefs(a, b), true);
      expect(sameChapterHrefs(a, c), false);
      expect(sameChapterHrefs('not json', a), false);
    });
  });

  group('SourceLibraryScanner 重建丢失的受管内容 (BUG-5569)', () {
    late Directory tmp;
    late Directory pp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bug5569_src_');
      pp = Directory.systemTemp.createTempSync('bug5569_pp_');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (MethodCall call) async => pp.path,
      );
      EpubStorage.debugBaseDirectoryOverride = pp.path;
    });
    tearDown(() {
      EpubStorage.debugBaseDirectoryOverride = null;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      for (final Directory d in <Directory>[tmp, pp]) {
        try {
          if (d.existsSync()) d.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    Future<SourceLibraryRow> addSource(FushiDatabase db) async {
      final int sid = await db.insertMediaSource(
        MediaSourcesCompanion.insert(
          label: 'Books',
          mediaKind: 'book',
          rootPath: tmp.path,
          createdAt: 1000,
        ),
      );
      return (await db.getMediaSourceById(sid))!;
    }

    Future<void> scan(
      WidgetTester tester,
      FushiDatabase db,
      SourceLibraryRow source,
    ) => tester.runAsync(() async {
      final SourceLibraryRow fresh = (await db.getMediaSourceById(source.id))!;
      await SourceLibraryScanner(db, transcribeAudiobook: null).scan(fresh);
    });

    Future<void> savePosition(FushiDatabase db, String uid) =>
        db.upsertReaderPosition(
          ReaderPositionsCompanion.insert(
            bookUid: uid,
            sectionIndex: 0,
            normCharOffset: 4242,
            charOffset: const Value<int>(7),
            updatedAt: 1,
          ),
        );

    testWidgets('解包目录丢了（原件未变）→ 原条目原地重建，身份与进度不变', (WidgetTester tester) async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      _writeEpub(p.join(tmp.path, 'novel.epub'), 'RepairNovel');
      final SourceLibraryRow source = await addSource(db);

      await scan(tester, db, source);
      final EpubBookRow before = (await db.getAllEpubBooks()).single;
      await savePosition(db, before.uid);

      Directory(before.extractDir).deleteSync(recursive: true);
      expect(
        await bookManagedContentIntact(
          format: before.format,
          extractDir: before.extractDir,
          epubPath: before.epubPath,
        ),
        false,
      );

      await scan(tester, db, source);

      final List<EpubBookRow> after = await db.getAllEpubBooks();
      expect(after, hasLength(1), reason: '不删行重导，也不生成 X (2)');
      final EpubBookRow row = after.single;
      expect(row.bookKey, before.bookKey);
      expect(row.uid, before.uid);
      expect(row.extractDir, before.extractDir);
      expect(row.chaptersJson, before.chaptersJson);
      expect(
        File(p.join(row.extractDir, 'META-INF', 'container.xml')).existsSync(),
        true,
        reason: '扫描必须从可用的原件重建丢掉的解包目录',
      );
      final ReaderPositionRow? pos = await db.getReaderPosition(row.uid);
      expect(pos?.normCharOffset, 4242, reason: '阅读进度挂在原条目上，原样保留');
      final SourceLibraryRow scanned = (await db.getMediaSourceById(
        source.id,
      ))!;
      expect(scanned.lastScanError, isNull);
      expect(scanned.mediaCount, 0, reason: '重建不是新入库');
    });

    testWidgets('原件换过（指纹变了，退到按标题判重复）→ 仍按原条目重建并提示', (WidgetTester tester) async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final String path = p.join(tmp.path, 'novel.epub');
      _writeEpub(path, 'ChangedNovel');
      final SourceLibraryRow source = await addSource(db);

      await scan(tester, db, source);
      final EpubBookRow before = (await db.getAllEpubBooks()).single;
      await savePosition(db, before.uid);

      // 同名书换成另一版（章数不同 → 大小 / 修改时刻都变）。
      _writeEpub(path, 'ChangedNovel', chapters: 3);
      Directory(before.extractDir).deleteSync(recursive: true);

      await scan(tester, db, source);

      final EpubBookRow row = (await db.getAllEpubBooks()).single;
      expect(row.uid, before.uid);
      expect(row.chapterCount, 3, reason: '章节元数据要与重建出来的新树一致');
      expect(
        File(p.join(row.extractDir, 'META-INF', 'container.xml')).existsSync(),
        true,
      );
      expect(
        (await db.getReaderPosition(row.uid))?.normCharOffset,
        4242,
        reason: '不静默重置进度',
      );
      final SourceLibraryRow scanned = (await db.getMediaSourceById(
        source.id,
      ))!;
      expect(
        scanned.lastScanError,
        contains('changed since import'),
        reason: '原件变了，进度可能对不上新内容：必须提示出来',
      );
    });

    testWidgets('手动导入的同名书不归本来源 → 不拿来源文件去重建它', (WidgetTester tester) async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final String manual = p.join(pp.path, 'manual.epub');
      _writeEpub(manual, 'ManualNovel');
      late String bookKey;
      await tester.runAsync(() async {
        bookKey = await EpubImporter.importFromPath(
          db: db,
          filePath: manual,
          fileName: 'manual.epub',
        );
      });
      final EpubBookRow before = (await db.getEpubBook(bookKey))!;
      Directory(before.extractDir).deleteSync(recursive: true);

      _writeEpub(p.join(tmp.path, 'other.epub'), 'ManualNovel');
      final SourceLibraryRow source = await addSource(db);
      await scan(tester, db, source);

      expect(await db.getAllEpubBooks(), hasLength(1));
      expect(
        Directory(before.extractDir).existsSync(),
        false,
        reason: '同名不等于同一份原件：不认领、不覆写',
      );
    });

    testWidgets('有声书持久目录里的音频与字幕副本丢了 → 补回原路径，进度不变', (WidgetTester tester) async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      _writeEpub(p.join(tmp.path, 'book.epub'), 'AudioRepair');
      File(p.join(tmp.path, 'book.srt')).writeAsStringSync(_srt);
      File(p.join(tmp.path, 'book.mp3')).writeAsStringSync('fake-mp3-bytes');
      final SourceLibraryRow source = await addSource(db);

      await scan(tester, db, source);
      final EpubBookRow book = (await db.getAllEpubBooks()).single;
      final AudiobookRepository repo = AudiobookRepository(db);
      final Audiobook ab = (await repo.findByBookKey(book.bookKey))!;
      final List<String> audio = ab.audioPaths!;
      expect(audio, hasLength(1));
      final int cueCount = (await db.getCuesForBook(book.bookKey)).length;
      expect(cueCount, greaterThan(0));
      await repo.updatePositionMs(bookKey: book.bookKey, positionMs: 1500);

      // 整个受管库丢了：解包目录 + 音频 + 字幕副本。
      Directory(book.extractDir).deleteSync(recursive: true);
      File(audio.single).deleteSync();
      File(ab.alignmentPath).deleteSync();

      await scan(tester, db, source);

      expect(await db.getAllEpubBooks(), hasLength(1));
      expect(
        File(p.join(book.extractDir, 'META-INF', 'container.xml')).existsSync(),
        true,
      );
      final Audiobook repaired = (await repo.findByBookKey(book.bookKey))!;
      expect(repaired.audioPaths, audio, reason: '补回原路径，音频清单不变');
      expect(File(audio.single).readAsStringSync(), 'fake-mp3-bytes');
      expect(repaired.alignmentPath, ab.alignmentPath);
      expect(File(ab.alignmentPath).existsSync(), true);
      expect((await db.getCuesForBook(book.bookKey)).length, cueCount);
      expect(
        await repo.readPositionMs(book.bookKey),
        1500,
        reason: '同一组文件补回来，播放进度不重置',
      );
      final SourceLibraryRow scanned = (await db.getMediaSourceById(
        source.id,
      ))!;
      expect(scanned.lastScanError, isNull);
    });

    testWidgets('只丢音频副本 → 只补音频，cue 不动', (WidgetTester tester) async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      _writeEpub(p.join(tmp.path, 'book.epub'), 'AudioOnlyRepair');
      File(p.join(tmp.path, 'book.srt')).writeAsStringSync(_srt);
      File(p.join(tmp.path, 'book.mp3')).writeAsStringSync('fake-mp3-bytes');
      final SourceLibraryRow source = await addSource(db);

      await scan(tester, db, source);
      final EpubBookRow book = (await db.getAllEpubBooks()).single;
      final AudiobookRepository repo = AudiobookRepository(db);
      final Audiobook ab = (await repo.findByBookKey(book.bookKey))!;
      final List<AudioCueRow> cues = await db.getCuesForBook(book.bookKey);
      File(ab.audioPaths!.single).deleteSync();

      await scan(tester, db, source);

      expect(File(ab.audioPaths!.single).existsSync(), true);
      final List<AudioCueRow> after = await db.getCuesForBook(book.bookKey);
      expect(
        after.map((AudioCueRow c) => c.id).toList(),
        cues.map((AudioCueRow c) => c.id).toList(),
        reason: '只补音频不重新对齐',
      );
    });

    testWidgets('库里挂的是另一组音频（手动重匹配过）→ 不拿原件去猜，扫描结果提示', (
      WidgetTester tester,
    ) async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      _writeEpub(p.join(tmp.path, 'book.epub'), 'AudioMismatch');
      File(p.join(tmp.path, 'book.srt')).writeAsStringSync(_srt);
      File(p.join(tmp.path, 'book.mp3')).writeAsStringSync('fake-mp3-bytes');
      final SourceLibraryRow source = await addSource(db);

      await scan(tester, db, source);
      final EpubBookRow book = (await db.getAllEpubBooks()).single;
      final AudiobookRepository repo = AudiobookRepository(db);
      final Audiobook ab = (await repo.findByBookKey(book.bookKey))!;
      // 用户后来手动换成了另一份音频（同在持久目录），之后这份副本也丢了。
      final String other = p.join(
        p.dirname(ab.audioPaths!.single),
        'other.mp3',
      );
      await repo.replaceAudio(
        bookKey: book.bookKey,
        audioPaths: <String>[other],
      );

      await scan(tester, db, source);

      expect(File(other).existsSync(), false);
      expect((await repo.findByBookKey(book.bookKey))!.audioPaths, <String>[
        other,
      ]);
      final SourceLibraryRow scanned = (await db.getMediaSourceById(
        source.id,
      ))!;
      expect(scanned.lastScanError, contains('no longer match'));
    });

    Future<SourceLibraryRow> addMangaSource(FushiDatabase db) async {
      final int sid = await db.insertMediaSource(
        MediaSourcesCompanion.insert(
          label: 'Manga',
          mediaKind: 'manga',
          rootPath: tmp.path,
          createdAt: 1000,
        ),
      );
      return (await db.getMediaSourceById(sid))!;
    }

    testWidgets('漫画 mokuro 卷的书目录丢了 → 按原条目重建，身份与进度不变', (
      WidgetTester tester,
    ) async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      _writeMokuro(tmp.path, title: 'RepairVolume', pages: 2);
      final SourceLibraryRow source = await addMangaSource(db);

      await scan(tester, db, source);
      final EpubBookRow before = (await db.getAllEpubBooks()).single;
      expect(before.format, BookFormat.manga.dbValue);
      await savePosition(db, before.uid);
      Directory(before.extractDir).deleteSync(recursive: true);

      await scan(tester, db, source);

      final List<EpubBookRow> after = await db.getAllEpubBooks();
      expect(after, hasLength(1));
      final EpubBookRow row = after.single;
      expect(row.uid, before.uid);
      expect(row.extractDir, before.extractDir);
      expect(row.chapterCount, 2);
      expect(File(p.join(row.extractDir, row.epubPath)).existsSync(), true);
      expect((await db.getReaderPosition(row.uid))?.normCharOffset, 4242);
      final SourceLibraryRow scanned = (await db.getMediaSourceById(
        source.id,
      ))!;
      expect(scanned.lastScanError, isNull);
      expect(scanned.mediaCount, 0);
    });

    testWidgets('漫画压缩包卷换成页数不同的版本后书目录丢了 → 重建并提示', (WidgetTester tester) async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final String cbz = p.join(tmp.path, 'vol1.cbz');
      _writeCbz(cbz);
      final SourceLibraryRow source = await addMangaSource(db);

      await scan(tester, db, source);
      final EpubBookRow before = (await db.getAllEpubBooks()).single;
      expect(before.chapterCount, 2);
      Directory(before.extractDir).deleteSync(recursive: true);
      _writeCbz(cbz, pages: 3);

      await scan(tester, db, source);

      final EpubBookRow row = (await db.getAllEpubBooks()).single;
      expect(row.uid, before.uid);
      expect(row.chapterCount, 3);
      expect(File(p.join(row.extractDir, row.epubPath)).existsSync(), true);
      final SourceLibraryRow scanned = (await db.getMediaSourceById(
        source.id,
      ))!;
      expect(scanned.lastScanError, contains('page count changed'));
    });
  });
}
