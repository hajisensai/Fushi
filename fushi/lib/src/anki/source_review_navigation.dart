import 'dart:async';

import 'package:flutter/foundation.dart';

/// The current media page owns its shutdown. External navigation must await
/// that shutdown instead of removing a route before its final writes finish.
class ExternalMediaNavigation {
  ExternalMediaNavigation._();
  static final ExternalMediaNavigation instance = ExternalMediaNavigation._();

  /// 测试专用的独立实例：[navigate] 的队列尾是跨调用存活的 future，单例在
  /// testWidgets 之间复用时它属于上一个用例的 FakeAsync zone，后续用例 await 它
  /// 永远等不到微任务。
  @visibleForTesting
  ExternalMediaNavigation.forTesting();
  Object? _owner;
  Future<bool> Function()? _close;
  String? Function()? _videoUid;
  Future<void> Function()? _returnToReading;
  bool Function()? _isSourceReview;
  Future<void> Function()? get returnToReading =>
      (_isSourceReview?.call() ?? true) ? _returnToReading : null;
  Future<void> _navigation = Future<void>.value();
  Future<bool>? _closing;
  String? get activeVideoUid => _videoUid?.call();

  void register(
    Object owner,
    Future<bool> Function() close, {
    String? Function()? videoUid,
    Future<void> Function()? returnToReading,
    bool Function()? isSourceReview,
  }) {
    _owner = owner;
    _close = close;
    _videoUid = videoUid;
    _returnToReading = returnToReading;
    _isSourceReview = isSourceReview;
  }

  void unregister(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _close = null;
    _videoUid = null;
    _returnToReading = null;
    _isSourceReview = null;
  }

  Future<bool> closeActive() async {
    final Future<bool>? pending = _closing;
    if (pending != null) return pending;
    final Future<bool> closing = _close?.call() ?? Future<bool>.value(true);
    _closing = closing;
    try {
      return await closing;
    } finally {
      if (identical(_closing, closing)) _closing = null;
    }
  }

  /// URL opens and the return button share one queue, so two route transitions
  /// cannot both restore media after awaiting the same outgoing page.
  Future<void> navigate(Future<void> Function() action) async {
    final Future<void> previous = _navigation;
    final Completer<void> finished = Completer<void>();
    _navigation = finished.future;
    await previous;
    try {
      await action();
    } finally {
      finished.complete();
    }
  }
}
