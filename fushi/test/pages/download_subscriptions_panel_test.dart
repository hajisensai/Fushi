import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_engine/media/torrent/anime_download_config.dart';
import 'package:fushi/src/media/torrent/anime_download_plan.dart';
import 'package:fushi/src/media/torrent/anime_download_subscription.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/download_subscriptions_panel.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/pages/implementations/browse_page.dart';

import '../helpers/test_platform_services.dart';

class _MemorySubscriptionStore extends AnimeDownloadSubscriptionStore {
  _MemorySubscriptionStore()
      : super(baseDir: Directory('unused-subscription-store'));

  final Map<String, AnimeDownloadSubscription> values =
      <String, AnimeDownloadSubscription>{};

  @override
  Future<List<AnimeDownloadSubscription>> loadAll() async =>
      values.values.toList();

  @override
  Future<void> save(AnimeDownloadSubscription subscription) async {
    values[subscription.id] = subscription;
    revision.value++;
  }

  @override
  Future<void> delete(String id) async {
    values.remove(id);
    revision.value++;
  }
}

class _MemoryPlanStore extends AnimeDownloadPlanStore {
  _MemoryPlanStore() : super(baseDir: Directory('unused-plan-store'));

  @override
  Future<List<AnimeDownloadPlan>> loadAll() async =>
      const <AnimeDownloadPlan>[];
}

class _NoopBackend implements TorrentBackend {
  @override
  Future<bool> addTorrent(
    String magnetOrUrl, {
    required String category,
    String? savePath,
    bool sequential = false,
    bool firstLastPiecePrio = false,
  }) async =>
      true;

  @override
  void close() {}

  // TODO-1961-c：本 fake 不测改名/移动路径，给出明确的「未实现」结果而不是
  // 假装成功——真要测这条链路的用例应当显式覆盖它。
  @override
  Future<TorrentStorageResult> renameFile(
          String torrentId, int fileIndex, String newPath) async =>
      const TorrentStorageResult.failure('not supported by fake');

  @override
  Future<TorrentStorageResult> moveStorage(
          String torrentId, String newSavePath) async =>
      const TorrentStorageResult.failure('not supported by fake');

  @override
  Future<List<TorrentFileEntry>> listFiles(String torrentId) async =>
      const <TorrentFileEntry>[];

  @override
  Future<List<TorrentSnapshot>> listTorrents({String? category}) async =>
      const <TorrentSnapshot>[];

  @override
  Future<bool> prepareCategory(String category) async => true;

  @override
  Future<String?> probeConnection() async => 'noop';
}

class _FakeAppModel extends AppModel {
  _FakeAppModel(this.store, this.planStore, this.service)
      : super(testPlatformServices());

  final _MemorySubscriptionStore store;
  final _MemoryPlanStore planStore;
  final AnimeDownloadSubscriptionService service;

  @override
  AnimeDownloadSubscriptionStore? get animeDownloadSubscriptionStore => store;

  @override
  AnimeDownloadSubscriptionService? get animeDownloadSubscriptionService =>
      service;
  @override
  AnimeDownloadPlanStore? get animeDownloadPlanStore => planStore;

  @override
  String get jimakuApiKey => '';

  @override
  QbConnectionConfig? get qbConnectionConfig => const QbConnectionConfig();

  @override
  bool get torrentUploadIntroShown => true;

  // #794 起下载页任务 tab 直接读 appModel.database(VideoDownloadJobsPanel),
  // fake 懒建内存库,用到任务 tab 的用例负责 close。
  FushiDatabase? testDatabase;

  @override
  FushiDatabase get database =>
      testDatabase ??= FushiDatabase.forTesting(NativeDatabase.memory());

  /// M3E 任务中心（468ceed6a93）起浏览页 initState 读「下载执行设备」偏好给
  /// 汇总卡的设备 chip；给一个落在同一内存库上的真偏好仓库（空库 = 本机）。
  PreferencesRepository? testPrefsRepo;

  @override
  PreferencesRepository get prefsRepo =>
      testPrefsRepo ??= PreferencesRepository(database);

