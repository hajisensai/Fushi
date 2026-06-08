import 'dart:io';

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
        'sync.local_audio',
        'sync.content',
        'sync.audiobook_files',
      ]);
      expect(idsOf(dest.sections[3]), <String>[
        'sync.server_mode_note',
        'sync.sync_now',
        'sync.compare',
      ]);
      expect(idsOf(dest.sections[4]),
          <String>['sync.backup_export', 'sync.backup_import']);
    });

    test('manual-sync actions are gated on server mode (BUG-084)', () {
      // A pure Hibiki host has no outbound sync, so "sync now" / "compare" must
      // be hidden in server mode and an explanatory note shown instead — every
      // one of the three carries a visibility predicate (none is unconditional).
      final SettingsSection actions = dest.sections[3];
      SettingsItem byId(String id) =>
          actions.items.firstWhere((SettingsItem i) => i.id == id);
      expect(byId('sync.sync_now').visible, isNotNull,
          reason: 'sync_now must be hidden when hosting as a server');
      expect(byId('sync.compare').visible, isNotNull,
          reason: 'compare must be hidden when hosting as a server');
      expect(byId('sync.server_mode_note').visible, isNotNull,
          reason: 'the server-mode note shows only while hosting');
    });

    test('the action gates key off the hosting-interconnect role (BUG-084)',
        () {
      // Source guard: the gates must branch on _isHostingInterconnect, which
      // requires BOTH serverEnabled AND the hibikiServer backend — so a stale
      // serverEnabled flag left from a past interconnect session can't hide
      // sync-now on a cloud backend (observed: serverEnabled=true while
      // backendType=googleDrive).
      final String src =
          File('lib/src/sync/sync_settings_schema.dart').readAsStringSync();
      final int noteAt = src.indexOf("id: 'sync.server_mode_note'");
      final int nowAt = src.indexOf("id: 'sync.sync_now'");
      final int compareAt = src.indexOf("id: 'sync.compare'");
      expect(noteAt, greaterThanOrEqualTo(0));
      for (final int at in <int>[noteAt, nowAt, compareAt]) {
        expect(src.substring(at, at + 200), contains('_isHostingInterconnect'),
            reason: 'manual-sync gate must use the hosting-interconnect role');
      }
      // The helper itself must require both conditions (not serverEnabled alone).
      final int helperAt = src.indexOf('bool _isHostingInterconnect(');
      expect(helperAt, greaterThanOrEqualTo(0));
      final String helper = src.substring(helperAt, helperAt + 200);
      expect(helper, contains('serverEnabled'));
      expect(helper, contains('SyncBackendType.hibikiServer'),
          reason: 'hosting role must also require the interconnect backend');
    });

    test('server-mode explanatory note uses compact row layout', () {
      final String src =
          File('lib/src/sync/sync_settings_schema.dart').readAsStringSync();
      final int noteAt = src.indexOf("id: 'sync.server_mode_note'");
      final int syncNowAt = src.indexOf("id: 'sync.sync_now'");
      expect(noteAt, greaterThanOrEqualTo(0));
      expect(syncNowAt, greaterThan(noteAt));

      final String noteBlock = src.substring(noteAt, syncNowAt);
      expect(noteBlock, contains('AdaptiveSettingsRow('));
      expect(noteBlock, isNot(contains('controlBelow: true')),
          reason: '说明行没有下方控件，不应预留控件行高度');
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
