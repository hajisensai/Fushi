import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fushi_asr_core/asr_core.dart';

import 'package:fushi/src/asr_host/asr_host.dart'
    show createAsrTranscriptionService, openAsrModelStoreForPack;
import 'package:fushi/src/asr_host/gpu_acceleration.dart'
    show gpuRuntimeToDownloadForUi, withGpuRuntimeDownload;
import 'package:fushi/src/asr_host/gpu_runtime_pack.dart' show GpuRuntimeStore;
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 一个语音转录模型包当前的下载进度快照。
@immutable
class AsrModelDownloadProgress {
  const AsrModelDownloadProgress({
    required this.receivedBytes,
    required this.totalBytes,
    required this.currentFile,
    required this.cancelling,
  });

  /// 整包已收字节：之前文件的总量 + 当前文件已收（下载器事件逐文件 0→100%）。
  final int receivedBytes;

  /// 该变体全套文件的预期总字节数。
  final int totalBytes;

  /// 最近一条事件的文件名；还没收到事件时为空串。
  final String currentFile;

  /// 已请求取消、正在等待下载器收尾。
  final bool cancelling;
}

/// 语音转录模型的**后台下载**登记表（全应用单例 [asrModelDownloads]）。
///
/// 与漫画 OCR 的 `MangaOcrModelDownloads` 同一套设计：下载订阅的所有权不在页面
/// 上——以前挂在设置区 widget 的 State 上，离开页面即取消，几百 MB 白下；而且
/// `fushi_cli models download asr` 发起的下载设置页看不到、设置页发起的 CLI 也
/// 看不到。现在设置页与控制通道读写同一份登记：进度、取消、最近一次失败原因
/// 两边互相可见。按包 id 分槽，同一个包重复发起直接忽略。
///
/// 这里也是「设置 › 模型」唯一的下载路径，设置页与 CLI 的语义因此一致：
/// - **按包**：状态 / 下载 / 删除只认这一个包的目录（[openPackStore]）。同一语言
///   可能有好几行（默认包、视频专用的 Parakeet、可选的 Kitsune、自带包），按语言
///   走服务拿到的永远是那种素材当前选中的那个包——别的行会照抄它的状态，下载 /
///   删除也落到它身上。
/// - **按素材问推荐**：只服务某一种素材的包（日语视频的 Parakeet）的变体 / EP
///   推荐问服务它那种素材的服务（[serviceForProfile]），拿有声书那份去问会得到
///   同语言通用包（ReazonSpeech）的推荐——Parakeet 的 fp32 显存门槛不同。
/// - **顺带下 GPU 环境**：Windows 上模型下完接着装这台机器显卡对应的 GPU 运行时
///   （[gpuRuntimeToDownload]），进度合进同一条；GPU 环境失败不算模型下载失败
///   （模型照样能按 CPU 转录），原因走 [onGpuRuntimeError] 与 [lastGpuRuntimeErrorOf]。
class AsrModelDownloads extends ChangeNotifier {
  AsrModelDownloads({
    this.onFinished,
    this.onGpuRuntimeError,
    this.openPackStore = openAsrModelStoreForPack,
    this.gpuRuntimeToDownload = gpuRuntimeToDownloadForUi,
    AsrTranscriptionService Function(AsrAudioProfile profile)?
    serviceForProfile,
  }) : serviceForProfile =
           serviceForProfile ??
           ((AsrAudioProfile profile) =>
               createAsrTranscriptionService(audioProfile: profile));

  /// 下载结束回调（`error` 非空 = 模型下载失败；取消不回调）。
  final void Function(AsrModelPack pack, {Object? error})? onFinished;

  /// 模型已下好、顺带的 GPU 环境装失败时回调（模型下载照常算成功）。
  final void Function(AsrModelPack pack, Object error)? onGpuRuntimeError;

  /// 按包开模型目录（手动接入的本地包认用户自己的文件夹）。
  final Future<AsrModelStore> Function(AsrModelPack pack) openPackStore;

  /// 下模型阶段该一起下的 GPU 环境；null = 不需要 / 本平台没有。
  final Future<GpuRuntimeStore?> Function() gpuRuntimeToDownload;

  /// 调用方给的服务不服务某个包的素材时，按那种素材现建的服务（按素材缓存）。
  /// 模型目录本身不经服务，走 [openPackStore]。
  final AsrTranscriptionService Function(AsrAudioProfile profile)
  serviceForProfile;

  final Map<AsrAudioProfile, AsrTranscriptionService> _profileServices =
      <AsrAudioProfile, AsrTranscriptionService>{};

  final Map<String, _AsrDownloadSlot> _slots = <String, _AsrDownloadSlot>{};

  /// 每个包最近一次下载失败的原因（成功 / 重新开始下载时清掉）。
  final Map<String, String> _lastErrors = <String, String>{};

  /// 每个包最近一次顺带装 GPU 环境失败的原因（重新开始下载时清掉）。
  final Map<String, String> _lastGpuErrors = <String, String>{};

  bool _disposed = false;

  /// 该包是否正在下载（含取消收尾中）。
  bool isActive(String packId) => _slots.containsKey(packId);

  /// 当前进度；未在下载时为 null。
  AsrModelDownloadProgress? progressOf(String packId) =>
      _slots[packId]?.snapshot();

  /// 最近一次下载失败的原因；没失败过 / 之后成功过为 null。
  String? lastErrorOf(String packId) => _lastErrors[packId];

  /// 最近一次顺带装 GPU 环境失败的原因；没失败过 / 重新下载后为 null。
  String? lastGpuRuntimeErrorOf(String packId) => _lastGpuErrors[packId];

