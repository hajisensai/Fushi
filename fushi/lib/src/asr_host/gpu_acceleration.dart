/// Windows GPU 推理环境的装配：自动检测显卡、偏好、启动时选 core、按需注册
/// CUDA。环境文件本身见 `gpu_runtime_pack.dart`。
///
/// 随包的只有最新 ORT CPU core。两条 GPU 路，**一个进程只能走一条**：
/// - CUDA：随包 core 不换，运行时注册官方 CUDA plugin EP（[activateGpuRuntime]，
///   懒触发——不用转录的人不加载约 1 GB 的 CUDA 库）；
/// - DirectML：换 core。必须在本进程任何 ORT 调用之前选中下载的 DirectML 版
///   onnxruntime.dll（[selectGpuRuntimeAtStartup]，`main()` 里调一次）。
///
/// 选哪条：偏好 [GpuRuntimePreference]（设备本地，`<数据根>/gpu_runtime/
/// preference.json`，**不进备份 / 同步**——它描述的是这台机器的显卡）。`auto`
/// 按 [detectGpuRuntime]：N 卡且驱动 / 计算能力达标走 CUDA，其它有硬件 D3D12
/// 适配器的走 DirectML，都不行留 CPU。环境在**下模型阶段**按
/// [gpuRuntimeToDownload] 一起下。
///
/// 进程里 ORT 已绑定随包 core 之后才装好 DirectML、或在 CUDA / DirectML 之间换
/// 偏好，都要重启 app 才生效（[GpuAccelerationStatus.restartRequired]）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:fushi_asr_core/asr_core.dart' as asr;
import 'package:path/path.dart' as p;

import 'package:fushi/src/asr_host/gpu_runtime_pack.dart';
import 'package:fushi/src/onnx/onnx_inference_ort.dart';
import 'package:fushi/src/storage/app_paths.dart';

/// 这条路只在 Windows 上有：随包 core 的替换 / CUDA 插件都是 Windows 机制。其它
/// 平台没有「GPU 环境」概念：macOS 走 CoreML / CPU，Android / iOS / Linux 走各自
/// 随包的 ORT，都不下载任何东西。（环境清单只有 win-x64 的 DLL——Windows 只发
/// x64；将来出 ARM64 原生包时要补 win-arm64 清单。）
bool get isGpuRuntimeSupported => Platform.isWindows;

/// CUDA 13 要求的最低驱动（`cuDriverGetVersion`，13000 = 13.0，R580 起）。
const int kCudaMinDriverVersion = 13000;

/// CUDA 13 支持的最低计算能力（Turing，sm_75）。
const int kCudaMinSmVersion = 75;

/// 这台机器的显卡 / 驱动能不能跑 CUDA 13。
bool isCudaEligible(CudaProbe probe) {
  final int? driver = probe.driverVersion;
  if (driver == null || driver < kCudaMinDriverVersion) return false;
  return probe.devices.any((CudaDevice d) => d.smVersion >= kCudaMinSmVersion);
}

/// 用户对 GPU 环境的选择。
enum GpuRuntimePreference {
  /// 按显卡自动挑（默认）。
  auto,
  cuda,
  directml,

  /// 不下也不用任何 GPU 环境。
  off,
}

/// 显卡检测结果（只问驱动 / DXGI，不绑定 ORT）。
class GpuDetection {
  const GpuDetection({required this.cuda, required this.hasHardwareAdapter});

  final CudaProbe cuda;

  /// DXGI 默认适配器是硬件（不是 WARP / Basic Render）。
  final bool hasHardwareAdapter;

  bool get cudaEligible => isCudaEligible(cuda);
}

/// 自动档挑哪种环境；null = 留 CPU。
GpuRuntimeKind? detectGpuRuntime(GpuDetection detection) {
  if (detection.cudaEligible) return GpuRuntimeKind.cuda;
  if (detection.hasHardwareAdapter) return GpuRuntimeKind.directml;
  return null;
}

