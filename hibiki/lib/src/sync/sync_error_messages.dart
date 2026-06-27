import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/utils.dart';

/// Localized friendly clause for a known error class, or null if the error is
/// not one we recognize (caller decides the fallback).
String? _friendlyClause(Object error) {
  final String msg =
      error is SyncBackendError ? error.message : _rawMessage(error);
  final String l = msg.toLowerCase();

  // This build has no real OAuth credentials baked in (the placeholder secret
  // shipped instead of a real one) — caught fail-fast before the browser flow.
  // Tell the user to get a properly configured build, not "sign in again".
  // Checked first because the marker is unambiguous (TODO-045).
  if (l.contains('sync_credentials_not_configured')) {
    return t.sync_err_not_configured;
  }

  // Configuration / validation problems are not "expired auth" — show the
  // (usually readable) raw reason instead of mislabeling them. This gate stays
  // NARROW: a bare 'credentials' substring used to live here, but it also
  // swallowed googleapis_auth's "Failed to obtain access credentials. Error:
  // invalid_client ... 401" (a real auth-config rejection handled below), so it
  // was dropped — invalid_client now reaches its own branch (TODO-045).
  if (l.contains('not configured') ||
      l.contains('requires') ||
      l.contains('missing')) {
    return null;
  }

  if (l.contains('507') || l.contains('quota')) {
    return t.sync_err_quota;
  }
  // invalid_client = the OAuth client_id/secret baked into this build is wrong
  // (e.g. CI shipped the placeholder secret). It surfaces as a 401 from the
  // token endpoint, but "sign-in expired" is the wrong fix — the user must
  // update to a build with valid credentials. Check it BEFORE the generic 401
  // branch so the more actionable message wins (TODO-045).
  if (l.contains('invalid_client')) {
    return t.sync_err_invalid_client;
  }
  // TODO-836: a 403 insufficient_scope means the sync scope changed
  // (drive.file → drive.appdata) and the old grant is now insufficient — the
  // user must re-consent. Matched BEFORE the 401 branch: the www-authenticate
  // string can carry 'unauthorized' too, and mislabeling this as "sign-in
  // expired" hides that it's a permission upgrade. The literal substrings here
  // match the marker GoogleDriveHandler throws ('insufficient_scope').
  if (l.contains('insufficient_scope') ||
      l.contains('insufficientpermissions') ||
      (l.contains('403') && l.contains('insufficient'))) {
    return t.sync_err_scope_upgrade;
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
