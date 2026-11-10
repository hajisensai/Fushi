// BUG-4367（反馈 Z9fC87pZrY）：Windows 应用外截屏识字的词框定位与几何取证。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/floating_ball/app_floating_ball_host.dart';
import 'package:fushi/src/floating_ball/floating_ball_channel.dart';
import 'package:fushi/src/floating_ball/screen_ocr_picker.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:material_ui/material_ui.dart';

/// Windows OCR 对「Fushi の設定」这种日英混排行的典型回包：英文词与日文之间有一大段
/// 空隙（行框把空隙也包进去了），日文逐字成词。坐标是截图像素（物理像素）。
Map<Object?, Object?> _mixedLinePayload() => <Object?, Object?>{
  'width': 3840,
  'height': 2160,
  'recognizedWidth': 3840,
  'recognizedHeight': 2160,
  'maxImageDimension': 10000,
  'lines': <Object?>[
    <Object?, Object?>{
      'text': 'Fushi の設定',
      'left': 0.0,
      'top': 0.0,
      'right': 390.0,
      'bottom': 30.0,
      'words': <Object?>[
        _word(0, 5, 0, 100),
        _word(6, 1, 300, 330),
        _word(7, 1, 330, 360),
        _word(8, 1, 360, 390),
      ],
    },
  ],
};

Map<Object?, Object?> _word(
  int start,
  int length,
  double left,
  double right, {
  double top = 0,
  double bottom = 30,
}) => <Object?, Object?>{
  'start': start,
  'length': length,
  'left': left,
  'top': top,
  'right': right,
  'bottom': bottom,
};

