import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/metadata/music_scrape_service.dart';
import 'package:fushi/src/media/music/metadata/music_tag_writeback.dart';
import 'package:fushi/src/pages/implementations/music/music_mv_page.dart';
import 'package:fushi/src/pages/implementations/music/music_track_scrape_sections.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/metadata/music_metadata_models.dart';
import 'package:fushi_engine/media/music/metadata/music_metadata_provider.dart';
import 'package:fushi_engine/media/music/metadata/music_metadata_resolver.dart';
import 'package:fushi_engine/media/music/metadata/musicbrainz_provider.dart';
import 'package:fushi_music/fushi_music.dart';

const String _rec = '79a8b80c-018d-4004-b3ff-cc10d21a3ddd';
const String _original = '11111111-1111-1111-1111-111111111111';
const String _work = 'd69ecd96-bb2c-461f-9762-29102d2b50a1';
const String _release = 'dad6dbbe-68a8-4b31-8c60-2fd287360d50';

/// 假 MusicBrainz：搜索命中一首（这首是翻唱），作品里还有原曲；每个请求都记一条原始快照。
class _FakeMb implements MusicRecordingProvider {
  _FakeMb(this.sink);

  final MusicRawResponseSink sink;
  int searches = 0;
  bool fail = false;

  static const MusicRecording recording = MusicRecording(
    mbRecordingId: _rec,
    title: 'Lemon',
    durationMs: 255826,
    artistCredit: <MusicArtistCredit>[
      MusicArtistCredit(name: '米津玄師', mbArtistId: 'artist-1'),
    ],
    releases: <MusicReleaseRef>[
      MusicReleaseRef(
        mbReleaseId: _release,
        title: 'Lemon',
        releaseGroupId: 'rg-1',
        status: 'Official',
        primaryType: 'Single',
        date: '2018-03-14',
        discPosition: 1,
        trackPosition: 1,
        catalogNumbers: <String>['SECL-2270'],
      ),
    ],
    works: <MusicWorkLink>[MusicWorkLink(mbWorkId: _work, title: 'Lemon')],
  );

  @override
  MusicMetadataProviderKind get providerKind =>
      MusicMetadataProviderKind.musicbrainz;
  @override
  bool get isAvailable => true;
  @override
  String? get unavailableReason => null;
  @override
  void close() {}

  @override
  Future<List<MusicRecording>> searchRecordings(
    MusicRecordingSearchQuery query,
  ) async {
    if (fail) throw const SocketException('offline');
    searches++;
    return <MusicRecording>[recording];
  }

  @override
  Future<MusicRecording?> fetchRecording(String id) async {
    sink(
      provider: providerKind,
      kind: 'recording',
      externalId: id,
      rawJson: '{"id":"$id"}',
    );
    return id == _rec ? recording : null;
  }

  @override
  Future<MusicWork?> fetchWork(String id) async => const MusicWork(
    mbWorkId: _work,
    title: 'Lemon',
    recordings: <MusicWorkRecording>[
      MusicWorkRecording(
        mbRecordingId: _original,
        title: 'Lemon',
        artistCreditText: 'Original Singer',
        firstReleaseDate: '2010-01-01',
      ),
      MusicWorkRecording(
        mbRecordingId: _rec,
        title: 'Lemon',
        artistCreditText: '米津玄師',
        firstReleaseDate: '2018-03-14',
        attributes: <String>['cover'],
      ),
    ],
  );
}

MusicTracksCompanion _track({String? mbid, int? cueStart}) =>
    MusicTracksCompanion.insert(
      trackUid: 't1',
      path: '/music/lemon.flac',
      title: 'Lemon',
      artistCredit: const Value<String?>('米津玄師'),
      albumUid: const Value<String?>('a1'),
      durationMs: const Value<int?>(255900),
      trackNo: const Value<int?>(1),
      mbRecordingId: Value<String?>(mbid),
      cueStartMs: Value<int?>(cueStart),
      fileMtimeAt: 1,
      fileSize: 1,
      addedAt: 1,
    );

