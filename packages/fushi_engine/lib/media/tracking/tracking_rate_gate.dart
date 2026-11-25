/// Sliding-window request budget shared by every client of one provider, so a
/// new sync session cannot restart the count. The default (30 a minute) is
/// AniList's degraded limit and MangaBaka's search limit.
final class TrackingRateGate {
  TrackingRateGate({
    this.maxRequests = 30,
    this.window = const Duration(minutes: 1),
    DateTime Function()? now,
    Future<void> Function(Duration delay)? wait,
  }) : _now = now ?? DateTime.now,
       _wait = wait ?? ((Duration delay) => Future<void>.delayed(delay));

  final int maxRequests;
  final Duration window;
  final DateTime Function() _now;
  final Future<void> Function(Duration delay) _wait;
  final List<DateTime> _sent = <DateTime>[];

  /// Waits until one more request fits in the window, then records it.
  Future<void> reserve() async {
    while (true) {
      final DateTime now = _now();
      _sent.removeWhere((DateTime at) => now.difference(at) >= window);
      if (_sent.length < maxRequests) {
        _sent.add(now);
        return;
      }
      await _wait(window - now.difference(_sent.first));
    }
  }
}
