import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

/// 漫画「画质缩放」的原生内核 `ffc_image_fit_jpeg_hq`：可放大、文字感知的 Gamma 校正（OCR 框外
/// 线性光、框内 sRGB）、越界 / 坏图返回 null（调用方给原图）。
void main() {
  final FushiComputeImage kernel = FushiComputeImage.instance;

  /// 64×64 灰度棋盘（黑白逐像素相间 = 最细的网点），PGM（P5）编码。
  Uint8List checkerPgm() {
    final List<int> header = 'P5\n64 64\n255\n'.codeUnits;
    final Uint8List out = Uint8List(header.length + 64 * 64)..setAll(0, header);
    for (int y = 0; y < 64; y++) {
      for (int x = 0; x < 64; x++) {
        out[header.length + y * 64 + x] = (x + y).isEven ? 0 : 255;
      }
    }
    return out;
  }

  double meanLuma(Uint8List jpeg) {
    final FfcDecodedImage img = kernel.decode(jpeg)!;
    final Uint8List px = img.pixels;
    double sum = 0;
    for (int i = 0; i < px.length; i += img.channels) {
      sum += px[i];
    }
    return sum / (px.length / img.channels);
  }

  test('text-aware gamma: linear light outside text boxes, sRGB inside', () {
    final Uint8List png = checkerPgm();
    Uint8List fit({Float32List? boxes}) => kernel.fitJpegHq(
      png,
      width: 32,
      height: 32,
      quality: 95,
      filter: FfcResampleFilter.box,
      textAwareGammaBoxes: boxes,
    )!;
    // 空框列表：等同 sRGB（没有 OCR 数据就不做线性光）。
    expect(meanLuma(fit(boxes: Float32List(0))), closeTo(128, 4));
    // 不开：sRGB 平均（网点发闷）。
    expect(meanLuma(fit()), closeTo(128, 4));
    // 一个远离整页的小框之外全是线性光。
    final double tiny = meanLuma(
      fit(boxes: Float32List.fromList(<double>[0.0, 0.0, 0.05, 0.05])),
    );
    expect(tiny, greaterThan(175));
    // 整页一个框 = 全是 sRGB。
    expect(
      meanLuma(fit(boxes: Float32List.fromList(<double>[0, 0, 1, 1]))),
      closeTo(128, 4),
    );
    expect(() => fit(boxes: Float32List(3)), throwsArgumentError);
  });

  test('upscales up to 4x; beyond, garbage and bad sizes give null', () {
    final Uint8List png = checkerPgm();
    final Uint8List? up = kernel.fitJpegHq(
      png,
      width: 256,
      height: 256,
      quality: 90,
      filter: FfcResampleFilter.catmullRom,
    );
    expect(kernel.probe(up!)?.width, 256);
    expect(kernel.fitJpegHq(png, width: 257, height: 256, quality: 90), isNull);
    expect(
      kernel.fitJpegHq(
        Uint8List.fromList(<int>[1, 2, 3]),
        width: 8,
        height: 8,
        quality: 90,
      ),
      isNull,
    );
    expect(kernel.fitJpegHq(png, width: 0, height: 8, quality: 90), isNull);
  });
}
