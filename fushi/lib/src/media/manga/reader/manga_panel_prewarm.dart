/// 漫画分镜检测的翻页预热调度（manga-21）。
///
/// 落到一个跨页就在后台把它的分镜检测好，第一次按翻分镜键不用再等整条「建检测器 +
/// 读页 + 预处理 + 推理」。但检测器内部是串行队列（`OnnxPanelDetector` 的
/// `_serial`），每翻一页都无条件丢一个预热进去的话，快速翻页 / 跳页会排起一长串
/// 已经翻过去的页的推理，读者停下来按翻分镜键时，当前页反而排在这串陈旧预热后面。
/// 这里只让一个预热在飞：在飞期间的请求只记「目标变了」，在飞的那个结束后直接追
/// 最新目标，中间翻过的跨页一律不检测。
library;

import 'dart:async';

/// 单飞、追最新目标的预热器。[T] 是目标的值相等身份（如 `(generation, spread)`
/// 记录）；`target()` 返回 null 表示当前不该预热（开关关着 / 条漫 / 页面已卸载）。
class MangaPanelPrewarmer<T extends Object> {
  MangaPanelPrewarmer({
    required T? Function() target,
    required Future<void> Function(T target) warm,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) : _target = target,
       _warm = warm,
       _onError = onError;

  final T? Function() _target;
  final Future<void> Function(T target) _warm;
  final void Function(Object error, StackTrace stackTrace)? _onError;
  bool _running = false;
  bool _disposed = false;

  /// 是否有预热在飞（测试与诊断用）。
  bool get running => _running;

  /// 读者落到了新目标。已有预热在飞时什么都不排：它结束后会重读 `target()`。
  void request() {
    if (_running || _disposed) return;
    final T? first = _target();
    if (first == null) return;
    _running = true;
    unawaited(_drain(first));
  }

  Future<void> _drain(T first) async {
    T? next = first;
    try {
      while (next != null && !_disposed) {
        final T current = next;
        try {
          await _warm(current);
        } on Object catch (error, stackTrace) {
          // 预热是尽力而为：失败只记日志，按键翻分镜时照常懒检测一次。
          _onError?.call(error, stackTrace);
        }
        if (_disposed) break;
        final T? latest = _target();
        next = latest == current ? null : latest;
      }
    } finally {
      _running = false;
    }
  }

  /// 页面卸载：在飞的那一个照常结束，之后不再追。
  void dispose() {
    _disposed = true;
  }
}
