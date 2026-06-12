typedef LookupAutoReadPlayback = Future<void> Function();

class LookupAutoReadCoordinator {
  LookupAutoReadCoordinator({
    Duration dedupeWindow = const Duration(milliseconds: 800),
    DateTime Function()? now,
  })  : _dedupeWindow = dedupeWindow,
        _now = now ?? DateTime.now;

  static const String defaultSource = 'lookup';

  static final LookupAutoReadCoordinator instance = LookupAutoReadCoordinator();

  final Duration _dedupeWindow;
  final DateTime Function() _now;
  final Map<_LookupAutoReadKey, DateTime> _acceptedAt =
      <_LookupAutoReadKey, DateTime>{};
  final Set<_LookupAutoReadKey> _inFlight = <_LookupAutoReadKey>{};

  Future<bool> runAutomatic({
    required String expression,
    required String reading,
    String source = defaultSource,
    required LookupAutoReadPlayback play,
  }) async {
    final _LookupAutoReadKey key = _LookupAutoReadKey(
      expression: expression,
      reading: reading,
      source: source,
    );
    final DateTime startedAt = _now();
    _pruneExpired(startedAt);

    final DateTime? previous = _acceptedAt[key];
    if (_inFlight.contains(key) ||
        (previous != null && startedAt.difference(previous) < _dedupeWindow)) {
      return false;
    }

    _inFlight.add(key);
    _acceptedAt[key] = startedAt;
    try {
      await play();
      _acceptedAt[key] = _now();
      return true;
    } catch (_) {
      _acceptedAt.remove(key);
      rethrow;
    } finally {
      _inFlight.remove(key);
      _pruneExpired(_now());
    }
  }

  void _pruneExpired(DateTime now) {
    _acceptedAt.removeWhere(
      (_, DateTime acceptedAt) => now.difference(acceptedAt) >= _dedupeWindow,
    );
  }
}

class _LookupAutoReadKey {
  const _LookupAutoReadKey({
    required this.expression,
    required this.reading,
    required this.source,
  });

  final String expression;
  final String reading;
  final String source;

  @override
  bool operator ==(Object other) {
    return other is _LookupAutoReadKey &&
        other.expression == expression &&
        other.reading == reading &&
        other.source == source;
  }

  @override
  int get hashCode => Object.hash(expression, reading, source);
}
