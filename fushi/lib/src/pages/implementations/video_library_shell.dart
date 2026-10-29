import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/drag_drop/drop_surface_scope.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi_engine/media/video/metadata/video_library_scrape_sweep.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/pages/implementations/browse_online_sources_view.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/pages/implementations/library_online_sources_view.dart';
import 'package:fushi/src/pages/implementations/media_library_shell.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_browse_page.dart';
import 'package:fushi/src/pages/implementations/media_sources_page.dart';
import 'package:fushi/src/pages/implementations/video_discovery_detail_page.dart';
import 'package:fushi/src/pages/implementations/video_discovery_page.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/utils/components/fushi_header_search.dart'
    show FushiHeaderSearchKeys, fushiVisibleHeaderSearch;
import 'package:fushi/src/utils/components/glass/fushi_apple_scroll_chrome.dart'
    show fushiNotificationFromVisibleSubtree;
import 'package:fushi/src/utils/components/section_visibility.dart';
import 'package:fushi/utils.dart';

/// 视频专用分区壳。
///
/// 首页、系列和全部视频共用一个 [HomeVideoPage] State；媒体服务器、发现、在线来源、
/// 扩展、导入和设置各自惰性构建并保活，避免视频页挂载时就触发在线请求，也保证切换
/// 分区后搜索词和滚动位置不丢失。
///
/// 发现 / 来源 / 扩展与顶层「浏览」模块是同一组组件（2026-10-01 用户拍板加回库页
/// 子标签），各自过 iOS 合规门 / 视频源宿主门。
///
/// 顶部是 M3 Expressive 浮动工具栏（2026-10-05「视频库页面也用浮动工具栏统一」，
/// [FushiFloatingChromeBar]）：左边分区页签胶囊，右边是当前分区页头动作的悬浮
/// 按钮组。各分区页面照旧用 [FushiPageHeader] 声明自己的动作，壳在这里挂一个
/// 自己的 [FushiShellActionsSlot]，页头把动作登记进来、由浮动动作组画出（于是
/// 首页外壳大标题条右侧不再收视频库的动作）。往下滚收起、往上滚 / 回顶 / 切分区 /
/// 焦点走进工具栏时弹回（[FushiFloatingChromeController]）。
///
/// 不放 FAB：视频库没有「一屏只此一个」的主创建动作——导入是独立分区（还有拖放），
/// 「继续观看」是首页 hero 内容本身而不是动作；而手机底部已有应用导航栏与多选
/// 批量栏，再叠一枚 FAB 只会互相遮挡。M3E 规范里 FAB 只给屏幕唯一的主动作。
class VideoLibraryShell extends StatefulWidget {
  const VideoLibraryShell({
    required this.repository,
    required this.libraryRefreshSignal,
    required this.scrapeTaskController,
    required this.onScrapeAll,
    required this.onClearAllScrapeRecords,
    required this.onScrapeSource,
    required this.onVideoScanCompleted,
    required this.onOpenScrapeTasks,
    required this.onLibraryChanged,
    this.loadPendingScrapeWorks,
    this.refreshPendingScrapeWorks,
    this.localLibraryPageBuilder,
    this.mediaServerServersLoader,
    this.mediaServerPageBuilder,
    this.discoveryController,
    this.discoveryActions = const VideoDiscoveryActions(),
    this.systemBackActive = true,
    super.key,
  });

  final VideoBookRepository repository;
  final Listenable libraryRefreshSignal;
  final VideoSourceScrapeTaskController scrapeTaskController;
  final Future<void> Function() onScrapeAll;
  final Future<void> Function() onClearAllScrapeRecords;
  final Future<void> Function(SourceLibraryRow source) onScrapeSource;
  final Future<void> Function(
    SourceLibraryRow source,
    SourceScanSummary summary,
  )
  onVideoScanCompleted;
  final VoidCallback onOpenScrapeTasks;
  final VoidCallback onLibraryChanged;

