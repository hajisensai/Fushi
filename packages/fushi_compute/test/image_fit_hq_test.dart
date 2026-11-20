import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

/// 漫画「画质缩放」的原生内核 `ffc_image_fit_jpeg_hq`：可放大、可在线性光里平均、越界 / 坏图返回
/// null（调用方给原图）。
void main() {
  final FushiComputeImage kernel = FushiComputeImage.instance;

  /// 64×64 灰度棋盘（黑白逐像素相间 = 最细的网点），PGM（P5）编码。
  Uint8List checkerPgm() {
    final List<int> header = 'P5\n64 64\n255\n'.codeUnits;
    final Uint8List out = Uint8List(header.length + 64 * 64)
      ..setAll(0, header);
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

  test('gamma-correct averaging keeps screentone at physical mid-gray', () {
    final Uint8List png = checkerPgm();
    final Uint8List linear = kernel.fitJpegHq(
      png,
      width: 32,
      height: 32,
      quality: 95,
      filter: FfcResampleFilter.box,
    )!;
    final Uint8List encoded = kernel.fitJpegHq(
      png,
      width: 32,
      height: 32,
      quality: 95,
      filter: FfcResampleFilter.box,
      linearLight: false,
    )!;
    expect(meanLuma(linear), closeTo(188, 4));
    expect(meanLuma(encoded), closeTo(128, 4));
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
    expect(
      kernel.fitJpegHq(png, width: 257, height: 256, quality: 90),
      isNull,
    );
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
