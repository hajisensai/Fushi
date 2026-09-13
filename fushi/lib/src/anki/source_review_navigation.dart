import 'dart:async';

/// The current media page owns its shutdown. External navigation must await
/// that shutdown instead of removing a route before its final writes finish.
class ExternalMediaNavigation {
  ExternalMediaNavigation._();
  static final ExternalMediaNavigation instance = ExternalMediaNavigation._();
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
