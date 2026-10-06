import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi/src/ai/ai_media_acquisition_assistant.dart'
    show AiMediaAcquisitionDomain;
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/drag_drop/drop_surface_scope.dart';
import 'package:fushi/src/media/drag_drop/fushi_file_drop_target.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_add_flow.dart';
import 'package:fushi/src/pages/implementations/discovery_ai_acquire_action.dart';
import 'package:fushi/src/pages/implementations/galgame_home_page.dart';
import 'package:fushi/src/pages/implementations/game_diagnostics_page.dart';
import 'package:fushi/src/pages/implementations/game_shared.dart';
import 'package:fushi/src/pages/implementations/game_stream_library_page.dart';
import 'package:fushi/src/pages/implementations/games_library_page.dart';
import 'package:fushi/src/pages/implementations/media_discovery_page.dart';
import 'package:fushi/src/pages/implementations/module_settings_view.dart';
import 'package:fushi/src/pages/implementations/texthooker_page.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_scroll_chrome.dart'
    show fushiNotificationFromVisibleSubtree;
import 'package:fushi/utils.dart';

// GameSection / gameSectionNotifier 已迁到 game_shared.dart（三页共享），
// 这里 re-export 保持既有 import 站点（如原生浮窗控制器）零改动。
export 'package:fushi/src/pages/implementations/game_shared.dart'
    show GameSection, gameSectionNotifier;

typedef GameMonitorBuilder =
    Widget Function(BuildContext context, VoidCallback onShowLibrary);
typedef GameLibraryBuilder =
    Widget Function(
      BuildContext context,
      GalHookSessionController controller,
      VoidCallback onLaunched,
    );

/// 游戏首页（仪表盘）子页构造器；测试可注入桩，绕开 [GalgameHomePage] 对
/// `appProvider`（Drift DB / 仓储）的依赖。
typedef GameDashboardBuilder =
    Widget Function(BuildContext context, VoidCallback onShowLibrary);
typedef GameSettingsBuilder =
    Widget Function(BuildContext context, Widget navigation);

/// 「发现」子区构造器；测试可注入桩，绕开 [MediaDiscoveryPage] 对 `appProvider`
/// （发现服务 / 偏好）的依赖。
typedef GameDiscoverBuilder =
    Widget Function(BuildContext context, Widget navigation);

/// 「串流」子区构造器；测试可注入桩，绕开 [GameStreamLibraryPage] 对已配对
/// 主机与网络的依赖。
typedef GameStreamSectionBuilder =
    Widget Function(BuildContext context, Widget navigation);

/// 首页一级「游戏」模块。
///
/// 集成持久化游戏库、Hook 监控工作台与兼容性诊断。内部使用 [IndexedStack]，
/// 从工作台返回游戏库不会销毁
/// [TexthookerPage] 所持有的文本、音频和窗口捕获会话。
class HomeGamePage extends StatefulWidget {
  const HomeGamePage({
    super.key,
    this.monitorBuilder,
    this.libraryBuilder,
    this.dashboardBuilder,
    this.settingsBuilder,
    this.discoverBuilder,
    this.streamBuilder,
    this.controller,
  });

  final GameMonitorBuilder? monitorBuilder;
  final GameLibraryBuilder? libraryBuilder;
  final GameDashboardBuilder? dashboardBuilder;
  final GameSettingsBuilder? settingsBuilder;
  final GameDiscoverBuilder? discoverBuilder;
  final GameStreamSectionBuilder? streamBuilder;
  final GalHookSessionController? controller;

  static const Key dashboardKey = ValueKey<String>('game-dashboard');
  static const Key libraryKey = ValueKey<String>('game-library');
  static const Key monitorKey = ValueKey<String>('game-monitor');
  static const Key diagnosticsKey = ValueKey<String>('game-diagnostics');
  static const Key settingsKey = ValueKey<String>('game-settings');
  static const Key importKey = ValueKey<String>('game-import');
  static const Key discoverKey = ValueKey<String>('game-discover');
  static const Key streamKey = ValueKey<String>('game-stream');

  /// 库页顶部会话状态带（原两张总览大卡的收敛替身），整条可点进入捕获工作台。
  static const Key captureStatusKey = ValueKey<String>('game-capture-status');

  @override
  State<HomeGamePage> createState() => _HomeGamePageState();
}

class _HomeGamePageState extends State<HomeGamePage> {
  late GameSection _section = gameSectionNotifier.value;

