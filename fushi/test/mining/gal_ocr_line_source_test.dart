import 'dart:async';
import 'dart:math' show Rectangle;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/gal_ocr_line_source.dart';
import 'package:fushi/src/mining/gal_ocr_recognizer.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:fushi_compute/fushi_compute.dart';
import 'package:image/image.dart' as img;

/// OCR 游戏模式的泵（拍板台 v5GSgDau9u / BUG-5083）：真 Rust 判定核心 + 合成截图 + 假截窗 /
/// 假 OCR，验「画面变了且稳定才 OCR、文本去重 / 续写、换区域重置、识别器不可用即停」。
void main() {
  /// 一帧 400×200 的整窗截图：下半部分（台词框）画 [bars] 根竖条当字，[cursor] 时右下角
  /// 多一块（闪烁的「点击继续」光标）。
  Uint8List frame(int bars, {bool cursor = false}) {
    final img.Image image = img.Image(width: 400, height: 200)
      ..clear(img.ColorRgb8(255, 255, 255));
    for (int b = 0; b < bars; b++) {
      img.fillRect(
        image,
        x1: 20 + b * 8,
        y1: 140,
        x2: 23 + b * 8,
        y2: 170,
        color: img.ColorRgb8(0, 0, 0),
      );
    }
    if (cursor) {
      img.fillRect(
        image,
        x1: 370,
        y1: 180,
        x2: 380,
        y2: 190,
        color: img.ColorRgb8(0, 0, 0),
      );
    }
    return img.encodePng(image);
  }

  const GalOcrRegion bottom = GalOcrRegion(
    left: 0,
    top: 0.5,
    width: 1,
    height: 0.5,
  );

  /// 跑一遍泵：截窗依次返回 [frames]（截完后报失败并通知完成），识别器按「当前帧的竖条数」
  /// 查 [textOf]。返回送出的行与识别次数。
  Future<({List<String> lines, int ocrCalls, List<GalOcrSourceIssue> issues})>
  pump(
    List<({int bars, bool cursor})> frames,
    String Function(int bars) textOf,
  ) async {
    final List<Uint8List> pngs = <Uint8List>[
      for (final ({int bars, bool cursor}) f in frames)
        frame(f.bars, cursor: f.cursor),
    ];
    final List<String> lines = <String>[];
    final List<GalOcrSourceIssue> issues = <GalOcrSourceIssue>[];
    final Completer<void> exhausted = Completer<void>();
    int index = 0;
    int current = 0;
    int ocrCalls = 0;
    final GalOcrLineSource source = GalOcrLineSource(
      hwnd: 7,
      region: bottom,
      interval: Duration.zero,
      capture: (int hwnd) async {
        if (index >= pngs.length) {
          if (!exhausted.isCompleted) exhausted.complete();
          return const WindowCaptureResult(error: 'done');
        }
        current = frames[index].bars;
        return WindowCaptureResult(pngBytes: pngs[index++]);
      },
      recognize: (Uint8List rgba, int width, int height) async {
        ocrCalls++;
        expect((width, height), (400, 100), reason: '交给 OCR 的是裁好的台词框');
        expect(rgba.length, width * height * 4);
        return GalOcrRecognition(textOf(current));
      },
      onLine: lines.add,
      onIssue: (GalOcrSourceIssue issue, Object? _) => issues.add(issue),
    )..start();
    await exhausted.future;
    await source.stop();
    return (lines: lines, ocrCalls: ocrCalls, issues: issues);
  }

  test('打字机逐字出现期间不 OCR，稳定后 OCR 一次；同一画面不重复识别', () async {
    final result = await pump(<({int bars, bool cursor})>[
      (bars: 0, cursor: false),
      for (int b = 1; b <= 8; b++) (bars: b, cursor: false),
      (bars: 8, cursor: false),
      (bars: 8, cursor: false),
      (bars: 8, cursor: false),
    ], (int bars) => bars == 8 ? '今日はいい天気ですね' : '途中');
    expect(result.lines, <String>['今日はいい天気ですね']);
    expect(result.ocrCalls, 1);
  });

  test('闪烁光标导致的重复识别被 Rust 文本去重吃掉；换句才出新行', () async {
    final result = await pump(<({int bars, bool cursor})>[
      (bars: 6, cursor: false),
      (bars: 6, cursor: false),
      (bars: 6, cursor: true),
      (bars: 6, cursor: true),
      (bars: 6, cursor: false),
      (bars: 6, cursor: false),
      (bars: 0, cursor: false),
      (bars: 9, cursor: false),
      (bars: 9, cursor: false),
    ], (int bars) => bars == 6 ? 'はじめまして、よろしく' : '次 の 台 詞 で す');
    expect(result.lines, <String>['はじめまして、よろしく', '次の台詞です']);
    expect(result.ocrCalls, greaterThanOrEqualTo(3));
  });

  test('打字机停顿识别到半句：续写输出为严格前缀扩展', () async {
    final result = await pump(<({int bars, bool cursor})>[
      (bars: 4, cursor: false),
      (bars: 4, cursor: false),
      (bars: 10, cursor: false),
      (bars: 10, cursor: false),
    ], (int bars) => bars == 4 ? '今日はとても' : '今日はとてもいい天気ですね');
    expect(result.lines, <String>['今日はとても', '今日はとてもいい天気ですね']);
  });

  test('截不到窗口只报一次故障，恢复后报 none', () async {
    final List<GalOcrSourceIssue> issues = <GalOcrSourceIssue>[];
    final Completer<void> done = Completer<void>();
    int calls = 0;
    final GalOcrLineSource source = GalOcrLineSource(
      hwnd: 7,
      region: bottom,
      interval: Duration.zero,
      capture: (int hwnd) async {
        calls++;
        if (calls <= 3) return const WindowCaptureResult(error: 'minimized');
        if (calls == 6 && !done.isCompleted) done.complete();
        return WindowCaptureResult(pngBytes: frame(3));
      },
      recognize: (Uint8List rgba, int w, int h) async =>
          const GalOcrRecognition('あいうえお'),
      onLine: (_) {},
      onIssue: (GalOcrSourceIssue issue, Object? _) => issues.add(issue),
    )..start();
    await done.future;
    await source.stop();
    expect(issues, <GalOcrSourceIssue>[
      GalOcrSourceIssue.captureFailed,
      GalOcrSourceIssue.none,
    ]);
  });

  test('识别器单次出错：同一画面下一轮重识别（Rust 只忘帧、不忘上一句）', () async {
    final List<String> lines = <String>[];
    final Completer<void> got = Completer<void>();
    int ocrCalls = 0;
    final GalOcrLineSource source = GalOcrLineSource(
      hwnd: 7,
      region: bottom,
      interval: Duration.zero,
      capture: (int hwnd) async => WindowCaptureResult(pngBytes: frame(5)),
      recognize: (Uint8List rgba, int w, int h) async {
        ocrCalls++;
        if (ocrCalls == 1) throw StateError('transient');
        return const GalOcrRecognition('一度目は失敗');
      },
      onLine: (String line) {
        lines.add(line);
        if (!got.isCompleted) got.complete();
      },
    )..start();
    await got.future.timeout(const Duration(seconds: 10));
    await source.stop();
    expect(ocrCalls, 2, reason: '同一画面不变也要再交出一次');
    expect(lines, <String>['一度目は失敗']);
  });

  test('识别器不可用：报 recognizerUnavailable 并停泵', () async {
    final List<GalOcrSourceIssue> issues = <GalOcrSourceIssue>[];
    int captures = 0;
    final GalOcrLineSource source = GalOcrLineSource(
      hwnd: 7,
      region: bottom,
      interval: Duration.zero,
      capture: (int hwnd) async {
        captures++;
        return WindowCaptureResult(pngBytes: frame(5));
      },
      recognize: (Uint8List rgba, int w, int h) async =>
          throw const SystemOcrUnavailableException(
            kSystemOcrLanguageUnavailableReason,
          ),
      onLine: (_) {},
      onIssue: (GalOcrSourceIssue issue, Object? _) => issues.add(issue),
    )..start();
    for (int i = 0; i < 200 && source.isRunning; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(source.isRunning, isFalse);
    final int capturesAtHalt = captures;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(captures, capturesAtHalt, reason: '停了就不再截窗');
    expect(issues, <GalOcrSourceIssue>[
      GalOcrSourceIssue.recognizerUnavailable,
    ]);
    await source.stop();
  });

  test('换区域：Rust tracker 重置，新区域里的同一句重新出行', () async {
    final List<String> lines = <String>[];
    final Completer<void> firstLine = Completer<void>();
    final Completer<void> secondLine = Completer<void>();
    final GalOcrLineSource source = GalOcrLineSource(
      hwnd: 7,
      region: bottom,
      interval: Duration.zero,
      capture: (int hwnd) async => WindowCaptureResult(pngBytes: frame(5)),
      recognize: (Uint8List rgba, int w, int h) async =>
          const GalOcrRecognition('同じ台詞'),
      onLine: (String line) {
        lines.add(line);
        if (!firstLine.isCompleted) {
          firstLine.complete();
        } else if (!secondLine.isCompleted) {
          secondLine.complete();
        }
      },
    )..start();
    await firstLine.future;
    source.setRegion(
      const GalOcrRegion(left: 0, top: 0.6, width: 1, height: 0.3),
    );
    await secondLine.future.timeout(const Duration(seconds: 10));
    await source.stop();
    expect(lines, <String>['同じ台詞', '同じ台詞']);
  });

  test('二值化（BUG-5141 ③）：开着时交给识别器的是纯黑白图，会话中可关', () async {
    final List<bool> pureBlackWhite = <bool>[];
    final Completer<void> twice = Completer<void>();
    late final GalOcrLineSource source;
    // 灰底黑字：不二值化时底是 200 灰，二值化后只剩 0 / 255。
    final img.Image image = img.Image(width: 400, height: 200)
      ..clear(img.ColorRgb8(200, 200, 200));
    for (int b = 0; b < 6; b++) {
      img.fillRect(
        image,
        x1: 20 + b * 8,
        y1: 140,
        x2: 23 + b * 8,
        y2: 170,
        color: img.ColorRgb8(0, 0, 0),
      );
    }
    final Uint8List gray = img.encodePng(image);
    source = GalOcrLineSource(
      hwnd: 7,
      region: bottom,
      binarize: true,
      interval: Duration.zero,
      capture: (int hwnd) async => WindowCaptureResult(pngBytes: gray),
      recognize: (Uint8List rgba, int w, int h) async {
        pureBlackWhite.add(rgba.every((int v) => v == 0 || v == 255));
        if (pureBlackWhite.length == 1) {
          source.setBinarize(false);
        } else if (!twice.isCompleted) {
          twice.complete();
        }
        return const GalOcrRecognition('灰色の台詞');
      },
      onLine: (_) {},
    )..start();
    await twice.future.timeout(const Duration(seconds: 10));
    await source.stop();
    expect(pureBlackWhite.take(2), <bool>[
      true,
      false,
    ], reason: '关掉二值化后同一画面按新选项再识别一次');
  });

  group('GalOcrRegion', () {
    test('fromCorners 任意顺序、夹到 0～1', () {
      final GalOcrRegion r = GalOcrRegion.fromCorners(0.9, 1.2, -0.1, 0.4);
      expect(r, const GalOcrRegion(left: 0, top: 0.4, width: 0.9, height: 0.6));
      expect(r.isValid, isTrue);
    });

    test('JSON 往返；坏值 / 过小的框返回 null', () {
      expect(
        GalOcrRegion.fromJson(GalOcrRegion.defaultDialogue.toJson()),
        GalOcrRegion.defaultDialogue,
      );
      expect(GalOcrRegion.fromJson('x'), isNull);
      expect(GalOcrRegion.fromJson(<String, Object?>{'left': 0}), isNull);
      expect(
        GalOcrRegion.fromJson(<String, Object?>{
          'left': 0.1,
          'top': 0.1,
          'width': 0.001,
          'height': 0.5,
        }),
        isNull,
      );
    });
  });

  group('游戏画面内嵌查词的逐字几何（BUG-5299 ②）', () {
    const WindowCaptureMetadata plainClient = WindowCaptureMetadata(
      capturedHwnd: 7,
      capturedPid: 1,
      clientLeftPx: 0,
      clientTopPx: 0,
      clientWidthPx: 400,
      clientHeightPx: 200,
      imageWidthPx: 400,
      imageHeightPx: 200,
      dpi: 96,
      clientAreaComplete: true,
      capturedAtTickMs: 1,
    );

    test('新句带客户区逐字框发布；画面一变就撤掉', () async {
      final List<Uint8List> pngs = <Uint8List>[
        frame(5),
        frame(5),
        frame(5),
        frame(9),
      ];
      final Completer<void> exhausted = Completer<void>();
      int index = 0;
      final GalOcrLineSource source = GalOcrLineSource(
        hwnd: 7,
        region: bottom,
        interval: Duration.zero,
        capture: (int hwnd) async {
          if (index >= pngs.length) {
            if (!exhausted.isCompleted) exhausted.complete();
            return const WindowCaptureResult(error: 'done');
          }
          return WindowCaptureResult(
            pngBytes: pngs[index++],
            metadata: plainClient,
          );
        },
        // 送检图是 400×100 的台词框（字高 30 px，不放大）：「あ」(10..30)、「い」(30..50)。
        recognize: (Uint8List rgba, int w, int h) async => GalOcrRecognition(
          'あい',
          charBoxes: Float32List.fromList(<double>[
            10, 10, 30, 40, //
            30, 10, 50, 40,
          ]),
        ),
        onLine: (_) {},
      );
      final List<GalOcrMeasuredFrame> frames = <GalOcrMeasuredFrame>[];
      final StreamSubscription<GalOcrMeasuredFrame> sub = source
          .measuredFeed
          .frames
          .listen(frames.add);
      source.start();
      await exhausted.future.timeout(const Duration(seconds: 10));
      await source.stop();
      await sub.cancel();

      expect(frames, hasLength(2));
      final GalOcrMeasuredFrame line = frames.first;
      expect(line.text, 'あい');
      expect((line.clientWidth, line.clientHeight), (400, 200));
      expect(line.complete, isTrue);
      expect(line.devicePixelRatio, 1);
      expect(line.glyphs, const <GalOcrMeasuredGlyph>[
        GalOcrMeasuredGlyph(
          textStart: 0,
          textLength: 1,
          rect: Rectangle<double>(10, 110, 20, 30),
        ),
        GalOcrMeasuredGlyph(
          textStart: 1,
          textLength: 1,
          rect: Rectangle<double>(30, 110, 20, 30),
        ),
      ]);
      // 换句（打字机开始）：旧框撤掉。
      expect(frames.last.isClear, isTrue);
      expect(source.measuredFeed.isClosed, isTrue);
    });

    test('截图元数据缺失 / 不完整：不猜坐标，不发几何', () async {
      final Completer<void> exhausted = Completer<void>();
      int index = 0;
      final GalOcrLineSource source = GalOcrLineSource(
        hwnd: 7,
        region: bottom,
        interval: Duration.zero,
        capture: (int hwnd) async {
          if (index++ >= 3) {
            if (!exhausted.isCompleted) exhausted.complete();
            return const WindowCaptureResult(error: 'done');
          }
          return WindowCaptureResult(pngBytes: frame(5));
        },
        recognize: (Uint8List rgba, int w, int h) async => GalOcrRecognition(
          'あ',
          charBoxes: Float32List.fromList(<double>[10, 10, 30, 40]),
        ),
        onLine: (_) {},
      );
      final List<GalOcrMeasuredFrame> frames = <GalOcrMeasuredFrame>[];
      final StreamSubscription<GalOcrMeasuredFrame> sub = source
          .measuredFeed
          .frames
          .listen(frames.add);
      source.start();
      await exhausted.future.timeout(const Duration(seconds: 10));
      await source.stop();
      await sub.cancel();
      expect(frames, isEmpty);
    });

    test('Magpie 呈现窗截图：按源视口换算回源窗口客户区', () {
      const WindowCaptureMetadata magpie = WindowCaptureMetadata(
        capturedHwnd: 9,
        capturedPid: 2,
        clientLeftPx: 0,
        clientTopPx: 0,
        clientWidthPx: 1920,
        clientHeightPx: 1080,
        imageWidthPx: 1920,
        imageHeightPx: 1080,
        sourceHwnd: 7,
        sourcePid: 3,
        presentationHwnd: 9,
        presentationPid: 2,
        usedPresentationCapture: true,
        presentationViewportComplete: true,
        sourceClientLeftPx: 100,
        sourceClientTopPx: 50,
        sourceClientWidthPx: 1000,
        sourceClientHeightPx: 600,
        sourceClientDpi: 96,
        sourceViewportLeftPx: 120,
        sourceViewportTopPx: 80,
        sourceViewportWidthPx: 960,
        sourceViewportHeightPx: 540,
        destinationViewportWidthPx: 1920,
        destinationViewportHeightPx: 1080,
        dpi: 96,
        clientAreaComplete: true,
        capturedAtTickMs: 1,
      );
      expect(galOcrClientMapping(magpie, imageWidth: 1920, imageHeight: 1080), (
        scaleX: 0.5,
        scaleY: 0.5,
        offsetX: 20.0,
        offsetY: 30.0,
        clientWidth: 1000,
        clientHeight: 600,
      ));
      final GalOcrMeasuredFrame? measured = galOcrMeasuredFrameOf(
        const FfcOcrLineText(
          kind: FfcOcrLineTextKind.newLine,
          text: 'あ',
          glyphs: <FfcOcrLineGlyph>[
            FfcOcrLineGlyph(
              start: 0,
              length: 1,
              left: 200,
              top: 900,
              right: 260,
              bottom: 960,
            ),
          ],
          imageWidth: 1920,
          imageHeight: 1080,
        ),
        magpie,
      );
      expect(
        measured!.glyphs.single.rect,
        const Rectangle<double>(120, 480, 30, 30),
      );
      expect((measured.clientWidth, measured.clientHeight), (1000, 600));
      // 截图尺寸与元数据对不上 / 没有元数据：不猜。
      expect(
        galOcrClientMapping(magpie, imageWidth: 1280, imageHeight: 720),
        isNull,
      );
      expect(
        galOcrClientMapping(null, imageWidth: 1920, imageHeight: 1080),
        isNull,
      );
    });

    test('识别结果 → 逐字框：词框内等分，其余在行框内按字数等分；竖排沿高度', () {
      const SystemOcrTextLine horizontal = SystemOcrTextLine(
        text: 'あいう',
        rect: Rect.fromLTRB(0, 0, 30, 10),
        isVertical: false,
        segments: <SystemOcrTextSegment>[
          SystemOcrTextSegment(
            start: 0,
            length: 1,
            rect: Rect.fromLTRB(0, 0, 12, 10),
          ),
        ],
      );
      expect(galOcrLineCharBoxes(horizontal), <double>[
        0, 0, 12, 10, //
        10, 0, 20, 10, //
        20, 0, 30, 10,
      ]);
      const SystemOcrTextLine vertical = SystemOcrTextLine(
        text: '\u{20BB7}あ',
        rect: Rect.fromLTRB(0, 0, 10, 40),
        isVertical: true,
      );
      expect(galOcrLineCharBoxes(vertical), <double>[
        0, 0, 10, 20, //
        0, 20, 10, 40,
      ]);
      final GalOcrRecognition recognition = galOcrRecognitionOf(
        const SystemOcrPageResult(
          lines: <SystemOcrTextLine>[
            SystemOcrTextLine(
              text: 'あ',
              rect: Rect.fromLTRB(0, 0, 10, 10),
              isVertical: false,
            ),
            SystemOcrTextLine(
              text: ' ',
              rect: Rect.fromLTRB(0, 0, 1, 1),
              isVertical: false,
            ),
            SystemOcrTextLine(
              text: 'い',
              rect: Rect.fromLTRB(0, 20, 10, 30),
              isVertical: false,
            ),
          ],
          imageWidth: 100,
          imageHeight: 100,
        ),
      );
      expect(recognition.text, 'あ\nい');
      expect(recognition.charBoxes, <double>[
        0, 0, 10, 10, //
        0, 0, 0, 0, //
        0, 20, 10, 30,
      ]);
    });
  });
}
