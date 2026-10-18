// 原生 PNG 解码 / JPEG 编码（encodePngAsJpeg，有声书片段导出逐帧重编码用）：
// - PNG 无损：各种色型解出的 RGBA 必须与 package:image `decodePng` 逐字节相同；
// - JPEG 换了编码器、字节不同：同质量参数下 PSNR 不得比 package:image `encodeJpg` 低 0.1 dB
//   以上，体积不得大 3% 以上。
// 库找不到时失败，不 skip。
@TestOn('vm')
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:fushi_engine/media/image_kernels.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

import 'synthetic_images.dart';

double _psnr(img.Image ref, img.Image got) {
  double se = 0;
  int n = 0;
  for (int y = 0; y < ref.height; y++) {
    for (int x = 0; x < ref.width; x++) {
      final img.Pixel a = ref.getPixel(x, y);
      final img.Pixel b = got.getPixel(x, y);
      se += (a.r - b.r) * (a.r - b.r);
      se += (a.g - b.g) * (a.g - b.g);
      se += (a.b - b.b) * (a.b - b.b);
      n += 3;
    }
  }
  return se == 0 ? 99 : 10 * math.log(255 * 255 / (se / n)) / math.ln10;
}

void main() {
  final Map<String, Uint8List> pngs = <String, Uint8List>{
    for (int ch = 1; ch <= 4; ch++)
      '${ch}ch': img.encodePng(synthImage(301, 157, ch, 11 + ch)),
    'palette': img.encodePng(
      img.quantize(synthImage(200, 120, 3, 5), numberOfColors: 32),
    ),
    '16bit': img.encodePng(
      synthImage(97, 61, 3, 9).convert(format: img.Format.uint16),
    ),
  };

  for (final MapEntry<String, Uint8List> e in pngs.entries) {
    test('PNG ${e.key} decodes to the same RGBA as package:image', () {
      final ({Uint8List rgba, int width, int height})? got = FushiComputeImage
          .instance
          .decodePngRgba(e.value);
      final img.Image ref = img
          .decodePng(e.value)!
          .convert(format: img.Format.uint8, numChannels: 4, alpha: 255);
      expect(got, isNotNull);
      expect((got!.width, got.height), (ref.width, ref.height));
      expect(got.rgba, ref.toUint8List());
    });
  }

  test('non-PNG / corrupt bytes => null', () {
    expect(encodePngAsJpeg(Uint8List(0), quality: 90), isNull);
    expect(
      encodePngAsJpeg(img.encodeJpg(synthImage(8, 8, 3, 1)), quality: 90),
      isNull,
    );
    final Uint8List png = pngs['3ch']!;
    expect(
      encodePngAsJpeg(
        Uint8List.sublistView(png, 0, png.length ~/ 2),
        quality: 90,
      ),
      isNull,
    );
  });

  for (final int q in <int>[98, 90, 75]) {
    test('JPEG q$q quality is not below package:image encodeJpg', () {
      final img.Image src = synthImage(540, 960, 4, 77);
      final Uint8List png = img.encodePng(src);
      final Uint8List ours = encodePngAsJpeg(png, quality: q)!;
      final Uint8List ref = img.encodeJpg(src, quality: q);
      final img.Image decodedOurs = img.decodeJpg(ours)!;
      expect((decodedOurs.width, decodedOurs.height), (540, 960));
      final double pOurs = _psnr(src, decodedOurs);
      final double pRef = _psnr(src, img.decodeJpg(ref)!);
      expect(
        pOurs,
        greaterThanOrEqualTo(pRef - 0.1),
        reason: 'PSNR $pOurs vs $pRef',
      );
      expect(ours.length, lessThanOrEqualTo(ref.length * 1.03));
    });
  }
}