  /// 「发现」子区访问过才构建：[IndexedStack] 会急切构建全部子区，而发现页一挂载
  /// 就向资源站发请求——不能因为打开游戏 tab 就联网。
  late bool _discoverVisited = _section == GameSection.discover;

  /// 「串流」子区同理：一挂载就去连已配对主机，访问过才构建。
  late bool _streamVisited = _section == GameSection.stream;
  late final GalHookSessionController _controller =
      widget.controller ?? GalHookSessionController.instance;

  @override
  void initState() {
    super.initState();
    gameSectionNotifier.addListener(_onSectionRequested);
  }

  /// 浮动工具栏的显隐（滚动驱动，与视频 / 书 / 漫画库同构）。
  final FushiFloatingChromeController _chrome = FushiFloatingChromeController();

  /// 子区页头登记动作的槽：由浮动工具栏右侧的动作组画出。
  final FushiShellActionsSlot _actionsSlot = FushiShellActionsSlot();

  bool _onScroll(ScrollNotification notification) {
    if (!fushiNotificationFromVisibleSubtree(notification)) return false;
    return _chrome.handleScrollNotification(notification);
  }

  @override
  void dispose() {
    _chrome.dispose();
    _actionsSlot.dispose();
    gameSectionNotifier.removeListener(_onSectionRequested);
    // HomeGamePage 生命周期结束后不要把一次外部导航请求泄漏给下一次挂载（也避免
    // profile/窗口重建后意外停在旧工作台）。回落到默认首屏（游戏首页）。运行中的
    // 页面仍由 notifier 正常保态。
    gameSectionNotifier.value = GameSection.dashboard;
    super.dispose();
  }

  void _onSectionRequested() {
    final GameSection requested = gameSectionNotifier.value;
    if (requested == _section || !mounted) return;
    // 换了子区，新页面从顶部开始：工具栏回来。
    _chrome.resetToTop();
    setState(() {
      _section = requested;
      if (requested == GameSection.discover) _discoverVisited = true;
      if (requested == GameSection.stream) _streamVisited = true;
    });
  }

  void _showSection(GameSection section) {
    // 门必须在这里、不能逐调用点补：新的两个调用点（drop 落库后、文件选择器返回
    // 后）都在 await 之后，用户完全可以在文件对话框开着时切走 tab / 关窗口。
    // 那时 [dispose] 已经把 notifier 复位成 dashboard，这里再写一次就是把一次
    // 过期的导航请求泄漏给下一次挂载——正是 [dispose] 那段注释要防的事。
    if (!mounted) return;
    if (gameSectionNotifier.value != section) {
      gameSectionNotifier.value = section;
      return;
    }
    _onSectionRequested();
  }

  void _showDashboard() => _showSection(GameSection.dashboard);
  void _showLibrary() => _showSection(GameSection.library);
  void _showMonitor() => _showSection(GameSection.monitor);
  void _showDiagnostics() => _showSection(GameSection.diagnostics);
  void _showSettings() => _showSection(GameSection.settings);

  /// 「导入」视图的进行中标记：选文件 / 拖放落库期间拖放区底部亮波浪进度。
  bool _importBusy = false;

  /// 桌面正拖着文件悬停在导入视图上（[FushiFileDropTarget.onHoverChanged]）：
  /// 拖拽期间指针 hover 事件不到达，拖放区卡片的放大变色改由这一位驱动。
  bool _importDragHovering = false;

  void _setImportDragHovering(bool value) {
    if (!mounted || _importDragHovering == value) return;
    setState(() => _importDragHovering = value);
  }

