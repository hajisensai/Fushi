/// [OnnxSession] 的真实实现：`flutter_onnxruntime` 薄封装（OCR / ASR 共用）。
///
/// 只做三件事：EP 枚举映射、OnnxTensor <-> OrtValue 转换、资源释放。
/// 算法层不 import 本文件（依赖 `onnx_inference.dart` 的抽象）。
///
/// 历史：这套实现最初以 `Ocr*` 前缀住在 `lib/src/ocr/ocr_inference_ort.dart`，
/// 有声书 ASR 接入后抬到本文件成为唯一实现；OCR 层只剩薄封装
/// （manga-ocr 导出名兼容的输入名对齐 + `hibiki.ocr` 日志通道）。
library;

import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:flutter/services.dart';

import 'package:fushi/src/onnx/onnx_inference.dart';

/// 共享层默认的 `dart:developer` 日志通道名。子系统可经 [logName] 参数换成自己
/// 的通道（OCR 用 `hibiki.ocr`），日志读者按通道过滤即可分清是谁在建会话。
///
/// 用 `dart:developer` 而不是 `debugPrint`：整卷 OCR / 整本转录跑在
/// `Isolate.spawn` 出来的后台 isolate 里，那里没有 Flutter binding，`debugPrint`
/// 的节流实现依赖 binding 的 Timer 调度；`developer.log` 在任何 isolate 都可直接用。
const String kOnnxLogName = 'hibiki.onnx';

/// 本平台是否内置 ONNX Runtime native 库（本地推理是否可用）。
///
/// **当前 Fushi 出包的五端全部为真**。曾经排除 Apple，是因为 vendored fork 把
/// `ios`/`macos` 从 `flutter.plugin.platforms` 删了——那不是 ORT 不支持 Apple，
/// 而是上游随 podspec 附带的 `Package.swift` 会经 SwiftPM 拉进
/// `onnxruntime-swift-package-manager`（清单写死 `.macOS(.v14)`），把整个 app 拖到
/// macOS 14。fork 改成删掉那两个 `Package.swift` 走 CocoaPods 后，真实下限只剩
/// `onnxruntime-objc` 1.23.0 自己的 iOS 15.1 / macOS 13.4，项目部署目标已对齐
/// （见 `third_party/flutter_onnxruntime/PATCHES.md`）。
///
/// 保留这个具名闸门而不是直接写 `true`：它是「本地推理可不可用」的唯一判定点，
/// 将来任一端的 native 再被摘掉（换 ORT 版本、平台下限回退），只改这里，
/// 调用方（`MangaOcrServiceImpl` 的整卷 / 点击 / 框选区域三个入口——框选区域自 PR
/// #1000 起复用同一条引擎链，不再有独立的单框 OCR 服务；以及有声书 ASR）无须改动。
/// OCR 层的 `ocr_inference_ort.dart` 保留同名 getter 转发到这里。
bool get isLocalOnnxRuntimeAvailable =>
    Platform.isWindows ||
    Platform.isLinux ||
    Platform.isAndroid ||
    Platform.isMacOS ||
    Platform.isIOS;

OrtProvider _toOrtProvider(OnnxExecutionProvider provider) {
  switch (provider) {
    case OnnxExecutionProvider.cuda:
      return OrtProvider.CUDA;
    case OnnxExecutionProvider.directml:
      return OrtProvider.DIRECT_ML;
    case OnnxExecutionProvider.coreml:
      return OrtProvider.CORE_ML;
    case OnnxExecutionProvider.cpu:
      return OrtProvider.CPU;
  }
}

/// `getAvailableProviders()` 回报名 -> 本层的加速 EP。
///
/// 只列**加速** EP：CPU 永远可用、永远是最后一档，不需要也不应该参与探测。
/// 运行时回报的其他 EP（TensorRT、XNNPACK…）两个子系统都不选，落 null 被滤掉。
const Map<OrtProvider, OnnxExecutionProvider> _acceleratedProviders =
    <OrtProvider, OnnxExecutionProvider>{
  OrtProvider.CUDA: OnnxExecutionProvider.cuda,
  OrtProvider.DIRECT_ML: OnnxExecutionProvider.directml,
  OrtProvider.CORE_ML: OnnxExecutionProvider.coreml,
};

