/// ONNX 推理会话抽象层。
///
/// 把 `flutter_onnxruntime` 包在窄接口后面：算法层（检测/识别/beam search）
/// 只依赖 [OcrSession] / [OcrTensor]，单元测试用 fake 实现即可，不需要真模型
/// 或 native 绑定。真实现见 `ocr_inference_ort.dart`。
library;

import 'dart:typed_data';

/// 支持的张量元素类型（本子系统只需要 float32 与 int64）。
enum OcrTensorType { float32, int64 }

/// 不可变张量：扁平数据 + 形状。
class OcrTensor {
  OcrTensor.float32(Float32List data, this.shape)
      : type = OcrTensorType.float32,
        floatData = data,
        intData = null {
    _checkLength(data.length);
  }

  OcrTensor.int64(Int64List data, this.shape)
      : type = OcrTensorType.int64,
        floatData = null,
        intData = data {
    _checkLength(data.length);
  }

  final OcrTensorType type;
  final List<int> shape;
  final Float32List? floatData;
  final Int64List? intData;

  int get elementCount => shape.fold<int>(1, (int acc, int dim) => acc * dim);

  void _checkLength(int length) {
    if (length != elementCount) {
      throw ArgumentError(
          'OcrTensor data length $length does not match shape $shape '
          '($elementCount elements)');
    }
  }
}

/// 一次可运行的 ONNX 会话。
abstract interface class OcrSession {
  /// 运行推理：输入/输出均为 名字 -> 张量。
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs);

  /// 释放 native 资源。
  Future<void> close();
}

/// 会话工厂：模型文件路径由调用方注入（模型下载管理不在本层）。
abstract interface class OcrSessionFactory {
  Future<OcrSession> createSession(
    String modelPath, {
    required List<OcrExecutionProvider> providers,
  });
}

/// 执行后端（execution provider）。
enum OcrExecutionProvider { cuda, directml, coreml, cpu }

/// 模型种类：检测（单次前向）与识别（自回归解码）的 EP 策略不同。
enum OcrModelKind { detection, recognition }

/// 平台（纯枚举入参，保持 [selectOcrExecutionProviders] 可测纯函数）。
enum OcrPlatform { windows, macos, ios, linux, android }

/// EP 选择策略（用户拍板 + 本机实测）：
///
/// - Windows 有 CUDA：检测与识别都走 CUDA（fallback CPU）。
/// - Windows 无 CUDA：检测走 DirectML（实测比 CPU 快 ~25 倍），识别走 CPU
///   —— 实测 DirectML 对自回归逐步解码是负优化（每步 GPU 往返开销远大于
///   小 batch 计算本身）。
/// - macOS / iOS：同理，检测尝试 CoreML（fallback CPU），识别走 CPU。
/// - 其他平台：CPU。
///
/// [cudaAvailable] 由调用方探测（例如 `OnnxRuntime().getAvailableProviders()`
/// 是否包含 CUDA），保持本函数无 IO。
List<OcrExecutionProvider> selectOcrExecutionProviders({
  required OcrModelKind kind,
  required OcrPlatform platform,
  required bool cudaAvailable,
}) {
  switch (platform) {
    case OcrPlatform.windows:
      if (cudaAvailable) {
        return const <OcrExecutionProvider>[
          OcrExecutionProvider.cuda,
          OcrExecutionProvider.cpu,
        ];
      }
      if (kind == OcrModelKind.detection) {
        return const <OcrExecutionProvider>[
          OcrExecutionProvider.directml,
          OcrExecutionProvider.cpu,
        ];
      }
      return const <OcrExecutionProvider>[OcrExecutionProvider.cpu];
    case OcrPlatform.macos:
    case OcrPlatform.ios:
      if (kind == OcrModelKind.detection) {
        return const <OcrExecutionProvider>[
          OcrExecutionProvider.coreml,
          OcrExecutionProvider.cpu,
        ];
      }
      return const <OcrExecutionProvider>[OcrExecutionProvider.cpu];
    case OcrPlatform.linux:
    case OcrPlatform.android:
      return const <OcrExecutionProvider>[OcrExecutionProvider.cpu];
  }
}