/// 偏好 + 检测 → 该用（该下）哪种环境；null = 不用。显式选了 CUDA 但显卡不达标
/// 时也是 null（不下一个跑不起来的 1 GB 包）。
GpuRuntimeKind? resolveGpuRuntime(
  GpuRuntimePreference preference,
  GpuDetection detection,
) => switch (preference) {
  GpuRuntimePreference.auto => detectGpuRuntime(detection),
  GpuRuntimePreference.cuda =>
    detection.cudaEligible ? GpuRuntimeKind.cuda : null,
  GpuRuntimePreference.directml =>
    detection.hasHardwareAdapter ? GpuRuntimeKind.directml : null,
  GpuRuntimePreference.off => null,
};

/// 本进程启动时实际该用的环境（只在已装好的里挑）；null = CPU。
///
/// 目标环境（[resolveGpuRuntime]）装好了就用它。自动档下目标没装、但 DirectML
/// 装了，先用 DirectML：N 卡老用户自动补的是 15 MB 的 DirectML（见
/// [backfillGpuRuntimeForExistingModels]），约 0.9 GB 的 CUDA 要用户自己点。
GpuRuntimeKind? effectiveGpuRuntime(
  GpuRuntimePreference preference,
  GpuDetection detection,
  Set<GpuRuntimeKind> installed,
) {
  final GpuRuntimeKind? target = resolveGpuRuntime(preference, detection);
  if (target != null && installed.contains(target)) return target;
  if (preference == GpuRuntimePreference.auto &&
      detection.hasHardwareAdapter &&
      installed.contains(GpuRuntimeKind.directml)) {
    return GpuRuntimeKind.directml;
  }
  return null;
}

/// 已装好的环境。
Future<Set<GpuRuntimeKind>> installedGpuRuntimes() async => <GpuRuntimeKind>{
  for (final GpuRuntimeKind k in GpuRuntimeKind.values)
    if ((await gpuRuntimeStore(k)).isReady) k,
};

Future<GpuRuntimeKind?> _effective() async => effectiveGpuRuntime(
  await readGpuRuntimePreference(),
  await detectGpu(),
  await installedGpuRuntimes(),
);

/// `<数据根>/gpu_runtime`。
Future<Directory> _gpuRuntimeRoot() async {
  final Directory support = await AppPaths.supportRootDirectory();
  return Directory(p.join(support.path, 'gpu_runtime'));
}

/// 某种环境的磁盘安装。
Future<GpuRuntimeStore> gpuRuntimeStore(GpuRuntimeKind kind) async =>
    GpuRuntimeStore(await _gpuRuntimeRoot(), gpuRuntimeEnvironmentOf(kind));

/// 读偏好；文件缺失 / 损坏按 [GpuRuntimePreference.auto]。
Future<GpuRuntimePreference> readGpuRuntimePreference() async {
  try {
    final File f = File(p.join((await _gpuRuntimeRoot()).path, _kPrefFile));
    if (!await f.exists()) return GpuRuntimePreference.auto;
    final Object? json = jsonDecode(await f.readAsString());
    final Object? name = json is Map ? json['preference'] : null;
    return GpuRuntimePreference.values.firstWhere(
      (GpuRuntimePreference v) => v.name == name,
      orElse: () => GpuRuntimePreference.auto,
    );
  } on Object catch (error) {
    debugPrint('[Fushi] GPU runtime preference unreadable: $error');
    return GpuRuntimePreference.auto;
  }
}

/// 写偏好（下次启动生效；CUDA 若本进程还没注册，下次用到时就按新偏好走）。
Future<void> writeGpuRuntimePreference(GpuRuntimePreference preference) async {
  final Directory root = await _gpuRuntimeRoot();
  await root.create(recursive: true);
  await File(
    p.join(root.path, _kPrefFile),
  ).writeAsString(jsonEncode(<String, String>{'preference': preference.name}));
}

const String _kPrefFile = 'preference.json';

GpuDetection? _detection;

