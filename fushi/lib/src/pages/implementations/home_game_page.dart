import 'dart:async' show unawaited;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/home_tab.dart' show HomeTab;
import 'package:fushi/src/models/module_registry.dart' show isHomeTabVisible;
import 'package:fushi/src/pages/implementations/browse_page.dart'
    show BrowseNavigationRequest, BrowseTab, externalBrowseRequest;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_core/fushi_core.dart' show SourceLibraryKind;
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi/src/ai/ai_media_acquisition_assistant.dart'
    show AiMediaAcquisitionDomain;
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/drag_drop/drop_surface_scope.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_add_flow.dart';
import 'package:fushi/src/mining/galgame_repository.dart'
    show GalgameRepository;
import 'package:fushi/src/media/import/import_page_layout.dart';
import 'package:fushi/src/media/import/import_surface_spec.dart';
import 'package:fushi/src/pages/implementations/discovery_ai_acquire_action.dart';
import 'package:fushi/src/pages/implementations/discovery_manage_sources_action.dart';
import 'package:fushi/src/pages/implementations/galgame_home_page.dart';
import 'package:fushi/src/pages/implementations/game_diagnostics_page.dart';
import 'package:fushi/src/pages/implementations/game_shared.dart';
import 'package:fushi/src/pages/implementations/game_stream_library_page.dart';
import 'package:fushi/src/pages/implementations/games_library_page.dart';
import 'package:fushi/src/pages/implementations/library_layout/library_chrome_spec.dart';
import 'package:fushi/src/pages/implementations/library_layout/library_layout.dart';
import 'package:fushi/src/pages/implementations/media_discovery_page.dart';
import 'package:fushi/src/pages/implementations/media_sources_view.dart';
import 'package:fushi/src/pages/implementations/media_library_shell.dart'
    show LibrarySectionGroup;
import 'package:fushi/src/pages/implementations/texthooker_page.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/pages/shared/fushi_header_search_keys.dart';
import 'package:fushi/src/utils/components/fushi_header_search.dart'
    show fushiVisibleHeaderSearch;
import 'package:fushi/src/utils/components/glass/fushi_apple_scroll_chrome.dart'
    show fushiNotificationDrivesPageChrome;
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/pages/shared/library_section_tabs.dart';
import 'package:fushi/src/utils/components/section_swipe_navigator.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

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

/// 「发现」子区构造器；测试可注入桩，绕开 [MediaDiscoveryPage] 对 `appProvider`
/// （发现服务 / 偏好）的依赖。
typedef GameDiscoverBuilder =
    Widget Function(BuildContext context, Widget navigation);

/// 「串流」子区构造器；测试可注入桩，绕开 [GameStreamLibraryPage] 对已配对
/// 主机与网络的依赖。
typedef GameStreamSectionBuilder =
    Widget Function(BuildContext context, Widget navigation);

