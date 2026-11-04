import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/sync/fushi_screen_ocr_host.dart';
import 'package:image/image.dart' as img;
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

/// 记录收到的文字图尺寸，按 [result] 回结果。
class _FakeSession implements MangaOcrPageSession, MangaOcrTextImageSession {
  _FakeSession(this.result);

  final OcrRecognition result;
  final List<(int, int)> sizes = <(int, int)>[];
  bool closed = false;

  @override
  Future<OcrRecognition> recognizeTextImage(
    Uint8List rgba, {
    required int width,
    required int height,
  }) async {
    expect(rgba.length, width * height * 4);
    sizes.add((width, height));
    return result;
  }

  @override
  Future<String> ocrPage(String relativeUrl) =>
      Future<String>.error(StateError('text images only'));

  @override
  Future<void> close() async => closed = true;
}

class _FakeService implements MangaOcrService, MangaOcrPageService {
  _FakeService(this.result, {this.ready = true});

  final OcrRecognition result;
  bool ready;
  final List<_FakeSession> sessions = <_FakeSession>[];
  final List<bool> textImagesOnlyFlags = <bool>[];

  @override
  bool get isSupportedPlatform => true;

  @override
  Future<MangaOcrModelStatus> modelStatus() async => MangaOcrModelStatus(
    detectorReady: ready,
    recognizerReady: ready,
    diskBytes: 0,
    totalBytes: 0,
  );

  @override
  Future<MangaOcrPageSession> openPageSession({
    required String imageDirPath,
    void Function(MangaOcrAcceleration acceleration)? onAcceleration,
    bool textImagesOnly = false,
  }) async {
    textImagesOnlyFlags.add(textImagesOnly);
    final _FakeSession session = _FakeSession(result);
    sessions.add(session);
    return session;
  }

  @override
  Future<String> resolvePageCacheDirPath({required String imageDirPath}) =>
      throw UnimplementedError();

  @override
  Stream<MangaOcrDownloadEvent> downloadModels() => throw UnimplementedError();

  @override
  Future<int> deleteModels() => throw UnimplementedError();

  @override
  Stream<MangaOcrVolumeEvent> ocrFolder({
    required String imageDirPath,
    String? volumeTitle,
    int startPage = 0,
  }) => throw UnimplementedError();
}

OcrRect _rect(double l, double t, double r, double b) =>
    OcrRect(left: l, top: t, right: r, bottom: b);

/// 两行「ab」「cde」，逐字框按拼接后的文字记区间。
final OcrRecognition _twoLines = OcrRecognition(
  text: 'abcde',
  vertical: false,
  lines: const <String>['ab', 'cde'],
  lineBoxes: <OcrRect>[_rect(0, 0, 20, 10), _rect(0, 12, 30, 22)],
  glyphBoxes: <OcrGlyphBox>[
    OcrGlyphBox(start: 0, end: 1, rect: _rect(0, 0, 10, 10)),
    OcrGlyphBox(start: 1, end: 2, rect: _rect(10, 0, 20, 10)),
    OcrGlyphBox(start: 2, end: 3, rect: _rect(0, 12, 10, 22)),
    OcrGlyphBox(start: 3, end: 4, rect: _rect(10, 12, 20, 22)),
    OcrGlyphBox(start: 4, end: 5, rect: _rect(20, 12, 30, 22)),
  ],
);

Uint8List _png(int width, int height) =>
    Uint8List.fromList(img.encodePng(img.Image(width: width, height: height)));

shelf.Request _post(Uint8List body, {String query = ''}) => shelf.Request(
  'POST',
  Uri.parse('http://localhost$kScreenOcrPath$query'),
  body: body,
);

