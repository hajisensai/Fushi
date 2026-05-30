import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

HibikiDatabase _testDb() =>
    HibikiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

String _b64(String s) => base64Encode(utf8.encode(s));

void main() {
  test('migrates an active SMB backend into WebDAV', () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);

    await db.setPref('sync_backend_type', 'smb');
    await db.setPref('sync_smb_webdav_url', 'http://nas.local/webdav');
    await db.setPref('sync_smb_username', 'user');
    await db.setPref('sync_smb_password', _b64('secret')); // stored base64
    await db.setPref('sync_smb_host', 'nas.local'); // dead key

    await repo.migrateSmbToWebDav();

    expect(await repo.getBackendType(), SyncBackendType.webDav);
    expect(await repo.getWebDavUrl(), 'http://nas.local/webdav');
    expect(await repo.getWebDavUsername(), 'user');
    expect(await repo.getWebDavPassword(), 'secret'); // decoded round-trip
    // All sync_smb_* keys gone.
    expect(await db.getPref('sync_smb_webdav_url'), isNull);
    expect(await db.getPref('sync_smb_username'), isNull);
    expect(await db.getPref('sync_smb_password'), isNull);
    expect(await db.getPref('sync_smb_host'), isNull);
  });

  test('never overwrites an existing WebDAV config', () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);

    await db.setPref('sync_backend_type', 'smb');
    await db.setPref('sync_webdav_url', 'http://existing/webdav');
    await db.setPref('sync_smb_webdav_url', 'http://smb/webdav');

    await repo.migrateSmbToWebDav();

    expect(await repo.getBackendType(), SyncBackendType.webDav);
    expect(await repo.getWebDavUrl(), 'http://existing/webdav'); // untouched
    expect(await db.getPref('sync_smb_webdav_url'), isNull);
  });

  test('clears dead SMB keys even when the backend is not SMB', () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);

    await db.setPref('sync_backend_type', 'webDav');
    await db.setPref('sync_smb_host', 'ghost');
    await db.setPref('sync_smb_share', 'ghost');
    await db.setPref('sync_smb_domain', 'ghost');

    await repo.migrateSmbToWebDav();

    expect(await repo.getBackendType(), SyncBackendType.webDav); // unchanged
    expect(await db.getPref('sync_smb_host'), isNull);
    expect(await db.getPref('sync_smb_share'), isNull);
    expect(await db.getPref('sync_smb_domain'), isNull);
  });

  test('is a no-op (and idempotent) with no SMB data', () async {
    final HibikiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);

    await db.setPref('sync_backend_type', 'googleDrive');

    await repo.migrateSmbToWebDav();
    await repo.migrateSmbToWebDav(); // idempotent

    expect(await repo.getBackendType(), SyncBackendType.googleDrive);
  });
}
