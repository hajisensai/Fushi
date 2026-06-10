import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/google_drive_auth.dart';

/// TODO-045: a desktop build that shipped the placeholder OAuth secret (CI
/// builds, or a clone that never filled google_oauth_secret.dart) used to run
/// the whole browser consent flow and only THEN fail with `invalid_client` 401,
/// confusing the user with a "sign-in expired" snackbar. `authenticate()` now
/// fails fast — before opening any browser — with the
/// `sync_credentials_not_configured` marker that sync_error_messages.dart maps
/// to the friendly "not configured in this build" message.
void main() {
  group('GoogleDriveAuth placeholder fail-fast (TODO-045)', () {
    test(
        'authenticate() throws the not-configured marker on a placeholder build '
        'instead of opening the browser', () async {
      // The committed google_oauth_secret.dart carries the placeholder default,
      // so host test runs reflect a CI/desktop build without a real secret.
      // (Skip on mobile platforms where the desktop branch is not taken.)
      if (GoogleDriveAuth.useMobileAuth) {
        return;
      }
      expect(GoogleDriveAuth.desktopCredentialsConfigured, isFalse,
          reason: 'this test environment is expected to carry the placeholder '
              'secret; a real secret was leaked into the committed file');

      await expectLater(
        () => GoogleDriveAuth.instance.authenticate(),
        throwsA(
          isA<GoogleDriveAuthError>().having(
            (GoogleDriveAuthError e) => e.message,
            'message',
            contains('sync_credentials_not_configured'),
          ),
        ),
      );
    });

    test('desktopCredentialsConfigured rejects the placeholder on desktop', () {
      // Pure-contract guard: the predicate must reject the exact placeholder
      // string baked into google_oauth_secret(.example).dart. On mobile the
      // desktop secret is irrelevant, so the predicate is not asserted there.
      if (GoogleDriveAuth.useMobileAuth) return;
      expect(GoogleDriveAuth.desktopCredentialsConfigured, isFalse);
    });
  });

  group('source guard: fail-fast precedes the browser loopback', () {
    test(
        'authenticate() checks desktopCredentialsConfigured before '
        'runDesktopOAuthLoopback', () {
      final File src = File('lib/src/sync/google_drive_auth.dart');
      expect(src.existsSync(), isTrue,
          reason: 'run from the hibiki/ package root');
      final String body = src.readAsStringSync();

      final int guardIdx = body.indexOf('!desktopCredentialsConfigured');
      final int loopbackIdx = body.indexOf('runDesktopOAuthLoopback');
      expect(guardIdx, greaterThanOrEqualTo(0),
          reason: 'the placeholder fail-fast guard was removed; the browser '
              'flow would run before invalid_client 401 (TODO-045)');
      expect(loopbackIdx, greaterThanOrEqualTo(0));
      expect(guardIdx, lessThan(loopbackIdx),
          reason: 'the credentials check must run BEFORE the browser loopback '
              'so we never open a browser on a misconfigured build');
    });
  });
}
