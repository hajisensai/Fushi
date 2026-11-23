/// 在线源条目跨设备同步（拍板台 mY5VWg1nD-）。
///
/// - 清单编解码；
/// - 并入规则（真 DB）：漫画 / 小说 / 视频只增不删、本机删过的不建回、对端重新加了
///   照常建、本机墓碑挡住、音乐曲目整行 LWW；
/// - 云通道（假云，两台设备）与互联（真 server：app 当 host 的参与方、无头服务端的
///   信箱）端到端。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_shelf_row.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi/src/media/novel/online/lnreader_online_book.dart';
import 'package:fushi/src/media/video/online/anime_source_library.dart';
import 'package:fushi/src/models/preference_keys.dart'
    show kOnlineLibraryLedgerPrefKey;
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi/src/storage/download_layout.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/online_library_items.dart';
import 'package:fushi/src/sync/pref_redaction_policy.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/video/anime_source_video_path.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/sync/online_library_sync.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart' show AssetEntry;
import 'package:path/path.dart' as p;

import 'fake_asset_store.dart';
import 'sync_orchestrator_test.dart' show FakeSyncBackend;

FushiDatabase _memDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

OnlineMangaLibraryEntry _manga(String seriesKey, String title) =>
    OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: 'eu.kanade.tachiyomi.extension.test',
      sourceId: '4242',
      series: OnlineMangaSeries(
        key: seriesKey,
        title: title,
        raw: const <String, Object?>{},
      ),
      chapters: const <OnlineMangaChapter>[
        OnlineMangaChapter(
          key: '/c/2',
          name: 'Chapter 2',
          raw: <String, Object?>{'url': '/c/2'},
        ),
        OnlineMangaChapter(
          key: '/c/1',
          name: 'Chapter 1',
          raw: <String, Object?>{'url': '/c/1'},
        ),
      ],
      subscribed: true,
    );

Future<EpubBookRow> _addManga(
  FushiDatabase db,
  Directory root,
  OnlineMangaLibraryEntry entry, {
  int importedAt = 1000,
}) async {
  final String key = onlineMangaBookKeyOf(entry);
  final Directory dir = Directory(p.join(root.path, 'src_manga', key));
  await dir.create(recursive: true);
  return insertOnlineMangaShelfRow(
    db,
    entry: entry,
    title: entry.series.title,
    author: 'Author',
    coverPath: null,
    epubPath: 'manga.json',
    extractDir: dir.path,
    importedAt: importedAt,
  );
}

const String _animeUid = 'anime-source:pkg:7:/ep/1';

Future<void> _addAnimeEpisode(
  FushiDatabase db, {
  String uid = _animeUid,
  int importedAt = 2000,
}) => db.upsertVideoBook(
  VideoBooksCompanion(
    bookUid: Value<String>(uid),
    title: const Value<String>('Show - E01'),
    videoPath: Value<String>(
      animeSourceVideoPath(
        extensionPackage: 'pkg',
        sourceId: '7',
        label: 'Show - E01',
      ),
    ),
    streamSpecJson: Value<String?>(
      const AnimeSourceBookSpec(
        extensionPackage: 'pkg',
        sourceId: '7',
        anime: MihonAnime(url: '/anime/1', title: 'Show'),
        episode: MihonEpisode(
          url: '/ep/1',
          name: 'Episode 1',
          uploadedAt: 0,
          number: 1,
        ),
      ).encode(),
    ),
    importedAt: Value<int?>(importedAt),
  ),
);

Future<void> _addMusic(
  FushiDatabase db, {
  required String uid,
  required int at,
}) => db.addMusicRemoteTrackToLibrary(
  MusicRemoteTracksCompanion.insert(
    trackUid: uid,
    kind: 'plugin',
    sourceKey: 'demo-plugin',
    itemId: 'track-$uid',
    title: 'Song $uid',
    createdAt: at,
    updatedAt: at,
  ),
  at: at,
);

const String _novelDescriptorJson =
    '{"type":"fushi-lnreader-online","version":1,"pluginId":"demo.novel",'
    '"novelPath":"/novel/9","chapters":[{"path":"/n/9/1","name":"One"},'
    '{"path":"/n/9/2","name":"Two"}],"author":"Writer"}';

