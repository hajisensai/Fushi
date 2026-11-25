import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/gal_ocr_line_source.dart';
import 'package:fushi/src/mining/window_capture_channel.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
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
        return textOf(current);
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
      recognize: (Uint8List rgba, int w, int h) async => 'あいうえお',
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
        return '一度目は失敗';
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
      recognize: (Uint8List rgba, int w, int h) async => '同じ台詞',
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
        return '灰色の台詞';
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
}
