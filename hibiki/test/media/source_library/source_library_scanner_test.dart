// TODO-817 M1b SourceLibraryScanner + sourceId backfill tests:
//  (1) planScanFromFileList pure: classifies epub/video/srt from a
//      SourceFileEntry list, associates same-stem subtitle sidecar, no IO.
//  (2) SourceLibraryScanner.scan over a real temp dir (video kind): inserts video
//      rows with sourceId + parses sidecar cues + writes updateMediaSourceScanResult.
//  (3) SourceLibraryScanner.scan over a real temp dir (book kind): imports EPUB via
//      the real isolate, epub_books.sourceId backfilled.
//  (4) sourceId backfill is opt-in: saveVideoBook/EpubImporter without sourceId
//      leave the column NULL (backward compatible).

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_charset_detector_platform_interface/decoding_result.dart';
import 'package:flutter_charset_detector_platform_interface/flutter_charset_detector_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:hibiki/src/epub/epub_storage.dart';
import 'package:hibiki/src/media/source_library/source_file_system.dart';
import 'package:hibiki/src/media/source_library/source_library_row.dart';
import 'package:hibiki/src/media/source_library/source_library_scanner.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

HibikiDatabase _memDb() => HibikiDatabase.forTesting(NativeDatabase.memory());

SourceFileEntry _file(String path, {int size = 1}) => SourceFileEntry(
      name: p.basename(path),
      path: path,
      isDirectory: false,
      sizeBytes: size,
    );

SourceFileEntry _dir(String path) =>
    SourceFileEntry(name: p.basename(path), path: path, isDirectory: true);

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

const String _srt = '1\n00:00:01,000 --> 00:00:02,000\nhello\n';