  /// 跑一轮库内自动补刮并回传当前待确认作品清单（见 [HomeVideoPage]）。
  /// null = 不接线（宿主测试），视频页的待确认提醒条静默不显示。
  final Future<List<VideoPendingScrapeWork>> Function()? loadPendingScrapeWorks;

  /// 刮削结果变化后只读重算待确认清单（见 [HomeVideoPage]，BUG-3072）。
  final Future<List<VideoPendingScrapeWork>> Function()?
  refreshPendingScrapeWorks;

  /// 允许宿主测试替换本地库叶子；生产环境保持 null，使用 [HomeVideoPage]。
  final Widget Function(
    BuildContext context,
    Widget navigation,
    VideoLibrarySection section,
  )?
  localLibraryPageBuilder;

  /// 「媒体服务器」分区的已登录服务器清单（生产由 HomePage 从 SyncRepository
  /// 装配）。null = 未接线（宿主测试），分区呈现空态。
  final Future<List<MediaServerEntry>> Function()? mediaServerServersLoader;

  /// 仅供宿主定制或 widget 测试注入媒体服务器页，不改变惰性构建/保活语义。
  final Widget Function(BuildContext context, Widget navigation)?
  mediaServerPageBuilder;

  /// 「发现」分区的搜索端口；与浏览页签共用 HomePage 的同一个生产实例。
  /// null = 未接线（宿主测试），发现页回落到空控制器。
  final VideoDiscoveryController? discoveryController;

  /// 「发现」分区的详情 / 下载 / 订阅回调；与浏览页签共用同一份。
  final VideoDiscoveryActions discoveryActions;

  /// 视频 tab 此刻是否是 HomePage 看得见的那个 tab。媒体服务器分区的嵌套栈靠
  /// [NavigatorPopHandler] 接系统返回，而它登记在 HomePage 根路由上、不随
  /// IndexedStack/Offstage 失效；宿主必须把可见性传进来，否则用户切去词典/设置 tab
  /// 按 Android 返回会静默 pop 一层看不见的分区栈（见 [MediaServerBrowsePage.systemBackActive]）。
  final bool systemBackActive;

  @override
  State<VideoLibraryShell> createState() => _VideoLibraryShellState();
}

class _VideoLibraryShellState extends State<VideoLibraryShell> {
  VideoLibrarySection _section = VideoLibrarySection.home;
  VideoLibrarySection _localSection = VideoLibrarySection.home;

  /// 「媒体库」组上次停留的分区（首页 / 系列 / 全部视频 / 媒体服务器），点组
  /// 页签回到这里。
  VideoLibrarySection _librarySection = VideoLibrarySection.home;

  /// 「在线」组上次停留的分区（发现 / 来源 / 扩展），点组页签回到这里；null =
  /// 还没进过，取组内第一个。网页视频站点 2026-10-19 搬去「网页」模块
  /// （`WebHubPage`）。
  VideoLibrarySection? _onlineSection;

  /// 进导入页之前停留的分区：再点一次导入钮回到这里。
  VideoLibrarySection _beforeImport = VideoLibrarySection.home;
  bool _mediaServersVisited = false;
  bool _sourcesVisited = false;

  /// 发现 / 在线来源 / 扩展三个分区的已访问集合（惰性构建 + 保活）。
  final Set<VideoLibrarySection> _onlineVisited = <VideoLibrarySection>{};

  /// 浮动工具栏的显隐（滚动驱动）。
  final FushiFloatingChromeController _chrome = FushiFloatingChromeController();

  /// 分区页头登记动作的槽：由浮动动作组画出（见类注释）。
  final FushiShellActionsSlot _actionsSlot = FushiShellActionsSlot();

  @override
  void dispose() {
    _chrome.dispose();
    _actionsSlot.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification notification) {
    // 隐藏的保活分区后台加载 / 横滚卡片行发来的通知不算（后者 controller 内按轴过滤）。
    if (!fushiNotificationFromVisibleSubtree(notification)) return false;
    return _chrome.handleScrollNotification(notification);
  }

