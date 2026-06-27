import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart' as auth;
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/sync/google_drive_handler.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_error_messages.dart';

/// TODO-045: Google Drive "登录后 401" surfaced as the raw English
/// `invalid_client` text (or a misleading "sign-in expired" message). The
/// `_friendlyClause` gate used to bail on any message containing the substring
/// `credentials`, which swallowed googleapis_auth's
/// "Failed to obtain access credentials. Error: invalid_client ... 401" before
/// it could reach the 401 mapping.
///
/// These tests assert the three distinct outcomes by comparing against the
/// localized getter itself (language-agnostic — no hardcoded English wording).
void main() {
  group('friendlySyncError — invalid_client / 401 disambiguation', () {
    // The verbatim message googleapis_auth throws from a token exchange when the
    // client secret is wrong (e.g. a CI build that shipped the placeholder).
    const String invalidClientMsg =
        'Failed to obtain access credentials. Error: invalid_client '
        'Unauthorized Status code:401';

    test('invalid_client (the exact 401 users saw) → "client invalid" message',
        () {
      final SyncAuthError error = SyncAuthError(invalidClientMsg);
      expect(friendlySyncError(error), equals(t.sync_err_invalid_client));
      expect(friendlySyncErrorDetail(error), equals(t.sync_err_invalid_client));
    });

    test('invalid_client is NOT mislabeled as "sign-in expired"', () {
      final SyncAuthError error = SyncAuthError(invalidClientMsg);
      expect(friendlySyncError(error), isNot(equals(t.sync_err_auth_expired)));
    });

    test('a genuine expired/401 token → "sign-in expired" message', () {
      final SyncAuthError error =
          SyncAuthError('Invalid Credentials (401 Unauthorized)');
      // This message contains "Credentials" + "401" but NOT invalid_client, so
      // it must map to the expired-auth clause, not the invalid_client one.
      expect(friendlySyncError(error), equals(t.sync_err_auth_expired));
      expect(
          friendlySyncError(error), isNot(equals(t.sync_err_invalid_client)));
    });

    test('placeholder fail-fast marker → "not configured" message', () {
      final SyncAuthError error = SyncAuthError(
          'sync_credentials_not_configured: this build has no Google desktop '
          'OAuth client secret (placeholder shipped)');
      expect(friendlySyncError(error), equals(t.sync_err_not_configured));
      expect(friendlySyncError(error), isNot(equals(t.sync_err_auth_expired)));
    });

    test('a bare invalid_grant (refresh token revoked) → "sign-in expired"',
        () {
      final SyncAuthError error = SyncAuthError('invalid_grant: Token expired');
      expect(friendlySyncError(error), equals(t.sync_err_auth_expired));
    });

    // Removing the bare `credentials` substring from the not-configured gate
    // must NOT regress the existing backend config errors. "... credentials not
    // configured" still hits the (now narrowed) gate and surfaces the raw
    // readable reason; "credentials not set" falls through to the raw message
    // too (it is neither an invalid_client nor a 401 auth/sign/token error).
    for (final String raw in <String>[
      'FTP credentials not configured',
      'WebDAV credentials not configured',
      'FTP credentials not set',
    ]) {
      test('backend config error "$raw" surfaces the raw readable reason', () {
        final SyncAuthError error = SyncAuthError(raw);
        expect(friendlySyncError(error), equals(t.sync_error(message: raw)));
        expect(
            friendlySyncError(error), isNot(equals(t.sync_err_auth_expired)));
        expect(
            friendlySyncError(error), isNot(equals(t.sync_err_invalid_client)));
      });
    }
  });

  // TODO-836: a 403 insufficient_scope (sync scope changed drive.file →
  // drive.appdata, old grant insufficient) must map to the dedicated
  // "permissions changed, sign in again" clause — and must NOT be mislabeled as
  // "sign-in expired" even though the www-authenticate string can contain
  // 'unauthorized'. This pins B2: the insufficient_scope branch runs BEFORE the
  // 401 branch.
  group('friendlySyncError — insufficient_scope (TODO-836)', () {
    // The marker GoogleDriveHandler throws once it detects the 403.
    const String scopeMarker =
        'insufficient_scope: re-consent required (scope upgraded to '
        'drive.appdata)';

    test('insufficient_scope marker → scope-upgrade message', () {
      final SyncAuthError error = SyncAuthError(scopeMarker);
      expect(friendlySyncError(error), equals(t.sync_err_scope_upgrade));
      expect(friendlySyncErrorDetail(error), equals(t.sync_err_scope_upgrade));
    });

    test(
        'insufficient_scope is NOT mislabeled as "sign-in expired" '
        '(B2 ordering)', () {
      // A verbatim 403 www-authenticate string carrying BOTH insufficient_scope
      // AND unauthorized: the scope branch must win because it is checked first.
      final SyncAuthError error = SyncAuthError(
          'Access was denied (www-authenticate header was: Bearer '
          'error="insufficient_scope") 403 unauthorized');
      expect(friendlySyncError(error), equals(t.sync_err_scope_upgrade));
      expect(friendlySyncError(error), isNot(equals(t.sync_err_auth_expired)));
    });

    test('a 403 insufficient permission (alt wording) → scope-upgrade', () {
      final SyncBackendError error =
          SyncBackendError('403 insufficient permissions for this request');
      expect(friendlySyncError(error), equals(t.sync_err_scope_upgrade));
    });

    test('a plain 401 expired token is still "sign-in expired", not scope', () {
      final SyncAuthError error =
          SyncAuthError('Invalid Credentials (401 Unauthorized)');
      expect(friendlySyncError(error), equals(t.sync_err_auth_expired));
      expect(friendlySyncError(error), isNot(equals(t.sync_err_scope_upgrade)));
    });
  });

  // TODO-836: pure predicate that classifies a 403 insufficient_scope so _call
  // can skip the pointless refresh+retry and throw the stable 403 marker.
  group('googleDriveErrorIsInsufficientScope (TODO-836)', () {
    test('403 DetailedApiRequestError with insufficient_scope → true', () {
      expect(
        googleDriveErrorIsInsufficientScope(
            drive.DetailedApiRequestError(403, 'insufficient_scope')),
        isTrue,
      );
    });

    test('403 with insufficientPermissions wording → true', () {
      expect(
        googleDriveErrorIsInsufficientScope(
            drive.DetailedApiRequestError(403, 'insufficientPermissions')),
        isTrue,
      );
    });

    test('a 401 is NOT insufficient_scope', () {
      expect(
        googleDriveErrorIsInsufficientScope(
            drive.DetailedApiRequestError(401, 'insufficient_scope')),
        isFalse,
      );
    });

    test('a 403 WITHOUT insufficient_scope (e.g. rate limit) → false', () {
      expect(
        googleDriveErrorIsInsufficientScope(
            drive.DetailedApiRequestError(403, 'Rate limit exceeded')),
        isFalse,
      );
    });

    test('AccessDeniedException carrying insufficient_scope → true', () {
      expect(
        googleDriveErrorIsInsufficientScope(auth.AccessDeniedException(
            'Access was denied (www-authenticate header was: Bearer '
            'error="insufficient_scope").')),
        isTrue,
      );
    });

    test('AccessDeniedException WITHOUT insufficient_scope (plain 401) → false',
        () {
      expect(
        googleDriveErrorIsInsufficientScope(auth.AccessDeniedException(
            'Access was denied (www-authenticate header was: Bearer '
            'error="invalid_token").')),
        isFalse,
      );
    });
  });
}
