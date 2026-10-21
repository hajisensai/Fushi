// FfcAvifAnimation（ffc_image_avif_anim_*）：动图 AVIF 逐帧解码的 FFI 端到端。
//
// 样本 sequence.avif：ffmpeg libsvtav1 编的 64×36 四帧纯色动图（红 / 绿 / 蓝 / 白，
// 80 / 160 / 240 / 40 ms，-loop 0），生成见 fushi_engine 测试样本目录的 gen_avif_fixtures.py。
// 原生库是硬依赖：缺库时 FfcAvifAnimation.open 抛 FushiComputeUnavailableError，测试红而不是跳过。
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

const String _fixtures =
    '../fushi_engine/test/media/image_kernels/fixtures/avif';

Uint8List _fixture(String name) => File('$_fixtures/$name').readAsBytesSync();

const List<List<int>> _colors = <List<int>>[
  <int>[255, 0, 0],
  <int>[0, 255, 0],
  <int>[0, 0, 255],
  <int>[255, 255, 255],
];
const List<int> _durations = <int>[80, 160, 240, 40];

/// 帧中心像素 RGBA。
List<int> _center(Uint8List px, int w, int h) {
  final int i = ((h ~/ 2) * w + w ~/ 2) * 4;
  return px.sublist(i, i + 4);
}

Matcher _near(List<int> rgb) => predicate<List<int>>(
  (List<int> p) =>
      p[3] == 255 &&
      <int>[0, 1, 2].every((int c) => (p[c] - rgb[c]).abs() <= 12),
  'RGB ≈ $rgb, alpha 255',
);

void main() {
  test('animated AVIF decodes frame by frame with durations and loops', () {
    final FfcAvifAnimation anim = FfcAvifAnimation.open(
      _fixture('sequence.avif'),
    )!;
    addTearDown(anim.close);
    expect(anim.frameCount, 4);
    expect(anim.isAnimated, isTrue);
    expect(anim.repeats, isTrue);
    expect((anim.width, anim.height), (64, 36));
    for (int round = 0; round < 2; round++) {
      for (int i = 0; i < 4; i++) {
        final FfcAvifFrame frame = anim.nextFrame()!;
        expect(frame.index, i, reason: 'round $round');
        expect(frame.durationMs, _durations[i], reason: 'round $round #$i');
        expect(frame.pixels.length, 64 * 36 * 4);
        expect(
          _center(frame.pixels, 64, 36),
          _near(_colors[i]),
          reason: 'round $round #$i',
        );
      }
    }
  });

  test('maxWidth downscales preserving aspect, never upscales', () {
    final FfcAvifAnimation small = FfcAvifAnimation.open(
      _fixture('sequence.avif'),
      maxWidth: 32,
    )!;
    addTearDown(small.close);
    expect((small.width, small.height), (32, 18));
    expect((small.sourceWidth, small.sourceHeight), (64, 36));
    final FfcAvifFrame frame = small.nextFrame()!;
    expect(frame.pixels.length, 32 * 18 * 4);
    expect(_center(frame.pixels, 32, 18), _near(_colors[0]));

    final FfcAvifAnimation big = FfcAvifAnimation.open(
      _fixture('sequence.avif'),
      maxWidth: 4096,
    )!;
    addTearDown(big.close);
    expect((big.width, big.height), (64, 36));
  });

  test('still AVIF opens as a single frame', () {
    final FfcAvifAnimation anim = FfcAvifAnimation.open(_fixture('rgba.avif'))!;
    addTearDown(anim.close);
    expect(anim.frameCount, 1);
    expect(anim.isAnimated, isFalse);
    expect(anim.repeats, isFalse);
    final FfcDecodedImage still = FushiComputeImage.instance.decode(
      _fixture('rgba.avif'),
    )!;
    expect((anim.width, anim.height), (still.width, still.height));
    final FfcAvifFrame frame = anim.nextFrame()!;
    expect(frame.durationMs, 0);
    expect(frame.pixels, still.pixels); // rgba.avif 是 4 通道
  });

  test('non-AVIF bytes return null; closed handle throws', () {
    expect(FfcAvifAnimation.open(Uint8List.fromList(<int>[1, 2, 3])), isNull);
    final FfcAvifAnimation anim = FfcAvifAnimation.open(
      _fixture('sequence.avif'),
    )!;
    anim.close();
    anim.close(); // 幂等
    expect(anim.nextFrame, throwsStateError);
  });
}
