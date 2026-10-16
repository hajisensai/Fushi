/// [OnnxSession] 的真实实现：`flutter_onnxruntime` 薄封装（OCR / ASR 共用）。
///
/// 只做三件事：EP 枚举映射、OnnxTensor <-> OrtValue 转换、资源释放。
/// 算法层不 import 本文件（依赖 `onnx_inference.dart` 的抽象）。
///
/// 历史：这套实现最初以 `Ocr*` 前缀住在 `lib/src/ocr/ocr_inference_ort.dart`，
/// 有声书 ASR 接入后抬到本文件成为唯一实现；OCR 层只剩薄封装
/// （manga-ocr 导出名兼容的输入名对齐 + `fushi.ocr` 日志通道）。
library;

import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:flutter/services.dart';

// `kOnnxLogName` 两边都有：本仓这份是 'fushi.onnx' 日志通道，明确 hide 掉
// 包里那份，别靠「本地声明遮蔽 import」这条隐式规则。
import 'package:fushi_asr_core/asr_core.dart' hide kOnnxLogName;
import 'package:fushi_engine/ocr/ocr_tensor_handles.dart'
    show OcrHandleRunResult, OcrHandleSession, OcrTensorHandle;

/// 共享层默认的 `dart:developer` 日志通道名。子系统可经 [logName] 参数换成自己
/// 的通道（OCR 用 `fushi.ocr`），日志读者按通道过滤即可分清是谁在建会话。
///
/// 用 `dart:developer` 而不是 `debugPrint`：整卷 OCR / 整本转录跑在
/// `Isolate.spawn` 出来的后台 isolate 里，那里没有 Flutter binding，`debugPrint`
/// 的节流实现依赖 binding 的 Timer 调度；`developer.log` 在任何 isolate 都可直接用。
const String kOnnxLogName = 'fushi.onnx';

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

/// 把算法层的语义输入名对齐到会话元数据里真实输入名的钩子。
///
/// 不传时输入名**精确匹配**（ASR：sherpa-onnx 导出的 IO 名已在
/// `asr_types.dart` 集中核实，不需要也不该猜）。OCR 传
/// `resolveOcrSessionInputs`：manga-ocr 下载源不同导出版本用过 `pixel_values` /
/// `images` 等名字，单输入模型按元数据对齐——那是 OCR 特有的兼容层，不进共享层。
typedef OnnxSessionInputResolver =
    Map<String, OnnxTensor> Function(
      Map<String, OnnxTensor> inputs,
      List<String> sessionInputNames,
    );

/// 把插件后端的 `PlatformException` 拆成 `code: message` 装进
/// [OnnxProviderResolution.fallbackReason]。
///
/// fushi_asr_core 的回退策略是后端无关的，默认只会 `toString()`。本仓的 UI 与日志按
/// `code: message` 这个老格式读（`PlatformException.toString()` 会带上 details 与
/// stacktrace，读起来完全是另一回事），所以在这里把描述器换回来。
///
/// 其余异常仍走 `toString`——比如 native 把非 UTF-8 字节送过 channel 时 Dart 侧抛的
/// `FormatException`，那串偏移量本身就是排查线索，不该被抹成一句「未知错误」。
void _installFushiProviderFailureDescriber() {
  if (_describerInstalled) return;
  _describerInstalled = true;
  onnxProviderFailureDescriber = (Object error) {
    if (error is PlatformException) {
      return '${error.code}: ${error.message ?? 'provider rejected by plugin'}';
    }
    return '$error';
  };
}

bool _describerInstalled = false;

/// flutter_onnxruntime 会话工厂。
class OrtOnnxSessionFactory implements OnnxSessionFactory {
  OrtOnnxSessionFactory({
    OnnxRuntime? runtime,
    OnnxSessionInputResolver? resolveInputs,
    this.logName = kOnnxLogName,
  }) : _runtime = runtime ?? OnnxRuntime(),
       _resolveInputs = resolveInputs {
    _installFushiProviderFailureDescriber();
  }

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
  @override
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

  /// 问 NVIDIA 驱动有没有能跑 CUDA 的卡（只加载 `nvcuda.dll`，不需要 CUDA 运行库
  /// 已下载）。见 [probeCuda]。
  Future<CudaProbe> probeCuda() => probeCudaWith(_runtime);

  /// 把 [dir] 下的 CUDA 插件 EP 注册进本进程。见 [registerCudaRuntime]。
  Future<CudaRegistration> registerCudaRuntime(String dir) =>
      registerCudaRuntimeWith(_runtime, dir);

  /// 本进程用哪份 onnxruntime。见 [ortRuntimeInfo]。
  Future<OrtRuntimeInfo> runtimeInfo() => ortRuntimeInfoWith(_runtime);

