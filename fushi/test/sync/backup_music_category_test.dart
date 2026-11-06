import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show QueryRow, Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// 「音乐」备份类别（v130）：歌单 + 条目 / 歌词 / MV 绑定 / 播放流随类别走；曲库目录
/// （曲目 / 专辑 …）设备本地、从不出境。合并：歌单 / 歌词 / MV 按 updated_at LWW，
/// 播放流去重并集。
Future<void> _seedUserData(
  FushiDatabase db, {
  required String playlistName,
  required int playlistAt,
  required List<String> entries,
  required String lyricText,
  required int lyricAt,
  required List<int> playStarts,
  Map<String, int> resumeAt = const <String, int>{},
}) async {
  await db
      .into(db.musicPlaylists)
      .insert(
        MusicPlaylistsCompanion.insert(
          playlistUid: 'pl1',
          name: playlistName,
          createdAt: 1,
          updatedAt: playlistAt,
        ),
      );
  for (int i = 0; i < entries.length; i++) {
    await db
        .into(db.musicPlaylistEntries)
        .insert(
          MusicPlaylistEntriesCompanion.insert(
            playlistUid: 'pl1',
            trackUid: entries[i],
            position: i,
            addedAt: 1,
          ),
        );
  }
  await db
      .into(db.musicLyrics)
      .insert(
        MusicLyricsCompanion.insert(
          trackUid: 't1',
          source: 'user',
          format: 'lrc',
          raw: Uint8List.fromList(utf8.encode(lyricText)),
          updatedAt: lyricAt,
        ),
      );
  // 逐曲断点（v145）：trackUid → updated_at，位置取 updated_at × 10 便于认出是哪边的。
  for (final MapEntry<String, int> r in resumeAt.entries) {
    await db.upsertMusicResumePoint(
      r.key,
      positionMs: r.value * 10,
      updatedAt: r.value,
    );
  }
  for (final int s in playStarts) {
    await db.startMusicPlayEvent(
      trackUid: 't1',
      startedAt: s,
      snapshot: MusicPlayEventSnapshot(
        path: 'fushi-music-plugin://np/t1',
        title: 'T1',
        sourceKind: 'plugin_playlist',
        sourceId: 'np/$s',
      ),
    );
  }
}

Future<String> _backupWithMusic(
  Directory root, {
  Set<BackupCategory>? categories,
}) async {
  final String dbDir = p.join(root.path, 'support');
  Directory(dbDir).createSync(recursive: true);
  final FushiDatabase src = FushiDatabase(dbDir);
  await _seedUserData(
    src,
    playlistName: 'Backup list',
    playlistAt: 200,
    entries: <String>['t1', 't2'],
    lyricText: 'backup lyric',
    lyricAt: 50,
    playStarts: <int>[10, 20],
    resumeAt: <String, int>{'r1': 200, 'r2': 50},
  );
  await src.writeMusicScanBatch(
    MusicScanBatchWrite(
      tracks: <MusicTracksCompanion>[
        MusicTracksCompanion.insert(
          trackUid: 'catalog',
          path: '/src/device/a.flac',
          title: 'a',
          fileMtimeAt: 1,
          fileSize: 1,
          addedAt: 1,
          sourceId: const Value<int?>(null),
        ),
      ],
      albums: const <MusicAlbumsCompanion>[],
      artists: const <MusicArtistsCompanion>[],
      credits: const <MusicTrackCreditsCompanion>[],
    ),
  );
  final String zip = p.join(root.path, 'music.zip');
  await BackupService(
    db: src,
    dbDirectory: dbDir,
    appVersion: '3.0.0',
  ).createBackup(zip, categories: categories);
  await src.close();
  return zip;
}

Future<int> _count(FushiDatabase db, String table) async =>
    (await db.customSelect('SELECT COUNT(*) AS c FROM $table').getSingle())
        .read<int>('c');

