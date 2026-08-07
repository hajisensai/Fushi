import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// BUG-780: a "keep this device's settings" (importSettings=false) OVERWRITE
/// import — the DEFAULT for the overwrite mode in the UI — used to run
/// `_restoreSettingsLayer` with `DELETE/INSERT ... WHERE key NOT LIKE
/// 'audiobook_pos_%'`. That wholesale-restored EVERY non-progress pref from THIS
/// device's pre-restore snapshot, including `local_audio_dbs` /
/// `audio_source_configs`. So a backup's audio-source registration was wiped and
/// replaced by this device's (usually empty) one: the imported `.db` FILE landed
/// on disk but no source was registered → local audio silently stopped working.
///
/// The fix restores from bak only the SETTINGS rows (+ device-local `sync_*`),
/// letting the audio-source registry (content) follow the backup. This test
/// exercises the real export→overwrite-import path with importSettings=false.
void main() {
  test(
      'keep-settings overwrite import keeps the BACKUP local-audio registry '
      "(not this device's), while pure settings + sync stay local (BUG-780)",
      () async {
    // ── THIS device: an existing DB with a pure app setting, an EMPTY audio
    //    registry, and its own device-local sync backend. ──
    final Directory dst = await Directory.systemTemp.createTemp('bug780_dst_');
    addTearDown(() => cleanupTempDir(dst));
    final String dstDbDir = p.join(dst.path, 'db');
    Directory(dstDbDir).createSync(recursive: true);

    final FushiDatabase curDb = FushiDatabase(dstDbDir);
    await curDb.setPref(
        'test_pure_setting', 'device-value'); // kept from device
    await curDb.setPref(
        'local_audio_dbs', PrefCodec.encode('[]')); // empty registry
    await SyncRepository(curDb).setBackendType(SyncBackendType.webDav);
    await curDb.close();

    // ── A backup from another device: a book + a REGISTERED local-audio db
    //    (with a real file to pack) + a different pure setting. ──
    final Directory src = await Directory.systemTemp.createTemp('bug780_src_');
    addTearDown(() => cleanupTempDir(src));
    final String srcDbDir = p.join(src.path, 'db');
    Directory(srcDbDir).createSync(recursive: true);
    // Internal-copy name so import re-homes it by filename onto this device.
    final String laPath = p.join(srcDbDir, 'local_audio_777.db');
    await File(laPath).writeAsString('FORVO-DB-BYTES');

    final FushiDatabase srcDb = FushiDatabase(srcDbDir);
    await srcDb.setPref('test_pure_setting', 'backup-value'); // must NOT win
    await srcDb.setPref(
      'local_audio_dbs',
      PrefCodec.encode(jsonEncode(<Map<String, Object?>>[
        <String, Object?>{
          'path': laPath,
          'displayName': '声優',
          'enabled': true,
        },
      ])),
    );
    await srcDb.insertEpubBook(EpubBooksCompanion.insert(
      bookKey: 'かがみの孤城',
      title: 'かがみの孤城',
      epubPath: '/fake/kagami.epub',
      extractDir: '/fake/extract',
      chapterCount: 12,
      chaptersJson: '[]',
      importedAt: DateTime.now().millisecondsSinceEpoch,
    ));

    final Directory zipDir =
        await Directory.systemTemp.createTemp('bug780_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final String zipPath = p.join(zipDir.path, 'backup.zip');
    // null categories = export EVERYTHING (packs the local-audio file, keeps the
    // settings rows in the DB blob).
    await BackupService(db: srcDb, dbDirectory: srcDbDir, appVersion: '2.0.0')
        .createBackup(zipPath);
    await srcDb.close();

    // ── Overwrite import KEEPING this device's settings (DB already closed). ──
    await BackupService.restoreBackup(
      dbDirectory: dstDbDir,
      zipPath: zipPath,
      importSettings: false,
    );

    final FushiDatabase after = FushiDatabase(dstDbDir);
    addTearDown(after.close);
    final Map<String, String> prefs = await after.getAllPrefs();

    // Pure setting KEPT from THIS device (backup's value rejected).
    expect(prefs['test_pure_setting'], 'device-value');

    // Device-local sync config KEPT.
    expect(
        await SyncRepository(after).getBackendType(), SyncBackendType.webDav);

    // Content came across from the backup.
    final List<EpubBookRow> books = await after.getAllEpubBooks();
    expect(books.map((EpubBookRow b) => b.title), contains('かがみの孤城'));

    // THE FIX: the audio-source registry FOLLOWS the backup — the imported
    // registration survived instead of being wiped by this device's empty one.
    final List<dynamic> dbs =
        jsonDecode(PrefCodec.decode<String>(prefs['local_audio_dbs']!, '[]'))
            as List<dynamic>;
    expect(dbs, hasLength(1),
        reason: "the backup's local-audio registration must survive");
    expect((dbs.single as Map)['displayName'], '声優');
    // And the .db FILE crossed over + the stored path was re-homed onto this device.
    final String homedPath = (dbs.single as Map)['path'] as String;
    expect(homedPath, startsWith(dstDbDir));
    expect(File(homedPath).existsSync(), isTrue);
  });
}
