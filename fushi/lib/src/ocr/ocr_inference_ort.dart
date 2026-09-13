/// OCR 侧的 `flutter_onnxruntime` 薄封装。
///
/// 真实现——EP 枚举映射、OnnxTensor <-> OrtValue 转换、provider 回退、资源释放
/// ——如今**唯一**住在 `lib/src/onnx/onnx_inference_ort.dart`（OCR / ASR 共用）。
/// 本文件只剩 OCR 特有的两样东西：`hibiki.ocr` 日志通道，以及 manga-ocr 下载源
/// 不同导出版本的输入名对齐（[resolveOcrSessionInputs]，经共享工厂的
/// `resolveInputs` 钩子注入）。`createOcrSessionWithProviderFallback` /
/// `isLocalOnnxRuntimeAvailable` 保留为转发入口，OCR 调用方与测试零改动。
///
/// 算法层不 import 本文件（依赖 `ocr_inference.dart` 的抽象）。
library;

import 'dart:developer' as developer;
import 'package:flutter/services.dart'
    show BackgroundIsolateBinaryMessenger, RootIsolateToken;
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
export 'package:fushi_engine/ocr/ocr_inference.dart'
    show
        createOcrSessionWithProviderFallback,
        isLocalOnnxRuntimeAvailable,
        kOcrLogName,
        resolveOcrSessionInputs;
import 'package:fushi/src/onnx/onnx_inference_ort.dart';
// 本地推理可不可用的那道闸门随共享 ONNX 抽象一起搬进了 fushi_asr_core；本层保留同名
// getter 转发，OCR 调用方与测试零改动。

/// 本子系统统一的 `dart:developer` 日志通道名。
///
/// 用 `dart:developer` 而不是 `debugPrint`：整卷 OCR 跑在 `Isolate.spawn` 出来
/// 的后台 isolate 里，那里没有 Flutter binding，`debugPrint` 的节流实现依赖
/// binding 的 Timer 调度；`developer.log` 在任何 isolate 都可直接用。
Map<String, OcrTensor> _resolveOcrInputs(
  Map<String, OcrTensor> inputs,
  List<String> sessionInputNames,
) {
  return resolveOcrSessionInputs(
    inputs: inputs,
    sessionInputNames: sessionInputNames,
  );
}

class OrtOcrSessionFactory extends OrtOnnxSessionFactory {
  OrtOcrSessionFactory({OnnxRuntime? runtime})
      : super(
          runtime: runtime,
          resolveInputs: _resolveOcrInputs,
          logName: kOcrLogName,
        );
}

/// 顶层函数：在后台 isolate 里构造插件后端的 OCR 会话工厂
/// （装进引擎 `ocrSessionFactoryBuilder`；只有顶层函数能跨 `Isolate.spawn`）。
OcrSessionFactory buildOrtOcrFactory() => OrtOcrSessionFactory();

/// 顶层函数：后台 isolate 引导——让 flutter_onnxruntime 的 MethodChannel 调用可从
/// 该 isolate 发出。没有 token 就没有 MethodChannel：后面第一次 ORT 调用会以
/// 「No implementation found」告终，而那条报错完全看不出根因在这里，所以留痕。
void fushiOcrIsolateBootstrap(Object? token) {
  if (token is RootIsolateToken) {
    BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    return;
  }
  developer.log(
    'manga OCR volume job started without a RootIsolateToken; '
    'ORT MethodChannel calls from this isolate will fail',
    name: kOcrLogName,
  );
}
