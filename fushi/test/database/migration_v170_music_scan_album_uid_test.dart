import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

/// v170：`music_tracks.scan_album_uid`——扫描时按标签算出的专辑 uid（归组前的原始归属，
/// HBK-AUDIT-027）。同一张 CD 只有部分曲目写了专辑艺人时（BUG-5164）的「同目录同名」
/// 并组改写的是生效专辑 `album_uid`，原始归属不动，组里艺人变了能退回。
void main() {
  test('v169 → v170：加列、存量回填为当前 album_uid，并整库归组一次（存量拆开的专辑并回）；'
      '重跑幂等', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'music_scan_album_v170',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = '${directory.path}/test.db';
    final FushiDatabase original = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await original.writeMusicScanBatch(_splitCd());
    await original.close();

    // 退回 v169 的样子：没有原始归属列，也没有归组（album_uid 就是按标签算的）。
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('UPDATE music_tracks SET album_uid = scan_album_uid');
    raw.execute('ALTER TABLE music_tracks DROP COLUMN scan_album_uid');
    raw.execute('PRAGMA user_version = 169');
    expect(
      raw
          .select("SELECT album_uid FROM music_tracks WHERE track_uid = 'h2'")
          .single
          .values
          .single,
      'dir-uid',
    );
    raw.dispose();

    FushiDatabase migrated = FushiDatabase.atFile(path, isMainProcess: false);
    expect(migrated.schemaVersion, 174);
    Future<void> expectGrouped(FushiDatabase db) async {
      final MusicTrackRow h1 = (await db.getMusicTrack('h1'))!;
      final MusicTrackRow h2 = (await db.getMusicTrack('h2'))!;
      expect(h1.albumUid, 'x-uid');
      expect(h1.scanAlbumUid, 'x-uid');
      expect(h2.albumUid, 'x-uid', reason: '存量拆开的同一张盘并回带艺人的那张');
      expect(h2.scanAlbumUid, 'dir-uid', reason: '原始归属保留按标签算的值');
    }

    await expectGrouped(migrated);
    await migrated.close();

    final sqlite.Database again = sqlite.sqlite3.open(path);
    again.execute('PRAGMA user_version = 169');
    again.dispose();
    migrated = FushiDatabase.atFile(path, isMainProcess: false);
    await expectGrouped(migrated);
    await migrated.close();
  });

  group('落库即归组（同一事务，只看改动到的目录）', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('一个批次落完就已经并好，不依赖扫描收尾（中途中断也不留拆开的状态）', () async {
      await db.writeMusicScanBatch(_splitCd());
      final MusicTrackRow h2 = (await db.getMusicTrack('h2'))!;
      expect(h2.albumUid, 'x-uid');
      expect(h2.scanAlbumUid, 'dir-uid');
    });

    test('并入的曲目被重新解析（改了别的标签）：仍按原始归属重算，不被旧的生效专辑钉死', () async {
      await db.writeMusicScanBatch(_splitCd());
      // 只重写 h2（同一 uid，标签没写专辑艺人）：批次里只有它，组里另一首没变。
      await db.writeMusicScanBatch(
        MusicScanBatchWrite(
          tracks: <MusicTracksCompanion>[_track('h2', 'dir-uid', 'renamed')],
          albums: <MusicAlbumsCompanion>[_album('dir-uid', null)],
          artists: const <MusicArtistsCompanion>[],
          credits: const <MusicTrackCreditsCompanion>[],
        ),
      );
      final MusicTrackRow h2 = (await db.getMusicTrack('h2'))!;
      expect(h2.title, 'renamed');
      expect(h2.albumUid, 'x-uid');
      expect(h2.scanAlbumUid, 'dir-uid');
    });

    test('用户「从音乐库移除」带艺人的那首：文件还在、标签照旧，同盘其它曲目不换专辑', () async {
      await db.writeMusicScanBatch(_splitCd());
      await db.hideMusicTracks(<String>['h1'], at: 5);
      // 再扫一次同目录（h2 重新解析）：判据仍算上墓碑行。
      await db.writeMusicScanBatch(
        MusicScanBatchWrite(
          tracks: <MusicTracksCompanion>[_track('h2', 'dir-uid', 'again')],
          albums: <MusicAlbumsCompanion>[_album('dir-uid', null)],
          artists: const <MusicArtistsCompanion>[],
          credits: const <MusicTrackCreditsCompanion>[],
        ),
      );
      expect((await db.getMusicTrack('h2'))!.albumUid, 'x-uid');
    });
  });
}

/// 同一目录 /music/CD 下的一张盘：01 写了专辑艺人 X，02 没写（BUG-5164 的拆分）。
MusicScanBatchWrite _splitCd() => MusicScanBatchWrite(
  tracks: <MusicTracksCompanion>[
    _track('h1', 'x-uid', 'one'),
    _track('h2', 'dir-uid', 'two'),
  ],
  albums: <MusicAlbumsCompanion>[_album('x-uid', 'X'), _album('dir-uid', null)],
  artists: const <MusicArtistsCompanion>[],
  credits: const <MusicTrackCreditsCompanion>[],
);

MusicTracksCompanion _track(String uid, String albumUid, String title) =>
    MusicTracksCompanion.insert(
      trackUid: uid,
      path: '${Directory.systemTemp.path}/music/CD/$uid.flac',
      title: title,
      albumUid: Value<String?>(albumUid),
      sourceId: const Value<int?>(1),
      fileMtimeAt: 1,
      fileSize: 1,
      addedAt: 1,
    );

MusicAlbumsCompanion _album(String uid, String? artist) =>
    MusicAlbumsCompanion.insert(
      albumUid: uid,
      title: 'Best',
      albumArtistCredit: Value<String?>(artist),
      addedAt: 1,
      updatedAt: 1,
    );
