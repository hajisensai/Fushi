import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi/src/media/video/download/video_download_subscription_service.dart';
import 'package:fushi/src/media/video/download/video_resource_registry.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_resolver.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_coordinator.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/pages/implementations/managed_video_source_prompt.dart';
import 'package:fushi/src/pages/implementations/video_discovery_acquisition_dialogs.dart';
import 'package:fushi/src/pages/implementations/video_discovery_detail_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/utils/misc/update_checker.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../helpers/test_platform_services.dart';

/// BUG-1872 的**行为**守卫：视频发现的两条流程在「下载后端就绪、只是一个受管视频
/// 来源都没有」时，必须先弹补来源引导、**不打开**资源搜索页 / 订阅页。
///
/// 钉的是 `home_page.dart` 里 `_openVideoDiscoveryResourceSearch` /
/// `_openVideoDiscoverySubscription` 各自那一行：
///
/// ```dart
/// final List<MediaSourceRow> sources =
///     await _managedVideoDownloadSourcesOrPrompt(context);
/// if (!context.mounted || sources.isEmpty) return;   // ← 这一行
/// ```
///
/// 这行是 PR #1021 合并冲突里手工保下来的：那个 PR 把「后端 runtime 可用性」延后
/// 到提交下载时判定，很容易顺手把这条「来源为空」的早退一起删掉——删掉后页面照常
/// 打开，只是来源下拉是空的、提交按钮永远灰着，用户看不出缺什么。
///
/// **与 `home_video_discovery_managed_source_guard_test.dart` 的分工**：那个是纯
/// 源码扫描守卫（`setUpAll` 读 `home_page.dart` 文本），只钉「两个入口都经
/// `_managedVideoDownloadSourcesOrPrompt` 拿来源、不得再甩 `media_source_no_sources`
/// 那句通用提示」；它对上面那行早退**零覆盖**——把 `if (... || sources.isEmpty)`
/// 删成 `if (!context.mounted)`，源码守卫依然全绿。本文件挂真的 [HomePage]、走真的
/// 接线（[HomePage.debugVideoDiscoveryActions] 取到的就是
/// `_productionVideoDiscoveryActions`），断言的是「页面到底开没开」这个用户可见结果，
/// 补的正是那块空缺。两者互补，都要留。
class _DiscoveryGateAppModel extends AppModel {
  _DiscoveryGateAppModel(this._dir, {required this.managedSources})
      : super(testPlatformServices());

  final Directory _dir;

  /// 直接 override「受管视频来源」而不是往 DB 插真目录：生产实现
  /// (`AppModel.getManagedVideoDownloadSources`) 会 `Directory.existsSync()`
  /// 校验落地目录，本测试要钉的判据在它之后。
  final List<MediaSourceRow> managedSources;

  VideoResourceRegistry? _testRegistry;
  VideoDownloadPipelineService? _testPipeline;
  VideoDownloadSubscriptionService? _testSubscriptions;
  VideoSourceScrapeCoordinator? _testScrapeCoordinator;

  @override
  Future<List<MediaSourceRow>> getManagedVideoDownloadSources() async =>
      managedSources;

  // ── 两个入口在目标行**之前**的前置门：registry / pipeline（订阅还多一个
  // subscription service）为 null 时会拐去「配置下载后端」引导，根本走不到来源
  // 判定。这里只接线到「非 null」为止，服务本身在本测试里不会被调用。──
  @override
  VideoResourceRegistry? get videoResourceRegistry => _testRegistry;

  @override
  VideoDownloadPipelineService? get videoDownloadPipelineService =>
      _testPipeline;

  @override
  VideoDownloadSubscriptionService? get videoDownloadSubscriptionService =>
      _testSubscriptions;

  void wireVideoDownloadRuntimeForTesting(FushiDatabase db) {
    final VideoResourceRegistry registry =
        VideoResourceRegistry(const <VideoResourceProvider>[]);
    final VideoSourceScrapeCoordinator coordinator =
        VideoSourceScrapeCoordinator(
      database: db,
      config: const VideoSourceScrapeGlobalConfig(),
      // 显式给空 registry：默认会按 config 造真的 TMDB/AniDB provider（含
      // HttpClient），单测不需要也不该造。
      registry: VideoMetadataProviderRegistry(const <VideoMetadataProvider>[]),
    );
    _testRegistry = registry;
    _testScrapeCoordinator = coordinator;
    _testPipeline = VideoDownloadPipelineService(
      database: db,
      resourceRegistry: registry,
      backendResolver: (VideoDownloadJobRow job) async => null,
      scrapeCoordinator: coordinator,
      // 构造不起 timer（只有 start()/wake() 才起），这里再把轮询推远一档。
      pollInterval: const Duration(hours: 1),
    );
    _testSubscriptions = VideoDownloadSubscriptionService(
      database: db,
      resourceRegistry: registry,
      enqueue: (VideoDownloadEnqueueRequest request) async => '',
    );
  }

