import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

/// v176：离线副本行补服务器种类（存量按服务器身份前缀回填）、补发队列表
/// `music_server_pending_actions`、客户端状态表 `music_server_track_states`（都设备本地）。
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

  bool hasTable(sqlite.Database raw, String name) => raw.select(
    "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
    <Object>[name],
  ).isNotEmpty;

  test('v175 → v176：回填 server_kind，建出两张新表，存量副本原样', () async {
    final Directory directory = Directory.systemTemp.createTempSync('mus174');
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);

    // 造一个 v175 形状的库：去掉新列 / 新表，写三行副本（Jellyfin / Subsonic / 认不出）。
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('DROP TABLE music_server_pending_actions');
    raw.execute('DROP TABLE music_server_track_states');
    raw.execute('DROP TABLE music_server_downloads');
    raw.execute(
      'CREATE TABLE music_server_downloads (track_uid TEXT NOT NULL PRIMARY KEY, '
      'source_key TEXT NOT NULL, item_id TEXT NOT NULL, file_path TEXT NOT NULL, '
      'cover_path TEXT NULL, size_bytes INTEGER NULL, codec TEXT NULL, '
      'downloaded_at INTEGER NOT NULL)',
    );
    for (final List<Object> r in <List<Object>>[
      <Object>['srv-a', 'jellyfin:http://jf|u1', 'a', '/m/a.flac'],
      <Object>['srv-b', 'subsonic-7', 'b', '/m/b.mp3'],
      <Object>['srv-c', 'weird', 'c', '/m/c.ogg'],
    ]) {
      raw.execute(
        'INSERT INTO music_server_downloads (track_uid, source_key, item_id, '
        'file_path, downloaded_at) VALUES (?, ?, ?, ?, 1)',
        r,
      );
    }
    raw.execute('PRAGMA user_version = 175');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, kFushiDbSchemaVersion);
    final Map<String, MusicServerDownloadRow> rows = await migrated
        .listMusicServerDownloadsOf(<String>['srv-a', 'srv-b', 'srv-c']);
    expect(rows['srv-a']?.serverKind, 'jellyfin');
    expect(rows['srv-b']?.serverKind, 'subsonic');
    expect(rows['srv-c']?.serverKind, isNull);
    expect(rows['srv-a']?.filePath, '/m/a.flac');
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    addTearDown(probe.dispose);
    expect(probe.select('PRAGMA user_version').first.values.first, kFushiDbSchemaVersion);
    expect(hasTable(probe, 'music_server_pending_actions'), isTrue);
    expect(hasTable(probe, 'music_server_track_states'), isTrue);
  });

  test('v176 步幂等：列 / 表已在时跳过，已有数据不丢', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'mus174idem',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = await createDbAt(directory);
    final FushiDatabase seeded = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await seeded.enqueueMusicServerPendingPlay(
      serverKind: 'jellyfin',
      serverId: 'jf',
      itemId: 'x',
      trackUid: 'srv-x',
      playedAt: 5,
      at: 6,
    );
    await seeded.close();
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('PRAGMA user_version = 175');
    raw.dispose();
    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    addTearDown(migrated.close);
    expect(await migrated.listMusicServerPendingActions(), hasLength(1));
  });

  group('补发队列与客户端状态', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    Future<void> play(String server, String id, int at, {int? created}) =>
        db.enqueueMusicServerPendingPlay(
          serverKind: 'jellyfin',
          serverId: server,
          itemId: id,
          trackUid: 'srv-$id',
          playedAt: at,
          at: created ?? at,
        );

    test('同一次播放只记一条；按播放时刻从旧到新列出', () async {
      await play('jf', 'b', 30);
      await play('jf', 'a', 10);
      await play('jf', 'a', 10);
      await play('ss', 'c', 20);
      final List<MusicServerPendingActionRow> all = await db
          .listMusicServerPendingActions();
      expect(
        all.map((MusicServerPendingActionRow r) => r.itemId).toList(),
        <String>['a', 'c', 'b'],
      );
      expect(
        (await db.listMusicServerPendingActions(serverId: 'jf')).length,
        2,
      );
    });

    test('收藏同一首只留最后一次切换（尝试次数清零）', () async {
      Future<void> fav(bool v, int at) => db.enqueueMusicServerPendingFavorite(
        serverKind: 'subsonic',
        serverId: 'ss',
        itemId: 'x',
        trackUid: 'srv-x',
        favorite: v,
        at: at,
      );
      await fav(true, 1);
      final String key = db.musicServerPendingFavoriteKey('ss', 'x');
      expect(await db.bumpMusicServerPendingAttempt(key, at: 2), 1);
      await fav(false, 3);
      final List<MusicServerPendingActionRow> rows = await db
          .listMusicServerPendingActions();
      expect(rows.single.favorite, isFalse);
      expect(rows.single.attempts, 0);
      expect(rows.single.createdAt, 3);
      // 只删这一版：期间又切换过（入队时刻变了）的不删。
      await db.deleteMusicServerPendingActionIfUnchanged(
        rows.single.copyWith(createdAt: 1),
      );
      expect(await db.listMusicServerPendingActions(), hasLength(1));
      await db.deleteMusicServerPendingActionIfUnchanged(rows.single);
      expect(await db.listMusicServerPendingActions(), isEmpty);
    });

    test('修剪：没配回来的服务器过 TTL 才丢；超上限丢最旧的播放', () async {
      await play('gone', 'old', 1);
      await play('gone', 'new', 900);
      await play('jf', 'p1', 2);
      await play('jf', 'p2', 3);
      await play('jf', 'p3', 4);
      await db.enqueueMusicServerPendingFavorite(
        serverKind: 'jellyfin',
        serverId: 'jf',
        itemId: 'f',
        trackUid: 'srv-f',
        favorite: true,
        at: 0,
      );
      final int dropped = await db.pruneMusicServerPendingActions(
        configuredServerIds: <String>{'jf'},
        orphanBefore: 500,
        cap: 3,
      );
      // 'gone/old' 过了 TTL；剩 5 条 > 3：丢最旧的两条播放（p1、p2），收藏留着。
      expect(dropped, 3);
      expect(
        (await db.listMusicServerPendingActions())
            .map((MusicServerPendingActionRow r) => r.itemId)
            .toSet(),
        <String>{'f', 'p3', 'new'},
      );
    });

    test('客户端状态：收藏与测量分别写、互不覆盖', () async {
      await db.writeMusicServerTrackFavorite(
        trackUid: 'srv-x',
        serverKind: 'jellyfin',
        serverId: 'jf',
        itemId: 'x',
        favorite: true,
        at: 1,
      );
      await db.writeMusicServerTrackMeasuredLoudness(
        trackUid: 'srv-x',
        serverKind: 'jellyfin',
        serverId: 'jf',
        itemId: 'x',
        gain: -4.5,
        peak: 0.8,
        at: 2,
      );
      final MusicServerTrackStateRow row = (await db.getMusicServerTrackState(
        'srv-x',
      ))!;
      expect(row.favorite, isTrue);
      expect(row.favoriteAt, 1);
      expect(row.measuredTrackGain, -4.5);
      expect(row.measuredTrackPeak, 0.8);
      expect(row.loudnessMeasuredAt, 2);
      expect(row.updatedAt, 2);
    });

    test('离线副本记录带服务器种类', () async {
      await db.recordMusicServerDownload(
        const MusicServerDownloadsCompanion(
          trackUid: Value<String>('srv-d'),
          sourceKey: Value<String>('jf'),
          itemId: Value<String>('d'),
          serverKind: Value<String?>('jellyfin'),
          filePath: Value<String>('/m/d.flac'),
        ),
        track: const MusicRemoteTracksCompanion(
          trackUid: Value<String>('srv-d'),
          kind: Value<String>('server'),
          sourceKey: Value<String>('jf'),
          itemId: Value<String>('d'),
          title: Value<String>('D'),
        ),
        at: 4,
      );
      expect(
        (await db.listMusicServerDownloadsOf(<String>[
          'srv-d',
        ]))['srv-d']?.serverKind,
        'jellyfin',
      );
    });
  });
}
