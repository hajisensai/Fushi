import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect, Size;
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mokuro_payload.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_ocr_service.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_protocol.dart';
import 'package:fushi/src/ocr/manga_ocr_folder_job.dart';
import 'package:fushi/src/ocr/manga_ocr_service.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'google_lens_fixture.dart';

class _FakeTransport implements GoogleLensTransport {
  _FakeTransport(this.response);

  final Uint8List response;
  int requests = 0;

  @override
  Future<Uint8List> post(Uint8List body) async {
    requests += 1;
    return response;
  }
}

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('lens_ocr_');
    for (int index = 1; index <= 2; index++) {
      File(p.join(root.path, 'p$index.png')).writeAsBytesSync(
        img.encodePng(img.Image(width: 100 + index, height: 200)),
      );
    }
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('serial page OCR writes engine metadata and character regions',
      () async {
    final _FakeTransport transport = _FakeTransport(makeGoogleLensFixture());
    final GoogleLensMangaOcrService service =
        GoogleLensMangaOcrService(transport: transport);
    final List<MangaOcrVolumeEvent> events = await service
        .ocrFolder(imageDirPath: root.path, onlyMissing: false)
        .toList();

    expect(transport.requests, 2);
    expect(events.last.finished, isTrue);
    final MokuroPayload payload =
        parseMangaJson(File(events.last.mangaJsonPath!).readAsStringSync());
    expect(payload.ocr?.engine, 'google_lens');
    expect(payload.ocr?.engineSignature, kGoogleLensEngineSignature);
    expect(payload.images, hasLength(2));
    expect(payload.images.first.blocks.single.lines.single, '日本');
    expect(payload.images.first.blocks.single.regions, hasLength(2));
  });

  test('page cache resumes without another network request', () async {
    final _FakeTransport first = _FakeTransport(makeGoogleLensFixture());
    await GoogleLensMangaOcrService(transport: first)
        .ocrFolder(imageDirPath: root.path, onlyMissing: false)
        .drain<void>();
    expect(first.requests, 2);

    final _FakeTransport second = _FakeTransport(makeGoogleLensFixture());
    await GoogleLensMangaOcrService(transport: second)
        .ocrFolder(imageDirPath: root.path, onlyMissing: false)
        .drain<void>();
    expect(second.requests, 0);
  });

  test('legacy cache is unflipped and restored in visual reading order',
      () async {
    final List<MangaOcrPageFile> pages = enumerateMangaPages(root);
    final Directory directory = Directory(p.join(
      root.path,
      kMangaOcrOutDirName,
      kMangaOcrPagesCacheDirName,
      kGoogleLensEngineSignature,
    ));
    final GoogleLensPageCache writer = GoogleLensPageCache(directory);
    await writer.write(
      0,
      pages[0],
      MokuroImage(
        url: pages[0].relativeUrl,
        size: const Size(101, 200),
        blocks: const <MokuroBlock>[
          MokuroBlock(
            rectangle: Rect.fromLTWH(10, 20, 60, 80),
            isVertical: false,
            fontSize: 10,
            zIndex: 0,
            lines: <String>['下上'],
            regions: <MangaOcrTextRegion>[
              MangaOcrTextRegion(
                rectangle: Rect.fromLTWH(10, 20, 10, 10),
                utf16Start: 0,
                utf16End: 1,
              ),
              MangaOcrTextRegion(
                rectangle: Rect.fromLTWH(10, 80, 10, 10),
                utf16Start: 1,
                utf16End: 2,
              ),
            ],
          ),
        ],
      ),
    );
    final File cacheFile = File(p.join(directory.path, '000000.json'));
    final Map<String, dynamic> legacy =
        jsonDecode(await cacheFile.readAsString()) as Map<String, dynamic>;
    legacy.remove('geometry_version');
    await cacheFile.writeAsString(jsonEncode(legacy), flush: true);

    final MokuroImage restored =
        (await GoogleLensPageCache(directory).read(0, pages[0]))!;
    expect(restored.blocks.single.lines.single, '上下');
    expect(restored.blocks.single.rectangle.top, 100);
    expect(
      restored.blocks.single.regions!.first.rectangle.top,
      lessThan(restored.blocks.single.regions!.last.rectangle.top),
    );
  });

  test('source change invalidates only that Lens page', () async {
    await GoogleLensMangaOcrService(
      transport: _FakeTransport(makeGoogleLensFixture()),
    ).ocrFolder(imageDirPath: root.path, onlyMissing: false).drain<void>();
    await Future<void>.delayed(const Duration(milliseconds: 2));
    File(p.join(root.path, 'p2.png')).writeAsBytesSync(
      img.encodePng(img.Image(width: 222, height: 200)),
      flush: true,
    );

    final _FakeTransport transport = _FakeTransport(makeGoogleLensFixture());
    await GoogleLensMangaOcrService(transport: transport)
        .ocrFolder(imageDirPath: root.path, onlyMissing: false)
        .drain<void>();
    expect(transport.requests, 1);
  });

  test('start page scans to the end then wraps to the beginning', () async {
    final List<int> progress = <int>[];
    final GoogleLensMangaOcrService service = GoogleLensMangaOcrService(
      transport: _FakeTransport(makeGoogleLensFixture()),
    );
    final List<MangaOcrVolumeEvent> events = await service
        .ocrFolder(
          imageDirPath: root.path,
          startPage: 1,
          onlyMissing: false,
        )
        .toList();
    progress.addAll(
      events.where((MangaOcrVolumeEvent e) => !e.finished).map(
            (MangaOcrVolumeEvent e) => e.pagesDone,
          ),
    );
    expect(progress, <int>[1, 2]);
  });
}
