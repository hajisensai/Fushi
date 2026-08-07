import 'dart:async';

/// Coalesces high-frequency WebView pinch/wheel zoom callbacks into one
/// trailing preference write while keeping the in-page zoom UI immediate.
class MangaZoomPreferenceDebouncer {
  MangaZoomPreferenceDebouncer({
    required this.persist,
    this.delay = const Duration(milliseconds: 250),
  });

  final Future<void> Function(int value) persist;
  final Duration delay;

  Timer? _timer;
  int? _pending;

  void queue(int value) {
    _pending = value;
    _timer?.cancel();
    _timer = Timer(delay, () => unawaited(flush()));
  }

  void discard() {
    _timer?.cancel();
    _timer = null;
    _pending = null;
  }

  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    final int? pending = _pending;
    _pending = null;
    if (pending != null) await persist(pending);
  }

  Future<void> dispose() => flush();
}
