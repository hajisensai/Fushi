/// 服务端的 OCR 会话工厂：`asr_onnx_ffi` 的 FFI ONNX Runtime + OCR 输入名对齐。
///
/// app 那边 `OrtOcrSessionFactory` 把 `resolveOcrSessionInputs` 塞给插件后端的
/// `resolveInputs` 钩子；FFI 后端没有这个钩子，所以这里用一层会话装饰器在 `run`
/// 前做同样的名字对齐（manga-ocr 的 encoder 输入名是 `pixel_values`，检测器是
/// `images`，识别/检测代码统一按逻辑名喂，见 `resolveOcrSessionInputs` 注释）。
///
/// 顶层函数 [buildServerOcrSessionFactory] 装进引擎 `ocrSessionFactoryBuilder`
/// （只有顶层函数能穿过 `Isolate.spawn`）。ORT 库路径覆盖经 [serverOrtLibraryPath]
/// 顶层变量传给 isolate——它在 spawn 前由主 isolate 赋值，isolate 启动时读到的是
/// 同一份静态初始值？不是：isolate 不共享顶层变量。所以覆盖路径走环境变量
/// `FUSHI_ORT_LIBRARY`（`OrtRuntime` 自己也认它），CLI 启动时把配置里的路径写进
/// `Platform.environment` 做不到（只读），改为在 spawn 参数里带——引擎的
/// `_JobIsolateArgs` 只带工厂构建函数，所以这里用 `bootstrapArg` 传路径，
/// `serverOcrIsolateBootstrap` 收到后写入本 isolate 的 [serverOrtLibraryPath]。
library;

import 'package:fushi_asr_onnx_ffi/asr_onnx_ffi.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';

/// 本 isolate 内的 ORT 库覆盖路径（由 [serverOcrIsolateBootstrap] 写入）。
String? serverOrtLibraryPath;

/// isolate 引导：把主 isolate 传来的 ORT 库路径落到本 isolate。
void serverOcrIsolateBootstrap(Object? arg) {
  if (arg is String && arg.isNotEmpty) serverOrtLibraryPath = arg;
}

OcrSessionFactory buildServerOcrSessionFactory() =>
    OcrInputResolvingSessionFactory(
      FfiOnnxSessionFactory(
        logName: kOcrLogName,
        libraryPathOverride: serverOrtLibraryPath,
      ),
    );

/// 把任意 [OnnxSessionFactory] 产出的会话包一层输入名对齐。
class OcrInputResolvingSessionFactory implements OcrSessionFactory {
  const OcrInputResolvingSessionFactory(this._inner);

  final OnnxSessionFactory _inner;

  @override
  Future<OnnxSession> createSession(
    String modelPath, {
    required List<OnnxExecutionProvider> providers,
    void Function(OnnxProviderResolution resolution)? onProviderResolved,
    int? intraOpNumThreads,
    Map<String, int>? freeDimensionOverrides,
  }) async {
    final OnnxSession session = await _inner.createSession(
      modelPath,
      providers: providers,
      onProviderResolved: onProviderResolved,
      intraOpNumThreads: intraOpNumThreads,
      freeDimensionOverrides: freeDimensionOverrides,
    );
    return _InputResolvingSession(session);
  }

  @override
  Future<Set<OnnxExecutionProvider>> availableAcceleratedProviders() =>
      _inner.availableAcceleratedProviders();

  @override
  Future<int?> deviceMemoryBudgetBytes() => _inner.deviceMemoryBudgetBytes();
}

class _InputResolvingSession implements OnnxSession {
  _InputResolvingSession(this._inner);

  final OnnxSession _inner;

  List<String> get _inputNames {
    final OnnxSession s = _inner;
    if (s is FfiOnnxSession) return s.inputNames;
    return const <String>[];
  }

  @override
  Future<Map<String, OnnxTensor>> run(Map<String, OnnxTensor> inputs) {
    final List<String> names = _inputNames;
    if (names.isEmpty) return _inner.run(inputs);
    return _inner.run(
      resolveOcrSessionInputs(inputs: inputs, sessionInputNames: names),
    );
  }

  @override
  Future<void> close() => _inner.close();
}
