import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Route;

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
  bool Function(Route<dynamic> route)? _ownsRoute;
  Future<void> Function()? get returnToReading =>
      (_isSourceReview?.call() ?? true) ? _returnToReading : null;
  Future<void> _navigation = Future<void>.value();
  Future<bool>? _closing;
  String? get activeVideoUid => _videoUid?.call();

  /// [route] 是不是当前登记的媒体页自己的路由。外部导航据此决定「这层交给
  /// [closeActive]」，而不是先按返回键（媒体页的返回回调是 async 的，`maybePop`
  /// 不等它；先按返回再 closeActive 会让同一页的退出流程跑两遍）。
  bool ownsRoute(Route<dynamic> route) => _ownsRoute?.call(route) ?? false;

  void register(
    Object owner,
    Future<bool> Function() close, {
    String? Function()? videoUid,
    Future<void> Function()? returnToReading,
    bool Function()? isSourceReview,
    bool Function(Route<dynamic> route)? ownsRoute,
  }) {
    _owner = owner;
    _close = close;
    _videoUid = videoUid;
    _returnToReading = returnToReading;
    _isSourceReview = isSourceReview;
    _ownsRoute = ownsRoute;
  }

  void unregister(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _close = null;
    _videoUid = null;
    _returnToReading = null;
    _isSourceReview = null;
    _ownsRoute = null;
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