Future<void> _addNovel(FushiDatabase db) => db.insertEpubBook(
  EpubBooksCompanion.insert(
    bookKey: 'Online Novel',
    title: 'Online Novel',
    epubPath: 'Online Novel.epub',
    extractDir: '/nowhere',
    chapterCount: 2,
    chaptersJson: '[]',
    importedAt: 3000,
    language: const Value<String?>('ja'),
    sourceMetadata: const Value<String?>(_novelDescriptorJson),
  ),
);

void main() {
  // 不起 TestWidgetsFlutterBinding：它把 HttpClient 换成一律回 400 的假客户端，
  // 互联端到端要真连本机 server。
  late Directory work;

  setUp(() async {
    work = await Directory.systemTemp.createTemp('online_library_sync_');
    final String root = p.join(work.path, 'downloads');
    DownloadRoot.install(() async => DownloadLayout(root: root));
    EpubStorage.debugBaseDirectoryOverride = p.join(work.path, 'books');
  });

  tearDown(() async {
    DownloadRoot.install(null);
    EpubStorage.debugBaseDirectoryOverride = null;
    if (work.existsSync()) await work.delete(recursive: true);
  });

  OnlineLibraryApplier applier(FushiDatabase db) => OnlineLibraryApplier(
    db,
    videoCoversDir: () async => Directory(p.join(work.path, 'covers')),
    novelPendingText: () => 'pending',
  );

  group('清单', () {
    test('往返；未知种类 / 坏条目只丢那一条；版本过新整份拒收', () {
      final OnlineLibraryManifest m = OnlineLibraryManifest.fromJson(
        <String, Object?>{
          'version': 1,
          'deviceId': 'dev',
          'items': <Object?>[
            <String, Object?>{
              'kind': 'video',
              'key': 'b',
              'title': 'B',
              'addedAt': 2,
              'payload': <String, Object?>{'videoPath': 'x'},
            },
            <String, Object?>{'kind': 'manga', 'key': 'a', 'addedAt': 1},
            <String, Object?>{'kind': 'future-kind', 'key': 'z'},
            <String, Object?>{'kind': 'video'},
            'junk',
          ],
        },
      );
      expect(m.deviceId, 'dev');
      expect(m.items.map((OnlineLibraryItem i) => i.ledgerKey), <String>[
        'video:b',
        'manga:a',
      ]);
      final OnlineLibraryManifest back = OnlineLibraryManifest.fromJson(
        jsonDecode(m.canonicalJson()),
      );
      expect(back.canonicalJson(), m.canonicalJson());
      // 规范化 JSON 与条目顺序无关。
      expect(
        OnlineLibraryManifest(
          deviceId: 'dev',
          items: m.items.reversed.toList(),
        ).canonicalJson(),
        m.canonicalJson(),
      );
      expect(
        () => OnlineLibraryManifest.fromJson(<String, Object?>{
          'version': 99,
          'items': <Object?>[],
        }),
        throwsFormatException,
      );
    });
  });

  group('并入规则', () {
    late FushiDatabase a;
    late FushiDatabase b;

    setUp(() {
      a = _memDb();
      b = _memDb();
    });

    tearDown(() async {
      await a.close();
      await b.close();
    });

    test('本机清单只收在线条目：漫画去掉章表、本地视频不在列', () async {
      final EpubBookRow manga = await _addManga(a, work, _manga('/m/1', 'M1'));
      await _addAnimeEpisode(a);
      await a.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'video/local',
          title: 'Local',
          videoPath: p.join(work.path, 'local.mp4'),
        ),
      );
      await _addMusic(a, uid: 'm1', at: 50);
      await _addNovel(a);

      final OnlineLibraryManifest m = await buildLocalOnlineLibraryManifest(
        a,
        deviceId: 'devA',
      );
      final Map<String, OnlineLibraryItem> byKey = <String, OnlineLibraryItem>{
        for (final OnlineLibraryItem i in m.items) i.ledgerKey: i,
      };
      expect(byKey.keys.toSet(), <String>{
        'manga:${manga.bookKey}',
        'video:$_animeUid',
        'music:m1',
        'novel:${onlineNovelItemKey('demo.novel', '/novel/9')}',
      });
      final Map<String, Object?> entry =
          (byKey['manga:${manga.bookKey}']!.payload['entry']!
                  as Map<String, Object?>)
              .cast<String, Object?>();
      expect(entry['chapters'], isEmpty, reason: '章表不进清单，收到的设备打开时刷新');
      expect(entry['subscribed'], isTrue);
      expect(byKey['manga:${manga.bookKey}']!.payload['uid'], manga.uid);
    });

    test('对端新加的建；本机删掉的不建回；对端重新加了照常建；本机墓碑挡住', () async {
      final OnlineMangaLibraryEntry entry = _manga('/m/1', 'M1');
      final EpubBookRow source = await _addManga(a, work, entry);
      await _addAnimeEpisode(a);
      await _addNovel(a);

      final OnlineLibraryManifest fromA = await buildLocalOnlineLibraryManifest(
        a,
        deviceId: 'devA',
      );
      final OnlineLibraryApplyResult first = await applier(
        b,
      ).apply(<OnlineLibraryManifest>[fromA], ownDeviceId: 'devB');
      expect(first.errors, isEmpty);
      expect(first.changed, 3);

      final EpubBookRow? manga = await b.getEpubBook(source.bookKey);
      expect(manga, isNotNull);
      expect(manga!.uid, source.uid, reason: 'uid 跟着条目走，合集 / 标签对得上');
      expect(manga.chapterCount, 0);
      expect(manga.importedAt, source.importedAt);
      expect(File(p.join(manga.extractDir, 'manga.json')).existsSync(), isTrue);
      final OnlineMangaLibraryEntry? parsed = OnlineMangaLibraryEntry.tryParse(
        manga.sourceMetadata,
      );
      expect(parsed?.series.key, '/m/1');
      expect(parsed?.subscribed, isTrue);

      final VideoBookRow? video = await b.getVideoBookByBookUid(_animeUid);
      expect(video, isNotNull);
      expect(isAnimeSourceVideoPath(video!.videoPath), isTrue);
      expect(AnimeSourceBookSpec.tryParse(video.streamSpecJson), isNotNull);

      final List<EpubBookRow> novels =
          await (b.select(b.epubBooks)..where(
                ($EpubBooksTable t) =>
                    t.bookKey.isNotIn(<String>[source.bookKey]),
              ))
              .get();
      expect(novels, hasLength(1));
      final LnReaderOnlineBookDescriptor? novel =
          LnReaderOnlineBookDescriptor.tryParse(novels.single.sourceMetadata);
      expect(novel?.pluginId, 'demo.novel');
      expect(novel?.chapters.map((LnReaderChapter c) => c.path), <String>[
        '/n/9/1',
        '/n/9/2',
      ]);
      expect(novels.single.chapterCount, 2);

      // 稳态：再并一次什么都不变。
      final OnlineLibraryApplyResult again = await applier(
        b,
      ).apply(<OnlineLibraryManifest>[fromA], ownDeviceId: 'devB');
      expect(again.changed, 0);

      // 本机（B）「仅本机删除」：不写墓碑，对端清单里还有，也不建回。
      await (b.delete(
        b.epubBooks,
      )..where(($EpubBooksTable t) => t.bookKey.equals(source.bookKey))).go();
      await b.deleteVideoBook(_animeUid);
      final OnlineLibraryApplyResult afterDelete = await applier(
        b,
      ).apply(<OnlineLibraryManifest>[fromA], ownDeviceId: 'devB');
      expect(afterDelete.changed, 0);
      expect(await b.getEpubBook(source.bookKey), isNull);
      expect(await b.getVideoBookByBookUid(_animeUid), isNull);

      // A 删了又重新加（addedAt 变大）：B 照常建。
      await (a.delete(
        a.epubBooks,
      )..where(($EpubBooksTable t) => t.bookKey.equals(source.bookKey))).go();
      await _addManga(a, work, entry, importedAt: 9000);
      final OnlineLibraryApplyResult readded = await applier(b).apply(
        <OnlineLibraryManifest>[
          await buildLocalOnlineLibraryManifest(a, deviceId: 'devA'),
        ],
        ownDeviceId: 'devB',
      );
      expect(readded.changed, 1);
      expect(await b.getEpubBook(source.bookKey), isNotNull);

      // 本机「从所有设备删除」的墓碑挡住删除之前就有的那条。
      const String other = 'anime-source:pkg:7:/ep/2';
      await _addAnimeEpisode(a, uid: other, importedAt: 4000);
      await b.writeSyncDeletionTombstone(
        SyncTombstoneKind.video.dbValue,
        other,
        5000,
      );
      final OnlineLibraryApplyResult vetoed = await applier(b).apply(
        <OnlineLibraryManifest>[
          await buildLocalOnlineLibraryManifest(a, deviceId: 'devA'),
        ],
        ownDeviceId: 'devB',
      );
      expect(vetoed.changed, 0);
      expect(await b.getVideoBookByBookUid(other), isNull);
    });

    test('本机自己的清单不并；已下载成本地视频的同一集不再建在线行', () async {
      await _addAnimeEpisode(a);
      final OnlineLibraryManifest fromA = await buildLocalOnlineLibraryManifest(
        a,
        deviceId: 'devA',
      );
      // B 上同一集已下载成本地视频（同 bookUid、路径是本地文件）。
      await b.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: _animeUid,
          title: 'Show - E01',
          videoPath: p.join(work.path, 'ep1.mp4'),
        ),
      );
      final OnlineLibraryApplyResult r = await applier(
        b,
      ).apply(<OnlineLibraryManifest>[fromA], ownDeviceId: 'devB');
      expect(r.changed, 0);
      expect(
        (await b.getVideoBookByBookUid(_animeUid))!.videoPath,
        p.join(work.path, 'ep1.mp4'),
      );
      // 标成本机设备 id 的清单整份跳过。
      final OnlineLibraryApplyResult own = await applier(
        a,
      ).apply(<OnlineLibraryManifest>[fromA], ownDeviceId: 'devA');
      expect(own.changed, 0);
    });

    test('音乐曲目整行 LWW：加入与移出音乐库都传播，旧的不覆盖新的', () async {
      await _addMusic(a, uid: 'm1', at: 100);
      final OnlineLibraryApplierResultProbe probe =
          OnlineLibraryApplierResultProbe(applier(b));
      expect(await probe.applyFrom(a), 1);
      expect((await b.getMusicRemoteTrack('m1'))?.libraryAddedAt, 100);

      await a.removeMusicRemoteTrackFromLibrary('m1', at: 200);
      expect(await probe.applyFrom(a), 1);
      final MusicRemoteTrackRow? removed = await b.getMusicRemoteTrack('m1');
      expect(removed?.libraryAddedAt, isNull);
      expect(removed?.createdAt, 100);

      // B 后来又加回（更新）：A 的旧状态不覆盖它。
      await b.addMusicRemoteTrackToLibrary(
        MusicRemoteTracksCompanion.insert(
          trackUid: 'm1',
          kind: 'plugin',
          sourceKey: 'demo-plugin',
          itemId: 'track-m1',
          title: 'Song m1',
          createdAt: 300,
          updatedAt: 300,
        ),
        at: 300,
      );
      expect(await probe.applyFrom(a), 0);
      expect((await b.getMusicRemoteTrack('m1'))?.libraryAddedAt, 300);
    });

    test('对端移出音乐库、本机有离线副本：放回曲库且不改 updatedAt（不回传）', () async {
      await _addMusic(a, uid: 'm2', at: 100);
      final OnlineLibraryApplierResultProbe probe =
          OnlineLibraryApplierResultProbe(applier(b));
      expect(await probe.applyFrom(a), 1);
      await b
          .into(b.musicServerDownloads)
          .insert(
            MusicServerDownloadsCompanion.insert(
              trackUid: 'm2',
              sourceKey: 'demo-plugin',
              itemId: 'track-m2',
              filePath: p.join('x', 'm2.flac'),
              downloadedAt: 150,
            ),
          );

      await a.removeMusicRemoteTrackFromLibrary('m2', at: 200);
      expect(await probe.applyFrom(a), 1);
      final MusicRemoteTrackRow kept = (await b.getMusicRemoteTrack('m2'))!;
      expect(kept.libraryAddedAt, 150, reason: '下载 ⊂ 音乐库：离线副本把曲目留在曲库');
      expect(kept.updatedAt, 200, reason: '设备本地修正不当成新编辑，A 下一轮不会被改回');
      expect(await probe.applyFrom(a), 0);
    });
  });

  test('账本与 host 信箱是设备本地键：不进备份 / Profile 快照 / 分享', () {
    expect(
      PrefRedactionPolicy.isDeviceLocalOrCredential(
        kOnlineLibraryLedgerPrefKey,
      ),
      isTrue,
    );
    expect(ProfileKeys.isExcludedPref(kOnlineLibraryLedgerPrefKey), isTrue);
    const String mailboxKey = '${OnlineLibraryMailbox.keyPrefix}devX';
    expect(PrefRedactionPolicy.isDeviceLocalOrCredential(mailboxKey), isTrue);
    expect(ProfileKeys.isExcludedPref(mailboxKey), isTrue);
  });

  group('云通道', () {
    test('两台设备经同一份假云互相拿到对方的在线条目，各写各的文件', () async {
      final FakeAssetStore store = FakeAssetStore();
      final FushiDatabase a = _memDb();
      final FushiDatabase b = _memDb();
      addTearDown(a.close);
      addTearDown(b.close);
      SyncOrchestrator orch(FushiDatabase db, String id) => SyncOrchestrator(
        db: db,
        backend: FakeSyncBackend(store),
        dictionaryResourceRoot: work,
        audioDatabaseRoot: work,
        tempDir: work,
        deviceId: id,
        syncStats: false,
        syncAudioBookPosition: false,
        syncContent: false,
        syncMangaContent: false,
        syncAudioBookFiles: false,
        syncDictionary: false,
      );

      final SyncRunReport empty = SyncRunReport();
      await orch(a, 'devA').syncOnlineLibraryCloudForTest(empty);
      expect(
        (await store.listChildren(
          kSyncCollectionsNamespace,
        )).map((AssetEntry e) => e.name),
        isNot(contains('online-library-devA.json')),
        reason: '没有在线条目：不无中生有地建空文件',
      );

      final EpubBookRow manga = await _addManga(a, work, _manga('/m/1', 'M1'));
      await _addAnimeEpisode(b);
      final SyncRunReport ra = SyncRunReport();
      await orch(a, 'devA').syncOnlineLibraryCloudForTest(ra);
      final SyncRunReport rb = SyncRunReport();
      await orch(b, 'devB').syncOnlineLibraryCloudForTest(rb);
      final SyncRunReport ra2 = SyncRunReport();
      await orch(a, 'devA').syncOnlineLibraryCloudForTest(ra2);
      expect(<String>[...ra.errors, ...rb.errors, ...ra2.errors], isEmpty);

      expect(rb.onlineLibraryItemsApplied, 1);
      expect(rb.needsLocalLibraryRefresh, isTrue);
      expect(await b.getEpubBook(manga.bookKey), isNotNull);
      expect(ra2.onlineLibraryItemsApplied, 1);
      expect(await a.getVideoBookByBookUid(_animeUid), isNotNull);
      expect(
        (await store.listChildren(kSyncCollectionsNamespace))
            .map((AssetEntry e) => e.name)
            .where(isOnlineLibraryManifestName)
            .toSet(),
        <String>{'online-library-devA.json', 'online-library-devB.json'},
      );
      expect(isCollectionsManifestName('online-library-devA.json'), isFalse);
    });
  });

  group('互联', () {
    const String token = 'online-library-token';

    Future<InterconnectSyncBackend> client(String base) async {
      final FushiDatabase db = _memDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);
      await repo.setFushiClientUrls(<FushiClientUrl>[
        FushiClientUrl(url: base, enabled: true),
      ]);
      await repo.setFushiClientToken(token);
      final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe(
        (String u, String t) async => true,
      );
      await backend.restoreAuth(repo);
      await backend.authenticate(repo: repo);
      return backend;
    }

    SyncOrchestrator orch(
      FushiDatabase db,
      InterconnectSyncBackend backend,
      String id,
    ) => SyncOrchestrator(
      db: db,
      backend: backend,
      dictionaryResourceRoot: work,
      audioDatabaseRoot: work,
      tempDir: work,
      deviceId: id,
      syncStats: false,
      syncAudioBookPosition: false,
      syncContent: false,
      syncMangaContent: false,
      syncAudioBookFiles: false,
      syncVideoFiles: false,
      syncDictionary: false,
    );

    Future<(FushiSyncServer, String)> startServer(
      FushiDatabase hostDb, {
      OnlineLibraryParticipant? participant,
    }) async {
      final FushiSyncServer server = FushiSyncServer(
        syncDataDir: p.join(work.path, 'server_data'),
        port: 0,
        token: token,
        allowLan: false,
        libraryService: LocalLibraryHostService(
          db: hostDb,
          dictionaryResourceRoot: Directory(work.path),
          packages: SyncAssetPackageService(db: hostDb),
          refreshDictionaryCache: () async {},
          runExclusive: (Future<void> Function() body) => body(),
          onlineLibraryParticipant: participant,
        ),
      );
      await server.start();
      addTearDown(server.stop);
      return (server, 'http://127.0.0.1:${server.port}');
    }

    test('app 当 host：client 的条目并进 host，host 的条目落到 client', () async {
      final FushiDatabase hostDb = _memDb();
      final FushiDatabase clientDb = _memDb();
      addTearDown(hostDb.close);
      addTearDown(clientDb.close);
      final EpubBookRow hostManga = await _addManga(
        hostDb,
        work,
        _manga('/m/host', 'Host Manga'),
      );
      await _addAnimeEpisode(clientDb);
      final (_, String base) = await startServer(
        hostDb,
        participant: AppOnlineLibraryParticipant(
          hostDb,
          applier: applier(hostDb),
        ),
      );
      final InterconnectSyncBackend backend = await client(base);

      final SyncRunReport report = SyncRunReport();
      await orch(
        clientDb,
        backend,
        'client-a',
      ).syncOnlineLibraryLiveForTest(report, backend);
      expect(report.errors, isEmpty);
      expect(report.peerGaps, isEmpty);
      expect(report.onlineLibraryItemsApplied, 1);
      expect(await clientDb.getEpubBook(hostManga.bookKey), isNotNull);
      expect(await hostDb.getVideoBookByBookUid(_animeUid), isNotNull);

      // 稳态：再跑一轮，两端都不变。
      final SyncRunReport again = SyncRunReport();
      await orch(
        clientDb,
        backend,
        'client-a',
      ).syncOnlineLibraryLiveForTest(again, backend);
      expect(again.errors, isEmpty);
      expect(again.onlineLibraryItemsApplied, 0);
    });

    test('无头服务端（无参与方）只当信箱：两台客户端经它互相拿到', () async {
      final FushiDatabase hostDb = _memDb();
      final FushiDatabase a = _memDb();
      final FushiDatabase b = _memDb();
      addTearDown(hostDb.close);
      addTearDown(a.close);
      addTearDown(b.close);
      final EpubBookRow manga = await _addManga(a, work, _manga('/m/a', 'A'));
      final (_, String base) = await startServer(hostDb);
      final InterconnectSyncBackend backendA = await client(base);
      final InterconnectSyncBackend backendB = await client(base);

      final SyncRunReport ra = SyncRunReport();
      await orch(
        a,
        backendA,
        'dev-a',
      ).syncOnlineLibraryLiveForTest(ra, backendA);
      final SyncRunReport rb = SyncRunReport();
      await orch(
        b,
        backendB,
        'dev-b',
      ).syncOnlineLibraryLiveForTest(rb, backendB);
      expect(<String>[...ra.errors, ...rb.errors], isEmpty);
      expect(rb.onlineLibraryItemsApplied, 1);
      expect(await b.getEpubBook(manga.bookKey), isNotNull);
      expect(
        await hostDb.getEpubBook(manga.bookKey),
        isNull,
        reason: '无头服务端没有在线源，只存清单不建行',
      );
    });
  });
}

/// 测试小工具：把 [from] 当前的清单并进 applier 的库，返回改动条数。
class OnlineLibraryApplierResultProbe {
  OnlineLibraryApplierResultProbe(this._applier);

  final OnlineLibraryApplier _applier;

  Future<int> applyFrom(FushiDatabase from) async =>
      (await _applier.apply(<OnlineLibraryManifest>[
        await buildLocalOnlineLibraryManifest(from, deviceId: 'peer'),
      ], ownDeviceId: 'self')).changed;
}
