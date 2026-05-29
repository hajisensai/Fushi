import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/utils.dart';

/// Map a raw sync error/exception to a human-readable, localized message.
///
/// Common cloud-sync failures (network unreachable, timeout, expired auth,
/// quota) surface from `package:http` / `dart:io` as opaque English or
/// OS-localized strings (e.g. "ClientException with SocketException: 信号灯
/// 超时", "quotaLimitReached"). This translates the frequent cases and falls
/// back to the original message (wrapped) so nothing is ever hidden.
String friendlySyncError(Object error) {
  if (error is SyncAuthError) return t.sync_err_auth_expired;

  final String message =
      error is SyncBackendError ? error.message : error.toString();
  final String l = message.toLowerCase();

  if (l.contains('507') || l.contains('quota')) {
    return t.sync_err_quota;
  }
  if (l.contains('401') ||
      l.contains('unauthorized') ||
      l.contains('authentication expired') ||
      l.contains('invalid_grant')) {
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

  // Unknown error: keep the original text so the user/devs can still see it.
  return t.sync_error(message: message);
}
