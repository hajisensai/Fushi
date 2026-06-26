// TODO-817 M1b MediaSourceScanner + sourceId backfill tests:
//  (1) planScanFromFileList pure: classifies epub/video/srt from a
//      SourceFileEntry list, associates same-stem subtitle sidecar, no IO.
//  (2) MediaSourceScanner.scan over a real temp dir (video kind): inserts video
//      rows with sourceId + parses sidecar cues + writes updateMediaSourceScanResult.
//  (3) MediaSourceScanner.scan over a real temp dir (book kind): imports EPUB via
//      the real isolate, epub_books.sourceId backfilled.
//  (4) sourceId backfill is opt-in: saveVideoBook/EpubImporter without sourceId
//      leave the column NULL (backward compatible).

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/source/media_source_scanner.dart';
import 'package:hibiki/src/media/source/source_file_system.dart';
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

      expect(plan.epubPaths, <String>['/lib/book.epub']);
      expect(plan.videos, hasLength(1));
      expect(plan.videos.single.videoPath, '/lib/movie.mp4');
      // Same-stem srt attaches to the video; .txt is ignored, dir skipped.
      // subtitlePath is built via p.join(dir, name) -> use p.join to stay
      // platform-agnostic (Windows uses a backslash separator).
      expect(plan.videos.single.subtitlePath, p.join('/lib', 'movie.srt'));
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
      expect(plan.epubPaths, isEmpty);
      expect(plan.videos, isEmpty);
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
        importedAt: Value(DateTime.now()),
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
          importedAt: Value(DateTime.now()),
        ),
        sourceId: sid,
      );

      final VideoBookRow? row = await repo.getByBookUid('video/scanned');
      expect(row!.sourceId, sid);
    });
  });

  group('MediaSourceScanner.scan (real temp dir)', () {
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
      final MediaSourceRow source = (await db.getMediaSourceById(sid))!;

      await MediaSourceScanner(db).scan(source);

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
      final MediaSourceRow after = (await db.getMediaSourceById(sid))!;
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
      final MediaSourceRow source = (await db.getMediaSourceById(sid))!;

      // EpubImporter.importFromPath runs on a real isolate (compute); drive it
      // inside runAsync so the real event loop progresses.
      await tester.runAsync(() async {
        await MediaSourceScanner(db).scan(source);
      });

      final List<EpubBookRow> books = await db.getAllEpubBooks();
      expect(books, hasLength(1));
      expect(books.single.title, 'ScannerNovel');
      expect(books.single.sourceId, sid,
          reason: 'scanned book must be backfilled with its source id');

      final MediaSourceRow after = (await db.getMediaSourceById(sid))!;
      expect(after.mediaCount, 1);
      expect(after.lastScannedAt, isNotNull);
      expect(after.lastScanError, isNull);
    });
  });
}
