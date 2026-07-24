/// [OcrSession] 的真实实现：`flutter_onnxruntime` 薄封装。
///
/// 只做三件事：EP 枚举映射、OcrTensor <-> OrtValue 转换、资源释放。
/// 算法层不 import 本文件（依赖 `ocr_inference.dart` 的抽象）。
library;

import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'package:hibiki/src/ocr/ocr_inference.dart';

OrtProvider _toOrtProvider(OcrExecutionProvider provider) {
  switch (provider) {
    case OcrExecutionProvider.cuda:
      return OrtProvider.CUDA;
    case OcrExecutionProvider.directml:
      return OrtProvider.DIRECT_ML;
    case OcrExecutionProvider.coreml:
      return OrtProvider.CORE_ML;
    case OcrExecutionProvider.cpu:
      return OrtProvider.CPU;
  }
}

/// flutter_onnxruntime 会话工厂。
class OrtOcrSessionFactory implements OcrSessionFactory {
  OrtOcrSessionFactory({OnnxRuntime? runtime})
      : _runtime = runtime ?? OnnxRuntime();

  final OnnxRuntime _runtime;

  /// 探测本机可用 EP（用于决定 `cudaAvailable` 再喂给
  /// [selectOcrExecutionProviders]）。
  Future<bool> isCudaAvailable() async {
    final List<OrtProvider> providers = await _runtime.getAvailableProviders();
    return providers.contains(OrtProvider.CUDA);
  }

  @override
  Future<OcrSession> createSession(
    String modelPath, {
    required List<OcrExecutionProvider> providers,
  }) async {
    final OrtSession session = await _runtime.createSession(
      modelPath,
      options: OrtSessionOptions(
        providers: providers.map(_toOrtProvider).toList(),
      ),
    );
    return _OrtOcrSession(session);
  }
}

class _OrtOcrSession implements OcrSession {
  _OrtOcrSession(this._session);

  final OrtSession _session;

  @override
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs) async {
    final Map<String, OrtValue> ortInputs = <String, OrtValue>{};
    try {
      for (final MapEntry<String, OcrTensor> entry in inputs.entries) {
        final OcrTensor tensor = entry.value;
        switch (tensor.type) {
          case OcrTensorType.float32:
            ortInputs[entry.key] =
                await OrtValue.fromList(tensor.floatData!, tensor.shape);
          case OcrTensorType.int64:
            ortInputs[entry.key] =
                await OrtValue.fromList(tensor.intData!, tensor.shape);
        }
      }

      final Map<String, OrtValue> ortOutputs = await _session.run(ortInputs);
      try {
        final Map<String, OcrTensor> outputs = <String, OcrTensor>{};
        for (final MapEntry<String, OrtValue> entry in ortOutputs.entries) {
          final List<dynamic> flat = await entry.value.asFlattenedList();
          // 本子系统的模型输出全部是 float（logits / boxes / hidden states）。
          final Float32List data = Float32List(flat.length);
          for (int i = 0; i < flat.length; i++) {
            data[i] = (flat[i] as num).toDouble();
          }
          outputs[entry.key] =
              OcrTensor.float32(data, List<int>.from(entry.value.shape));
        }
        return outputs;
      } finally {
        for (final OrtValue value in ortOutputs.values) {
          await value.dispose();
        }
      }
    } finally {
      for (final OrtValue value in ortInputs.values) {
        await value.dispose();
      }
    }
  }

  @override
  Future<void> close() => _session.close();
}