/// 用配置的加速 EP 创建会话；首选 EP 建不起来时，按 [providers] 中已有的 CPU
/// 后备重试一次。
///
/// 判据是**「首选 EP 没建成会话」**，不是某一个错误码。加速 EP 失败的形态本来
/// 就不止一种：插件不认识这个 provider 会在建 session 之前抛
/// `PlatformException(INVALID_PROVIDER, ...)`；而 ORT 自己初始化 EP 失败是在
/// 建 session 之中抛 `ORT_ERROR`——本机实测 DirectML 初始化 int8 检测器时抛
/// `E_INVALIDARG (80070057)`，走的正是后一条路。按错误码枚举「哪种失败才算 EP
/// 问题」注定漏，而漏掉的代价是整条 OCR 直接不可用：列表尾部那个 CPU 后备明明
/// 在，却一次都轮不到（BUG-2034）。
///
/// 「模型损坏也会被多试一次 CPU」是这么换来的，而且这笔交易划算：那种输入下
/// CPU 同样建不成，最终照样抛错，只是多花一次失败的时间；反过来，为了省这一次
/// 而维护一张错误码白名单，换来的是真·EP 故障时功能整个躺平。
///
/// CPU 重试也失败时抛出的是**CPU 那次**的异常（类型与内容都不变，调用方原有的
/// `on PlatformException` 之类照旧成立），首选 EP 的失败则落进日志——两次失败
/// 都得留痕，回退不能变成「把第一个错误吃掉」。
///
/// [onResolved] 在会话建成后**必定**被调用一次，回报本次真正生效的 provider
/// 与降级原因（BUG-1163）：降级不允许静默发生，调用层据此写日志并把状态送到
/// UI。回调本身抛出的异常不影响会话创建结果，只落日志。
///
/// [logName] 是日志通道名（默认 [kOnnxLogName]；OCR 传 `hibiki.ocr`）。
Future<T> createOnnxSessionWithProviderFallback<T>({
  required List<OnnxExecutionProvider> providers,
  required Future<T> Function(List<OnnxExecutionProvider> providers) create,
  void Function(OnnxProviderResolution resolution)? onResolved,
  String logName = kOnnxLogName,
}) async {
  final OnnxExecutionProvider preferred =
      providers.isEmpty ? OnnxExecutionProvider.cpu : providers.first;
  try {
    final T session = await create(providers);
    _notifyResolved(
      onResolved,
      OnnxProviderResolution(requested: providers, effective: preferred),
      logName,
    );
    return session;
  } on Exception catch (error) {
    final bool canRetryOnCpu = preferred != OnnxExecutionProvider.cpu &&
        providers.contains(OnnxExecutionProvider.cpu);
    if (!canRetryOnCpu) rethrow;
    developer.log(
      'ONNX session on ${preferred.name} failed; retrying on CPU',
      name: logName,
      error: error,
    );
    final T session;
    try {
      session = await create(const <OnnxExecutionProvider>[
        OnnxExecutionProvider.cpu,
      ]);
    } on Exception catch (cpuError) {
      developer.log(
        'ONNX session fell back to CPU and failed there too; '
        '${preferred.name} had failed with: $error',
        name: logName,
        error: cpuError,
      );
      rethrow;
    }
    _notifyResolved(
      onResolved,
      OnnxProviderResolution(
        requested: providers,
        effective: OnnxExecutionProvider.cpu,
        fallbackReason: _describeProviderFailure(error),
      ),
      logName,
    );
    return session;
  }
}

/// 降级原因的可读形态。
///
/// `PlatformException` 保留 `code: message` 的老格式（UI 与日志都按它读）；其余
/// 异常直接用 `toString`——比如 native 把非 UTF-8 字节送过 channel 时 Dart 侧抛的
/// `FormatException`，那串偏移量本身就是排查线索，不该被抹成一句“未知错误”。
String _describeProviderFailure(Object error) {
  if (error is PlatformException) {
    return '${error.code}: ${error.message ?? 'provider rejected by plugin'}';
  }
  return '$error';
}

void _notifyResolved(
  void Function(OnnxProviderResolution resolution)? onResolved,
  OnnxProviderResolution resolution,
  String logName,
) {
  if (resolution.didFallBack) {
    developer.log(
      'ONNX execution provider fell back: $resolution',
      name: logName,
    );
  } else {
    developer.log(
      'ONNX execution provider resolved: $resolution',
      name: logName,
    );
  }
  if (onResolved == null) return;
  try {
    onResolved(resolution);
  } catch (error, stack) {
    developer.log(
      'ONNX provider resolution callback threw',
      name: logName,
      error: error,
      stackTrace: stack,
    );
  }
}

