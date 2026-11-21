@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

/// 迁到 Rust 之前 `fushi/lib/src/media/video/raw_video_frame.dart` 里的 Dart 逐字节循环
/// （HBK-AUDIT-008），作逐字节对照的参考实现。
Uint8List _referenceBgraToRgba(
  Uint8List src,
  int stride,
  int left,
  int top,
  int w,
  int h,
) {
  final Uint8List out = Uint8List(w * h * 4);
  int o = 0;
  for (int y = 0; y < h; y++) {
    int i = (top + y) * stride + left * 4;
    for (int x = 0; x < w; x++) {
      out[o] = src[i + 2];
      out[o + 1] = src[i + 1];
      out[o + 2] = src[i];
      out[o + 3] = 255;
      o += 4;
      i += 4;
    }
  }
  return out;
}

void _fillRandom(Uint8List bytes, math.Random rng) {
  for (int i = 0; i < bytes.length; i++) {
    bytes[i] = rng.nextInt(256);
  }
}

void main() {
  final FushiComputeImage kernel = FushiComputeImage.instance;

  test('byte-identical to the Dart loop across strides and rects', () {
    final math.Random rng = math.Random(20261122);
    // (宽, 高, stride)：紧排、4 字节对齐填充、非 4 倍数填充（走原先的逐字节分支）。
    const List<(int, int, int)> frames = <(int, int, int)>[
      (16, 9, 64),
      (17, 11, 17 * 4 + 12),
      (33, 7, 33 * 4 + 3),
      (64, 36, 64 * 4 + 256),
    ];
    for (final (int width, int height, int stride) in frames) {
      final Uint8List bgra = Uint8List(height * stride);
      _fillRandom(bgra, rng);
      for (int trial = 0; trial < 25; trial++) {
        final int left = rng.nextInt(width);
        final int top = rng.nextInt(height);
        final int w = 1 + rng.nextInt(width - left);
        final int h = 1 + rng.nextInt(height - top);
        final Uint8List got = kernel.bgraToRgba8(
          bgra,
          stride: stride,
          x: left,
          y: top,
          width: w,
          height: h,
        );
        expect(
          got,
          _referenceBgraToRgba(bgra, stride, left, top, w, h),
          reason: 'frame ${width}x$height/$stride rect ($left,$top,$w,$h)',
        );
      }
    }
  });

  test('reads a native buffer view (mpv node) and prepends the header', () {
    const int width = 40, height = 20, stride = 40 * 4 + 32;
    final Pointer<Uint8> native = malloc<Uint8>(height * stride);
    try {
      final Uint8List view = native.asTypedList(height * stride);
      _fillRandom(view, math.Random(7));
      final Uint8List got = kernel.bgraToRgba8(
        view,
        stride: stride,
        x: 3,
        y: 15,
        width: 37,
        height: 5,
        headerBytes: 24,
      );
      expect(got.length, 24 + 37 * 5 * 4);
      expect(got.sublist(0, 24), everyElement(0));
      expect(
        Uint8List.sublistView(got, 24),
        _referenceBgraToRgba(view, stride, 3, 15, 37, 5),
      );
    } finally {
      malloc.free(native);
    }
  });

  test('rejects rects outside the buffer or the stride', () {
    final Uint8List bgra = Uint8List(2 * 16);
    expect(
      () =>
          kernel.bgraToRgba8(bgra, stride: 8, x: 0, y: 0, width: 4, height: 2),
      throwsArgumentError,
    );
    expect(
      () => kernel.bgraToRgba8(
        Uint8List(20),
        stride: 16,
        x: 0,
        y: 0,
        width: 4,
        height: 2,
      ),
      throwsArgumentError,
    );
    expect(
      () =>
          kernel.bgraToRgba8(bgra, stride: 16, x: 0, y: 0, width: 0, height: 2),
      throwsArgumentError,
    );
    // 末行只需读到矩形右缘。
    expect(
      kernel.bgraToRgba8(
        Uint8List(16 + 8),
        stride: 16,
        x: 0,
        y: 0,
        width: 2,
        height: 2,
      ),
      hasLength(16),
    );
  });
}
