import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:macos_ui/macos_ui.dart'
    show
        MacosScaffold,
        ToolBar,
        ContentArea,
        Sidebar,
        SidebarItems,
        SidebarItem,
        MacosBackButton,
        MacosIcon;
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:fushi_anki/fushi_anki.dart' show AnkiMediaDedupReport;
import 'package:fushi/src/anki/anki_media_dedup_dialogs.dart';
import 'package:fushi/src/anki/anki_media_dedup_runner.dart';
import 'package:fushi/src/anki/anki_view_model.dart'
    show ankiRepositoryProvider;
import 'package:fushi/src/anki/lapis_template_service.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/media/external_provider.dart';
import 'package:fushi/src/media/source_library/source_library_row.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:drift/drift.dart' show Value;
import 'package:fushi/src/media/collections/collection_continue.dart';
import 'package:fushi/src/media/torrent/nyaa_resource_provider.dart';
import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_service.dart';
import 'package:fushi/src/media/video/download/video_download_backend_identity.dart';
import 'package:fushi/src/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi/src/media/video/download/video_resource_registry.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart'
    show VideoSubtitleCandidate;
import 'package:fushi/src/media/video/video_subtitle_attach.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_coordinator.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_dialog.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi/src/media/video/metadata/video_source_metadata_indexer.dart';
import 'package:fushi/src/media/video/scraper/tmdb_default_key.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/pages/implementations/video_discovery_acquisition_dialogs.dart';
import 'package:fushi/src/pages/implementations/video_discovery_detail_page.dart';
import 'package:fushi/src/pages/implementations/video_discovery_page.dart'
    show VideoDiscoveryController;
import 'package:fushi/src/pages/implementations/video_library_shell.dart';
import 'package:fushi/src/media/audiobook/now_listening_mini_bar.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart'
    show FushiFocusController, FushiFocusRoot;
import 'package:fushi/src/shortcuts/input_binding.dart'
    show GamepadButton, ModifierKey;
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show
        GamepadButtonIntent,
        arrowFocusMoveDirection,
        arrowTraversalDirection,
        dispatchNativeGamepadButtonIntent,
        focusedEditableText,
        gamepadMoveFocusInDirection;
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi_core/fushi_core.dart'
    show
        MediaCollectionItemRow,
        MediaKind,
        MediaSourceRow,
        VideoBookRow,
        VideoDownloadJobLifecycle,
        VideoDownloadJobRow,
        VideoDownloadJobStage,
        VideoDownloadSubscriptionRow,
        VideoDownloadSubscriptionsCompanion,
        VideoMetadataProviderIdentityRow,
        VideoMetadataWorkRow,
        VideoSourceScrapeRunRow,
        VideoSourceScrapeSettingRow;

/// 顶层 tab 的逻辑身份（取代写死的整数索引 0/1/2）。条件 tab（video/downloads 常驻、
/// games 仅 Windows）用枚举身份而非位置来切换/路由——插入条件 tab 不会再打乱「设置/词典」
/// 的索引（消除 `==2` / `case 1/2` / `%3` 这类特殊情况）。底栏/侧栏只在渲染层把身份映射
/// 成位置。games（galgame 库）紧跟在 video 之后。顶层 texthooker tab 已删（galgame 捕获
/// 工作台现内嵌于 games tab，会话见 [GalHookSessionController]）。
enum HomeTab {
  home,
  books,
  manga,
  video,
  downloads,
  dictionaries,
  games,
  browserExtension,
  settings,
}

/// 纯函数：给定视频开关与游戏库开关，返回可见顶层 tab 的**视觉顺序**——视频固定插在书架
/// 与词典之间（用户要求「在书架和词典管理中间」），games（galgame 库）仅在开启时出现，
/// 位置固定紧跟 video 之后（用户要求「底栏里把游戏移动到视频后面」，与书/漫画/视频/游戏
/// 四类媒体入口连成一段）。提取成顶层函数便于单测条件插入与顺序，不必实例化整个
/// [HomePage]。底栏/侧栏的位置索引由此列表导出。
List<HomeTab> homeActiveTabs({
  required bool videoEnabled,
  bool gamesEnabled = false,
  bool browserExtensionEnabled = false,
}) =>
    <HomeTab>[
      HomeTab.home,
      HomeTab.books,
      HomeTab.manga,
      if (videoEnabled) HomeTab.video,
      if (gamesEnabled) HomeTab.games,
      // 下载 tab 恒在（统一下载中心）：除番剧 torrent 外还承载通用磁力（书）与
      // 漫画「在线目录」卷下载队列，不再随视频开关隐藏；位置在视频/游戏之后。
      HomeTab.downloads,
      HomeTab.dictionaries,
      // 浏览器扩展管理（安装引导 + 连接检测 + 版本）独立成页，仅桌面出现（手机浏览器
      // 不支持加载未解压扩展，故按平台而非实验开关门控），位置紧邻设置之前。
      if (browserExtensionEnabled) HomeTab.browserExtension,
      HomeTab.settings,
    ];

HomeTab homeInitialTab({
  required bool startupDefaultDictionaryTab,
  required HomeTab fallback,
}) {
  if (startupDefaultDictionaryTab) return HomeTab.dictionaries;
  return fallback;
}

int homeVisualIndexForTab({
  required List<HomeTab> tabs,
  required HomeTab tab,
  required bool reversed,
}) {
  final int logical = tabs.indexOf(tab);
  if (logical < 0) return 0;
  return reversed ? tabs.length - 1 - logical : logical;
}

HomeTab homeTabForVisualIndex({
  required List<HomeTab> tabs,
  required int visualIndex,
  required bool reversed,
}) {
  final int logicalIndex =
      reversed ? (tabs.length - 1 - visualIndex) : visualIndex;
  if (logicalIndex < 0 || logicalIndex >= tabs.length) return HomeTab.books;
  return tabs[logicalIndex];
}

/// 顶层 home-shell 选中 tab 的共享真值（[HomeTab] 身份，不用整数位置——插入 video /
/// games 条件 tab 不再打乱索引）。macOS 根 [MacosWindow] 的原生侧栏在 main.dart
/// 的 builder 里（Approach B，让 MacosWindow 包住整个 navigator，pushed 路由也拿到
/// MacosWindowScope）构建，与 HomePage 自绘的 rail / 底栏驱动**同一个**选中身份。
/// 非 macOS 平台不读写它，纯 no-op。
final ValueNotifier<HomeTab> homeShellTabNotifier =
    ValueNotifier<HomeTab>(HomeTab.home);

/// 单个 [HomeTab] 的导航项（图标 + 标签）。顶层函数，供 HomePage 的 rail/底栏与 macOS
/// 根侧栏共用，保证三处标签/图标一致。
AdaptiveNavItem homeNavItemFor(HomeTab tab) {
  switch (tab) {
    case HomeTab.home:
      return AdaptiveNavItem(
        icon: Icons.home_outlined,
        selectedIcon: Icons.home,
        label: t.nav_home,
      );
    case HomeTab.books:
      return AdaptiveNavItem(
        icon: Icons.menu_book_outlined,
        selectedIcon: Icons.menu_book,
        label: t.books,
      );
    case HomeTab.manga:
      return AdaptiveNavItem(
        icon: Icons.photo_library_outlined,
        selectedIcon: Icons.photo_library,
        label: t.manga_library,
      );
    case HomeTab.video:
      return AdaptiveNavItem(
        icon: Icons.movie_outlined,
        selectedIcon: Icons.movie,
        label: t.nav_video,
      );
    case HomeTab.downloads:
      return AdaptiveNavItem(
        icon: Icons.download_outlined,
        selectedIcon: Icons.download,
        label: t.nav_downloads,
      );
    case HomeTab.dictionaries:
      return AdaptiveNavItem(
        icon: Icons.search_outlined,
        selectedIcon: Icons.search,
        label: t.nav_lookup,
      );
    case HomeTab.games:
      return AdaptiveNavItem(
        icon: Icons.sports_esports_outlined,
        selectedIcon: Icons.sports_esports,
        label: t.nav_game,
      );
    case HomeTab.browserExtension:
      return AdaptiveNavItem(
        icon: Icons.extension_outlined,
        selectedIcon: Icons.extension,
        label: t.nav_browser_extension,
      );
    case HomeTab.settings:
      return AdaptiveNavItem(
        icon: Icons.tune_outlined,
        selectedIcon: Icons.tune,
        label: t.settings,
      );
  }
}

/// 为根 [MacosWindow] 构建 macOS 原生 [Sidebar]。住在根（不在 HomePage 内）才能让
/// pushed 路由——阅读器、设置详情、对话框——继承 MacosWindowScope 用原生 ToolBar。
/// 侧栏项由 [activeTabs] 动态生成（与底栏/rail 的 [homeActiveTabs] 同一真值，video /
/// games 开关变化时自动增删），选中身份走 [homeShellTabNotifier]。
Sidebar buildFushiMacosSidebar({required List<HomeTab> activeTabs}) {
  return Sidebar(
    minWidth: 220,
    builder: (BuildContext context, ScrollController scrollController) {
      final List<AdaptiveNavItem> items =
          activeTabs.map(homeNavItemFor).toList();
      return ValueListenableBuilder<HomeTab>(
        valueListenable: homeShellTabNotifier,
        builder: (BuildContext context, HomeTab current, _) {
          // 当前 tab 若已不在可见列表（刚关掉实验开关仍停在 video），回落到书架，
          // 避免 SidebarItems.currentIndex 越界。
          final int currentIndex =
              activeTabs.contains(current) ? activeTabs.indexOf(current) : 0;
          return SidebarItems(
            currentIndex: currentIndex,
            onChanged: (int i) {
              if (i >= 0 && i < activeTabs.length) {
                // 只写共享真值；HomePage 监听它并走 _selectTab（保留 _previousTab /
                // 焦点环复位语义），再写回，故三处入口同一条路径。
                homeShellTabNotifier.value = activeTabs[i];
              }
            },
            scrollController: scrollController,
            items: <SidebarItem>[
              for (final AdaptiveNavItem item in items)
                SidebarItem(
                  leading: MacosIcon(item.selectedIcon ?? item.icon),
                  label: Text(item.label),
                ),
            ],
          );
        },
      );
    },
  );
}

/// 纯函数：顶层同步态 [PopScope] 在收到系统返回时是否应弹「同步进行中」告警。
///
/// 仅当**正在同步**且**当前不在设置 tab**时才告警。设置 tab 的返回由它自己的内层
/// [PopScope]（[HomeSettingsTabContent]）拦截切回来源 tab；但同 route 多 PopScope 的
/// 回调会被**全部遍历**，故顶层必须按当前 tab 自我收窄，否则设置 tab + 同步同时进行
/// 时按返回会误弹告警（即使返回已被内层消费、route 未真正 pop）。
bool shouldWarnOnExit({required bool syncing, required bool isSettingsTab}) =>
    syncing && !isSettingsTab;