void main() {
  test('musicUserTables 与 backupTableRules 一致：用户表 follows music，目录表设备本地', () {
    for (final String t in musicUserTables) {
      expect(backupTableRules[t]!.categories, <BackupCategory>{
        BackupCategory.music,
      }, reason: t);
    }
    for (final String t in <String>[
      'music_tracks',
      'music_track_uid_aliases',
      'music_albums',
      'music_artists',
      'music_track_credits',
      'music_disc_sources',
    ]) {
      expect(backupTableRules[t]!.fate, BackupTableFate.deviceLocal, reason: t);
    }
  });

  test('合并导入：歌单 LWW 整组换条目、歌词 LWW、播放流去重并集；目录不出境', () async {
    final Directory srcRoot = await Directory.systemTemp.createTemp('mus_src_');
    addTearDown(() => cleanupTempDir(srcRoot));
    final String zip = await _backupWithMusic(srcRoot);

    final Directory curRoot = await Directory.systemTemp.createTemp('mus_cur_');
    addTearDown(() => cleanupTempDir(curRoot));
    final String curDir = p.join(curRoot.path, 'support');
    Directory(curDir).createSync(recursive: true);
    final FushiDatabase seed = FushiDatabase(curDir);
    // 本机：歌单旧（100 < 200，备份胜出）、歌词新（90 > 50，本机胜出）、一条同刻播放。
    await _seedUserData(
      seed,
      playlistName: 'Local list',
      playlistAt: 100,
      entries: <String>['t9'],
      lyricText: 'local lyric',
      lyricAt: 90,
      playStarts: <int>[20],
      resumeAt: <String, int>{'r1': 100, 'r2': 90, 'r3': 5},
    );
    await seed.close();

    await BackupRestoreService.mergeRestoreBackup(
      dbDirectory: curDir,
      zipPath: zip,
    );

    final FushiDatabase cur = FushiDatabase(curDir);
    addTearDown(cur.close);
    final List<MusicPlaylistRow> lists = await cur.listMusicPlaylists();
    expect(lists.single.name, 'Backup list');
    final List<QueryRow> entries = await cur
        .customSelect(
          "SELECT track_uid FROM music_playlist_entries WHERE playlist_uid='pl1' "
          'ORDER BY position',
        )
        .get();
    expect(entries.map((QueryRow r) => r.read<String>('track_uid')), <String>[
      't1',
      't2',
    ]);
    final QueryRow lyric = await cur
        .customSelect("SELECT raw FROM music_lyrics WHERE track_uid='t1'")
        .getSingle();
    expect(utf8.decode(lyric.read<Uint8List>('raw')), 'local lyric');
    expect(await _count(cur, 'music_play_events'), 2, reason: '20 去重，10 并入');
    final QueryRow merged = await cur
        .customSelect(
          'SELECT path, title, source_kind, source_id FROM music_play_events '
          'WHERE started_at = 10',
        )
        .getSingle();
    expect(
      merged.read<String>('path'),
      'fushi-music-plugin://np/t1',
      reason: 'v139 快照随合并导入带过来（在线曲目的最近播放全靠它）',
    );
    expect(merged.read<String>('title'), 'T1');
    expect(merged.read<String>('source_kind'), 'plugin_playlist');
    expect(merged.read<String>('source_id'), 'np/10');
    // 断点按 updated_at 取较新：r1 备份新（200 > 100），r2 本机新（90 > 50），r3 只在本机。
    expect((await cur.getMusicResumePoint('r1'))?.positionMs, 2000);
    expect((await cur.getMusicResumePoint('r2'))?.positionMs, 900);
    expect((await cur.getMusicResumePoint('r3'))?.positionMs, 50);
    expect(await _count(cur, 'music_tracks'), 0, reason: '曲库目录是设备本地，不随备份来');
  });

  test('合并导入后按本机曲目 uid 别名改指（v145）：备份里挂着本机已并掉的重复曲目 uid '
      '的歌单项 / 播放记录改指胜者', () async {
    final Directory srcRoot = await Directory.systemTemp.createTemp('mus_al_');
    addTearDown(() => cleanupTempDir(srcRoot));
    // 备份：歌单 [t1, t2]，播放流挂 t1。
    final String zip = await _backupWithMusic(srcRoot);

    final Directory curRoot = await Directory.systemTemp.createTemp('mus_alc_');
    addTearDown(() => cleanupTempDir(curRoot));
    final String curDir = p.join(curRoot.path, 'support');
    Directory(curDir).createSync(recursive: true);
    final FushiDatabase seed = FushiDatabase(curDir);
    // 本机曾把重复曲目 t2 并进 win、t1 并进 win1。
    await seed.customStatement(
      'INSERT INTO music_track_uid_aliases (alias_uid, track_uid, created_at) '
      "VALUES ('t2', 'win', 1), ('t1', 'win1', 1)",
    );
    await seed.close();

    await BackupRestoreService.mergeRestoreBackup(
      dbDirectory: curDir,
      zipPath: zip,
    );

    final FushiDatabase cur = FushiDatabase(curDir);
    addTearDown(cur.close);
    final List<QueryRow> entries = await cur
        .customSelect(
          "SELECT track_uid FROM music_playlist_entries WHERE playlist_uid='pl1' "
          'ORDER BY position',
        )
        .get();
    expect(entries.map((QueryRow r) => r.read<String>('track_uid')), <String>[
      'win1',
      'win',
    ]);
    final List<QueryRow> plays = await cur
        .customSelect('SELECT DISTINCT track_uid FROM music_play_events')
        .get();
    expect(plays.map((QueryRow r) => r.read<String>('track_uid')), <String>[
      'win1',
    ]);
    expect(
      await _count(cur, 'music_track_uid_aliases'),
      2,
      reason: '别名是设备本地，合并不动它',
    );
  });

  test('导出不勾「音乐」：用户表在包里清空；导入摘要不出音乐开关', () async {
    final Directory srcRoot = await Directory.systemTemp.createTemp('mus_ex_');
    addTearDown(() => cleanupTempDir(srcRoot));
    final String zip = await _backupWithMusic(
      srcRoot,
      categories: BackupCategory.values
          .where((BackupCategory c) => c != BackupCategory.music)
          .toSet(),
    );
    final BackupContentSummary without =
        await BackupRestoreService.summarizeBackupFile(zip);
    expect(without.has(BackupCategory.music), isFalse);

    final Directory root2 = await Directory.systemTemp.createTemp('mus_ex2_');
    addTearDown(() => cleanupTempDir(root2));
    final String zipWith = await _backupWithMusic(root2);
    final BackupContentSummary withMusic =
        await BackupRestoreService.summarizeBackupFile(zipWith);
    expect(withMusic.has(BackupCategory.music), isTrue);
    expect(
      withMusic.counts[BackupCategory.music],
      8,
      reason: '1 歌单 + 2 条目 + 1 歌词 + 2 播放 + 2 断点',
    );
  });
}