  /// 发现排第一后，「下载」左邻在有小说在线源的平台上是「扩展」页签，它会建
  /// LNReader 管理器（根目录在数据库目录下）；给一个临时目录让它建得起来。
  Directory? testDatabaseDirectory;

  @override
  Directory get databaseDirectory => testDatabaseDirectory ??=
      Directory.systemTemp.createTempSync('fushi_browse_test_');

  /// 测试直接给定可见模块（浏览页的页签随它增减）。
  ModuleVisibility? visibilityOverride;

  @override
  ModuleVisibility get moduleVisibility =>
      visibilityOverride ?? super.moduleVisibility;

  void setVisibility(ModuleVisibility visibility) {
    visibilityOverride = visibility;
    notifyListeners();
  }
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Future<(_FakeAppModel, AnimeDownloadSubscriptionService)> pumpPanel(
    WidgetTester tester, {
    required Size size,
    bool withSubscription = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final _MemorySubscriptionStore store = _MemorySubscriptionStore();
    if (withSubscription) {
      final AnimeDownloadSubscription subscription =
          AnimeDownloadSubscription.fromSelection(
        anilistId: 42,
        seriesTitle: 'A Rather Long Example Anime Series Title',
        nyaaQuery: 'Example',
        category: '1_2',
        releaseGroup: 'A-Rather-Long-Release-Group',
        resolution: '1080p',
        startAfterEpisode: 12,
        jimakuEntryId: 77,
        jimakuEntryName: 'Complete season pack',
        jimakuLanguage: 'ja',
        now: DateTime.utc(2026, 7, 1),
      ).copyWith(
        processedEpisodes: <int>{13},
        lastCheckedAtMs: DateTime.utc(2026, 7, 23).millisecondsSinceEpoch,
      );
      store.values[subscription.id] = subscription;
    }
    final _MemoryPlanStore planStore = _MemoryPlanStore();
    final AnimeDownloadSubscriptionService service =
        AnimeDownloadSubscriptionService(
      store: store,
      planStore: planStore,
      configProvider: () => const QbConnectionConfig(),
      backendFactory: (_) => _NoopBackend(),
      search: (_) async => const [],
    );
    final _FakeAppModel appModel = _FakeAppModel(store, planStore, service);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
        ],
        child: TranslationProvider(
          child: const MaterialApp(
            home: Scaffold(body: DownloadSubscriptionsPanel()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (appModel, service);
  }

  testWidgets('subscription card has no overflow on a narrow phone',
      (WidgetTester tester) async {
    final (_FakeAppModel appModel, AnimeDownloadSubscriptionService service) =
        await pumpPanel(
      tester,
      size: const Size(360, 720),
    );

    expect(
        find.text('A Rather Long Example Anime Series Title'), findsOneWidget);
    expect(find.textContaining('A-Rather-Long-Release-Group'), findsOneWidget);
    expect(find.textContaining('Complete season pack'), findsOneWidget);
    expect(tester.takeException(), isNull);

    service.checking.dispose();
    appModel.store.revision.dispose();
  });

  testWidgets('subscription panel remains bounded on desktop',
      (WidgetTester tester) async {
    final (_FakeAppModel appModel, AnimeDownloadSubscriptionService service) =
        await pumpPanel(
      tester,
      size: const Size(1200, 800),
    );

    final Finder card = find.byType(FushiCard);
    expect(card, findsWidgets);
    expect(
      tester.getSize(card.last).width,
      lessThanOrEqualTo(760),
    );
    expect(tester.takeException(), isNull);

    service.checking.dispose();
    appModel.store.revision.dispose();
  });

  testWidgets('empty state explains how to create a subscription',
      (WidgetTester tester) async {
    final (_FakeAppModel appModel, AnimeDownloadSubscriptionService service) =
        await pumpPanel(
      tester,
      size: const Size(360, 720),
      withSubscription: false,
    );

    expect(find.text(t.download_subscription_empty_title), findsOneWidget);
    expect(find.text(t.download_subscription_empty_body), findsOneWidget);

    service.checking.dispose();
    appModel.store.revision.dispose();
  });

  testWidgets(
      'browse page downloads tab switches between tasks and subscriptions',
      (WidgetTester tester) async {
    final _MemorySubscriptionStore store = _MemorySubscriptionStore();
    final _MemoryPlanStore planStore = _MemoryPlanStore();
    final AnimeDownloadSubscriptionService service =
        AnimeDownloadSubscriptionService(
      store: store,
      planStore: planStore,
      configProvider: () => const QbConnectionConfig(),
      backendFactory: (_) => _NoopBackend(),
      search: (_) async => const [],
    );
    final _FakeAppModel appModel = _FakeAppModel(store, planStore, service);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
        ],
        child: TranslationProvider(
          child: const MaterialApp(
            home: BrowsePage(initialTab: BrowseTab.downloads),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(t.nav_downloads), findsOneWidget);
    // 任务是「下载」页签的默认段。
    expect(find.text(t.download_tasks_tab), findsOneWidget);
    expect(find.text(t.anime_download_no_tasks), findsOneWidget);

    await tester.tap(find.text(t.download_subscriptions_tab));
    await tester.pumpAndSettle();
    expect(find.text(t.download_subscription_empty_title), findsOneWidget);
    expect(tester.takeException(), isNull);

    service.checking.dispose();
    store.revision.dispose();
    await appModel.testDatabase?.close();
  });

  // 二级标签页可横滑切段；滑过首 / 末段继续滑时交给相邻的顶层页签（内层
  // TabBarView 在手势竞技场里恒先胜出，不接力就永远滑不出当前页签）。
  testWidgets(
      'browse sub-tabs swipe and hand off to the adjacent top-level tab',
      (WidgetTester tester) async {
    final _MemorySubscriptionStore store = _MemorySubscriptionStore();
    final _MemoryPlanStore planStore = _MemoryPlanStore();
    final AnimeDownloadSubscriptionService service =
        AnimeDownloadSubscriptionService(
      store: store,
      planStore: planStore,
      configProvider: () => const QbConnectionConfig(),
      backendFactory: (_) => _NoopBackend(),
      search: (_) async => const [],
    );
    final _FakeAppModel appModel = _FakeAppModel(store, planStore, service)
      ..visibilityOverride =
          const ModuleVisibility(<ModuleId>{ModuleId.browse, ModuleId.books});
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
        ],
        child: TranslationProvider(
          child: const MaterialApp(
            home: BrowsePage(initialTab: BrowseTab.downloads),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    TabController outer() =>
        tester.widget<TabBarView>(find.byType(TabBarView).first).controller!;
    final int downloadsIndex = outer().index;
    expect(outer().length, greaterThan(1));
    expect(find.text(t.anime_download_no_tasks), findsOneWidget);

    // 左滑：任务 → 订阅（仍在「下载」页签）。
    await tester.drag(
      find.text(t.anime_download_no_tasks),
      const Offset(-500, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.download_subscription_empty_title), findsOneWidget);
    expect(outer().index, downloadsIndex);

    // 订阅是最后一个页签的末段：再往左滑没有下一个页签，原地不动。
    await tester.drag(
      find.text(t.download_subscription_empty_title),
      const Offset(-500, 0),
    );
    await tester.pumpAndSettle();
    expect(outer().index, downloadsIndex);
    expect(find.text(t.download_subscription_empty_title), findsOneWidget);

    // 右滑回任务；在首段继续右滑 → 交给上一个顶层页签（发现排第一后，
    // 有在线源的平台上是「扩展」，没有时是「发现」）。
    await tester.drag(
      find.text(t.download_subscription_empty_title),
      const Offset(500, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.anime_download_no_tasks), findsOneWidget);
    expect(outer().index, downloadsIndex);
    await tester.drag(
      find.text(t.anime_download_no_tasks),
      const Offset(500, 0),
    );
    await tester.pumpAndSettle();
    expect(outer().index, downloadsIndex - 1);
    expect(tester.takeException(), isNull);

    service.checking.dispose();
    store.revision.dispose();
    await appModel.testDatabase?.close();
  });

  // PR #1707 审查：首页保活浏览页后，「管理订阅」等跳转要原地切到目标段，
  // 不再靠换 key 整页重建（那会丢掉各页签的搜索与结果）。
  testWidgets('navigation request switches a mounted browse page in place',
      (WidgetTester tester) async {
    final _MemorySubscriptionStore store = _MemorySubscriptionStore();
    final _MemoryPlanStore planStore = _MemoryPlanStore();
    final AnimeDownloadSubscriptionService service =
        AnimeDownloadSubscriptionService(
      store: store,
      planStore: planStore,
      configProvider: () => const QbConnectionConfig(),
      backendFactory: (_) => _NoopBackend(),
      search: (_) async => const [],
    );
    final _FakeAppModel appModel = _FakeAppModel(store, planStore, service)
      ..visibilityOverride =
          const ModuleVisibility(<ModuleId>{ModuleId.browse});
    BrowseNavigationRequest? request;
    late StateSetter setHost;
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) {
                setHost = setState;
                return BrowsePage(
                  initialTab: BrowseTab.downloads,
                  navigationRequest: request,
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.anime_download_no_tasks), findsOneWidget);
    final State<StatefulWidget> mounted = tester.state(find.byType(BrowsePage));

    setHost(() {
      request = BrowseNavigationRequest(
        BrowseTab.downloads,
        downloadsSection: BrowseDownloadsSection.subscriptions,
      );
    });
    await tester.pumpAndSettle();
    expect(find.text(t.download_subscription_empty_title), findsOneWidget);
    expect(identical(tester.state(find.byType(BrowsePage)), mounted), isTrue,
        reason: '跳转是原地切段，不是重建整页');

    // 宿主用后即清（传 null）不得把页面拽回别的段。
    setHost(() => request = null);
    await tester.pumpAndSettle();
    expect(find.text(t.download_subscription_empty_title), findsOneWidget);
    expect(tester.takeException(), isNull);

    service.checking.dispose();
    store.revision.dispose();
    await appModel.testDatabase?.close();
  });

  // PR #1707 审查：页签随模块开关增减时按页签 id 保留选中，DefaultTabController
  // 只保留下标——前面多出来源 / 扩展 / 发现三个页签，旧实现会从「下载」静默
  // 落到「来源」。
  testWidgets('browse page keeps the selected tab by id when tabs change',
      (WidgetTester tester) async {
    final _MemorySubscriptionStore store = _MemorySubscriptionStore();
    final _MemoryPlanStore planStore = _MemoryPlanStore();
    final AnimeDownloadSubscriptionService service =
        AnimeDownloadSubscriptionService(
      store: store,
      planStore: planStore,
      configProvider: () => const QbConnectionConfig(),
      backendFactory: (_) => _NoopBackend(),
      search: (_) async => const [],
    );
    final _FakeAppModel appModel = _FakeAppModel(store, planStore, service)
      ..visibilityOverride =
          const ModuleVisibility(<ModuleId>{ModuleId.browse});
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
        ],
        child: TranslationProvider(
          child: const MaterialApp(home: BrowsePage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.anime_download_no_tasks), findsOneWidget);

    appModel.setVisibility(
      const ModuleVisibility(<ModuleId>{ModuleId.browse, ModuleId.books}),
    );
    await tester.pumpAndSettle();
    // 页签确实变多了（前面多出来源 / 扩展 / 发现），选中仍是「下载」。
    expect(find.text(t.library_view_discover), findsOneWidget);
    expect(find.text(t.anime_download_no_tasks), findsOneWidget);
    // 来源 / 扩展是否出现取决于测试宿主平台的在线宿主门，「发现」一定出现；
    // 「下载」恒在最后。
    // 最外层是顶层页签的 TabBarView，每个页签里还有自己的二级 TabBarView。
    final TabBarView view =
        tester.widget<TabBarView>(find.byType(TabBarView).first);
    expect(view.children.length, greaterThan(1));
    expect(view.controller!.index, view.children.length - 1);
    expect(tester.takeException(), isNull);

    service.checking.dispose();
    store.revision.dispose();
    await appModel.testDatabase?.close();
  });
}
