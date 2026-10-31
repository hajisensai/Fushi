import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v139：`music_play_events` 加播放项快照（path / cue 起止 / 标题 / 艺人 / 专辑 /
/// 时长 / 封面）与播放来源（source_kind / source_id / source_title / source_cover）。
/// 在线插件曲目不进 `music_tracks`，最近播放靠快照显示与重播；来源驱动「最近播放的
/// 歌单 / 专辑」。
void main() {
  const List<String> newColumns = <String>[
    'path',
    'cue_start_ms',
    'cue_end_ms',
    'title',
    'artist',
    'album',
    'album_uid',
    'duration_ms',
    'cover_path',
    'source_kind',
    'source_id',
    'source_title',
    'source_cover',
  ];

  Set<String> columnsOf(sqlite.Database raw) => <String>{
    for (final sqlite.Row row in raw.select(
      "PRAGMA table_info('music_play_events')",
    ))
      row['name'] as String,
  };

  Future<String> createDbAt(Directory directory) async {
    final String path = '${directory.path}/test.db';
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    await db.customSelect('SELECT 1').get();
    await db.close();
    return path;
  }

  test('v138 → v139 加快照与来源列；存量行保持 NULL；重跑幂等', () async {
    final Directory directory = Directory.systemTemp.createTempSync('music139');
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    // 退回 v138 形态：重建一张只有旧四列的表，带一条存量事件。
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('DROP TABLE music_play_events');
    raw.execute(
      'CREATE TABLE music_play_events ('
      'id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, '
      'track_uid TEXT NOT NULL, started_at INTEGER NOT NULL, '
      'listened_ms INTEGER NOT NULL DEFAULT 0, '
      'completed INTEGER NOT NULL DEFAULT 0 CHECK (completed IN (0, 1)))',
    );
    raw.execute(
      'INSERT INTO music_play_events (track_uid, started_at, listened_ms, '
      "completed) VALUES ('old', 10, 5, 1)",
    );
    raw.execute('PRAGMA user_version = 138');
    expect(columnsOf(raw), isNot(contains('source_kind')));
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 140);
    final MusicPlayEventRow old = await migrated
        .select(migrated.musicPlayEvents)
        .getSingle();
    expect(old.trackUid, 'old');
    expect(old.listenedMs, 5);
    expect(old.completed, isTrue);
    expect(old.path, isNull);
    expect(old.sourceKind, isNull);
    // 存量事件没快照、曲库里也没这首：最近播放里不出现（不显示一行空白）。
    expect(await migrated.listRecentMusicPlays(), isEmpty);
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    expect(probe.select('PRAGMA user_version').first.values.first, 140);
    expect(columnsOf(probe), containsAll(newColumns));
    // 重跑 v139 步：列已在，不得报错。
    probe.execute('PRAGMA user_version = 138');
    probe.dispose();
    final FushiDatabase again = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(await again.select(again.musicPlayEvents).get(), hasLength(1));
    await again.close();
  });

  group('最近播放查询', () {
    late Directory directory;
    late FushiDatabase db;

    setUp(() async {
      directory = Directory.systemTemp.createTempSync('music139q');
      db = FushiDatabase.atFile(
        '${directory.path}/test.db',
        isMainProcess: false,
      );
      await db.writeMusicScanBatch(
        MusicScanBatchWrite(
          tracks: <MusicTracksCompanion>[
            _track('local1', album: 'a1'),
            _track('local2', album: 'a1'),
            _track('gone', album: 'a1'),
          ],
          albums: <MusicAlbumsCompanion>[_album('a1')],
          artists: const <MusicArtistsCompanion>[],
          credits: const <MusicTrackCreditsCompanion>[],
        ),
      );
      await db.customStatement(
        "UPDATE music_tracks SET deleted_at = 1 WHERE track_uid = 'gone'",
      );
    });

    tearDown(() async {
      await db.close();
      directory.deleteSync(recursive: true);
    });

    test('在线曲目靠快照留下；本地曲目 join 曲库；按曲目去重取最近一次', () async {
      // local1 播两次，第二次（t=50）晚于 plugin（t=40）。
      await db.startMusicPlayEvent(trackUid: 'local1', startedAt: 10);
      await db.startMusicPlayEvent(
        trackUid: 'plg1',
        startedAt: 40,
        snapshot: const MusicPlayEventSnapshot(
          path: 'fushi-music-plugin://demo/123',
          title: '夜に駆ける',
          artist: 'YOASOBI',
          album: 'THE BOOK',
          durationMs: 261000,
          coverPath: 'https://img.example/cover.jpg',
          sourceKind: 'plugin_playlist',
          sourceId: 'demo/pl9',
          sourceTitle: '我喜欢的音乐',
          sourceCover: 'https://img.example/pl.jpg',
        ),
      );
      await db.startMusicPlayEvent(
        trackUid: 'local1',
        startedAt: 50,
        snapshot: const MusicPlayEventSnapshot(
          path: '/music/local1.flac',
          title: 'snapshot-title',
          sourceKind: 'album',
          sourceId: 'a1',
        ),
      );
      // 存量（无快照）事件：曲库里在 → 留；曲库里软删且无快照 → 丢。
      await db.startMusicPlayEvent(trackUid: 'local2', startedAt: 30);
      await db.startMusicPlayEvent(trackUid: 'gone', startedAt: 60);
      // 不在曲库但有快照 → 靠快照留下。
      await db.startMusicPlayEvent(
        trackUid: 'nolib',
        startedAt: 20,
        snapshot: const MusicPlayEventSnapshot(
          path: '/music/nolib.flac',
          title: 'nolib',
        ),
      );

      final List<MusicRecentPlay> plays = await db.listRecentMusicPlays();
      expect(
        <String>[for (final MusicRecentPlay p in plays) p.trackUid],
        <String>['local1', 'plg1', 'local2', 'nolib'],
      );
      final MusicRecentPlay local1 = plays[0];
      expect(local1.lastPlayedAt, 50);
      expect(local1.track?.title, 'title-local1', reason: '曲库行为准');
      expect(local1.album?.albumUid, 'a1');
      expect(local1.event.sourceKind, 'album');

      final MusicRecentPlay plugin = plays[1];
      expect(plugin.track, isNull);
      expect(plugin.event.path, 'fushi-music-plugin://demo/123');
      expect(plugin.event.title, '夜に駆ける');
      expect(plugin.event.durationMs, 261000);
      expect(plugin.event.coverPath, 'https://img.example/cover.jpg');

      expect(plays[2].track?.trackUid, 'local2');
      expect(plays[3].track, isNull);

      // 过滤在 SQL 里：被丢的 'gone' 不占 limit 名额。
      final List<MusicRecentPlay> top2 = await db.listRecentMusicPlays(
        limit: 2,
      );
      expect(
        <String>[for (final MusicRecentPlay p in top2) p.trackUid],
        <String>['local1', 'plg1'],
      );
      expect(await db.listRecentMusicPlays(limit: 0), isEmpty);
    });

    test('来源按 (kind, id) 去重，标题 / 封面取最近一次；kinds 过滤', () async {
      Future<void> play(
        String uid,
        int at,
        String? kind,
        String? id,
        String? title,
      ) => db.startMusicPlayEvent(
        trackUid: uid,
        startedAt: at,
        snapshot: MusicPlayEventSnapshot(
          path: '/x/$uid',
          title: uid,
          sourceKind: kind,
          sourceId: id,
          sourceTitle: title,
          sourceCover: title == null ? null : 'cover-$title',
        ),
      );

      await play('t1', 10, 'album', 'a1', '旧名');
      await play('t2', 20, 'plugin_playlist', 'demo/pl9', '歌单');
      await play('t3', 30, 'album', 'a1', '新名');
      await play('t4', 40, null, null, null); // 来源未知：不进来源列表
      await play('t5', 25, 'playlist', 'p1', '本地歌单');
      // 同 id 不同 kind 是两个来源。
      await play('t6', 5, 'plugin_album', 'a1', '插件专辑');

      final List<MusicRecentSource> sources = await db.listRecentMusicSources();
      expect(
        <String>[
          for (final MusicRecentSource s in sources) '${s.kind}:${s.id}',
        ],
        <String>[
          'album:a1',
          'playlist:p1',
          'plugin_playlist:demo/pl9',
          'plugin_album:a1',
        ],
      );
      expect(sources.first.title, '新名');
      expect(sources.first.cover, 'cover-新名');
      expect(sources.first.lastPlayedAt, 30);

      final List<MusicRecentSource> onlyPlaylists = await db
          .listRecentMusicSources(
            kinds: <String>{'playlist', 'plugin_playlist'},
          );
      expect(
        <String>[for (final MusicRecentSource s in onlyPlaylists) s.id],
        <String>['p1', 'demo/pl9'],
      );
      expect(await db.listRecentMusicSources(kinds: <String>{}), isEmpty);
      expect(await db.listRecentMusicSources(limit: 1), hasLength(1));
    });

    test('kind 为 null 时 sourceId 不落库', () async {
      await db.startMusicPlayEvent(
        trackUid: 'x',
        startedAt: 1,
        snapshot: const MusicPlayEventSnapshot(path: '/x', sourceId: 'orphan'),
      );
      final MusicPlayEventRow row = await db
          .select(db.musicPlayEvents)
          .getSingle();
      expect(row.sourceId, isNull);
    });
  });
}

MusicTracksCompanion _track(String uid, {required String album}) =>
    MusicTracksCompanion.insert(
      trackUid: uid,
      path: '/music/$uid.flac',
      title: 'title-$uid',
      albumUid: Value<String?>(album),
      fileMtimeAt: 1,
      fileSize: 1,
      addedAt: 1,
    );

MusicAlbumsCompanion _album(String uid) => MusicAlbumsCompanion.insert(
  albumUid: uid,
  title: 'album-$uid',
  addedAt: 1,
  updatedAt: 1,
);