  @override
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

class _OrtOnnxSession implements OnnxSession, OcrHandleSession {
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
    final Stopwatch? trace = kOnnxTraceEnabled ? (Stopwatch()..start()) : null;
    int tIn = 0;
    int tRun = 0;
    int tOut = 0;
    int elems = 0;
    try {
      final OnnxSessionInputResolver? resolve = _resolveInputs;
      final Map<String, OnnxTensor> resolvedInputs = resolve == null
          ? inputs
          : resolve(inputs, _session.inputNames);
      for (final MapEntry<String, OnnxTensor> entry in resolvedInputs.entries) {
        ortInputs[entry.key] = await _toOrtValue(entry.value);
      }

      if (trace != null) tIn = trace.elapsedMilliseconds;
      final Map<String, OrtValue> ortOutputs = await _session.run(ortInputs);
      if (trace != null) tRun = trace.elapsedMilliseconds - tIn;
      try {
        final Map<String, OnnxTensor> outputs = <String, OnnxTensor>{};
        for (final MapEntry<String, OrtValue> entry in ortOutputs.entries) {
          final OnnxTensor t = await _readAsFloat32(entry.key, entry.value);
          elems += t.floatData?.length ?? 0;
          outputs[entry.key] = t;
        }
        if (trace != null) tOut = trace.elapsedMilliseconds - tIn - tRun;
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
      if (trace != null) {
        final int total = trace.elapsedMilliseconds;
        onnxTrace(
          '[onnx-trace] in=${tIn}ms run=${tRun}ms out=${tOut}ms '
          'dispose=${total - tIn - tRun - tOut}ms total=${total}ms '
          'outElems=$elems inputs=${ortInputs.keys.join(',')}',
        );
      }
    }
  }

  static Future<OrtValue> _toOrtValue(OnnxTensor tensor) {
    switch (tensor.type) {
      case OnnxTensorType.float32:
        return OrtValue.fromList(tensor.floatData!, tensor.shape);
      case OnnxTensorType.int64:
        return OrtValue.fromList(tensor.intData!, tensor.shape);
      case OnnxTensorType.int32:
        return OrtValue.fromList(tensor.int32Data!, tensor.shape);
    }
  }

  /// 句柄式运行（[OcrHandleSession]）：插件的 [OrtValue] 本就只是原生侧 id，
  /// 输出留在原生侧、下一步原样当输入，只有 [fetch] 里的输出读回 Dart。
  /// manga-ocr KV cache 解码靠它把每步过通道的数据从几 MB 降到一行 logits。
  @override
  Future<OcrTensorHandle> upload(OnnxTensor tensor) async =>
      _OrtTensorHandle(await _toOrtValue(tensor));