  void _select(VideoLibrarySection value) {
    if (value == _section) return;
    // 换了分区，新页面从顶部开始：工具栏回来。
    _chrome.resetToTop();
    setState(() {
      if (value == VideoLibrarySection.sources) _beforeImport = _section;
      switch (_groupOf(value)) {
        case LibrarySectionGroup.library:
          _librarySection = value;
        case LibrarySectionGroup.online:
          _onlineSection = value;
        case null:
          break;
      }
      _section = value;
      if (value == VideoLibrarySection.home ||
          value == VideoLibrarySection.series ||
          value == VideoLibrarySection.allVideos) {
        _localSection = value;
      }
      if (value == VideoLibrarySection.mediaServers) {
        _mediaServersVisited = true;
      }
      if (value == VideoLibrarySection.sources) _sourcesVisited = true;
      if (value == VideoLibrarySection.discover ||
          value == VideoLibrarySection.onlineSources ||
          value == VideoLibrarySection.extensions) {
        _onlineVisited.add(value);
      }
    });
  }

  /// 顶栏某组页签此刻代表的分区：组内上次停留的那个（还没进过或已下线时取组内
  /// 第一个）。
  VideoLibrarySection _activeSectionOf(
    LibrarySectionGroup group,
    List<LibrarySectionTab<VideoLibrarySection>> members,
  ) {
    final VideoLibrarySection? last = switch (group) {
      LibrarySectionGroup.library => _librarySection,
      LibrarySectionGroup.online => _onlineSection,
    };
    return members.any(
          (LibrarySectionTab<VideoLibrarySection> tab) => tab.value == last,
        )
        ? last!
        : members.first.value;
  }

  String _groupLabel(
    LibrarySectionGroup group,
    List<LibrarySectionTab<VideoLibrarySection>> members,
  ) => switch (group) {
    LibrarySectionGroup.library => t.library_view_media,
    LibrarySectionGroup.online =>
      members.length == 1 ? members.single.label : t.library_view_online,
  };

  /// 导入钮：不在导入页时进去，在导入页时回到进来前的分区。
  void _toggleImport() => _select(
    _section == VideoLibrarySection.sources
        ? _beforeImport
        : VideoLibrarySection.sources,
  );

  bool get _showsLocalLibrary => switch (_section) {
    VideoLibrarySection.home ||
    VideoLibrarySection.series ||
    VideoLibrarySection.allVideos => true,
    VideoLibrarySection.mediaServers ||
    VideoLibrarySection.discover ||
    VideoLibrarySection.onlineSources ||
    VideoLibrarySection.extensions ||
    VideoLibrarySection.sources => false,
  };

  /// 分区页面页头的标题位：页签已在壳顶部的浮动工具栏里（整个壳只有这一份，
  /// 切分区时指示条在同一个 [TabController] 上从旧分区滑到新分区），页面页头只
  /// 留一个空标题位来登记自己的动作。
  Widget _navigationFor(bool active, Widget navigation) =>
      const SizedBox.shrink();

  /// 给一个保活子视图套上拖放作用域。
  ///
  /// [Offstage] 只关掉 Flutter 自己的 hitTest；desktop_drop 是进程级全局广播，
  /// 只按各 drop target 的 `RenderBox.paintBounds` 过滤，而隐藏的子视图仍以完整
  /// 约束布局（全屏大小），于是**每个访问过的子视图都会收到同一次 OS drop**。
  /// 外层 home-shell 的作用域只回答「视频 tab 可见吗」，答案在用户停在发现/来源/
  /// 设置分区时同样是 true —— 于是拖一个文件夹进窗口会被隐藏的 [HomeVideoPage]
  /// 接走、直接往 media_sources 插一条常驻扫描根并跑全量扫描。
  ///
  /// [visible] 是回调而不是 bool：拖放判定只发生在事件到达的瞬间，判据与上面
  /// `offstage:` 用的是同一个表达式，保证「看得见的那个」与「接拖放的那个」
  /// 永远是同一个。
  ///
  /// 同时给分区一份自己的主滚动控制器（[SectionPrimaryScrollScope]）：保活分区
  /// 同时挂在树上，共用外壳那一个会让多个主滚动视图附着同一控制器、Scrollbar 断言。
  Widget _dropScoped(bool Function() visible, Widget child) => DropSurfaceScope(
    isActive: visible,
    child: SectionPrimaryScrollScope(child: child),
  );

