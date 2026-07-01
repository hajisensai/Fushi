import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/backup_service.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;
import 'temp_dir_cleanup.dart';

/// End-to-end proof that a MERGE import now content-merges the
/// `favorite_sentences` preference blob through the wired
/// BackupMergeEngine -> AggregateMergeService path. Before TODO-1056 phase A
/// this blob was never merged (favorite sentences are a pref JSON list, not a
/// table, so the ATTACH SQL merge could not touch them) and the backup's
/// sentences were silently dropped.
Future<Directory> _tempDir(String prefix) =>
    Directory.systemTemp.createTemp(prefix);

Future<void> _exportZip(
  HibikiDatabase srcDb,
  String srcDir,
  String zipPath,
) async {
  await BackupService(db: srcDb, dbDirectory: srcDir, appVersion: '2.0.0')
      .exportBackup(zipPath);
}

void main() {
  test('merge import content-merges favorite_sentences (union + dedupe)',
      () async {
    final Directory curDir = await _tempDir('fs_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final HibikiDatabase cur = HibikiDatabase(curDir.path);
    final FavoriteSentenceRepository curRepo = FavoriteSentenceRepository(cur);
    // Device has one local-only sentence and one it SHARES (by content) with
    // the backup but under a different (earlier) createdAt / id.
    await curRepo.add(FavoriteSentence(
      id: 'hl_local_only',
      text: 'ローカル限定',
      bookTitle: 'BookA',
      bookKey: 'a',
      sectionIndex: 0,
      normCharOffset: 5,
      createdAt: DateTime.fromMillisecondsSinceEpoch(100),
    ));
    await curRepo.add(FavoriteSentence(
      id: 'hl_shared_local',
      text: '共有文',
      bookTitle: 'BookB',
      bookKey: 'b',
      sectionIndex: 1,
      normCharOffset: 10,
      createdAt: DateTime.fromMillisecondsSinceEpoch(200),
    ));
    await cur.close();

    final Directory srcDir = await _tempDir('fs_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final HibikiDatabase src = HibikiDatabase(srcDir.path);
    final FavoriteSentenceRepository srcRepo = FavoriteSentenceRepository(src);
    // Backup has the SAME shared sentence (later createdAt, different id ->
    // must dedupe to the device's earlier one) plus a backup-only sentence.
    await srcRepo.add(FavoriteSentence(
      id: 'hl_shared_backup',
      text: '共有文',
      bookTitle: 'BookB',
      bookKey: 'b',
      sectionIndex: 1,
      normCharOffset: 10,
      createdAt: DateTime.fromMillisecondsSinceEpoch(900),
    ));
    await srcRepo.add(FavoriteSentence(
      id: 'hl_backup_only',
      text: 'バックアップ限定',
      bookTitle: 'BookC',
      bookKey: 'c',
      sectionIndex: 2,
      normCharOffset: 20,
      createdAt: DateTime.fromMillisecondsSinceEpoch(500),
    ));
    final Directory zipDir = await _tempDir('fs_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final String zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    await BackupService.mergeImportBackupFiles(
        dbDirectory: curDir.path, zipPath: zip);
    // Re-import the SAME backup -> must stay idempotent (no duplicates).
    await BackupService.mergeImportBackupFiles(
        dbDirectory: curDir.path, zipPath: zip);

    final HibikiDatabase after = HibikiDatabase(curDir.path);
    addTearDown(after.close);
    final List<FavoriteSentence> all =
        await FavoriteSentenceRepository(after).getAll();
    // Union: local-only + shared (deduped to one) + backup-only = 3.
    expect(all.length, 3);
    final Set<String> texts = all.map((FavoriteSentence s) => s.text).toSet();
    expect(texts, <String>{'ローカル限定', '共有文', 'バックアップ限定'});
    // The shared sentence kept the EARLIER (device) createdAt/id.
    final FavoriteSentence shared =
        all.firstWhere((FavoriteSentence s) => s.text == '共有文');
    expect(shared.id, 'hl_shared_local');
    expect(shared.createdAt.millisecondsSinceEpoch, 200);
    // Sorted newest-first (createdAt desc): backup-only(500) > shared(200) >
    // local(100).
    expect(all.map((FavoriteSentence s) => s.text).toList(),
        <String>['バックアップ限定', '共有文', 'ローカル限定']);

    // The stored blob is well-formed JSON (repository re-readable).
    final String? raw = await after.getPref('favorite_sentences');
    expect(raw, isNotNull);
    expect(jsonDecode(raw!) as List<dynamic>, hasLength(3));
  });

  test('merge import with no favorite_sentences in backup leaves device blob',
      () async {
    final Directory curDir = await _tempDir('fs_cur2_');
    addTearDown(() => cleanupTempDir(curDir));
    final HibikiDatabase cur = HibikiDatabase(curDir.path);
    await FavoriteSentenceRepository(cur).add(FavoriteSentence(
      id: 'hl_keep',
      text: '残す',
      bookTitle: 'BookA',
      bookKey: 'a',
      sectionIndex: 0,
      normCharOffset: 1,
      createdAt: DateTime.fromMillisecondsSinceEpoch(100),
    ));
    await cur.close();

    final Directory srcDir = await _tempDir('fs_src2_');
    addTearDown(() => cleanupTempDir(srcDir));
    final HibikiDatabase src = HibikiDatabase(srcDir.path); // no fav sentences
    final Directory zipDir = await _tempDir('fs_zip2_');
    addTearDown(() => cleanupTempDir(zipDir));
    final String zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    await BackupService.mergeImportBackupFiles(
        dbDirectory: curDir.path, zipPath: zip);

    final HibikiDatabase after = HibikiDatabase(curDir.path);
    addTearDown(after.close);
    final List<FavoriteSentence> all =
        await FavoriteSentenceRepository(after).getAll();
    expect(all.length, 1);
    expect(all.single.text, '残す'); // device sentence untouched
  });
}