  Future<void> disposeVideoDownloadRuntimeForTesting() async {
    await _testSubscriptions?.dispose();
    await _testPipeline?.dispose();
    _testScrapeCoordinator?.close();
    _testSubscriptions = null;
    _testPipeline = null;
    _testScrapeCoordinator = null;
    _testRegistry = null;
  }

  @override
  PackageInfo get packageInfo => PackageInfo(
        appName: 'Fushi',
        packageName: 'app.hibiki.reader',
        version: '1.0.0',
        buildNumber: '1',
      );

  @override
  Directory get appDirectory => _dir;

  @override
  Directory get temporaryDirectory => _dir;

  @override
  Directory get dictionaryResourceDirectory => _dir;

  // HomePage.build 的第一道门：库没开就整页 SizedBox.shrink。
  @override
  bool get isDatabaseOpen => true;

  // 跳过新手引导整条路由（不属于本测试主题）。
  @override
  bool get isFirstTimeSetup => false;

  @override
  bool get onboardingCompleted => true;

  // ── 查词页最小桩：HomePage 用 IndexedStack 承载各 tab，查词 tab 即便不在前台
  // 也会被构建，缺这些桩会在首帧炸（与 home_hidden_tab_select_behavior_test 同构）。

  @override
  List<DictionarySearchResult> get dictionaryHistory =>
      <DictionarySearchResult>[];

  @override
  List<Dictionary> get dictionaries => <Dictionary>[
        Dictionary(name: 'Test', formatKey: 'test', order: 0),
      ];

  @override
  int get maximumTerms => 10;

  @override
  void addToSearchHistory({
    required String historyKey,
    required String searchTerm,
  }) {}

  @override
  void addToDictionaryHistory({required DictionarySearchResult result}) {}

  @override
  Future<DictionarySearchResult> searchDictionary({
    required String searchTerm,
    required bool searchWithWildcards,
    int? overrideMaximumTerms,
    bool useCache = true,
    bool allowRemoteLookup = true,
  }) async =>
      DictionarySearchResult(searchTerm: searchTerm);
}

const MediaSourceRow _managedSource = MediaSourceRow(
  id: 1,
  label: 'himoto',
  mediaKind: 'video',
  transport: 'local',
  rootPath: r'D:\media',
  mediaCount: 0,
  recursive: true,
  sortOrder: 0,
  createdAt: 1,
);

VideoDiscoveryItem _item() => VideoDiscoveryItem(
      reference: VideoMediaReference(
        providerId: 'anilist',
        mediaId: '100',
        mediaKind: VideoMetadataMediaKind.tv,
        discoveryCategory: VideoDiscoveryCategory.anime,
        title: '测试动画',
        year: 2026,
        anilistId: 100,
      ),
    );

Future<_DiscoveryGateAppModel> _pumpHome(
  WidgetTester tester, {
  required List<MediaSourceRow> managedSources,
}) async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final PreferencesRepository prefsRepo = PreferencesRepository(db);
  await prefsRepo.loadFromDb();
  final Directory tmpDir =
      Directory.systemTemp.createTempSync('fushi_home_video_source_gate_');
  addTearDown(() {
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  final _DiscoveryGateAppModel appModel = _DiscoveryGateAppModel(
    tmpDir,
    managedSources: managedSources,
  )
    ..wireLocalAudioForTesting(prefsRepo: prefsRepo, databaseDirectory: tmpDir)
    ..wireDatabaseForTesting(db);
  appModel.wireVideoDownloadRuntimeForTesting(db);
  addTearDown(appModel.disposeVideoDownloadRuntimeForTesting);

  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('window_manager'),
    (MethodCall call) {
      if (call.method == 'isFocused') return Future<bool>.value(true);
      return Future<void>.value();
    },
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((ref) => appModel),
        platformServicesProvider.overrideWithValue(testPlatformServices()),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: appModel.navigatorKey,
          home: const HomePage(),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(HomePage.debugVideoDiscoveryActions, isNotNull,
      reason: 'HomePage 必须已挂载并注册 debugVideoDiscoveryActions 生产钩子');
  return appModel;
}

/// 有界推帧。整页 HomePage 挂着持续动画与 1 分钟周期定时器，`pumpAndSettle`
/// 永远等不到静止，只能按固定帧数推进（覆盖 300ms 路由转场绰绰有余）。
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 断言做完后主动卸载：drift `.watch()` 的 StreamQueryStore 在 ProviderScope
/// dispose 时排一个零时长 Timer，留到测试结束会撞 `!timersPending` 不变式。
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(Duration.zero);
  await tester.pump(const Duration(milliseconds: 10));
}

