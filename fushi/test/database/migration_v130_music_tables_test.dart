import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v130：音乐模块 P0 的十张表（docs/specs/2026-10-23-music-module-design.md §10）。
///
/// 迁移只建表 + 索引、不动既有数据，重跑幂等；曲库读写 API（扫描批次 upsert、
/// 软删消失的文件、专辑 / 艺人只列有在库曲目的）在这里钉死。
void main() {
  const List<String> musicTables = <String>[
    'music_tracks',
    'music_albums',
    'music_artists',
    'music_track_credits',
    'music_lyrics',
    'music_videos',
    'music_disc_sources',
    'music_playlists',
    'music_playlist_entries',
    'music_play_events',
  ];

  bool tableExists(sqlite.Database raw, String table) => raw.select(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
    <Object?>[table],
  ).isNotEmpty;

  bool indexExists(sqlite.Database raw, String index) => raw.select(
    "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?",
    <Object?>[index],
  ).isNotEmpty;

  test('v129 → v130 建十张音乐表与索引；重跑幂等、不清数据', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'music_v130',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = '${directory.path}/test.db';
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    await db.getAllTags(); // 触发建库
    await db.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    // 子表先删（music_playlist_entries 外键指向 music_playlists）。
    for (final String table in musicTables.reversed) {
      raw.execute('DROP TABLE $table');
    }
    for (final String table in musicTables) {
      expect(tableExists(raw, table), isFalse);
    }
    raw.execute('PRAGMA user_version = 129');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 138);
    await migrated.writeMusicScanBatch(
      MusicScanBatchWrite(
        tracks: <MusicTracksCompanion>[_track('t1', album: 'a1')],
        albums: <MusicAlbumsCompanion>[_album('a1')],
        artists: const <MusicArtistsCompanion>[],
        credits: const <MusicTrackCreditsCompanion>[],
      ),
    );
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    expect(probe.select('PRAGMA user_version').first.values.first, 138);
    for (final String table in musicTables) {
      expect(tableExists(probe, table), isTrue, reason: table);
    }
    expect(indexExists(probe, 'idx_music_tracks_album'), isTrue);
    expect(indexExists(probe, 'idx_music_play_events_track'), isTrue);
    // 重跑 v130 步：表已在，不得报错、不得清数据。
    probe.execute('PRAGMA user_version = 129');
    probe.dispose();

    final FushiDatabase reopened = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect((await reopened.getMusicTrack('t1'))?.title, 'title-t1');
    await reopened.close();
  });

  group('曲库 API', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('重扫 upsert 不改入库时刻、清软删；署名整组替换', () async {
      await db.writeMusicScanBatch(
        MusicScanBatchWrite(
          tracks: <MusicTracksCompanion>[
            _track('t1', album: 'a1', addedAt: 10),
          ],
          albums: <MusicAlbumsCompanion>[_album('a1')],
          artists: <MusicArtistsCompanion>[_artist('x'), _artist('y')],
          credits: <MusicTrackCreditsCompanion>[
            _credit('t1', 'x'),
            _credit('t1', 'y'),
          ],
        ),
      );
      await db.softDeleteMusicTrack('t1', deletedAt: 50);
      expect(await db.listMusicTracks(), isEmpty);

      await db.writeMusicScanBatch(
        MusicScanBatchWrite(
          tracks: <MusicTracksCompanion>[
            _track('t1', album: 'a1', addedAt: 99, title: 'renamed'),
          ],
          albums: <MusicAlbumsCompanion>[_album('a1')],
          artists: <MusicArtistsCompanion>[_artist('x')],
          credits: <MusicTrackCreditsCompanion>[_credit('t1', 'x')],
        ),
      );
      final MusicTrackRow row = (await db.getMusicTrack('t1'))!;
      expect(row.title, 'renamed');
      expect(row.addedAt, 10, reason: '入库时刻只在首次插入时写');
      expect(row.deletedAt, isNull, reason: '文件重新出现要清软删');
      expect(
        (await db.listMusicArtists()).map((MusicArtistRow a) => a.artistUid),
        <String>['x'],
        reason: '标签里去掉的艺人不再出现在艺人分区',
      );
    });

    test('softDeleteMissingMusicTracks 只软删本来源没见到的曲目', () async {
      await db.writeMusicScanBatch(
        MusicScanBatchWrite(
          tracks: <MusicTracksCompanion>[
            _track('keep', album: 'a1', sourceId: 1),
            _track('gone', album: 'a1', sourceId: 1),
            _track('other', album: 'a2', sourceId: 2),
          ],
          albums: <MusicAlbumsCompanion>[_album('a1'), _album('a2')],
          artists: const <MusicArtistsCompanion>[],
          credits: const <MusicTrackCreditsCompanion>[],
        ),
      );
      final int n = await db.softDeleteMissingMusicTracks(
        sourceId: 1,
        seenTrackUids: <String>{'keep'},
        deletedAt: 7,
      );
      expect(n, 1);
      expect(
        (await db.listMusicTracks()).map((MusicTrackRow t) => t.trackUid),
        unorderedEquals(<String>['keep', 'other']),
      );
    });

    test('专辑分区只列至少有一首在库曲目的专辑', () async {
      await db.writeMusicScanBatch(
        MusicScanBatchWrite(
          tracks: <MusicTracksCompanion>[
            _track('t1', album: 'a1'),
            _track('t2', album: 'a2'),
          ],
          albums: <MusicAlbumsCompanion>[_album('a1'), _album('a2')],
          artists: const <MusicArtistsCompanion>[],
          credits: const <MusicTrackCreditsCompanion>[],
        ),
      );
      await db.softDeleteMusicTrack('t2', deletedAt: 1);
      expect(
        (await db.listMusicAlbums()).map((MusicAlbumRow a) => a.albumUid),
        <String>['a1'],
      );
    });

    test('最近播放按最近一次开始时刻去重排序', () async {
      await db.writeMusicScanBatch(
        MusicScanBatchWrite(
          tracks: <MusicTracksCompanion>[
            _track('t1', album: 'a1'),
            _track('t2', album: 'a1'),
          ],
          albums: <MusicAlbumsCompanion>[_album('a1')],
          artists: const <MusicArtistsCompanion>[],
          credits: const <MusicTrackCreditsCompanion>[],
        ),
      );
      await db.startMusicPlayEvent(trackUid: 't1', startedAt: 1);
      await db.startMusicPlayEvent(trackUid: 't2', startedAt: 2);
      final int id = await db.startMusicPlayEvent(trackUid: 't1', startedAt: 3);
      await db.finishMusicPlayEvent(id, listenedMs: 1000, completed: true);
      expect(
        (await db.listRecentlyPlayedMusicTracks()).map(
          (MusicTrackRow t) => t.trackUid,
        ),
        <String>['t1', 't2'],
      );
    });
  });

  test('四个媒体种类值域都认 music，落库串逐字节冻结', () {
    expect(SourceLibraryKind.tryParse('music'), SourceLibraryKind.music);
    expect(StatSourceKind.tryParse('music'), StatSourceKind.music);
    expect(ActivityMediaKind.tryParse('music'), ActivityMediaKind.music);
    expect(SyncTombstoneKind.tryParse('music'), SyncTombstoneKind.music);
    expect(
      shelfKindsOfActivityMedia(ActivityMediaKind.music),
      isEmpty,
      reason: '音乐曲目不在合集 / 书架域里',
    );
  });
}

MusicTracksCompanion _track(
  String uid, {
  required String album,
  int addedAt = 1,
  int? sourceId,
  String? title,
}) => MusicTracksCompanion.insert(
  trackUid: uid,
  path: '/music/$uid.flac',
  title: title ?? 'title-$uid',
  albumUid: Value<String?>(album),
  sourceId: Value<int?>(sourceId),
  fileMtimeAt: 1,
  fileSize: 1,
  addedAt: addedAt,
);

MusicAlbumsCompanion _album(String uid) => MusicAlbumsCompanion.insert(
  albumUid: uid,
  title: 'album-$uid',
  addedAt: 1,
  updatedAt: 1,
);

MusicArtistsCompanion _artist(String uid) =>
    MusicArtistsCompanion.insert(artistUid: uid, name: uid, addedAt: 1);

MusicTrackCreditsCompanion _credit(String track, String artist) =>
    MusicTrackCreditsCompanion.insert(
      trackUid: track,
      artistUid: artist,
      role: 'artist',
      creditName: artist,
    );
