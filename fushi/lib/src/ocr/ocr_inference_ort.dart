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

import 'package:fushi/src/ocr/ocr_inference.dart';

/// 本子系统统一的 `dart:developer` 日志通道名。
///
/// 用 `dart:developer` 而不是 `debugPrint`：整卷 OCR 跑在 `Isolate.spawn` 出来
/// 的后台 isolate 里，那里没有 Flutter binding，`debugPrint` 的节流实现依赖
/// binding 的 Timer 调度；`developer.log` 在任何 isolate 都可直接用。
const String kOcrLogName = 'hibiki.ocr';

/// 本平台是否内置 ONNX Runtime native 库（本地 OCR 推理是否可用）。
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
/// #1000 起复用同一条引擎链，不再有独立的单框 OCR 服务）无须改动。
bool get isLocalOnnxRuntimeAvailable =>
    Platform.isWindows ||
    Platform.isLinux ||
    Platform.isAndroid ||
    Platform.isMacOS ||
    Platform.isIOS;

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

/// `getAvailableProviders()` 回报名 -> 本子系统的加速 EP。
///
/// 只列**加速** EP：CPU 永远可用、永远是最后一档，不需要也不应该参与探测。
/// 运行时回报的其他 EP（TensorRT、XNNPACK…）本子系统不选，落 null 被滤掉。
const Map<OrtProvider, OcrExecutionProvider> _acceleratedProviders =
    <OrtProvider, OcrExecutionProvider>{
  OrtProvider.CUDA: OcrExecutionProvider.cuda,
  OrtProvider.DIRECT_ML: OcrExecutionProvider.directml,
  OrtProvider.CORE_ML: OcrExecutionProvider.coreml,
};

/// 用配置的加速 EP 创建会话；建不起来时按 [providers] 里的 CPU 后备重试一次。
///
/// **判据是「首选的是不是加速 provider」，不是错误码**（BUG-2050）。错误码曾经
/// 能当代理：那时插件的 Windows MethodChannel 只实现 CPU/CUDA 映射，传
/// `DIRECT_ML` 会在碰到 ORT 之前就整张列表拒掉，必然是 `INVALID_PROVIDER`。
/// BUG-1968 把真 DML EP 接进来之后这个前提没了——失败改从 ORT 内部出来，码变成
/// `PROVIDER_ERROR`（append EP 阶段，含建不出 D3D12 设备）/ `ORT_ERROR`
/// （`Ort::Session` 构造阶段）/ `SESSION_CREATION_ERROR`，白名单一条都不命中，
/// 于是整卷 OCR 直接报错而不是退 CPU。维护「哪些码算 provider 问题」这张清单
/// 本身就是错的：native 侧每改一次错误映射它就会悄悄过期一次。
///
/// 「那模型损坏会被掩盖吗？」不会，也不需要特判：模型真坏，CPU 那次同样建不
/// 起来，异常照抛，而且抛的是 CPU 那条（「连 CPU 都读不了这个模型」比
/// 「DML 读不了」更有诊断价值）。代价只是对一个已经注定失败的模型多试一次。
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
    // 判据只有两条，都不看错误码：这次请求的首选是不是加速 provider，以及
    // 列表里有没有 CPU 兜底。`preferred != cpu` 已经蕴含 `providers.length > 1`
    // （CPU 在列表里且不是首项），不需要再单独判长度。
    final bool triedAcceleratedProvider = preferred != OcrExecutionProvider.cpu;
    final bool hasCpuFallback = providers.contains(OcrExecutionProvider.cpu);
    if (!triedAcceleratedProvider || !hasCpuFallback) rethrow;
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

  /// 探测本机 ORT 运行时**编译进来**的加速 EP 集合，喂给
  /// [selectOcrExecutionProviders]。
  ///
  /// BUG-2050 的根因修复点：原先这里只问 CUDA，DirectML 的可用性靠平台分支硬
  /// 假设。但 `getAvailableProviders()` 本来就一次性回报全部 EP（native 侧
  /// `flutter_onnxruntime_plugin.cpp` 明确把 `DmlExecutionProvider` 映射成
  /// `DIRECT_ML`），问一个和问全部同价——不问才是 bug。
  ///
  /// **语义边界**：这里回报的是「该 EP 编译进了当前 onnxruntime 运行时」，
  /// **不是**「它此刻真能建出会话」（DirectML 还要能建出 D3D12 设备，CUDA 还要
  /// 有驱动和可用显卡）。必要不充分，别拿它当运行期可用性的结论。
  ///
  /// 探测本身失败是一条真实的降级路径（有 N 卡也会退到 CPU），不允许调用方
  /// `catch (_)` 静默吞掉——所以这里不吞异常，由调用方捕获后记进可观测的降级
  /// 说明（BUG-1163）。
  Future<Set<OcrExecutionProvider>> availableAcceleratedProviders() async {
    final List<OrtProvider> providers = await _runtime.getAvailableProviders();
    return providers
        .map((OrtProvider provider) => _acceleratedProviders[provider])
        .whereType<OcrExecutionProvider>()
        .toSet();
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
