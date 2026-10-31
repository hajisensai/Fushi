import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v133：音乐 P4 刮削三表（docs/specs/2026-10-23-music-module-design.md §8 / §10）。
///
/// 迁移只建表、不动既有数据，重跑幂等；识别身份在曲库目录上的叠加（重扫后重放）、
/// 字段锁、MV 绑定的读写在这里钉死。
void main() {
  const List<String> scrapeTables = <String>[
    'music_scrape_meta',
    'music_metadata_raw_snapshots',
    'music_locked_fields',
  ];

  bool tableExists(sqlite.Database raw, String table) => raw.select(
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
    <Object?>[table],
  ).isNotEmpty;

  test('v132 → v133 建三张刮削表；重跑幂等、不清数据', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'music_v133',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = '${directory.path}/test.db';
    final FushiDatabase db = FushiDatabase.atFile(path, isMainProcess: false);
    await db.getAllTags(); // 触发建库
    await db.close();

    final sqlite.Database raw = sqlite.sqlite3.open(path);
    for (final String table in scrapeTables) {
      raw.execute('DROP TABLE $table');
    }
    raw.execute('PRAGMA user_version = 132');
    raw.dispose();

    final FushiDatabase migrated = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect(migrated.schemaVersion, 142);
    await migrated.writeMusicScanBatch(
      MusicScanBatchWrite(
        tracks: <MusicTracksCompanion>[_track('t1', album: 'a1')],
        albums: <MusicAlbumsCompanion>[_album('a1')],
        artists: const <MusicArtistsCompanion>[],
        credits: const <MusicTrackCreditsCompanion>[],
      ),
    );
    await migrated.writeMusicScrapeResult(meta: _meta('t1'));
    await migrated.close();

    final sqlite.Database probe = sqlite.sqlite3.open(path);
    expect(probe.select('PRAGMA user_version').first.values.first, 142);
    for (final String table in scrapeTables) {
      expect(tableExists(probe, table), isTrue, reason: table);
    }
    probe.execute('PRAGMA user_version = 132');
    probe.dispose();

    final FushiDatabase reopened = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    expect((await reopened.getMusicScrapeMeta('t1'))?.mbRecordingId, _rec);
    await reopened.close();
  });

  group('刮削 API', () {
    late FushiDatabase db;
    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    Future<void> scan({String? tagRecording, String? tagCatalog}) =>
        db.writeMusicScanBatch(
          MusicScanBatchWrite(
            tracks: <MusicTracksCompanion>[
              _track('t1', album: 'a1', mbRecordingId: tagRecording),
            ],
            albums: <MusicAlbumsCompanion>[_album('a1', catalogNo: tagCatalog)],
            artists: const <MusicArtistsCompanion>[],
            credits: const <MusicTrackCreditsCompanion>[],
          ),
        );

    test('识别身份叠加到曲库，重扫（标签没 MBID）后仍在', () async {
      await scan();
      await db.writeMusicScrapeResult(
        meta: _meta('t1'),
        snapshots: <MusicMetadataRawSnapshotsCompanion>[
          MusicMetadataRawSnapshotsCompanion.insert(
            provider: 'musicbrainz',
            snapshotKind: 'recording',
            externalId: _rec,
            rawJson: '{"v":1}',
            fetchedAt: 1,
          ),
        ],
      );
      MusicTrackRow? t = await db.getMusicTrack('t1');
      expect(t?.mbRecordingId, _rec);
      expect(t?.mbWorkId, _work);
      MusicAlbumRow? a = await db.getMusicAlbum('a1');
      expect(a?.mbReleaseId, _release);
      expect(a?.catalogNo, 'SECL-2270');

      // 重扫：扫描批次按标签整行 upsert，把身份冲回 NULL——同一事务里重放。
      await scan();
      t = await db.getMusicTrack('t1');
      expect(t?.mbRecordingId, _rec);
      a = await db.getMusicAlbum('a1');
      expect(a?.mbReleaseId, _release);

      // 快照按外部实体覆盖，不堆积。
      await db.writeMusicScrapeResult(
        meta: _meta('t1'),
        snapshots: <MusicMetadataRawSnapshotsCompanion>[
          MusicMetadataRawSnapshotsCompanion.insert(
            provider: 'musicbrainz',
            snapshotKind: 'recording',
            externalId: _rec,
            rawJson: '{"v":2}',
            fetchedAt: 2,
          ),
        ],
      );
      final MusicMetadataRawSnapshotRow? snap = await db.getMusicRawSnapshot(
        provider: 'musicbrainz',
        snapshotKind: 'recording',
        externalId: _rec,
      );
      expect(snap?.rawJson, '{"v":2}');
    });

    test('专辑：标签写了的目录编号以标签为准；未识别的结论不叠加', () async {
      await scan(tagCatalog: 'TAG-1');
      await db.writeMusicScrapeResult(meta: _meta('t1'));
      expect((await db.getMusicAlbum('a1'))?.catalogNo, 'TAG-1');

      await db.writeMusicScrapeResult(
        meta: _meta('t1', status: 'unmatched', recording: null),
      );
      await scan();
      expect((await db.getMusicTrack('t1'))?.mbRecordingId, isNull);
    });

    test('取消识别：结论删掉、录音身份清空', () async {
      await scan();
      await db.writeMusicScrapeResult(meta: _meta('t1'));
      await db.clearMusicScrapeResult('t1');
      expect(await db.getMusicScrapeMeta('t1'), isNull);
      expect((await db.getMusicTrack('t1'))?.mbRecordingId, isNull);
    });

    test('待刮清单：没结论 / 版本旧的才列', () async {
      await scan();
      expect(
        (await db.listMusicTracksNeedingScrape(olderThanVersion: 1)).length,
        1,
      );
      await db.writeMusicScrapeResult(meta: _meta('t1'));
      expect(
        await db.listMusicTracksNeedingScrape(olderThanVersion: 1),
        isEmpty,
      );
      expect(
        (await db.listMusicTracksNeedingScrape(olderThanVersion: 2)).length,
        1,
      );
      expect(
        (await db.listMusicTracksByRecordingIds(<String>{
          _rec,
        })).single.trackUid,
        't1',
      );
    });

    test('字段锁整组替换', () async {
      await db.setMusicLockedFields(
        entityKind: 'track',
        entityUid: 't1',
        fields: <String>{'title', 'artist'},
        lockedAt: 1,
      );
      await db.setMusicLockedFields(
        entityKind: 'track',
        entityUid: 't1',
        fields: <String>{'artist', 'album'},
        lockedAt: 2,
      );
      expect(
        await db.listMusicLockedFields(entityKind: 'track', entityUid: 't1'),
        <String>{'artist', 'album'},
      );
    });

    test('刮削封面不覆盖目录封面', () async {
      await scan();
      expect(
        await db.setMusicAlbumScrapedCover(
          albumUid: 'a1',
          coverPath: '/covers/caa.jpg',
          updatedAt: 5,
        ),
        isTrue,
      );
      expect((await db.getMusicAlbum('a1'))?.coverPath, '/covers/caa.jpg');
      expect(
        await db.setMusicAlbumScrapedCover(
          albumUid: 'a1',
          coverPath: '/covers/other.jpg',
          updatedAt: 6,
        ),
        isFalse,
      );
    });

    test('MV 绑定：按 (曲目, 种类, 引用) 唯一，用户绑定排前', () async {
      await db.upsertMusicVideo(
        MusicVideosCompanion.insert(
          trackUid: 't1',
          kind: 'local',
          ref: '/mv/a.mkv',
          offsetMs: const Value<int>(8000),
          confidence: const Value<double?>(0.9),
          updatedAt: 1,
        ),
      );
      await db.upsertMusicVideo(
        MusicVideosCompanion.insert(
          trackUid: 't1',
          kind: 'youtube',
          ref: 'https://youtu.be/x',
          isUserBound: const Value<bool>(true),
          updatedAt: 1,
        ),
      );
      await db.upsertMusicVideo(
        MusicVideosCompanion.insert(
          trackUid: 't1',
          kind: 'local',
          ref: '/mv/a.mkv',
          offsetMs: const Value<int>(8120),
          confidence: const Value<double?>(0.95),
          updatedAt: 2,
        ),
      );
      final List<MusicVideoRow> rows = await db.listMusicVideos('t1');
      expect(rows, hasLength(2));
      expect(rows.first.kind, 'youtube');
      expect(rows.last.offsetMs, 8120);
      await db.deleteMusicVideo(rows.last.id);
      expect(await db.listMusicVideos('t1'), hasLength(1));
    });
  });
}