  @override
  Future<OcrHandleRunResult> runWithHandles({
    Map<String, OnnxTensor> tensors = const <String, OnnxTensor>{},
    Map<String, OcrTensorHandle> handles = const <String, OcrTensorHandle>{},
    required Set<String> fetch,
  }) async {
    final Map<String, OrtValue> uploaded = <String, OrtValue>{};
    try {
      final OnnxSessionInputResolver? resolve = _resolveInputs;
      final Map<String, OnnxTensor> resolvedTensors =
          resolve == null || tensors.isEmpty || handles.isNotEmpty
          ? tensors
          : resolve(tensors, _session.inputNames);
      for (final MapEntry<String, OnnxTensor> entry
          in resolvedTensors.entries) {
        uploaded[entry.key] = await _toOrtValue(entry.value);
      }
      final Map<String, OrtValue> inputs = <String, OrtValue>{...uploaded};
      for (final MapEntry<String, OcrTensorHandle> entry in handles.entries) {
        final OcrTensorHandle handle = entry.value;
        if (handle is! _OrtTensorHandle) {
          throw ArgumentError.value(
            handle,
            entry.key,
            'handle belongs to a different inference backend',
          );
        }
        inputs[entry.key] = handle.value;
      }
      final Map<String, OrtValue> outputs = await _session.run(inputs);
      final Map<String, OnnxTensor> fetched = <String, OnnxTensor>{};
      final Map<String, OcrTensorHandle> kept = <String, OcrTensorHandle>{};
      try {
        for (final MapEntry<String, OrtValue> entry in outputs.entries) {
          if (fetch.contains(entry.key)) {
            fetched[entry.key] = await _readAsFloat32(entry.key, entry.value);
            await entry.value.dispose();
          } else {
            kept[entry.key] = _OrtTensorHandle(entry.value);
          }
        }
      } catch (_) {
        for (final OrtValue value in outputs.values) {
          await value.dispose();
        }
        rethrow;
      }
      return OcrHandleRunResult(fetched: fetched, kept: kept);
    } finally {
      for (final OrtValue value in uploaded.values) {
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

/// 插件原生侧的一份张量（[OrtValue] 只是原生 id）。
class _OrtTensorHandle implements OcrTensorHandle {
  _OrtTensorHandle(this.value);

  final OrtValue value;
  bool _disposed = false;

  @override
  List<int> get shape => List<int>.from(value.shape);

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await value.dispose();
  }
}

/// 一张 CUDA 设备（`nvcuda.dll` 驱动 API 回报，与 ORT 无关）。
class CudaDevice {
  const CudaDevice({
    required this.index,
    required this.name,
    required this.computeMajor,
    required this.computeMinor,
    required this.totalMemBytes,
  });

  /// CUDA 设备序号（`cuDeviceGet` 的 ordinal）。注意：与 DXGI 适配器序号不一定
  /// 一致（多卡 / 笔记本 Optimus）。
  final int index;
  final String name;
  final int computeMajor;
  final int computeMinor;
  final int totalMemBytes;

  /// 计算能力合成一个整数便于比较，如 sm_89 -> 89、sm_120 -> 120。
  int get smVersion => computeMajor * 10 + computeMinor;

  @override
  String toString() =>
      'CudaDevice($index, $name, sm_$computeMajor$computeMinor, '
      '${totalMemBytes ~/ (1024 * 1024)} MiB)';
}

/// [probeCuda] 的结果。
class CudaProbe {
  const CudaProbe({
    required this.driverVersion,
    required this.devices,
    this.error,
  });

  /// 平台没有这项查询（非 Windows）时的结果。
  const CudaProbe.unsupported()
    : driverVersion = null,
      devices = const <CudaDevice>[],
      error = 'CUDA probe is not supported on this platform';

  /// `cuDriverGetVersion`（如 13000 = CUDA 13.0）；没有 NVIDIA 驱动时 null。
  final int? driverVersion;
  final List<CudaDevice> devices;

  /// 第一处失败（没装驱动、`cuInit` 失败……）；null 表示驱动完整作答。
  final String? error;

  @override
  String toString() =>
      'CudaProbe(driver=$driverVersion, devices=$devices, error=$error)';
}

/// [registerCudaRuntime] 的结果。
class CudaRegistration {
  const CudaRegistration({
    required this.ok,
    required this.deviceCount,
    this.error,
  });

  /// 平台没有插件 EP 这条路（非 Windows）时的结果。
  const CudaRegistration.unsupported()
    : ok = false,
      deviceCount = 0,
      error =
          'CUDA plugin execution provider is not supported on this '
          'platform';

  final bool ok;

  /// ORT 认到的 CUDA 设备数（`GetEpDevices` 里 CUDAExecutionProvider 的条目数）。
  final int deviceCount;
  final String? error;

  @override
  String toString() =>
      'CudaRegistration(ok=$ok, devices=$deviceCount, error=$error)';
}

int _asInt(Object? value) => value is num ? value.toInt() : 0;

/// 问 NVIDIA 驱动（只加载 `nvcuda.dll` + `cuInit` / `cuDeviceGet*`）有哪些 CUDA
/// 设备、驱动支持到哪个 CUDA 版本。**不需要** CUDA 运行库已下载，用来在提供下载
/// 之前判断值不值得：CUDA 13 要求驱动 ≥ 13000（R580+）且 sm_75+。
///
/// 非 Windows 回 [CudaProbe.unsupported]；插件调用本身失败照常抛（不吞）。
Future<CudaProbe> probeCuda() => probeCudaWith(OnnxRuntime());

/// [probeCuda] 的可注入 runtime 版本。
Future<CudaProbe> probeCudaWith(OnnxRuntime runtime) async {
  final Map<String, dynamic>? map = await runtime.probeCuda();
  if (map == null) return const CudaProbe.unsupported();
  final Object? rawDevices = map['devices'];
  final List<CudaDevice> devices = <CudaDevice>[
    if (rawDevices is List)
      for (final Object? raw in rawDevices)
        if (raw is Map)
          CudaDevice(
            index: _asInt(raw['index']),
            name: '${raw['name'] ?? ''}',
            computeMajor: _asInt(raw['computeMajor']),
            computeMinor: _asInt(raw['computeMinor']),
            totalMemBytes: _asInt(raw['totalMemBytes']),
          ),
  ];
  final Object? driver = map['driverVersion'];
  final Object? error = map['error'];
  return CudaProbe(
    driverVersion: driver is num ? driver.toInt() : null,
    devices: devices,
    error: error is String ? error : null,
  );
}

/// 把 [dir] 下的 ORT CUDA 插件 EP（`onnxruntime_providers_cuda.dll` 及同目录的
/// cuBLAS / cuDNN）注册进**本进程**（进程级状态，任何 isolate 调都一样）。
///
/// 成功后 [OrtOnnxSessionFactory.availableAcceleratedProviders] 会回报
/// [OnnxExecutionProvider.cuda]，建会话可以请求它；没注册就请求 CUDA，建会话
/// 那一步报 `PROVIDER_ERROR`，按 [createOnnxSessionWithProviderFallback] 的约定
/// 可观测地降级。同一 [dir] 重复调用直接返回上次的成功结果；失败不留半注册状态，
/// 可以（比如下载补齐后）重试；已从别的目录注册成功时拒绝换目录（需重启 app）。
///
/// 注意：cuDNN 缺失 / 版本不对在建会话时**不报错**，第一次 Run 走到 Conv 才失败
/// ——调用方要拿首个 Run 当健康检查。
Future<CudaRegistration> registerCudaRuntime(String dir) =>
    registerCudaRuntimeWith(OnnxRuntime(), dir);

/// [registerCudaRuntime] 的可注入 runtime 版本。
Future<CudaRegistration> registerCudaRuntimeWith(
  OnnxRuntime runtime,
  String dir,
) async {
  final Map<String, dynamic>? map = await runtime.registerCudaRuntime(dir);
  if (map == null) return const CudaRegistration.unsupported();
  final Object? error = map['error'];
  return CudaRegistration(
    ok: map['ok'] == true,
    deviceCount: _asInt(map['deviceCount']),
    error: error is String ? error : null,
  );
}

/// 本进程实际绑定的 onnxruntime（Windows：随包的最新 CPU core，或下载的 DirectML
/// core）。
class OrtRuntimeInfo {
  const OrtRuntimeInfo({
    required this.loaded,
    required this.version,
    required this.selectedPath,
  });

  /// 平台没有 core 选择（非 Windows）时的结果。
  const OrtRuntimeInfo.unsupported()
    : loaded = false,
      version = '',
      selectedPath = '';

  /// ORT 是否已经在本进程绑定（绑定后换 core 只能重启）。
  final bool loaded;

  /// 已绑定 core 的版本串（如 `1.31.0`）；未绑定时空串。
  final String version;

  /// 经 [selectOrtRuntime] 选中的 core 路径；空串 = 随包那份。
  final String selectedPath;

  @override
  String toString() =>
      'OrtRuntimeInfo(loaded=$loaded, version=$version, '
      'selectedPath=$selectedPath)';
}

/// [selectOrtRuntime] 的结果。
class OrtRuntimeSelection {
  const OrtRuntimeSelection({required this.ok, this.error});

  /// 平台没有 core 选择（非 Windows）时的结果。
  const OrtRuntimeSelection.unsupported()
    : ok = false,
      error = 'ONNX Runtime core selection is not supported on this platform';

  final bool ok;
  final String? error;

  @override
  String toString() => 'OrtRuntimeSelection(ok=$ok, error=$error)';
}

/// 让本进程改用 [path] 处的 onnxruntime.dll（下载的 DirectML core）而不是随包的
/// CPU core。**必须在本进程任何 ORT 调用之前**（建会话、查 provider……）调；ORT
/// 已绑定后只有同一路径回 ok，换 core 要重启 app。`probeCuda` /
/// [ortRuntimeInfo] 不绑定 ORT，可以先调。
Future<OrtRuntimeSelection> selectOrtRuntime(String path) =>
    selectOrtRuntimeWith(OnnxRuntime(), path);

/// [selectOrtRuntime] 的可注入 runtime 版本。
Future<OrtRuntimeSelection> selectOrtRuntimeWith(
  OnnxRuntime runtime,
  String path,
) async {
  final Map<String, dynamic>? map = await runtime.selectRuntime(path);
  if (map == null) return const OrtRuntimeSelection.unsupported();
  final Object? error = map['error'];
  return OrtRuntimeSelection(
    ok: map['ok'] == true,
    error: error is String && error.isNotEmpty ? error : null,
  );
}

/// 本进程用哪份 onnxruntime（不触发绑定）。
Future<OrtRuntimeInfo> ortRuntimeInfo() => ortRuntimeInfoWith(OnnxRuntime());

/// [ortRuntimeInfo] 的可注入 runtime 版本。
Future<OrtRuntimeInfo> ortRuntimeInfoWith(OnnxRuntime runtime) async {
  final Map<String, dynamic>? map = await runtime.getRuntimeInfo();
  if (map == null) return const OrtRuntimeInfo.unsupported();
  return OrtRuntimeInfo(
    loaded: map['loaded'] == true,
    version: '${map['version'] ?? ''}',
    selectedPath: '${map['selectedPath'] ?? ''}',
  );
}