void main() {
  late Directory work;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('screen_ocr_test');
  });

  tearDown(() async {
    if (await work.exists()) await work.delete(recursive: true);
  });

  group('ScreenOcrRegion.tryParse', () {
    test('accepts x,y,w,h', () {
      final ScreenOcrRegion? r = ScreenOcrRegion.tryParse('10, 20,300,40');
      expect((r!.x, r.y, r.width, r.height), (10, 20, 300, 40));
      expect(r.fitsIn(310, 60), isTrue);
      expect(r.fitsIn(309, 60), isFalse);
    });

    test('rejects malformed or empty regions', () {
      for (final String bad in <String>[
        '',
        '1,2,3',
        '1,2,3,4,5',
        'a,2,3,4',
        '-1,0,5,5',
        '0,0,0,5',
      ]) {
        expect(ScreenOcrRegion.tryParse(bad), isNull, reason: bad);
      }
    });
  });

  group('screenOcrLines', () {
    test('splits glyph boxes per line with line-relative offsets', () {
      final List<ScreenOcrLine> lines = screenOcrLines(
        _twoLines,
        fallbackBox: _rect(0, 0, 100, 100),
        dx: 100,
        dy: 50,
      );
      expect(lines.map((ScreenOcrLine l) => l.text), <String>['ab', 'cde']);
      expect(lines[1].box.left, 100);
      expect(lines[1].box.top, 62);
      final List<OcrGlyphBox> second = lines[1].glyphs!;
      expect(second.map((OcrGlyphBox g) => (g.start, g.end)), <(int, int)>[
        (0, 1),
        (1, 2),
        (2, 3),
      ]);
      expect(second.last.rect.left, 120);
      expect(second.last.rect.top, 62);
    });

    test('whole-block text without line geometry becomes one line', () {
      final List<ScreenOcrLine> lines = screenOcrLines(
        const OcrRecognition(text: '縦書き', vertical: true),
        fallbackBox: _rect(0, 0, 40, 90),
      );
      expect(lines, hasLength(1));
      expect(lines.single.text, '縦書き');
      expect(lines.single.box.bottom, 90);
      expect(lines.single.glyphs, isNull);
    });

    test('empty recognition gives no lines', () {
      expect(
        screenOcrLines(
          const OcrRecognition(text: '', vertical: false),
          fallbackBox: _rect(0, 0, 1, 1),
        ),
        isEmpty,
      );
    });
  });

  group('ScreenOcrHost.handle', () {
    test('returns lines and reuses one text-image session', () async {
      final _FakeService service = _FakeService(_twoLines);
      final ScreenOcrHost host = ScreenOcrHost(service: service, workDir: work);
      addTearDown(host.dispose);

      for (int i = 0; i < 2; i++) {
        final shelf.Response res = await host.handle(_post(_png(64, 32)));
        expect(res.statusCode, 200);
        final Map<String, dynamic> json =
            jsonDecode(await res.readAsString()) as Map<String, dynamic>;
        expect((json['width'], json['height']), (64, 32));
        final List<dynamic> lines = json['lines'] as List<dynamic>;
        expect(
          lines.map((dynamic l) => (l as Map<String, dynamic>)['text']),
          <String>['ab', 'cde'],
        );
        expect(
          ((lines[1] as Map<String, dynamic>)['glyphs'] as List).length,
          3,
        );
      }
      expect(service.sessions, hasLength(1));
      expect(service.textImagesOnlyFlags, <bool>[true]);
    });

    test('region crops the frame and shifts boxes back', () async {
      final _FakeService service = _FakeService(_twoLines);
      final ScreenOcrHost host = ScreenOcrHost(service: service, workDir: work);
      addTearDown(host.dispose);

      final shelf.Response res = await host.handle(
        _post(_png(200, 100), query: '?region=50,60,40,30'),
      );
      expect(res.statusCode, 200);
      expect(service.sessions.single.sizes.single, (40, 30));
      final Map<String, dynamic> json =
          jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect((json['width'], json['height']), (200, 100));
      final Map<String, dynamic> box =
          ((json['lines'] as List<dynamic>).first
                  as Map<String, dynamic>)['box']
              as Map<String, dynamic>;
      expect((box['left'], box['top']), (50.0, 60.0));
    });

    test('rejects bad requests', () async {
      final ScreenOcrHost host = ScreenOcrHost(
        service: _FakeService(_twoLines),
        workDir: work,
      );
      addTearDown(host.dispose);

      expect(
        (await host.handle(
          shelf.Request('GET', Uri.parse('http://localhost$kScreenOcrPath')),
        )).statusCode,
        405,
      );
      expect((await host.handle(_post(Uint8List(0)))).statusCode, 400);
      expect(
        (await host.handle(
          _post(Uint8List.fromList(utf8.encode('not an image'))),
        )).statusCode,
        400,
      );
      expect(
        (await host.handle(
          _post(_png(20, 20), query: '?region=bad'),
        )).statusCode,
        400,
      );
      expect(
        (await host.handle(
          _post(_png(20, 20), query: '?region=10,10,20,20'),
        )).statusCode,
        400,
      );
    });

    test('503 while models are missing, then works once ready', () async {
      final _FakeService service = _FakeService(_twoLines, ready: false);
      final ScreenOcrHost host = ScreenOcrHost(service: service, workDir: work);
      addTearDown(host.dispose);

      expect(await host.isAvailable(), isFalse);
      expect((await host.handle(_post(_png(8, 8)))).statusCode, 503);
      expect(service.sessions, isEmpty);

      service.ready = true;
      expect(await host.isAvailable(), isTrue);
      expect((await host.handle(_post(_png(8, 8)))).statusCode, 200);
    });

    test('closes the session when idle and on dispose', () async {
      final _FakeService service = _FakeService(_twoLines);
      final ScreenOcrHost host = ScreenOcrHost(
        service: service,
        workDir: work,
        idleTimeout: const Duration(milliseconds: 20),
      );

      await host.handle(_post(_png(8, 8)));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(service.sessions.single.closed, isTrue);

      await host.handle(_post(_png(8, 8)));
      expect(service.sessions, hasLength(2));
      await host.dispose();
      expect(service.sessions.last.closed, isTrue);
      expect((await host.handle(_post(_png(8, 8)))).statusCode, 503);
    });
  });
}
