import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis_auth/googleapis_auth.dart' as auth;
import 'package:hibiki/src/sync/google_drive_auth.dart';

/// Guards the desktop Google Drive auth fix (BUG-034): the session kept dropping
/// on every app restart because the old flow (clientViaUserConsent) never
/// requested offline access, so Google issued no refresh token, and a transient
/// network failure on restore additionally wiped the saved session.
void main() {
  group('desktop auth URL requests a durable refresh token (BUG-034)', () {
    final url =
        GoogleDriveAuth.debugBuildDesktopAuthUrl('http://localhost:1234');

    test('hits Google authorization endpoint', () {
      expect(url.scheme, 'https');
      expect(url.host, 'accounts.google.com');
      expect(url.path, '/o/oauth2/v2/auth');
    });

    test('requests offline access so Google returns a refresh token', () {
      // Without access_type=offline Google never issues a refresh token →
      // the session cannot be restored after a restart (the original bug).
      expect(url.queryParameters['access_type'], 'offline');
    });

    test('forces consent so a refresh token is issued on re-auth too', () {
      // 'consent' guarantees a refresh token even on re-auth; 'select_account'
      // lets multi-account users choose which Google account to use.
      expect(url.queryParameters['prompt'], contains('consent'));
    });

    test('carries the loopback redirect and PKCE challenge', () {
      expect(url.queryParameters['redirect_uri'], 'http://localhost:1234');
      expect(url.queryParameters['response_type'], 'code');
      expect(url.queryParameters['code_challenge_method'], 'S256');
      expect(url.queryParameters['code_challenge'], isNotEmpty);
      // TODO-836: sync now lives in the appDataFolder space (drive.appdata),
      // not the user-visible Drive (drive.file).
      expect(url.queryParameters['scope'], contains('drive.appdata'));
      expect(url.queryParameters['scope'], isNot(contains('drive.file')));
    });
  });

  group('restore only drops the session on a real rejection (BUG-034)', () {
    test('Google rejecting the refresh token (HTTP 400) is fatal', () {
      // invalid_grant → 400; the saved session is genuinely dead.
      expect(
        GoogleDriveAuth.debugIsCredentialsRejected(
          auth.ServerRequestFailedException('invalid_grant',
              statusCode: 400, responseContent: null),
        ),
        isTrue,
      );
    });

    test('HTTP 401 is fatal', () {
      expect(
        GoogleDriveAuth.debugIsCredentialsRejected(
          auth.ServerRequestFailedException('unauthorized',
              statusCode: 401, responseContent: null),
        ),
        isTrue,
      );
    });

    test('HTTP 403 (revoked / project disabled) is fatal', () {
      expect(
        GoogleDriveAuth.debugIsCredentialsRejected(
          auth.ServerRequestFailedException('forbidden',
              statusCode: 403, responseContent: null),
        ),
        isTrue,
      );
    });

    test('access denied is fatal', () {
      expect(
        GoogleDriveAuth.debugIsCredentialsRejected(
          auth.AccessDeniedException('denied'),
        ),
        isTrue,
      );
    });

    test('a transient network failure must NOT wipe the session', () {
      // Offline / blocked direct connection / TLS error behind a restrictive
      // network — keep the still-valid refresh token for the next launch.
      expect(
        GoogleDriveAuth.debugIsCredentialsRejected(
          const SocketException('Connection timed out'),
        ),
        isFalse,
      );
    });

    test('a 5xx server error is treated as transient, not a rejection', () {
      expect(
        GoogleDriveAuth.debugIsCredentialsRejected(
          auth.ServerRequestFailedException('server error',
              statusCode: 503, responseContent: null),
        ),
        isFalse,
      );
    });
  });

  test('source guard: no regression to the offline-less consent flow (BUG-034)',
      () {
    final source =
        File('lib/src/sync/google_drive_auth.dart').readAsStringSync();
    // The offline-less googleapis_auth flow must stay gone. Match the call
    // form (with paren) so the prose mention in the fix comment doesn't count.
    expect(source.contains('clientViaUserConsent('), isFalse,
        reason: 'clientViaUserConsent never sends access_type=offline → no '
            'refresh token → session dies on restart (BUG-034).');
    // The durable-refresh-token wiring must stay in place.
    expect(source.contains("'access_type': 'offline'"), isTrue);
    expect(source.contains("'prompt': 'consent"), isTrue);
    expect(source.contains('obtainAccessCredentialsViaCodeExchange'), isTrue);
    expect(source.contains('runDesktopOAuthLoopback'), isTrue);
    // The restore path must gate the wipe behind a real rejection.
    expect(source.contains('if (_isCredentialsRejected(e)) {'), isTrue,
        reason: 'restoreDesktopAuth must not clear the session on transient '
            'network errors (BUG-034).');
  });
}
