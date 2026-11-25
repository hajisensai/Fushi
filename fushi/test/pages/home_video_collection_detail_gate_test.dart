import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/video_collection_open_request.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/pages/implementations/media_collection_detail_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteCollectionMembership, RemoteVideoInfo;
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// BUG-1891 止血闸门的**合集详情**入口守卫。
///
/// 库页自己取清单走 `_readRemoteVideoList`：Jellyfin/Emby 关掉「自动列出条目」→
/// 只读缓存、不取数。但合集详情页的远端上下文（`_collectionRemoteContext`）此前
/// 直接 `_remoteCache.read(fetch: listRemoteVideos)` 绕过了这道闸门——大库用户关掉
/// 开关后点进任意一个含「只在对端」成员的合集，TTL 一过仍触发整台服务器的全库
/// 递归枚举。本测试驱动真页面：种一个成员缺本地行的合集（详情页因此必须问远端
/// 清单），断言闸门关时点进详情**一次** `listRemoteVideos` 都不发；再以闸门开为
/// 对照，证明这条路径确实会取数（不是测试自己没走到）。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_collection_gate_pp',
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => pathProviderDir.path,
    );
  });
  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (pathProviderDir.existsSync()) {
      try {
        pathProviderDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  late FushiDatabase db;
  late PreferencesRepository prefs;
  late PlatformServices platformServices;
  late FakeAnkiRepository ankiRepository;
  late AppModel appModel;
  late Directory storeDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_collection_gate');
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) {
      storeDir.deleteSync(recursive: true);
    }
  });

  /// 系列墙入墙资格 = 有 AniDB 主身份的规范作品（与
  /// home_video_collection_cover_card_test 同一手法）；ep2 **只在合集清单里**、
  /// 本地没有视频行——详情页解析成员时必然要问远端清单。
  Future<int> seedCollectionWithRemoteOnlyMember() async {
    await db.upsertVideoBook(
      const VideoBooksCompanion(
        bookUid: Value('video/ep1'),
        title: Value('第1集'),
        videoPath: Value('/abs/ep1.mp4'),
      ),
    );
    final int cid = await db.createMediaCollection(
      '某番剧',
      collectionType: 'playlist',
    );
    await db.addToCollection(cid, MediaKind.video, 'video/ep1');
    await db.addToCollection(cid, MediaKind.video, 'video/ep2');
    final int workId = await db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        mediaType: 'tv',
        title: '某番剧',
        collectionId: Value<int?>(cid),
        updatedAt: DateTime(2026, 1, 1).millisecondsSinceEpoch,
      ),
    );
    await db.replaceVideoMetadataProviderIdentities(
      workId: workId,
      identities: <VideoMetadataProviderIdentitiesCompanion>[
        VideoMetadataProviderIdentitiesCompanion.insert(
          identityKey: 'work:$workId:anidb',
          provider: 'anidb',
          externalId: 'anidb-$cid',
          isPrimary: const Value<bool>(true),
          updatedAt: DateTime(2026, 1, 1).millisecondsSinceEpoch,
        ),
      ],
    );
    return cid;
  }

  Widget buildApp(JellyfinVideoClient client) => ProviderScope(
    overrides: <Override>[
      platformServicesProvider.overrideWithValue(platformServices),
      ankiRepositoryProvider.overrideWithValue(ankiRepository),
      appProvider.overrideWith((ref) => appModel),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: HomeVideoPage(
            repo: VideoBookRepository(db),
            section: VideoLibrarySection.series,
            remoteVideoClientLoader: () async => client,
          ),
        ),
      ),
    ),
  );

  Future<void> openCollectionDetail(WidgetTester tester, int cid) async {
    // 顶部 hero / 横滚行之下的墙在 800 高视口里会被懒构建跳过；抬高视口。
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey<String>('home_video_collection_card_$cid')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byType(MediaCollectionDetailPage),
      findsOneWidget,
      reason: '前提：整卡点击必须真的进了合集详情页',
    );
  }

  /// 详情页对远端只按 id 查本合集的成员：成员解析问本机缺的那一集，「删除本机
  /// 副本」入口另问本机成员是不是对端副本——都不碰整份清单。
  void expectOnlyMemberLookups(_CountingJellyfinClient client) {
    expect(client.byIdsCalls.first, <String>[
      'video/ep2',
    ], reason: '成员解析只问本机缺的那一集');
    expect(
      client.byIdsCalls.expand((List<String> ids) => ids).toSet(),
      everyElement(isIn(<String>{'video/ep1', 'video/ep2'})),
      reason: '只问本合集的成员 id',
    );
  }

  testWidgets('Jellyfin 关掉自动列出 → 进含远端成员的合集详情不发一次清单请求', (
    WidgetTester tester,
  ) async {
    await prefs.setJellyfinAutoListVideos(false);
    final int cid = await seedCollectionWithRemoteOnlyMember();
    final _CountingJellyfinClient client = _CountingJellyfinClient();

    await tester.pumpWidget(buildApp(client));
    await openCollectionDetail(tester, cid);

    expect(
      client.listCalls,
      0,
      reason: '闸门关时合集详情必须与库页同一判据：只读缓存、绝不取数（BUG-1891）',
    );
  });

  testWidgets('Jellyfin 关掉自动列出 → 从别处打开合集只按 id 查缺的那一集，照样列出它', (
    WidgetTester tester,
  ) async {
    await prefs.setJellyfinAutoListVideos(false);
    final int cid = await seedCollectionWithRemoteOnlyMember();
    final _CountingJellyfinClient client = _CountingJellyfinClient();
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildApp(client));
    await tester.pumpAndSettle();
    // 「同一作品」卡片等库页以外的入口（[requestVideoCollectionOpen]）：库页闸门关、
    // 没有清单，来源照常解析，详情页的远端成员只按 id 查。
    requestVideoCollectionOpen(cid);
    await tester.pumpAndSettle();
    expect(find.byType(MediaCollectionDetailPage), findsOneWidget);

    expect(client.listCalls, 0, reason: '按 id 查不是全库枚举，闸门照旧挡住整库请求');
    expectOnlyMemberLookups(client);
    expect(
      find.byKey(const ValueKey<String>('collection-episode-row-video/ep2')),
      findsOneWidget,
      reason: '远端成员照常列出（可流播 / 下载），不退化成只有本地成员',
    );
  });

  testWidgets('首轮整库清单还在取 → 打开合集不等它，远端成员按 id 查到就显示', (
    WidgetTester tester,
  ) async {
    await prefs.setJellyfinAutoListVideos(true);
    final int cid = await seedCollectionWithRemoteOnlyMember();
    final Completer<List<RemoteVideoInfo>> fullList =
        Completer<List<RemoteVideoInfo>>();
    final _CountingJellyfinClient client = _CountingJellyfinClient(
      list: () => fullList.future,
    );
    addTearDown(() {
      if (!fullList.isCompleted) fullList.complete(const <RemoteVideoInfo>[]);
    });

    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp(client));
    // 整库请求挂着：只推有限帧（可能有常驻的加载动画，不能 pumpAndSettle）。
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(client.listCalls, 1, reason: '前提：库页的整库请求已发出且仍在途');
    await tester.tap(
      find.byKey(ValueKey<String>('home_video_collection_card_$cid')),
    );
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.byType(MediaCollectionDetailPage), findsOneWidget);
    expect(fullList.isCompleted, isFalse, reason: '整库请求仍在途');
    expectOnlyMemberLookups(client);
    expect(
      find.byKey(const ValueKey<String>('collection-episode-row-video/ep2')),
      findsOneWidget,
      reason: '详情页的远端成员不等整库清单',
    );
  });

  testWidgets('对照：自动列出开着 → 同一路径确实会问远端清单', (WidgetTester tester) async {
    await prefs.setJellyfinAutoListVideos(true);
    final int cid = await seedCollectionWithRemoteOnlyMember();
    final _CountingJellyfinClient client = _CountingJellyfinClient();

    await tester.pumpWidget(buildApp(client));
    await openCollectionDetail(tester, cid);

    expect(
      client.listCalls,
      greaterThanOrEqualTo(1),
      reason: '闸门开时这条路径要真的取数，否则上面的 0 只是「根本没走到」',
    );
  });
}

