import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fushi_asr_core/asr_core.dart';

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
class AsrModelDownloads extends ChangeNotifier {
  AsrModelDownloads({this.onFinished});

  /// 下载结束回调（`error` 非空 = 失败；取消不回调）。
  final void Function(AsrModelPack pack, {Object? error})? onFinished;

  final Map<String, _AsrDownloadSlot> _slots = <String, _AsrDownloadSlot>{};

  /// 每个包最近一次下载失败的原因（成功 / 重新开始下载时清掉）。
  final Map<String, String> _lastErrors = <String, String>{};

  bool _disposed = false;

  /// 该包是否正在下载（含取消收尾中）。
  bool isActive(String packId) => _slots.containsKey(packId);

  /// 当前进度；未在下载时为 null。
  AsrModelDownloadProgress? progressOf(String packId) =>
      _slots[packId]?.snapshot();

  /// 最近一次下载失败的原因；没失败过 / 之后成功过为 null。
  String? lastErrorOf(String packId) => _lastErrors[packId];

  /// 发起下载 [plan] 推荐的变体（与设置页 / 转录弹层同一个 `plan(auto)`）。
  ///
  /// 同一个包已在下载时返回 false，不另起第二条流。
  bool start(
    AsrModelPack pack, {
    required AsrTranscriptionService service,
    required AsrTranscribePlan plan,
  }) {
    if (_disposed || _slots.containsKey(pack.id)) return false;
    final _AsrDownloadSlot slot = _AsrDownloadSlot(
      total: plan.modelStatus.totalBytes,
      received: plan.modelStatus.obtainedBytes,
    );
    _slots[pack.id] = slot;
    _lastErrors.remove(pack.id);
    slot.subscription = service
        .downloadModel(language: pack.language, variant: plan.variant)
        .listen(
          (ModelDownloadEvent event) {
            slot.onEvent(event);
            _notify();
          },
          onError: (Object error, StackTrace stack) {
            ErrorLogService.instance.log(
              'AsrModelDownloads.download[${pack.id}]',
              error,
              stack,
            );
            unawaited(slot.cancel());
            _finish(pack, slot, error: error);
          },
          onDone: () => _finish(pack, slot),
          cancelOnError: true,
        );
    _notify();
    return true;
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

  final int total;
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