  /// 包住一次导入：期间点亮进度，结束（成功 / 取消 / 抛错）后熄灭。异常照常
  /// 抛回调用方——拖放路径的唯一错误咽喉在 `FushiFileDropTarget.runDrop`，这里
  /// 不能吞。
  Future<void> _trackImport(Future<void> Function() run) async {
    if (mounted) setState(() => _importBusy = true);
    try {
      await run();
    } finally {
      if (mounted) setState(() => _importBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final GameMonitorBuilder monitorBuilder =
        widget.monitorBuilder ??
        (BuildContext context, VoidCallback onShowLibrary) => TexthookerPage(
          embedded: true,
          captureSetupEnabled: _section == GameSection.monitor,
          onShowLibrary: onShowLibrary,
          onShowDiagnostics: _showDiagnostics,
        );
    final GameDashboardBuilder dashboardBuilder =
        widget.dashboardBuilder ??
        (BuildContext context, VoidCallback onShowLibrary) => GalgameHomePage(
          sessionController: _controller,
          onShowLibrary: onShowLibrary,
          onShowMonitor: _showMonitor,
          onShowDiagnostics: _showDiagnostics,
          onLaunched: _showMonitor,
        );
    // 子区内容按 [GameSection] 建表，再按 `GameSection.values` 顺序展开：既把
    // 「IndexedStack 索引 == 枚举序」这条隐式约定变成结构约束（`index:` 用的就是
    // `_section.index`），也保证**每个**子区必然经过下面同一处拖放作用域包裹，
    // 以后新增子区不可能漏掉。
    final Map<GameSection, Widget> sections = <GameSection, Widget>{
      GameSection.dashboard: KeyedSubtree(
        key: HomeGamePage.dashboardKey,
        child: dashboardBuilder(context, _showLibrary),
      ),
      GameSection.library: KeyedSubtree(
        key: HomeGamePage.libraryKey,
        child: _buildLibrary(context),
      ),
      GameSection.monitor: KeyedSubtree(
        key: HomeGamePage.monitorKey,
        child: monitorBuilder(context, _showLibrary),
      ),
      GameSection.diagnostics: KeyedSubtree(
        key: HomeGamePage.diagnosticsKey,
        child: GameDiagnosticsPage(
          controller: _controller,
          onShowLibrary: _showLibrary,
          onShowCapture: _showMonitor,
        ),
      ),
      GameSection.settings: KeyedSubtree(
        key: HomeGamePage.settingsKey,
        child: Builder(
          builder: (BuildContext context) {
            final Widget navigation = GameSectionTabs(
              selected: GameSection.settings,
              focusIdPrefix: 'game-settings-tab',
              onSelectDashboard: _showDashboard,
              onSelectLibrary: _showLibrary,
              onSelectMonitor: _showMonitor,
              onSelectSettings: _showSettings,
            );
            return widget.settingsBuilder?.call(context, navigation) ??
                ModuleSettingsView(
                  destinationId: SettingsDestinationId.game,
                  // 页签由外壳浮动工具栏画：页头主位给零尺寸占位，整行零高度，
                  // 设置正文从工具区下方开始（不再隔一条空白带）。
                  navigation: const SizedBox.shrink(),
                );
          },
        ),
      ),
      GameSection.importGames: KeyedSubtree(
        key: HomeGamePage.importKey,
        child: _buildImport(context),
      ),
      GameSection.discover: KeyedSubtree(
        key: HomeGamePage.discoverKey,
        child: _discoverVisited ? _buildDiscover() : const SizedBox.shrink(),
      ),
      GameSection.stream: KeyedSubtree(
        key: HomeGamePage.streamKey,
        child: _streamVisited ? _buildStream() : const SizedBox.shrink(),
      ),
    };
    // 顶部与视频 / 书 / 漫画库同一套 M3E 浮动工具栏（2026-10-06「库页顶部结构
    // 统一」）：外壳大标题下一行是贴合内容宽的分区页签胶囊 + 右侧动作组；各子区
    // 页头里的那份页签在 [GameSectionTabsHostScope] 下留空，动作登记进外壳的
    // [_actionsSlot] 由动作组画出。
    final Widget navigation = GameSectionTabs(
      selected: _section,
      // 焦点 id 沿用各子区原来那份页签的稳定 id（`game-library-tab-sections`
      // 等）：键盘 / 手柄 / 集成测试按它定位，换成外壳统一画也不能变。
      focusIdPrefix: switch (_section) {
        GameSection.dashboard => 'game-dashboard-tab',
        GameSection.library => 'game-library-tab',
        GameSection.monitor => 'game-capture-tab',
        GameSection.discover => 'game-discover-tab',
        GameSection.importGames => 'game-import-tab',
        GameSection.settings => 'game-settings-tab',
        GameSection.diagnostics => 'game-diagnostics-tab',
        GameSection.stream => 'game-stream-tab',
      },
      floating: true,
      onSelectDashboard: _showDashboard,
      onSelectLibrary: _showLibrary,
      onSelectMonitor: _showMonitor,
      onSelectSettings: _showSettings,
    );
    final Widget body = LibrarySectionFollowScope(
      current: gameSectionNotifier,
      // 触屏横滑按页签**视觉序**（[kGameSectionTabOrder]）切相邻子区；诊断不在
      // 页签序里，停在诊断时横滑不响应（导航层级只对页签序负责）。
      child: SectionSwipeNavigator<GameSection>(
        sections: kGameSectionTabOrder,
        selected: _section,
        onSelect: _showSection,
        child: IndexedStack(
          index: _section.index,
          children: <Widget>[
            for (final GameSection section in GameSection.values)
              // [IndexedStack] 比 [Offstage] 更狠：它**急切构建全部子区**并以完整约束
              // 布局，而 desktop_drop 是进程级全局广播、只按各 drop target 的
              // `RenderBox.paintBounds` 过滤 —— 于是六个子区的 drop target 会全部命中
              // 同一次 OS drop。外层 home-shell 的作用域只回答「游戏 tab 可见吗」，
              // 用户停在诊断/设置子区时答案照样是 true。判据与 `index:` 用的是同一个
              // `_section`，且写成回调、在 drop 落地那一刻求值。
              // 每个子区自己的主滚动控制器：六个子区同时挂在 IndexedStack 里，
              // 共用 tab 外壳那一个会让多个主滚动视图附着同一控制器、Scrollbar 断言。
              DropSurfaceScope(
                isActive: () => _section == section,
                // 子区让出浮动工具栏的高度（工具栏叠在内容上，见下方
                // [FushiFloatingChromeOverlay]），见 [_chromeInsetFor]。
                child: SectionPrimaryScrollScope(
                  child: _chromeInsetFor(section, child: sections[section]!),
                ),
              ),
          ],
        ),
      ),
    );
    return Material(
      type: MaterialType.transparency,
      child: FushiShellTitleScope(
        title: FushiShellTitleScope.maybeTitleOf(context) ?? '',
        actionsSlot: _actionsSlot,
        child: FushiFloatingChromeScope(
          controller: _chrome,
          // 工具栏叠在内容上，收起只滑出画面、不改内容视口高度（BUG-2975）。
          child: FushiFloatingChromeOverlay(
            chrome: FushiFloatingChromeBar(
              tabs: navigation,
              slot: _actionsSlot,
            ),
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScroll,
              child: GameSectionTabsHostScope(child: body),
            ),
          ),
        ),
      ),
    );
  }

  /// 子区怎么让出叠放的浮动工具区（2026-10-06 结构收口）：
  ///
  /// - 首页 / 导入 / 设置：主滚动视图自己吃掉让位——[FushiFloatingChromeScrollInset]
  ///   把它交成 MediaQuery 顶部 padding，内容从工具区下方开始、往下滚时滚到
  ///   工具区底下，工具区收起后顶部不留空白（旧的整体下移让出的那段永远是空的
  ///   页面底色，往下一滚顶部就是一整块白，用户 2026-10-06 截图）。
  /// - 库 / 诊断 / 发现：页面把自己的工具行（搜索筛选 / 分组跳转条）叠进浮动
  ///   工具区（嵌套 [FushiFloatingChromeOverlay]），要读外层的让位，不能在这里
  ///   归零。
  /// - 捕获工作台：定高工作台版面（会话卡 + 自带滚动的台词面板），没有整页滚动
  ///   视图可以吃让位：[FushiFloatingChromeVisiblePadding] 按工具区此刻的可见
  ///   下沿让位，随收起动画缩到 0。
  Widget _chromeInsetFor(GameSection section, {required Widget child}) =>
      switch (section) {
        GameSection.dashboard ||
        GameSection.importGames ||
        GameSection.settings => FushiFloatingChromeScrollInset(child: child),
        GameSection.library ||
        GameSection.diagnostics ||
        GameSection.discover => child,
        // 捕获工作台没有整页滚动，串流列表也不消费 MediaQuery 顶部 padding；
        // 两者按工具区此刻的可见下沿让位，收起后不留空白。
        GameSection.monitor ||
        GameSection.stream => FushiFloatingChromeVisiblePadding(child: child),
      };

  /// 「串流」视图复用串流游戏库页，页签和动作统一由外壳浮动工具栏绘制。
  Widget _buildStream() {
    // 显式零尺寸主位让 FushiPageHeader 连同空行内边距一起收起。
    const Widget navigation = SizedBox.shrink();
    final GameStreamSectionBuilder? builder = widget.streamBuilder;
    if (builder != null) {
      return Builder(
        builder: (BuildContext context) => builder(context, navigation),
      );
    }
    return Consumer(
      builder: (BuildContext context, WidgetRef ref, Widget? _) =>
          GameStreamLibraryPage(
            services: GameStreamLibraryServices.interconnect(
              appModel: ref.read(appProvider),
            ),
            navigation: navigation,
          ),
    );
  }

  /// 游戏「发现」视图：与「浏览 › 发现 › 游戏」同一个生产发现页，页头主位放本模块
  /// 的分段页签。
  Widget _buildDiscover() {
    final Widget navigation = GameSectionTabs(
      selected: GameSection.discover,
      focusIdPrefix: 'game-discover-tab',
      onSelectDashboard: _showDashboard,
      onSelectLibrary: _showLibrary,
      onSelectMonitor: _showMonitor,
      onSelectSettings: _showSettings,
    );
    final GameDiscoverBuilder? builder = widget.discoverBuilder;
    if (builder != null) {
      return Builder(
        builder: (BuildContext context) => builder(context, navigation),
      );
    }
    return Consumer(
      builder: (BuildContext context, WidgetRef ref, Widget? _) =>
          MediaDiscoveryPage(
            kinds: const <DiscoveryMediaKind>[DiscoveryMediaKind.game],
            navigation: navigation,
            onAiAcquire: discoveryAiAcquireAction(
              context: context,
              readAppModel: () => ref.read(appProvider),
              domain: AiMediaAcquisitionDomain.game,
              domainLabel: t.nav_game,
            ),
          ),
    );
  }

  /// 游戏「导入」视图：与书 / 漫画 / 视频库页的「导入」视图同构同位（快速导入
  /// 区收纳单件入口；游戏暂无扫描根概念，故本页只有快速导入一区）。
  Widget _buildImport(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 导入页自己接 drop：此前整个游戏域只有**库**页挂了 drop target，而
    // `DropSurfaceScope` 又按当前 section 过滤，于是站在「导入」页拖 exe 进来
    // 完全没反应——页面上还写着「也可以把 .exe 拖进来」。
    return FushiFileDropTarget(
      debugLabel: 'game-import',
      onHoverChanged: _setImportDragHovering,
      // 必须把这个 future 交回去：`FushiFileDropTarget.runDrop` 特意 await 回调，
      // 那是拖放路径上**唯一**的错误咽喉（否则 repo.load()/addAll() 抛出时异常
      // 直接漂进 zone，用户看到的只有「拖了没反应」——正是本页要修的症状）。
      // 包成 unawaited 等于把回调立刻变成 void，await 什么也接不到。
      // `_trackImport` 只在前后点亮 / 熄灭进度，future 与异常原样交回。
      onDrop: (List<String> paths, Offset position) => _trackImport(
        () => addGamesFromPaths(
          ProviderScope.containerOf(
            context,
            listen: false,
          ).read(appProvider).galgameRepo,
          paths,
          onImported: _showLibrary,
        ),
      ),
      child: DesktopContentLayout(
        kind: DesktopContentKind.readerShelf,
        child: Column(
          children: <Widget>[
            // 分区页签由外壳浮动工具栏画：主位给零尺寸占位，页头整行零高度。
            FushiPageHeader.customTitle(
              title: const SizedBox.shrink(),
              actions: const <Widget>[],
            ),
            Expanded(
              // M3E 导入视图：区标题 + 一张大圆角虚线拖放区（主按钮「添加游戏」+
              // 拖放提示 + 导入中波浪进度），错峰进场。
              // IndexedStack 急切构建：切到导入子区时重开进场窗口。
              child: FushiEntranceScope(
                replayKey: _section == GameSection.importGames,
                // 浮动工具区的让位（[FushiFloatingChromeScrollInset] 交来的
                // MediaQuery 顶部 padding）加进滚动内边距：内容滚到工具区底下。
                // 必须在 Builder 里读——本方法拿的是 State 的 context，在让位
                // 那层之上。
                child: Builder(
                  builder: (BuildContext context) => SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                      tokens.spacing.page,
                      8 + MediaQuery.paddingOf(context).top,
                      tokens.spacing.page,
                      24,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        FushiStaggeredEntrance(
                          index: 0,
                          child: Text(
                            t.quick_import_title,
                            style: context.fushiType.titleLargeEmphasized,
                          ),
                        ),
                        SizedBox(height: tokens.spacing.gap),
                        FushiStaggeredEntrance(
                          index: 1,
                          child: _GameImportDropZone(
                            busy: _importBusy,
                            dragHovering: _importDragHovering,
                            // IndexedStack 急切构建全部子区，本视图在无
                            // ProviderScope 的 widget 测试里也会被 build——
                            // 容器只在点按时解析，构建期零 provider 依赖。
                            // 导入成功后跳到游戏库：新游戏落在**另一个** section
                            // 里，停在导入页的话屏幕上什么都不变，成功与失败在
                            // 观感上一模一样（用户「导成功没反应我还以为失败了
                            // 重试了好几次」）。
                            onAdd: () => _trackImport(
                              () => addGameViaFilePicker(
                                ProviderScope.containerOf(
                                  context,
                                  listen: false,
                                ).read(appProvider).galgameRepo,
                                onImported: _showLibrary,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLibrary(BuildContext context) {
    // 顶部一条紧凑会话状态带（原两张总览大卡的收敛替身）：只留库页独有
    // 的会话摘要，整条可点进入捕获工作台。诊断细节（序号缺口 / 端点连通）
    // 归诊断页，不再挤占库页面积。
    final Widget statusStrip = AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        final GalHookSessionState state = _controller.state;
        final lines = _controller.lines;
        final GalWorkbenchReadiness readiness = galWorkbenchReadiness(
          state: state,
          hasEngineSource: _controller.hasEngineSource,
          selectedTextThreadKey: _controller.selectedTextThreadKey,
        );
        final double page = FushiDesignTokens.of(context).spacing.page;
        // 左右取页边，与浮动页签胶囊 / 工具行 / 内容同一条左右缘。
        return Padding(
          padding: EdgeInsets.fromLTRB(page, 8, page, 0),
          child: _CaptureStatusStrip(
            lineCount: lines.length,
            latestLine: lines.isEmpty ? null : lines.last.text,
            state: state,
            readiness: readiness,
            onOpen: _showMonitor,
          ),
        );
      },
    );
    final GameLibraryBuilder? libraryBuilder = widget.libraryBuilder;
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          FushiPageHeader.customTitle(
            // 统计入口已收敛到首页 dashboard（用户定案 2026-09-01）。
            // 分区页签由外壳浮动工具栏画（[GameSectionTabsHostScope]）：主位给
            // 零尺寸占位，页头整行零高度（动作登记进外壳动作组），不在工具区
            // 下面留一条钉死的空白带。
            title: const SizedBox.shrink(),
            // 顶部不再放「捕获工作台」图标钮——它与下方 GameSectionTabs 的
            // 「工作台」分段去向完全相同，纯冗余；入口收敛到分段导航 + 状态带。
            // 网格 / 列表切换（与视频库「全部视频」同位：页头动作）。只在真库页
            // 时出现——注入 libraryBuilder 的测试宿主没有 ProviderScope。
            actions: <Widget>[
              if (widget.libraryBuilder == null)
                const GamesLibraryLayoutToggle(),
            ],
          ),
          Expanded(
            // 生产路径：库页自己把搜索 / 筛选行叠进浮动工具区、主滚动视图消费
            // 让位（本子区在 [build] 里不再整体下移）；状态带作为滚动内容的
            // 第一块，随内容滚到工具区底下。
            child: libraryBuilder == null
                ? GamesLibraryPage(
                    embedded: true,
                    sessionController: _controller,
                    onLaunched: _showMonitor,
                    header: statusStrip,
                  )
                // 测试替身页不认识浮动工具区：状态带 + 替身整体下移让位。
                : FushiFloatingChromeInsetPadding(
                    child: Column(
                      children: <Widget>[
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: statusStrip,
                        ),
                        const FushiDividerControl(height: 1),
                        Expanded(
                          child: libraryBuilder(
                            context,
                            _controller,
                            _showMonitor,
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// 游戏「导入」视图的拖放区卡片（M3E）：28 圆角虚线描边 + 饱和容器色块，中间是
/// 花瓣形状图标、主按钮「添加游戏」与拖放提示，导入进行中底部亮波浪进度。
///
/// 拖放命中由外层 [FushiFileDropTarget] 处理；它经 `onHoverChanged` 报出的
/// 「正拖着文件悬停」由 [dragHovering] 传进来，与指针悬停同款反馈：spring 轻放大
/// + 描边 / 底色转强调色（拖拽期间 MouseRegion 收不到 hover，只能靠这一位）。
class _GameImportDropZone extends StatelessWidget {
  const _GameImportDropZone({
    required this.busy,
    required this.onAdd,
    this.dragHovering = false,
  });

  final bool busy;
  final Future<void> Function() onAdd;
  final bool dragHovering;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final FushiMotionScheme motion = context.fushiMotion;
    final bool eink = isEinkTheme(context);
    final bool apple = isGlassDesign(context);
    final double radius = apple
        ? FushiM3eShape.small
        : FushiM3eShape.containerLarge;
    return FushiHoverLift(
      scale: 1.01,
      forceLifted: dragHovering,
      builder: (BuildContext context, bool hovering) {
        final Color fill = eink
            ? colors.surface
            : hovering
            ? colors.primaryContainer
            : colors.surfaceContainerLow;
        final Color border = eink
            ? colors.outline
            : hovering
            ? colors.primary
            : colors.outlineVariant;
        return AnimatedContainer(
          duration: motion.effectsDefault.duration,
          curve: motion.effectsDefault.curve,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(radius),
          ),
          child: CustomPaint(
            foregroundPainter: _DashedRRectPainter(
              color: border,
              radius: radius,
              // 墨水屏实线：虚线在低刷新灰阶上读成噪点。
              dashed: !eink,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  AnimatedScale(
                    scale: hovering ? 1.08 : 1,
                    duration: motion.spatialFast.duration,
                    curve: motion.spatialFast.curve,
                    child: const FushiListLeadingIcon(
                      FushiIcons.games,
                      shape: FushiLeadingShape.flower,
                      tone: FushiCardTone.primary,
                      size: 72,
                      iconSize: 36,
                    ),
                  ),
                  const SizedBox(height: 20),
                  FushiFilledButton.icon(
                    onPressed: busy ? null : () => onAdd(),
                    size: FushiButtonSize.m,
                    icon: const FushiIcon(FushiIcons.add),
                    label: Text(t.game_add),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    t.game_import_drop_hint,
                    textAlign: TextAlign.center,
                    style: context.fushiType.bodyMedium.copyWith(
                      color: hovering && !eink
                          ? colors.onPrimaryContainer
                          : colors.onSurfaceVariant,
                    ),
                  ),
                  AnimatedSize(
                    duration: motion.spatialDefault.duration,
                    curve: motion.spatialDefault.curve,
                    alignment: Alignment.topCenter,
                    child: busy
                        ? const Padding(
                            padding: EdgeInsets.only(top: 20),
                            child: FushiLinearProgressIndicator(),
                          )
                        : const SizedBox(width: double.infinity),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 拖放区的圆角矩形描边：[dashed] 时画虚线（拖放区的通用视觉语言），否则实线。
class _DashedRRectPainter extends CustomPainter {
  const _DashedRRectPainter({
    required this.color,
    required this.radius,
    required this.dashed,
  });

  final Color color;
  final double radius;
  final bool dashed;

  static const double _strokeWidth = 2;
  static const double _dash = 8;
  static const double _gap = 6;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth;
    final RRect rrect = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(_strokeWidth / 2),
      Radius.circular(radius),
    );
    if (!dashed) {
      canvas.drawRRect(rrect, paint);
      return;
    }
    final Path outline = Path()..addRRect(rrect);
    for (final ui.PathMetric metric in outline.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        final double end = (distance + _dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance += _dash + _gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRRectPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.radius != radius ||
      oldDelegate.dashed != dashed;
}

/// 库页顶部的紧凑会话状态带：把此前两张总览大卡（捕获总览 + 诊断总览）收敛成
/// 一条 M3E 卡片，横向排列库页独有的会话摘要。整条可点进入捕获工作台（保留快捷
/// 入口但不再放显式大按钮 / 冗余图标钮）；序号缺口、端点连通数这类诊断细节留给
/// 诊断页，库页不再展示。
///
/// M3E：活动态整条换成 primary 饱和色块（[FushiCardTone.primary]），行首是会
/// 弹簧换形的形状图标（空闲圆 → 捕获中四瓣 cookie），右侧台词数用等宽大数字、
/// 会话阶段用 chip；按压回弹由 [FushiCard] 自带。
class _CaptureStatusStrip extends StatelessWidget {
  const _CaptureStatusStrip({
    required this.lineCount,
    required this.latestLine,
    required this.state,
    required this.readiness,
    required this.onOpen,
  });

  final int lineCount;
  final String? latestLine;
  final GalHookSessionState state;
  final GalWorkbenchReadiness readiness;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final FushiMotionScheme motion = context.fushiMotion;
    // 有台词、或会话阶段非 idle/error，都算「在捕获」——阶段已 running 但尚未
    // 产出台词时仍显示活动态，而不是回落到「尚未开始」。
    final bool active =
        readiness != GalWorkbenchReadiness.idle || lineCount > 0;
    // eink：饱和色块既是抖动灰、又塌成页面底色，激活态看不出来；改走
    // FushiCard 的 selected（eink 下 2px 描边），图标 + 文案已带语义。
    final bool eink = isEinkTheme(context);
    final bool toned = active && !eink;
    // 色块卡里的文字跟随卡片配对前景 onContainer（字阶样式自带页面前景色，
    // 不显式覆盖会盖掉卡片注入的默认前景，HBK-AUDIT-022），中性卡回落
    // onSurfaceVariant。
    final Color? onCard = toned
        ? fushiCardToneColors(context, FushiCardTone.primary)?.onContainer
        : null;
    final Color? secondary = toned ? onCard : colors.onSurfaceVariant;

    final Widget detail = active
        ? readiness == GalWorkbenchReadiness.waitingForThread
              ? _buildWaitingForThreadDetail(context, secondary, onCard)
              : _buildActiveDetail(context, secondary, onCard)
        : Text(
            '${t.game_session_idle}  ·  ${t.game_open_capture_workspace}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.fushiType.bodyMedium.copyWith(color: secondary),
          );

    return FushiCard(
      key: HomeGamePage.captureStatusKey,
      focusId: const FushiFocusId('game-capture-status'),
      padding: const EdgeInsets.fromLTRB(12, 12, 16, 12),
      tone: toned ? FushiCardTone.primary : FushiCardTone.neutral,
      selected: active && eink,
      onTap: onOpen,
      child: Row(
        children: <Widget>[
          AnimatedSwitcher(
            duration: motion.spatialFast.duration,
            switchInCurve: motion.spatialFast.curve,
            switchOutCurve: motion.effectsFast.curve,
            transitionBuilder: (Widget child, Animation<double> animation) =>
                ScaleTransition(scale: animation, child: child),
            child: FushiListLeadingIcon(
              active ? FushiIcons.filled(FushiIcons.audio) : FushiIcons.game,
              key: ValueKey<bool>(active),
              shape: active
                  ? FushiLeadingShape.cookie
                  : FushiLeadingShape.circle,
              // 活动态在 primary 色块上：行首取 tertiary 拉开对比。
              tone: active ? FushiCardTone.tertiary : FushiCardTone.secondary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: detail),
          if (active) ...<Widget>[
            const SizedBox(width: 12),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Text(
                  '$lineCount',
                  style: context.fushiType.titleLargeEmphasized.tabular
                      .copyWith(color: onCard),
                ),
                Text(
                  t.game_captured_lines,
                  maxLines: 1,
                  style: context.fushiType.labelSmall.copyWith(
                    color: secondary,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(width: 8),
          FushiIcon(FushiIcons.chevronRight, color: secondary, size: 20),
        ],
      ),
    );
  }

  Widget _buildWaitingForThreadDetail(
    BuildContext context,
    Color? secondary,
    Color? onCard,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Flexible(
              child: Text(
                t.game_session_waiting_thread,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.fushiType.labelLargeEmphasized.copyWith(
                  color: onCard,
                ),
              ),
            ),
            const SizedBox(width: 8),
            _SessionPhaseChip(label: galHookSessionPhaseLabel(state.phase)),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          t.game_text_thread_unset,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.fushiType.bodySmall.copyWith(color: secondary),
        ),
      ],
    );
  }

  /// 活动态：横向排关键状态（正在捕获 · 音频来源）+ Hook 阶段 chip，下方一行
  /// 截断的最新台词；台词数在卡片右侧单独用大数字展示。
  Widget _buildActiveDetail(
    BuildContext context,
    Color? secondary,
    Color? onCard,
  ) {
    final String meta = <String>[
      t.game_capture_active,
      galHookAudioBackendLabel(state.audioBackend),
    ].join('  ·  ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Flexible(
              child: Text(
                meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.fushiType.labelLargeEmphasized.copyWith(
                  color: onCard,
                ),
              ),
            ),
            const SizedBox(width: 8),
            _SessionPhaseChip(label: galHookSessionPhaseLabel(state.phase)),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          latestLine ?? t.game_waiting_for_text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.fushiType.bodySmall.copyWith(color: secondary),
        ),
      ],
    );
  }
}

/// 状态带里的 Hook 会话阶段 chip：primary 实色胶囊（在 primaryContainer 色块上
/// 读作强调），墨水屏退成描边胶囊。
class _SessionPhaseChip extends StatelessWidget {
  const _SessionPhaseChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: eink ? colors.surface : colors.primary,
        shape: StadiumBorder(
          side: eink ? BorderSide(color: colors.outline) : BorderSide.none,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.fushiType.labelSmallEmphasized.copyWith(
            color: eink ? colors.onSurface : colors.onPrimary,
          ),
        ),
      ),
    );
  }
}
