import 'dart:async';
import 'dart:io';

/// Whether [error] is a **transient** network/timeout failure a bounded
/// retry-with-backoff can recover from, as opposed to a permanent one (auth,
/// permission, not-found, malformed request).
///
/// Mirrors the substring taxonomy `sync_error_messages.dart` already trusts for
/// its "timeout" / "network" clauses, plus the concrete `dart:io` exception
/// types. Auth / scope / other permanent failures are explicitly NOT transient:
/// they have their own refresh / re-consent handling and must never be silently
/// retried (a hard sign-in-expired would just burn every attempt then fail the
/// same way). This is the missing classifier behind BUG-864 — a Google Drive
/// `SocketException` (信号灯超时 / errno 121) arrived unclassified and abandoned
/// the whole aggregate sync round with zero retries.
bool isTransientSyncError(Object error) {
  if (error is SocketException) return true;
  if (error is TimeoutException) return true;
  if (error is HttpException) return true;
  final String l = error.toString().toLowerCase();
  // Permanent auth/permission failures: never retry (own handling path). Checked
  // first so a message that happens to also mention a socket cannot smuggle an
  // auth error into the retry loop.
  if (l.contains('insufficient_scope') ||
      l.contains('unauthorized') ||
      l.contains('invalid_grant') ||
      l.contains('403') && l.contains('insufficient')) {
    return false;
  }
  const List<String> transientMarkers = <String>[
    'timed out',
    'timeout',
    '信号灯超时', // Windows ERROR_SEM_TIMEOUT
    'errno = 121', // ERROR_SEM_TIMEOUT
    'errno = 110', // ETIMEDOUT
    'socketexception',
    'clientexception',
    'handshakeexception',
    'failed host lookup',
    'connection refused',
    'connection closed',
    'connection reset',
    'connection abort', // "software caused connection abort"
    'network is unreachable',
  ];
  for (final String marker in transientMarkers) {
    if (l.contains(marker)) return true;
  }
  return false;
}

/// Runs [op], retrying up to [maxAttempts] **total** attempts while the thrown
/// error passes [isTransient] (default [isTransientSyncError]). Waits
/// `backoff * attempt` (linear backoff) between tries; [sleep] is injectable so
/// tests run without real delay.
///
/// Re-throws the last error the moment attempts are exhausted OR the error is
/// non-transient, so a permanent failure surfaces immediately instead of
/// wasting the whole retry budget. The retried [op] must be idempotent — every
/// caller here is (Drive folder ensure / list / download / overwrite-by-name
/// upload), so a repeated attempt after a partial network blip is safe.
Future<T> retryTransientSync<T>(
  Future<T> Function() op, {
  int maxAttempts = 4,
  Duration backoff = const Duration(milliseconds: 400),
  bool Function(Object error) isTransient = isTransientSyncError,
  Future<void> Function(Duration delay)? sleep,
}) async {
  assert(maxAttempts >= 1, 'maxAttempts must be at least 1');
  final Future<void> Function(Duration delay) doSleep =
      sleep ?? (Duration delay) => Future<void>.delayed(delay);
  int attempt = 0;
  while (true) {
    attempt++;
    try {
      return await op();
    } catch (error) {
      if (attempt >= maxAttempts || !isTransient(error)) rethrow;
      await doSleep(backoff * attempt);
    }
  }
}
