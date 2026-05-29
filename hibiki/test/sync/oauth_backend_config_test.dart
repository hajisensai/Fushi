import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/dropbox_sync_backend.dart';
import 'package:hibiki/src/sync/onedrive_sync_backend.dart';

/// The sync settings picker hides OAuth backends whose client ID is still a
/// placeholder (see `_isBackendSelectable` in sync_settings_schema.dart).
/// These tests lock the `isConfigured` contract that filter depends on.
///
/// HBK-AUDIT-146: previously these tests only asserted
/// `isConfigured == isTrue`, which is true by construction once a real client
/// ID is hardcoded — it exercised none of the placeholder-hiding logic the
/// docstring claimed to lock. We now (1) cover the underlying predicate
/// (`!clientId.startsWith('YOUR_')`) against both a placeholder and a real id,
/// and (2) keep the current-state assertion as a genuine regression guard that
/// fails if a shipped key is ever reverted to a `YOUR_...` placeholder.

/// Mirrors the production predicate behind `isConfigured` in
/// dropbox_sync_backend.dart / onedrive_sync_backend.dart:
/// `static bool get isConfigured => !_clientId.startsWith('YOUR_');`.
bool isClientIdConfigured(String clientId) => !clientId.startsWith('YOUR_');

void main() {
  group('isConfigured predicate (placeholder-hiding contract)', () {
    test('placeholder client id reports NOT configured', () {
      expect(isClientIdConfigured('YOUR_DROPBOX_APP_KEY'), isFalse);
      expect(isClientIdConfigured('YOUR_ONEDRIVE_CLIENT_ID'), isFalse);
    });

    test('real client id reports configured', () {
      expect(isClientIdConfigured('lt0ufixv6si14dc'), isTrue);
      expect(
        isClientIdConfigured('49f7e6d1-fab5-48ef-90ab-13ce04986b46'),
        isTrue,
      );
    });
  });

  group('shipped OAuth backends carry real (non-placeholder) client IDs', () {
    test('OneDrive client ID is not a placeholder', () {
      expect(OneDriveSyncBackend.isConfigured, isTrue,
          reason: 'OneDrive client ID was reverted to a YOUR_ placeholder; '
              'the settings picker will hide the backend.');
    });

    test('Dropbox app key is not a placeholder', () {
      expect(DropboxSyncBackend.isConfigured, isTrue,
          reason: 'Dropbox app key was reverted to a YOUR_ placeholder; '
              'the settings picker will hide the backend.');
    });
  });
}
