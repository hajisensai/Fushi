import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/backup_service.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

String _b64(String s) => base64Encode(utf8.encode(s));

Future<Directory> _tempDir(String prefix) =>
    Directory.systemTemp.createTemp(prefix);

void main() {
  test('import preserves this device sync config, takes content from backup',
      () async {
    // ── This device: a configured WebDAV account + behavior flag + cache ──
    final currentDir = await _tempDir('hibiki_cur_');
    addTearDown(() => currentDir.delete(recursive: true));
    final curDb = HibikiDatabase(currentDir.path);
    final curRepo = SyncRepository(curDb);
    await curRepo.setBackendType(SyncBackendType.webDav);
    await curRepo.setWebDavUrl('https://local.example/dav');
    await curRepo.setWebDavPassword('localpw'); // base64-stored secret
    await curRepo.setAutoSyncEnabled(true); // behavior flag (local)
    await curRepo.setRootFolderId('local-root'); // folder cache (local)
    await curDb.close();

    // ── A backup from ANOTHER device with different config + a book ──
    final srcDir = await _tempDir('hibiki_src_');
    addTearDown(() => srcDir.delete(recursive: true));
    final srcDb = HibikiDatabase(srcDir.path);
    final srcRepo = SyncRepository(srcDb);
    await srcRepo.setBackendType(SyncBackendType.ftp);
    await srcRepo.setWebDavUrl('https://backup.example/dav');
    await srcRepo.setWebDavPassword('backuppw');
    await srcRepo.setAutoSyncEnabled(false); // backup's behavior flag
    await srcRepo.setRootFolderId('backup-root');
    await srcDb.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: 'かがみの孤城',
      title: 'かがみの孤城',
      epubPath: '/fake/kagami.epub',
      extractDir: '/fake/extract',
      chapterCount: 12,
      chaptersJson: '[]',
      importedAt: DateTime.now().millisecondsSinceEpoch,
    ));
    final zipDir = await _tempDir('hibiki_zip_');
    addTearDown(() => zipDir.delete(recursive: true));
    final zipPath = '${zipDir.path}/backup.zip';
    await BackupService(
      db: srcDb,
      dbDirectory: srcDir.path,
      appVersion: '2.0.0',
    ).exportBackup(zipPath); // strips secrets from the copy
    await srcDb.close();

    // ── Import the backup into this device (DB already closed) ──
    await BackupService.importBackupFiles(
      dbDirectory: currentDir.path,
      zipPath: zipPath,
    );

    final afterDb = HibikiDatabase(currentDir.path);
    addTearDown(afterDb.close);
    final afterRepo = SyncRepository(afterDb);

    // Device-local config preserved (NOT the backup's):
    expect(await afterRepo.getBackendType(), SyncBackendType.webDav);
    expect(await afterRepo.getWebDavUrl(), 'https://local.example/dav');
    expect(await afterRepo.getWebDavPassword(), 'localpw'); // secret survived

    // Behavior flag + content come FROM the backup:
    expect(await afterRepo.isAutoSyncEnabled(), isFalse);
    final books = await afterDb.getAllEpubBooks();
    expect(books, hasLength(1));
    expect(books.single.title, 'かがみの孤城');

    // Folder cache cleared (stale, belonged to backup account) → rebuild later:
    expect(await afterDb.getPref('sync_root_folder_id'), isNull);

    // Sidecar + pre-restore copy cleaned up (no disk leak):
    expect(File('${currentDir.path}/hibiki.db.sync-preserve.json').existsSync(),
        isFalse);
    expect(File('${currentDir.path}/hibiki.db.pre-restore.bak').existsSync(),
        isFalse);
  });

  test('recoverPendingImport re-applies a leftover sidecar then clears it',
      () async {
    final dir = await _tempDir('hibiki_recover_');
    addTearDown(() => dir.delete(recursive: true));

    // Simulate a DB whose sync config was wiped by a crashed import.
    final db = HibikiDatabase(dir.path);
    await SyncRepository(db).setRootFolderId('stale-root');
    await db.close();

    // Sidecar left behind by the crashed import (raw stored values).
    await File('${dir.path}/hibiki.db.sync-preserve.json').writeAsString(
      jsonEncode(<String, String>{
        'sync_backend_type': 'dropbox',
        'sync_webdav_password': _b64('recovered'),
      }),
    );

    await BackupService.recoverPendingImport(dir.path);

    final db2 = HibikiDatabase(dir.path);
    addTearDown(db2.close);
    final repo = SyncRepository(db2);
    expect(await repo.getBackendType(), SyncBackendType.dropbox);
    expect(await repo.getWebDavPassword(), 'recovered');
    expect(await db2.getPref('sync_root_folder_id'), isNull); // cache cleared
    expect(
        File('${dir.path}/hibiki.db.sync-preserve.json').existsSync(), isFalse);
  });
}
