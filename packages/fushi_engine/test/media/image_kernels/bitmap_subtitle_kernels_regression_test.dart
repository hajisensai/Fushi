// 位图字幕内核回归：原生实现（经 FUSHI_COMPUTE_LIB 定位）必须逐位复现旧纯 Dart 实现在
// 合成码流上的输出摘要（bitmap_subtitle_kernel_vectors.dart）。库找不到时失败，不 skip。
@TestOn('vm')
library;

import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

import 'bitmap_subtitle_kernel_cases.dart';
import 'bitmap_subtitle_kernel_vectors.dart';

void main() {
  test('native bitmap subtitle kernels are loadable', () {
    expect(FushiComputeBitmapSubtitle.instance, isNotNull);
  });

  final Map<String, String Function()> cases = bitmapSubtitleKernelCases();

  test('every case has a pinned vector and vice versa', () {
    expect(cases.keys.toSet(), kBitmapSubtitleKernelVectors.keys.toSet());
  });

  for (final MapEntry<String, String Function()> e in cases.entries) {
    test(e.key, () => expect(e.value(), kBitmapSubtitleKernelVectors[e.key]));
  }
}
