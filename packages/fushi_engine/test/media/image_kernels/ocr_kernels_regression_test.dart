// OCR 后段 / 分格排序回归：原生实现（native/fushi_compute `ffc_ocr_*`；测试宿主下加载器自动找
// 本仓 prebuilt）必须逐位复现旧纯 Dart 实现的输出摘要（ocr_kernel_vectors.dart）。库找不到
// 时失败，不 skip。
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

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

  // 按位比：Windows / macOS 用各自平台上旧实现生成的摘要；其它平台（Linux 等）没有按位基线，
  // 分数经 `exp` 的用例只比可移植摘要。
  String? exact(String key) {
    if (Platform.isWindows) return kOcrKernelVectors[key];
    if (Platform.isMacOS) {
      return kOcrKernelVectorsMacosOverrides[key] ?? kOcrKernelVectors[key];
    }
    return kOcrKernelPortableVectors.containsKey(key)
        ? null
        : kOcrKernelVectors[key];
  }

  for (final MapEntry<String, FutureOr<String> Function()> e in cases.entries) {
    final String? want = exact(e.key);
    if (want != null) {
      test(e.key, () async {
        ocrKernelQuantizeScores = false;
        expect(await e.value(), want);
      });
    }
    final String? portable = kOcrKernelPortableVectors[e.key];
    if (portable != null) {
      test('${e.key} (portable)', () async {
        ocrKernelQuantizeScores = true;
        try {
          expect(await e.value(), portable);
        } finally {
          ocrKernelQuantizeScores = false;
        }
      });
    }
  }

  test('platform-dependent cases are the same set in both tables', () {
    expect(
      kOcrKernelVectorsMacosOverrides.keys.toSet(),
      kOcrKernelPortableVectors.keys.toSet(),
    );
  });
}
