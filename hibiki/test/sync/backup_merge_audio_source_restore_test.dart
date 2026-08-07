import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'temp_dir_cleanup.dart';

/// Regression: a MERGE import used to drop the audio-source registry prefs
/// (`audio_source_configs` / `local_audio_dbs`) because "preferences are device
/// settings, kept non-merge". But those are CONTENT config — the local-audio
/// `.db` files they point at DO travel in the backup — so on a merge the files
/// were copied yet left orphaned and "音频来源" silently never restored. The
/// merge now adopts the backup's audio-source prefs when the device has none,
/// and re-homes the embedded paths onto this device's support dir.
void main() {
  test('MERGE restores audio-source prefs + re-homes their paths', () async {
    // ── source "device": one local-audio DB + its registry prefs ──────
    final Directory srcRoot =
        await Directory.systemTemp.createTemp('audsrc_src_');
    addTearDown(() => cleanupTempDir(srcRoot));
    final String srcDbDir = p.join(srcRoot.path, 'support');
    Directory(srcDbDir).createSync(recursive: true);
    final String srcLadb = p.join(srcDbDir, 'local_audio_123.db');
    File(srcLadb).writeAsStringSync('LADB');
    final String srcLadbJson = srcLadb.replaceAll(r'\', r'\\');

    final HibikiDatabase src = HibikiDatabase(srcDbDir);
    await src.setPref('local_audio_dbs',
        's:[{"path":"$srcLadbJson","displayName":"x","enabled":true}]');
    await src.setPref('audio_source_configs',
        'j:[{"kind":"localAudio","enabled":true,"label":"x","path":"$srcLadbJson"}]');
    final Directory zipDir =
        await Directory.systemTemp.createTemp('audsrc_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final String zip = p.join(zipDir.path, 'b.zip');
    await BackupService(db: src, dbDirectory: srcDbDir, appVersion: '2.0.0')
        .createBackup(zip);
    await src.close();

    // ── fresh target "device": an empty-placeholder registry (like a
    //    freshly-started app) — the bare NOT-EXISTS-on-key guard would have
    //    left this untouched, so the empty-list case must be handled. ──
    final Directory curRoot =
        await Directory.systemTemp.createTemp('audsrc_cur_');
    addTearDown(() => cleanupTempDir(curRoot));
    final String curDbDir = p.join(curRoot.path, 'support');
    Directory(curDbDir).createSync(recursive: true);
    final HibikiDatabase seed = HibikiDatabase(curDbDir);
    await seed.setPref('local_audio_dbs', 's:[]');
    await seed.setPref('audio_source_configs', 'j:[]');
    await seed.close();

    await BackupService.mergeRestoreBackup(
      dbDirectory: curDbDir,
      zipPath: zip,
    );

    final HibikiDatabase cur = HibikiDatabase(curDbDir);
    addTearDown(cur.close);
    final String? audioCfg = await cur.getPref('audio_source_configs');
    final String? localAudio = await cur.getPref('local_audio_dbs');

    // The registry prefs are restored (were empty placeholders before).
    expect(audioCfg, isNotNull);
    expect(localAudio, isNotNull);
    expect(audioCfg, contains('localAudio'));
    // The local-audio DB file travelled and was copied into this device's dir.
    expect(File(p.join(curDbDir, 'local_audio_123.db')).existsSync(), isTrue);
    // Paths are re-homed onto THIS device's support dir, not the source's.
    // Compare slash-agnostically (the pref stores JSON-escaped backslashes).
    String flat(String s) => s.replaceAll(r'\', '/').replaceAll('//', '/');
    final String curName = p.basename(curRoot.path); // audsrc_cur_XXXX
    final String srcName = p.basename(srcRoot.path); // audsrc_src_XXXX
    expect(flat(audioCfg!), contains(curName));
    expect(flat(localAudio!), contains(curName));
    expect(flat(audioCfg), isNot(contains(srcName)));
  });

  test('MERGE keeps the device\'s own non-empty audio-source list', () async {
    // Device already has its own audio source → merge must not clobber it.
    final Directory srcRoot =
        await Directory.systemTemp.createTemp('audkeep_src_');
    addTearDown(() => cleanupTempDir(srcRoot));
    final String srcDbDir = p.join(srcRoot.path, 'support');
    Directory(srcDbDir).createSync(recursive: true);
    final HibikiDatabase src = HibikiDatabase(srcDbDir);
    await src.setPref('audio_source_configs',
        'j:[{"kind":"localAudio","label":"FROM_BACKUP"}]');
    final Directory zipDir =
        await Directory.systemTemp.createTemp('audkeep_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final String zip = p.join(zipDir.path, 'b.zip');
    await BackupService(db: src, dbDirectory: srcDbDir, appVersion: '2.0.0')
        .createBackup(zip);
    await src.close();

    final Directory curRoot =
        await Directory.systemTemp.createTemp('audkeep_cur_');
    addTearDown(() => cleanupTempDir(curRoot));
    final String curDbDir = p.join(curRoot.path, 'support');
    Directory(curDbDir).createSync(recursive: true);
    final HibikiDatabase seed = HibikiDatabase(curDbDir);
    await seed.setPref('audio_source_configs',
        'j:[{"kind":"localAudio","label":"DEVICE_OWN"}]');
    await seed.close();

    await BackupService.mergeRestoreBackup(
      dbDirectory: curDbDir,
      zipPath: zip,
    );

    final HibikiDatabase cur = HibikiDatabase(curDbDir);
    addTearDown(cur.close);
    final String? audioCfg = await cur.getPref('audio_source_configs');
    expect(audioCfg, contains('DEVICE_OWN'));
    expect(audioCfg, isNot(contains('FROM_BACKUP')));
  });
}
