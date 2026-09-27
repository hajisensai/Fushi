import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/anime_source_video_path.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi/src/media/manga/mihon/mihon_bridge_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_source_browse_page.dart';
import 'package:fushi/src/media/online/online_work_detail.dart';
import 'package:fushi/src/media/video/online/anime_source_detail_page.dart';
import 'package:fushi/src/media/video/online/anime_source_video_client.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

import '../../../helpers/test_platform_services.dart';

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

  /// 作品页的库状态读写走真 DB（异步 IO）：在真时间里让它跑完再重建。
  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

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
            w is OnlineWorkItemTile &&
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

  group('primary play button', () {
    late PreferencesRepository prefs;
    late _TestAppModel appModel;

    setUp(() {
      LocaleSettings.setLocale(AppLocale.en);
      prefs = PreferencesRepository(database);
      appModel = _TestAppModel(prefs, root, database);
    });

    String episodeId(String url) =>
        '$kAnimeSourceVideoIdPrefix'
        'eu.kanade.tachiyomi.animeextension.all.fixture:42:$url';

    Future<List<(RemoteVideoInfo, int)>> pumpDetail(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final List<(RemoteVideoInfo, int)> opened = <(RemoteVideoInfo, int)>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            platformServicesProvider.overrideWithValue(testPlatformServices()),
            appProvider.overrideWith((Ref ref) => appModel),
          ],
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
                  ) async => opened.add((info, index)),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      return opened;
    }

    Finder playButton() =>
        find.byKey(const ValueKey<String>('anime_source_play'));

    String playLabel(WidgetTester tester) => tester
        .widget<Text>(
          find.descendant(of: playButton(), matching: find.byType(Text)),
        )
        .data!;

    testWidgets('without any watch position it reads Play and plays the '
        'first episode', (WidgetTester tester) async {
      final List<(RemoteVideoInfo, int)> opened = await pumpDetail(tester);
      expect(find.text('Fixture Show (details)'), findsWidgets);
      expect(playLabel(tester), t.play);
      await tester.tap(playButton());
      await tester.pump();
      expect(opened.single.$2, 0);
      expect(opened.single.$1.id, episodeId('/ep/1'));
    });

    Future<void> seedWatchedAt(
      WidgetTester tester,
      Map<String, int> atByEpisodeUrl,
    ) => tester.runAsync(() async {
      for (final MapEntry<String, int> entry in atByEpisodeUrl.entries) {
        await prefs.setPref(
          videoRemotePositionEpisodeAtPrefKey(episodeId(entry.key), 0),
          entry.value,
        );
      }
    });

    testWidgets('continue watching lands on the episode watched most '
        'recently (episode 2 newer than episode 1)', (
      WidgetTester tester,
    ) async {
      await seedWatchedAt(tester, <String, int>{'/ep/1': 1000, '/ep/2': 2000});
      final List<(RemoteVideoInfo, int)> opened = await pumpDetail(tester);
      final String label = playLabel(tester);
      expect(label, contains(t.video_continue_watching));
      expect(label, contains('Episode 2'));
      await tester.tap(playButton());
      await tester.pump();
      expect(opened.single.$2, 1);
      expect(opened.single.$1.id, episodeId('/ep/2'));
    });

    testWidgets('recency wins over list order: a later-watched episode 1 '
        'beats an earlier-watched episode 2', (WidgetTester tester) async {
      await seedWatchedAt(tester, <String, int>{'/ep/2': 1000, '/ep/1': 2000});
      final List<(RemoteVideoInfo, int)> opened = await pumpDetail(tester);
      expect(playLabel(tester), '${t.video_continue_watching} · Episode 1');
      await tester.tap(playButton());
      await tester.pump();
      expect(opened.single.$2, 0);
    });
  });

  group('media library', () {
    late _TestAppModel appModel;

    setUp(() {
      LocaleSettings.setLocale(AppLocale.en);
      appModel = _TestAppModel(PreferencesRepository(database), root, database);
    });

    Future<void> pumpDetail(
      WidgetTester tester, {
      GlobalKey<NavigatorState>? navigatorKey,
    }) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            platformServicesProvider.overrideWithValue(testPlatformServices()),
            appProvider.overrideWith((Ref ref) => appModel),
          ],
          child: MaterialApp(
            navigatorKey: navigatorKey,
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
                  ) async {},
            ),
          ),
        ),
      );
      await settle(tester);
    }

    Finder addButton() =>
        find.byKey(const ValueKey<String>('anime_source_library_add'));
    Finder removeButton() =>
        find.byKey(const ValueKey<String>('anime_source_library_remove'));

    testWidgets('add writes one online row per episode and flips the button '
        'to remove; remove deletes them again', (WidgetTester tester) async {
      await pumpDetail(tester);
      expect(addButton(), findsOneWidget);
      expect(removeButton(), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('anime_source_download_all')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey<String>(
            'anime_download_$kAnimeSourceVideoIdPrefix'
            'eu.kanade.tachiyomi.animeextension.all.fixture:42:/ep/1',
          ),
        ),
        findsOneWidget,
      );

      await tester.tap(addButton());
      await settle(tester);

      final List<VideoBookRow> rows = (await tester.runAsync(
        database.allVideoBooks,
      ))!;
      expect(rows.length, 2);
      expect(
        rows.every((VideoBookRow r) => isAnimeSourceVideoPath(r.videoPath)),
        isTrue,
      );
      expect(addButton(), findsNothing);
      expect(removeButton(), findsOneWidget);

      await tester.tap(removeButton());
      await settle(tester);

      expect((await tester.runAsync(database.allVideoBooks))!, isEmpty);
      expect(addButton(), findsOneWidget);
      expect(removeButton(), findsNothing);
      expect(tester.takeException(), isNull);
    });

    String episodeId(String url) =>
        '$kAnimeSourceVideoIdPrefix'
        'eu.kanade.tachiyomi.animeextension.all.fixture:42:$url';

    Future<void> seedRow(
      WidgetTester tester,
      String url, {
      required bool downloaded,
    }) => tester.runAsync(
      () => database.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: episodeId(url),
          title: 'Episode',
          videoPath: downloaded
              ? '${root.path}${Platform.pathSeparator}ep.mp4'
              : 'anime-source://fixture/42/Fixture Show - E0',
        ),
      ),
    );

    Future<Map<String, String>> rowsByUid(WidgetTester tester) async =>
        <String, String>{
          for (final VideoBookRow row in (await tester.runAsync(
            database.allVideoBooks,
          ))!)
            row.bookUid: row.videoPath,
        };

    testWidgets('a work with some episodes in the library and a new one '
        'shows both remove and add; add fills in the new episode', (
      WidgetTester tester,
    ) async {
      await seedRow(tester, '/ep/2', downloaded: false);
      await pumpDetail(tester);
      expect(removeButton(), findsOneWidget);
      // 第 1 集还不在库里（刷新后多出来的新集）：仍能加入。
      expect(addButton(), findsOneWidget);

      await tester.tap(addButton());
      await settle(tester);
      final Map<String, String> rows = await rowsByUid(tester);
      expect(rows.keys.toSet(), <String>{
        episodeId('/ep/1'),
        episodeId('/ep/2'),
      });
      expect(rows.values.every(isAnimeSourceVideoPath), isTrue);
      expect(addButton(), findsNothing);
      expect(removeButton(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('after downloading one episode the others can still be added '
        'and nothing online can be removed yet', (WidgetTester tester) async {
      await seedRow(tester, '/ep/1', downloaded: true);
      await pumpDetail(tester);
      expect(addButton(), findsOneWidget);
      expect(removeButton(), findsNothing);

      await tester.tap(addButton());
      await settle(tester);
      final Map<String, String> rows = await rowsByUid(tester);
      // 已下载的集保持本地文件，其余集补成在线行。
      expect(isAnimeSourceVideoPath(rows[episodeId('/ep/1')]!), isFalse);
      expect(isAnimeSourceVideoPath(rows[episodeId('/ep/2')]!), isTrue);
      expect(addButton(), findsNothing);
      expect(removeButton(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('remove deletes only the online rows and says so; the '
        'downloaded episode stays', (WidgetTester tester) async {
      final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();
      FushiToast.navigatorKey = navigator;
      await seedRow(tester, '/ep/1', downloaded: true);
      await seedRow(tester, '/ep/2', downloaded: false);
      await pumpDetail(tester, navigatorKey: navigator);
      expect(removeButton(), findsOneWidget);
      expect(addButton(), findsNothing);

      await tester.tap(removeButton());
      await settle(tester);
      expect((await rowsByUid(tester)).keys, <String>[episodeId('/ep/1')]);
      expect(find.text(t.video_online_library_removed), findsOneWidget);
      expect(removeButton(), findsNothing);
      expect(addButton(), findsOneWidget);
      // 让 toast 的消失计时器走完。
      await tester.pump(const Duration(seconds: 3));
      expect(tester.takeException(), isNull);
    });

    testWidgets('remove that deletes nothing (the online row was downloaded '
        'meanwhile) does not claim it removed anything', (
      WidgetTester tester,
    ) async {
      final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();
      FushiToast.navigatorKey = navigator;
      await seedRow(tester, '/ep/2', downloaded: false);
      await pumpDetail(tester, navigatorKey: navigator);
      expect(removeButton(), findsOneWidget);
      // 页面状态读出后，这一集在后台下载完成、成了本地行。
      await seedRow(tester, '/ep/2', downloaded: true);

      await tester.tap(removeButton());
      await settle(tester);
      expect(find.text(t.video_online_library_removed), findsNothing);
      expect((await rowsByUid(tester)).keys, <String>[episodeId('/ep/2')]);
      expect(removeButton(), findsNothing);
      await tester.pump(const Duration(seconds: 3));
      expect(tester.takeException(), isNull);
    });
  });

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

/// 作品页经 `appProvider` 读远端断点时间戳：挂一份真 [PreferencesRepository]（同一个
/// 内存 DB），其余 AppModel 初始化不跑。
class _TestAppModel extends AppModel {
  _TestAppModel(
    PreferencesRepository prefs,
    Directory root,
    FushiDatabase database,
  ) : super(testPlatformServices()) {
    wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: root);
    // 作品页读「本作品哪些集已在库 / 已下载」要用同一个库。
    wireDatabaseForTesting(database);
  }
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