/// 把算法层的语义输入名对齐到会话元数据里真实输入名的钩子。
///
/// 不传时输入名**精确匹配**（ASR：sherpa-onnx 导出的 IO 名已在
/// `asr_types.dart` 集中核实，不需要也不该猜）。OCR 传
/// `resolveOcrSessionInputs`：manga-ocr 下载源不同导出版本用过 `pixel_values` /
/// `images` 等名字，单输入模型按元数据对齐——那是 OCR 特有的兼容层，不进共享层。
typedef OnnxSessionInputResolver = Map<String, OnnxTensor> Function(
  Map<String, OnnxTensor> inputs,
  List<String> sessionInputNames,
);

/// flutter_onnxruntime 会话工厂。
class OrtOnnxSessionFactory implements OnnxSessionFactory {
  OrtOnnxSessionFactory({
    OnnxRuntime? runtime,
    OnnxSessionInputResolver? resolveInputs,
    this.logName = kOnnxLogName,
  })  : _runtime = runtime ?? OnnxRuntime(),
        _resolveInputs = resolveInputs;

  final OnnxRuntime _runtime;
  final OnnxSessionInputResolver? _resolveInputs;

  /// 本工厂建会话 / 回退时写日志用的通道名。
  final String logName;

  /// 探测本机 ORT 运行时**编译进来**的加速 EP 集合，喂给各子系统的 EP 选择
  /// 纯函数（OCR `selectOcrExecutionProviders` / ASR `selectAsrEncoderProviders`）。
  ///
  /// BUG-2050 的根因修复点：原先这里只问 CUDA，DirectML 的可用性靠平台分支硬
  /// 假设。但 `getAvailableProviders()` 本来就一次性回报全部 EP（native 侧
  /// `flutter_onnxruntime_plugin.cpp` 明确把 `DmlExecutionProvider` 映射成
  /// `DIRECT_ML`），问一个和问全部同价——不问才是 bug。
  ///
  /// **语义边界**：这里回报的是「该 EP 编译进了当前 onnxruntime 运行时」，
  /// **不是**「它此刻真能建出会话」（DirectML 还要能建出 D3D12 设备，CUDA 还要
  /// 有驱动和可用显卡）。必要不充分，别拿它当运行期可用性的结论——
  /// [createOnnxSessionWithProviderFallback] 那层 CPU 回退因此不是死代码。
  ///
  /// 探测本身失败是一条真实的降级路径（有 N 卡也会退到 CPU），不允许调用方
  /// `catch (_)` 静默吞掉——所以这里不吞异常，由调用方捕获后记进可观测的降级
  /// 说明（BUG-1163）。
  /// GPU 显存预算（字节；DXGI 本进程可分配上限）。非 Windows、无 GPU、查询失败
  /// 都返回 null——调用方按「未知」处理，不当成 0。
  Future<int?> deviceMemoryBudgetBytes() async {
    try {
      final OrtDeviceMemoryInfo? info = await _runtime.getDeviceMemoryInfo();
      if (info == null || info.isSoftware || info.budget <= 0) return null;
      return info.budget;
    } catch (error) {
      developer.log(
        'ONNX device memory budget query failed; treating as unknown',
        name: logName,
        error: error,
      );
      return null;
    }
  }

  Future<Set<OnnxExecutionProvider>> availableAcceleratedProviders() async {
    final List<OrtProvider> providers = await _runtime.getAvailableProviders();
    return providers
        .map((OrtProvider provider) => _acceleratedProviders[provider])
        .whereType<OnnxExecutionProvider>()
        .toSet();
  }

  @override
  Future<OnnxSession> createSession(
    String modelPath, {
    required List<OnnxExecutionProvider> providers,
    void Function(OnnxProviderResolution resolution)? onProviderResolved,
    int? intraOpNumThreads,
    Map<String, int>? freeDimensionOverrides,
  }) async {
    final OrtSession session =
        await createOnnxSessionWithProviderFallback<OrtSession>(
      providers: providers,
      onResolved: onProviderResolved,
      logName: logName,
      create: (List<OnnxExecutionProvider> effectiveProviders) =>
          _runtime.createSession(
        modelPath,
        options: OrtSessionOptions(
          providers: effectiveProviders.map(_toOrtProvider).toList(),
          intraOpNumThreads: intraOpNumThreads,
          freeDimensionOverrides: freeDimensionOverrides,
        ),
      ),
    );
    return _OrtOnnxSession(session, _resolveInputs);
  }
}

