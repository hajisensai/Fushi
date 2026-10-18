// 图像内核回归：原生实现（native/fushi_compute；测试宿主下加载器自动找本仓 prebuilt，也可用 FUSHI_COMPUTE_LIB 指定）必须逐位复现
// 旧纯 Dart 实现在合成图上的输出摘要（image_kernel_vectors.dart）。库找不到时整组失败，
// 不 skip。
@TestOn('vm')
library;

import 'package:fushi_compute/fushi_compute.dart';
import 'package:fushi_engine/media/image_kernels.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

import 'image_kernel_cases.dart';
import 'image_kernel_vectors.dart';

img.Image _resize(
  img.Image src, {
  ({int x, int y, int width, int height})? crop,
  required int width,
  required int height,
  required img.Interpolation interpolation,
}) => resizeImageExact(
  src,
  crop: crop,
  width: width,
  height: height,
  interpolation: interpolation,
);

void main() {
  test('native image kernels are loadable', () {
    // 抛 FushiComputeUnavailableError 即失败：图像内核没有 Dart 回退。
    expect(FushiComputeImage.instance, isNotNull);
  });

  final Map<String, String Function()> cases = imageKernelCases(_resize);

  test('every case has a pinned vector and vice versa', () {
    expect(cases.keys.toSet(), kImageKernelVectors.keys.toSet());
  });

  for (final MapEntry<String, String Function()> e in cases.entries) {
    test(e.key, () => expect(e.value(), kImageKernelVectors[e.key]));
  }
}
