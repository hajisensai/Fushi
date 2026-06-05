import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart' as auth;
import 'package:hibiki/src/sync/google_drive_handler.dart';

void main() {
  group('googleDriveErrorIsUnauthorized (BUG-060)', () {
    test(
        'classifies the www-authenticate AccessDeniedException as refreshable '
        '— the exact error users saw before the fix', () {
      // Verbatim message googleapis_auth throws from authenticatedClient.send()
      // when the access token has expired (auth_http_utils.dart). This is NOT a
      // drive.DetailedApiRequestError, so before BUG-060 the refresh-and-retry
      // branch never fired and this surfaced as a raw sync failure.
      final error = auth.AccessDeniedException(
        'Access was denied (www-authenticate header was: Bearer '
        'realm="https://accounts.google.com/", error="invalid_token").',
      );
      expect(googleDriveErrorIsUnauthorized(error), isTrue);
    });

    test('classifies a DetailedApiRequestError(401) as refreshable', () {
      expect(
        googleDriveErrorIsUnauthorized(
            drive.DetailedApiRequestError(401, 'Invalid Credentials')),
        isTrue,
      );
    });

    test('classifies a ServerRequestFailedException(401) as refreshable', () {
      final error = auth.ServerRequestFailedException(
        'token rejected',
        statusCode: 401,
        responseContent: null,
      );
      expect(googleDriveErrorIsUnauthorized(error), isTrue);
    });

    test('does NOT treat a non-401 DetailedApiRequestError as refreshable', () {
      expect(
        googleDriveErrorIsUnauthorized(
            drive.DetailedApiRequestError(404, 'File not found')),
        isFalse,
      );
      expect(
        googleDriveErrorIsUnauthorized(
            drive.DetailedApiRequestError(403, 'Rate limit exceeded')),
        isFalse,
      );
    });

    test('does NOT treat a non-401 ServerRequestFailedException as refreshable',
        () {
      final error = auth.ServerRequestFailedException(
        'server error',
        statusCode: 500,
        responseContent: null,
      );
      expect(googleDriveErrorIsUnauthorized(error), isFalse);
    });

    test('does NOT treat an unrelated error (e.g. network) as refreshable', () {
      expect(
        googleDriveErrorIsUnauthorized(
            const SocketException('Connection refused')),
        isFalse,
      );
      expect(googleDriveErrorIsUnauthorized(StateError('boom')), isFalse);
    });
  });
}