/// 检测显卡（每进程一次；驱动 / DXGI 查询失败按「没有」处理并记日志）。
Future<GpuDetection> detectGpu({OnnxRuntime? runtime}) async {
  final GpuDetection? cached = _detection;
  if (cached != null) return cached;
  final OnnxRuntime rt = runtime ?? OnnxRuntime();
  CudaProbe cuda;
  try {
    cuda = await probeCudaWith(rt);
  } on Object catch (error) {
    cuda = CudaProbe(
      driverVersion: null,
      devices: const <CudaDevice>[],
      error: '$error',
    );
  }
  bool hardware = false;
  try {
    final OrtDeviceMemoryInfo? info = await rt.getDeviceMemoryInfo();
    hardware = info != null && !info.isSoftware;
  } on Object catch (error) {
    debugPrint('[Fushi] DXGI adapter query failed: $error');
  }
  final GpuDetection detection = GpuDetection(
    cuda: cuda,
    hasHardwareAdapter: hardware,
  );
  debugPrint(
    '[Fushi] GPU detection: cuda=$cuda hardwareAdapter=$hardware '
    '-> ${detectGpuRuntime(detection)?.name ?? 'cpu'}',
  );
  return _detection = detection;
}

/// 下模型阶段该一起下的环境；null = 不需要（非 Windows / 偏好关 / 显卡不行 /
/// 已装好 / 正在别处下载）。
Future<GpuRuntimeStore?> gpuRuntimeToDownload() async {
  if (!isGpuRuntimeSupported) return null;
  final GpuRuntimeKind? kind = resolveGpuRuntime(
    await readGpuRuntimePreference(),
    await detectGpu(),
  );
  if (kind == null || _installing.contains(kind)) return null;
  final GpuRuntimeStore store = await gpuRuntimeStore(kind);
  return store.isReady ? null : store;
}

/// UI 用的 [gpuRuntimeToDownload]：按 `defaultTargetPlatform` 门控（widget 测试
/// 跑在 Windows 宿主上也不会去碰插件 / 数据根），查询失败按「不需要」——GPU
/// 环境只是加速，不能拦住模型下载。
Future<GpuRuntimeStore?> gpuRuntimeToDownloadForUi() async {
  if (defaultTargetPlatform != TargetPlatform.windows ||
      !isGpuRuntimeSupported) {
    return null;
  }
  try {
    return await gpuRuntimeToDownload();
  } on Object catch (error) {
    debugPrint('[Fushi] GPU runtime download check failed: $error');
    return null;
  }
}

/// 转录弹层用：模型已就绪、但这台机器该用的 GPU 环境还没装时给的提示。
class GpuRuntimeOffer {
  const GpuRuntimeOffer({required this.store, required this.effective});

  /// 建议下载的环境。
  final GpuRuntimeStore store;

  /// 不下载的话本进程会用的环境；null = CPU。
  final GpuRuntimeKind? effective;
}

/// 有没有该补的 GPU 环境（[gpuRuntimeToDownload]），连同不补时的现状。
Future<GpuRuntimeOffer?> gpuRuntimeOffer() async {
  final GpuRuntimeStore? store = await gpuRuntimeToDownload();
  if (store == null) return null;
  return GpuRuntimeOffer(store: store, effective: await _effective());
}

final Set<GpuRuntimeKind> _installing = <GpuRuntimeKind>{};

/// 装一种环境（进程内同一种只允许一个安装在跑——老用户的后台补下、转录弹层、
/// 设置页可能同时触发，两个写者会写坏同一个 `.deflate.part`）。装完调
/// [onGpuRuntimeInstalled]。同种已在装时抛 [StateError]。
///
/// 安装失败只以错误事件结束，**不**调 [onGpuRuntimeInstalled]：`yield*` 把内层
/// 错误当事件转发、生成器照常往下走，不记下失败的话，不在第一个错误就取消订阅
/// 的消费方（[withGpuRuntimeDownload]）会让一次失败的安装也去激活环境。
Stream<GpuRuntimeInstallProgress> installGpuRuntime(
  GpuRuntimeStore store,
) async* {
  final GpuRuntimeKind kind = store.environment.kind;
  if (!_installing.add(kind)) {
    throw StateError('${kind.name} runtime is already being downloaded');
  }
  bool failed = false;
  try {
    yield* store.install().handleError((Object error, StackTrace stack) {
      failed = true;
      Error.throwWithStackTrace(error, stack);
    });
  } finally {
    _installing.remove(kind);
  }
  if (failed) return;
  await onGpuRuntimeInstalled(kind);
}