/// 计数版 Jellyfin client：`is JellyfinVideoClient` 命中 BUG-1891 闸门；只实现
/// 页面与详情页这条路径真正会碰到的成员，其余经 [noSuchMethod] 兜底。
class _CountingJellyfinClient implements JellyfinVideoClient {
  _CountingJellyfinClient({Future<List<RemoteVideoInfo>> Function()? list})
    : _list = list;

  final Future<List<RemoteVideoInfo>> Function()? _list;
  int listCalls = 0;
  final List<List<String>> byIdsCalls = <List<String>>[];

  static const List<RemoteVideoInfo> _library = <RemoteVideoInfo>[
    RemoteVideoInfo(
      id: 'video/ep2',
      title: '第2集',
      collection: RemoteCollectionMembership(
        collectionName: '某番剧',
        collectionType: 'playlist',
        sortIndex: 2,
      ),
    ),
  ];

  @override
  Future<List<RemoteVideoInfo>> remoteVideosByIds(List<String> ids) async {
    byIdsCalls.add(List<String>.of(ids));
    return <RemoteVideoInfo>[
      for (final RemoteVideoInfo video in _library)
        if (ids.contains(video.id)) video,
    ];
  }

  @override
  String get remoteLibrarySourceId => 'jellyfin:http://nas:8096|u1';

  @override
  String get coverCacheNamespace => 'jellyfin-test';

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() {
    listCalls++;
    return _list?.call() ?? Future<List<RemoteVideoInfo>>.value(_library);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
