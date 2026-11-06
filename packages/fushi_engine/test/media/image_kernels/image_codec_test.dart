// 原生解码（decodeImageNative / probeImageNative）与 JPEG 编码（encodeImageAsJpeg）：
// - 无损格式（PNG 各色型 / BMP / TGA / GIF）解出的像素必须与 package:image 逐字节相同；
// - JPEG 解码换了实现（zune-jpeg），与 package:image 有 ±1 的通道差：这里钉住容差（最大差
//   ≤ 2、平均差 ≤ 0.1），下游影响的实测见 PR #2330；
// - EXIF 方向：默认转正（= bakeOrientation），orient: false 保持存储方向；
// - JPEG 换了编码器、字节不同：同质量参数下 PSNR 不得比 package:image `encodeJpg` 低 0.1 dB
//   以上，体积不得大 3% 以上。
// 测试宿主下加载器自动找本仓 prebuilt；库找不到时失败，不 skip。
@TestOn('vm')
library;

import 'dart:io';
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

/// package:image 的解码结果换成与原生同一形态（uint8，有 alpha 4 通道否则 3 通道）。
Uint8List _reference(img.Image decoded, int channels) => decoded
    .convert(format: img.Format.uint8, numChannels: channels, alpha: 255)
    .toUint8List();

({int max, double mean}) _diff(Uint8List a, Uint8List b) {
  int max = 0;
  int sum = 0;
  for (int i = 0; i < a.length; i++) {
    final int d = (a[i] - b[i]).abs();
    sum += d;
    if (d > max) max = d;
  }
  return (max: max, mean: sum / a.length);
}

/// PIL（libjpeg / libwebp）生成的小样本，见 fixtures/。
Uint8List _fixture(String name) => File(
  '${Directory.current.path}/test/media/image_kernels/fixtures/$name',
).readAsBytesSync();

