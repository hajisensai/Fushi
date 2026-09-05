/// 与业务无关的 ONNX 推理会话抽象层（OCR / ASR 共用）。
///
/// 把 `flutter_onnxruntime` 包在窄接口后面：算法层只依赖 [OnnxSession] /
/// [OnnxTensor]，单元测试用 fake 实现即可，不需要真模型或 native 绑定。
/// 真实现见 `onnx_inference_ort.dart`。
///
/// 历史：这套类型最初以 `Ocr*` 前缀住在 `lib/src/ocr/ocr_inference.dart`，
/// 有声书 ASR 接入后抬到本文件成为唯一定义；`ocr_inference.dart` 里的 `Ocr*`
/// 名字保留为 typedef 别名，OCR 调用方零改动。
library;

import 'dart:typed_data';

/// 支持的张量元素类型（两个子系统只需要 float32 与 int64）。
enum OnnxTensorType { float32, int64 }

/// 不可变张量：扁平数据 + 形状。
class OnnxTensor {
  OnnxTensor.float32(Float32List data, this.shape)
      : type = OnnxTensorType.float32,
        floatData = data,
        intData = null {
    _checkLength(data.length);
  }

  OnnxTensor.int64(Int64List data, this.shape)
      : type = OnnxTensorType.int64,
        floatData = null,
        intData = data {
    _checkLength(data.length);
  }

  final OnnxTensorType type;
  final List<int> shape;
  final Float32List? floatData;
  final Int64List? intData;

  int get elementCount => shape.fold<int>(1, (int acc, int dim) => acc * dim);

  void _checkLength(int length) {
    if (length != elementCount) {
      throw ArgumentError(
          'OnnxTensor data length $length does not match shape $shape '
          '($elementCount elements)');
    }
  }
}

/// 一次可运行的 ONNX 会话。
abstract interface class OnnxSession {
  /// 运行推理：输入/输出均为 名字 -> 张量。
  ///
  /// 输出张量的元素类型由实现决定；`flutter_onnxruntime` 实现把所有输出读成
  /// float32（int64 输出以整数值落在 float 里，调用方 `round()` 取回）。
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs);

  /// 释放 native 资源。
  Future<void> close();
}

/// 会话工厂：模型文件路径由调用方注入（模型下载管理不在本层）。
abstract interface class OnnxSessionFactory {
  Future<OnnxSession> createSession(
    String modelPath, {
    required List<OnnxExecutionProvider> providers,
  });
}

/// 执行后端（execution provider）。
enum OnnxExecutionProvider { cuda, directml, coreml, cpu }

/// 一次会话创建实际落到哪个执行后端，以及（若发生）降级原因。
///
/// 粒度就是插件边界能给出的粒度：`flutter_onnxruntime` 只回报「整张 provider
/// 列表被接受」或「被拒绝」，不告诉我们 ORT 内部最终选中的 EP。因此
/// [effective] 的语义是「本次真正提交给 ORT 的首选 provider」——列表被接受时
/// 是 [requested] 的首项，被拒绝并回退时是 [OnnxExecutionProvider.cpu]。
///
/// 存在的唯一理由：降级路径必须显式可观测。把 GPU 静默换成 CPU 会让用户在
/// 整卷 OCR / 整本转录这种耗时任务上误判性能，本仓不允许无声降级。
class OnnxProviderResolution {
  const OnnxProviderResolution({
    required this.requested,
    required this.effective,
    this.fallbackReason,
  });

  /// 调用方按平台策略请求的 provider 列表（首项为首选）。
  final List<OnnxExecutionProvider> requested;

  /// 本次会话真正提交给 ORT 的首选 provider。
  final OnnxExecutionProvider effective;

  /// 降级原因；null 表示未降级。
  final String? fallbackReason;

  bool get didFallBack => fallbackReason != null;

  @override
  String toString() {
    if (!didFallBack) return 'OnnxProviderResolution(${effective.name})';
    final String from = requested.isEmpty ? 'none' : requested.first.name;
    return 'OnnxProviderResolution($from -> ${effective.name}: '
        '$fallbackReason)';
  }
}
