import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';
import 'package:fushi_core/fushi_core.dart';

/// v149（反馈 se3Fw8HmOX）：`music_remote_tracks` 新增 `cover_ref` / `album_id` /
/// `artist_refs` 三列——收 Jellyfin / Subsonic 服务器曲目（只存服务器配置身份 + 服务器侧
/// 条目 id + 元数据，封面只存服务器侧引用），并补插件曲目的艺人引用与专辑 id。可空新增、
/// 无回填：v148 的存量行原样保留、三列为 NULL；建表时已带这些列的库幂等跳过。
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

  Set<String> columnsOf(sqlite.Database raw) => <String>{
    for (final sqlite.Row r in raw.select(
      'PRAGMA table_info(music_remote_tracks)',
    ))
      r['name']! as String,
  };

  test('v148 → v149：补出三列，存量远程曲目原样、新列为 NULL', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'musremotev149',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    // 退回 v148 的表形状（没有三列），放一行 v148 写的 YouTube 曲目。
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('DROP TABLE music_remote_tracks');
    raw.execute(
      'CREATE TABLE music_remote_tracks (track_uid TEXT NOT NULL, '
      'kind TEXT NOT NULL, source_key TEXT NOT NULL, item_id TEXT NOT NULL, '
      'title TEXT NOT NULL, artist TEXT NULL, album TEXT NULL, '
      'duration_ms INTEGER NULL, cover_url TEXT NULL, '
      'library_added_at INTEGER NULL, created_at INTEGER NOT NULL, '
      'updated_at INTEGER NOT NULL, PRIMARY KEY (track_uid))',
    );
    raw.execute(
      'INSERT INTO music_remote_tracks (track_uid, kind, source_key, item_id, '
      'title, cover_url, library_added_at, created_at, updated_at) VALUES '
      "('srv-old', 'youtube', 'youtube', 'vid', 'Old', "
      "'https://i.ytimg.com/vi/vid/hq.jpg', 5, 5, 5)",
    );
    raw.execute('PRAGMA user_version = 148');
    expect(columnsOf(raw), isNot(contains('cover_ref')));
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 152);
    final MusicRemoteTrackRow old = (await migrated.getMusicRemoteTrack(
      'srv-old',
    ))!;
    expect(old.title, 'Old');
    expect(old.libraryAddedAt, 5);
    expect(old.coverUrl, 'https://i.ytimg.com/vi/vid/hq.jpg');
    expect(old.coverRef, isNull);
    expect(old.albumId, isNull);
    expect(old.artistRefs, isNull);

    // 新列可写：一首服务器曲目。
    await migrated.addMusicRemoteTrackToLibrary(
      const MusicRemoteTracksCompanion(
        trackUid: Value<String>('srv-new'),
        kind: Value<String>('server'),
        sourceKey: Value<String>('subsonic-1'),
        itemId: Value<String>('tr-1'),
        title: Value<String>('New'),
        coverRef: Value<String?>('al-1'),
        albumId: Value<String?>('al-1'),
      ),
      at: 9,
    );
    final MusicRemoteTrackRow added = (await migrated.getMusicRemoteTrack(
      'srv-new',
    ))!;
    expect(added.kind, 'server');
    expect(added.coverRef, 'al-1');
    expect(added.albumId, 'al-1');
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    addTearDown(probe.dispose);
    expect(probe.select('PRAGMA user_version').first.values.first, 152);
    expect(
      columnsOf(probe),
      containsAll(<String>['cover_ref', 'album_id', 'artist_refs']),
    );
  });

  test('v149 步幂等：列已在（v148 步按当前定义建的表）时跳过，已有值不丢', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'musremotev149idem',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    final FushiDatabase seeded = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await seeded.addMusicRemoteTrackToLibrary(
      const MusicRemoteTracksCompanion(
        trackUid: Value<String>('plg-1'),
        kind: Value<String>('plugin'),
        sourceKey: Value<String>('np'),
        itemId: Value<String>('42'),
        title: Value<String>('Song'),
        albumId: Value<String?>('alb'),
        artistRefs: Value<String?>('[{"name":"A","id":"a1"}]'),
      ),
      at: 7,
    );
    await seeded.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('PRAGMA user_version = 148');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    final MusicRemoteTrackRow row = (await migrated.getMusicRemoteTrack(
      'plg-1',
    ))!;
    expect(row.albumId, 'alb');
    expect(row.artistRefs, '[{"name":"A","id":"a1"}]');
    expect(row.libraryAddedAt, 7);
    await migrated.close();
  });
}