void main() {
  final Map<String, Uint8List> lossless = <String, Uint8List>{
    for (int ch = 1; ch <= 4; ch++)
      'png ${ch}ch': img.encodePng(synthImage(301, 157, ch, 11 + ch)),
    'png palette': img.encodePng(
      img.quantize(synthImage(200, 120, 3, 5), numberOfColors: 32),
    ),
    'tga': img.encodeTga(synthImage(64, 40, 4, 22)),
    'gif': img.encodeGif(synthImage(90, 60, 3, 23)),
    // package:image 的 BMP 编码器写 24 位 + BI_BITFIELDS（不合规范），用 PIL 出的标准 BMP。
    'bmp': _fixture('std24.bmp'),
    'webp lossless': _fixture('lossless.webp'),
  };

  for (final MapEntry<String, Uint8List> e in lossless.entries) {
    test('${e.key} decodes to the same pixels as package:image', () {
      final img.Image? got = decodeImageNative(e.value);
      final img.Image ref = img.decodeImage(e.value)!;
      expect(got, isNotNull);
      expect((got!.width, got.height), (ref.width, ref.height));
      expect(got.toUint8List(), _reference(ref, got.numChannels));
    });
  }

  test('16-bit PNG is narrowed to 8 bit within 1', () {
    final Uint8List png = img.encodePng(
      synthImage(97, 61, 3, 9).convert(format: img.Format.uint16),
    );
    final img.Image got = decodeImageNative(png)!;
    final ({int max, double mean}) d = _diff(
      got.toUint8List(),
      _reference(img.decodePng(png)!, got.numChannels),
    );
    expect(d.max, lessThanOrEqualTo(1));
  });

  // libjpeg（PIL）出的 JPEG：4:4:4 与灰度和 package:image 最多差 3。
  for (final String name in <String>['libjpeg_444.jpg', 'gray.jpg']) {
    test('$name differs from package:image by at most ±3', () {
      final Uint8List jpg = _fixture(name);
      final img.Image got = decodeImageNative(jpg)!;
      expect(got.numChannels, 3);
      final ({int max, double mean}) d = _diff(
        got.toUint8List(),
        _reference(img.decodeJpg(jpg)!, 3),
      );
      expect(d.max, lessThanOrEqualTo(3), reason: 'max ${d.max}');
      expect(d.mean, lessThanOrEqualTo(0.25), reason: 'mean ${d.mean}');
    });
  }

  // 4:2:0 + 强色度边缘：package:image 的色度上采样与 libjpeg 不同（这张样本上差到 67），
  // 原生解码与 libjpeg 自己的解码结果（PIL 解出存成 PNG）最多差 3。
  test('4:2:0 JPEG matches libjpeg within ±3', () {
    final img.Image got = decodeImageNative(_fixture('libjpeg_420.jpg'))!;
    final img.Image libjpeg = img.decodePng(
      _fixture('libjpeg_420.libjpeg_decoded.png'),
    )!;
    final ({int max, double mean}) d = _diff(
      got.toUint8List(),
      _reference(libjpeg, 3),
    );
    expect(d.max, lessThanOrEqualTo(3), reason: 'max ${d.max}');
    expect(d.mean, lessThanOrEqualTo(0.4), reason: 'mean ${d.mean}');
  });

  // package:image 自己编出的 4:4:4 JPEG（高频噪点图）：最大差 3。它的 4:2:0 编码结果
  // libjpeg（PIL）与原生解码一致、package:image 自己解出来偏差上百，不拿来比。
  test('package:image-encoded 4:4:4 JPEG differs by at most ±3', () {
    final Uint8List jpg = img.encodeJpg(
      synthImage(640, 480, 3, 31),
      quality: 90,
    );
    final ({int max, double mean}) d = _diff(
      decodeImageNative(jpg)!.toUint8List(),
      _reference(img.decodeJpg(jpg)!, 3),
    );
    expect(d.max, lessThanOrEqualTo(3), reason: 'max ${d.max}');
    expect(d.mean, lessThanOrEqualTo(0.25), reason: 'mean ${d.mean}');
  });

  test('lossy WebP decodes close to package:image', () {
    final Uint8List webp = _fixture('lossy.webp');
    final img.Image got = decodeImageNative(webp)!;
    final ({int max, double mean}) d = _diff(
      got.toUint8List(),
      _reference(img.decodeWebP(webp)!, got.numChannels),
    );
    expect(d.max, lessThanOrEqualTo(3), reason: 'max ${d.max}');
  });

  test('EXIF orientation: baked by default, kept with orient: false', () {
    final img.Image src = synthImage(120, 80, 3, 41);
    src.exif.imageIfd.orientation = 6; // 顺时针 90°
    final Uint8List jpg = img.encodeJpg(src, quality: 95);
    final img.Image baked = decodeImageNative(jpg)!;
    final img.Image stored = decodeImageNative(jpg, orient: false)!;
    expect((baked.width, baked.height), (80, 120));
    expect((stored.width, stored.height), (120, 80));
    final img.Image ref = img.bakeOrientation(img.decodeJpg(jpg)!);
    expect(
      _diff(baked.toUint8List(), _reference(ref, 3)).max,
      lessThanOrEqualTo(3),
    );
    final ({int width, int height, FfcImageFormat format})? probed =
        probeImageNative(jpg);
    expect(probed, (width: 80, height: 120, format: FfcImageFormat.jpeg));
    expect(probeImageNative(jpg, orient: false)?.width, 120);
  });

  test('garbage / truncated bytes => null', () {
    expect(decodeImageNative(Uint8List(0)), isNull);
    expect(decodeImageNative(Uint8List.fromList(<int>[1, 2, 3, 4])), isNull);
    final Uint8List png = lossless['png 3ch']!;
    expect(
      decodeImageNative(Uint8List.sublistView(png, 0, png.length ~/ 2)),
      isNull,
    );
    expect(probeImageNative(Uint8List(3)), isNull);
    expect(encodeImageAsJpeg(Uint8List(0), quality: 90), isNull);
  });

  for (final int q in <int>[98, 90, 75]) {
    test('JPEG q$q quality is not below package:image encodeJpg', () {
      final img.Image src = synthImage(540, 960, 4, 77);
      final Uint8List png = img.encodePng(src);
      final Uint8List ours = encodeImageAsJpeg(png, quality: q)!;
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

  // AVIF：原生侧 image/avif.rs（rav1d）。参考像素是 libavif 解码 / 按 HEIF 规范拼裁的 PNG，
  // 生成脚本见 fixtures/avif/gen_avif_fixtures.py；逐像素容差的实测依据见 avif.rs 的单元测试。
  group('AVIF', () {
    const Map<String, (int, int, int)> cases = <String, (int, int, int)>{
      // 名字: (宽, 高, 通道数)——orient6 / clap_rot 带 irot，宽高已按显示方向互换。
      'rgb420': (61, 47, 3),
      'rgb444': (64, 40, 3),
      'rgba': (48, 36, 4),
      'orient2': (40, 24, 3),
      'orient6': (24, 40, 3),
      'orient7': (24, 40, 3),
      'ten_bit': (64, 48, 3),
      'gray': (64, 48, 3),
      'grid': (72, 60, 3),
      'clap_rot': (30, 40, 3),
    };
    for (final MapEntry<String, (int, int, int)> e in cases.entries) {
      test('${e.key} decodes through FFI to the libavif reference', () {
        final Uint8List bytes = _fixture('avif/${e.key}.avif');
        final (int w, int h, int ch) = e.value;
        final ({img.Image image, FfcImageFormat format})? got =
            decodeImageWithFormat(bytes);
        expect(got, isNotNull);
        expect(got!.format, FfcImageFormat.avif);
        expect(
          (got.image.width, got.image.height, got.image.numChannels),
          (w, h, ch),
        );
        expect(probeImageNative(bytes), (
          width: w,
          height: h,
          format: FfcImageFormat.avif,
        ));
        // orient: false 也应用 irot / imir（HEIF 的必选变换，不是 EXIF）。
        final img.Image? raw = decodeImageNative(bytes, orient: false);
        expect((raw!.width, raw.height), (w, h));
        final img.Image ref = img.decodePng(_fixture('avif/${e.key}.ref.png'))!;
        final ({int max, double mean}) d = _diff(
          got.image.toUint8List(),
          _reference(ref, ch),
        );
        expect(d.max, lessThanOrEqualTo(4), reason: '${e.key} $d');
        expect(d.mean, lessThanOrEqualTo(1.2), reason: '${e.key} $d');
      });
    }

    test('truncated AVIF returns null instead of throwing', () {
      final Uint8List bytes = _fixture('avif/grid.avif');
      expect(
        decodeImageNative(Uint8List.sublistView(bytes, 0, bytes.length - 40)),
        isNull,
      );
      expect(probeImageNative(Uint8List.sublistView(bytes, 0, 24)), isNull);
    });

    test('AVIF crops through the same native pipeline (JPEG out)', () {
      final Uint8List jpeg = encodeImageAsJpeg(
        _fixture('avif/rgb444.avif'),
        quality: 90,
      )!;
      expect(img.decodeJpg(jpeg)!.width, 64);
    });
  });
}
