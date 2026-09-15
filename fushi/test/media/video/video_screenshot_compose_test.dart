import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_screenshot_compose.dart';

/// 画一张 [width]×[height] 的纯色 PNG。
Future<Uint8List> _solidPng(
  int width,
  int height,
  Color color, {
  Rect? patch,
  Color? patchColor,
}) async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = color,
  );
  if (patch != null) {
    canvas.drawRect(
        patch, Paint()..color = patchColor ?? const Color(0xFF00FF00));
  }
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(width, height);
  final ByteData? png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return png!.buffer.asUint8List();
}

/// 读回 [pngBytes] 在 ([x], [y]) 处的像素（RGBA）。
Future<List<int>> _pixelAt(Uint8List pngBytes, int x, int y) async {
  final ui.Codec codec = await ui.instantiateImageCodec(pngBytes);
  final ui.FrameInfo frame = await codec.getNextFrame();
  final ui.Image image = frame.image;
  final ByteData? raw =
      await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final int offset = (y * image.width + x) * 4;
  final List<int> pixel = <int>[
    raw!.getUint8(offset),
    raw.getUint8(offset + 1),
    raw.getUint8(offset + 2),
    raw.getUint8(offset + 3),
  ];
  image.dispose();
  codec.dispose();
  return pixel;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('composeScreenshotWithOverlays', () {
    test('叠加层盖在底图上，输出保持底图分辨率', () async {
      final Uint8List base = await _solidPng(40, 20, const Color(0xFF0000FF));
      // 只在左上 10×10 有不透明像素的叠加层，其余透明。
      final Uint8List overlay = await _solidPng(
        40,
        20,
        const Color(0x00000000),
        patch: const Rect.fromLTWH(0, 0, 10, 10),
        patchColor: const Color(0xFFFF0000),
      );

      final Uint8List? out = await composeScreenshotWithOverlays(
        frameBytes: base,
        overlayPngs: <Uint8List>[overlay],
      );
      expect(out, isNotNull);

      // 叠加层覆盖处是红的，未覆盖处仍是底图的蓝——证明是「叠」而不是「换」。
      expect(await _pixelAt(out!, 2, 2), <int>[255, 0, 0, 255]);
      expect(await _pixelAt(out, 30, 15), <int>[0, 0, 255, 255]);

      final ui.Codec codec = await ui.instantiateImageCodec(out);
      final ui.FrameInfo frame = await codec.getNextFrame();
      expect(frame.image.width, 40);
      expect(frame.image.height, 20);
      frame.image.dispose();
      codec.dispose();
    });

    test('空叠加层列表 = 原样转成 PNG（剪贴板路径要的就是这个）', () async {
      final Uint8List base = await _solidPng(8, 8, const Color(0xFF123456));
      final Uint8List? out = await composeScreenshotWithOverlays(
        frameBytes: base,
        overlayPngs: const <Uint8List>[],
      );
      expect(out, isNotNull);
      expect(await _pixelAt(out!, 4, 4), <int>[0x12, 0x34, 0x56, 255]);
    });

    test('多层按给出顺序叠，后给的在上', () async {
      final Uint8List base = await _solidPng(10, 10, const Color(0xFF000000));
      final Uint8List first = await _solidPng(
        10,
        10,
        const Color(0x00000000),
        patch: const Rect.fromLTWH(0, 0, 10, 10),
        patchColor: const Color(0xFFFF0000),
      );
      final Uint8List second = await _solidPng(
        10,
        10,
        const Color(0x00000000),
        patch: const Rect.fromLTWH(0, 0, 10, 10),
        patchColor: const Color(0xFF00FF00),
      );
      final Uint8List? out = await composeScreenshotWithOverlays(
        frameBytes: base,
        overlayPngs: <Uint8List>[first, second],
      );
      expect(await _pixelAt(out!, 5, 5), <int>[0, 255, 0, 255]);
    });

    test('底图不是图片时返回 null，而不是抛', () async {
      final Uint8List? out = await composeScreenshotWithOverlays(
        frameBytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
        overlayPngs: const <Uint8List>[],
      );
      expect(out, isNull);
    });

    test('单个叠加层解不出来时跳过它，底图照常输出', () async {
      final Uint8List base = await _solidPng(8, 8, const Color(0xFFFFFFFF));
      final Uint8List? out = await composeScreenshotWithOverlays(
        frameBytes: base,
        overlayPngs: <Uint8List>[
          Uint8List.fromList(<int>[9, 9, 9])
        ],
      );
      expect(out, isNotNull);
      expect(await _pixelAt(out!, 4, 4), <int>[255, 255, 255, 255]);
    });
  });

  group('screenshotFrameSize', () {
    test('返回帧的像素尺寸', () async {
      final Uint8List base = await _solidPng(64, 36, const Color(0xFF808080));
      final ({int width, int height})? size = await screenshotFrameSize(base);
      expect(size?.width, 64);
      expect(size?.height, 36);
    });

    test('坏字节返回 null', () async {
      expect(await screenshotFrameSize(Uint8List.fromList(<int>[0])), isNull);
      expect(await screenshotFrameSize(Uint8List(0)), isNull);
    });
  });
}
