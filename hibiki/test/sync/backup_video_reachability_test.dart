import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/backup_service.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;
import 'temp_dir_cleanup.dart';

// TODO-1261: a backup MERGE must never land a dead "empty video" shell (a
// local-file video whose file never travelled), and the confirm dialog's
// counts must match what the merge actually does. These tests pin both.

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

VideoBooksCompanion _video(String uid, String videoPath, {String? title}) =>
    VideoBooksCompanion.insert(
      bookUid: uid,
      title: title ?? uid,
      videoPath: videoPath,
    );

void main() {
  test(
      'merge SKIPS a local-file video whose file never travelled (no empty '
      'video shell)', () async {
    final curDir = await _tempDir('vr_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = HibikiDatabase(curDir.path);
    await cur.close();

    final srcDir = await _tempDir('vr_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = HibikiDatabase(srcDir.path);
    // A local-file video whose file does not exist → nothing to pack.
    await src.upsertVideoBook(_video('local-vid', '/fake/missing.mp4'));
    // A streaming video (http) is self-contained → must be kept.
    await src.upsertVideoBook(
        _video('stream-vid', 'https://example.com/watch?v=abc'));
    final zipDir = await _tempDir('vr_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    await BackupService.mergeImportBackupFiles(
        dbDirectory: curDir.path, zipPath: zip);

    final after = HibikiDatabase(curDir.path);
    addTearDown(after.close);
    final uids = (await after.allVideoBooks()).map((v) => v.bookUid).toSet();
    // Only the streaming video imported; the dead local shell was skipped.
    expect(uids, <String>{'stream-vid'});
  });

  test('merge IMPORTS a local video whose file travelled with the backup',
      () async {
    final curDir = await _tempDir('vr_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = HibikiDatabase(curDir.path);
    await cur.close();

    // Source device: a real video file under its videos root.
    final srcVideos = await _tempDir('vr_srcvid_');
    addTearDown(() => cleanupTempDir(srcVideos));
    final srcFile = File(p.join(srcVideos.path, 'movie.mp4'));
    await srcFile.writeAsString('VIDEO-BYTES');

    final srcDir = await _tempDir('vr_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = HibikiDatabase(srcDir.path);
    await src.upsertVideoBook(_video('real-vid', srcFile.path));
    final zipDir = await _tempDir('vr_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await BackupService(
      db: src,
      dbDirectory: srcDir.path,
      appVersion: '2.0.0',
    ).exportBackup(zip);
    await src.close();

    final curVideos = await _tempDir('vr_curvid_');
    addTearDown(() => cleanupTempDir(curVideos));
    await BackupService.mergeImportBackupFiles(
      dbDirectory: curDir.path,
      zipPath: zip,
      videosRootDirectory: curVideos.path,
    );

    final after = HibikiDatabase(curDir.path);
    addTearDown(after.close);
    final uids = (await after.allVideoBooks()).map((v) => v.bookUid).toSet();
    expect(uids, <String>{'real-vid'}); // reachable local video imported
  });

  test('previewMergeImport video count equals what the merge actually inserts',
      () async {
    final curDir = await _tempDir('vr_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = HibikiDatabase(curDir.path);
    addTearDown(cur.close);

    final srcDir = await _tempDir('vr_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = HibikiDatabase(srcDir.path);
    await src.upsertVideoBook(_video('local-vid', '/fake/missing.mp4'));
    await src.upsertVideoBook(_video('stream-vid', 'https://example.com/v'));
    final zipDir = await _tempDir('vr_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    final preview = await BackupService.previewMergeImport(
      liveDb: cur,
      dbDirectory: curDir.path,
      zipPath: zip,
    );
    expect(preview != null, true);
    // Preview promises 1 (streaming only); the dead local shell is excluded.
    expect(preview!.newVideoBooks, 1);
    expect(preview.newBooks, 1);
  });

  test(
      'export meta counts usable videos in bookCount (video-only backup is '
      'not reported as 0 books)', () async {
    final srcDir = await _tempDir('vr_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = HibikiDatabase(srcDir.path);
    // Two streaming videos, zero EPUBs.
    await src.upsertVideoBook(_video('v1', 'https://example.com/a'));
    await src.upsertVideoBook(_video('v2', 'https://example.com/b'));
    // A local video with no file must NOT be counted (it won't travel usably).
    await src.upsertVideoBook(_video('v3', '/fake/missing.mp4'));
    // A watch-statistics row so statsCount is non-zero too.
    await src.setVideoWatchStatistic(VideoWatchStatisticsCompanion.insert(
      title: 'v1',
      dateKey: '2026-01-01',
      subtitleChars: 10,
      watchTimeMs: 6000,
      lastModified: 1,
    ));
    final zipDir = await _tempDir('vr_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);

    final meta = await BackupService(
      db: src,
      dbDirectory: srcDir.path,
      appVersion: '2.0.0',
    ).validateBackup(zip);
    await src.close();

    expect(meta != null, true);
    expect(meta!.bookCount, 2); // two usable (streaming) videos, not 0
    expect(meta.statsCount >= 1, true); // video watch stat counted
  });
}