/// 「导入」子区里常驻来源列表的构造器；测试可注入桩，绕开 [MediaSourcesView] 对
/// `appProvider`（Drift DB / 偏好）的依赖。[viewKey] 必须挂在真正的
/// [MediaSourcesView] 上：区头「添加来源」按钮经它调 [MediaSourcesViewState.addSource]。
typedef GameSourcesBuilder =
    Widget Function(
      BuildContext context,
      GlobalKey<MediaSourcesViewState> viewKey,
    );

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
    this.discoverBuilder,
    this.streamBuilder,
    this.sourcesBuilder,
    this.controller,
  });

  final GameMonitorBuilder? monitorBuilder;
  final GameLibraryBuilder? libraryBuilder;
  final GameDashboardBuilder? dashboardBuilder;
  final GameDiscoverBuilder? discoverBuilder;
  final GameStreamSectionBuilder? streamBuilder;
  final GameSourcesBuilder? sourcesBuilder;
  final GalHookSessionController? controller;

  static const Key dashboardKey = ValueKey<String>('game-dashboard');
  static const Key libraryKey = ValueKey<String>('game-library');
  static const Key monitorKey = ValueKey<String>('game-monitor');
  static const Key diagnosticsKey = ValueKey<String>('game-diagnostics');
  static const Key importKey = ValueKey<String>('game-import');
  static const Key discoverKey = ValueKey<String>('game-discover');
  static const Key streamKey = ValueKey<String>('game-stream');

  /// 「导入」子区「常驻来源」区头的「添加来源」按钮（反馈 9Rm_8JEkGM）。
  static const Key addSourceKey = ValueKey<String>('import-sources-add');

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

  /// 「导入」子区的常驻来源列表同理：一挂载就查来源表与各来源计数，访问过才构建。
  late bool _importVisited = _section == GameSection.importGames;

  /// 常驻来源列表的状态句柄：区头「添加来源」按钮经它调 `addSource`。
  final GlobalKey<MediaSourcesViewState> _sourcesKey =
      GlobalKey<MediaSourcesViewState>();

  /// 「我的游戏」组上次停留的子区：在发现 / 导入时点组页签回到这里。
  late GameSection _lastLibrarySection =
      gameSectionGroupOf(_section) == LibrarySectionGroup.library
      ? _section
      : GameSection.dashboard;

  /// 进导入页之前停留的子区：再点一次导入钮回到这里。
  GameSection _beforeImport = GameSection.library;
  late final GalHookSessionController _controller =
      widget.controller ?? GalHookSessionController.instance;

  @override
  void initState() {
    super.initState();
    gameSectionNotifier.addListener(_onSectionRequested);
    _controller.gameExitedCount.addListener(_onGameExited);
  }

  /// 游戏关掉、会话随之自动结束（BUG-4002）：还停在捕获工作台上就回游戏首页。
  /// 用户此刻在别的子区（库、发现……）时不打扰。
  void _onGameExited() {
    if (_section != GameSection.monitor) return;
    _showDashboard();
  }

  /// 浮动工具栏的显隐（滚动驱动，与视频 / 书 / 漫画库同构）。
  final FushiFloatingChromeController _chrome = FushiFloatingChromeController();

  /// 子区页头登记动作的槽：由浮动工具栏右侧的动作组画出。
  final FushiShellActionsSlot _actionsSlot = FushiShellActionsSlot();

  bool _onScroll(ScrollNotification notification) {
    if (!fushiNotificationDrivesPageChrome(notification)) return false;
    return _chrome.handleScrollNotification(notification);
  }

  @override
  void dispose() {
    _chrome.dispose();
    _actionsSlot.dispose();
    gameSectionNotifier.removeListener(_onSectionRequested);
    _controller.gameExitedCount.removeListener(_onGameExited);
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
      if (requested == GameSection.importGames) _beforeImport = _section;
      if (gameSectionGroupOf(requested) == LibrarySectionGroup.library) {
        _lastLibrarySection = requested;
      }
      _section = requested;
      if (requested == GameSection.discover) _discoverVisited = true;
      if (requested == GameSection.stream) _streamVisited = true;
      if (requested == GameSection.importGames) _importVisited = true;
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

  /// 导入钮：不在导入页时进去，在导入页时回到进来前的子区。
  void _toggleImport() => _showSection(
    _section == GameSection.importGames
        ? _beforeImport
        : GameSection.importGames,
  );

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
    // 顶部与视频 / 书 / 漫画库同一套库页外壳（[LibraryLayout]：M3E 浮动工具栏 /
    // Apple 方案 A）：各子区页头里的那份页签在 [GameSectionTabsHostScope] 下留空，
    // 动作登记进外壳的 [_actionsSlot] 由动作组画出。
    //
    // 诊断不设页签（从捕获工作台 / 全局设置进入），停在诊断时高亮「工作台」；
    // 这时与停在导入页一样，高亮只是视觉锚点，点它照常回到工作台（BUG-4706）。
    final GameSection shown = _section == GameSection.diagnostics
        ? GameSection.monitor
        : _section;
    final LibrarySectionGroup? shownGroup = gameSectionGroupOf(shown);
    final LibraryChromeSpec<GameSection> spec = LibraryChromeSpec<GameSection>(
      title: FushiShellTitleScope.maybeTitleOf(context) ?? '',
      groups: gameLibraryChromeGroups(
        shown: shown,
        lastLibrarySection: _lastLibrarySection,
      ),
      selected: shown,
      currentGroup: shownGroup,
      selectedIsCurrent: shownGroup != null && shown == _section,
      onSelect: _showSection,
      // 焦点 id 沿用各子区原来那份页签的稳定 id（`game-library-tab-sections`
      // 等）：键盘 / 手柄 / 集成测试按它定位，换成外壳统一画也不能变。
      focusIdPrefix: switch (_section) {
        GameSection.dashboard => 'game-dashboard-tab',
        GameSection.library => 'game-library-tab',
        GameSection.monitor => 'game-capture-tab',
        GameSection.discover => 'game-discover-tab',
        GameSection.importGames => 'game-import-tab',
        GameSection.diagnostics => 'game-diagnostics-tab',
        GameSection.stream => 'game-stream-tab',
      },
      actionsSlot: _actionsSlot,
      chrome: _chrome,
      import: LibraryChromeImport(
        selected: _section == GameSection.importGames,
        onTap: _toggleImport,
        focusIdPrefix: 'game-library-view',
      ),
      iconOf: gameSectionIcon,
    );
    final Widget body = LibrarySectionFollowScope(
      current: gameSectionNotifier,
      // 触屏横滑按页签**视觉序**（[kGameSectionTabOrder]）切相邻子区；诊断不在
      // 页签序里，停在诊断时横滑不响应（导航层级只对页签序负责）。
      child: SectionSwipeNavigator<GameSection>(
        // 导入不是页签，只在停在导入页时留在序里（从它滑回相邻子区）。
        sections: <GameSection>[
          for (final GameSection section in kGameSectionTabOrder)
            if (section != GameSection.importGames ||
                _section == GameSection.importGames)
              section,
        ],
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
              // 用户停在诊断/导入子区时答案照样是 true。判据与 `index:` 用的是同一个
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
        child: FushiHeaderSearchKeys(
          // Ctrl+F / `/` 展开当前视图的页头搜索，展开时 Esc 先清空再收起
          // （焦点在页签、动作或内容上都认）。
          resolve: () => fushiVisibleHeaderSearch(_actionsSlot),
          child: LibraryLayout<GameSection>(
            spec: spec,
            // 子区滚动驱动工具栏显隐（与视频 / 书 / 漫画库同构）。
            body: NotificationListener<ScrollNotification>(
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
  /// - 首页 / 导入：主滚动视图自己吃掉让位——[FushiFloatingChromeScrollInset]
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
        GameSection.dashboard => FushiFloatingChromeScrollInset(child: child),
        // [ImportPageLayout] 自己读 [FushiFloatingChromeInset] 加进滚动内边距
        // （内容从工具区下方起排、往下滚到工具区底下），不能先被 ScrollInset 归零。
        GameSection.importGames ||
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
            onManageSources: discoveryManageSourcesAction(
              context: context,
              appModel: ref.read(appProvider),
            ),
          ),
    );
  }

  /// 游戏「导入」视图（导入稿 v2 第二节 5）：与书 / 漫画 / 视频 / 音乐同一套
  /// [ImportPageLayout]——引导首块 + 两个方式块（添加游戏 / 扫描文件夹），其下
  /// 「常驻来源」色块区（互联块照旧保留，IM21；扫描根；添加来源直接选目录）。
  ///
  /// 拖放只认 .exe（[addGamesFromPaths] → `filterOutDuplicateGameExes` 丢弃文件夹），
  /// 所以引导首块只说 .exe、格式只有 EXE；「扫描文件夹」只在方式块与添加来源里。
  /// 整页落点由 [ImportPageLayout] 按 spec.onDrop 装（此前另写的拖放卡与虚线
  /// 画笔删掉，IM11），外层仍是本页 IndexedStack 的 `DropSurfaceScope` 门。
  Widget _buildImport(BuildContext context) {
    // IndexedStack 急切构建全部子区，本视图在无 ProviderScope 的 widget 测试里
    // 也会被 build——容器只在点按 / 落下时解析，构建期零 provider 依赖。
    GalgameRepository repo() => ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appProvider).galgameRepo;
    final ImportSurfaceSpec spec = ImportSurfaceSpec(
      id: 'game',
      tone: ImportTone.amber,
      guideIcon: FushiIcons.games,
      guideTitle: t.import_guide_game_title,
      guideDescription: t.import_guide_game_desc,
      methods: <ImportMethod>[
        ImportMethod(
          id: 'game-add',
          kind: ImportMethodKind.primary,
          icon: FushiIcons.games,
          label: t.game_add,
          description: t.import_method_game_add_desc,
          destination: ImportDestination.pickFile,
          // 不弹对话框（系统选 exe → 落库）：块上转圈直到落库结束（IM14）。
          reportsProgress: true,
          // 导入成功后跳到游戏库：新游戏落在**另一个** section 里，停在导入页
          // 的话屏幕上什么都不变，成功与失败在观感上一模一样（用户「导成功没
          // 反应我还以为失败了重试了好几次」）。
          onTap: () => addGameViaFilePicker(repo(), onImported: _showLibrary),
        ),
        ImportMethod(
          id: 'game-scan-folder',
          kind: ImportMethodKind.folder,
          icon: FushiIcons.folder,
          label: t.import_method_game_scan_folder,
          description: t.import_method_game_scan_folder_desc,
          destination: ImportDestination.pickFolder,
          // 游戏来源只收本地文件夹：`addSource` 直达选目录（IM13 保持原语义）。
          // 扫描进度画在新来源块上，方式块不转圈。
          onTap: () async => _sourcesKey.currentState?.addSource(),
        ),
      ],
      formatGroups: <ImportFormatGroup>[
        ImportFormatGroup(
          title: t.nav_game,
          labels: importFormatLabels(<Iterable<String>>[
            kGameExecutableExtensions,
          ]),
        ),
      ],
      // 必须把 future 交回去：`FushiFileDropTarget.runDrop` 特意 await 回调，
      // 那是拖放路径上**唯一**的错误咽喉（repo.load()/addAll() 抛出时异常不能
      // 漂进 zone，否则用户看到的只有「拖了没反应」）。
      onDrop: (List<String> paths, Offset position) =>
          addGamesFromPaths(repo(), paths, onImported: _showLibrary),
    );
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: ImportPageLayout(
        spec: spec,
        // 来源列表一挂载就查来源表与各来源计数：访问过导入页才构建。
        sources: _importVisited
            ? _buildSources(context)
            : const SizedBox.shrink(),
        onAddSource: () => unawaited(_sourcesKey.currentState?.addSource()),
      ),
    );
  }

  /// 常驻来源列表（游戏种类）。扫描写完 `galgames` 后由 AppModel 的
  /// `onGameSourceScanned` 重载游戏库缓存，这里不另接刷新。
  Widget _buildSources(BuildContext context) {
    final GameSourcesBuilder? builder = widget.sourcesBuilder;
    if (builder != null) return builder(context, _sourcesKey);
    return MediaSourcesView(
      key: _sourcesKey,
      mediaKind: SourceLibraryKind.game.dbValue,
      presentation: MediaSourcesPresentation.blocks,
      // 0 引导首块 → 1..2 方式块 → 3 区头 → 来源块。
      entranceIndexOffset: 4,
      addSourceHint: t.game_source_scan_hint,
    );
  }

  /// 跳到统一下载中心（浏览 › 下载 › 任务）。写首页监听的
  /// [externalBrowseRequest]，由首页走它唯一的浏览跳转出口（先判可达、再退回
  /// 根路由、再切页签），本页不另拼导航。
  void _openDownloads() {
    externalBrowseRequest.value = BrowseNavigationRequest(BrowseTab.downloads);
  }

  Widget _buildLibrary(BuildContext context) {
    // 注入 libraryBuilder 的测试宿主用的紧凑会话状态带（原两张总览大卡的收敛
    // 替身），整条可点进入捕获工作台。生产路径的会话带由库页自己画（见下）。
    final Widget statusStrip = AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        final GalHookSessionState state = _controller.state;
        final lines = _controller.lines;
        final GalWorkbenchReadiness readiness = galWorkbenchReadiness(
          state: state,
          requiresTextThread: _controller.requiresTextThreadSelection,
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
            // 网格 / 列表切换已并进游戏库自己的单行页头（与搜索 / 刮削 / 排序
            // 同一组动作，2026-10-14），这里不再挂页头动作。
          ),
          Expanded(
            // 生产路径：库页自己把搜索 / 筛选行叠进浮动工具区、主滚动视图消费
            // 让位（本子区在 [build] 里不再整体下移）；状态带作为滚动内容的
            // 第一块，随内容滚到工具区底下。
            //
            // 会话带（GA5）：生产路径不再传常驻状态带——Windows 上库页有
            // sessionController 时自己画会话带，只在有 Hook 会话时出现（游戏名 +
            // 已抓台词数 + 最新一行），空闲时不占位。
            child: libraryBuilder == null
                ? Consumer(
                    builder: (BuildContext context, WidgetRef ref, Widget? _) {
                      // 下载块「打开下载 ›」：浏览模块关着就不出这个入口（与视频
                      // 发现页「查看下载」同一判据），开着走首页统一的浏览跳转出口。
                      final bool browseReachable = ref.watch(
                        appProvider.select(
                          (AppModel model) => isHomeTabVisible(
                            HomeTab.browse,
                            model.moduleVisibility,
                          ),
                        ),
                      );
                      return GamesLibraryPage(
                        embedded: true,
                        sessionController: _controller,
                        onLaunched: _showMonitor,
                        onOpenDownloads: browseReachable
                            ? _openDownloads
                            : null,
                      );
                    },
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
/// 读作强调），墨水屏退成描边胶囊；Apple = 强调色 15% 淡染胶囊 + 强调色字
/// （iOS 状态标签的 tinted 样式，不用实色块）。
class _SessionPhaseChip extends StatelessWidget {
  const _SessionPhaseChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final FushiAppleColors? appleColors = !eink && isGlassDesign(context)
        ? appleColorsOf(context)
        : null;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: eink
            ? colors.surface
            : appleColors?.accent.withValues(alpha: 0.15) ?? colors.primary,
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
            color: eink
                ? colors.onSurface
                : appleColors?.accent ?? colors.onPrimary,
          ),
        ),
      ),
    );
  }
}