/// 下模型阶段：[model] 下完后，接着装 [gpu]（[gpuRuntimeToDownload] 的结果，
/// null 则什么都不加），合成一条逐文件事件流交给现有的模型下载 UI。
///
/// GPU 环境失败**不算**模型下载失败——模型已经就绪、CPU 照样能转录；原因交给
/// [onGpuRuntimeError]（UI 提示一下即可，设置页可重试）。模型下载失败则照样以
/// 错误事件结束、不再去装 GPU 环境。取消订阅即取消，已收的部分下次续传。
///
/// 两段都用 `yield*` 而不是 `await for`：async* 在 `await for` 两个事件之间挂起时，
/// 取消要等到下一个事件才生效——下载卡住（或测试里一直不来事件）时，取消就一直
/// 挂着；`yield*` 会把取消立刻转给正在跑的那条流。
Stream<asr.ModelDownloadEvent> withGpuRuntimeDownload(
  Stream<asr.ModelDownloadEvent> model,
  GpuRuntimeStore? gpu, {
  void Function(Object error)? onGpuRuntimeError,
}) async* {
  if (gpu == null) {
    yield* model;
    return;
  }
  bool modelFailed = false;
  yield* model.where((asr.ModelDownloadEvent e) => !e.done).handleError((
    Object error,
    StackTrace stack,
  ) {
    modelFailed = true;
    Error.throwWithStackTrace(error, stack);
  });
  if (modelFailed) return;
  yield* installGpuRuntime(gpu)
      .where(
        (GpuRuntimeInstallProgress p) => p.phase != GpuRuntimeInstallPhase.done,
      )
      .map(
        (GpuRuntimeInstallProgress p) => asr.ModelDownloadEvent(
          fileName: p.fileName ?? '',
          receivedBytes: p.memberReceived,
          totalBytes: p.memberTotal,
        ),
      )
      .handleError((Object error) {
        debugPrint('[Fushi] GPU runtime install failed: $error');
        onGpuRuntimeError?.call(error);
      });
  yield const asr.ModelDownloadEvent(
    fileName: '',
    receivedBytes: 0,
    totalBytes: 0,
    done: true,
  );
}

/// 老用户补齐：已经下过语音模型的人不会再经过「下模型阶段」，而他们以前靠随包
/// 的 DirectML 跑 GPU——不补就会悄悄掉到 CPU。[hasDownloadedModel] 答真、偏好
/// 没关、有硬件显卡、且本机还没有任何能用的 GPU 环境时，后台补下 DirectML
/// （15 MB，等于把以前随包的那份还回去，不打扰用户）。显式选了 CUDA 的不补：
/// 约 0.9 GB 的下载要用户在转录弹层 / 设置里自己点。
///
/// 下完时本进程若还没碰过 ORT 就当场换 core；否则下次启动生效。失败只记日志
/// （设置页可重试）。
Future<void> backfillGpuRuntimeForExistingModels({
  required Future<bool> Function() hasDownloadedModel,
}) async {
  if (!isGpuRuntimeSupported) return;
  try {
    if (!await hasDownloadedModel()) return;
    final GpuRuntimePreference preference = await readGpuRuntimePreference();
    if (preference == GpuRuntimePreference.off ||
        preference == GpuRuntimePreference.cuda) {
      return;
    }
    final GpuDetection detection = await detectGpu();
    if (!detection.hasHardwareAdapter) return;
    if (await _effective() != null) return;
    final GpuRuntimeStore store = await gpuRuntimeStore(
      GpuRuntimeKind.directml,
    );
    if (store.isReady) return;
    debugPrint('[Fushi] backfilling DirectML runtime for an existing model');
    await installGpuRuntime(store).drain<void>();
  } on Object catch (error) {
    debugPrint('[Fushi] DirectML runtime backfill failed: $error');
  }
}