  @override
  Widget build(BuildContext context) {
    // 页签与横滑切区（[SectionSwipeNavigator]）共用同一份序：加减分区只改这里。
    final bool online = isOnlineSourcesDomainAvailable(
      OnlineSourcesDomain.video,
    );
    final List<LibrarySectionTab<VideoLibrarySection>> tabs =
        <LibrarySectionTab<VideoLibrarySection>>[
          LibrarySectionTab<VideoLibrarySection>(
            value: VideoLibrarySection.home,
            label: t.nav_home,
          ),
          LibrarySectionTab<VideoLibrarySection>(
            value: VideoLibrarySection.series,
            label: t.series,
          ),
          LibrarySectionTab<VideoLibrarySection>(
            value: VideoLibrarySection.allVideos,
            label: t.video_library_all_videos,
          ),
          // 媒体服务器是用户自己的远端库，归「媒体库」组、排在本地视图之后；
          // 发现 / 来源 / 扩展归「在线」组；导入是工具栏右端的按钮。
          LibrarySectionTab<VideoLibrarySection>(
            value: VideoLibrarySection.mediaServers,
            label: t.video_library_media_servers,
          ),
          if (StoreRestrictedCapability.externalDiscovery.isAvailable)
            LibrarySectionTab<VideoLibrarySection>(
              value: VideoLibrarySection.discover,
              label: t.library_view_discover,
            ),
          if (online)
            LibrarySectionTab<VideoLibrarySection>(
              value: VideoLibrarySection.onlineSources,
              label: t.library_view_sources,
            ),
          if (online)
            LibrarySectionTab<VideoLibrarySection>(
              value: VideoLibrarySection.extensions,
              label: t.media_import_segment_extensions,
            ),
          LibrarySectionTab<VideoLibrarySection>(
            value: VideoLibrarySection.sources,
            label: t.library_view_import,
          ),
        ];
    // 顶栏只放两组（2026-10-30 用户拍板方案 D，见 [LibrarySectionGroup]）：
    // 媒体库 = 首页 / 系列 / 全部视频 / 媒体服务器，在线 = 发现 / 来源 / 扩展，
    // 组内由顶栏下方的二级胶囊切换；导入是工具栏右端的按钮。每组页签的值就是
    // 该组「当前 / 上次停留」的分区，点组页签即回到组内上次的位置，选中判据仍是
    // `_section`，横滑顺序仍是上面的扁平分区表。
    final List<LibrarySectionTab<VideoLibrarySection>> groupTabs =
        <LibrarySectionTab<VideoLibrarySection>>[];
    for (final LibrarySectionGroup group in LibrarySectionGroup.values) {
      final List<LibrarySectionTab<VideoLibrarySection>> members =
          <LibrarySectionTab<VideoLibrarySection>>[
            for (final LibrarySectionTab<VideoLibrarySection> tab in tabs)
              if (_groupOf(tab.value) == group) tab,
          ];
      if (members.isEmpty) continue;
      groupTabs.add(
        LibrarySectionTab<VideoLibrarySection>(
          value: _groupOf(_section) == group
              ? _section
              : _activeSectionOf(group, members),
          label: _groupLabel(group, members),
          // 组页签的值随组内停留的分区变，顺序身份认组。
          orderId: group.name,
        ),
      );
    }
    final LibrarySectionGroup? currentGroup = _groupOf(_section);
    final List<LibrarySectionTab<VideoLibrarySection>> subTabs =
        currentGroup == null
        ? const <LibrarySectionTab<VideoLibrarySection>>[]
        : <LibrarySectionTab<VideoLibrarySection>>[
            for (final LibrarySectionTab<VideoLibrarySection> tab in tabs)
              if (_groupOf(tab.value) == currentGroup) tab,
          ];
    // 一级只剩一组（iOS 合规门下没有在线分区）时不画胶囊；停在导入页时高亮
    // 「媒体库」组（导入管理的就是本地库）。
    final Widget navigation = groupTabs.length < 2
        ? const SizedBox.shrink()
        : LibrarySectionTabs<VideoLibrarySection>(
            tabs: groupTabs,
            selected: currentGroup == null ? groupTabs.first.value : _section,
            onChanged: _select,
            focusIdPrefix: 'video-library-view',
            floating: true,
            // 反馈 ndQ5eXLcqp：长按 / 右键页签栏自定义顶部页签顺序。
            orderKey: 'video',
          );
    // 保留外壳给本 tab 的页面名（页头据它判断「标题已由外壳画出」），只把动作槽
    // 换成壳自己的，动作改由浮动动作组画。
    //
    // 对子树暴露与通用库页壳同一个「切到某视图」能力：「来源」空态的「浏览扩展」
    // 经它就地切到本页「扩展」，而不是再 push 一页。只声明本壳真有的在线分区。
    return MediaLibraryShellScope(
      kinds: <MediaLibraryViewKind>{
        if (online) MediaLibraryViewKind.onlineSources,
        if (online) MediaLibraryViewKind.extensions,
      },
      select: _selectViewKind,
      child: FushiShellTitleScope(
        title: FushiShellTitleScope.maybeTitleOf(context) ?? t.nav_video,
        actionsSlot: _actionsSlot,
        child: FushiHeaderSearchKeys(
          // Ctrl+F / `/` 展开当前视图的页头搜索，展开时 Esc 先清空再收起
          // （焦点在页签、动作或内容上都认）。
          resolve: () => fushiVisibleHeaderSearch(_actionsSlot),
          child: FushiFloatingChromeScope(
            controller: _chrome,
            // 工具栏叠在内容上，收起只滑出画面、不改内容视口高度（滚轮上下「回弹、
            // 滚不动」的根因是收起改了视口高度，见 [FushiFloatingChromeOverlay]）。
            child: FushiFloatingChromeOverlay(
              chrome: FushiFloatingChromeBar(
                tabs: navigation,
                slot: _actionsSlot,
                trailing: libraryImportChromeButton(
                  selected: _section == VideoLibrarySection.sources,
                  onTap: _toggleImport,
                  focusIdPrefix: 'video-library-view',
                ),
              ),
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScroll,
                child: SectionSwipeNavigator<VideoLibrarySection>(
                  // 导入不是页签，只在停在导入页时留在序里（从它滑回相邻分区）。
                  sections: <VideoLibrarySection>[
                    for (final LibrarySectionTab<VideoLibrarySection> tab
                        in tabs)
                      if (tab.value != VideoLibrarySection.sources ||
                          _section == VideoLibrarySection.sources)
                        tab.value,
                  ],
                  selected: _section,
                  onSelect: _select,
                  // 二级胶囊行叠在页面上、与顶栏同一份显隐（嵌套的
                  // [FushiFloatingChromeOverlay] 读同一个作用域，内层页面的顶部
                  // 让位自动累加两行），收放不改页面视口。
                  child: FushiFloatingChromeOverlay(
                    chrome: subTabs.length < 2
                        ? const SizedBox.shrink()
                        : Padding(
                            // 与顶栏胶囊、页面内容同一条页边；顶上 8 + 顶栏底边 4
                            // = 两级页签之间 12（同浏览页二级内容域）。
                            padding: EdgeInsets.fromLTRB(
                              FushiDesignTokens.of(context).spacing.page,
                              FushiDesignTokens.of(context).spacing.gap,
                              FushiDesignTokens.of(context).spacing.page,
                              FushiDesignTokens.of(context).spacing.gap,
                            ),
                            child: Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: LibrarySectionTabs<VideoLibrarySection>(
                                // 换组即换一份页签（段数与段值都变），不复用旧
                                // controller。
                                key: ValueKey<LibrarySectionGroup?>(
                                  currentGroup,
                                ),
                                tabs: subTabs,
                                selected: _section,
                                onChanged: _select,
                                focusIdPrefix: 'video-library-subview',
                                secondary: true,
                                floating: true,
                              ),
                            ),
                          ),
                    child: _buildSections(navigation),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// [MediaLibraryShellScope.select] 的落地：库页视图种类 → 本壳分区。只认本壳
  /// 声明进 `kinds` 的在线分区，其它种类静默忽略（与通用壳同一契约）。
  void _selectViewKind(MediaLibraryViewKind kind) {
    switch (kind) {
      case MediaLibraryViewKind.onlineSources:
        _select(VideoLibrarySection.onlineSources);
      case MediaLibraryViewKind.extensions:
        _select(VideoLibrarySection.extensions);
      default:
        break;
    }
  }

  Widget _buildSections(Widget navigation) {
    return Stack(
      children: <Widget>[
        Offstage(
          offstage: !_showsLocalLibrary,
          child: SectionVisibilityScope(
            visible: _showsLocalLibrary,
            child: TickerMode(
              enabled: _showsLocalLibrary,
              child: _dropScoped(
                () => _showsLocalLibrary,
                _insetPadded(
                      widget.localLibraryPageBuilder?.call(
                        context,
                        _navigationFor(_showsLocalLibrary, navigation),
                        _localSection,
                      ),
                    ) ??
                    // 主滚动视图自己把工具栏高度加成顶部内边距（内容滚到工具栏底下）。
                    HomeVideoPage(
                      repo: widget.repository,
                      navigation: _navigationFor(
                        _showsLocalLibrary,
                        navigation,
                      ),
                      section: _localSection,
                      libraryRefreshSignal: widget.libraryRefreshSignal,
                      onOpenScrapeTasks: widget.onOpenScrapeTasks,
                      scrapeTaskController: widget.scrapeTaskController,
                      loadPendingScrapeWorks: widget.loadPendingScrapeWorks,
                      refreshPendingScrapeWorks:
                          widget.refreshPendingScrapeWorks,
                      onOpenSources: () => _select(VideoLibrarySection.sources),
                    ),
              ),
            ),
          ),
        ),
        if (_mediaServersVisited)
          Offstage(
            offstage: _section != VideoLibrarySection.mediaServers,
            child: SectionVisibilityScope(
              visible: _section == VideoLibrarySection.mediaServers,
              child: TickerMode(
                enabled: _section == VideoLibrarySection.mediaServers,
                child: _dropScoped(
                  () => _section == VideoLibrarySection.mediaServers,
                  // 媒体服务器页头自己叠进浮动工具区、正文自己让位
                  // （[MediaServerPageFrame]），不再整体下移。
                  widget.mediaServerPageBuilder?.call(
                        context,
                        _navigationFor(
                          _section == VideoLibrarySection.mediaServers,
                          navigation,
                        ),
                      ) ??
                      MediaServerBrowsePage(
                        navigation: _navigationFor(
                          _section == VideoLibrarySection.mediaServers,
                          navigation,
                        ),
                        systemBackActive:
                            widget.systemBackActive &&
                            _section == VideoLibrarySection.mediaServers,
                        repo: widget.repository,
                        loadServers:
                            widget.mediaServerServersLoader ??
                            () async => const <MediaServerEntry>[],
                      ),
                ),
              ),
            ),
          ),
        for (final VideoLibrarySection section in <VideoLibrarySection>[
          VideoLibrarySection.discover,
          VideoLibrarySection.onlineSources,
          VideoLibrarySection.extensions,
        ])
          if (_onlineVisited.contains(section))
            _keepAlive(section, navigation, _buildOnlineSection),
        if (_sourcesVisited)
          Offstage(
            offstage: _section != VideoLibrarySection.sources,
            child: SectionVisibilityScope(
              visible: _section == VideoLibrarySection.sources,
              child: TickerMode(
                enabled: _section == VideoLibrarySection.sources,
                child: _dropScoped(
                  () => _section == VideoLibrarySection.sources,
                  // 导入页的滚动视图自己让出工具区高度（收起后不留空白）。
                  MediaSourcesPage(
                    mediaKind: 'video',
                    navigation: _navigationFor(
                      _section == VideoLibrarySection.sources,
                      navigation,
                    ),
                    onScrapeAll: widget.onScrapeAll,
                    onClearAllScrapeRecords: widget.onClearAllScrapeRecords,
                    onScrapeSource: widget.onScrapeSource,
                    onVideoScanCompleted: widget.onVideoScanCompleted,
                    scrapeTaskController: widget.scrapeTaskController,
                    onOpenScrapeTasks: widget.onOpenScrapeTasks,
                    onLibraryChanged: widget.onLibraryChanged,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 测试替身页面不会自己加顶部内边距：整体让开叠放的工具栏。
  Widget? _insetPadded(Widget? page) =>
      page == null ? null : FushiFloatingChromeInsetPadding(child: page);

  /// 一个惰性保活分区：与上面各分区同一套 Offstage / ExcludeFocus / TickerMode /
  /// 拖放作用域，判据都是「[section] 是当前分区」。
  Widget _keepAlive(
    VideoLibrarySection section,
    Widget navigation,
    Widget Function(VideoLibrarySection section, Widget navigation) build,
  ) {
    final bool active = _section == section;
    return Offstage(
      offstage: !active,
      child: SectionVisibilityScope(
        visible: active,
        child: TickerMode(
          enabled: active,
          child: _dropScoped(
            () => _section == section,
            // 来源 / 扩展 / 发现的主滚动视图都自己把工具区高度加成顶部内边距
            // （发现页的搜索 / 筛选行也叠进浮动工具区，见 [VideoDiscoveryPage]），
            // 工具区收起后不留空白、内容在胶囊背后可见。
            build(section, _navigationFor(active, navigation)),
          ),
        ),
      ),
    );
  }

  Widget _buildOnlineSection(VideoLibrarySection section, Widget navigation) =>
      switch (section) {
        VideoLibrarySection.discover => VideoDiscoveryPage(
          key: const ValueKey<String>('video-library-discovery'),
          navigation: navigation,
          controller: widget.discoveryController,
          actions: widget.discoveryActions,
        ),
        VideoLibrarySection.extensions => LibraryOnlineSourcesView(
          domain: OnlineSourcesDomain.video,
          section: OnlineSourcesSection.extensions,
          navigation: navigation,
        ),
        _ => LibraryOnlineSourcesView(
          domain: OnlineSourcesDomain.video,
          section: OnlineSourcesSection.sources,
          navigation: navigation,
        ),
      };
}

/// 视频分区所属的一级分组（见 [LibrarySectionGroup]）；导入不属于任何组。
LibrarySectionGroup? _groupOf(VideoLibrarySection section) => switch (section) {
  VideoLibrarySection.home ||
  VideoLibrarySection.series ||
  VideoLibrarySection.allVideos ||
  VideoLibrarySection.mediaServers => LibrarySectionGroup.library,
  VideoLibrarySection.discover ||
  VideoLibrarySection.onlineSources ||
  VideoLibrarySection.extensions => LibrarySectionGroup.online,
  VideoLibrarySection.sources => null,
};
