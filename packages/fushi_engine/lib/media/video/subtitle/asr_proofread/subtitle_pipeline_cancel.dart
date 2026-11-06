/// 视频字幕管线的取消令牌（spec `2026-10-19-video-asr-llm-subtitle-pipeline`）。
///
/// 管线既跑在 host job 里（取消走 `HostJobCancelToken`），也跑在 app 前台与 CLI
/// 里；这里只定义管线需要的最小形状，host job 那边用 [HostJobSubtitleCancelToken]
/// 适配，不让管线依赖 host job 的上下文类型。
library;

import 'package:fushi_engine/sync/host_jobs/host_job_runner.dart';

/// 取消信号：只读 + 订阅。
abstract interface class SubtitleCancelToken {
  bool get isCancelled;

  /// 取消时回调；已取消则立刻回调一次。
  void onCancel(void Function() listener);
}

/// 管线被取消：已落盘的阶段产物保留，重跑同一任务即从断点续。
class SubtitlePipelineCancelled implements Exception {
  const SubtitlePipelineCancelled();

  @override
  String toString() => 'SubtitlePipelineCancelled';
}

/// 已取消就抛 [SubtitlePipelineCancelled]。
void throwIfSubtitleCancelled(SubtitleCancelToken cancel) {
  if (cancel.isCancelled) throw const SubtitlePipelineCancelled();
}

/// 可手动触发的令牌（app 前台 / CLI / 测试）。
class SubtitleCancelSource implements SubtitleCancelToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = <void Function()>[];

  @override
  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final void Function() l in List<void Function()>.of(_listeners)) {
      l();
    }
    _listeners.clear();
  }

  @override
  void onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }
}

/// 永不取消。
class SubtitleNeverCancel implements SubtitleCancelToken {
  const SubtitleNeverCancel();

  @override
  bool get isCancelled => false;

  @override
  void onCancel(void Function() listener) {}
}

/// `HostJobCancelToken` → [SubtitleCancelToken]。
class HostJobSubtitleCancelToken implements SubtitleCancelToken {
  const HostJobSubtitleCancelToken(this.token);

  final HostJobCancelToken token;

  @override
  bool get isCancelled => token.isCancelled;

  @override
  void onCancel(void Function() listener) => token.onCancel(listener);
}