/// `main()` 里、任何 ORT 调用之前调一次：该用 DirectML（[effectiveGpuRuntime]）
/// 时让本进程用下载的 DirectML core。失败（文件被删、加载不了）安静地留在随包
/// core，原因进日志与 [GpuAccelerationStatus]。
Future<void> selectGpuRuntimeAtStartup() async {
  if (!isGpuRuntimeSupported) return;
  try {
    if (await _effective() != GpuRuntimeKind.directml) return;
    await _selectDirectMl();
  } on Object catch (error) {
    debugPrint('[Fushi] DirectML core selection failed: $error');
    _selectError = '$error';
  }
}

String? _selectError;

/// 选中已装好的 DirectML core。ORT 尚未绑定时立即生效（刚下完也一样）；已绑定
/// 随包 core 则返回失败，需重启。
Future<OrtRuntimeSelection?> _selectDirectMl() async {
  final GpuRuntimeStore store = await gpuRuntimeStore(GpuRuntimeKind.directml);
  if (!store.isReady) return null;
  final OrtRuntimeSelection selection = await selectOrtRuntime(
    store.ortCorePath,
  );
  debugPrint('[Fushi] DirectML core selection: $selection');
  _selectError = selection.ok ? null : selection.error;
  return selection;
}

/// 环境刚装好时调：该用 DirectML 且能立即生效就选上（本进程还没碰过 ORT）；
/// CUDA 清掉「没装」的缓存结论，下次用到时注册。
Future<void> onGpuRuntimeInstalled(GpuRuntimeKind kind) async {
  _activation = null;
  if (kind == GpuRuntimeKind.directml &&
      await _effective() == GpuRuntimeKind.directml) {
    final OrtRuntimeInfo info = await ortRuntimeInfo();
    if (!info.loaded) await _selectDirectMl();
  }
}

Future<CudaRegistration?>? _activation;

/// 在探测 EP / 建会话之前调（每进程一次）：偏好落在 CUDA、环境就绪、本进程用的
/// 是随包 core 时，注册 CUDA 插件 EP。返回 null = 没走到注册。CUDA 环境没装时
/// 不缓存结论：下载完成后再调就会注册。注册成功 ≠ 能跑：cuDNN 不对时第一次 Run
/// 才失败，那道兜底在引擎装载的健康检查里（`AsrEngineLoader.load`）。
Future<CudaRegistration?> activateGpuRuntime() => _activation ??= _activate();

Future<CudaRegistration?> _activate() async {
  if (!isGpuRuntimeSupported) return null;
  try {
    if (await _effective() != GpuRuntimeKind.cuda) {
      // 没装 CUDA 时不缓存结论：下载完成后再调就会注册。
      _activation = null;
      return null;
    }
    final GpuRuntimeStore store = await gpuRuntimeStore(GpuRuntimeKind.cuda);
    final OrtRuntimeInfo info = await ortRuntimeInfo();
    if (info.selectedPath.isNotEmpty) {
      // 本进程用的是 DirectML core：CUDA 插件要与随包 core 同一 revision。
      return null;
    }
    final CudaRegistration registration = await registerCudaRuntime(
      store.dir.path,
    );
    debugPrint('[Fushi] CUDA runtime registration: $registration');
    return registration;
  } on Object catch (error) {
    // 注册失败不能拦住转录——留在 CPU。原因进日志，设置页从
    // [gpuAccelerationStatus] 读到的是「未生效」。
    debugPrint('[Fushi] CUDA runtime registration failed: $error');
    _activation = null;
    return CudaRegistration(ok: false, deviceCount: 0, error: '$error');
  }
}

