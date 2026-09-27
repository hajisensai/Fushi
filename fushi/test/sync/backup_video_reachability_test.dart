import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'temp_dir_cleanup.dart';

// TODO-1261: a backup MERGE must never land a dead "empty video" shell (a
// local-file video whose file never travelled), and the confirm dialog's
// counts must match what the merge actually does. These tests pin both.

Future<Directory> _tempDir(String prefix) =>
    Directory.systemTemp.createTemp(prefix);

Future<void> _exportZip(
  FushiDatabase srcDb,
  String srcDir,
  String zipPath,
) async {
  await BackupService(db: srcDb, dbDirectory: srcDir, appVersion: '2.0.0')
      .createBackup(zipPath);
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
    final cur = FushiDatabase(curDir.path);
    await cur.close();

    final srcDir = await _tempDir('vr_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = FushiDatabase(srcDir.path);
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

    await BackupRestoreService.mergeRestoreBackup(
        dbDirectory: curDir.path, zipPath: zip);

    final after = FushiDatabase(curDir.path);
    addTearDown(after.close);
    final uids = (await after.allVideoBooks()).map((v) => v.bookUid).toSet();
    // Only the streaming video imported; the dead local shell was skipped.
    expect(uids, <String>{'stream-vid'});
  });

  test('merge IMPORTS a local video whose file travelled with the backup',
      () async {
    final curDir = await _tempDir('vr_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);
    await cur.close();

    // Source device: a real video file under its videos root.
    final srcVideos = await _tempDir('vr_srcvid_');
    addTearDown(() => cleanupTempDir(srcVideos));
    final srcFile = File(p.join(srcVideos.path, 'movie.mp4'));
    await srcFile.writeAsString('VIDEO-BYTES');

    final srcDir = await _tempDir('vr_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = FushiDatabase(srcDir.path);
    await src.upsertVideoBook(_video('real-vid', srcFile.path));
    final zipDir = await _tempDir('vr_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await BackupService(
      db: src,
      dbDirectory: srcDir.path,
      appVersion: '2.0.0',
    ).createBackup(zip);
    await src.close();

    final curVideos = await _tempDir('vr_curvid_');
    addTearDown(() => cleanupTempDir(curVideos));
    await BackupRestoreService.mergeRestoreBackup(
      dbDirectory: curDir.path,
      zipPath: zip,
      videosRootDirectory: curVideos.path,
    );

    final after = FushiDatabase(curDir.path);
    addTearDown(after.close);
    final uids = (await after.allVideoBooks()).map((v) => v.bookUid).toSet();
    expect(uids, <String>{'real-vid'}); // reachable local video imported
  });

  test('previewMergeRestore video count equals what the merge actually inserts',
      () async {
    final curDir = await _tempDir('vr_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);
    addTearDown(cur.close);

    final srcDir = await _tempDir('vr_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = FushiDatabase(srcDir.path);
    await src.upsertVideoBook(_video('local-vid', '/fake/missing.mp4'));
    await src.upsertVideoBook(_video('stream-vid', 'https://example.com/v'));
    final zipDir = await _tempDir('vr_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    final preview = await BackupRestoreService.previewMergeRestore(
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
    final src = FushiDatabase(srcDir.path);
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

    final meta = await BackupRestoreService.validateBackup(zip);
    await src.close();

    expect(meta != null, true);
    expect(meta!.bookCount, 2); // two usable (streaming) videos, not 0
    expect(meta.statsCount >= 1, true); // video watch stat counted
  });

  test(
      'anime-source rows (online video source episodes) are reachable like '
      'streams: exported, counted, previewed and merged', () async {
    final curDir = await _tempDir('vr_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);
    addTearDown(cur.close);

    final srcDir = await _tempDir('vr_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = FushiDatabase(srcDir.path);
    await src.upsertVideoBook(_video('local-vid', '/fake/missing.mp4'));
    await src.upsertVideoBook(_video(
        'anime-source:pkg:42:/ep/1', 'anime-source://pkg/42/Show - E01'));
    await src.upsertVideoBook(_video(
        'anime-source:pkg:42:/ep/2', 'ANIME-SOURCE://pkg/42/Show - E02'));
    final zipDir = await _tempDir('vr_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    final meta = await BackupRestoreService.validateBackup(zip);
    expect(meta!.bookCount, 2); // both online episodes, not the dead local

    final preview = await BackupRestoreService.previewMergeRestore(
      liveDb: cur,
      dbDirectory: curDir.path,
      zipPath: zip,
    );
    expect(preview!.newVideoBooks, 2);
    await cur.close();

    await BackupRestoreService.mergeRestoreBackup(
        dbDirectory: curDir.path, zipPath: zip);
    final after = FushiDatabase(curDir.path);
    addTearDown(after.close);
    final uids = (await after.allVideoBooks()).map((v) => v.bookUid).toSet();
    expect(uids, <String>{
      'anime-source:pkg:42:/ep/1',
      'anime-source:pkg:42:/ep/2',
    });
  });

  // IPTV 频道（M3U 导入）的 videoPath 是 rtsp / rtmp / udp 等直播协议地址：与
  // http(s) 一样自包含、按 URL 重开。导出计数（Dart 判据）与合并 / 预览（SQL
  // 谓词）必须同样认它们，否则频道在合并时被当成「文件没随包的本地视频」丢掉。
  test(
      'merge + preview treat IPTV live-protocol channels (rtsp / udp / RTMP) '
      'as reachable streaming books', () async {
    final curDir = await _tempDir('vr_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);

    final srcDir = await _tempDir('vr_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = FushiDatabase(srcDir.path);
    await src.upsertVideoBook(_video('ch-rtsp', 'rtsp://10.0.0.1:554/live/1'));
    await src.upsertVideoBook(_video('ch-udp', 'udp://@239.0.0.1:1234'));
    // 协议大小写不敏感：Dart 判据小写化比较，SQLite LIKE 对 ASCII 不分大小写。
    await src.upsertVideoBook(_video('ch-rtmp', 'RTMP://cdn.example/live/x'));
    // 对照：文件不存在的本地视频 / 本地 `.strm` 都不随包 → 仍然不可达。
    await src.upsertVideoBook(_video('local-vid', '/fake/missing.mp4'));
    await src.upsertVideoBook(_video('local-strm', '/fake/missing.strm'));
    final zipDir = await _tempDir('vr_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    final meta = await BackupRestoreService.validateBackup(zip);
    expect(meta != null, true);
    expect(meta!.bookCount, 3, reason: '三个频道都算随包可用的视频');

    final preview = await BackupRestoreService.previewMergeRestore(
      liveDb: cur,
      dbDirectory: curDir.path,
      zipPath: zip,
    );
    expect(preview != null, true);
    expect(preview!.newVideoBooks, 3);
    await cur.close();

    await BackupRestoreService.mergeRestoreBackup(
        dbDirectory: curDir.path, zipPath: zip);
    final after = FushiDatabase(curDir.path);
    addTearDown(after.close);
    final uids = (await after.allVideoBooks()).map((v) => v.bookUid).toSet();
    expect(uids, <String>{'ch-rtsp', 'ch-udp', 'ch-rtmp'});
  });

  test('a local .strm pointer file is packed and merged like a local video',
      () async {
    final curDir = await _tempDir('vr_cur_');
    addTearDown(() => cleanupTempDir(curDir));
    final cur = FushiDatabase(curDir.path);
    await cur.close();

    // 本地 `.strm` 是磁盘上的真实文件（一行流地址）：不属于「网络流」，照常随包。
    final srcVideos = await _tempDir('vr_srcvid_');
    addTearDown(() => cleanupTempDir(srcVideos));
    final strm = File(p.join(srcVideos.path, 'channel.strm'));
    await strm.writeAsString('https://example.com/live.m3u8\n');

    final srcDir = await _tempDir('vr_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final src = FushiDatabase(srcDir.path);
    await src.upsertVideoBook(_video('strm-vid', strm.path));
    final zipDir = await _tempDir('vr_zip_');
    addTearDown(() => cleanupTempDir(zipDir));
    final zip = p.join(zipDir.path, 'b.zip');
    await _exportZip(src, srcDir.path, zip);
    await src.close();

    final meta = await BackupRestoreService.validateBackup(zip);
    expect(meta!.videoFiles.keys, contains(strm.path));

    final curVideos = await _tempDir('vr_curvid_');
    addTearDown(() => cleanupTempDir(curVideos));
    await BackupRestoreService.mergeRestoreBackup(
      dbDirectory: curDir.path,
      zipPath: zip,
      videosRootDirectory: curVideos.path,
    );
    final after = FushiDatabase(curDir.path);
    addTearDown(after.close);
    final uids = (await after.allVideoBooks()).map((v) => v.bookUid).toSet();
    expect(uids, <String>{'strm-vid'});
  });
}
