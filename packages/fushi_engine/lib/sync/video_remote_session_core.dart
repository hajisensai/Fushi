import 'dart:async';
import 'dart:collection';

import 'package:fushi_engine/sync/video_remote_service.dart';

/// Bounded revision journal, exclusive controller lease and retry deduplication.
final class VideoRemoteSessionCore {
  VideoRemoteSessionCore({
    DateTime Function()? now,
    this.leaseDuration = const Duration(seconds: 35),
    this.historyLimit = 128,
    this.requestLimit = 128,
    this.onLeaseExpired,
  }) : assert(historyLimit > 0),
       assert(requestLimit > 0),
       assert(leaseDuration > Duration.zero),
       _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final Duration leaseDuration;
  final int historyLimit;
  final int requestLimit;
  final Future<void> Function(String peerId)? onLeaseExpired;
  String? _owner;
  DateTime? _expires;
  Timer? _leaseTimer;
  bool _disposed = false;
  Future<void>? _expiry;
  int _revision = 0;
  int _leaseGeneration = 0;
  final Queue<Map<String, Object?>> _journal = Queue<Map<String, Object?>>();
  final Set<Completer<void>> _waiters = <Completer<void>>{};
  final LinkedHashMap<String, _RemoteRequest> _requests =
      LinkedHashMap<String, _RemoteRequest>();

  int get revision => _revision;
  String? get owner => _owner;
  int get leaseGeneration => _leaseGeneration;

  Future<void> acquire(String peerId) async {
    if (_disposed) {
      throw const VideoRemoteException(410, 'remote_closed');
    }
    if (peerId.isEmpty) {
      throw const VideoRemoteException(403, 'invalid_peer');
    }
    await _expireIfNeeded();
    if (_disposed) {
      throw const VideoRemoteException(410, 'remote_closed');
    }
    if (_owner != null && _owner != peerId) {
      throw const VideoRemoteException(409, 'controller_busy');
    }
    if (_owner == null) {
      _leaseGeneration++;
    }
    _owner = peerId;
    _expires = _now().add(leaseDuration);
    _leaseTimer?.cancel();
    _leaseTimer = Timer(leaseDuration, () {
      unawaited(_expireIfNeeded());
    });
  }

  Future<void> assertOwner(String peerId) async {
    await _expireIfNeeded();
    if (_owner != peerId) {
      throw const VideoRemoteException(409, 'controller_lease_lost');
    }
    await acquire(peerId);
  }

  Future<void> _expireIfNeeded() async {
    final Future<void>? pending = _expiry;
    if (pending != null) {
      return pending;
    }
    final String? expired = _owner;
    if (expired == null || _now().isBefore(_expires!)) {
      return;
    }
    _owner = null;
    _leaseGeneration++;
    _expires = null;
    _leaseTimer?.cancel();
    final Future<void> cleanup = Future<void>.sync(() async {
      await onLeaseExpired?.call(expired);
      publish('controllerDisconnected', <String, Object?>{});
    });
    _expiry = cleanup;
    try {
      await cleanup;
    } finally {
      _expiry = null;
    }
  }

  void release(String peerId) {
    if (_owner != peerId) {
      return;
    }
    _owner = null;
    _leaseGeneration++;
    _expires = null;
    _leaseTimer?.cancel();
    publish('controllerDisconnected', <String, Object?>{});
  }

  void publish(String type, Map<String, Object?> payload) {
    if (_disposed) {
      return;
    }
    _journal.add(
      Map<String, Object?>.unmodifiable(<String, Object?>{
        'revision': ++_revision,
        'type': type,
        'payload': Map<String, Object?>.unmodifiable(payload),
      }),
    );
    while (_journal.length > historyLimit) {
      _journal.removeFirst();
    }
    for (final Completer<void> waiter in _waiters.toList()) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
    _waiters.clear();
  }

  Future<Map<String, Object?>> events(
    int afterRevision, {
    int waitMs = 25000,
  }) async {
    if (afterRevision < 0) {
      throw const VideoRemoteException(400, 'invalid_revision');
    }
    if (_revision == afterRevision && !_disposed && waitMs > 0) {
      final Completer<void> waiter = Completer<void>();
      _waiters.add(waiter);
      final Timer timer = Timer(
        Duration(milliseconds: waitMs.clamp(0, 25000)),
        () {
          if (!waiter.isCompleted) {
            waiter.complete();
          }
        },
      );
      try {
        await waiter.future;
      } finally {
        timer.cancel();
        _waiters.remove(waiter);
      }
    }
    final bool reset =
        afterRevision > _revision ||
        (_journal.isNotEmpty &&
            afterRevision < (_journal.first['revision']! as int) - 1);
    return <String, Object?>{
      'revision': _revision,
      'reset': reset,
      'events': reset
          ? <Object?>[]
          : _journal
                .where(
                  (Map<String, Object?> event) =>
                      (event['revision']! as int) > afterRevision,
                )
                .toList(),
    };
  }

  Future<Map<String, Object?>> runIdempotent(
    String peerId,
    String requestId,
    Future<Map<String, Object?>> Function() action, {
    required String fingerprint,
  }) {
    if (requestId.isEmpty || requestId.length > 200) {
      throw const VideoRemoteException(400, 'invalid_request_id');
    }
    final String key = '$peerId:$requestId';
    final _RemoteRequest? existing = _requests[key];
    if (existing != null) {
      if (existing.fingerprint != fingerprint) {
        throw const VideoRemoteException(409, 'request_id_conflict');
      }
      return existing.result;
    }
    if (_requests.length >= requestLimit) {
      final List<String> completed = _requests.entries
          .where(
            (MapEntry<String, _RemoteRequest> entry) => entry.value.completed,
          )
          .map((MapEntry<String, _RemoteRequest> entry) => entry.key)
          .toList();
      if (completed.isEmpty) {
        throw const VideoRemoteException(429, 'requests_busy');
      }
      _requests.remove(completed.first);
    }
    final _RemoteRequest request = _RemoteRequest(fingerprint);
    _requests[key] = request;
    request.result = Future<Map<String, Object?>>.sync(action)
        .then(
          (Map<String, Object?> value) => value,
          onError: (Object error, StackTrace stack) {
            // A [VideoRemoteException] is a deterministic protocol answer and is
            // replayed for the same request ID. Anything else is an internal
            // fault: drop the journal entry so the result is never replayed as
            // if the operation had a settled outcome.
            if (error is! VideoRemoteException &&
                identical(_requests[key], request)) {
              _requests.remove(key);
            }
            Error.throwWithStackTrace(error, stack);
          },
        )
        .whenComplete(() {
          request.completed = true;
        });
    return request.result;
  }

  void dispose() {
    _disposed = true;
    _leaseGeneration++;
    _owner = null;
    _expires = null;
    _leaseTimer?.cancel();
    for (final Completer<void> waiter in _waiters) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
    _waiters.clear();
    _requests.clear();
  }
}

final class _RemoteRequest {
  _RemoteRequest(this.fingerprint);
  final String fingerprint;
  late final Future<Map<String, Object?>> result;
  bool completed = false;
}
