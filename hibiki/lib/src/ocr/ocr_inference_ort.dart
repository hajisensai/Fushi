/// [OcrSession] 的真实实现：`flutter_onnxruntime` 薄封装。
///
/// 只做三件事：EP 枚举映射、OcrTensor <-> OrtValue 转换、资源释放。
/// 算法层不 import 本文件（依赖 `ocr_inference.dart` 的抽象）。
library;

import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:flutter/services.dart';

import 'package:hibiki/src/ocr/ocr_inference.dart';

/// 本子系统统一的 `dart:developer` 日志通道名。
///
/// 用 `dart:developer` 而不是 `debugPrint`：整卷 OCR 跑在 `Isolate.spawn` 出来
/// 的后台 isolate 里，那里没有 Flutter binding，`debugPrint` 的节流实现依赖
/// binding 的 Timer 调度；`developer.log` 在任何 isolate 都可直接用。
const String kOcrLogName = 'hibiki.ocr';

/// 本平台是否内置 ONNX Runtime native 库（本地 OCR 推理是否可用）。
///
/// `flutter_onnxruntime` 已在 vendored fork 中 gate 出 Apple（macOS/iOS，见
/// `third_party/flutter_onnxruntime/PATCHES.md`）：Apple 上该插件的 MethodChannel
/// 无 native 实现，任何本地 OCR 会话构造都会抛 MissingPluginException。其余三端
/// （Windows / Linux / Android）native 正常注册，本地 OCR 照常工作。
///
/// 所有本地整卷 OCR 入口（`MangaOcrServiceImpl`）都必须先过此闸门，
/// Apple 上改走互联 host；需要整页云端识别时由用户显式选择 Google Lens。
bool get isLocalOnnxRuntimeAvailable => !(Platform.isMacOS || Platform.isIOS);

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

/// 用配置的加速 EP 创建会话；vendored `flutter_onnxruntime` 拒绝尚未实现的
/// provider 时，按 [providers] 中已有的 CPU 后备重试一次。
///
/// Windows 的 ONNX Runtime 会报告 `DmlExecutionProvider`，但当前插件的 Windows
/// MethodChannel 只实现 CPU/CUDA 映射，传 `DIRECT_ML` 会在真正创建 ORT session
/// 之前抛 `PlatformException(INVALID_PROVIDER, ...)`。调用层已经把 CPU 放在 EP
/// 列表尾部，因此这里把插件边界的“拒绝整个列表”还原成 ORT 预期的逐级后备语义。
/// 只捕获明确的 `INVALID_PROVIDER`；模型损坏、shape 错误和推理异常仍原样上抛。
///
/// [onResolved] 在会话建成后**必定**被调用一次，回报本次真正生效的 provider
/// 与降级原因（BUG-1163）：降级不允许静默发生，调用层据此写日志并把状态送到
/// UI。回调本身抛出的异常不影响会话创建结果，只落日志。
Future<T> createOcrSessionWithProviderFallback<T>({
  required List<OcrExecutionProvider> providers,
  required Future<T> Function(List<OcrExecutionProvider> providers) create,
  void Function(OcrProviderResolution resolution)? onResolved,
}) async {
  final OcrExecutionProvider preferred =
      providers.isEmpty ? OcrExecutionProvider.cpu : providers.first;
  try {
    final T session = await create(providers);
    _notifyResolved(
      onResolved,
      OcrProviderResolution(requested: providers, effective: preferred),
    );
    return session;
  } on PlatformException catch (error) {
    final bool canFallbackToCpu = error.code == 'INVALID_PROVIDER' &&
        providers.length > 1 &&
        providers.contains(OcrExecutionProvider.cpu);
    if (!canFallbackToCpu) rethrow;
    final T session =
        await create(const <OcrExecutionProvider>[OcrExecutionProvider.cpu]);
    _notifyResolved(
      onResolved,
      OcrProviderResolution(
        requested: providers,
        effective: OcrExecutionProvider.cpu,
        fallbackReason:
            '${error.code}: ${error.message ?? 'provider rejected by plugin'}',
      ),
    );
    return session;
  }
}