const String _rec = '79a8b80c-018d-4004-b3ff-cc10d21a3ddd';
const String _work = 'd69ecd96-bb2c-461f-9762-29102d2b50a1';
const String _release = 'dad6dbbe-68a8-4b31-8c60-2fd287360d50';

MusicScrapeMetaCompanion _meta(
  String uid, {
  String status = 'matched',
  String? recording = _rec,
}) => MusicScrapeMetaCompanion.insert(
  trackUid: uid,
  status: status,
  method: const Value<String?>('tag_search'),
  mbRecordingId: Value<String?>(recording),
  mbWorkId: Value<String?>(recording == null ? null : _work),
  mbReleaseId: Value<String?>(recording == null ? null : _release),
  catalogNo: const Value<String?>('SECL-2270'),
  scraperVersion: 1,
  scrapedAt: 1,
);

MusicTracksCompanion _track(
  String uid, {
  required String album,
  String? mbRecordingId,
}) => MusicTracksCompanion.insert(
  trackUid: uid,
  path: '/music/$uid.flac',
  title: 'title-$uid',
  albumUid: Value<String?>(album),
  mbRecordingId: Value<String?>(mbRecordingId),
  fileMtimeAt: 1,
  fileSize: 1,
  addedAt: 1,
);

MusicAlbumsCompanion _album(String uid, {String? catalogNo}) =>
    MusicAlbumsCompanion.insert(
      albumUid: uid,
      title: 'album-$uid',
      catalogNo: Value<String?>(catalogNo),
      mbReleaseId: const Value<String?>(null),
      addedAt: 1,
      updatedAt: 1,
    );
