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

import 'dart:io';
import 'dart:typed_data';

/// 支持的张量元素类型：float32 / int64 给 OCR 与大多数 ASR 模型；int32 给把
/// 索引张量导成 int32 的 ASR 导出（X-ASR zipformer，`asr_model_manifest.dart`）。
enum OnnxTensorType { float32, int64, int32 }

/// 不可变张量：扁平数据 + 形状。
class OnnxTensor {
  OnnxTensor.float32(Float32List data, this.shape)
      : type = OnnxTensorType.float32,
        floatData = data,
        intData = null,
        int32Data = null {
    _checkLength(data.length);
  }

  OnnxTensor.int64(Int64List data, this.shape)
      : type = OnnxTensorType.int64,
        floatData = null,
        intData = data,
        int32Data = null {
    _checkLength(data.length);
  }

  OnnxTensor.int32(Int32List data, this.shape)
      : type = OnnxTensorType.int32,
        floatData = null,
        intData = null,
        int32Data = data {
    _checkLength(data.length);
  }

  final OnnxTensorType type;
  final List<int> shape;
  final Float32List? floatData;
  final Int64List? intData;
  final Int32List? int32Data;

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
  /// [intraOpNumThreads]：ORT 单算子内并行线程数；null 用 ORT 默认（全核）。
  /// 小矩阵逐帧型的图（ASR 贪心 Loop 图）全核反而慢，调用方按实测传。
  ///
  /// [freeDimensionOverrides]：把模型输入的符号维度（如 `N` / `T`）钉成固定值
  /// （ORT `AddFreeDimensionOverrideByName`）。全部输入 shape 静态后 ORT 能在建
  /// 会话时把整图融合/编译一次，而不是每次 run 重新规划——DirectML 上 zipformer
  /// 编码器吞吐 5~7 倍（见 `asr_encoder_buckets.dart`）。之后喂进来的张量必须
  /// **恰好**是这些维度。只有 Windows 插件实现了此项，其它平台忽略。
  Future<OnnxSession> createSession(
    String modelPath, {
    required List<OnnxExecutionProvider> providers,
    int? intraOpNumThreads,
    Map<String, int>? freeDimensionOverrides,
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

/// `FUSHI_ASR_TRACE=<文件路径>`：每次 [OnnxSession.run] 追加一行分步耗时
/// （建输入张量 / Run / 读回输出 / 释放），encode 也记张量填充耗时——Dart↔插件
/// 往返有多贵只能这样量，`AsrDecodeStats` 的分段计时把等待都算在一起分不出来。
/// 落文件而不是 stdout：转录跑在后台 isolate，那里的 `print` 进不了集成测试的
/// command.log。诊断开关，生产不设。
final String? kOnnxTraceFile = () {
  final String? v = Platform.environment['FUSHI_ASR_TRACE'];
  return v == null || v.isEmpty ? null : v;
}();

bool get kOnnxTraceEnabled => kOnnxTraceFile != null;

/// 追加一行 trace（同步小写；只在 [kOnnxTraceEnabled] 时调）。
void onnxTrace(String line) {
  final String? path = kOnnxTraceFile;
  if (path == null) return;
  File(path).writeAsStringSync(
    '${DateTime.now().toIso8601String()} $line\n',
    mode: FileMode.append,
    flush: true,
  );
}