/// 本进程 GPU 环境的当前状态（设置页展示用）。
class GpuAccelerationStatus {
  const GpuAccelerationStatus({
    required this.supportedPlatform,
    required this.preference,
    this.detection,
    this.target,
    this.effective,
    this.installed = const <GpuRuntimeKind>{},
    this.active,
    this.error,
  });

  /// 只有 Windows 有这条路。
  final bool supportedPlatform;
  final GpuRuntimePreference preference;
  final GpuDetection? detection;

  /// 偏好 + 检测落到的环境；null = 留 CPU。
  final GpuRuntimeKind? target;

  /// 已装好的环境里本该生效的那个（[effectiveGpuRuntime]）。
  final GpuRuntimeKind? effective;

  /// 已装好的环境。
  final Set<GpuRuntimeKind> installed;

  /// 本进程实际生效的环境；null = CPU。
  final GpuRuntimeKind? active;

  /// 最近一次选 core / 注册失败的原因。
  final String? error;

  bool get targetInstalled => target != null && installed.contains(target);

  /// 该生效的环境已装好却没生效（ORT 已绑定了别的 core）——重启 app 才会切过去。
  bool get restartRequired =>
      effective != null && active != effective && error == null;
}

/// 设置页用：问一遍状态（会顺手触发 CUDA 注册）。
Future<GpuAccelerationStatus> gpuAccelerationStatus() async {
  final GpuRuntimePreference preference = await readGpuRuntimePreference();
  if (!isGpuRuntimeSupported) {
    return GpuAccelerationStatus(
      supportedPlatform: false,
      preference: preference,
    );
  }
  final GpuDetection detection = await detectGpu();
  final GpuRuntimeKind? target = resolveGpuRuntime(preference, detection);
  final Set<GpuRuntimeKind> installed = await installedGpuRuntimes();
  final CudaRegistration? registration = await activateGpuRuntime();
  final OrtRuntimeInfo info = await ortRuntimeInfo();
  final GpuRuntimeKind? active = info.selectedPath.isNotEmpty
      ? GpuRuntimeKind.directml
      : (registration?.ok ?? false)
      ? GpuRuntimeKind.cuda
      : null;
  return GpuAccelerationStatus(
    supportedPlatform: true,
    preference: preference,
    detection: detection,
    target: target,
    effective: effectiveGpuRuntime(preference, detection, installed),
    installed: installed,
    active: active,
    error: registration?.ok == false ? registration?.error : _selectError,
  );
}

/// 在探测 EP / 建会话之前确保 GPU 环境已激活的工厂装饰。只给根 isolate 用：
/// 注册是进程级的，后台 isolate 共享同一个插件实例。
class GpuAwareOnnxSessionFactory implements asr.OnnxSessionFactory {
  GpuAwareOnnxSessionFactory(this._inner);

  final asr.OnnxSessionFactory _inner;

  @override
  Future<Set<asr.OnnxExecutionProvider>> availableAcceleratedProviders() async {
    await activateGpuRuntime();
    return _inner.availableAcceleratedProviders();
  }

  @override
  Future<asr.OnnxSession> createSession(
    String modelPath, {
    required List<asr.OnnxExecutionProvider> providers,
    void Function(asr.OnnxProviderResolution resolution)? onProviderResolved,
    int? intraOpNumThreads,
    Map<String, int>? freeDimensionOverrides,
  }) async {
    if (providers.contains(asr.OnnxExecutionProvider.cuda)) {
      await activateGpuRuntime();
    }
    return _inner.createSession(
      modelPath,
      providers: providers,
      onProviderResolved: onProviderResolved,
      intraOpNumThreads: intraOpNumThreads,
      freeDimensionOverrides: freeDimensionOverrides,
    );
  }

  @override
  Future<int?> deviceMemoryBudgetBytes() => _inner.deviceMemoryBudgetBytes();
}
