import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';

/// 一个本机 OCR 模型当前的下载进度快照。
@immutable
class MangaOcrModelDownloadProgress {
  const MangaOcrModelDownloadProgress({
    required this.receivedBytes,
    required this.currentFile,
    required this.cancelling,
  });

  /// 按文件名归并后的已收字节总和（下载器逐文件报进度，见 BUG-1732）。
  final int receivedBytes;

  /// 最近一条事件的文件名；还没收到事件时为 null。
  final String? currentFile;

  /// 已请求取消、正在等待下载器收尾。收尾前文件仍归下载器所有。
  final bool cancelling;
}

/// 本机 OCR 模型的**后台下载**登记表（全应用单例，经 provider 取）。
///
/// 下载订阅以前挂在设置区 widget 的 State 上：离开设置页 `dispose` 一取消，几百
/// MB 到几 GB 的下载就白下了，用户只能守在页面上等。这里把订阅所有权提到页面
/// 之外——页面只是观察者，关掉页面下载照跑，完成 / 失败由这里弹全局提示；设置
/// 区与「设置 › 存储」看到的是同一份进度。
///
/// 按模型分槽：各模型落在互不相干的兄弟目录（[MangaOcrLocalModel.modelsDirectory]），
/// 不同模型可以并行下载；同一模型重复发起直接忽略。
class MangaOcrModelDownloads extends ChangeNotifier {
  MangaOcrModelDownloads({this.onFinished});

  /// 下载结束回调（`failed` 为真表示出错；取消不回调）。生产接线用它弹全局
  /// toast——页面可能早已关闭，提示不能依赖页面。
  final void Function(MangaOcrLocalModel model, {required bool failed})?
  onFinished;

  final Map<MangaOcrLocalModel, _DownloadSlot> _slots =
      <MangaOcrLocalModel, _DownloadSlot>{};

  bool _disposed = false;

  /// 该模型是否正在下载（含取消收尾中）。
  bool isActive(MangaOcrLocalModel model) => _slots.containsKey(model);

  /// 当前进度；未在下载时为 null。
  MangaOcrModelDownloadProgress? progressOf(MangaOcrLocalModel model) =>
      _slots[model]?.snapshot();

  /// 发起下载。
  ///
  /// 同一模型已在下载时返回 false，不另起第二条流。
  bool start(MangaOcrLocalModel model, MangaOcrService service) {
    if (_disposed || _slots.containsKey(model)) return false;
    final Stream<MangaOcrDownloadEvent> events = service.downloadModels();
    final _DownloadSlot slot = _DownloadSlot();
    _slots[model] = slot;
    slot.subscription = events.listen(
      (MangaOcrDownloadEvent event) {
        slot.currentFile = event.fileName;
        // 同名文件取最新值而不是累加：同一文件会连发多条递增进度事件。
        slot.receivedByFile[event.fileName] = event.receivedBytes;
        _notify();
      },
      onError: (Object error, StackTrace stack) {
        // 失败只弹 toast 的话，事后用户说「下到一半停了」日志里什么都没有。
        ErrorLogService.instance.log(
          'MangaOcrModelDownloads.download[${model.name}]',
          error,
          stack,
        );
        unawaited(slot.cancel());
        _finish(model, slot, failed: true);
      },
      onDone: () => _finish(model, slot, failed: false),
    );
    _notify();
    return true;
  }

  /// 取消下载。等下载器确认收尾（删 `.part`）后才释放槽位——
  /// 收尾前那批文件仍归下载器，删除 / 导入入口据此保持禁用。
  Future<void> cancel(MangaOcrLocalModel model) async {
    final _DownloadSlot? slot = _slots[model];
    if (slot == null || slot.cancelling) return;
    slot.cancelling = true;
    _notify();
    try {
      await slot.cancel();
    } finally {
      if (identical(_slots[model], slot)) {
        _slots.remove(model);
        _notify();
      }
    }
  }

  void _finish(
    MangaOcrLocalModel model,
    _DownloadSlot slot, {
    required bool failed,
  }) {
    if (!identical(_slots[model], slot) || slot.cancelling) return;
    _slots.remove(model);
    _notify();
    if (!_disposed) onFinished?.call(model, failed: failed);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final _DownloadSlot slot in _slots.values) {
      unawaited(slot.cancel());
    }
    _slots.clear();
    super.dispose();
  }
}

class _DownloadSlot {
  StreamSubscription<MangaOcrDownloadEvent>? subscription;

  Future<void> cancel() async => subscription?.cancel();
  final Map<String, int> receivedByFile = <String, int>{};
  String? currentFile;
  bool cancelling = false;

  MangaOcrModelDownloadProgress snapshot() => MangaOcrModelDownloadProgress(
    receivedBytes: receivedByFile.values.fold<int>(0, (int a, int b) => a + b),
    currentFile: currentFile,
    cancelling: cancelling,
  );
}
