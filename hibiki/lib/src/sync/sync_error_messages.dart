import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/utils.dart';

/// Localized friendly clause for a known error class, or null if the error is
/// not one we recognize (caller decides the fallback).
String? _friendlyClause(Object error) {
  final String msg =
      error is SyncBackendError ? error.message : _rawMessage(error);
  final String l = msg.toLowerCase();

  // Configuration / validation problems are not "expired auth" — show the
  // (usually readable) reason instead of mislabeling them.
  if (l.contains('not configured') ||
      l.contains('credentials') ||
      l.contains('requires') ||
      l.contains('missing')) {
    return null;
  }

  if (l.contains('507') || l.contains('quota')) {
    return t.sync_err_quota;
  }
  // Treat as expired/unauthorized only when the message actually says so;
  // a bare SyncAuthError can also mean "not configured" (handled above).
  if (l.contains('401') ||
      l.contains('unauthorized') ||
      l.contains('authentication expired') ||
      l.contains('expired') ||
      l.contains('invalid_grant') ||
      l.contains('refresh token') ||
      (error is SyncAuthError &&
          (l.contains('auth') || l.contains('sign') || l.contains('token')))) {
    return t.sync_err_auth_expired;
  }
  if (l.contains('timed out') ||
      l.contains('timeout') ||
      l.contains('信号灯超时') || // Windows ERROR_SEM_TIMEOUT
      l.contains('errno = 121') ||
      l.contains('errno = 110')) {
    return t.sync_err_timeout;
  }
  if (l.contains('socketexception') ||
      l.contains('clientexception') ||
      l.contains('handshakeexception') ||
      l.contains('failed host lookup') ||
      l.contains('connection refused') ||
      l.contains('connection closed') ||
      l.contains('connection reset') ||
      l.contains('network is unreachable')) {
    return t.sync_err_network;
  }
  return null;
}

String _rawMessage(Object error) => error is SyncBackendError
    ? error.message
    : error is SyncAuthError
        ? error.message
        : error.toString();

/// Complete, user-facing message for an error shown on its own (snackbar,
/// dialog body). Known errors become a friendly localized sentence; unknown
/// ones fall back to the raw message wrapped in [t.sync_error] so the original
/// text is never hidden.
String friendlySyncError(Object error) =>
    _friendlyClause(error) ?? t.sync_error(message: _rawMessage(error));

/// Friendly clause only, for embedding in another template's `message:` slot
/// (e.g. `t.sync_webdav_test_failed(message: ...)`). Falls back to the raw
/// message so nothing is hidden, without double-wrapping in [t.sync_error].
String friendlySyncErrorDetail(Object error) =>
    _friendlyClause(error) ?? _rawMessage(error);