class _OrtOnnxSession implements OnnxSession {
  _OrtOnnxSession(this._session, this._resolveInputs);

  final OrtSession _session;
  final OnnxSessionInputResolver? _resolveInputs;

  /// 运行推理。
  ///
  /// **输出统一读成 float32**（[OnnxSession.run] 的契约），但按 [OrtValue.dataType]
  /// 分支而不是盲转：
  /// - 浮点（float32 / float16 / bfloat16）原值落入 float32；
  /// - 整数（int64 / int32 / … / uint64）按整数值落入 float32——OCR 的
  ///   `orig_target_sizes` 类输出与 ASR 的 `encoder_out_lens`（帧数，≤ 数万）都在
  ///   float32 精确表示整数的范围（|v| ≤ 2^24）内，调用方 `round()` 取回；超出该
  ///   范围只会丢低位精度，不会丢符号、不会截断、不会静默变 0；
  /// - bool 落成 1.0 / 0.0；
  /// - string / complex 输出两个子系统都没有，遇到即抛 [UnsupportedError]——
  ///   把它们硬转成数字是无声的垃圾数据，比抛错更糟。
  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) async {
    final Map<String, OrtValue> ortInputs = <String, OrtValue>{};
    try {
      final OnnxSessionInputResolver? resolve = _resolveInputs;
      final Map<String, OnnxTensor> resolvedInputs =
          resolve == null ? inputs : resolve(inputs, _session.inputNames);
      for (final MapEntry<String, OnnxTensor> entry in resolvedInputs.entries) {
        final OnnxTensor tensor = entry.value;
        switch (tensor.type) {
          case OnnxTensorType.float32:
            ortInputs[entry.key] = await OrtValue.fromList(
              tensor.floatData!,
              tensor.shape,
            );
          case OnnxTensorType.int64:
            ortInputs[entry.key] = await OrtValue.fromList(
              tensor.intData!,
              tensor.shape,
            );
        }
      }

      final Map<String, OrtValue> ortOutputs = await _session.run(ortInputs);
      try {
        final Map<String, OnnxTensor> outputs = <String, OnnxTensor>{};
        for (final MapEntry<String, OrtValue> entry in ortOutputs.entries) {
          outputs[entry.key] = await _readAsFloat32(entry.key, entry.value);
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

  static Future<OnnxTensor> _readAsFloat32(String name, OrtValue value) async {
    final List<dynamic> flat = await value.asFlattenedList();
    // 快路径：Windows/Android 端 float32 输出经 StandardMessageCodec 直接落成
    // Float32List，逐元素拆箱再拷一遍纯属浪费——RNN-T 逐帧 joiner 每步要读回
    // batch×5224 个 logit，这条路径是热点。
    if (flat is Float32List) {
      return OnnxTensor.float32(flat, List<int>.from(value.shape));
    }
    final Float32List data = Float32List(flat.length);
    switch (value.dataType) {
      case OrtDataType.float32:
      case OrtDataType.float16:
      case OrtDataType.bfloat16:
      case OrtDataType.int64:
      case OrtDataType.int32:
      case OrtDataType.int16:
      case OrtDataType.int8:
      case OrtDataType.uint8:
      case OrtDataType.uint16:
      case OrtDataType.uint32:
      case OrtDataType.uint64:
        for (int i = 0; i < flat.length; i++) {
          data[i] = (flat[i] as num).toDouble();
        }
      case OrtDataType.bool:
        for (int i = 0; i < flat.length; i++) {
          data[i] = (flat[i] as bool) ? 1.0 : 0.0;
        }
      case OrtDataType.string:
      case OrtDataType.complex64:
      case OrtDataType.complex128:
        throw UnsupportedError(
          'ONNX output "$name" has ${value.dataType.name} elements; '
          'OnnxSession.run only carries numeric/bool outputs as float32',
        );
    }
    return OnnxTensor.float32(data, List<int>.from(value.shape));
  }

  @override
  Future<void> close() => _session.close();
}
