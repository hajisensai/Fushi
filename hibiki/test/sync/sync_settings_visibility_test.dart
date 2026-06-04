import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_settings_schema.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('isOAuthSyncBackend', () {
    test('true only for cloud OAuth backends (account/sign-in row)', () {
      expect(isOAuthSyncBackend(SyncBackendType.googleDrive), isTrue);
      expect(isOAuthSyncBackend(SyncBackendType.oneDrive), isTrue);
      expect(isOAuthSyncBackend(SyncBackendType.dropbox), isTrue);
      expect(isOAuthSyncBackend(SyncBackendType.webDav), isFalse);
      expect(isOAuthSyncBackend(SyncBackendType.ftp), isFalse);
      expect(isOAuthSyncBackend(SyncBackendType.sftp), isFalse);
      expect(isOAuthSyncBackend(SyncBackendType.hibikiServer), isFalse);
    });

    test('covers every backend type (no orphan after enum changes)', () {
      for (final SyncBackendType t in SyncBackendType.values) {
        // Must not throw for any value; pure total function.
        isOAuthSyncBackend(t);
      }
    });
  });

  group('buildSyncBackupDestination structure', () {
    late SettingsDestination dest;
    setUpAll(() => dest = buildSyncBackupDestination());

    List<String> idsOf(SettingsSection s) =>
        s.items.map((SettingsItem i) => i.id).toList();

    test('regroups into five intent-based sections', () {
      expect(dest.sections, hasLength(5));
    });

    test('group 1 (sync method) holds selector + scoped account/config/LAN',
        () {
      expect(idsOf(dest.sections[0]), <String>[
        'sync.mode',
        'sync.account_status',
        'sync.webdav_config',
        'sync.ftp_config',
        'sync.sftp_config',
        'sync.hibiki_server_config',
        'sync.lan_devices',
      ]);
    });

    test('selector is unconditional; account + LAN are backend-gated', () {
      final SettingsSection method = dest.sections[0];
      SettingsItem byId(String id) =>
          method.items.firstWhere((SettingsItem i) => i.id == id);
      expect(byId('sync.mode').visible, isNull);
      expect(byId('sync.account_status').visible, isNotNull);
      expect(byId('sync.lan_devices').visible, isNotNull);
    });

    test('host-server group is standalone with an explanatory footer', () {
      expect(dest.sections[1].footer, isNotNull);
      expect(idsOf(dest.sections[1]), <String>['sync.server_mode']);
    });

    test('host-server group is backend-gated (Hibiki interconnect only)', () {
      // Hosting only makes sense for the Hibiki P2P backend, so the whole
      // section carries a visibility predicate instead of being always shown.
      expect(dest.sections[1].visible, isNotNull);
    });

    test('content / actions / backup groups remain global', () {
      expect(idsOf(dest.sections[2]), <String>[
        'sync.auto_sync',
        'sync.statistics',
        'sync.audiobook',
        'sync.dictionary',
        'sync.content',
        'sync.audiobook_files',
      ]);
      expect(idsOf(dest.sections[3]),
          <String>['sync.sync_now', 'sync.compare', 'sync.conflicts']);
      expect(idsOf(dest.sections[4]),
          <String>['sync.backup_export', 'sync.backup_import']);
    });

    test('the fake SMB config option is gone', () {
      final allIds = dest.sections
          .expand((SettingsSection s) => s.items)
          .map((SettingsItem i) => i.id)
          .toList();
      expect(allIds, isNot(contains('sync.smb_config')));
    });
  });
}