  /// [pack] 的变体 / EP 推荐该问哪份服务：[service] 服务这个包的素材就用它，否则
  /// 用 [serviceForProfile] 按包的素材建的那份。
  AsrTranscriptionService serviceFor(
    AsrTranscriptionService service,
    AsrModelPack pack,
  ) {
    if (pack.servesProfile(service.audioProfile)) return service;
    final AsrAudioProfile profile = pack.audioProfiles.first;
    return _profileServices.putIfAbsent(
      profile,
      () => serviceForProfile(profile),
    );
  }

  /// [pack] 的下载计划：变体与 EP 推荐按「语言 + 这个包服务的素材」取（与转录
  /// 弹层同一个 `plan(auto)`），模型状态换成**这个包自己目录**的。设置页每一行
  /// 与 CLI 都走这里。
  Future<AsrTranscribePlan> planFor(
    AsrTranscriptionService service,
    AsrModelPack pack,
  ) async {
    final AsrTranscribePlan byLanguage = await serviceFor(
      service,
      pack,
    ).plan(language: pack.language, preference: AsrAccelerationPreference.auto);
    final AsrModelStore store = await openPackStore(pack);
    return AsrTranscribePlan(
      language: byLanguage.language,
      variant: byLanguage.variant,
      expectedProvider: byLanguage.expectedProvider,
      modelStatus: await store.status(byLanguage.variant),
      probeError: byLanguage.probeError,
      availableProviders: byLanguage.availableProviders,
    );
  }

  /// 发起下载 [plan]（[planFor] 的结果）推荐的变体到 [pack] 自己的目录，并顺带
  /// 装 GPU 环境。
  ///
  /// 同一个包已在下载时返回 false，不另起第二条流。
  bool start(AsrModelPack pack, {required AsrTranscribePlan plan}) {
    if (_disposed || _slots.containsKey(pack.id)) return false;
    final _AsrDownloadSlot slot = _AsrDownloadSlot(
      total: plan.modelStatus.totalBytes,
      received: plan.modelStatus.obtainedBytes,
    );
    _slots[pack.id] = slot;
    _lastErrors.remove(pack.id);
    _lastGpuErrors.remove(pack.id);
    unawaited(_run(pack, slot, plan));
    _notify();
    return true;
  }

  Future<void> _run(
    AsrModelPack pack,
    _AsrDownloadSlot slot,
    AsrTranscribePlan plan,
  ) async {
    final AsrModelStore store;
    final GpuRuntimeStore? gpu;
    try {
      store = await openPackStore(pack);
      gpu = await gpuRuntimeToDownload();
    } on Object catch (error, stack) {
      _onError(pack, slot, error, stack);
      return;
    }
    // 打开目录期间被取消（或已被新一轮替换）：不再起下载。
    if (_disposed || slot.cancelling || !identical(_slots[pack.id], slot)) {
      return;
    }
    slot.total += gpu?.pendingDownloadBytes ?? 0;
    slot.subscription =
        withGpuRuntimeDownload(
          store.download(plan.variant),
          gpu,
          onGpuRuntimeError: (Object error) {
            _lastGpuErrors[pack.id] = '$error';
            if (!_disposed) onGpuRuntimeError?.call(pack, error);
          },
        ).listen(
          (ModelDownloadEvent event) {
            slot.onEvent(event);
            _notify();
          },
          onError: (Object error, StackTrace stack) =>
              _onError(pack, slot, error, stack),
          onDone: () => _finish(pack, slot),
          cancelOnError: true,
        );
    _notify();
  }

  void _onError(
    AsrModelPack pack,
    _AsrDownloadSlot slot,
    Object error,
    StackTrace stack,
  ) {
    ErrorLogService.instance.log(
      'AsrModelDownloads.download[${pack.id}]',
      error,
      stack,
    );
    unawaited(slot.cancel());
    _finish(pack, slot, error: error);
  }

  /// 取消下载。已落盘的 `.part` 留着，下次「下载」由下载器 Range 续上。
  Future<void> cancel(String packId) async {
    final _AsrDownloadSlot? slot = _slots[packId];
    if (slot == null || slot.cancelling) return;
    slot.cancelling = true;
    _notify();
    try {
      await slot.cancel();
    } finally {
      if (identical(_slots[packId], slot)) {
        _slots.remove(packId);
        _notify();
      }
    }
  }

  void _finish(AsrModelPack pack, _AsrDownloadSlot slot, {Object? error}) {
    if (!identical(_slots[pack.id], slot) || slot.cancelling) return;
    _slots.remove(pack.id);
    if (error != null) _lastErrors[pack.id] = '$error';
    _notify();
    if (!_disposed) onFinished?.call(pack, error: error);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final _AsrDownloadSlot slot in _slots.values) {
      unawaited(slot.cancel());
    }
    _slots.clear();
    super.dispose();
  }
}

class _AsrDownloadSlot {
  _AsrDownloadSlot({required this.total, required this.received});

  StreamSubscription<ModelDownloadEvent>? subscription;

  Future<void> cancel() async => subscription?.cancel();

  /// 模型全套文件 + 顺带的 GPU 环境（打开目录后才知道要不要）的预期总字节。
  int total;
  int received;
  int _completed = 0;
  String _lastFile = '';
  int _lastFileTotal = 0;
  String file = '';
  bool cancelling = false;

  void onEvent(ModelDownloadEvent event) {
    if (event.fileName != _lastFile) {
      _completed += _lastFileTotal;
      _lastFile = event.fileName;
      _lastFileTotal = event.totalBytes;
    }
    file = event.fileName;
    received = _completed + event.receivedBytes;
  }

  AsrModelDownloadProgress snapshot() => AsrModelDownloadProgress(
    receivedBytes: received,
    totalBytes: total,
    currentFile: file,
    cancelling: cancelling,
  );
}
