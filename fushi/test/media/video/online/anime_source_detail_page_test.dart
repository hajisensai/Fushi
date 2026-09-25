import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi/src/media/manga/mihon/mihon_bridge_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_source_browse_page.dart';
import 'package:fushi/src/media/video/online/anime_source_detail_page.dart';
import 'package:fushi/src/media/video/online/anime_source_video_client.dart';
import 'package:fushi/src/sync/remote_video_client.dart';

/// 视频源扩展的浏览 → 作品页 → 起播链路（播放页本体被 openPlayer 桩替换：widget
/// 测试里起不了 libmpv）。
void main() {
  late Directory root;
  late FushiDatabase database;
  late _AnimeRuntime runtime;
  late MihonManager manager;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('hibiki-anime-detail-');
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    runtime = _AnimeRuntime();
    await database.upsertMangaExtension(
      MangaExtensionsCompanion.insert(
        packageName: 'eu.kanade.tachiyomi.animeextension.all.fixture',
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
    await database.replaceMangaOnlineSources(
      'eu.kanade.tachiyomi.animeextension.all.fixture',
      <MangaOnlineSourcesCompanion>[
        MangaOnlineSourcesCompanion.insert(
          extensionPackage: 'eu.kanade.tachiyomi.animeextension.all.fixture',
          sourceId: '42',
          name: 'Fixture Anime',
          language: 'all',
          mediaKind: const Value('anime'),
        ),
      ],
    );
    manager = MihonManager(
      database: database,
      rootDirectory: root,
      runtime: runtime,
      kind: MihonMediaKind.anime,
      ownsRuntime: false,
    );
    await manager.initialise();
  });

  tearDown(() async {
    manager.dispose();
    await database.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<MihonSourceContext> context() =>
      manager.contextForSource(manager.sources.single);

  testWidgets('browse grid of an anime manager opens the anime detail page', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: MihonSourceBrowsePage(
            manager: manager,
            target: MihonInstalledTarget(manager.sources.single),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(runtime.calls, contains('filtersAnime'));
    expect(runtime.calls, contains('getPopularAnime'));
    expect(find.text('Fixture Show'), findsOneWidget);
    await tester.tap(find.text('Fixture Show'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(AnimeSourceDetailPage), findsOneWidget);
    expect(runtime.calls, contains('getDetailsAnime'));
    expect(runtime.calls, contains('getEpisodeList'));
  });

  testWidgets(
    'episodes list in playback order and a single candidate plays directly',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final List<(RemoteVideoInfo, int)> opened = <(RemoteVideoInfo, int)>[];
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: AnimeSourceDetailPage(
              manager: manager,
              sourceContext: await context(),
              anime: const MihonAnime(url: '/anime/1', title: 'Fixture Show'),
              subtitleLanguageResolver: () => null,
              openPlayer:
                  (
                    _,
                    AnimeSourceVideoClient client,
                    RemoteVideoInfo info,
                    int index,
                  ) async {
                    opened.add((info, index));
                    // 取流留给播放页：它取完流、load 前读到的头就是那条流的头。
                    await client.remoteVideoStreamUrls(info.id);
                    expect(client.httpHeaderFields, <String, String>{
                      'Referer': 'https://site.example/',
                    });
                  },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Fixture Show (details)'), findsWidgets);
      // 源给的是新集在前，页面按集号升序排。
      final Finder rows = find.byWidgetPredicate(
        (Widget w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('anime_episode_'),
      );
      expect(rows, findsNWidgets(2));
      expect(
        tester
            .widgetList(rows)
            .map((Widget w) => (w.key! as ValueKey<String>).value),
        <String>['anime_episode_/ep/1', 'anime_episode_/ep/2'],
      );

      runtime.videos = <Object?>[
        <Object?, Object?>{
          'url': 'https://cdn.example/ep1.m3u8',
          'quality': '1080p',
          'headers': <Object?, Object?>{'Referer': 'https://site.example/'},
        },
      ];
      await tester.tap(find.text('Episode 1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(opened.single.$2, 0);
      expect(opened.single.$1.id, endsWith(':42:/ep/1'));
      expect(opened.single.$1.collection?.collectionType, 'playlist');
    },
  );

  testWidgets(
    'several candidates open the player at once with the default line, '
    'and the player can switch lines afterwards',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      AnimeSourceVideoClient? opened;
      String? openedId;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: AnimeSourceDetailPage(
              manager: manager,
              sourceContext: await context(),
              anime: const MihonAnime(url: '/anime/1', title: 'Fixture Show'),
              subtitleLanguageResolver: () => null,
              openPlayer:
                  (
                    _,
                    AnimeSourceVideoClient client,
                    RemoteVideoInfo info,
                    int index,
                  ) async {
                    opened = client;
                    openedId = info.id;
                  },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      runtime.videos = <Object?>[
        <Object?, Object?>{
          'url': 'https://cdn.example/1080.mp4',
          'quality': '1080p',
        },
        <Object?, Object?>{
          'url': 'https://cdn.example/480.mp4',
          'quality': '480p',
        },
      ];
      await tester.tap(find.text('Episode 2'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // 不再弹「选一条流」拦一道：作品页也不预解析，取流留给播放页。
      expect(find.text('Choose a stream'), findsNothing);
      expect(runtime.calls, isNot(contains('getVideoList')));
      expect(openedId, endsWith(':42:/ep/2'));
      // 播放页取流：默认线路 = 扩展给的第一条，线路菜单列出两条并标出当前。
      final AnimeSourceVideoClient client = opened!;
      final RemoteVideoStreamUrls urls = await client.remoteVideoStreamUrls(
        openedId!,
      );
      expect(urls.streamUrl, 'https://cdn.example/1080.mp4');
      expect(
        client.streamVariants
            .map((RemoteVideoStreamVariant v) => v.label)
            .toList(),
        <String>['1080p', '480p'],
      );
      expect(client.streamVariantIndex, 0);
      // 播放器里换线路：钉住后重新取流播那条，不再问扩展。
      client.streamVariantIndex = 1;
      final RemoteVideoStreamUrls switched = await client.remoteVideoStreamUrls(
        openedId!,
      );
      expect(switched.streamUrl, 'https://cdn.example/480.mp4');
      expect(client.streamVariantIndex, 1);
      expect(runtime.calls.where((String c) => c == 'getVideoList').length, 1);
    },
  );

  testWidgets('an episode without streams still opens the player, '
      'which reports NO stream on load', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    AnimeSourceVideoClient? opened;
    String? openedId;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: AnimeSourceDetailPage(
            manager: manager,
            sourceContext: await context(),
            anime: const MihonAnime(url: '/anime/1', title: 'Fixture Show'),
            subtitleLanguageResolver: () => null,
            openPlayer:
                (
                  _,
                  AnimeSourceVideoClient client,
                  RemoteVideoInfo info,
                  int index,
                ) async {
                  opened = client;
                  openedId = info.id;
                },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    runtime.videos = <Object?>[];
    await tester.tap(find.text('Episode 1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(opened, isNotNull);
    await expectLater(
      () => opened!.remoteVideoStreamUrls(openedId!),
      throwsA(
        isA<MihonRuntimeException>().having(
          (MihonRuntimeException e) => e.code,
          'code',
          'NO_VIDEOS',
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'open on website asks the extension for the page url and hands it to the browser',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final List<Uri> launched = <Uri>[];
      runtime.animeUrl = 'https://site.example/watch/fixture-show';
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: AnimeSourceDetailPage(
              manager: manager,
              sourceContext: await context(),
              anime: const MihonAnime(url: '/anime/1', title: 'Fixture Show'),
              openExternal: (Uri url) async => launched.add(url),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('anime_source_open_website')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(runtime.calls, contains('getAnimeUrl'));
      // 详情合并后身份仍是入参的 url，问扩展时带的也是它。
      expect(runtime.animeUrlRequests, <String>['/anime/1']);
      expect(launched, <Uri>[
        Uri.parse('https://site.example/watch/fixture-show'),
      ]);
      expect(tester.takeException(), isNull);
    },
  );
}

class _AnimeRuntime extends MihonBridgeRuntime {
  final List<String> calls = <String>[];
  Object? videos = <Object?>[];
  String? animeUrl;
  final List<String> animeUrlRequests = <String>[];

  @override
  Future<Object?> invokeBridge(
    MihonExtensionRef extension,
    String method,
    Map<String, Object?> arguments, {
    MihonSource? source,
  }) async {
    calls.add(method);
    switch (method) {
      case 'filtersAnime':
        return <Object?>[];
      case 'getPopularAnime':
      case 'getLatestAnime':
      case 'getSearchAnime':
        return <Object?, Object?>{
          'animes': <Object?>[
            <Object?, Object?>{'url': '/anime/1', 'title': 'Fixture Show'},
          ],
          'hasNextPage': false,
        };
      case 'getDetailsAnime':
        return <Object?, Object?>{
          'url': '',
          'title': 'Fixture Show (details)',
          'description': 'A show.',
        };
      case 'getEpisodeList':
        return <Object?>[
          <Object?, Object?>{
            'url': '/ep/2',
            'name': 'Episode 2',
            'episode_number': 2,
          },
          <Object?, Object?>{
            'url': '/ep/1',
            'name': 'Episode 1',
            'episode_number': 1,
          },
        ];
      case 'getVideoList':
        return videos;
      case 'getAnimeUrl':
        animeUrlRequests.add(
          (arguments['animeData']! as Map<String, Object?>)['url']! as String,
        );
        return animeUrl;
      case 'preferencesAnime':
        return <Object?>[];
    }
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
