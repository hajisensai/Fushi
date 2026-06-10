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
        'isDesktopSecretConfigured rejects the placeholder but accepts a real '
        'secret', () {
      // Environment-independent contract: feed the predicate the exact
      // placeholder string and a representative real GOCSPX- secret directly,
      // so the rejection logic is verified regardless of whichever secret this
      // machine / build compiled in (a configured desktop build carries a real
      // GOCSPX- secret, a CI/placeholder build carries the placeholder).
      expect(
        GoogleDriveAuth.isDesktopSecretConfigured(
          GoogleDriveAuth.debugPlaceholderClientSecret,
        ),
        isFalse,
        reason: 'the committed placeholder must be treated as "not configured"',
      );
      expect(
        GoogleDriveAuth.isDesktopSecretConfigured(''),
        isFalse,
        reason:
            'an empty secret (e.g. an explicit empty --dart-define) is also '
            'not configured',
      );
      expect(
        GoogleDriveAuth.isDesktopSecretConfigured('GOCSPX-aRealLookingSecret'),
        isTrue,
        reason: 'a real GOCSPX- secret must be treated as configured',
      );
    });

    test(
        'authenticate() throws the not-configured marker on a placeholder build '
        'instead of opening the browser', () async {
      // This end-to-end path can only be exercised on a build that actually
      // ships the placeholder (CI / a clone that never filled the secret); on a
      // configured desktop build authenticate() would legitimately drive the
      // real browser loopback, so skip it there rather than assert a false
      // expectation. The pure-predicate test above covers the rejection logic
      // on every machine.
      if (GoogleDriveAuth.useMobileAuth ||
          GoogleDriveAuth.desktopCredentialsConfigured) {
        return;
      }

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
