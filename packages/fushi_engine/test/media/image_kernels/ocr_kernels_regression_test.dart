// OCR 后段 / 分格排序回归：原生实现（native/fushi_compute `ffc_ocr_*`；测试宿主下加载器自动找
// 本仓 prebuilt）必须逐位复现旧纯 Dart 实现的输出摘要（ocr_kernel_vectors.dart）。库找不到
// 时失败，不 skip。
@TestOn('vm')
library;

import 'dart:async';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

import 'ocr_kernel_cases.dart';
import 'ocr_kernel_vectors.dart';

void main() {
  test('native OCR kernels are loadable', () {
    expect(FushiComputeOcr.instance, isNotNull);
  });

  final Map<String, FutureOr<String> Function()> cases = ocrKernelCases();

  test('every case has a pinned vector and vice versa', () {
    expect(cases.keys.toSet(), kOcrKernelVectors.keys.toSet());
  });

  for (final MapEntry<String, FutureOr<String> Function()> e in cases.entries) {
    test(e.key, () async => expect(await e.value(), kOcrKernelVectors[e.key]));
  }
}
