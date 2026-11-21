import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/reader/manga_stream_ocr_types.dart';
import 'package:fushi/src/media/video/graphic_subtitle_ocr.dart';
import 'package:fushi/src/media/video/raw_video_frame.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/ocr/ocr_types.dart' show OcrRgbaImage;

/// 视频暂停 OCR（拍板 design-nmv-pause-ocr-png 方案 a）：播放器截帧的 BGRA 在截帧 isolate
/// 上直接换成 RGBA，识别会话把像素交给引擎的 [MangaStreamPageRecognizer.recognizePixels]，
/// 整条链上不再有 PNG 编码、落盘与再解码（#3828 测量：编码 + 解码约占 95%）。

/// mpv `screenshot-raw` 形状的一帧：BGRA，第四字节未定义（bgr0），行尾带填充。
({Uint8List bgra, int stride}) _bgraFrame(int width, int height, int pad) {
  final int stride = width * 4 + pad;
  final Uint8List bgra = Uint8List(stride * height);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final int o = y * stride + x * 4;
      bgra[o] = (x * 3 + y) & 0xFF; // B
      bgra[o + 1] = (x + y * 5) & 0xFF; // G
      bgra[o + 2] = (x * 7 + y * 2) & 0xFF; // R
      bgra[o + 3] = 0; // bgr0：未定义
    }
    for (int k = width * 4; k < stride; k++) {
      bgra[y * stride + k] = 0xEE;
    }
  }
  return (bgra: bgra, stride: stride);
}

Uint8List _expectedRgba(Uint8List bgra, int width, int height, int stride) {
  final Uint8List out = Uint8List(width * height * 4);
  int o = 0;
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final int i = y * stride + x * 4;
      out[o++] = bgra[i + 2];
      out[o++] = bgra[i + 1];
      out[o++] = bgra[i];
      out[o++] = 255;
    }
  }
  return out;
}

class _PixelRecognizer implements MangaStreamPageRecognizer {
  final List<OcrRgbaImage> frames = <OcrRgbaImage>[];
  final List<String> urls = <String>[];

  @override
  Future<MokuroImage> recognize(File pageFile) =>
      throw StateError('pause OCR must not write frames to files');

  @override
  Future<MokuroImage> recognizePixels(
    OcrRgbaImage image, {
    required String url,
  }) async {
    frames.add(image);
    urls.add(url);
    return MokuroImage(
      url: url,
      size: MokuroSize(image.width.toDouble(), image.height.toDouble()),
      blocks: <MokuroBlock>[
        MokuroBlock(
          rectangle: MokuroRect.fromLTRB(2, 2, 10, 6),
          isVertical: false,
          fontSize: 4,
          zIndex: 0,
          lines: const <String>['字幕'],
        ),
      ],
    );
  }

  @override
  Future<void> close() async {}
}

void main() {
  group('截帧变换：BGRA → 不透明 RGBA（不编码）', () {
    test('行跨度带填充、第四字节未定义：通道换对、alpha 置满', () {
      final ({Uint8List bgra, int stride}) f = _bgraFrame(37, 11, 12);
      final OcrRgbaImage? frame = parseRawVideoFrameRgba(
        rawVideoFrameRgbaTransform(37, 11, f.stride, f.bgra),
      );
      expect(frame, isNotNull);
      expect((frame!.width, frame.height), (37, 11));
      expect(frame.rgba, _expectedRgba(f.bgra, 37, 11, f.stride));
    });

    test('缓冲未按 4 字节对齐时走逐字节路径，结果相同', () {
      final ({Uint8List bgra, int stride}) f = _bgraFrame(9, 5, 4);
      final Uint8List shifted = Uint8List(f.bgra.length + 1)..setAll(1, f.bgra);
      final Uint8List view = Uint8List.sublistView(shifted, 1);
      expect(view.offsetInBytes % 4, isNot(0));
      final OcrRgbaImage? frame = parseRawVideoFrameRgba(
        rawVideoFrameRgbaTransform(9, 5, f.stride, view),
      );
      expect(frame!.rgba, _expectedRgba(f.bgra, 9, 5, f.stride));
    });

    test('裁剪（不是整帧）的字节不被当成整帧', () {
      final ({Uint8List bgra, int stride}) f = _bgraFrame(20, 10, 0);
      final Uint8List? crop = rawVideoFrameCropTransform(
        const Rect.fromLTRB(0, 0.5, 1, 1),
      )(20, 10, f.stride, f.bgra);
      expect(crop, isNotNull);
      expect(parseRawVideoFrameRgba(crop), isNull);
    });
  });

  test('识别会话把像素直接交给引擎：不落盘，每帧一个唯一 url', () async {
    final _PixelRecognizer recognizer = _PixelRecognizer();
    final GraphicSubtitleOcrSession session = GraphicSubtitleOcrSession(
      prepare: (String _) async =>
          MangaStreamOcrReady(MangaOcrEngineId.systemOcr, recognizer),
    );
    addTearDown(session.close);
    final OcrRgbaImage frame = OcrRgbaImage(
      rgba: Uint8List(16 * 8 * 4),
      width: 16,
      height: 8,
    );
    final GraphicSubtitleOcrFrame? first = await session.recognize(frame);
    final GraphicSubtitleOcrFrame? second = await session.recognize(frame);
    expect(
      identical(recognizer.frames.first, frame),
      isTrue,
      reason: '像素原样交给引擎',
    );
    expect(recognizer.urls.toSet(), hasLength(2));
    expect(
      first!.chars.map((GraphicSubtitleOcrChar c) => c.sentence).toSet(),
      <String>{'字幕'},
    );
    expect(second!.isEmpty, isFalse);
  });
}
