import 'dart:io';

import 'package:drift/drift.dart' show Value, Variable, QueryRow;
import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v148：新表 `music_remote_tracks`（只能串流的远程曲目加入音乐库 / 本地歌单，反馈
/// 0tRY-D2JgG）。纯新增：升级建表、不碰存量歌单；建过的库幂等跳过。另钉死本地歌单读写
/// API（此前 `music_playlist_entries` 没有任何写路径）与远程曲目的入库 / 移出语义。
void main() {
  Future<String> createDbAt(Directory directory) async {
    final String path = '${directory.path}/test.db';
    final FushiDatabase original = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await original.customSelect('SELECT 1').get();
    await original.close();
    return path;
  }

  bool hasTable(sqlite.Database raw) => raw
      .select(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='music_remote_tracks'",
      )
      .isNotEmpty;

  MusicRemoteTracksCompanion yt(String id, {String title = 'Song'}) =>
      MusicRemoteTracksCompanion(
        trackUid: Value<String>('srv-$id'),
        kind: const Value<String>('youtube'),
        sourceKey: const Value<String>('youtube'),
        itemId: Value<String>(id),
        title: Value<String>(title),
        artist: const Value<String?>('Artist'),
        durationMs: const Value<int?>(200000),
        coverUrl: Value<String?>('https://i.ytimg.com/vi/$id/hq.jpg'),
      );

  List<String> uidsOf(List<MusicPlaylistEntryRow> e) => <String>[
    for (final MusicPlaylistEntryRow r in e) r.trackUid,
  ];
  List<int> positionsOf(List<MusicPlaylistEntryRow> e) => <int>[
    for (final MusicPlaylistEntryRow r in e) r.position,
  ];

  test('v147 → v148：建出远程曲目表，存量歌单原样', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'musremotev148',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('DROP TABLE music_remote_tracks');
    raw.execute(
      'INSERT INTO music_playlists (playlist_uid, name, created_at, '
      "updated_at) VALUES ('p1', 'Old', 1, 1)",
    );
    raw.execute(
      'INSERT INTO music_playlist_entries (playlist_uid, track_uid, '
      "position, added_at) VALUES ('p1', 'local-1', 0, 1)",
    );
    raw.execute('PRAGMA user_version = 147');
    expect(hasTable(raw), isFalse);
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 148);
    await migrated.addMusicRemoteTrackToLibrary(yt('aaaaaaaaaaa'), at: 10);
    expect(
      (await migrated.listMusicRemoteLibraryTracks()).single.itemId,
      'aaaaaaaaaaa',
    );
    expect(uidsOf(await migrated.listMusicPlaylistEntries('p1')), <String>[
      'local-1',
    ]);
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    addTearDown(probe.dispose);
    expect(probe.select('PRAGMA user_version').first.values.first, 148);
    expect(hasTable(probe), isTrue);
  });

  test('v148 步幂等：表已在时跳过，已有行不丢', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'musremotev148idem',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    final FushiDatabase seeded = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await seeded.addMusicRemoteTrackToLibrary(yt('bbbbbbbbbbb'), at: 7);
    await seeded.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('PRAGMA user_version = 147');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(
      (await migrated.getMusicRemoteTrack('srv-bbbbbbbbbbb'))?.libraryAddedAt,
      7,
    );
    await migrated.close();
  });

  group('远程曲目入库语义', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('重复加入不改入库时刻、刷新元数据；移出只清入库时刻、行留着', () async {
      await db.addMusicRemoteTrackToLibrary(yt('ccccccccccc'), at: 10);
      await db.addMusicRemoteTrackToLibrary(
        yt('ccccccccccc', title: 'Renamed'),
        at: 20,
      );
      MusicRemoteTrackRow row = (await db.getMusicRemoteTrack(
        'srv-ccccccccccc',
      ))!;
      expect(row.libraryAddedAt, 10);
      expect(row.createdAt, 10);
      expect(row.updatedAt, 20);
      expect(row.title, 'Renamed');

      await db.removeMusicRemoteTrackFromLibrary('srv-ccccccccccc', at: 30);
      expect(await db.listMusicRemoteLibraryTracks(), isEmpty);
      row = (await db.getMusicRemoteTrack('srv-ccccccccccc'))!;
      expect(row.libraryAddedAt, isNull);
      expect(row.updatedAt, 30);
    });

    test('加进歌单的远程曲目同事务落库，但不因此进音乐库', () async {
      final MusicPlaylistRow p = await db.createMusicPlaylist(
        'Mix',
        at: 5,
        trackUids: <String>['local-1', 'srv-ddddddddddd'],
        remote: <MusicRemoteTracksCompanion>[yt('ddddddddddd')],
      );
      expect(p.name, 'Mix');
      expect(p.playlistUid, hasLength(36));
      final List<MusicPlaylistEntryRow> entries = await db
          .listMusicPlaylistEntries(p.playlistUid);
      expect(uidsOf(entries), <String>['local-1', 'srv-ddddddddddd']);
      expect(positionsOf(entries), <int>[0, 1]);
      expect(
        (await db.listMusicRemoteTracks(<String>['srv-ddddddddddd'])).keys,
        <String>['srv-ddddddddddd'],
      );
      expect(await db.listMusicRemoteLibraryTracks(), isEmpty);
    });

    test('追加接在末尾；删一条后位置前移无空洞；同一首可出现两次', () async {
      final MusicPlaylistRow p = await db.createMusicPlaylist('L', at: 1);
      await db.addMusicPlaylistEntries(p.playlistUid, <String>[
        'a',
        'b',
      ], at: 2);
      await db.addMusicPlaylistEntries(p.playlistUid, <String>['a'], at: 3);
      List<MusicPlaylistEntryRow> e = await db.listMusicPlaylistEntries(
        p.playlistUid,
      );
      expect(uidsOf(e), <String>['a', 'b', 'a']);
      expect((await db.getMusicPlaylist(p.playlistUid))!.updatedAt, 3);
      expect((await db.countMusicPlaylistEntries())[p.playlistUid], 3);

      await db.removeMusicPlaylistEntry(p.playlistUid, e.first.id, at: 4);
      e = await db.listMusicPlaylistEntries(p.playlistUid);
      expect(uidsOf(e), <String>['b', 'a']);
      expect(positionsOf(e), <int>[0, 1]);
      expect((await db.getMusicPlaylist(p.playlistUid))!.updatedAt, 4);
    });

    test('改名推进 updated_at；删除是软删 + 清条目，列表里不再出现', () async {
      final MusicPlaylistRow p = await db.createMusicPlaylist(
        'Old',
        at: 1,
        trackUids: <String>['a'],
      );
      await db.renameMusicPlaylist(p.playlistUid, 'New', at: 2);
      expect((await db.getMusicPlaylist(p.playlistUid))!.name, 'New');
      await db.deleteMusicPlaylist(p.playlistUid, at: 3);
      expect(await db.getMusicPlaylist(p.playlistUid), isNull);
      expect(await db.listMusicPlaylists(), isEmpty);
      expect(await db.listMusicPlaylistEntries(p.playlistUid), isEmpty);
      final QueryRow tomb = await db
          .customSelect(
            'SELECT updated_at, deleted_at FROM music_playlists '
            'WHERE playlist_uid = ?',
            variables: <Variable<Object>>[Variable<String>(p.playlistUid)],
          )
          .getSingle();
      expect(tomb.read<int?>('deleted_at'), 3);
      expect(tomb.read<int>('updated_at'), 3);
    });
  });
}
