import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/anime_source_video_path.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi/src/media/manga/mihon/mihon_bridge_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/video/online/anime_source_library.dart';
import 'package:fushi/src/media/video/online/anime_source_video_client.dart';
import 'package:path/path.dart' as p;

/// 浏览阶段 2b：在线作品「加入媒体库 / 移出 / 下载后入库 / 从库重开」。
void main() {
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
  late MihonManager manager;
  late VideoBookRepository repository;
  late AnimeSourceLibrary library;

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

  MihonManager newManager() => MihonManager(
    database: database,
    rootDirectory: root,
    runtime: _NoCoverRuntime(),
    kind: MihonMediaKind.anime,
    ownsRuntime: false,
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('hibiki-anime-library-');
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    await insertSource(database);
    manager = newManager();
    await manager.initialise();
    repository = VideoBookRepository(database);
    library = AnimeSourceLibrary(database: database, repository: repository);
  });

  tearDown(() async {
    manager.dispose();
    await database.close();
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
    expect(await library.libraryEpisodeIds(c), isEmpty);
    expect(await library.addToLibrary(c), 3);

    final List<String> ids = <String>[
      for (final RemoteVideoInfo info in c.remoteVideos) info.id,
    ];
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
    expect(await library.libraryEpisodeIds(c), ids.toSet());
    expect(await library.downloadedEpisodeIds(c), isEmpty);

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
    expect(await library.downloadedEpisodeIds(c), <String>{first.id});
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
    expect(await library.libraryEpisodeIds(c), <String>{first.id});
    // 再移出一次：没有在线行可删。
    expect(await library.removeFromLibrary(c), 0);
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

/// 只需要 [contextForSource] 与取封面：取封面一律失败（入库的封面是尽力而为）。
class _NoCoverRuntime extends MihonBridgeRuntime {
  @override
  Future<Object?> invokeBridge(
    MihonExtensionRef extension,
    String method,
    Map<String, Object?> arguments, {
    MihonSource? source,
  }) async {
    if (method == 'preferencesAnime') return <Object?>[];
    throw UnimplementedError(method);
  }

  @override
  Future<Uint8List> fetchSourceImage(
    MihonExtensionRef extension,
    MihonSource source,
    String url, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async => throw const MihonRuntimeException('NO_COVER', 'fixture');

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