/// 在 [dir] 写出一份最小合法 mokuro 卷（`.mokuro` + `images/` 页图），返回
/// `.mokuro` 路径。样式对齐 manga_importer_test 的 `_writeValidSample`：页图用
/// 任意字节即可（mokuro 导入只拷贝字节、不解码图片）。
String _writeMokuro(String dir, {required String title}) {
  Directory(dir).createSync(recursive: true);
  final Directory images = Directory(p.join(dir, 'images'))
    ..createSync(recursive: true);
  File(p.join(images.path, 'p001.jpg')).writeAsBytesSync(<int>[1, 2, 3]);
  final Map<String, Object?> payload = <String, Object?>{
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
  };
  final String mokuroPath = p.join(dir, '$title.mokuro');
  File(mokuroPath).writeAsStringSync(jsonEncode(payload));
  return mokuroPath;
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  group('planScanFromFileList (pure)', () {
    test('classifies epub / video; subtitle attaches as video sidecar', () {
      final List<SourceFileEntry> files = <SourceFileEntry>[
        _file('/lib/book.epub'),
        _file('/lib/movie.mp4'),
        _file('/lib/movie.srt'),
        _file('/lib/notes.txt'),
        _dir('/lib/season1'),
      ];

      final ScanPlan plan = planScanFromFileList(files);

      expect(plan.books, hasLength(1));
      expect(plan.books.single.epubPath, '/lib/book.epub');
      // No sidecar audio -> plain EPUB (not an audiobook).
      expect(plan.books.single.isAudiobook, isFalse);
      expect(plan.videos, hasLength(1));
      expect(plan.videos.single.videoPath, '/lib/movie.mp4');
      // Same-stem srt attaches to the video; .txt is ignored, dir skipped.
      // subtitlePath is the ORIGINAL sidecar entry path (TODO-1274: looked
      // up from the entries, not rebuilt via p.join, so remote forward-slash
      // paths survive on a Windows host).
      expect(plan.videos.single.subtitlePath, '/lib/movie.srt');
    });

    test('video without a same-name subtitle has null subtitlePath', () {
      final List<SourceFileEntry> files = <SourceFileEntry>[
        _file('/lib/ep1.mkv'),
        _file('/lib/other.srt'),
      ];
      final ScanPlan plan = planScanFromFileList(files);
      expect(plan.videos.single.subtitlePath, isNull);
    });

    test('sidecar association is scoped per directory', () {
      final List<SourceFileEntry> files = <SourceFileEntry>[
        _file('/a/show.mkv'),
        _file('/b/show.srt'), // same stem but different dir -> not associated
      ];
      final ScanPlan plan = planScanFromFileList(files);
      expect(plan.videos.single.videoPath, '/a/show.mkv');
      expect(plan.videos.single.subtitlePath, isNull);
    });

    test('empty input yields empty plan; no IO', () {
      final ScanPlan plan = planScanFromFileList(const <SourceFileEntry>[]);
      expect(plan.books, isEmpty);
      expect(plan.videos, isEmpty);
      expect(plan.playlists, isEmpty);
      expect(plan.mangas, isEmpty);
    });

    // 漫画扫描根：.mokuro 分类进 mangas，不混进 books/videos/playlists；
    // 页图（jpg 等）不单独入计划（导入器自己按 mokuro 惯例探测同级图片）。
    test('.mokuro classifies as manga; page images are not planned', () {
      final List<SourceFileEntry> files = <SourceFileEntry>[
        _file('/lib/vol1.mokuro'),
        _file('/lib/images/p001.jpg'),
        _file('/lib/book.epub'),
        _file('/lib/movie.mp4'),
      ];
      final ScanPlan plan = planScanFromFileList(files);
      expect(
        plan.mangas.map((ScanMangaItem i) => i.mokuroPath).toList(),
        <String>['/lib/vol1.mokuro'],
      );
      // 既有分类零变化：EPUB/视频照旧，页图不出现在任何清单。
      expect(plan.books.single.epubPath, '/lib/book.epub');
      expect(plan.videos.single.videoPath, '/lib/movie.mp4');
      expect(plan.playlists, isEmpty);
    });

    // TODO-1237: .m3u8/.m3u manifests classify as PLAYLISTS (multi-episode),
    // reusing the drag-drop kDragPlaylistExtensions whitelist. They must NOT be
    // silently ignored (the reported bug) nor mis-classified as single videos.
    test('m3u8 / m3u manifests classify as playlists, not videos', () {
      final List<SourceFileEntry> files = <SourceFileEntry>[
        _file('/lib/series.m3u8'),
        _file('/lib/other.m3u'),
        _file('/lib/movie.mp4'),
      ];
      final ScanPlan plan = planScanFromFileList(files);
      expect(
        plan.playlists.map((ScanPlaylistItem i) => i.playlistPath).toList(),
        <String>['/lib/series.m3u8', '/lib/other.m3u'],
        reason: 'both m3u8 and m3u land in playlists',
      );
      // The single .mp4 stays a video; the manifests are not double-counted.
      expect(
        plan.videos.map((ScanVideoItem i) => i.videoPath).toList(),
        <String>['/lib/movie.mp4'],
      );
    });

    // TODO-946: a book with a same-stem sidecar subtitle AND audio becomes an
    // audiobook item (subtitle = alignment source, audio attached).
    test('EPUB + same-stem srt + mp3 -> audiobook book item', () {
      final List<SourceFileEntry> files = <SourceFileEntry>[
        _file('/lib/book.epub'),
        _file('/lib/book.srt'),
        _file('/lib/book.mp3'),
      ];
      final ScanPlan plan = planScanFromFileList(files);
      expect(plan.books, hasLength(1));
      final ScanBookItem b = plan.books.single;
      expect(b.epubPath, '/lib/book.epub');
      expect(b.subtitlePath, '/lib/book.srt');
      expect(b.audioPaths, <String>['/lib/book.mp3']);
      expect(b.isAudiobook, isTrue);
    });

    test('EPUB + srt but no audio -> plain book (not audiobook)', () {
      final List<SourceFileEntry> files = <SourceFileEntry>[
        _file('/lib/book.epub'),
        _file('/lib/book.srt'),
      ];
      final ScanPlan plan = planScanFromFileList(files);
      final ScanBookItem b = plan.books.single;
      expect(b.subtitlePath, '/lib/book.srt');
      expect(b.audioPaths, isEmpty);
      expect(b.isAudiobook, isFalse,
          reason: 'audio is required to import as an audiobook');
    });

    test('EPUB + mp3 but no subtitle -> plain book (audio needs subtitle)', () {
      final List<SourceFileEntry> files = <SourceFileEntry>[
        _file('/lib/book.epub'),
        _file('/lib/book.mp3'),
      ];
      final ScanPlan plan = planScanFromFileList(files);
      final ScanBookItem b = plan.books.single;
      expect(b.subtitlePath, isNull);
      // Audio is collected, but without a subtitle it cannot align -> plain EPUB.
      expect(b.isAudiobook, isFalse,
          reason: 'audio must be paired with a subtitle (sidecar semantics)');
    });

    test('multi-part audio (book + book 01 / book-02) attaches to the book',
        () {
      final List<SourceFileEntry> files = <SourceFileEntry>[
        _file('/lib/book.epub'),
        _file('/lib/book.srt'),
        _file('/lib/book 01.mp3'),
        _file('/lib/book-02.mp3'),
      ];
      final ScanPlan plan = planScanFromFileList(files);
      final ScanBookItem b = plan.books.single;
      expect(b.audioPaths, hasLength(2));
      expect(b.isAudiobook, isTrue);
    });
  });

  group('sourceId backfill is opt-in (backward compatible)', () {
    test('saveVideoBook without sourceId leaves the column NULL', () async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      final VideoBookRepository repo = VideoBookRepository(db);

      await repo.saveVideoBook(VideoBooksCompanion(
        bookUid: const Value('video/manual'),
        title: const Value('Manual'),
        videoPath: const Value('/m/manual.mp4'),
        importedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ));

      final VideoBookRow? row = await repo.getByBookUid('video/manual');
      expect(row, isNotNull);
      expect(row!.sourceId, isNull);
    });

    test('saveVideoBook with sourceId backfills the column', () async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      final VideoBookRepository repo = VideoBookRepository(db);

      final int sid = await db.insertMediaSource(MediaSourcesCompanion.insert(
        label: 'Vids',
        mediaKind: 'video',
        rootPath: '/srv/vids',
        createdAt: 1000,
      ));

      await repo.saveVideoBook(
        VideoBooksCompanion(
          bookUid: const Value('video/scanned'),
          title: const Value('Scanned'),
          videoPath: const Value('/srv/vids/scanned.mp4'),
          importedAt: Value(DateTime.now().millisecondsSinceEpoch),
        ),
        sourceId: sid,
      );

      final VideoBookRow? row = await repo.getByBookUid('video/scanned');
      expect(row!.sourceId, sid);
    });
  });

  group('SourceLibraryScanner.scan (real temp dir)', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('m1b_scanner_');
    });
    tearDown(() {
      try {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('video source: inserts videos with sourceId + cues + scan result',
        () async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      final VideoBookRepository repo = VideoBookRepository(db);

      // movie.mp4 + same-stem movie.srt -> one video with parsed cues.
      File(p.join(tmp.path, 'movie.mp4')).writeAsStringSync('fake-mp4');
      File(p.join(tmp.path, 'movie.srt')).writeAsStringSync(_srt);

      final int sid = await db.insertMediaSource(MediaSourcesCompanion.insert(
        label: 'Vids',
        mediaKind: 'video',
        rootPath: tmp.path,
        createdAt: 1000,
      ));
      final SourceLibraryRow source = (await db.getMediaSourceById(sid))!;

      await SourceLibraryScanner(db).scan(source);

      final List<VideoBookRow> videos = await repo.listAll();
      expect(videos, hasLength(1));
      expect(videos.single.sourceId, sid,
          reason: 'scanned video must be backfilled with its source id');
      expect(videos.single.videoPath, p.join(tmp.path, 'movie.mp4'));
      expect(videos.single.subtitleSource, p.join(tmp.path, 'movie.srt'));
      // Sidecar srt was parsed into cues.
      final List<AudioCueRow> cues =
          await db.getCuesForBook(videos.single.bookUid);
      expect(cues, isNotEmpty);

      // Scan result written back.
      final SourceLibraryRow after = (await db.getMediaSourceById(sid))!;
      expect(after.mediaCount, 1);
      expect(after.lastScannedAt, isNotNull);
      expect(after.lastScanError, isNull);
    });

    testWidgets('book source: imports EPUB with sourceId + scan result',
        (WidgetTester tester) async {
      final Directory pp =
          Directory.systemTemp.createTempSync('m1b_scanner_pp_');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (MethodCall call) async => pp.path,
      );
      addTearDown(() {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
        try {
          if (pp.existsSync()) pp.deleteSync(recursive: true);
        } catch (_) {}
      });

      final HibikiDatabase db = _memDb();
      addTearDown(db.close);

      _writeEpub(p.join(tmp.path, 'novel.epub'), 'ScannerNovel');

      final int sid = await db.insertMediaSource(MediaSourcesCompanion.insert(
        label: 'Books',
        mediaKind: 'book',
        rootPath: tmp.path,
        createdAt: 1000,
      ));
      final SourceLibraryRow source = (await db.getMediaSourceById(sid))!;

      // EpubImporter.importFromPath runs on a real isolate (compute); drive it
      // inside runAsync so the real event loop progresses.
      await tester.runAsync(() async {
        await SourceLibraryScanner(db).scan(source);
      });

      final List<EpubBookRow> books = await db.getAllEpubBooks();
      expect(books, hasLength(1));
      expect(books.single.title, 'ScannerNovel');
      expect(books.single.sourceId, sid,
          reason: 'scanned book must be backfilled with its source id');

      final SourceLibraryRow after = (await db.getMediaSourceById(sid))!;
      expect(after.mediaCount, 1);
      expect(after.lastScannedAt, isNotNull);
      expect(after.lastScanError, isNull);
    });
  });

  // ── BUG-443: folder-scan book dedup (no silent X (2) re-import) ──────
  // Manual single-file import asks / auto-suffixes; a batch folder scan must NOT
  // re-import an already-imported same-title book as "X (2)". _importBooks passes
  // skipIfExists:true -> EpubImporter throws DuplicateImportCancelledException on
  // a sanitizeTtuFilename key collision, which the scanner catches and skips.
  group('SourceLibraryScanner.scan book dedup (BUG-443)', () {
    late Directory tmp;
    late Directory pp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('bug443_scan_');
      pp = Directory.systemTemp.createTempSync('bug443_pp_');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (MethodCall call) async => pp.path,
      );
      // EpubStorage caches the base dir in a process-global static; pin it to
      // this test's pp so a prior test's (now-deleted) cached base can't leak.
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

    testWidgets('re-scanning an already-imported title imports no duplicate',
        (WidgetTester tester) async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);

      _writeEpub(p.join(tmp.path, 'dup.epub'), 'DupNovel');

      final int sid = await db.insertMediaSource(MediaSourcesCompanion.insert(
        label: 'Books',
        mediaKind: 'book',
        rootPath: tmp.path,
        createdAt: 1000,
      ));
      final SourceLibraryRow source = (await db.getMediaSourceById(sid))!;

      // First scan imports the book.
      await tester.runAsync(() async {
        await SourceLibraryScanner(db).scan(source);
      });
      expect(await db.getAllEpubBooks(), hasLength(1));

      // Second scan of the SAME folder must NOT import a second copy / "X (2)".
      await tester.runAsync(() async {
        await SourceLibraryScanner(db).scan(source);
      });

      final List<EpubBookRow> books = await db.getAllEpubBooks();
      expect(books, hasLength(1),
          reason: 'folder re-scan must dedup by title key, not create X (2)');
      expect(books.single.title, 'DupNovel');
      expect(
        books.where((EpubBookRow b) => b.title.contains('(2)')),
        isEmpty,
        reason: 'no silent X (2) duplicate from folder scan',
      );
      // mediaCount reflects only the newly-inserted (0 on the dedup re-scan).
      final SourceLibraryRow after = (await db.getMediaSourceById(sid))!;
      expect(after.mediaCount, 0,
          reason: 'second scan inserted nothing (all duplicates skipped)');
      expect(after.lastScanError, isNull);
    });

    testWidgets('a new title still imports while the duplicate is skipped',
        (WidgetTester tester) async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);

      // Pre-import "DupNovel" manually.
      _writeEpub(p.join(tmp.path, 'dup.epub'), 'DupNovel');
      final int sid = await db.insertMediaSource(MediaSourcesCompanion.insert(
        label: 'Books',
        mediaKind: 'book',
        rootPath: tmp.path,
        createdAt: 1000,
      ));
      SourceLibraryRow source = (await db.getMediaSourceById(sid))!;
      await tester.runAsync(() async {
        await SourceLibraryScanner(db).scan(source);
      });
      expect(await db.getAllEpubBooks(), hasLength(1));

      // Add a brand-new book to the folder, re-scan.
      _writeEpub(p.join(tmp.path, 'fresh.epub'), 'FreshNovel');
      source = (await db.getMediaSourceById(sid))!;
      await tester.runAsync(() async {
        await SourceLibraryScanner(db).scan(source);
      });

      final List<EpubBookRow> books = await db.getAllEpubBooks();
      expect(books, hasLength(2),
          reason: 'new title imports; duplicate skipped');
      expect(
        books.map((EpubBookRow b) => b.title).toSet(),
        <String>{'DupNovel', 'FreshNovel'},
      );
      final SourceLibraryRow after = (await db.getMediaSourceById(sid))!;
      expect(after.mediaCount, 1,
          reason: 'only the one new book counted on the second scan');
    });

    testWidgets('two same-title EPUBs in one scan import only one',
        (WidgetTester tester) async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);

      // Two different filenames but the SAME embedded title -> same identity key.
      _writeEpub(p.join(tmp.path, 'a.epub'), 'SameTitle');
      _writeEpub(p.join(tmp.path, 'b.epub'), 'SameTitle');

      final int sid = await db.insertMediaSource(MediaSourcesCompanion.insert(
        label: 'Books',
        mediaKind: 'book',
        rootPath: tmp.path,
        createdAt: 1000,
      ));
      final SourceLibraryRow source = (await db.getMediaSourceById(sid))!;

      await tester.runAsync(() async {
        await SourceLibraryScanner(db).scan(source);
      });

      final List<EpubBookRow> books = await db.getAllEpubBooks();
      expect(books, hasLength(1),
          reason: 'same-batch duplicate title imports once, no X (2)');
      expect(books.single.title, 'SameTitle');
      final SourceLibraryRow after = (await db.getMediaSourceById(sid))!;
      expect(after.mediaCount, 1);
    });
  });

  // ── TODO-1237: video-source folder scan imports m3u8/m3u playlists ─────
  // A .m3u8 manifest sitting in a scanned video source folder must import as a
  // PLAYLIST VideoBook (playlistJson carrying the parsed episodes), NOT be
  // ignored (the reported bug) and NOT be mis-imported as a single video.
  // Reuses parseM3u8 + saveVideoBook, the same persistence as the manual
  // "playlist" button and the drag-drop importNewPlaylist path.
  group('SourceLibraryScanner.scan video playlist (TODO-1237)', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('todo1237_scan_');
    });
    tearDown(() {
      try {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test(
        'm3u8 manifest imports as N per-episode rows + a playlist collection '
        '(统一合集 Phase 2)', () async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      final VideoBookRepository repo = VideoBookRepository(db);

      // A 2-episode m3u8; relative paths resolve against the manifest's dir.
      File(p.join(tmp.path, 'series.m3u8')).writeAsStringSync(
        '''
#EXTM3U
#EXTINF:-1,Episode 1
ep1.mp4
#EXTINF:-1,Episode 2
ep2.mp4
''',
      );

      final int sid = await db.insertMediaSource(MediaSourcesCompanion.insert(
        label: 'Vids',
        mediaKind: 'video',
        rootPath: tmp.path,
        createdAt: 1000,
      ));
      final SourceLibraryRow source = (await db.getMediaSourceById(sid))!;

      await SourceLibraryScanner(db).scan(source);

      // 拆集：2 条独立 per-episode VideoBooks 行（uid=video/<集文件名>），各自 videoPath，
      // 都不再写 playlistJson，都回填 sourceId。
      final List<VideoBookRow> videos = await repo.listAll();
      expect(videos, hasLength(2), reason: '2 集拆成 2 条独立 VideoBooks 行');
      final Map<String, VideoBookRow> byUid = <String, VideoBookRow>{
        for (final VideoBookRow r in videos) r.bookUid: r,
      };
      expect(byUid.keys.toSet(), <String>{'video/ep1', 'video/ep2'});
      for (final VideoBookRow r in videos) {
        expect(r.sourceId, sid, reason: 'scanned episodes backfilled sourceId');
        expect(r.playlistJson, isNull, reason: '拆集后不再写 playlistJson');
      }
      expect(byUid['video/ep1']!.videoPath,
          p.normalize(p.join(tmp.path, 'ep1.mp4')));

      // playlist 合集：type=playlist，名=m3u8 basename，成员按序 = 各集 uid。
      final List<MediaCollectionRow> collections =
          await db.getAllMediaCollections();
      expect(collections, hasLength(1));
      final MediaCollectionRow playlist = collections.single;
      expect(playlist.collectionType, 'playlist');
      expect(playlist.name, 'series');
      final List<MediaCollectionItemRow> members =
          await db.getCollectionItems(playlist.id);
      expect(members.map((MediaCollectionItemRow m) => m.entryKey).toList(),
          <String>['video/ep1', 'video/ep2']);

      final SourceLibraryRow after = (await db.getMediaSourceById(sid))!;
      expect(after.mediaCount, 1, reason: '1 个 playlist 合集导入');
      expect(after.lastScanError, isNull);
    });

    test('empty / comment-only m3u8 imports nothing (skipped, no error)',
        () async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      final VideoBookRepository repo = VideoBookRepository(db);

      // Only the header -> parseM3u8 yields no entries -> nothing inserted.
      File(p.join(tmp.path, 'empty.m3u8')).writeAsStringSync('''
#EXTM3U
''');

      final int sid = await db.insertMediaSource(MediaSourcesCompanion.insert(
        label: 'Vids',
        mediaKind: 'video',
        rootPath: tmp.path,
        createdAt: 1000,
      ));
      final SourceLibraryRow source = (await db.getMediaSourceById(sid))!;

      await SourceLibraryScanner(db).scan(source);

      expect(await repo.listAll(), isEmpty,
          reason: 'an empty manifest must not create an orphan VideoBook');
      final SourceLibraryRow after = (await db.getMediaSourceById(sid))!;
      expect(after.mediaCount, 0);
      expect(after.lastScanError, isNull);
    });

    // TODO-1237 ②: re-scanning the same video folder must NOT create `X (2)`
    // duplicates — already-imported single videos are skipped (path dedup),
    // mirroring _importBooks' skipIfExists (BUG-443).
    test('re-scan skips already-imported single videos (no X (2) dup)',
        () async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      final VideoBookRepository repo = VideoBookRepository(db);

      // Two standalone videos (empty files: cover extraction just yields null,
      // dedup is path-based, not content-based).
      File(p.join(tmp.path, 'A.mp4')).writeAsBytesSync(<int>[0]);
      File(p.join(tmp.path, 'B.mkv')).writeAsBytesSync(<int>[0]);

      final int sid = await db.insertMediaSource(MediaSourcesCompanion.insert(
        label: 'Vids',
        mediaKind: 'video',
        rootPath: tmp.path,
        createdAt: 1000,
      ));
      final SourceLibraryRow source = (await db.getMediaSourceById(sid))!;

      await SourceLibraryScanner(db).scan(source);
      expect(await repo.listAll(), hasLength(2));

      // Second scan of the unchanged folder: every file already imported.
      await SourceLibraryScanner(db).scan(source);
      final List<VideoBookRow> after = await repo.listAll();
      expect(after, hasLength(2),
          reason: 're-scan must import nothing new (dedup), not X (2) rows');
      expect(after.map((VideoBookRow r) => r.bookUid).toSet(), hasLength(2),
          reason: 'no suffixed duplicate book_uid');
      final SourceLibraryRow afterSrc = (await db.getMediaSourceById(sid))!;
      expect(afterSrc.mediaCount, 0,
          reason: 'second scan reports 0 newly-imported media');
    });

    // TODO-1237 ②: re-scanning a folder whose only manifest is a playlist must
    // not duplicate the playlist VideoBook either.
    test('re-scan skips already-imported m3u8 playlist (no duplicate)',
        () async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      final VideoBookRepository repo = VideoBookRepository(db);

      File(p.join(tmp.path, 'series.m3u8')).writeAsStringSync('''
#EXTM3U
#EXTINF:-1,Episode 1
ep1.mp4
#EXTINF:-1,Episode 2
ep2.mp4
''');

      final int sid = await db.insertMediaSource(MediaSourcesCompanion.insert(
        label: 'Vids',
        mediaKind: 'video',
        rootPath: tmp.path,
        createdAt: 1000,
      ));
      final SourceLibraryRow source = (await db.getMediaSourceById(sid))!;

      await SourceLibraryScanner(db).scan(source);
      expect(await repo.listAll(), hasLength(2)); // 2 集拆成 2 行

      await SourceLibraryScanner(db).scan(source);
      expect(await repo.listAll(), hasLength(2),
          reason: 're-scan must not duplicate the split episode rows');
      // 同名 playlist 合集仍只有一个（未重复建）。
      expect(
          (await db.getAllMediaCollections())
              .where((MediaCollectionRow c) => c.collectionType == 'playlist'),
          hasLength(1));
      final SourceLibraryRow afterSrc = (await db.getMediaSourceById(sid))!;
      expect(afterSrc.mediaCount, 0,
          reason: 'second scan reports 0 newly-imported playlists');
    });

    // TODO-1237 ②: the user's real bug — a manifest whose EPISODE PATHS change
    // between scans (they edited relative paths into absolute ones) must still
    // dedup by the STABLE m3u8 identity, NOT by the volatile first-episode path.
    // The old first-episode-path key produced an `X (2)` duplicate here.
    test(
        're-scan after manifest episode paths change: identity dedup, no X (2)',
        () async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      final VideoBookRepository repo = VideoBookRepository(db);

      final File manifest = File(p.join(tmp.path, 'series.m3u8'));
      manifest.writeAsStringSync('''
#EXTM3U
#EXTINF:-1,Episode 1
sub_a/ep1.mp4
#EXTINF:-1,Episode 2
sub_a/ep2.mp4
''');

      final int sid = await db.insertMediaSource(MediaSourcesCompanion.insert(
        label: 'Vids',
        mediaKind: 'video',
        rootPath: tmp.path,
        createdAt: 1000,
      ));
      final SourceLibraryRow source = (await db.getMediaSourceById(sid))!;

      await SourceLibraryScanner(db).scan(source);
      final List<VideoBookRow> first = await repo.listAll();
      expect(first, hasLength(2)); // 2 集拆成 2 行
      final Map<String, String> firstPathByUid = <String, String>{
        for (final VideoBookRow r in first) r.bookUid: r.videoPath,
      };

      // The user edits the manifest so every episode path differs (here a
      // different subdirectory), changing the resolved first-episode path. The
      // playlist collection identity (its basename-derived name) is unchanged.
      manifest.writeAsStringSync('''
#EXTM3U
#EXTINF:-1,Episode 1
sub_b/ep1.mp4
#EXTINF:-1,Episode 2
sub_b/ep2.mp4
''');

      await SourceLibraryScanner(db).scan(source);
      final List<VideoBookRow> after = await repo.listAll();
      expect(after, hasLength(2),
          reason: 'name dedup: same m3u8 basename => skip even though episode '
              'paths changed (a path-only key would make X (2) duplicates)');
      expect(
          after.where((VideoBookRow r) => r.bookUid.contains('(2)')), isEmpty,
          reason: 'no suffixed duplicate book_uid');
      // The surviving rows are the ORIGINAL import (skip, not overwrite): paths
      // still point at sub_a, not the edited sub_b.
      expect(<String, String>{
        for (final VideoBookRow r in after) r.bookUid: r.videoPath
      }, firstPathByUid,
          reason: 're-scan skips (does not rewrite) the already-imported rows');
      final SourceLibraryRow afterSrc = (await db.getMediaSourceById(sid))!;
      expect(afterSrc.mediaCount, 0,
          reason: 'second scan imported nothing new');
    });
  });

  // Source guard: _importBooks must keep the BUG-443 dedup wiring so a future
  // edit can't silently drop it and re-introduce X (2) folder-scan duplicates.
  test('source guard: _importBooks passes skipIfExists for dedup (BUG-443)',
      () {
    final String src = File(
      'lib/src/media/source_library/source_library_scanner.dart',
    ).readAsStringSync();
    expect(src.contains('skipIfExists: true'), isTrue,
        reason: '_importBooks must request silent dedup from the importer');
    expect(src.contains('DuplicateImportCancelledException'), isTrue,
        reason: '_importBooks must catch+skip the duplicate-cancel signal');
    // TODO-1237 ②: _importVideos keeps the physical-path re-scan dedup
    // (existingPaths.add short-circuit) so a future edit can't silently
    // reintroduce X (2) single-video folder-scan duplicates.
    expect(src.contains('existingPaths.add(normalizeVideoPath'), isTrue,
        reason: 'single-video scan must skip already-imported physical paths');
    // TODO-1237 ② / 统一合集 Phase 2 / BUG-830: _importPlaylists keys on the
    // STABLE playlist COLLECTION name (m3u8 basename). First import splits into
    // per-episode rows + a collection; a re-scan of an ALREADY-imported manifest
    // RECONCILES its members to the current manifest (add/remove diff) instead of
    // suffixing an X (2) duplicate. Guard the name-keyed collection map + the
    // reconcile wiring so a future edit can neither regress to a volatile
    // first-episode-path key nor drop the member-sync that BUG-830 restored.
    expect(src.contains('existingPlaylistIds[collectionName]'), isTrue,
        reason: 'playlist scan must key dedup by stable collection name');
    expect(src.contains('reconcileSplitPlaylist('), isTrue,
        reason: 'a re-scanned existing playlist must reconcile members to the '
            'current manifest (BUG-830), not silently skip');
    expect(src.contains('importSplitPlaylist('), isTrue,
        reason:
            'playlist scan must split into per-episode rows + a collection');
  });

  // TODO-1284: the duplicate-skip branch must still attach a sidecar srt+audio
  // added after first import. Guard the attach helper wiring so a future edit
  // can't collapse the catch back to a bare skip that drops the new subtitle.
  test('source guard: duplicate-skip attaches sidecar audiobook (TODO-1284)',
      () {
    final String src = File(
      'lib/src/media/source_library/source_library_scanner.dart',
    ).readAsStringSync();
    expect(src.contains('_attachSidecarAudiobookToExisting'), isTrue,
        reason:
            'the duplicate-skip branch must call the sidecar-attach helper');
    expect(src.contains('alignAndPersistAudiobook'), isTrue,
        reason: 'the attach helper must align+persist the newly-added sidecar');
  });

  // ── TODO-817 M1c T5: subtitle charset detection via copyToLocal ────────────
  // A real Shift-JIS .srt (Japanese cue) must decode correctly. These bytes
  // (こんにちは = 82 b1 82 f1 82 c9 82 bf 82 cd) are INVALID UTF-8, so the
  // scanner's readTextWithEncoding path falls back to the charset detector. If
  // the scanner used fs.readText (plain utf8.decode) instead, decoding would
  // throw, the scan would record lastScanError and parse zero cues -> RED. This
  // guards M1b TODO② (copyToLocal + readTextWithEncoding) from regressing back to
  // a UTF-8-only read. CharsetDetector.autoDecode is a native method channel
  // unavailable in headless flutter test, so we override its platform interface
  // with a Dart fake that decodes the known SJIS fixture.
  group('SourceLibraryScanner.scan subtitle charset (SJIS)', () {
    late Directory tmp;
    late CharsetDetectorPlatform original;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('m1c_sjis_');
      original = CharsetDetectorPlatform.instance;
      CharsetDetectorPlatform.instance = _FakeSjisCharsetDetector();
    });
    tearDown(() {
      CharsetDetectorPlatform.instance = original;
      try {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('Shift-JIS subtitle decodes to Japanese cue text', () async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);

      // SRT with a Japanese cue encoded as Shift-JIS bytes (invalid UTF-8).
      final List<int> sjis = <int>[];
      sjis.addAll('1\n00:00:01,000 --> 00:00:02,000\n'.codeUnits);
      // こんにちは in Shift-JIS / CP932.
      sjis.addAll(
          <int>[0x82, 0xb1, 0x82, 0xf1, 0x82, 0xc9, 0x82, 0xbf, 0x82, 0xcd]);
      sjis.add(0x0a);
      File(p.join(tmp.path, 'movie.mp4')).writeAsStringSync('fake-mp4');
      File(p.join(tmp.path, 'movie.srt')).writeAsBytesSync(sjis);

      final int sid = await db.insertMediaSource(MediaSourcesCompanion.insert(
        label: 'Vids',
        mediaKind: 'video',
        rootPath: tmp.path,
        createdAt: 1000,
      ));
      final SourceLibraryRow source = (await db.getMediaSourceById(sid))!;

      await SourceLibraryScanner(db).scan(source);

      // Scan succeeded (no error) and the SJIS cue decoded to Japanese.
      final SourceLibraryRow after = (await db.getMediaSourceById(sid))!;
      expect(after.lastScanError, isNull,
          reason:
              'SJIS subtitle must decode via readTextWithEncoding fallback, '
              'not throw on a UTF-8-only read');
      final VideoBookRepository repo = VideoBookRepository(db);
      final List<VideoBookRow> videos = await repo.listAll();
      expect(videos, hasLength(1));
      final List<AudioCueRow> cues =
          await db.getCuesForBook(videos.single.bookUid);
      expect(cues, isNotEmpty);
      expect(cues.first.cueText, contains('こんにちは'),
          reason: 'cue text must be the decoded Japanese, proving the scanner '
              'routed through readTextWithEncoding (SJIS), not fs.readText');
    });
  });

  // ── TODO-946: manage-sources book scan auto-attaches sibling audio ─────────
  // An EPUB with a same-stem .srt AND .mp3 in the same folder must import as an
  // AUDIOBOOK (paired Audiobooks row + cues + paired SrtBook), not a plain text
  // EPUB. Reuses the non-UI alignAndPersistAudiobook service extracted from the
  // import dialog. An EPUB with no sidecar audio must stay a plain EPUB (no
  // Audiobooks row) — proving the routing is gated on a sibling audio.
  group('SourceLibraryScanner.scan book sidecar audio (TODO-946)', () {
    late Directory tmp;
    late Directory pp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('todo946_scan_');
      pp = Directory.systemTemp.createTempSync('todo946_pp_');
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

    testWidgets('book.epub + book.srt + book.mp3 -> audiobook (cues + SrtBook)',
        (WidgetTester tester) async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);

      _writeEpub(p.join(tmp.path, 'book.epub'), 'AudiobookNovel');
      File(p.join(tmp.path, 'book.srt')).writeAsStringSync(_srt);
      // A fake mp3: the alignment service only copies the bytes + runs the text
      // matcher; it never decodes the audio, so raw bytes are sufficient.
      File(p.join(tmp.path, 'book.mp3')).writeAsStringSync('fake-mp3-bytes');

      final int sid = await db.insertMediaSource(MediaSourcesCompanion.insert(
        label: 'Books',
        mediaKind: 'book',
        rootPath: tmp.path,
        createdAt: 1000,
      ));
      final SourceLibraryRow source = (await db.getMediaSourceById(sid))!;

      await tester.runAsync(() async {
        await SourceLibraryScanner(db).scan(source);
      });

      final List<EpubBookRow> books = await db.getAllEpubBooks();
      expect(books, hasLength(1));
      final String bookKey = books.single.bookKey;
      expect(books.single.sourceId, sid);

      // The sibling audio promoted this book to an audiobook.
      final AudiobookRow? ab = await db.getAudiobookByBookKey(bookKey);
      expect(ab, isNotNull,
          reason: 'sibling srt + mp3 must auto-import as an audiobook');
      expect(ab!.audioPathsJson, isNotNull,
          reason: 'the sibling audio must be persisted onto the audiobook');

      // Cues parsed from the sidecar srt are stored under the bookKey.
      final List<AudioCueRow> cues = await db.getCuesForBook(bookKey);
      expect(cues, isNotEmpty,
          reason: 'the sidecar subtitle must be parsed into cues');

      // TODO-894 paired SrtBook row written so sync push can find it.
      final SrtBookRow? srtBook = await db.getSrtBookByBookKey(bookKey);
      expect(srtBook, isNotNull,
          reason: 'epub-backed audiobook needs a paired srt_books row');

      final SourceLibraryRow after = (await db.getMediaSourceById(sid))!;
      expect(after.mediaCount, 1);
      expect(after.lastScanError, isNull);
    });

    testWidgets('book.epub with NO sibling audio stays a plain EPUB',
        (WidgetTester tester) async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);

      // EPUB + same-stem srt but NO audio -> must stay a plain text EPUB.
      _writeEpub(p.join(tmp.path, 'plain.epub'), 'PlainNovel');
      File(p.join(tmp.path, 'plain.srt')).writeAsStringSync(_srt);

      final int sid = await db.insertMediaSource(MediaSourcesCompanion.insert(
        label: 'Books',
        mediaKind: 'book',
        rootPath: tmp.path,
        createdAt: 1000,
      ));
      final SourceLibraryRow source = (await db.getMediaSourceById(sid))!;

      await tester.runAsync(() async {
        await SourceLibraryScanner(db).scan(source);
      });

      final List<EpubBookRow> books = await db.getAllEpubBooks();
      expect(books, hasLength(1));
      final AudiobookRow? ab =
          await db.getAudiobookByBookKey(books.single.bookKey);
      expect(ab, isNull,
          reason: 'no sibling audio -> plain EPUB, no audiobook promotion');
    });
  });

  // ── TODO-1284: re-scan attaches a sidecar srt+audio ADDED after first import ─
  // A book first imported as a plain EPUB (no sibling srt/audio yet) must be
  // promoted to an audiobook on a later re-scan once the same-stem .srt + .mp3
  // appear next to it. Before the fix, _importBooks caught the duplicate-title
  // skip and returned without ever calling alignAndPersistAudiobook, so the
  // newly-added subtitle/audio were silently ignored (the user's report: "这个
  // 刷新应该附加上"). Attach is gated on the book having no audiobook yet, so a
  // repeat re-scan is idempotent and never re-runs the matcher.
  group('SourceLibraryScanner.scan re-scan sidecar attach (TODO-1284)', () {
    late Directory tmp;
    late Directory pp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('todo1284_scan_');
      pp = Directory.systemTemp.createTempSync('todo1284_pp_');
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

    testWidgets(
        'srt+mp3 added after first import -> re-scan promotes to audiobook',
        (WidgetTester tester) async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);

      // First scan: only the EPUB is present -> imports as a plain text EPUB.
      _writeEpub(p.join(tmp.path, 'book.epub'), 'RescanNovel');

      final int sid = await db.insertMediaSource(MediaSourcesCompanion.insert(
        label: 'Books',
        mediaKind: 'book',
        rootPath: tmp.path,
        createdAt: 1000,
      ));
      SourceLibraryRow source = (await db.getMediaSourceById(sid))!;

      await tester.runAsync(() async {
        await SourceLibraryScanner(db).scan(source);
      });

      final List<EpubBookRow> books = await db.getAllEpubBooks();
      expect(books, hasLength(1));
      final String bookKey = books.single.bookKey;
      expect(await db.getAudiobookByBookKey(bookKey), isNull,
          reason: 'no sidecar yet -> plain EPUB after first scan');

      // The user drops a same-stem .srt + .mp3 next to the book, then hits
      // "重新扫描" (re-scan).
      File(p.join(tmp.path, 'book.srt')).writeAsStringSync(_srt);
      File(p.join(tmp.path, 'book.mp3')).writeAsStringSync('fake-mp3-bytes');

      source = (await db.getMediaSourceById(sid))!;
      await tester.runAsync(() async {
        await SourceLibraryScanner(db).scan(source);
      });

      // Same book row (no X (2) duplicate), now promoted to an audiobook.
      final List<EpubBookRow> after = await db.getAllEpubBooks();
      expect(after, hasLength(1),
          reason: 're-scan must not create a duplicate book row');
      final AudiobookRow? ab = await db.getAudiobookByBookKey(bookKey);
      expect(ab, isNotNull,
          reason: 're-scan must promote the existing book to an audiobook '
              'once the sidecar srt+audio appear');
      expect(ab!.audioPathsJson, isNotNull,
          reason: 'the newly-added sibling audio must be persisted');

      final List<AudioCueRow> cues = await db.getCuesForBook(bookKey);
      expect(cues, isNotEmpty,
          reason: 'the newly-added sidecar subtitle must be parsed into cues');
      final SrtBookRow? srtBook = await db.getSrtBookByBookKey(bookKey);
      expect(srtBook, isNotNull,
          reason: 'epub-backed audiobook needs a paired srt_books row');

      // Re-scan inserted no NEW book, so mediaCount reflects zero new inserts.
      final SourceLibraryRow scanned = (await db.getMediaSourceById(sid))!;
      expect(scanned.mediaCount, 0,
          reason: 'attaching an audiobook to an existing book is not a new '
              'media insert');
      expect(scanned.lastScanError, isNull);
    });

    testWidgets('a third re-scan is idempotent (already-attached audiobook)',
        (WidgetTester tester) async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);

      // Book + sidecar srt + mp3 all present up front -> first scan already an
      // audiobook. A second scan must stay green and not duplicate anything.
      _writeEpub(p.join(tmp.path, 'book.epub'), 'IdempotentNovel');
      File(p.join(tmp.path, 'book.srt')).writeAsStringSync(_srt);
      File(p.join(tmp.path, 'book.mp3')).writeAsStringSync('fake-mp3-bytes');

      final int sid = await db.insertMediaSource(MediaSourcesCompanion.insert(
        label: 'Books',
        mediaKind: 'book',
        rootPath: tmp.path,
        createdAt: 1000,
      ));

      for (int i = 0; i < 2; i++) {
        final SourceLibraryRow source = (await db.getMediaSourceById(sid))!;
        await tester.runAsync(() async {
          await SourceLibraryScanner(db).scan(source);
        });
      }

      final List<EpubBookRow> books = await db.getAllEpubBooks();
      expect(books, hasLength(1),
          reason: 'repeat scans keep a single book row');
      final AudiobookRow? ab =
          await db.getAudiobookByBookKey(books.single.bookKey);
      expect(ab, isNotNull);
      final SourceLibraryRow after = (await db.getMediaSourceById(sid))!;
      expect(after.lastScanError, isNull);
    });
  });

  // ── 漫画扫描根（mediaKind='manga'）：.mokuro 经 MangaImporter 落库 ─────────
  // 首版边界：只认 .mokuro（不扫 CBZ/裸图，无 skipIfExists 身份契约会重复导入）、
  // 仅 local transport（网络 manga 按视频先例整体拒绝）。重扫去重走 BUG-443 范式
  // （skipIfExists -> DuplicateImportCancelledException 静默跳过）。
  group('SourceLibraryScanner.scan manga source', () {
    late Directory tmp;
    late Directory pp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('manga_scan_');
      pp = Directory.systemTemp.createTempSync('manga_scan_pp_');
      // MangaStorage.bookDirectory 复用 EpubStorage；钉住本测试的书目录根
      // （进程级静态缓存，防前一个测试已删除的缓存根泄漏，同 BUG-443 组）。
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

    test('manga source: imports .mokuro volume with sourceId + scan result',
        () async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);

      _writeMokuro(tmp.path, title: 'ScanVolume');

      final int sid = await db.insertMediaSource(MediaSourcesCompanion.insert(
        label: 'Manga',
        mediaKind: 'manga',
        rootPath: tmp.path,
        createdAt: 1000,
      ));
      final SourceLibraryRow source = (await db.getMediaSourceById(sid))!;

      await SourceLibraryScanner(db).scan(source);

      final List<EpubBookRow> books = await db.getAllEpubBooks();
      expect(books, hasLength(1));
      expect(books.single.format, 'manga',
          reason: 'mokuro 卷落 EpubBooks format=manga（第三种书）');
      expect(books.single.title, 'ScanVolume');
      expect(books.single.sourceId, sid,
          reason: 'scanned manga must be backfilled with its source id');

      final SourceLibraryRow after = (await db.getMediaSourceById(sid))!;
      expect(after.mediaCount, 1);
      expect(after.lastScannedAt, isNotNull);
      expect(after.lastScanError, isNull);

      // DAO 计数分支：manga 源按 epub_books(format='manga') 反向 COUNT。
      expect(await db.countMediaBySourceId(sid, 'manga'), 1);
    });

    test('re-scan skips the already-imported volume (silent dedup, 0 new)',
        () async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);

      _writeMokuro(tmp.path, title: 'RescanVolume');

      final int sid = await db.insertMediaSource(MediaSourcesCompanion.insert(
        label: 'Manga',
        mediaKind: 'manga',
        rootPath: tmp.path,
        createdAt: 1000,
      ));

      // 第一遍导入。
      SourceLibraryRow source = (await db.getMediaSourceById(sid))!;
      await SourceLibraryScanner(db).scan(source);
      expect(await db.getAllEpubBooks(), hasLength(1));

      // 第二遍重扫：同标题身份 key 命中 -> 静默跳过，不产生 X (2)、不算错误。
      source = (await db.getMediaSourceById(sid))!;
      await SourceLibraryScanner(db).scan(source);

      final List<EpubBookRow> books = await db.getAllEpubBooks();
      expect(books, hasLength(1),
          reason: 'manga re-scan must dedup by title key, not create X (2)');
      expect(books.single.title, 'RescanVolume');
      final SourceLibraryRow after = (await db.getMediaSourceById(sid))!;
      expect(after.mediaCount, 0,
          reason: 'second scan inserted nothing (duplicate skipped)');
      expect(after.lastScanError, isNull);
    });

    test('empty folder: 0 media, no error', () async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);

      final int sid = await db.insertMediaSource(MediaSourcesCompanion.insert(
        label: 'Manga',
        mediaKind: 'manga',
        rootPath: tmp.path,
        createdAt: 1000,
      ));
      final SourceLibraryRow source = (await db.getMediaSourceById(sid))!;

      await SourceLibraryScanner(db).scan(source);

      expect(await db.getAllEpubBooks(), isEmpty);
      final SourceLibraryRow after = (await db.getMediaSourceById(sid))!;
      expect(after.mediaCount, 0);
      expect(after.lastScanError, isNull);
    });

    test('non-local transport is rejected (first-version limit)', () async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);

      final int sid = await db.insertMediaSource(MediaSourcesCompanion.insert(
        label: 'Manga',
        mediaKind: 'manga',
        rootPath: '/srv/manga',
        createdAt: 1000,
      ));
      final SourceLibraryRow source = (await db.getMediaSourceById(sid))!;

      await SourceLibraryScanner(db).scan(source, fs: _FakeRemoteFs());

      expect(await db.getAllEpubBooks(), isEmpty);
      final SourceLibraryRow after = (await db.getMediaSourceById(sid))!;
      expect(after.lastScanError, contains('Network manga sources'),
          reason: '网络 manga 源按视频先例整体拒绝并记进 lastScanError');
      expect(after.mediaCount, 0);
    });
  });

  // 漫画扫描守卫：_importManga 必须保持 mokuro-only 白名单 + skipIfExists 静默
  // 去重接线（BUG-443 范式），防未来编辑悄悄放开 CBZ/裸图或退化成重复导入。
  test('source guard: manga scan is mokuro-only with silent dedup', () {
    final String src = File(
      'lib/src/media/source_library/source_library_scanner.dart',
    ).readAsStringSync();
    expect(src.contains("kScanMangaExtensions = <String>{'mokuro'}"), isTrue,
        reason: '首版只认 .mokuro（CBZ/裸图无 skipIfExists 身份契约）');
    expect(src.contains('MangaImporter.importFromMokuroPath'), isTrue,
        reason: '漫画扫描必须复用既有 mokuro 导入链（不自造落库路径）');
  });
}

