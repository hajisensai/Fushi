import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v158：`music_tracks.hidden_at`——用户「从音乐库移除」本地曲目的墓碑（拍板台
/// IDeN5PYaI7）。只从曲库隐藏、不碰磁盘文件，重扫见到同一个文件不复活；「恢复」清墓碑。
/// 歌单批量移除 / 撤销（多选动作条）也钉在这里。
void main() {
  test('v157 → v158 加 hidden_at；存量曲目都没隐藏', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'music_hidden_v158',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = '${directory.path}/test.db';
    final FushiDatabase original = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await original.writeMusicScanBatch(_batch(<String>['t1']));
    await original.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('ALTER TABLE music_tracks DROP COLUMN hidden_at');
    raw.execute('PRAGMA user_version = 157');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 162);
    final MusicTrackRow row = (await migrated.getMusicTrack('t1'))!;
    expect(row.hiddenAt, isNull);
    expect(row.deletedAt, isNull);
    expect(await migrated.hideMusicTracks(<String>['t1'], at: 5), 1);
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    expect(probe.select('PRAGMA user_version').first.values.first, 162);
    expect(
      probe
          .select("SELECT hidden_at FROM music_tracks WHERE track_uid = 't1'")
          .first
          .values
          .first,
      5,
    );
    // 重跑 v158 步：列已在，不得报错、不得清数据。
    probe.execute('PRAGMA user_version = 157');
    probe.dispose();
    final FushiDatabase reopened = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect((await reopened.getMusicTrack('t1'))?.hiddenAt, 5);
    await reopened.close();
  });

  group('从音乐库移除（墓碑）', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    Future<Set<String>> live() async => <String>{
      for (final MusicTrackRow r in await db.listMusicTracks()) r.trackUid,
    };

    test('移除后不在曲库；重扫同一文件（整首重新解析）不复活，元数据不被改写', () async {
      await db.writeMusicScanBatch(_batch(<String>['t1', 't2']));
      expect(await db.hideMusicTracks(<String>['t1'], at: 7), 1);
      expect(await live(), <String>{'t2'});
      final MusicTrackRow hidden = (await db.getMusicTrack('t1'))!;
      expect(hidden.hiddenAt, 7);
      expect(hidden.deletedAt, 7, reason: '隐藏的行与软删一样不进任何曲库查询');
      expect(
        await db.hideMusicTracks(<String>['t1'], at: 9),
        0,
        reason: '已经移除过的不重写时刻',
      );

      // 文件改过标签后重扫：同一 uid 整行重新解析落库。
      await db.writeMusicScanBatch(
        _batch(<String>['t1', 't2'], title: 'retagged'),
      );
      expect(await live(), <String>{'t2'});
      final MusicTrackRow still = (await db.getMusicTrack('t1'))!;
      expect(still.hiddenAt, 7);
      expect(still.deletedAt, isNotNull);
      expect(still.title, 'title-t1', reason: '墓碑行整行不动');
      expect((await db.getMusicTrack('t2'))!.title, 'retagged');
    });

    test('同一个文件换了 uid（旧版本扫出的拼法）重扫：沿用墓碑行，仍不复活', () async {
      await db.writeMusicScanBatch(_batch(<String>['t1']));
      await db.hideMusicTracks(<String>['t1'], at: 7);
      final Map<String, String> remap = await db.writeMusicScanBatch(
        MusicScanBatchWrite(
          tracks: <MusicTracksCompanion>[
            _track('t1-new', path: '/music/t1.flac'),
          ],
          albums: const <MusicAlbumsCompanion>[],
          artists: const <MusicArtistsCompanion>[],
          credits: const <MusicTrackCreditsCompanion>[],
        ),
      );
      expect(remap['t1-new'], 't1', reason: '按路径键认出库里已有的同一个文件');
      expect(await live(), isEmpty);
      expect(await db.getMusicTrack('t1-new'), isNull);
      expect((await db.getMusicTrack('t1'))!.hiddenAt, 7);
    });

    test('扫描的「已知文件」带上移除过的曲目（没变就不必每次重新解析）', () async {
      await db.writeMusicScanBatch(_batch(<String>['t1', 't2'], sourceId: 3));
      await db.hideMusicTracks(<String>['t1'], at: 7);
      await db.softDeleteMusicTrack('t2', deletedAt: 8);
      final Set<String> known = <String>{
        for (final ({String path, int mtimeAt, int size, String trackUid}) k
            in await db.musicTrackFilesOfSource(3))
          k.trackUid,
      };
      expect(known, <String>{'t1'}, reason: '普通软删（文件消失）的不算已知');
    });

    test('恢复：清墓碑与软删，回到曲库；只动真被移除过的行', () async {
      await db.writeMusicScanBatch(_batch(<String>['t1', 't2', 't3']));
      await db.hideMusicTracks(<String>['t1', 't2'], at: 7);
      await db.softDeleteMusicTrack('t3', deletedAt: 8);
      final List<MusicTrackRow> hidden = await db
          .watchHiddenMusicTracks()
          .first;
      expect(hidden.map((MusicTrackRow r) => r.trackUid).toSet(), <String>{
        't1',
        't2',
      });

      expect(await db.unhideMusicTracks(<String>['t1', 't3']), 1);
      expect(await live(), <String>{'t1'});
      expect((await db.getMusicTrack('t3'))!.deletedAt, 8);
      expect(
        (await db.watchHiddenMusicTracks().first).map(
          (MusicTrackRow r) => r.trackUid,
        ),
        <String>['t2'],
      );
    });
    test('移除音乐来源：墓碑行一并处理——被覆盖的改挂且仍是墓碑，没被覆盖的离开「已移除」、恢复不回曲库', () async {
      final String root = p.join(p.rootPrefix(p.current), 'm');
      Future<int> src(String path) => db.insertMediaSource(
        MediaSourcesCompanion.insert(
          label: path,
          mediaKind: 'music',
          rootPath: normalizeSourceRootPath(path, transport: 'local'),
          createdAt: 1,
        ),
      );
      final int inner = await src(p.join(root, 'A'));
      final int other = await src(p.join(root, 'B'));
      await db.writeMusicScanBatch(
        MusicScanBatchWrite(
          tracks: <MusicTracksCompanion>[
            _track('gone', path: p.join(root, 'A', '1.flac'), sourceId: inner),
            _track('kept', path: p.join(root, 'B', '1.flac'), sourceId: inner),
            _track('live', path: p.join(root, 'A', '2.flac'), sourceId: inner),
          ],
          albums: const <MusicAlbumsCompanion>[],
          artists: const <MusicArtistsCompanion>[],
          credits: const <MusicTrackCreditsCompanion>[],
        ),
      );
      await db.hideMusicTracks(<String>['gone', 'kept'], at: 7);

      final ({int reassigned, int softDeleted}) r = await db
          .releaseMusicTracksOfSource(inner);
      expect(r, (reassigned: 0, softDeleted: 1), reason: '墓碑行本就不在曲库，不计数');

      final MusicTrackRow kept = (await db.getMusicTrack('kept'))!;
      expect(kept.sourceId, other, reason: '仍被另一个来源覆盖：改挂');
      expect(kept.hiddenAt, 7, reason: '改挂不清墓碑，那个来源重扫仍不复活');
      expect(kept.deletedAt, 7);
      final MusicTrackRow gone = (await db.getMusicTrack('gone'))!;
      expect(gone.hiddenAt, isNull, reason: '来源没了：清墓碑');
      expect(gone.deletedAt, 7, reason: '保持软删');
      expect(
        (await db.watchHiddenMusicTracks().first).map(
          (MusicTrackRow r) => r.trackUid,
        ),
        <String>['kept'],
      );

      // 用户在「已移除的曲目」页点「全部恢复」：只有仍有来源的那首回来。
      expect(await db.unhideMusicTracks(<String>['gone', 'kept']), 1);
      expect(await live(), <String>{'kept'});
      expect((await db.getMusicTrack('gone'))!.deletedAt, 7);
    });
  });

  group('歌单批量移除 / 撤销', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    Future<List<String>> order(String uid) async => <String>[
      for (final MusicPlaylistEntryRow r in await db.listMusicPlaylistEntries(
        uid,
      ))
        '${r.trackUid}@${r.position}',
    ];

    test('按条目 id 删（同一首两次只删选中的），剩下重排；撤销按原位置放回', () async {
      final MusicPlaylistRow p = await db.createMusicPlaylist(
        'Road',
        at: 1,
        trackUids: <String>['a', 'b', 'a', 'c'],
      );
      final List<MusicPlaylistEntryRow> before = await db
          .listMusicPlaylistEntries(p.playlistUid);
      final List<MusicPlaylistEntryRow> removed = await db
          .removeMusicPlaylistEntries(p.playlistUid, <int>[
            before[0].id,
            before[3].id,
          ], at: 2);
      expect(removed.map((MusicPlaylistEntryRow r) => r.trackUid), <String>[
        'a',
        'c',
      ]);
      expect(await order(p.playlistUid), <String>['b@0', 'a@1']);

      await db.restoreMusicPlaylistEntries(p.playlistUid, removed, at: 3);
      expect(await order(p.playlistUid), <String>['a@0', 'b@1', 'a@2', 'c@3']);
      expect(
        (await db.listMusicPlaylistEntries(
          p.playlistUid,
        )).map((MusicPlaylistEntryRow r) => r.id),
        before.map((MusicPlaylistEntryRow r) => r.id),
        reason: '撤销放回的是原条目（原 id）',
      );
    });

    test('歌单期间被删了：撤销什么都不做', () async {
      final MusicPlaylistRow p = await db.createMusicPlaylist(
        'Road',
        at: 1,
        trackUids: <String>['a', 'b'],
      );
      final List<MusicPlaylistEntryRow> removed = await db
          .removeMusicPlaylistEntries(p.playlistUid, <int>[
            (await db.listMusicPlaylistEntries(p.playlistUid)).first.id,
          ], at: 2);
      await db.deleteMusicPlaylist(p.playlistUid, at: 3);
      await db.restoreMusicPlaylistEntries(p.playlistUid, removed, at: 4);
      expect(await db.listMusicPlaylistEntries(p.playlistUid), isEmpty);
    });
  });
}

MusicScanBatchWrite _batch(List<String> uids, {String? title, int? sourceId}) =>
    MusicScanBatchWrite(
      tracks: <MusicTracksCompanion>[
        for (final String uid in uids)
          _track(uid, title: title, sourceId: sourceId),
      ],
      albums: const <MusicAlbumsCompanion>[],
      artists: const <MusicArtistsCompanion>[],
      credits: const <MusicTrackCreditsCompanion>[],
    );

MusicTracksCompanion _track(
  String uid, {
  String? path,
  String? title,
  int? sourceId,
}) => MusicTracksCompanion.insert(
  trackUid: uid,
  path: path ?? '/music/$uid.flac',
  title: title ?? 'title-$uid',
  sourceId: Value<int?>(sourceId),
  fileMtimeAt: 1,
  fileSize: 1,
  addedAt: 1,
);
