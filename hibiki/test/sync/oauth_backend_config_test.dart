import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/dropbox_sync_backend.dart';
import 'package:hibiki/src/sync/onedrive_sync_backend.dart';

/// The sync settings picker hides OAuth backends whose client ID is still a
/// placeholder (see `_isBackendSelectable` in sync_settings_schema.dart).
/// These tests lock the `isConfigured` contract that filter depends on.
/// When real credentials are filled in, `isConfigured` flips to true and the
/// matching assertion below should be updated to reflect that the backend is
/// now selectable.
void main() {
  group('OAuth backend isConfigured', () {
    test('OneDrive reports not configured while client ID is a placeholder',
        () {
      expect(OneDriveSyncBackend.isConfigured, isFalse);
    });

    test('Dropbox reports configured once a real app key is filled in', () {
      expect(DropboxSyncBackend.isConfigured, isTrue);
    });
  });
}