/// Fake [CharsetDetectorPlatform] for headless tests: decodes the known
/// Shift-JIS SRT fixture (ASCII bytes 1:1, the こんにちは SJIS run -> Japanese).
/// Only used as the fallback when utf8.decode throws on the SJIS bytes.
class _FakeSjisCharsetDetector extends CharsetDetectorPlatform
    with MockPlatformInterfaceMixin {
  @override
  Future<DecodingResult> autoDecode(Uint8List bytes) async {
    final StringBuffer out = StringBuffer();
    int i = 0;
    while (i < bytes.length) {
      final int b = bytes[i];
      if (b < 0x80) {
        out.writeCharCode(b);
        i += 1;
        continue;
      }
      // Shift-JIS double-byte lead (0x81-0x9F or 0xE0-0xFC).
      if (i + 1 < bytes.length) {
        final int lo = bytes[i + 1];
        final String? ch = _sjisPair(b, lo);
        if (ch != null) {
          out.write(ch);
          i += 2;
          continue;
        }
      }
      i += 1; // skip unknown byte
    }
    return DecodingResult.fromJson(<String, dynamic>{
      'charset': 'Shift_JIS',
      'string': out.toString(),
    });
  }

  /// Minimal SJIS->Unicode table for the fixture's こんにちは.
  String? _sjisPair(int hi, int lo) {
    const Map<int, String> table = <int, String>{
      0x82b1: 'こ',
      0x82f1: 'ん',
      0x82c9: 'に',
      0x82bf: 'ち',
      0x82cd: 'は',
    };
    return table[(hi << 8) | lo];
  }
}

/// 非 local 传输的假文件系统：只用于断言 scan 入口的 transport 门（manga 首版
/// 拒网络源）。门在 listFiles 之前触发，故各方法不应被走到——走到即测试失败。
class _FakeRemoteFs implements SourceFileSystem {
  @override
  bool get isLocal => false;

  @override
  Future<List<SourceFileEntry>> listFiles(
    String dirPath, {
    bool recursive = false,
  }) async {
    throw StateError('transport gate must reject before listing');
  }

  @override
  Future<List<String>> listSiblingNames(String filePath) async =>
      const <String>[];

  @override
  Future<String> readText(String filePath) async =>
      throw StateError('unexpected readText on rejected remote fs');

  @override
  Future<String> copyToLocal(String filePath, String destDir) async =>
      throw StateError('unexpected copyToLocal on rejected remote fs');
}