void main() {
  group('parseSystemOcrPayload 词框', () {
    test('词框按行内位置解析，送检尺寸与上限一并带回', () {
      final SystemOcrPageResult result = parseSystemOcrPayload(
        _mixedLinePayload(),
      );
      expect(result.recognizedWidth, 3840);
      expect(result.recognizedHeight, 2160);
      expect(result.maxImageDimension, 10000);
      final SystemOcrTextLine line = result.lines.single;
      expect(
        line.segments.map((SystemOcrTextSegment s) => s.start).toList(),
        <int>[0, 6, 7, 8],
      );
      expect(line.segments.first.rect, const Rect.fromLTRB(0, 0, 100, 30));
      expect(
        line.text.substring(line.segments[1].start, line.segments[1].end),
        'の',
      );
    });

    test('越界、倒序 / 重叠、没面积的词框丢掉；没有 words 的平台为空', () {
      final SystemOcrPageResult result = parseSystemOcrPayload(
        <Object?, Object?>{
          'width': 100,
          'height': 100,
          'lines': <Object?>[
            <Object?, Object?>{
              'text': 'abcd',
              'left': 0.0,
              'top': 0.0,
              'right': 40.0,
              'bottom': 10.0,
              'words': <Object?>[
                _word(0, 2, 0, 20, bottom: 10),
                // 与上一段重叠。
                _word(1, 1, 10, 20, bottom: 10),
                // 没面积。
                _word(2, 1, 20, 20, bottom: 10),
                // 越出行文本。
                _word(3, 4, 30, 40, bottom: 10),
              ],
            },
            <Object?, Object?>{
              'text': 'macOS',
              'left': 0.0,
              'top': 20.0,
              'right': 40.0,
              'bottom': 30.0,
            },
          ],
        },
      );
      expect(
        result.lines[0].segments.map((SystemOcrTextSegment s) => s.start),
        <int>[0],
      );
      expect(result.lines[1].segments, isEmpty);
      expect(result.recognizedWidth, isNull);
      expect(result.maxImageDimension, isNull);
    });
  });

  group('screenOcrHitTest 按词框定位（多 DPI）', () {
    final SystemOcrTextLine line = parseSystemOcrPayload(
      _mixedLinePayload(),
    ).lines.single;
    final SystemOcrTextLine lineOnly = SystemOcrTextLine(
      text: line.text,
      rect: line.rect,
      isVertical: false,
    );

    // scale = 逻辑像素 / 截图像素：桌面冻结层用截图像素（1），应用内选取页按
    // devicePixelRatio 换算（1/1.25、1/1.5、1/2）。
    for (final double dpr in <double>[1, 1.25, 1.5, 2]) {
      final double scale = 1 / dpr;

      test('dpr=$dpr：点在「の」上查的是「の」，不是整行等分估出的「設」', () {
        final Offset point = Offset(305 * scale, 15 * scale);
        final ScreenOcrHit hit = screenOcrHitTest(
          lines: <SystemOcrTextLine>[line],
          point: point,
          scale: scale,
        )!;
        expect(line.text.substring(hit.charIndex), 'の設定');
        expect(hit.charRect.left, closeTo(300 * scale, 1e-9));
        expect(hit.charRect.right, closeTo(330 * scale, 1e-9));
        expect(hit.charRect.top, closeTo(0, 1e-9));
        expect(hit.charRect.bottom, closeTo(30 * scale, 1e-9));
        expect(hit.lineRect.right, closeTo(390 * scale, 1e-9));

        // 反证：只有行框时按整行等分落到「設」——这就是修前的错位。
        final ScreenOcrHit legacy = screenOcrHitTest(
          lines: <SystemOcrTextLine>[lineOnly],
          point: point,
          scale: scale,
        )!;
        expect(lineOnly.text.substring(legacy.charIndex), '設定');
      });

      test('dpr=$dpr：多字词内按字等分', () {
        final ScreenOcrHit hit = screenOcrHitTest(
          lines: <SystemOcrTextLine>[line],
          point: Offset(50 * scale, 10 * scale),
          scale: scale,
        )!;
        expect(hit.charIndex, 2);
        expect(hit.charRect.left, closeTo(40 * scale, 1e-9));
        expect(hit.charRect.right, closeTo(60 * scale, 1e-9));
      });

      test('dpr=$dpr：点在词间空隙取沿阅读方向最近的词', () {
        final ScreenOcrHit hit = screenOcrHitTest(
          lines: <SystemOcrTextLine>[line],
          point: Offset(250 * scale, 15 * scale),
          scale: scale,
        )!;
        expect(line.text.substring(hit.charIndex), 'の設定');
        final ScreenOcrHit nearEnglish = screenOcrHitTest(
          lines: <SystemOcrTextLine>[line],
          point: Offset(140 * scale, 15 * scale),
          scale: scale,
        )!;
        // 最近的是「Fushi」，落点在它右侧 → 取它最后一个字。
        expect(nearEnglish.charIndex, 4);
      });
    }

    test('点在行框外（含容差）仍返回 null', () {
      expect(
        screenOcrHitTest(
          lines: <SystemOcrTextLine>[line],
          point: const Offset(200, 60),
          scale: 1,
        ),
        isNull,
      );
    });
  });

  group('截屏几何取证', () {
    test('原生回带的 DPI / HDR / 取帧路径解析进 DesktopScreenOcrCapture', () {
      final DesktopScreenOcrCapture capture = DesktopScreenOcrCapture.fromWire(
        <Object?, Object?>{
          'png': Uint8List.fromList(<int>[1, 2, 3]),
          'screen': <Object?>[0, 0, 3840, 2160],
          'dpi': 144,
          'hdrMonitor': true,
          'capturePath': 'gdi',
        },
      );
      expect(capture.dpi, 144);
      expect(capture.hdrMonitor, isTrue);
      expect(capture.capturePath, 'gdi');

      final DesktopScreenOcrCapture legacy = DesktopScreenOcrCapture.fromWire(
        <Object?, Object?>{
          'png': Uint8List.fromList(<int>[1, 2, 3]),
          'screen': <Object?>[0, 0, 100, 100],
        },
      );
      expect(legacy.dpi, isNull);
      expect(legacy.hdrMonitor, isNull);
      expect(legacy.capturePath, isNull);
    });

    test('一行摘要写明显示器 / 截图 / 送检尺寸、DPI、HDR、行框', () {
      final DesktopScreenOcrCapture capture = DesktopScreenOcrCapture.fromWire(
        <Object?, Object?>{
          'png': Uint8List.fromList(<int>[1, 2, 3]),
          'screen': <Object?>[0, 0, 3840, 2160],
          'dpi': 144,
          'hdrMonitor': false,
          'capturePath': 'gdi',
        },
      );
      final String summary = screenOcrGeometrySummary(
        capture: capture,
        result: parseSystemOcrPayload(_mixedLinePayload()),
      );
      expect(summary, contains('screen=[0,0,3840,2160]'));
      expect(summary, contains('image=3840x2160'));
      expect(summary, contains('screenMatchesImage=true'));
      expect(summary, contains('dpi=144(150%)'));
      expect(summary, contains('hdr=false'));
      expect(summary, contains('path=gdi'));
      expect(summary, contains('recognized=3840x2160'));
      expect(summary, contains('max=10000'));
      expect(summary, contains('lines=1'));
      expect(summary, contains('boxes=[0,0,390,30]/9c/4w'));
    });

    test('显示器矩形与截图尺寸对不上（逻辑 / 物理像素混用）时标出来', () {
      final DesktopScreenOcrCapture capture = DesktopScreenOcrCapture.fromWire(
        <Object?, Object?>{
          'png': Uint8List.fromList(<int>[1, 2, 3]),
          'screen': <Object?>[0, 0, 2560, 1440],
        },
      );
      final String summary = screenOcrGeometrySummary(
        capture: capture,
        result: parseSystemOcrPayload(_mixedLinePayload()),
      );
      expect(summary, contains('screenMatchesImage=false'));
      expect(summary, contains('dpi=-'));
      expect(summary, contains('hdr=-'));
    });

    test('行框只记前 maxBoxes 行', () {
      final SystemOcrPageResult result = SystemOcrPageResult(
        lines: <SystemOcrTextLine>[
          for (int i = 0; i < 12; i++)
            SystemOcrTextLine(
              text: 'あ',
              rect: Rect.fromLTWH(0, i * 40.0, 30, 30),
              isVertical: false,
            ),
        ],
        imageWidth: 100,
        imageHeight: 500,
      );
      final String summary = screenOcrGeometrySummary(
        capture: DesktopScreenOcrCapture.fromWire(<Object?, Object?>{
          'png': Uint8List.fromList(<int>[1]),
          'screen': <Object?>[0, 0, 100, 500],
        }),
        result: result,
        maxBoxes: 3,
      );
      expect(summary, contains('lines=12'));
      expect(RegExp(r'/1c/0w').allMatches(summary).length, 3);
      expect(summary, contains('recognized=-'));
    });
  });
}