/// 取生产接线本身，而不是测试自己拼一个 [VideoDiscoveryActions]——后者只能证明
/// 「我写的假回调按我写的跑」。
VideoDiscoveryActions _productionActions() =>
    HomePage.debugVideoDiscoveryActions!();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    UpdateChecker.disableAutoCheckForTesting = true;
    DesktopLookupService.instance.debugReset();
  });

  tearDown(() {
    UpdateChecker.disableAutoCheckForTesting = false;
    DesktopLookupService.instance.debugReset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });

  Future<void> useLargeSurface(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  /// 缺来源那条路径上的公共尾巴：引导必须弹出来、目标页必须没开，然后点「取消」
  /// （= 用户明确放弃）让流程收尾。
  Future<void> expectPromptedInsteadOfOpening(
    WidgetTester tester, {
    required Finder page,
    required String pageReason,
  }) async {
    expect(
      find.byType(ManagedVideoSourcePromptDialog),
      findsOneWidget,
      reason: '一个受管视频来源都没有时，必须先弹引导说清缺的是落地文件夹（BUG-1872）。',
    );
    expect(page, findsNothing, reason: pageReason);

    await tester.tap(
      find.descendant(
        of: find.byType(ManagedVideoSourcePromptDialog),
        matching: find.text(t.dialog_cancel),
      ),
    );
    await _settle(tester);
    expect(
      find.byType(ManagedVideoSourcePromptDialog),
      findsNothing,
      reason: '取消后引导应关闭。',
    );
    expect(page, findsNothing, reason: pageReason);
  }

  testWidgets('没有受管视频来源：不打开资源搜索页，先弹补来源引导', (WidgetTester tester) async {
    await useLargeSurface(tester);
    await _pumpHome(tester, managedSources: const <MediaSourceRow>[]);

    final VideoDiscoveryActions actions = _productionActions();
    final BuildContext homeContext = tester.element(find.byType(HomePage));
    final Future<void> pending = actions.onSearchResource!(homeContext, _item());
    await _settle(tester);

    await expectPromptedInsteadOfOpening(
      tester,
      page: find.byType(VideoDiscoveryResourceSearchPage),
      pageReason: '来源为空就打开资源搜索页 = 来源下拉是空的、提交按钮永远灰着，'
          '用户看不出缺什么。`if (!context.mounted || sources.isEmpty) return;` '
          '必须留在 push 之前。',
    );
    await pending;
    await _unmount(tester);
  });

  testWidgets('有受管视频来源：直接打开资源搜索页，不弹补来源引导', (WidgetTester tester) async {
    await useLargeSurface(tester);
    await _pumpHome(
      tester,
      managedSources: const <MediaSourceRow>[_managedSource],
    );

    final VideoDiscoveryActions actions = _productionActions();
    final BuildContext homeContext = tester.element(find.byType(HomePage));
    final Future<void> pending = actions.onSearchResource!(homeContext, _item());
    await _settle(tester);

    expect(
      find.byType(ManagedVideoSourcePromptDialog),
      findsNothing,
      reason: '来源齐了就不该再拦一道。',
    );
    expect(
      find.byType(VideoDiscoveryResourceSearchPage),
      findsOneWidget,
      reason: '这是那条早退的反面：正常路径必须照常开页，否则等于把功能门死。',
    );

    Navigator.of(
      tester.element(find.byType(VideoDiscoveryResourceSearchPage)),
    ).pop();
    await _settle(tester);
    await pending;
    await _unmount(tester);
  });

  testWidgets('没有受管视频来源：不打开订阅页，先弹补来源引导', (WidgetTester tester) async {
    await useLargeSurface(tester);
    await _pumpHome(tester, managedSources: const <MediaSourceRow>[]);

    final VideoDiscoveryActions actions = _productionActions();
    final BuildContext homeContext = tester.element(find.byType(HomePage));
    final Future<void> pending = actions.onSubscribe!(homeContext, _item());
    await _settle(tester);

    await expectPromptedInsteadOfOpening(
      tester,
      page: find.byType(VideoDiscoverySubscriptionPage),
      pageReason: '订阅入口与资源搜索是同一条判据的两份拷贝，删掉哪一份都算回归。',
    );
    await pending;
    await _unmount(tester);
  });

  testWidgets('有受管视频来源：直接打开订阅页，不弹补来源引导', (WidgetTester tester) async {
    await useLargeSurface(tester);
    await _pumpHome(
      tester,
      managedSources: const <MediaSourceRow>[_managedSource],
    );

    final VideoDiscoveryActions actions = _productionActions();
    final BuildContext homeContext = tester.element(find.byType(HomePage));
    final Future<void> pending = actions.onSubscribe!(homeContext, _item());
    await _settle(tester);

    expect(
      find.byType(ManagedVideoSourcePromptDialog),
      findsNothing,
      reason: '来源齐了就不该再拦一道。',
    );
    expect(
      find.byType(VideoDiscoverySubscriptionPage),
      findsOneWidget,
      reason: '这是那条早退的反面：正常路径必须照常开页，否则等于把功能门死。',
    );

    Navigator.of(
      tester.element(find.byType(VideoDiscoverySubscriptionPage)),
    ).pop();
    await _settle(tester);
    await pending;
    await _unmount(tester);
  });
}
