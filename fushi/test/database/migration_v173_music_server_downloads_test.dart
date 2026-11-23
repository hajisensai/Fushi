import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

/// v173：新表 `music_server_downloads`（Jellyfin / Subsonic 曲目的离线副本，设备本地）。
/// 纯新增：升级建表、不碰存量远程曲目；建过的库幂等跳过。另钉死专辑 / 艺人整体入库与
/// 移出（一个事务）、「下载 ⊂ 音乐库」的读写 API。
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
        "AND name='music_server_downloads'",
      )
      .isNotEmpty;

  MusicRemoteTracksCompanion server(String id, {String title = 'Song'}) =>
      MusicRemoteTracksCompanion(
        trackUid: Value<String>('srv-$id'),
        kind: const Value<String>('server'),
        sourceKey: const Value<String>('jf-1'),
        itemId: Value<String>(id),
        title: Value<String>(title),
        album: const Value<String?>('Album'),
        albumId: const Value<String?>('alb'),
        coverRef: const Value<String?>('alb'),
      );

  MusicServerDownloadsCompanion download(String id, String path) =>
      MusicServerDownloadsCompanion(
        trackUid: Value<String>('srv-$id'),
        sourceKey: const Value<String>('jf-1'),
        itemId: Value<String>(id),
        filePath: Value<String>(path),
        codec: const Value<String?>('flac'),
        sizeBytes: const Value<int?>(1234),
      );

  test('v172 → v173：建出离线副本表，存量远程曲目原样', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'musdlv173',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    final FushiDatabase seeded = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await seeded.addMusicRemoteTrackToLibrary(server('a'), at: 5);
    await seeded.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('DROP TABLE music_server_downloads');
    raw.execute('PRAGMA user_version = 172');
    expect(hasTable(raw), isFalse);
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 174);
    expect((await migrated.getMusicRemoteTrack('srv-a'))?.libraryAddedAt, 5);
    await migrated.recordMusicServerDownload(
      download('a', '/music/a.flac'),
      track: server('a'),
      at: 9,
    );
    final MusicServerDownloadRow row = (await migrated
        .listMusicServerDownloadsOf(<String>['srv-a']))['srv-a']!;
    expect(row.filePath, '/music/a.flac');
    expect(row.downloadedAt, 9);
    // 已在库：入库时刻不变。
    expect((await migrated.getMusicRemoteTrack('srv-a'))?.libraryAddedAt, 5);
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    addTearDown(probe.dispose);
    expect(probe.select('PRAGMA user_version').first.values.first, 174);
    expect(hasTable(probe), isTrue);
  });

  test('v173 步幂等：表已在时跳过，已有行不丢', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'musdlv173idem',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);
    final FushiDatabase seeded = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await seeded.recordMusicServerDownload(
      download('b', '/music/b.mp3'),
      track: server('b'),
      at: 3,
    );
    await seeded.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('PRAGMA user_version = 172');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    addTearDown(migrated.close);
    expect(
      (await migrated.listMusicServerDownloadsOf(<String>[
        'srv-b',
      ])).keys.toList(),
      <String>['srv-b'],
    );
  });

  group('专辑 / 艺人整体入库与离线副本', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('整批加入：一个事务，已在库的不改入库时刻', () async {
      await db.addMusicRemoteTrackToLibrary(server('x'), at: 1);
      await db.addMusicRemoteTracksToLibrary(<MusicRemoteTracksCompanion>[
        server('x', title: 'X2'),
        server('y'),
        server('z'),
      ], at: 50);
      expect((await db.getMusicRemoteTrack('srv-x'))?.libraryAddedAt, 1);
      expect((await db.getMusicRemoteTrack('srv-x'))?.title, 'X2');
      expect((await db.getMusicRemoteTrack('srv-y'))?.libraryAddedAt, 50);
      expect(
        await db.musicRemoteLibraryUidsOf(<String>[
          'srv-x',
          'srv-y',
          'srv-z',
          'srv-nope',
        ]),
        <String>{'srv-x', 'srv-y', 'srv-z'},
      );
    });

    test('整批移出只清入库时刻；离线副本留到调用方删（列在「不在库」里）', () async {
      await db.recordMusicServerDownload(
        download('x', '/m/x.flac'),
        track: server('x'),
        at: 1,
      );
      await db.recordMusicServerDownload(
        download('y', '/m/y.flac'),
        track: server('y'),
        at: 1,
      );
      expect(await db.listMusicServerDownloadsOutsideLibrary(), isEmpty);

      await db.removeMusicRemoteTracksFromLibrary(<String>['srv-x'], at: 7);
      final MusicRemoteTrackRow x = (await db.getMusicRemoteTrack('srv-x'))!;
      expect(x.libraryAddedAt, isNull);
      expect(x.updatedAt, 7);
      expect(
        (await db.listMusicServerDownloadsOutsideLibrary())
            .map((MusicServerDownloadRow r) => r.trackUid)
            .toList(),
        <String>['srv-x'],
      );
      expect(
        await db.listMusicServerDownloadsOutsideLibrary(<String>['srv-y']),
        isEmpty,
      );

      final List<MusicServerDownloadRow> gone = await db
          .deleteMusicServerDownloads(<String>['srv-x']);
      expect(gone.single.filePath, '/m/x.flac');
      expect(
        (await db.listMusicServerDownloadsOf(<String>[
          'srv-x',
          'srv-y',
        ])).keys.toSet(),
        <String>{'srv-y'},
      );
    });

    test('入库状态 watch 随写路径更新', () async {
      final Stream<Set<String>> stream = db.watchMusicRemoteLibraryUidsOf(
        <String>['srv-p', 'srv-q'],
      );
      final List<Set<String>> seen = <Set<String>>[];
      final sub = stream.listen(seen.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();
      await db.addMusicRemoteTracksToLibrary(<MusicRemoteTracksCompanion>[
        server('p'),
      ], at: 2);
      await pumpEventQueue();
      await db.removeMusicRemoteTracksFromLibrary(<String>['srv-p'], at: 3);
      await pumpEventQueue();
      expect(seen.first, isEmpty);
      expect(
        seen.any((Set<String> s) => s.length == 1 && s.contains('srv-p')),
        isTrue,
      );
      expect(seen.last, isEmpty);
    });
  });
}