/// Keeps the UI contract out of the provider layer. The production service can
/// therefore stay usable by tests and background code without importing pages.
class _ProductionVideoDiscoveryController implements VideoDiscoveryController {
  const _ProductionVideoDiscoveryController(this.service);

  final VideoDiscoveryService service;

  @override
  Future<ProviderBatchResult<VideoDiscoveryPage>> load(
    VideoDiscoveryRequest request,
  ) =>
      service.load(request);
}

String? _videoMetadataImageUrl(
  VideoMetadataWork work,
  VideoMetadataImageKind kind,
) {
  for (final VideoMetadataImage image in work.images) {
    if (image.kind == kind && image.url.trim().isNotEmpty) return image.url;
  }
  return null;
}

class HomePage extends BasePage {
  const HomePage({super.key});

  /// 测试钩子：确定性切换顶层 tab（离屏集成测试焦点驱动 nav 在 IndexedStack +
  /// 自绘 rail 下偶发切不过去，故提供直达入口）。仅 debug/profile build 注册。
  @visibleForTesting
  static void Function(HomeTab tab)? debugSelectTab;

  @override
  BasePageState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends BasePageState<HomePage>
    with WidgetsBindingObserver {
  String get appVersion => appModel.packageInfo.version;

  HomeTab _currentTab = HomeTab.home;

  /// 进入「设置」标签前的来源 tab，供设置全屏左上返回箭头切回。
  HomeTab _previousTab = HomeTab.home;
  final FocusNode _keyboardFocusNode = FocusNode();
  final ValueNotifier<int> _dictFocusSignal = ValueNotifier<int>(0);
  final ValueNotifier<int> _videoLibraryRefreshSignal = ValueNotifier<int>(0);
  VideoSourceScrapeCoordinator? _videoSourceScrapeCoordinator;
  VideoSourceScrapeTaskController? _videoSourceScrapeTaskController;
  String? _videoSourceScrapeConfigFingerprint;
  bool _videoSourceScrapePanelOpen = false;
  VideoDiscoveryService? _videoDiscoveryService;
  VideoDiscoveryController? _videoDiscoveryController;
  String? _videoDiscoveryConfigFingerprint;
  int _downloadsInitialTabIndex = 0;
  int _downloadsGeneration = 0;

  /// 定时后台同步：app 存活期每隔 [_periodicSyncInterval] 重跑一次 app-open 语义的全量
  /// sweep，让「手机一直开着、电脑那边改了数据」这种没有任何事件触发的场景也能自动拉到
  /// 远端改动。此前同步纯事件驱动（只在 app 打开 / 进入后台 / 关书时触发），设备静止不
  /// 动就永远不同步，只能手动点「立即同步」。
  ///
  /// 轮询间隔特意**小于** `_runAutoSyncAll` 里的 5 分钟冷却窗（`_syncCooldownMs`）：真正
  /// 是否发起网络同步由那道冷却闸决定，轮询只是「频繁探一下、到点即跑」。若把间隔取成恰
  /// 等于冷却窗，tick 会落在冷却下沿（now-lastSync≈4分58秒 < 5分）被跳过，把有效周期翻
  /// 倍成 10 分钟；小间隔 + 冷却闸则自校正，且 app-open / 关书 / 后台同步都会自然重置冷
  /// 却。被闸掉的 tick 只是两次本地 DB 读后早退，开销可忽略；退后台 / 熄屏时 OS 会挂起
  /// timer，不额外耗电。
  static const Duration _periodicSyncInterval = Duration(minutes: 1);
  Timer? _periodicSyncTimer;

  @override
  void initState() {
    super.initState();

    _currentTab = homeInitialTab(
      startupDefaultDictionaryTab: appModelNoUpdate.startupDefaultDictionaryTab,
      fallback: _currentTab,
    );
    // Seed the shared shell notifier (drives the macOS root sidebar) and listen
    // for external selection from it. No-op on non-macOS (the sidebar that writes
    // it only exists under the macOS shell).
    homeShellTabNotifier.value = _currentTab;
    homeShellTabNotifier.addListener(_onShellTabRequested);

    WidgetsBinding.instance.addObserver(this);
    assert(() {
      HomePage.debugSelectTab = _selectTab;
      return true;
    }());
    appModelNoUpdate.databaseCloseNotifier.addListener(refresh);
    // TODO-376：只监听显式「打开查词 tab」请求（桌面悬浮字幕点词等手势触发），切到
    // 查词 tab 让 HomeDictionaryPage 挂载并消费 pending。不在此监听 DesktopLookupService
    // ——spec 2026-07-10 §7 后服务由 AppModel 持有 app 级监听，消费按
    // resolveDesktopLookupConsumer 分区（mainTab 仍只归 HomeDictionaryPage），
    // HomePage 根节点依旧不消费查词请求。
    appModelNoUpdate.homeDictionaryTabRequest
        .addListener(_onHomeDictionaryTabRequested);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (appModel.isFirstTimeSetup) {
        appModel.setLastSelectedDictionaryFormat(
            JapaneseLanguage.instance.standardFormat);
        appModel.setFirstTimeSetupFlag();
      }

      if (mounted) {
        UpdateChecker.scheduleCheck(
          context,
          appVersion,
          // BUG-457：beta/debug 通道用 buildNumber 还原本机已安装 release sequence，
          // 避免无后缀 `X.Y.Z` release 包永判「已是最新」。
          currentBuildNumber: appModel.packageInfo.buildNumber,
          neverRemind: appModel.updateNeverRemind,
          autoInstall: appModel.updateAutoInstall,
          betaChannel: appModel.updateBetaChannel,
          debugChannel: appModel.updateDebugChannel,
          customProxy: appModel.updateCustomProxy,
          // TODO-1024 / BUG-479：启动期后台检查跑完即把结果写回缓存，下次「检查更新」
          // 直接读缓存乐观反馈（恒快）。auto 路径不读缓存（仍后台静默刷新）。
          cacheWriter: appModel.setUpdateCheckCache,
        );
      }

      _triggerFullAutoSync();
      unawaited(appModel.database
          .interruptStaleVideoSourceScrapeRuns()
          .catchError((Object error, StackTrace stackTrace) {
        ErrorLogService.instance.log(
          'HomePage.interruptStaleVideoScrapeRuns',
          error,
          stackTrace,
        );
        return 0;
      }));
      // v77 之前已经存在于库中的来源不会自动重触发扫描。启动时做一次纯本地、
      // 幂等的作品索引，把旧合集/独立电影补成规范 VideoMetadataWork；否则系列页
      // 能看到临时卡片，点进详情却永远只能落到无资料的旧合集视图。
      unawaited(_backfillVideoMetadataWorks());
      // 首帧同步之后挂定时轮询，让静止不动的设备也能周期性拉到远端改动（见
      // [_periodicSyncInterval] 注释）。dispose 时 cancel。
      _periodicSyncTimer =
          Timer.periodic(_periodicSyncInterval, (_) => _triggerFullAutoSync());

      // Lapis 模板启动自动迁移：Hibiki 基线/客制化变了且 Anki 端仍是 Hibiki
      // 已知产物时，自动备份后推送新 styling（手改内容绝不自动覆盖，Anki 未
      // 运行静默跳过）。服务内部有每进程一次的闸门，HomePage 重建不会重跑。
      if (mounted) {
        unawaited(LapisTemplateService(ref.read(ankiRepositoryProvider))
            .maybeAutoMigrateOnStartup()
            .catchError((Object e, StackTrace s) {
          ErrorLogService.instance.log('HomePage.lapisAutoMigrate', e, s);
        }));
      }

      // Anki 媒体去重的自动处理：**默认关**，只有用户在设置页主动打开才会跑。
      // 打开之后也只是自动干跑并把清单提示出来，用户确认后才真删；只有再显式
      // 打开「自动直接删除」才跳过确认（判定全在
      // [AnkiMediaDedupRunner.maybeAutoRunOnStartup]，这里不做二次决策）。
      if (mounted) {
        unawaited(
            _maybeAutoDedupAnkiMedia().catchError((Object e, StackTrace s) {
          ErrorLogService.instance.log('HomePage.ankiMediaDedupAuto', e, s);
        }));
      }
    });
  }

  /// 启动期自动处理一轮 Anki 媒体去重的 UI 侧收尾：报结果，或提示 + 等确认。
  Future<void> _maybeAutoDedupAnkiMedia() async {
    final AnkiMediaDedupAutoOutcome? outcome =
        await AnkiMediaDedupRunner(ref.read(ankiRepositoryProvider))
            .maybeAutoRunOnStartup();
    if (outcome == null || !mounted) return;
    final AnkiMediaDedupReport? applied = outcome.applied;
    if (applied != null) {
      // 用户显式选了「自动直接删除」：只报结果。
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(t.anki_dedup_auto_done(
          count: '${applied.duplicatesRemoved}',
          size: formatAnkiMediaDedupBytes(applied.bytesSaved),
        )),
      ));
      return;
    }
    if (!outcome.needsConfirmation) return;
    // 保守路径（默认）：只提示。用户点「查看」才摊开逐条清单，再点删除才真删。
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(t.anki_dedup_auto_found(
        count: '${outcome.plan.duplicatesRemoved}',
        size: formatAnkiMediaDedupBytes(outcome.plan.bytesSaved),
      )),
      duration: const Duration(seconds: 10),
      action: SnackBarAction(
        label: t.anki_dedup_auto_review,
        onPressed: () => unawaited(_reviewAutoDedupPlan(outcome.plan)),
      ),
    ));
  }

  /// 「查看」→ 逐条清单 + 删除确认 → 真删（带进度对话框，可取消）→ 结果
  /// 报告。与设置页手动路径同一套弹窗（见 anki_media_dedup_dialogs.dart）。
  Future<void> _reviewAutoDedupPlan(AnkiMediaDedupReport plan) async {
    if (!mounted) return;
    final bool confirmed =
        await showAnkiMediaDedupPlanDialog(context, plan, offerDelete: true);
    if (!confirmed || !mounted) return;
    final AnkiMediaDedupReport? result = await runAnkiMediaDedupWithProgress(
      context,
      AnkiMediaDedupRunner(ref.read(ankiRepositoryProvider)),
      dryRun: false,
    );
    if (result == null || !mounted) return;
    await showAnkiMediaDedupReportDialog(context, result);
  }

  /// 触发一次 app-open 语义的全量双向同步（导入远端新书 + 同步进度 / 内容 / 词典 / 有声书
  /// / 统计 / 合集）。首帧 postFrame 与 [_periodicSyncTimer] 定时轮询共用同一入口，保持
  /// 单一逻辑。内部经 `_runAutoSyncAll` 的自动开关门控 + 5 分钟冷却 + `__all__` 去重锁，
  /// 重复触发天然安全。
  void _triggerFullAutoSync() {
    if (!mounted) return;
    triggerAutoSyncOnAppOpen(
      db: appModel.database,
      dictionaryResourceRoot: appModel.dictionaryResourceDirectory,
      audioDatabaseRoot: Directory('${appModel.appDirectory.path}/audiobooks'),
      tempDir: appModel.temporaryDirectory,
      localAudioEntries: appModel.localAudioDbs,
      onLocalAudioImported: appModel.importSyncedLocalAudioDb,
      onPostRun: appModel.refreshAfterSyncRun,
      onReport: appModel.presentSyncPrompts,
    );
  }

  void refresh() {
    setState(() {});
  }

  Future<void> _backfillVideoMetadataWorks() async {
    final List<SourceLibraryRow> sources =
        await appModel.database.getMediaSourcesByKind('video');
    final VideoSourceMetadataIndexer indexer =
        VideoSourceMetadataIndexer(appModel.database);
    bool changed = false;
    for (final SourceLibraryRow source in sources) {
      try {
        await indexer.index(source);
        changed = true;
      } on Object catch (error, stackTrace) {
        ErrorLogService.instance.log(
          'HomePage.backfillVideoMetadataWorks.${source.id}',
          error,
          stackTrace,
        );
      }
    }
    if (changed && mounted) _notifyVideoLibraryChanged();
  }

  /// TODO-376：响应显式「打开查词 tab」请求（[AppModel.homeDictionaryTabRequest]）。
  /// 桌面悬浮字幕条点词（reader 路由 `_lookupFromFloatingLyric`）这类**显式**手势会先
  /// 把待查词排进 [DesktopLookupService.pendingText]、唤主窗前台，再发本请求；这里只把
  /// 主窗切到查词 tab，让 [HomeDictionaryPage] 挂载——它在 initState 里无条件消费一次
  /// 已存在的 pending 并展示。
  ///
  /// 这是与被动剪贴板监听正交的显式导航：本回调不读 pendingText、也不被剪贴板/热键的
  /// 被动命中触发，故不违反「HomePage 根节点不消费查词请求（mainTab 分区只归
  /// HomeDictionaryPage，spec 2026-07-10 §7）」的守卫。已在查词 tab 时无需切换
  /// （页面已挂载并消费）。
  void _onHomeDictionaryTabRequested() {
    if (!mounted) return;
    if (_currentTab == HomeTab.dictionaries) return;
    _selectTab(HomeTab.dictionaries);
  }

  @override
  void dispose() {
    assert(() {
      HomePage.debugSelectTab = null;
      return true;
    }());
    _periodicSyncTimer?.cancel();
    _shutdownVideoSourceScrape();
    _videoDiscoveryService?.close();
    _videoDiscoveryService = null;
    _videoDiscoveryController = null;
    _dictFocusSignal.dispose();
    _videoLibraryRefreshSignal.dispose();
    _keyboardFocusNode.dispose();
    WidgetsBinding.instance.removeObserver(this);
    appModelNoUpdate.databaseCloseNotifier.removeListener(refresh);
    appModelNoUpdate.homeDictionaryTabRequest
        .removeListener(_onHomeDictionaryTabRequested);
    homeShellTabNotifier.removeListener(_onShellTabRequested);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (AppLifecycleState.resumed == state) {
      debugPrint('Lifecycle Resumed');
      appModel.searchDictionary(
        searchTerm: JapaneseLanguage.instance.helloWorld,
        searchWithWildcards: false,
        useCache: false,
      );
      // TODO-900: OS 层失焦（Alt+Tab 切窗）后 Flutter 不保证把 primaryFocus 归还到
      // 首页键事件 Focus，导致切窗回来后页级 / 全局快捷键全死，只能重启 app 才靠
      // autofocus 抢回。对齐视频页 [_reclaimVideoFocusIfOwned] 的 resumed 回收范式。
      _reclaimHomeFocusIfOwned();
    } else if (AppLifecycleState.detached == state) {
      _videoSourceScrapeTaskController?.markInterrupted();
    } else if (AppLifecycleState.paused == state) {
      if (appModel.lowMemoryMode) {
        PaintingBinding.instance.imageCache.clear();
      }
      final item = appModel.currentMediaItem;
      if (item != null) {
        triggerAutoSyncOnBackground(
          db: appModel.database,
          mediaIdentifier: item.mediaIdentifier,
        );
      }
    }
  }

  /// TODO-900：app 回前台时把 Flutter 焦点收回首页键事件入口，修复「切窗回来后
  /// 首页 / 全局快捷键整体失灵、只能重启复活」。两态分支（对齐 [_wrapFocusNavigation]）：
  /// - 实验焦点导航开（存在 [FushiFocusRoot] 控制器）→ `controller.ensureFocus()`，
  ///   把焦点 home 到一个真实可聚焦目标（仍落在首页 Focus 子树内，键事件照常冒泡到
  ///   [_handleKeyEvent]）。
  /// - 关（默认，无 FushiFocusRoot）→ 直接 requestFocus **既有** [_keyboardFocusNode]
  ///   （绑定 [_handleKeyEvent] 的同一节点，不新造节点）。
  /// 路由门控：首页非当前路由（上方压着对话框）时不抢焦点，避免夺走对话框焦点
  /// （Never break userspace）——对话框关闭时各自的返回点会归还焦点。
  void _reclaimHomeFocusIfOwned() {
    if (!mounted) return;
    final ModalRoute<Object?>? owner = ModalRoute.of(context);
    if (owner != null && !owner.isCurrent) return;
    final FushiFocusController? controller =
        FushiFocusRoot.maybeControllerOf(context, listen: false);
    if (controller != null) {
      controller.ensureFocus();
      return;
    }
    if (_keyboardFocusNode.canRequestFocus) {
      _keyboardFocusNode.requestFocus();
    }
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    // Arrow KeyDownEvent OR OS auto-repeat (KeyRepeatEvent) drives a step of
    // directional focus movement, so holding an arrow advances focus
    // continuously instead of one step per discrete press. KeyDown also runs the
    // shortcut/gamepad resolution below (once per press); a repeat must ONLY move
    // focus — re-resolving a bound shortcut on every repeat would fire it
    // repeatedly. Skipped while a text field is focused so the field's own caret
    // keeps the arrows (same guard as the KeyDown arrow branch below).
    final TraversalDirection? repeatDir =
        event is KeyRepeatEvent ? arrowFocusMoveDirection(event) : null;
    if (repeatDir != null) {
      if (focusedEditableText() != null) return KeyEventResult.ignored;
      gamepadMoveFocusInDirection(context, repeatDir);
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final KeyEventResult focusedGamepadAction =
        dispatchNativeGamepadButtonIntent(event);
    if (focusedGamepadAction == KeyEventResult.handled) {
      return focusedGamepadAction;
    }

    final modifiers = <ModifierKey>{};
    if (HardwareKeyboard.instance.isControlPressed) {
      modifiers.add(ModifierKey.ctrl);
    }
    if (HardwareKeyboard.instance.isShiftPressed) {
      modifiers.add(ModifierKey.shift);
    }
    if (HardwareKeyboard.instance.isAltPressed) {
      modifiers.add(ModifierKey.alt);
    }
    if (HardwareKeyboard.instance.isMetaPressed) {
      modifiers.add(ModifierKey.meta);
    }

    // TODO-847: IME 激活时 logicalKey 被改写成 process，传 physicalKey 让 registry
    // 走物理键回退；文本框 composing（focusedEditableText != null）时传 null 关闭
    // 回退，避免搜索框打字误触 Ctrl+数字等快捷键。
    final PhysicalKeyboardKey? imeFallbackPhysicalKey =
        focusedEditableText() == null ? event.physicalKey : null;
    ShortcutAction? action = appModel.shortcutRegistry.resolveKeyboard(
          event.logicalKey,
          modifiers: modifiers,
          scope: ShortcutScope.home,
          physicalKey: imeFallbackPhysicalKey,
        ) ??
        appModel.shortcutRegistry.resolveKeyboard(
          event.logicalKey,
          modifiers: modifiers,
          scope: ShortcutScope.global,
          physicalKey: imeFallbackPhysicalKey,
        ) ??
        // 兜底「返回上一级」（universal，默认 Esc / Alt+← / 手柄 B）。首页自解析它
        // 后不再冒泡到最外层 wrapper，与阅读器/漫画/视频三页同一范式。
        appModel.shortcutRegistry.resolveKeyboard(
          event.logicalKey,
          modifiers: modifiers,
          scope: ShortcutScope.universal,
          physicalKey: imeFallbackPhysicalKey,
        );

    if (action == null) {
      final GamepadButton? gamepad = GamepadButton.fromKeyEvent(event);
      if (gamepad != null) {
        action = appModel.shortcutRegistry.resolveGamepad(
              gamepad,
              scope: ShortcutScope.home,
            ) ??
            appModel.shortcutRegistry.resolveGamepad(
              gamepad,
              scope: ShortcutScope.global,
            ) ??
            appModel.shortcutRegistry.resolveGamepad(
              gamepad,
              scope: ShortcutScope.universal,
            );
      }
    }

    if (action != null) return _executeShortcutAction(action);

    // Arrow keys are unbound on home, so drive robust directional focus
    // navigation through the SAME helper the gamepad D-pad/stick uses — keyboard
    // and gamepad therefore behave identically. Skipped while a text field is
    // focused so the field's own cursor movement keeps working (up/down then
    // bubble to wrapWithGlobalNavigation, which lets them escape a single-line
    // field). Uses the shared arrow/editable helpers so home and the app-wide
    // wrapper read arrows and "is a text field focused" the same way — the old
    // private `is EditableText` check missed every field (the primary focus is
    // EditableText's inner Focus, not the EditableText), so it never actually
    // guarded the search field's caret.
    final TraversalDirection? dir = arrowTraversalDirection(event.logicalKey);
    if (dir != null && focusedEditableText() == null) {
      gamepadMoveFocusInDirection(context, dir);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 当前可见的顶层 tab：首页 → 书架 → 漫画 → 视频 → 游戏 → 下载 → 词典 → 设置。视频
  /// tab 已毕业为常驻（位于书架与词典之间）；games（galgame 库）仅 Windows 桌面出现
  /// （galgame 引擎-hook 注入本就 Windows-only，故以平台而非实验开关门控，默认可见），
  /// 紧跟视频之后。底栏/侧栏的位置索引由此列表导出。
  List<HomeTab> _activeTabs() => homeActiveTabs(
        videoEnabled: true,
        gamesEnabled: Platform.isWindows,
        // 「电脑才有」：浏览器扩展 tab 仅桌面（Windows/macOS/Linux）显示。
        browserExtensionEnabled: DesktopLookupService.isDesktop,
      );

  /// 渲染用的当前 tab：若 `_currentTab` 已不在可见列表（例如刚关掉实验开关时仍停在
  /// 视频 tab），回落到书架，避免渲染一个不存在的 tab。`_currentTab` 自身保持不变，
  /// 下一次 [_selectTab] 会纠正它。
  HomeTab get _visibleTab {
    final List<HomeTab> tabs = _activeTabs();
    return tabs.contains(_currentTab) ? _currentTab : HomeTab.books;
  }

  /// 统一切换顶层 tab：进入「设置」前记录来源 tab，供设置全屏返回箭头切回。
  /// 所有切 tab 入口（侧栏 / 底栏 / 快捷键）都走这里，保证 _previousTab 一致。
  void _selectTab(HomeTab tab) {
    // A same-route home-tab switch (IndexedStack, no route push/pop) still
    // changes the visible screen, so reset any focus ring lit on the old tab so
    // it is not carried onto the new one (BUG-398). Route-based navigation is
    // covered by AppModel.focusHighlightObserver; this handles the tab case the
    // NavigatorObserver cannot see.
    if (tab != _currentTab) {
      appModelNoUpdate.gamepadService.resetHighlightForScreenSwitch();
    }
    setState(() {
      if (tab == HomeTab.settings && _currentTab != HomeTab.settings) {
        _previousTab = _currentTab;
      }
      _currentTab = tab;
    });
    // Reflect the selection into the shared notifier so the macOS root sidebar
    // (built outside HomePage) stays in sync. Guarded by value-equality inside
    // ValueNotifier, so this never re-enters _onShellTabRequested pointlessly.
    homeShellTabNotifier.value = tab;
  }

  /// The macOS root sidebar writes [homeShellTabNotifier] directly; route that
  /// external request through the SAME [_selectTab] path so _previousTab and the
  /// focus-ring reset run identically to a rail/bottom-bar/shortcut switch. Guard
  /// against the echo from _selectTab's own write-back.
  void _onShellTabRequested() {
    final HomeTab requested = homeShellTabNotifier.value;
    if (requested == _currentTab) return;
    if (!mounted) return;
    _selectTab(requested);
  }

  /// next/prev 快捷键：在当前可见 tab 列表里环形步进（视频开关变化时自动适配长度）。
  void _cycleTab(int delta) {
    final List<HomeTab> tabs = _activeTabs();
    final int current = tabs.indexOf(_visibleTab);
    final int next = (current + delta) % tabs.length;
    _selectTab(tabs[(next + tabs.length) % tabs.length]);
  }

  KeyEventResult _executeShortcutAction(ShortcutAction action) {
    switch (action) {
      case ShortcutAction.homeTabBooks:
        _selectTab(HomeTab.books);
        return KeyEventResult.handled;
      case ShortcutAction.homeTabDict:
        _selectTab(HomeTab.dictionaries);
        return KeyEventResult.handled;
      case ShortcutAction.homeTabSettings:
        _selectTab(HomeTab.settings);
        return KeyEventResult.handled;
      case ShortcutAction.homeTabNext:
        _cycleTab(1);
        return KeyEventResult.handled;
      case ShortcutAction.homeTabPrev:
        _cycleTab(-1);
        return KeyEventResult.handled;
      case ShortcutAction.homeFocusSearch:
        _selectTab(HomeTab.dictionaries);
        _dictFocusSignal.value++;
        return KeyEventResult.handled;
      case ShortcutAction.globalBack:
        Navigator.of(context).maybePop();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  /// Handles a gamepad button delivered via [GamepadButtonIntent] (desktop
  /// polled path), routing it through the same actions as the key-event path.
  /// Returns true when consumed; false lets the GamepadService fall back to
  /// directional focus / activate / global back.
  bool _handleGamepadButton(GamepadButton button) {
    final ShortcutAction? action = appModel.shortcutRegistry.resolveGamepad(
          button,
          scope: ShortcutScope.home,
        ) ??
        appModel.shortcutRegistry.resolveGamepad(
          button,
          scope: ShortcutScope.global,
        ) ??
        // 兜底「返回上一级」（universal，默认手柄 B）。
        appModel.shortcutRegistry.resolveGamepad(
          button,
          scope: ShortcutScope.universal,
        );
    if (action == null) return false;
    return _executeShortcutAction(action) == KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    if (!appModel.isDatabaseOpen) {
      return const SizedBox.shrink();
    }

    final Widget home = ValueListenableBuilder<bool>(
        valueListenable: syncInProgress,
        builder: (context, syncing, child) => PopScope(
              canPop: !syncing,
              onPopInvokedWithResult: (didPop, _) async {
                if (didPop) return;
                // 同 route 多 PopScope 的回调全部遍历，故此顶层同步 PopScope 在设置
                // tab 上也会被触发；设置 tab 的返回由内层 PopScope 切回来源 tab，
                // 这里据 [shouldWarnOnExit] 收窄到非设置 tab 才弹同步告警（TODO-698）。
                if (_visibleTab == HomeTab.settings) return;
                final bool? confirmed = await showAppDialog<bool>(
                  context: context,
                  builder: (BuildContext ctx) => _SyncExitWarningDialog(
                    onCancel: () => Navigator.pop(ctx, false),
                    onExit: () => Navigator.pop(ctx, true),
                  ),
                );
                if (confirmed == true) {
                  SystemNavigator.pop();
                }
              },
              child: child!,
            ),
        child: Actions(
            // Desktop gamepad path: the GamepadService dispatches
            // GamepadButtonIntent here (no gameButton* key events on desktop).
            // Resolving it against home/global routes polled controller input
            // through the same actions as the key-event path.
            actions: <Type, Action<Intent>>{
              GamepadButtonIntent: CallbackAction<GamepadButtonIntent>(
                onInvoke: (GamepadButtonIntent intent) =>
                    _handleGamepadButton(intent.button),
              ),
            },
            child: Focus(
              // Autofocus on every platform: on mobile no field on the home tabs
              // grabs focus at mount, so without this the FocusManager has no
              // primary focus and hardware-keyboard / gamepad shortcuts never
              // reach _handleKeyEvent until the user taps something. The home
              // search field focuses on demand, so this never fights an editable.
              autofocus: true,
              // But this wrapper spans the whole page, so it must NOT be a
              // traversal target: otherwise directional (keyboard arrow /
              // gamepad) navigation lands on it and the focus ring covers the
              // entire window. skipTraversal keeps it as a key-event sink only;
              // Tab/arrow/D-pad traversal moves between the real controls and
              // the ring follows them. Shortcut keys still bubble up here.
              skipTraversal: true,
              focusNode: _keyboardFocusNode,
              onKeyEvent: _handleKeyEvent,
              child: GestureDetector(
                onTap: () {
                  final FocusNode? current = FocusManager.instance.primaryFocus;
                  if (current != null && current != _keyboardFocusNode) {
                    current.unfocus();
                  }
                },
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // BUG-401: classify on the real physical width
                    // (logical × appUiScale). This LayoutBuilder sits INSIDE
                    // FushiAppUiScale, so `constraints.maxWidth` is the
                    // inflated logical canvas width; reading it directly kept
                    // desktop locked to the nav-rail layout and the phone
                    // (bottom-bar) layout was unreachable however narrow the
                    // real window got dragged.
                    // macOS-native shell: a real root MacosWindow + Sidebar
                    // (built in main.dart, Approach B) replaces the self-drawn
                    // rail/bottom-bar. MacosWindow manages its own breakpoints, so
                    // HomePage only renders the tab body here — checked before the
                    // size-class switch.
                    if (isMacosPlatform(context)) {
                      return _buildMacosLayout();
                    }
                    final sizeClass = windowSizeClassReal(
                      constraints.maxWidth,
                      FushiAppUiScale.of(context),
                    );
                    // compact(<600) → 底栏；medium/expanded(≥600，含竖屏平板) → 侧边布局。
                    if (sizeClass == WindowSizeClass.compact) {
                      return _buildMobileLayout();
                    }
                    return _buildDesktopLayout(sizeClass);
                  },
                ),
              ),
            )));
    // 桌面剪贴板/热键查词不再叠加独立 overlay 页；监听生命周期收窄到查词 tab。
    return home;
  }

  /// 单个 [HomeTab] 的导航项（图标 + 标签）。底栏/侧栏/macOS 根侧栏共用同一顶层
  /// [homeNavItemFor]，保证三处标签/选中图标一致。
  AdaptiveNavItem _navItemFor(HomeTab tab) => homeNavItemFor(tab);

  /// 可见 tab 列表对应的导航项（与 [_activeTabs] 顺序一致）。
  List<AdaptiveNavItem> _navItems(List<HomeTab> tabs) =>
      tabs.map(_navItemFor).toList();

  /// macOS-native shell (Approach B): the MacosWindow + Sidebar live at the app
  /// ROOT (main.dart builder, via [buildFushiMacosSidebar]) so pushed routes
  /// also inherit a MacosWindowScope. Here HomePage only renders the visible
  /// tab's body in a [MacosScaffold] with a native ToolBar titled by the current
  /// destination. Settings tab reuses the same full-screen two-pane content the
  /// desktop layout uses (the sidebar IS the destination switcher, so no extra
  /// back button). Tab identity is [HomeTab]-driven — the dynamic [_activeTabs]
  /// list (video/games toggles) flows through the same enum, never int.
  Widget _buildMacosLayout() {
    final AdaptiveNavItem currentItem = _navItemFor(_visibleTab);
    // TODO-1375（症状③）：macOS ToolBar 的 automaticallyImplyLeading 只在
    // route.canPop 时生成返回键；home（含 settings）是顶层 route、tab 是 IndexedStack
    // 切换非 route push，故永远 canPop=false、无返回键。设计假设「设置靠根 sidebar 切
    // 走」，可一旦 sidebar 因任何原因没了，设置 tab 就零出口困死。给设置 tab 一个**不
    // 依赖 sidebar**的显式返回出口（切回来源 tab），与桌面 _buildDesktopLayout 的
    // showBackButton:true 对齐——即便 sidebar 缺席也永不困死。
    final bool showSettingsBack = _visibleTab == HomeTab.settings;
    return KeyedSubtree(
      key: fushiMacosNavKey,
      child: MacosScaffold(
        toolBar: ToolBar(
          leading: showSettingsBack
              ? MacosBackButton(
                  fillColor: Colors.transparent,
                  onPressed: () => _selectTab(_previousTab),
                )
              : null,
          automaticallyImplyLeading: false,
          title: Text(currentItem.label),
          titleWidth: 240,
        ),
        children: <Widget>[
          ContentArea(
            builder: (BuildContext context, ScrollController _) {
              // MacosWindow provides no Material ink surface, but the page bodies
              // use Material widgets (InkWell chips, list tiles). A transparent
              // Material gives them the required ancestor without painting over
              // the native window background.
              return Material(
                type: MaterialType.transparency,
                child: _bodyWithMiniBar(),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopLayout(WindowSizeClass sizeClass) {
    if (_visibleTab == HomeTab.settings) {
      // 设置标签（全部设计系统）：隐藏 3 图标侧栏，全屏二栏（内部
      // MaterialSupportingPaneLayout），左上返回箭头切回来源 tab（参考 Mihon
      // 宽屏设置）。Cupertino 桌面也走这里——叶子控件保持 Cupertino 皮肤，但外壳
      // 复用同一 Material 架构；返回出口由 SettingsHomePage 的嵌入页头提供
      // （BUG-009 R2）。否则会退化成「3 图标 rail + 嵌入式 Cupertino 设置」三栏
      // 混排、无返回出口、且详情面板溢出。
      return Scaffold(
        resizeToAvoidBottomInset: false,
        body: SafeArea(
          // macOS 透明标题栏 + full-size content view 下，交通灯不计入
          // MediaQuery.padding，返回箭头会被压在按钮下方。预留标题栏高度作为
          // SafeArea 下限，让顶部内容整体让位（BUG-869）。其它平台 top=0 无影响。
          minimum: EdgeInsets.only(
            top: Platform.isMacOS ? kMacTitleBarHeight : 0,
          ),
          child: FocusTraversalGroup(
            child: _buildSettingsTabContent(showBackButton: true),
          ),
        ),
      );
    }

    final List<HomeTab> tabs = _activeTabs();
    final bool reversed = appModel.reverseNavigationBar;
    final List<AdaptiveNavItem> items = _navItems(tabs);
    final List<AdaptiveNavItem> displayItems =
        reversed ? items.reversed.toList() : items;
    final int visualIndex = homeVisualIndexForTab(
      tabs: tabs,
      tab: _visibleTab,
      reversed: reversed,
    );

    void selectVisual(int index) {
      _selectTab(homeTabForVisualIndex(
        tabs: tabs,
        visualIndex: index,
        reversed: reversed,
      ));
    }

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        // macOS 交通灯保留带：透明标题栏 + full-size content view 下交通灯不计入
        // SafeArea，导航 rail 顶部会被红黄绿按钮压住。预留标题栏高度作为下限，
        // 把整行内容下移一条标题栏（BUG-869）。其它平台 top=0，零影响。
        minimum: EdgeInsets.only(
          top: Platform.isMacOS ? kMacTitleBarHeight : 0,
        ),
        // Two traversal groups so Tab / Shift+Tab walk each region as one block
        // in visual order (whole rail, then whole content) instead of zig-zagging
        // between the rail and the content pane row-by-row.
        child: Row(
          children: [
            // Each rail destination is its own gamepad/keyboard focus target, so
            // the app focus ring hugs the single selected item; D-pad Up/Down
            // steps between them and Left/Right leaves to the content.
            FocusTraversalGroup(
              child: adaptiveNavRail(
                context: context,
                currentIndex: visualIndex,
                onTap: selectVisual,
                items: displayItems,
              ),
            ),
            Expanded(child: FocusTraversalGroup(child: _bodyWithMiniBar())),
          ],
        ),
      ),
    );
  }

  /// 内容主体 + 底部「正在听书」迷你条（TODO-291 阶段2，无活动会话时收起）。
  Widget _bodyWithMiniBar() {
    return Column(
      children: <Widget>[
        Expanded(child: buildBody()),
        const NowListeningMiniBar(),
      ],
    );
  }

  Widget _buildMobileLayout() {
    final List<HomeTab> tabs = _activeTabs();
    final bool reversed = appModel.reverseNavigationBar;
    final List<AdaptiveNavItem> items = _navItems(tabs);
    final List<AdaptiveNavItem> displayItems =
        reversed ? items.reversed.toList() : items;
    final int visualIndex = homeVisualIndexForTab(
      tabs: tabs,
      tab: _visibleTab,
      reversed: reversed,
    );

    // Two traversal groups so D-pad / arrow Left/Right walks each region as one
    // closed block (whole bottom bar, or whole content) instead of escaping from
    // an edge tab up into a content focus target. Mirrors the desktop layout,
    // which already isolates the rail and content panes (TODO-713: 移动端底栏
    // 边缘 tab 按左/右焦点跑到上部).
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: SafeArea(child: FocusTraversalGroup(child: _bodyWithMiniBar())),
      // The FocusTraversalGroup keeps the bottom-nav isolated as one closed
      // traversal block (TODO-713).
      bottomNavigationBar: FocusTraversalGroup(
        child: adaptiveBottomBar(
          context: context,
          currentIndex: visualIndex,
          onTap: (int index) {
            _selectTab(homeTabForVisualIndex(
              tabs: tabs,
              visualIndex: index,
              reversed: reversed,
            ));
          },
          items: displayItems,
        ),
      ),
    );
  }

  /// 需要跨 tab 切换**保活**（State 不随切走而销毁）的顶层 tab：书架、视频与游戏。
  ///
  /// 书架与视频进入时会做**无持久缓存的远端加载**——`listRemoteBooks()` /
  /// `listRemoteVideos()` 每次都实打实打网络，远端封面（`RemoteCoverImage`）只走进程
  /// 内 `ImageCache`、无磁盘缓存。若页面 State 随切走被销毁，切回时 `initState` 重跑
  /// 就会把远端列表 + 封面全部重新联网拉一遍（用户报「每次进书架/视频都重新加载」）。
  /// 保活让 State 常驻 → 切回沿用已加载的列表/封面/滚动位置，秒回。
  ///
  /// 游戏页也必须保活：捕获工作台拥有文本订阅、音频源与轮询会话，切去查词或设置时
  /// 只能隐藏，不能因 dispose 停止正在进行的 Hook。
  ///
  /// 其余 tab（词典 / 设置）**故意不保活**、按需重建，以保留其依赖
  /// `initState` 挂载的语义——尤其 [HomeDictionaryPage] 靠切到查词 tab 时 re-mount
  /// 消费桌面悬浮字幕的 pending 查词（TODO-376，见 [_onHomeDictionaryTabRequested]）；
  /// 若把它也保活会不再 re-mount 而漏消费。
  static const Set<HomeTab> _keepAliveTabs = <HomeTab>{
    HomeTab.books,
    HomeTab.manga,
    HomeTab.video,
    HomeTab.games,
  };

  /// 用户已实际打开过至少一次的保活 tab。惰性构建：没进过的视频/书架 tab 不预建，
  /// 避免 app 一启动就把没访问的 tab 的远端列表/封面预拉一遍。
  final Set<HomeTab> _visitedKeepAliveTabs = <HomeTab>{};

  /// 缓存视频页仓库实例，令 [HomeVideoPage] 的 `widget.repo` 跨 [buildBody] 重建保持
  /// 同一对象，避免每次 `setState` 都塞入新 repo 触发无谓 didUpdateWidget。
  VideoBookRepository? _videoRepo;
  VideoBookRepository get _videoRepository =>
      _videoRepo ??= VideoBookRepository(appModel.database);

  VideoDiscoveryController get _productionVideoDiscoveryController {
    final String configuredTmdbKey = appModelNoUpdate.prefsRepo
        .getPref(kVideoScraperTmdbApiKeyPref, defaultValue: '') as String;
    final VideoSourceScrapeGlobalConfig config =
        VideoSourceScrapeGlobalConfig.fromPreferences(
      appModelNoUpdate.prefsRepo,
      resolvedTmdbApiKey: resolveTmdbApiKey(configuredTmdbKey),
    );
    final String fingerprint = <Object>[
      config.tmdbApiKey,
      config.bangumiToken,
      config.locale,
    ].join('\u0000');
    final VideoDiscoveryController? existing = _videoDiscoveryController;
    if (existing != null && _videoDiscoveryConfigFingerprint == fingerprint) {
      return existing;
    }
    _videoDiscoveryService?.close();
    final VideoDiscoveryService service =
        VideoDiscoveryService.production(config);
    final VideoDiscoveryController controller =
        _ProductionVideoDiscoveryController(service);
    _videoDiscoveryService = service;
    _videoDiscoveryController = controller;
    _videoDiscoveryConfigFingerprint = fingerprint;
    return controller;
  }

  VideoDiscoveryActions get _productionVideoDiscoveryActions =>
      VideoDiscoveryActions(
        loadDetails: _loadVideoDiscoveryDetails,
        watchStatus: _watchVideoDiscoveryStatus,
        onSearchResource: _openVideoDiscoveryResourceSearch,
        onSearchSubtitle: _openVideoDiscoverySubtitleSearch,
        onSubscribe: _openVideoDiscoverySubscription,
        onPlay: _openLocalVideoDiscoveryWork,
        onOpenDownloads: () => _openDownloadsTab(0),
        onOpenSubscriptions: _openVideoDiscoverySubscriptionsPanel,
      );

  void _openVideoDiscoverySubscriptionsPanel() {
    unawaited(Navigator.of(context).maybePop().then((_) {
      if (mounted) _openDownloadsTab(2);
    }));
  }

  Future<VideoDiscoveryDetailData> _loadVideoDiscoveryDetails(
    VideoDiscoveryItem item,
  ) async {
    final VideoMetadataWork? work =
        await _videoDiscoveryService?.loadDetails(item);
    if (work == null) return VideoDiscoveryDetailData(item: item);
    final VideoDiscoveryItem detailedItem = VideoDiscoveryItem(
      reference: item.reference,
      overview: work.plot ?? item.overview,
      posterUrl: _videoMetadataImageUrl(
            work,
            VideoMetadataImageKind.cover,
          ) ??
          item.posterUrl,
      backdropUrl: _videoMetadataImageUrl(
            work,
            VideoMetadataImageKind.backdrop,
          ) ??
          item.backdropUrl,
      score: work.rating ?? item.score,
      releaseDate: work.premiered ?? item.releaseDate,
      genres: work.genres.isEmpty ? item.genres : work.genres,
      metadataWork: work,
      confirmedLookup: item.confirmedLookup,
    );
    final Map<String, VideoDiscoveryPerson> people =
        <String, VideoDiscoveryPerson>{};
    for (final VideoMetadataCredit credit in work.credits) {
      final VideoMetadataPerson person = credit.person;
      final String key =
          person.id?.trim().isNotEmpty == true ? person.id! : person.name;
      people.putIfAbsent(
        key,
        () => VideoDiscoveryPerson(
          name: person.name,
          role: credit.roleName ?? credit.job ?? credit.department,
          imageUrl: person.profileUrl,
        ),
      );
    }
    return VideoDiscoveryDetailData(
      item: detailedItem,
      facts: <VideoDiscoveryFact>[
        if (work.year != null)
          VideoDiscoveryFact(
            label: t.video_filter_year,
            value: '${work.year}',
          ),
        if (work.episodeCount != null)
          VideoDiscoveryFact(
            label: t.video_scrape_episodes,
            value: '${work.episodeCount}',
          ),
        if (work.studios.isNotEmpty)
          VideoDiscoveryFact(
            label: t.video_work_studios,
            value: work.studios.join(' · '),
          ),
        if (work.countries.isNotEmpty)
          VideoDiscoveryFact(
            label: t.video_work_countries,
            value: work.countries.join(' · '),
          ),
        if (work.contentRating?.trim().isNotEmpty == true)
          VideoDiscoveryFact(
            label: t.video_work_content_rating,
            value: work.contentRating!,
          ),
      ],
      people: people.values,
    );
  }

  Future<void> _openVideoDiscoveryResourceSearch(
    BuildContext context,
    VideoDiscoveryItem item,
  ) async {
    final VideoResourceRegistry? registry =
        appModelNoUpdate.videoResourceRegistry;
    final VideoDownloadPipelineService? pipeline =
        appModelNoUpdate.videoDownloadPipelineService;
    if (registry == null || pipeline == null) {
      _showVideoDiscoveryMessage(context, t.download_backend_not_configured);
      return;
    }
    final List<MediaSourceRow> sources =
        await appModelNoUpdate.getManagedVideoDownloadSources();
    if (!context.mounted) return;
    if (sources.isEmpty) {
      _showVideoDiscoveryMessage(context, t.media_source_no_sources);
      return;
    }
    final VideoDownloadBackendIdentity identity;
    try {
      identity = await appModelNoUpdate.currentVideoDownloadBackendIdentity();
    } on VideoDownloadBackendUnavailable catch (error) {
      if (context.mounted) {
        _showVideoDiscoveryMessage(context, error.message);
      }
      return;
    } on Object {
      if (context.mounted) {
        _showVideoDiscoveryMessage(context, t.download_backend_not_configured);
      }
      return;
    }
    if (!context.mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => VideoDiscoveryResourceSearchPage(
          item: item,
          registry: registry,
          sources: sources,
          defaultSourceId:
              appModelNoUpdate.prefsRepo.videoDownloadTargetSourceId,
          onSubmit: (VideoDiscoveryDownloadSelection selection) async {
            await pipeline.enqueue(
              VideoDownloadEnqueueRequest(
                media: selection.media,
                resource: selection.resource,
                backendIdentity: identity,
                targetSourceId: selection.source.id,
                subtitlePolicy: selection.subtitlePolicy,
                coverUrl: item.posterUrl,
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _openVideoDiscoverySubscription(
    BuildContext context,
    VideoDiscoveryItem item,
  ) async {
    final List<VideoDownloadSubscriptionRow> existing =
        await _matchingVideoDiscoverySubscriptions(item.reference);
    if (!context.mounted) return;
    if (existing.any((VideoDownloadSubscriptionRow row) => row.enabled)) {
      Navigator.of(context).pop();
      _openDownloadsTab(2);
      return;
    }
    final VideoResourceRegistry? registry =
        appModelNoUpdate.videoResourceRegistry;
    if (registry == null ||
        appModelNoUpdate.videoDownloadPipelineService == null ||
        appModelNoUpdate.videoDownloadSubscriptionService == null) {
      _showVideoDiscoveryMessage(context, t.download_backend_not_configured);
      return;
    }
    final List<MediaSourceRow> sources =
        await appModelNoUpdate.getManagedVideoDownloadSources();
    if (!context.mounted) return;
    if (sources.isEmpty) {
      _showVideoDiscoveryMessage(context, t.media_source_no_sources);
      return;
    }
    final VideoDownloadBackendIdentity identity;
    try {
      identity = await appModelNoUpdate.currentVideoDownloadBackendIdentity();
    } on VideoDownloadBackendUnavailable catch (error) {
      if (context.mounted) {
        _showVideoDiscoveryMessage(context, error.message);
      }
      return;
    } on Object {
      if (context.mounted) {
        _showVideoDiscoveryMessage(context, t.download_backend_not_configured);
      }
      return;
    }
    if (!context.mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => VideoDiscoverySubscriptionPage(
          item: item,
          registry: registry,
          sources: sources,
          defaultSourceId:
              appModelNoUpdate.prefsRepo.videoDownloadTargetSourceId,
          onSubmit: (VideoDiscoverySubscriptionSelection selection) async {
            final int now = DateTime.now().millisecondsSinceEpoch;
            final String subscriptionId =
                videoDiscoverySubscriptionId(item.reference);
            final VideoDownloadSubscriptionRow? previous =
                await appModelNoUpdate.database
                    .getVideoDownloadSubscription(subscriptionId);
            final VideoResourceCandidate resource = selection.download.resource;
            await appModelNoUpdate.database.upsertVideoDownloadSubscription(
              VideoDownloadSubscriptionsCompanion.insert(
                subscriptionId: subscriptionId,
                resourceProvider: persistedVideoResourceProviderId(resource),
                metadataProvider: Value<String?>(item.reference.providerId),
                externalId: Value<String?>(item.reference.mediaId),
                mediaKind: item.reference.mediaKind.name,
                discoveryCategory:
                    Value<String?>(item.reference.discoveryCategory.name),
                title: item.reference.title,
                year: Value<int?>(item.reference.year),
                season: Value<int?>(item.reference.season),
                coverUrl: Value<String?>(item.posterUrl),
                searchQuery: _videoResourceSearchQuery(item.reference),
                filterJson: Value<String>(selection.filter.json),
                mode: Value<String>(
                  item.reference.mediaKind == VideoMetadataMediaKind.movie
                      ? 'oneShot'
                      : 'ongoing',
                ),
                startAfterEpisode: Value<int?>(selection.startAfterEpisode),
                backendKind: identity.kind,
                backendProfileId: Value<String?>(identity.profileId),
                fingerprint: identity.fingerprint,
                category: Value<String?>(identity.category),
                targetSourceId: Value<int?>(selection.download.source.id),
                organizationPolicy: const Value<String>('library'),
                subtitlePolicy:
                    Value<String>(selection.download.subtitlePolicy.name),
                enabled: const Value<bool>(true),
                nextCheckAt: Value<int?>(now),
                claimedBy: const Value<String?>(null),
                claimExpiresAt: const Value<int?>(null),
                retryCount: const Value<int>(0),
                fulfilledAt: const Value<int?>(null),
                lastError: const Value<String?>(null),
                createdAt: previous?.createdAt ?? now,
                updatedAt: now,
              ),
            );
            await appModelNoUpdate.videoDownloadSubscriptionService?.checkNow();
          },
        ),
      ),
    );
  }

  Future<void> _openVideoDiscoverySubtitleSearch(
    BuildContext context,
    VideoDiscoveryItem item,
  ) async {
    final registry = appModelNoUpdate.videoSubtitleRegistry;
    if (registry == null) {
      _showVideoDiscoveryMessage(context, t.video_discovery_load_failed);
      return;
    }
    final VideoDownloadPipelineService? pipeline =
        appModelNoUpdate.videoDownloadPipelineService;
    final List<VideoDownloadJobRow> attachableJobs =
        (await appModelNoUpdate.database.getVideoDownloadJobs())
            .where(
              (VideoDownloadJobRow job) =>
                  isAttachableVideoDownloadJob(job, item.reference),
            )
            .toList(growable: false);
    if (!context.mounted) return;
    await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => VideoDiscoverySubtitleSearchPage(
          item: item,
          registry: registry,
          pickVideo: (BuildContext pickerContext) => pickRealFilePath(
            context: pickerContext,
            appModel: appModelNoUpdate,
            allowedExtensions: videoDiscoveryPickerExtensions,
          ),
          pickDirectory: (BuildContext pickerContext) => pickRealDirectoryPath(
            context: pickerContext,
            appModel: appModelNoUpdate,
          ),
          attachableJobs: attachableJobs,
          onAttach: pipeline == null
              ? null
              : (
                  VideoDownloadJobRow job,
                  VideoSubtitleCandidate candidate,
                ) =>
                  pipeline.attachSubtitleSelection(
                    jobId: job.jobId,
                    candidate: candidate,
                    season: item.reference.season,
                    episode: item.reference.episode,
                  ),
          onInstalled: (
            SubtitleInstallTarget target,
            String selectedPath,
            String installedPath,
          ) async {
            if (target != SubtitleInstallTarget.existingVideo) return;
            final VideoBookRow? book =
                await _videoRepository.findByVideoPath(selectedPath);
            if (book == null) return;
            final SubtitleAttachResult result = await attachSubtitleToVideoBook(
              repo: _videoRepository,
              book: book,
              subtitlePath: installedPath,
            );
            if (result.outcome == SubtitleAttachOutcome.attached) {
              _notifyVideoLibraryChanged();
            }
          },
        ),
      ),
    );
  }

  String _videoResourceSearchQuery(VideoMediaReference reference) {
    if (reference.discoveryCategory != VideoDiscoveryCategory.anime) {
      return reference.title;
    }
    final List<String> queries = preferredNyaaSearchQueries(
      VideoResourceSearchRequest(media: reference),
    );
    return queries.isEmpty ? reference.title : queries.first;
  }

  void _showVideoDiscoveryMessage(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _openDownloadsTab(int tabIndex) {
    setState(() {
      _downloadsInitialTabIndex = tabIndex.clamp(0, 2);
      _downloadsGeneration++;
    });
    _selectTab(HomeTab.downloads);
  }

  Stream<VideoDiscoveryAcquisitionState> _watchVideoDiscoveryStatus(
    VideoMediaReference reference,
  ) {
    late final StreamController<VideoDiscoveryAcquisitionState> controller;
    final List<StreamSubscription<Object?>> subscriptions =
        <StreamSubscription<Object?>>[];
    bool reading = false;
    bool pending = false;

    Future<void> emit() async {
      if (reading) {
        pending = true;
        return;
      }
      reading = true;
      do {
        pending = false;
        final VideoDiscoveryAcquisitionState state =
            await _readVideoDiscoveryStatus(reference);
        if (!controller.isClosed) controller.add(state);
      } while (pending && !controller.isClosed);
      reading = false;
    }

    void onLibraryRefresh() => unawaited(emit());
    controller = StreamController<VideoDiscoveryAcquisitionState>(
      onListen: () {
        subscriptions.add(
          appModelNoUpdate.database.watchVideoDownloadJobs().listen(
                (_) => unawaited(emit()),
              ),
        );
        subscriptions.add(
          appModelNoUpdate.database.watchVideoDownloadSubscriptions().listen(
                (_) => unawaited(emit()),
              ),
        );
        subscriptions.add(
          _videoRepository.watchVideoBookUids().listen(
                (_) => unawaited(emit()),
              ),
        );
        _videoLibraryRefreshSignal.addListener(onLibraryRefresh);
        unawaited(emit());
      },
      onCancel: () async {
        _videoLibraryRefreshSignal.removeListener(onLibraryRefresh);
        for (final StreamSubscription<Object?> subscription in subscriptions) {
          await subscription.cancel();
        }
      },
    );
    return controller.stream;
  }

  Future<VideoDiscoveryAcquisitionState> _readVideoDiscoveryStatus(
    VideoMediaReference reference,
  ) async {
    final List<VideoDownloadJobRow> jobs =
        (await appModelNoUpdate.database.getVideoDownloadJobs())
            .where((VideoDownloadJobRow row) => _discoveryIdentityMatches(
                  reference,
                  row.metadataProvider,
                  row.externalId,
                ))
            .toList(growable: false);
    final List<VideoDownloadSubscriptionRow> subscriptions =
        await _matchingVideoDiscoverySubscriptions(reference);
    final VideoMetadataWorkRow? local =
        await _findLocalVideoDiscoveryWork(reference);
    final VideoDownloadJobRow? job = jobs.firstOrNull;
    final bool busy = job?.lifecycle == VideoDownloadJobLifecycle.active;
    final bool subscribed = subscriptions.any(
      (VideoDownloadSubscriptionRow row) => row.enabled,
    );
    return VideoDiscoveryAcquisitionState(
      statusLabel: _videoDiscoveryStatusLabel(
        job: job,
        subscribed: subscribed,
        inLibrary: local != null,
      ),
      isSubscribed: subscribed,
      isInLibrary: local != null,
      isBusy: busy,
    );
  }

  String? _videoDiscoveryStatusLabel({
    required VideoDownloadJobRow? job,
    required bool subscribed,
    required bool inLibrary,
  }) {
    if (job != null) {
      if (job.lifecycle == VideoDownloadJobLifecycle.needsAttention ||
          job.lifecycle == VideoDownloadJobLifecycle.failed) {
        return '${t.download_task_status_error} · '
            '${_videoDownloadStageLabel(job.stage)}';
      }
      if (job.lifecycle == VideoDownloadJobLifecycle.cancelled) {
        return t.download_status_cancelled;
      }
      if (job.lifecycle == VideoDownloadJobLifecycle.active) {
        return _videoDownloadStageLabel(job.stage);
      }
      if (job.lifecycle == VideoDownloadJobLifecycle.completed && !inLibrary) {
        return t.download_task_status_completed;
      }
    }
    if (inLibrary) return t.video_discovery_in_library;
    if (subscribed) return t.download_airing_calendar_subscribed;
    return null;
  }

  String _videoDownloadStageLabel(String stage) => switch (stage) {
        VideoDownloadJobStage.enqueue => t.download_status_queued,
        VideoDownloadJobStage.download => t.download_task_status_downloading,
        VideoDownloadJobStage.organize => t.download_task_status_moving,
        VideoDownloadJobStage.subtitle => t.video_loading_subtitle,
        VideoDownloadJobStage.import => t.import_step_persisting,
        VideoDownloadJobStage.scrape => t.video_source_scrape_phase_applying,
        _ => t.video_discovery_pipeline_idle,
      };

  Future<List<VideoDownloadSubscriptionRow>>
      _matchingVideoDiscoverySubscriptions(
    VideoMediaReference reference,
  ) async =>
          (await appModelNoUpdate.database.getVideoDownloadSubscriptions())
              .where(
                (VideoDownloadSubscriptionRow row) => _discoveryIdentityMatches(
                  reference,
                  row.metadataProvider,
                  row.externalId,
                ),
              )
              .toList(growable: false);

  bool _discoveryIdentityMatches(
    VideoMediaReference reference,
    String? provider,
    String? externalId,
  ) {
    final String normalizedProvider = provider?.trim().toLowerCase() ?? '';
    final String normalizedId = externalId?.trim().toLowerCase() ?? '';
    if (normalizedProvider.isEmpty || normalizedId.isEmpty) return false;
    if (normalizedProvider == reference.providerId.trim().toLowerCase() &&
        normalizedId == reference.mediaId.trim().toLowerCase()) {
      return true;
    }
    return switch (normalizedProvider) {
      'tmdb' => normalizedId == reference.tmdbId?.toString(),
      'anilist' => normalizedId == reference.anilistId?.toString(),
      'bangumi' => normalizedId == reference.bangumiId?.toString(),
      'imdb' => normalizedId == reference.imdbId?.trim().toLowerCase(),
      'tvdb' => normalizedId == reference.tvdbId?.toString(),
      _ => reference.externalIds.entries.any(
          (MapEntry<String, String> entry) =>
              entry.key.trim().toLowerCase() == normalizedProvider &&
              entry.value.trim().toLowerCase() == normalizedId,
        ),
    };
  }

  Future<VideoMetadataWorkRow?> _findLocalVideoDiscoveryWork(
    VideoMediaReference reference,
  ) async {
    final List<VideoMetadataWorkRow> works =
        await appModelNoUpdate.database.getAllVideoMetadataWorks();
    for (final VideoMetadataWorkRow work in works) {
      if (work.mediaType != reference.mediaKind.name) continue;
      final List<VideoMetadataProviderIdentityRow> identities =
          await appModelNoUpdate.database.getVideoMetadataProviderIdentities(
        workId: work.id,
      );
      if (identities.any(
        (VideoMetadataProviderIdentityRow identity) =>
            _discoveryIdentityMatches(
          reference,
          identity.provider,
          identity.externalId,
        ),
      )) {
        return work;
      }
    }
    return null;
  }

  Future<void> _openLocalVideoDiscoveryWork(
    BuildContext context,
    VideoDiscoveryItem item,
  ) async {
    final VideoMetadataWorkRow? work =
        await _findLocalVideoDiscoveryWork(item.reference);
    if (work == null || !context.mounted) return;
    final String? bookUid = work.bookUid;
    if (bookUid != null) {
      final VideoBookRow? book =
          await appModelNoUpdate.database.getVideoBookByBookUid(bookUid);
      if (book == null || !context.mounted) return;
      await openLocalVideoBook(
        context: context,
        repo: _videoRepository,
        bookUid: book.bookUid,
      );
      return;
    }
    final int? collectionId = work.collectionId;
    if (collectionId == null) return;
    final List<MediaCollectionItemRow> items =
        await appModelNoUpdate.database.getCollectionItems(collectionId);
    final List<VideoBookRow> members = <VideoBookRow>[];
    for (final MediaCollectionItemRow entry in items) {
      if (MediaKind.tryParse(entry.mediaType) != MediaKind.video) continue;
      final VideoBookRow? book =
          await appModelNoUpdate.database.getVideoBookByBookUid(entry.entryKey);
      if (book != null) members.add(book);
    }
    if (members.isEmpty || !context.mounted) return;
    final int index = continueMemberIndex(
      members
          .map(
            (VideoBookRow book) => CollectionMemberProgress(
              positionMs: book.lastPositionMs,
              completed: book.completedAt != null,
            ),
          )
          .toList(growable: false),
    );
    await openLocalVideoBook(
      context: context,
      repo: _videoRepository,
      bookUid: members[index].bookUid,
      playlistCollectionId: collectionId,
    );
  }

  void _notifyVideoLibraryChanged() {
    _videoLibraryRefreshSignal.value++;
  }

  VideoSourceScrapeTaskController get _videoSourceScrapeController {
    final VideoSourceScrapeTaskController? existing =
        _videoSourceScrapeTaskController;
    final String configuredTmdbKey = appModelNoUpdate.prefsRepo
        .getPref(kVideoScraperTmdbApiKeyPref, defaultValue: '') as String;
    final VideoSourceScrapeGlobalConfig config =
        VideoSourceScrapeGlobalConfig.fromPreferences(
      appModelNoUpdate.prefsRepo,
      resolvedTmdbApiKey: resolveTmdbApiKey(configuredTmdbKey),
    );
    final String fingerprint = <Object>[
      config.primaryProvider.name,
      config.tmdbApiKey,
      config.fanartApiKey,
      config.bangumiToken,
      config.doubanEndpoint,
      config.doubanToken,
      config.locale,
    ].join('\u0000');
    if (existing != null &&
        (existing.isBusy ||
            _videoSourceScrapeConfigFingerprint == fingerprint)) {
      return existing;
    }
    existing?.removeListener(_onVideoSourceScrapeTaskChanged);
    existing?.dispose();
    _videoSourceScrapeCoordinator?.close();
    final VideoSourceScrapeCoordinator coordinator =
        VideoSourceScrapeCoordinator(
      database: appModel.database,
      config: config,
    );
    _videoSourceScrapeCoordinator = coordinator;
    _videoSourceScrapeConfigFingerprint = fingerprint;
    final VideoSourceScrapeTaskController controller =
        VideoSourceScrapeTaskController(coordinator)
          ..addListener(_onVideoSourceScrapeTaskChanged);
    return _videoSourceScrapeTaskController = controller;
  }

  void _onVideoSourceScrapeTaskChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _openVideoSourceScrapeTasks() async {
    if (!mounted || _videoSourceScrapePanelOpen) return;
    _videoSourceScrapePanelOpen = true;
    try {
      await showVideoSourceScrapeTaskPanel(
        context: context,
        controller: _videoSourceScrapeController,
        loadRuns: () => appModel.database.getVideoSourceScrapeRuns(limit: 20),
        onRetry: (VideoSourceScrapeRunRow run) async {
          final int? sourceId = run.sourceId;
          if (sourceId == null) return;
          final SourceLibraryRow? source =
              await appModel.database.getMediaSourceById(sourceId);
          if (source == null) return;
          await _scrapeVideoSource(source);
        },
      );
    } finally {
      _videoSourceScrapePanelOpen = false;
    }
  }

  Future<SourceScrapeReport> _observeVideoSourceScrape(
    Future<SourceScrapeReport> task,
  ) {
    unawaited(task.then<void>((SourceScrapeReport _) {
      if (mounted) _notifyVideoLibraryChanged();
    }, onError: (Object error, StackTrace stackTrace) {
      ErrorLogService.instance.log(
        'HomePage.videoSourceScrape',
        error,
        stackTrace,
      );
    }));
    return task;
  }

  Future<void> _scrapeVideoSource(SourceLibraryRow source) async {
    final ({bool proceed, bool grant}) overwrite =
        await _confirmProtectedSidecarOverwrite(<SourceLibraryRow>[source]);
    if (!mounted || !overwrite.proceed) return;
    final VideoSourceScrapeTaskController controller =
        _videoSourceScrapeController;
    _observeVideoSourceScrape(
      controller.scrapeSource(
        source,
        interactive: true,
        allowProtectedOverwrite: overwrite.grant,
      ),
    );
    if (!mounted) return;
    FushiToast.show(msg: t.video_source_scrape_background_started);
    unawaited(_openVideoSourceScrapeTasks());
  }

  Future<void> _scrapeAllVideosFromSources() async {
    final List<SourceLibraryRow> sources =
        await appModel.database.getMediaSourcesByKind('video');
    final List<SourceLibraryRow> localSources = sources
        .where((SourceLibraryRow source) => source.transport == 'local')
        .toList(growable: false);
    if (!mounted) return;
    if (localSources.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.media_source_no_sources)),
      );
      return;
    }
    final ({bool proceed, bool grant}) overwrite =
        await _confirmProtectedSidecarOverwrite(localSources);
    if (!mounted || !overwrite.proceed) return;
    final VideoSourceScrapeTaskController controller =
        _videoSourceScrapeController;
    _observeVideoSourceScrape(
      controller.scrapeAllSources(
        localSources,
        interactive: true,
        allowProtectedOverwrite: overwrite.grant,
      ),
    );
    if (!mounted) return;
    FushiToast.show(msg: t.video_source_scrape_background_started);
    unawaited(_openVideoSourceScrapeTasks());
  }

  Future<({bool proceed, bool grant})> _confirmProtectedSidecarOverwrite(
    Iterable<SourceLibraryRow> sources,
  ) async {
    bool requested = false;
    for (final SourceLibraryRow source in sources) {
      final VideoSourceScrapeSettingRow? settings =
          await appModel.database.getVideoSourceScrapeSettings(source.id);
      if (settings?.allowExternalOverwrite == true &&
          (settings?.nfoPolicy == 'overwrite' ||
              settings?.imagePolicy == 'overwrite')) {
        requested = true;
        break;
      }
    }
    if (!requested) return (proceed: true, grant: false);
    if (!mounted) return (proceed: false, grant: false);
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog.adaptive(
        title: Text(
          t.video_source_scrape_external_overwrite_confirm_title,
        ),
        content: Text(
          t.video_source_scrape_external_overwrite_confirm_body,
        ),
        actions: <Widget>[
          adaptiveDialogAction(
            context: dialogContext,
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(t.dialog_cancel),
          ),
          adaptiveDialogAction(
            context: dialogContext,
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(t.dialog_replace),
          ),
        ],
      ),
    );
    return (proceed: confirmed == true, grant: confirmed == true);
  }

  /// Widget dispose 不能 await；先标记中断并让在途 Future 到下一取消边界，再关闭
  /// HTTP client/ChangeNotifier，避免已释放 notifier 或已关闭 client 被异步任务继续用。
  void _shutdownVideoSourceScrape() {
    final VideoSourceScrapeTaskController? controller =
        _videoSourceScrapeTaskController;
    final VideoSourceScrapeCoordinator? coordinator =
        _videoSourceScrapeCoordinator;
    _videoSourceScrapeTaskController = null;
    _videoSourceScrapeCoordinator = null;
    _videoSourceScrapeConfigFingerprint = null;
    if (controller == null) {
      coordinator?.close();
      return;
    }
    controller.removeListener(_onVideoSourceScrapeTaskChanged);
    controller.markInterrupted();
    final Future<SourceScrapeReport>? active = controller.activeTask;
    if (active == null) {
      controller.dispose();
      coordinator?.close();
      return;
    }
    unawaited(active
        .then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    )
        .whenComplete(() {
      controller.dispose();
      coordinator?.close();
    }));
  }

  Future<void> _onVideoSourceScanCompleted(
    SourceLibraryRow source,
    SourceScanSummary summary,
  ) async {
    _notifyVideoLibraryChanged();
    if (!summary.succeeded) return;
    final VideoSourceScrapeSettingRow? settings =
        await appModel.database.getVideoSourceScrapeSettings(source.id);
    if (!mounted ||
        settings?.enabled == false ||
        settings?.autoAfterScan != true ||
        _videoSourceScrapeController.isRunning) {
      return;
    }
    _observeVideoSourceScrape(
      _videoSourceScrapeController.scrapeSource(source),
    );
  }

  Widget buildBody() {
    final HomeTab visible = _visibleTab;
    if (_keepAliveTabs.contains(visible)) {
      _visitedKeepAliveTabs.add(visible);
    }
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // 保活 tab：一旦访问过就常驻树中，仅用 Offstage 隐藏未选中者（State 不销毁）。
        // 隐藏时同步关掉 TickerMode，令其 AnimationController 停走、不与可见 tab 抢帧。
        for (final HomeTab tab in _keepAliveTabs)
          if (_visitedKeepAliveTabs.contains(tab))
            Offstage(
              key: ValueKey<HomeTab>(tab),
              offstage: visible != tab,
              child: TickerMode(
                enabled: visible == tab,
                child: _buildTabContent(tab),
              ),
            ),
        // 非保活 tab：仅在选中时构建、切走即销毁，保留其 initState 挂载语义。
        if (!_keepAliveTabs.contains(visible))
          KeyedSubtree(
            key: ValueKey<HomeTab>(visible),
            child: _buildTabContent(visible),
          ),
        if (_videoSourceScrapeTaskController case final controller?)
          if (controller.isBusy)
            Positioned(
              right: 20,
              bottom: 20,
              child: SafeArea(
                child: FloatingActionButton.small(
                  key: const ValueKey<String>(
                    'video-source-background-task-panel',
                  ),
                  tooltip: t.video_source_scrape_tasks_open,
                  onPressed: () => unawaited(_openVideoSourceScrapeTasks()),
                  child: Icon(
                    controller.pendingConfirmation == null
                        ? Icons.sync
                        : Icons.rule_folder_outlined,
                  ),
                ),
              ),
            ),
      ],
    );
  }

  Widget _buildTabContent(HomeTab tab) {
    switch (tab) {
      case HomeTab.home:
        return HomeDashboardPage(videoRepo: _videoRepository);
      case HomeTab.video:
        return VideoLibraryShell(
          repository: _videoRepository,
          libraryRefreshSignal: _videoLibraryRefreshSignal,
          scrapeTaskController: _videoSourceScrapeController,
          onScrapeAll: _scrapeAllVideosFromSources,
          onScrapeSource: _scrapeVideoSource,
          onVideoScanCompleted: _onVideoSourceScanCompleted,
          onOpenScrapeTasks: () => unawaited(_openVideoSourceScrapeTasks()),
          onLibraryChanged: _notifyVideoLibraryChanged,
          discoveryController: _productionVideoDiscoveryController,
          discoveryActions: _productionVideoDiscoveryActions,
        );
      case HomeTab.downloads:
        return DownloadsPage(
          key: ValueKey<String>('downloads-$_downloadsGeneration'),
          initialTabIndex: _downloadsInitialTabIndex,
        );
      case HomeTab.dictionaries:
        return HomeDictionaryPage(
          focusSignal: _dictFocusSignal,
        );
      case HomeTab.games:
        return const HomeGamePage();
      case HomeTab.browserExtension:
        return const BrowserExtensionPage();
      case HomeTab.settings:
        // 设置 tab 走侧栏/底栏切回，不显示页头返回箭头；但仍需 PopScope 拦截系统
        // 返回键（否则冒泡到顶层 PopScope = 退出 app，见 BUG-236）。
        return _buildSettingsTabContent(showBackButton: false);
      case HomeTab.books:
        return const HomeReaderPage();
      case HomeTab.manga:
        return const MangaLibraryPage();
    }
  }

  /// 设置 tab 的内容外壳。[showBackButton] 为 true 时（宽屏隐藏 3 图标侧栏的全屏
  /// 设置）显示页头左上返回箭头；为 false 时（移动底栏 / 宽屏侧栏在侧，可直接切回）不
  /// 显示箭头，系统返回手势仍由 [HomeSettingsTabContent] 内的 PopScope 拦截。
  Widget _buildSettingsTabContent({required bool showBackButton}) {
    return HomeSettingsTabContent(
      showBackButton: showBackButton,
      onReturnToPreviousTab: () => _selectTab(_previousTab),
    );
  }
}

/// 设置 tab 的内容外壳：用 [PopScope] 拦截系统返回键（Android 硬件返回 / 手势返回），
/// 消费后切回来源 tab（[onReturnToPreviousTab]）而不是让事件冒泡到 home 顶层
/// [PopScope] 退出 app（BUG-236）。注意：同 route 多个 PopScope 的回调会被**全部
/// 遍历**、popDisposition 按 OR 聚合（任一 canPop:false 即不真正 pop），没有「内层先收
/// 到」的顺序保证；故顶层同步 PopScope 在设置 tab 上也会触发，需按当前 tab 自我收窄
/// （见 [shouldWarnOnExit]，TODO-698）。非设置 tab 不构造此 widget，仍走顶层 PopScope
/// 的正常退出/同步告警逻辑。
///
/// 设置内容默认是 [FushiSettingsContent]；[child] 仅供 widget 测试注入轻量占位以独立
/// 验证 PopScope 拦截行为（生产路径始终用默认值）。
class HomeSettingsTabContent extends StatelessWidget {
  const HomeSettingsTabContent({
    super.key,
    required this.onReturnToPreviousTab,
    this.showBackButton = false,
    this.child,
  });

  /// 系统返回键被拦截后调用：切回进入设置前的来源 tab。
  final VoidCallback onReturnToPreviousTab;

  /// 是否在设置页头左侧显示返回箭头（宽屏隐藏图标侧栏的全屏设置场景）。
  final bool showBackButton;

  /// 设置内容；为空时回落到默认的 [FushiSettingsContent]。
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        onReturnToPreviousTab();
      },
      child: child ??
          FushiSettingsContent(
            onBack: showBackButton ? onReturnToPreviousTab : null,
          ),
    );
  }
}

class _SyncExitWarningDialog extends StatelessWidget {
  const _SyncExitWarningDialog({
    required this.onCancel,
    required this.onExit,
  });

  final VoidCallback onCancel;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final TextTheme textTheme = Theme.of(context).textTheme;

    return FushiDialogFrame(
      maxWidth: 380,
      padding: EdgeInsets.all(tokens.spacing.card + 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            t.sync_exit_warning_title,
            style: textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: tokens.spacing.gap + 4),
          Text(
            t.sync_exit_warning,
            style: textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          SizedBox(height: tokens.spacing.card + tokens.spacing.gap),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              adaptiveDialogAction(
                context: context,
                onPressed: onCancel,
                child: Text(t.dialog_cancel),
              ),
              SizedBox(width: tokens.spacing.gap),
              adaptiveDialogAction(
                context: context,
                isDestructiveAction: true,
                onPressed: onExit,
                child: Text(t.dialog_exit),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