void _notifyResolved(
  void Function(OcrProviderResolution resolution)? onResolved,
  OcrProviderResolution resolution,
) {
  if (resolution.didFallBack) {
    developer.log(
      'OCR execution provider fell back: $resolution',
      name: kOcrLogName,
    );
  } else {
    developer.log(
      'OCR execution provider resolved: $resolution',
      name: kOcrLogName,
    );
  }
  if (onResolved == null) return;
  try {
    onResolved(resolution);
  } catch (error, stack) {
    developer.log(
      'OCR provider resolution callback threw',
      name: kOcrLogName,
      error: error,
      stackTrace: stack,
    );
  }
}

/// 把算法层的语义输入名对齐到当前 ONNX 文件声明的真实输入名。
///
/// Manga OCR 下载源的检测器/编码器都只有一个输入，但不同导出版本分别使用过
/// `pixel_values`、`images` 等名字。单输入模型不存在位置歧义，因此以 session
/// 元数据为准；多输入 decoder 仍要求名称精确匹配，避免按顺序猜测而接错张量。
///
/// 单输入分支必须放在按名匹配**之前**：放在后面时，循环里任一未命中就已经
/// `return inputs` 退出，循环走完又保证 `resolved` 非空，元数据回退永远不可达
/// ——doc 宣称的鲁棒性并不存在（BUG-1173 同批审查发现）。
Map<String, OcrTensor> resolveOcrSessionInputs({
  required Map<String, OcrTensor> inputs,
  required List<String> sessionInputNames,
}) {
  if (inputs.length == 1 && sessionInputNames.length == 1) {
    return <String, OcrTensor>{
      sessionInputNames.single: inputs.values.single,
    };
  }
  final Map<String, OcrTensor> resolved = <String, OcrTensor>{};
  for (final String sessionName in sessionInputNames) {
    final OcrTensor? exact = inputs[sessionName];
    if (exact != null) {
      resolved[sessionName] = exact;
      continue;
    }
    if (sessionName == 'images' && inputs['pixel_values'] != null) {
      resolved[sessionName] = inputs['pixel_values']!;
      continue;
    }
    return inputs;
  }
  if (resolved.isNotEmpty) {
    return resolved;
  }
  return inputs;
}

/// flutter_onnxruntime 会话工厂。
class OrtOcrSessionFactory implements OcrSessionFactory {
  OrtOcrSessionFactory({OnnxRuntime? runtime})
      : _runtime = runtime ?? OnnxRuntime();

  final OnnxRuntime _runtime;

  /// 探测本机可用 EP（用于决定 `cudaAvailable` 再喂给
  /// [selectOcrExecutionProviders]）。
  ///
  /// 探测本身失败是一条真实的降级路径（有 N 卡也会退到 DirectML/CPU），
  /// 不允许调用方 `catch (_)` 静默吞掉——所以这里不吞异常，由调用方捕获后
  /// 记进可观测的降级说明（BUG-1163）。
  Future<bool> isCudaAvailable() async {
    final List<OrtProvider> providers = await _runtime.getAvailableProviders();
    return providers.contains(OrtProvider.CUDA);
  }

  @override
  Future<OcrSession> createSession(
    String modelPath, {
    required List<OcrExecutionProvider> providers,
    void Function(OcrProviderResolution resolution)? onProviderResolved,
  }) async {
    final OrtSession session =
        await createOcrSessionWithProviderFallback<OrtSession>(
      providers: providers,
      onResolved: onProviderResolved,
      create: (List<OcrExecutionProvider> effectiveProviders) =>
          _runtime.createSession(
        modelPath,
        options: OrtSessionOptions(
          providers: effectiveProviders.map(_toOrtProvider).toList(),
        ),
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
      final Map<String, OcrTensor> resolvedInputs = resolveOcrSessionInputs(
        inputs: inputs,
        sessionInputNames: _session.inputNames,
      );
      for (final MapEntry<String, OcrTensor> entry in resolvedInputs.entries) {
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