void main() {
  late FushiDatabase db;
  late _FakeMb? mb;
  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    mb = null;
    await db.writeMusicScanBatch(
      MusicScanBatchWrite(
        tracks: <MusicTracksCompanion>[_track()],
        albums: <MusicAlbumsCompanion>[
          MusicAlbumsCompanion.insert(
            albumUid: 'a1',
            title: 'Lemon',
            addedAt: 1,
            updatedAt: 1,
          ),
        ],
        artists: const <MusicArtistsCompanion>[],
        credits: const <MusicTrackCreditsCompanion>[],
      ),
    );
  });
  tearDown(() => db.close());

  MusicScrapeService service({String acoustidKey = ''}) => MusicScrapeService(
    database: () => db,
    acoustidApiKey: () => acoustidKey,
    vgmdbEnabled: () => false,
    clock: () => 42,
    coverDirectory: () async => Directory.systemTemp,
    fingerprinter: (MusicTrackRow _) async => null,
    scraperFactory:
        ({
          required MusicRawResponseSink sink,
          required String acoustidApiKey,
          required bool vgmdbEnabled,
        }) {
          final _FakeMb fake = mb ??= _FakeMb(sink);
          return MusicMetadataScraper(
            resolver: MusicMetadataResolver(musicBrainz: fake),
          );
        },
  );

  test('识别落库：结论 / 原曲 / 其它版本 / 快照 / 身份叠加；显示列不动', () async {
    final MusicScrapeOutcome o = await service().scrapeTrack('t1');
    expect(o.matched, isTrue);
    final MusicScrapeMetaRow meta = (await db.getMusicScrapeMeta('t1'))!;
    expect(meta.method, 'tag_search');
    expect(meta.mbRecordingId, _rec);
    expect(meta.mbReleaseId, _release);
    expect(meta.catalogNo, 'SECL-2270');
    expect(meta.originalRecordingId, _original);
    expect(meta.originalArtistCredit, 'Original Singer');
    expect(meta.selfIsOriginal, isFalse);
    expect(meta.scrapedAt, 42);
    expect(meta.scraperVersion, kMusicScraperVersion);
    // AcoustID 没 key：识别照常（标签命中），并记一条说明。
    expect(meta.warnings, isNull);
    expect(
      await db.getMusicRawSnapshot(
        provider: 'musicbrainz',
        snapshotKind: 'recording',
        externalId: _rec,
      ),
      isNotNull,
    );
    final MusicTrackRow t = (await db.getMusicTrack('t1'))!;
    expect(t.mbRecordingId, _rec);
    expect(t.mbWorkId, _work);
    expect(t.title, 'Lemon');
    expect((await db.getMusicAlbum('a1'))!.mbReleaseId, _release);
    expect(
      (await db.listMusicTracksNeedingScrape(
        olderThanVersion: kMusicScraperVersion,
      )),
      isEmpty,
    );
  });

  test('主源连不上：记 error，但不覆盖已有的成功结论', () async {
    final MusicScrapeService s = service();
    await s.scrapeTrack('t1');
    mb!.fail = true;
    final MusicScrapeOutcome o = await s.scrapeTrack('t1');
    expect(o.status, MusicScrapeStatus.error);
    expect(
      (await db.getMusicScrapeMeta('t1'))!.status,
      MusicScrapeStatus.matched,
    );
  });

  test('重新识别：叠加上去的录音 id 不当成「MBID 标签」自我确认', () async {
    final MusicScrapeService s = service();
    await s.scrapeTrack('t1');
    expect((await db.getMusicTrack('t1'))!.mbRecordingId, _rec);
    await s.scrapeTrack('t1');
    expect(mb!.searches, 2);
    expect((await db.getMusicScrapeMeta('t1'))!.method, 'tag_search');
  });

  test('手选：跳过搜索直接按 MBID', () async {
    final MusicScrapeService s = service();
    await s.scrapeTrack('t1', manualRecordingId: _rec.toUpperCase());
    expect(mb!.searches, 0);
    expect((await db.getMusicScrapeMeta('t1'))!.method, 'manual');
  });

  test('设置：AcoustID key / VGMdb 开关按调用时的偏好交给 provider 组', () async {
    final List<({String key, bool vgmdb})> seen =
        <({String key, bool vgmdb})>[];
    bool vgmdb = false;
    String key = '';
    final MusicScrapeService s = MusicScrapeService(
      database: () => db,
      acoustidApiKey: () => key,
      vgmdbEnabled: () => vgmdb,
      fingerprinter: (MusicTrackRow _) async => null,
      scraperFactory:
          ({
            required MusicRawResponseSink sink,
            required String acoustidApiKey,
            required bool vgmdbEnabled,
          }) {
            seen.add((key: acoustidApiKey, vgmdb: vgmdbEnabled));
            return MusicMetadataScraper(
              resolver: MusicMetadataResolver(musicBrainz: _FakeMb(sink)),
            );
          },
    );
    expect(s.acoustidConfigured, isFalse);
    await s.scrapeTrack('t1');
    vgmdb = true;
    key = 'k';
    expect(s.acoustidConfigured, isTrue);
    await s.scrapeTrack('t1');
    expect(seen, <({String key, bool vgmdb})>[
      (key: '', vgmdb: false),
      (key: 'k', vgmdb: true),
    ]);
  });

  test('AcoustID key：用户填的优先，没填用内置，两者都空才不可用', () {
    expect(resolveMusicAcoustidApiKey(' mine ', builtinKey: 'builtin'), 'mine');
    expect(resolveMusicAcoustidApiKey('  ', builtinKey: 'builtin'), 'builtin');
    expect(resolveMusicAcoustidApiKey('', builtinKey: ''), '');
  });

  test('曲库批量：串行、统计按途径', () async {
    final MusicLibraryScrapeReport r = await service().scrapeLibrary();
    expect(r.total, 1);
    expect(r.matched, 1);
    expect(r.byMethod, <String, int>{'tag_search': 1});
  });

  group('写回标签 diff', () {
    test('提议值与文件值比较：数字按数值、MBID 不分大小写、锁住的标出来', () async {
      await service().scrapeTrack('t1');
      final MusicScrapeMetaRow meta = (await db.getMusicScrapeMeta('t1'))!;
      final List<MusicTagChange> changes = diffMusicTags(
        current: <MusicTagField, String>{
          MusicTagField.title: 'Lemon',
          MusicTagField.trackNo: '01',
          MusicTagField.mbRecordingId: _rec.toUpperCase(),
        },
        proposed: proposedMusicTags(meta),
        lockedFields: <String>{'catalog_no'},
      );
      final Map<MusicTagField, MusicTagChange> by =
          <MusicTagField, MusicTagChange>{
            for (final MusicTagChange c in changes) c.field: c,
          };
      expect(by.containsKey(MusicTagField.title), isFalse);
      expect(by.containsKey(MusicTagField.trackNo), isFalse);
      expect(by.containsKey(MusicTagField.mbRecordingId), isFalse);
      expect(by[MusicTagField.artist]?.current, isNull);
      expect(by[MusicTagField.artist]?.proposed, '米津玄師');
      expect(by[MusicTagField.catalogNo]?.locked, isTrue);
      expect(by[MusicTagField.mbReleaseId]?.proposed, _release);
    });

    test('CUE 曲目与未识别的曲目不能写回', () async {
      final MusicTagWriteback wb = MusicTagWriteback(database: db);
      expect(
        (await wb.preview('t1')).blockedReason,
        MusicTagBlocked.notIdentified,
      );
      await db.writeMusicScanBatch(
        MusicScanBatchWrite(
          tracks: <MusicTracksCompanion>[_track(cueStart: 1000)],
          albums: const <MusicAlbumsCompanion>[],
          artists: const <MusicArtistsCompanion>[],
          credits: const <MusicTrackCreditsCompanion>[],
        ),
      );
      expect((await wb.preview('t1')).blockedReason, MusicTagBlocked.cueTrack);
    });

    test('真文件：只写勾选的字段，没勾的上锁（native/fushi_music）', () async {
      final Directory tmp = Directory.systemTemp.createTempSync('wb');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final String src = _fixture('Album A/01 First Song.flac');
      final String path = '${tmp.path}/song.flac';
      File(src).copySync(path);
      await db.customStatement(
        'UPDATE music_tracks SET path = ? WHERE track_uid = ?',
        <Object?>[path, 't1'],
      );
      await service().scrapeTrack('t1');
      final MusicTagWriteback wb = MusicTagWriteback(
        database: db,
        clock: () => 7,
      );
      final MusicTagPreview p = await wb.preview('t1');
      expect(p.canWrite, isTrue);
      await wb.apply(p, <MusicTagField>{
        MusicTagField.mbRecordingId,
        MusicTagField.catalogNo,
      });
      final Map<MusicTagField, String> after = MusicTagFieldsIo.instance.read(
        path,
      );
      expect(after[MusicTagField.mbRecordingId], _rec);
      expect(after[MusicTagField.catalogNo], 'SECL-2270');
      expect(after[MusicTagField.artist], isNot('米津玄師'));
      final Set<String> locks = await db.listMusicLockedFields(
        entityKind: MusicLockEntity.track,
        entityUid: 't1',
      );
      expect(locks, contains('artist'));
      expect(locks, isNot(contains('catalog_no')));
      // 再预览：写过的字段一致了，没勾的仍在但默认不勾（锁）。
      final MusicTagPreview again = await wb.preview('t1');
      expect(
        again.changes.map((MusicTagChange c) => c.field),
        isNot(contains(MusicTagField.mbRecordingId)),
      );
      expect(
        again.changes
            .firstWhere((MusicTagChange c) => c.field == MusicTagField.artist)
            .locked,
        isTrue,
      );
    });
  });

  test('存储的版本 / 候选 JSON 解码：坏 JSON 当空', () {
    expect(decodeMusicStoredRecordings('not json'), isEmpty);
    final List<MusicStoredRecording> r = decodeMusicStoredRecordings(
      '[{"id":"x","title":"T","artist":"A","attrs":["cover"]},{"title":"no id"}]',
    );
    expect(r.single.attributes, <String>['cover']);
  });

  test('MV 页：外挂曲库音轨的 audio-delay 与歌词时刻', () {
    // MV 有 8 s 前奏剧情：外挂音轨晚 8 s 出声。
    expect(musicMvAudioDelaySeconds(offsetMs: 8000), 8.0);
    // CUE 曲目从整轨 600 s 处起：外挂的是整轨文件，要再提前 600 s。
    expect(
      musicMvAudioDelaySeconds(offsetMs: 8000, cueStartMs: 600000),
      -592.0,
    );
    expect(
      musicMvLyricPosition(const Duration(seconds: 10), 8000),
      const Duration(seconds: 2),
    );
    expect(
      musicMvLyricPosition(const Duration(seconds: 3), 8000),
      Duration.zero,
    );
  });
}

String _fixture(String rel) {
  Directory dir = Directory.current.absolute;
  for (int i = 0; i < 6; i++) {
    final File f = File(
      '${dir.path}/native/fushi_music/tests/fixtures/library/$rel',
    );
    if (f.existsSync()) return f.path;
    dir = dir.parent;
  }
  throw StateError('fixture $rel not found');
}
