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
import 'package:flutter_charset_detector_platform_interface/decoding_result.dart';
import 'package:flutter_charset_detector_platform_interface/flutter_charset_detector_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
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
  group('MediaSourceScanner.scan subtitle charset (SJIS)', () {
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
      final MediaSourceRow source = (await db.getMediaSourceById(sid))!;

      await MediaSourceScanner(db).scan(source);

      // Scan succeeded (no error) and the SJIS cue decoded to Japanese.
      final MediaSourceRow after = (await db.getMediaSourceById(sid))!;
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
