import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/preferences_repository.dart';
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
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_collection_gate_pp');
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
    storeDir = Directory.systemTemp.createTempSync('hibiki_collection_gate');
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
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/ep1'),
      title: Value('第1集'),
      videoPath: Value('/abs/ep1.mp4'),
    ));
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
    expect(find.byType(MediaCollectionDetailPage), findsOneWidget,
        reason: '前提：整卡点击必须真的进了合集详情页');
  }

  testWidgets('Jellyfin 关掉自动列出 → 进含远端成员的合集详情不发一次清单请求',
      (WidgetTester tester) async {
    await prefs.setJellyfinAutoListVideos(false);
    final int cid = await seedCollectionWithRemoteOnlyMember();
    final _CountingJellyfinClient client = _CountingJellyfinClient();

    await tester.pumpWidget(buildApp(client));
    await openCollectionDetail(tester, cid);

    expect(client.listCalls, 0,
        reason: '闸门关时合集详情必须与库页同一判据：只读缓存、绝不取数（BUG-1891）');
  });

  testWidgets('对照：自动列出开着 → 同一路径确实会问远端清单', (WidgetTester tester) async {
    await prefs.setJellyfinAutoListVideos(true);
    final int cid = await seedCollectionWithRemoteOnlyMember();
    final _CountingJellyfinClient client = _CountingJellyfinClient();

    await tester.pumpWidget(buildApp(client));
    await openCollectionDetail(tester, cid);

    expect(client.listCalls, greaterThanOrEqualTo(1),
        reason: '闸门开时这条路径要真的取数，否则上面的 0 只是「根本没走到」');
  });
}

/// 计数版 Jellyfin client：`is JellyfinVideoClient` 命中 BUG-1891 闸门；只实现
/// 页面与详情页这条路径真正会碰到的成员，其余经 [noSuchMethod] 兜底。
class _CountingJellyfinClient implements JellyfinVideoClient {
  int listCalls = 0;

  @override
  String get remoteLibrarySourceId => 'jellyfin:http://nas:8096|u1';

  @override
  String get coverCacheNamespace => 'jellyfin-test';

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async {
    listCalls++;
    return const <RemoteVideoInfo>[
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
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
