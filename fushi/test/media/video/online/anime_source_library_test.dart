import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/video/anime_source_video_path.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_operation_gate.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi/src/media/manga/mihon/mihon_bridge_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extension_store_client.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/video/online/anime_source_library.dart';
import 'package:fushi/src/media/video/online/anime_source_video_client.dart';
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

/// 浏览阶段 2b：在线作品「加入媒体库 / 移出 / 下载后入库 / 从库重开」。
void main() {
  // 封面落盘后要驱逐解码缓存（PaintingBinding）。
  TestWidgetsFlutterBinding.ensureInitialized();

  const String pkg = 'eu.kanade.tachiyomi.animeextension.all.fixture';
  const MihonAnime anime = MihonAnime(
    url: '/anime/1',
    title: 'Fixture Show',
    // 有封面地址但扩展取图失败：封面是尽力而为，入库照常完成。
    coverUrl: 'https://site.example/cover.jpg',
  );
  const List<MihonEpisode> episodes = <MihonEpisode>[
    MihonEpisode(url: '/ep/1', name: 'Episode 1', uploadedAt: 1, number: 1),
    MihonEpisode(url: '/ep/2', name: 'Episode 2', uploadedAt: 2, number: 2),
    MihonEpisode(url: '/ep/3', name: 'Episode 3', uploadedAt: 3, number: 3),
  ];

  late Directory root;
  late FushiDatabase database;
  late _NoCoverRuntime runtime;
  late MihonManager manager;
  late VideoBookRepository repository;
  late AnimeSourceLibrary library;
  late EnginePaths previousPaths;

  Future<void> insertSource(FushiDatabase db) async {
    await db.upsertMangaExtension(
      MangaExtensionsCompanion.insert(
        packageName: pkg,
        name: 'Fixture',
        versionCode: 9,
        versionName: '14.9',
        libVersion: '14',
        language: 'all',
        apkPath: 'extensions/fixture.apk',
        apkSha256: 'aa',
        signerSha256: 'bb',
        installedAt: 1,
        mediaKind: const Value('anime'),
      ),
    );
    await db.replaceMangaOnlineSources(pkg, <MangaOnlineSourcesCompanion>[
      MangaOnlineSourcesCompanion.insert(
        extensionPackage: pkg,
        sourceId: '42',
        name: 'Fixture Anime',
        language: 'all',
        mediaKind: const Value('anime'),
      ),
    ]);
  }

  MihonManager newManager({MihonExtensionStoreClient? storeClient}) =>
      MihonManager(
        database: database,
        rootDirectory: root,
        runtime: runtime,
        kind: MihonMediaKind.anime,
        ownsRuntime: false,
        storeClient: storeClient,
      );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('hibiki-anime-library-');
    // 封面目录落在临时根下（不碰本机真实数据根）。
    previousPaths = enginePaths;
    enginePaths = FixedEnginePaths(
      documents: Directory(p.join(root.path, 'documents')),
      support: Directory(p.join(root.path, 'support')),
      temp: Directory(p.join(root.path, 'temp')),
    );
    VideoCoverMutationGate.debugResetForTesting();
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    await insertSource(database);
    runtime = _NoCoverRuntime();
    manager = newManager();
    await manager.initialise();
    repository = VideoBookRepository(database);
    library = AnimeSourceLibrary(database: database, repository: repository);
  });

  tearDown(() async {
    manager.dispose();
    await database.close();
    enginePaths = previousPaths;
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<AnimeSourceVideoClient> client({
    List<MihonEpisode> list = episodes,
  }) async => AnimeSourceVideoClient(
    manager: manager,
    context: await manager.contextForSource(manager.sources.single),
    anime: anime,
    episodes: list,
    subtitleLanguageResolver: () => null,
  );

  Future<MediaCollectionRow> playlist() async =>
      (await database.getMediaCollectionByNaturalKey(anime.title, 'playlist'))!;

  Future<List<String>> playlistOrder() async {
    final List<MediaCollectionItemRow> items = await database
        .getCollectionItems((await playlist()).id);
    items.sort(
      (MediaCollectionItemRow a, MediaCollectionItemRow b) =>
          a.sortIndex.compareTo(b.sortIndex),
    );
    return <String>[
      for (final MediaCollectionItemRow item in items) item.entryKey,
    ];
  }

  test('addToLibrary writes one online row per episode and adopts them into '
      'the anime playlist in order', () async {
    final AnimeSourceVideoClient c = await client();
    final List<String> ids = <String>[
      for (final RemoteVideoInfo info in c.remoteVideos) info.id,
    ];
    final AnimeSourceEpisodeStatus before = await library.episodeStatus(c);
    expect(before.missing, ids.toSet());
    expect(before.online, isEmpty);
    expect(before.canAdd, isTrue);
    expect(before.canRemove, isFalse);
    expect(await library.addToLibrary(c), 3);

    for (int i = 0; i < ids.length; i++) {
      final VideoBookRow row = (await repository.getByBookUid(ids[i]))!;
      expect(row.title, 'Episode ${i + 1}');
      expect(isAnimeSourceVideoPath(row.videoPath), isTrue);
      expect(row.videoPath, 'anime-source://$pkg/42/Fixture Show - E0${i + 1}');
      final AnimeSourceBookSpec spec = AnimeSourceBookSpec.tryParse(
        row.streamSpecJson,
      )!;
      expect(spec.extensionPackage, pkg);
      expect(spec.sourceId, '42');
      expect(spec.anime.url, anime.url);
      expect(spec.episode.url, episodes[i].url);
      expect(row.importedAt, isNotNull);
    }
    expect(await playlistOrder(), ids);
    final AnimeSourceEpisodeStatus after = await library.episodeStatus(c);
    expect(after.online, ids.toSet());
    expect(after.downloaded, isEmpty);
    expect(after.missing, isEmpty);
    expect(after.canAdd, isFalse);
    expect(after.canRemove, isTrue);

    // 再点一次：不重复建行，合集成员不变。
    expect(await library.addToLibrary(c), 0);
    expect((await database.allVideoBooks()).length, 3);
    expect(await playlistOrder(), ids);
  });

  test('refreshing with a new episode only adds the new one', () async {
    await library.addToLibrary(await client(list: episodes.sublist(0, 2)));
    final AnimeSourceVideoClient full = await client();
    expect(await library.addToLibrary(full), 1);
    expect((await database.allVideoBooks()).length, 3);
    expect(await playlistOrder(), <String>[
      for (final RemoteVideoInfo info in full.remoteVideos) info.id,
    ]);
  });

  test('registerDownloaded turns the online row into a local video with the '
      'same bookUid; removeFromLibrary keeps it', () async {
    final AnimeSourceVideoClient c = await client();
    await library.addToLibrary(c);
    final RemoteVideoInfo first = c.remoteVideos.first;
    final File file = File(p.join(root.path, 'ep1.mp4'))
      ..writeAsBytesSync(<int>[1, 2, 3]);

    await library.registerDownloaded(c, first, file);

    final VideoBookRow row = (await repository.getByBookUid(first.id))!;
    expect(row.bookUid, first.id);
    expect(row.videoPath, file.path);
    expect(row.streamSpecJson, isNull);
    expect(isNetworkOnlyVideoPath(row.videoPath), isFalse);
    expect((await library.episodeStatus(c)).downloaded, <String>{first.id});
    expect((await database.allVideoBooks()).length, 3);
    // 仍在作品合集里、顺序不变。
    expect(await playlistOrder(), <String>[
      for (final RemoteVideoInfo info in c.remoteVideos) info.id,
    ]);

    // 移出：只删在线行，已下载的本地集留在库里。
    expect(await library.removeFromLibrary(c), 2);
    final List<VideoBookRow> left = await database.allVideoBooks();
    expect(left.map((VideoBookRow r) => r.bookUid), <String>[first.id]);
    expect(left.single.videoPath, file.path);
    expect(await file.exists(), isTrue);
    final AnimeSourceEpisodeStatus left2 = await library.episodeStatus(c);
    expect(left2.online, isEmpty);
    expect(left2.downloaded, <String>{first.id});
    expect(left2.canRemove, isFalse);
    // 下载过的那集之外的集又能加入了。
    expect(left2.missing, <String>{
      for (final RemoteVideoInfo info in c.remoteVideos.skip(1)) info.id,
    });
    expect(left2.canAdd, isTrue);
    // 再移出一次：没有在线行可删。
    expect(await library.removeFromLibrary(c), 0);
  });

  test(
    'after downloading one episode without adding the work, adding it '
    'fills in the other episodes and keeps the downloaded one local',
    () async {
      final AnimeSourceVideoClient c = await client();
      final RemoteVideoInfo first = c.remoteVideos.first;
      final File file = File(p.join(root.path, 'ep1.mp4'))
        ..writeAsBytesSync(<int>[1]);
      await library.registerDownloaded(c, first, file);
      final AnimeSourceEpisodeStatus status = await library.episodeStatus(c);
      expect(status.downloaded, <String>{first.id});
      expect(status.canAdd, isTrue);
      expect(status.canRemove, isFalse);

      expect(await library.addToLibrary(c), 2);
      expect((await repository.getByBookUid(first.id))!.videoPath, file.path);
      final AnimeSourceEpisodeStatus added = await library.episodeStatus(c);
      expect(added.online, <String>{
        for (final RemoteVideoInfo info in c.remoteVideos.skip(1)) info.id,
      });
      expect(added.canAdd, isFalse);
      expect(await playlistOrder(), <String>[
        for (final RemoteVideoInfo info in c.remoteVideos) info.id,
      ]);
    },
  );

  test('registerDownloaded keeps the row subtitle when the source has no '
      'default subtitle track', () async {
    final AnimeSourceVideoClient c = await client();
    await library.addToLibrary(c);
    final RemoteVideoInfo first = c.remoteVideos.first;
    final String subtitle = p.join(root.path, 'mine.ja.srt');
    await (database.update(
      database.videoBooks,
    )..where(($VideoBooksTable t) => t.bookUid.equals(first.id))).write(
      VideoBooksCompanion(
        subtitleSource: Value<String?>(subtitle),
        subtitleFormat: const Value<String?>('srt'),
      ),
    );
    await library.registerDownloaded(
      c,
      first,
      File(p.join(root.path, 'ep1.mp4'))..writeAsBytesSync(<int>[1]),
    );
    final VideoBookRow row = (await repository.getByBookUid(first.id))!;
    expect(row.subtitleSource, subtitle);
    expect(row.subtitleFormat, 'srt');
  });

  group('online watch position carries over to the downloaded row', () {
    Future<VideoBookRow> register(
      AnimeSourceVideoClient c,
      AnimeOnlinePosition? position,
    ) async {
      final AnimeSourceLibrary withPosition = AnimeSourceLibrary(
        database: database,
        repository: repository,
        onlinePositionReader: (String id) =>
            id == c.remoteVideos.first.id ? position : null,
      );
      await withPosition.registerDownloaded(
        c,
        c.remoteVideos.first,
        File(p.join(root.path, 'ep1.mp4'))..writeAsBytesSync(<int>[1]),
      );
      return (await repository.getByBookUid(c.remoteVideos.first.id))!;
    }

    test('a never-played row takes the online position and time', () async {
      final VideoBookRow row = await register(await client(), (
        positionMs: 90000,
        playedAt: 1700000000000,
      ));
      expect(row.lastPositionMs, 90000);
      expect(row.lastPlayedAt, 1700000000000);
    });

    test('a row with a newer position of its own keeps it', () async {
      final AnimeSourceVideoClient c = await client();
      await library.addToLibrary(c);
      await repository.updatePosition(
        c.remoteVideos.first.id,
        30000,
        playedAt: 1800000000000,
      );
      final VideoBookRow row = await register(c, (
        positionMs: 90000,
        playedAt: 1700000000000,
      ));
      expect(row.lastPositionMs, 30000);
      expect(row.lastPlayedAt, 1800000000000);
    });

    test('a newer online position replaces an older row position', () async {
      final AnimeSourceVideoClient c = await client();
      await library.addToLibrary(c);
      await repository.updatePosition(
        c.remoteVideos.first.id,
        30000,
        playedAt: 1600000000000,
      );
      final VideoBookRow row = await register(c, (
        positionMs: 90000,
        playedAt: 1700000000000,
      ));
      expect(row.lastPositionMs, 90000);
      expect(row.lastPlayedAt, 1700000000000);
    });

    test('no online position leaves the row alone', () async {
      final VideoBookRow row = await register(await client(), null);
      expect(row.lastPositionMs, 0);
      expect(row.lastPlayedAt, isNull);
    });
  });

  test('covers: one shared file per work (short name), fetched once, kept '
      'while any episode row references it and reclaimed with the last '
      'one', () async {
    runtime.cover = _jpeg();
    final AnimeSourceVideoClient twoEpisodes = await client(
      list: episodes.sublist(0, 2),
    );
    await library.addToLibrary(twoEpisodes);
    final AnimeSourceVideoClient c = await client();
    expect(await library.addToLibrary(c), 1);
    final List<String> ids = <String>[
      for (final RemoteVideoInfo info in c.remoteVideos) info.id,
    ];
    final Set<String?> covers = <String?>{
      for (final String id in ids)
        (await repository.getByBookUid(id))!.coverPath,
    };
    expect(covers.length, 1, reason: 'every episode points at one file');
    final String cover = covers.single!;
    expect(
      p.basename(cover),
      matches(RegExp(r'^anime_source_[0-9a-f]{40}\.jpg$')),
    );
    expect(p.isWithin(p.join(root.path, 'documents'), cover), isTrue);
    expect(await File(cover).readAsBytes(), _jpeg());
    // 第二次入库（补新集）不再联网取图，只把新行指到已有文件。
    expect(runtime.coverFetches, 1);
    final MediaCollectionRow collection = await playlist();
    expect(collection.coverPath, isNotNull);
    expect(await File(collection.coverPath!).exists(), isTrue);

    // 删一集：别的集还引用着，共用封面留着。
    await repository.deleteVideoBooksAndReclaimAssets(<String>[ids.first]);
    expect(await File(cover).exists(), isTrue);
    // 移出剩下的在线行：最后一个引用没了，文件随之回收。
    expect(await library.removeFromLibrary(c), 2);
    expect(await File(cover).exists(), isFalse);
  });

  test('a cover that cannot be written does not fail adding to the '
      'library', () async {
    runtime.cover = Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
    final AnimeSourceVideoClient c = await client();
    expect(await library.addToLibrary(c), 3);
    for (final RemoteVideoInfo info in c.remoteVideos) {
      expect((await repository.getByBookUid(info.id))!.coverPath, isNull);
    }
  });

  test('startAnimeEpisodeDownloads does not re-download an episode whose '
      'file is already at its destination; it registers it instead', () async {
    final AnimeSourceVideoClient c = await client();
    await library.addToLibrary(c);
    final RemoteVideoInfo first = c.remoteVideos.first;
    final Directory dir = Directory(p.join(root.path, 'downloads'))
      ..createSync(recursive: true);
    final File dest = File(
      p.join(dir.path, animeEpisodeDownloadFileName(c, first)),
    )..writeAsBytesSync(<int>[1, 2, 3]);
    final InterconnectDownloadManager downloads = InterconnectDownloadManager();
    addTearDown(downloads.dispose);
    await startAnimeEpisodeDownloads(
      manager: downloads,
      library: library,
      template: c,
      episodeIds: <String>[first.id],
      destinationDirectory: dir,
    );
    // 没起任务（起了就会向扩展取流：本夹具的运行时一取就抛）。
    expect(downloads.taskFor(first.id), isNull);
    expect(runtime.videoRequests, 0);
    expect((await repository.getByBookUid(first.id))!.videoPath, dest.path);
    expect(await dest.readAsBytes(), <int>[1, 2, 3]);
    c.dispose();
  });

  test('registerDownloaded without a prior online row still registers the '
      'local video into the playlist', () async {
    final AnimeSourceVideoClient c = await client();
    final RemoteVideoInfo second = c.remoteVideos[1];
    final File file = File(p.join(root.path, 'ep2.mp4'))
      ..writeAsBytesSync(<int>[9]);
    await library.registerDownloaded(c, second, file);
    final VideoBookRow row = (await repository.getByBookUid(second.id))!;
    expect(row.videoPath, file.path);
    expect(row.importedAt, isNotNull);
    expect(await playlistOrder(), <String>[second.id]);
  });

  group('buildAnimeSourceLaunch', () {
    test('rebuilds playlist members from the collection with row ids and '
        'starts at the opened row', () async {
      final AnimeSourceVideoClient c = await client();
      await library.addToLibrary(c);
      final List<String> ids = <String>[
        for (final RemoteVideoInfo info in c.remoteVideos) info.id,
      ];
      final VideoBookRow opened = (await repository.getByBookUid(ids[1]))!;

      final launch = await buildAnimeSourceLaunch(
        row: opened,
        database: database,
        repository: repository,
        manager: manager,
        playlistCollectionId: (await playlist()).id,
      );

      expect(launch.members.map((RemoteVideoInfo m) => m.id), ids);
      expect(launch.client.remoteVideos.map((RemoteVideoInfo m) => m.id), ids);
      expect(launch.startIndex, 1);
      expect(launch.info.id, ids[1]);
      expect(launch.client.anime.url, anime.url);
      expect(launch.client.episodes.map((MihonEpisode e) => e.url), <String>[
        '/ep/1',
        '/ep/2',
        '/ep/3',
      ]);
      expect(launch.client.context.source.id, '42');
      launch.client.dispose();
    });

    test('downloaded members drop out of the online playlist', () async {
      final AnimeSourceVideoClient c = await client();
      await library.addToLibrary(c);
      final List<RemoteVideoInfo> infos = c.remoteVideos;
      await library.registerDownloaded(
        c,
        infos.first,
        File(p.join(root.path, 'ep1.mp4'))..writeAsBytesSync(<int>[1]),
      );
      final VideoBookRow opened = (await repository.getByBookUid(infos[2].id))!;
      final launch = await buildAnimeSourceLaunch(
        row: opened,
        database: database,
        repository: repository,
        manager: manager,
        playlistCollectionId: (await playlist()).id,
      );
      expect(launch.members.map((RemoteVideoInfo m) => m.id), <String>[
        infos[1].id,
        infos[2].id,
      ]);
      expect(launch.startIndex, 1);
      launch.client.dispose();
    });

    test('without a collection only the opened episode is a member', () async {
      final AnimeSourceVideoClient c = await client();
      await library.addToLibrary(c);
      final String id = c.remoteVideos[2].id;
      final launch = await buildAnimeSourceLaunch(
        row: (await repository.getByBookUid(id))!,
        database: database,
        repository: repository,
        manager: manager,
      );
      expect(launch.members.map((RemoteVideoInfo m) => m.id), <String>[id]);
      expect(launch.startIndex, 0);
      expect(launch.info.id, id);
      launch.client.dispose();
    });

    test('a row without a parseable spec is unavailable', () async {
      final AnimeSourceVideoClient c = await client();
      await library.addToLibrary(c);
      final VideoBookRow row = (await repository.getByBookUid(
        c.remoteVideos.first.id,
      ))!;
      await expectLater(
        buildAnimeSourceLaunch(
          row: row.copyWith(streamSpecJson: const Value<String?>('{}')),
          database: database,
          repository: repository,
          manager: manager,
        ),
        throwsA(isA<AnimeSourceLaunchUnavailable>()),
      );
    });

    test('launching reads installed sources locally and never refreshes '
        'extension stores over the network', () async {
      final AnimeSourceVideoClient c = await client();
      await library.addToLibrary(c);
      await database.upsertMangaExtensionStore(
        MangaExtensionStoresCompanion.insert(
          indexUrl: 'https://repo.example/index.min.json',
          mediaKind: const Value('anime'),
          name: 'Repo',
          format: 'legacy',
        ),
      );
      int storeRequests = 0;
      // 冷启动的 manager（没跑过 initialise）：initialise 会去拉这个仓库的索引。
      final MihonManager cold = newManager(
        storeClient: MihonExtensionStoreClient(
          client: MockClient((http.Request request) async {
            storeRequests++;
            return http.Response('offline', 503);
          }),
        ),
      );
      addTearDown(cold.dispose);
      final String id = c.remoteVideos.first.id;
      final launch = await buildAnimeSourceLaunch(
        row: (await repository.getByBookUid(id))!,
        database: database,
        repository: repository,
        manager: cold,
      );
      expect(launch.info.id, id);
      expect(storeRequests, 0);
      launch.client.dispose();
    });

    test('an uninstalled source is reported as unavailable', () async {
      final AnimeSourceVideoClient c = await client();
      await library.addToLibrary(c);
      final VideoBookRow row = (await repository.getByBookUid(
        c.remoteVideos.first.id,
      ))!;
      await database.replaceMangaOnlineSources(
        pkg,
        const <MangaOnlineSourcesCompanion>[],
      );
      final MihonManager empty = newManager();
      addTearDown(empty.dispose);
      await expectLater(
        buildAnimeSourceLaunch(
          row: row,
          database: database,
          repository: repository,
          manager: empty,
          playlistCollectionId: (await playlist()).id,
        ),
        throwsA(
          isA<AnimeSourceLaunchUnavailable>().having(
            (AnimeSourceLaunchUnavailable e) => e.message,
            'message',
            contains(pkg),
          ),
        ),
      );
    });
  });

  test('animeEpisodeDownloadFileName is readable, sanitised and pinned to '
      'the episode id', () async {
    final AnimeSourceVideoClient c = await client(
      list: const <MihonEpisode>[
        MihonEpisode(url: '/ep/a', name: 'A', uploadedAt: 0, number: 1),
        MihonEpisode(url: '/ep/b', name: 'B', uploadedAt: 0, number: 1),
      ],
    );
    final List<RemoteVideoInfo> infos = c.remoteVideos;
    final String a = animeEpisodeDownloadFileName(c, infos[0]);
    final String b = animeEpisodeDownloadFileName(c, infos[1]);
    expect(a, startsWith('Fixture Show - E01.'));
    expect(a, endsWith('.mp4'));
    expect(a, isNot(b));
    expect(animeEpisodeDownloadFileName(c, infos[0]), a);
    expect(a, isNot(matches(RegExp(r'[\\/:*?"<>|]'))));
    c.dispose();
  });
}

/// 完整可解码的最小 JPEG 形状（SOI … EOI）：封面写盘只认完整图片。
Uint8List _jpeg() => Uint8List.fromList(<int>[
  0xFF, 0xD8, 0xFF, 0xE0, //
  ...List<int>.filled(28, 0x11),
  0xFF, 0xD9,
]);

/// 只需要 [contextForSource] 与取封面：默认取封面一律失败（入库的封面是尽力而为），
/// 设了 [cover] 就返回它。取流（`getVideoList`）一律抛，并计数。
class _NoCoverRuntime extends MihonBridgeRuntime {
  Uint8List? cover;
  int coverFetches = 0;
  int videoRequests = 0;

  @override
  Future<Object?> invokeBridge(
    MihonExtensionRef extension,
    String method,
    Map<String, Object?> arguments, {
    MihonSource? source,
  }) async {
    if (method == 'preferencesAnime') return <Object?>[];
    if (method == 'getVideoList') videoRequests++;
    throw UnimplementedError(method);
  }

  @override
  Future<Uint8List> fetchSourceImage(
    MihonExtensionRef extension,
    MihonSource source,
    String url, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    coverFetches++;
    final Uint8List? bytes = cover;
    if (bytes == null) {
      throw const MihonRuntimeException('NO_COVER', 'fixture');
    }
    return bytes;
  }

  @override
  Future<Uint8List> fetchImage(
    MihonExtensionRef extension,
    MihonSource source,
    MihonPage page, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) => throw UnimplementedError();

  @override
  Future<MihonCapabilities> getCapabilities() => throw UnimplementedError();

  @override
  Future<MihonExtensionInspection> inspectExtension(String apkPath) =>
      throw UnimplementedError();

  @override
  Future<String> installPrivateExtension(String apkPath) =>
      throw UnimplementedError();

  @override
  Future<void> uninstallPrivateExtension(String packageName) =>
      throw UnimplementedError();

  @override
  Future<void> clearSourceData(
    MihonExtensionRef extension,
    MihonSource source,
  ) => throw UnimplementedError();

  @override
  Future<void> invalidateExtension(String packageName) =>
      throw UnimplementedError();

  @override
  Future<void> invalidateExtensions(Iterable<String> packageNames) =>
      throw UnimplementedError();

  @override
  Future<void> dispose() async {}
}
