import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ocr/local_screen_ocr.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:image/image.dart' as img;

/// Linux screen OCR runs on the local OCR model (Linux has no system OCR): the
/// freeze layer needs lines in screenshot pixels, and a missing model must come
/// back as "model unavailable", not as a generic failure.
void main() {
  group('systemOcrPageFromRecognition', () {
    test('one line per recognized line, boxes in screenshot pixels', () {
      final SystemOcrPageResult page = systemOcrPageFromRecognition(
        const OcrRecognition(
          text: '勉強する\n食べる',
          vertical: false,
          lines: <String>['勉強する', ' 食べる '],
          lineBoxes: <OcrRect>[
            OcrRect(left: 10, top: 20, right: 110, bottom: 44),
            OcrRect(left: 10, top: 60, right: 90, bottom: 84),
          ],
        ),
        width: 1280,
        height: 800,
      );
      expect(page.imageWidth, 1280);
      expect(page.imageHeight, 800);
      expect(page.lines.map((SystemOcrTextLine l) => l.text), <String>[
        '勉強する',
        '食べる',
      ]);
      expect(page.lines.first.rect, const Rect.fromLTRB(10, 20, 110, 44));
      expect(page.lines.every((SystemOcrTextLine l) => !l.isVertical), isTrue);
    });

    test('drops empty lines and boxes without area', () {
      final SystemOcrPageResult page = systemOcrPageFromRecognition(
        const OcrRecognition(
          text: 'あ',
          vertical: true,
          lines: <String>['  ', 'あ', 'い'],
          lineBoxes: <OcrRect>[
            OcrRect(left: 0, top: 0, right: 10, bottom: 10),
            OcrRect(left: 5, top: 5, right: 25, bottom: 60),
            OcrRect(left: 30, top: 5, right: 30, bottom: 60),
          ],
        ),
        width: 100,
        height: 100,
      );
      expect(page.lines, hasLength(1));
      expect(page.lines.single.text, 'あ');
      expect(page.lines.single.isVertical, isTrue);
    });

    test('text without line geometry becomes one line over the image', () {
      final SystemOcrPageResult page = systemOcrPageFromRecognition(
        const OcrRecognition(text: ' 文字 ', vertical: false),
        width: 640,
        height: 360,
      );
      expect(page.lines.single.text, '文字');
      expect(page.lines.single.rect, const Rect.fromLTWH(0, 0, 640, 360));
    });

    test('nothing read -> empty page', () {
      expect(
        systemOcrPageFromRecognition(
          const OcrRecognition(text: '', vertical: false),
          width: 1,
          height: 1,
        ).isEmpty,
        isTrue,
      );
    });
  });

  group('LocalScreenOcr', () {
    late Directory work;
    final Uint8List png = Uint8List.fromList(
      img.encodePng(img.Image(width: 4, height: 2)),
    );

    setUp(() => work = Directory.systemTemp.createTempSync('screen_ocr_'));
    tearDown(() => work.deleteSync(recursive: true));

    test(
      'model not downloaded -> model_unavailable, no session opened',
      () async {
        final _FakeService service = _FakeService(ready: false);
        final LocalScreenOcr ocr = LocalScreenOcr(service, workDir: work);
        expect(await ocr.isAvailable(), isFalse);
        await expectLater(
          ocr.recognize(png, language: 'ja'),
          throwsA(
            isA<SystemOcrUnavailableException>().having(
              (SystemOcrUnavailableException e) => e.reason,
              'reason',
              kSystemOcrModelUnavailableReason,
            ),
          ),
        );
        expect(service.opened, 0);
      },
    );

    test('decodes the PNG to RGBA, reuses one text-image session', () async {
      final _FakeService service = _FakeService(ready: true);
      final LocalScreenOcr ocr = LocalScreenOcr(service, workDir: work);
      final SystemOcrPageResult first = await ocr.recognize(
        png,
        language: 'ja',
      );
      await ocr.recognize(png, language: 'ja');
      expect(service.opened, 1);
      expect(service.textImagesOnly, isTrue);
      expect(service.session.sizes, <String>['4x2:32', '4x2:32']);
      expect(first.lines.single.text, '日本語');
      await ocr.dispose();
      expect(service.session.closed, isTrue);
    });

    test(
      'idle timer never closes the session under a running recognition',
      () async {
        final _FakeService service = _FakeService(ready: true);
        final LocalScreenOcr ocr = LocalScreenOcr(
          service,
          workDir: work,
          idleTimeout: const Duration(milliseconds: 40),
        );
        await ocr.recognize(png, language: 'ja');
        // The second one starts before the first one's idle timer fires and
        // is still running when it would have fired.
        final Completer<void> gate = Completer<void>();
        service.session.gate = gate;
        final Future<SystemOcrPageResult> running = ocr.recognize(
          png,
          language: 'ja',
        );
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(service.session.closed, isFalse);
        gate.complete();
        expect((await running).lines.single.text, '日本語');
        // Idle again: now it closes.
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(service.session.closed, isTrue);
      },
    );

    test('an image that does not decode is a format error', () async {
      final LocalScreenOcr ocr = LocalScreenOcr(
        _FakeService(ready: true),
        workDir: work,
      );
      await expectLater(
        ocr.recognize(Uint8List.fromList(<int>[1, 2, 3]), language: 'ja'),
        throwsFormatException,
      );
    });
  });
}

class _FakeSession implements MangaOcrPageSession, MangaOcrTextImageSession {
  final List<String> sizes = <String>[];
  bool closed = false;
  Completer<void>? gate;

  @override
  Future<OcrRecognition> recognizeTextImage(
    Uint8List rgba, {
    required int width,
    required int height,
  }) async {
    sizes.add('${width}x$height:${rgba.length}');
    await gate?.future;
    return const OcrRecognition(
      text: '日本語',
      vertical: false,
      lines: <String>['日本語'],
      lineBoxes: <OcrRect>[OcrRect(left: 0, top: 0, right: 3, bottom: 2)],
    );
  }

  @override
  Future<void> close() async => closed = true;

  @override
  Future<String> ocrPage(String relativeUrl) => throw StateError('text only');
}

class _FakeService implements MangaOcrService, MangaOcrPageService {
  _FakeService({required this.ready});

  final bool ready;
  final _FakeSession session = _FakeSession();
  int opened = 0;
  bool? textImagesOnly;

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
    opened++;
    this.textImagesOnly = textImagesOnly;
    return session;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
