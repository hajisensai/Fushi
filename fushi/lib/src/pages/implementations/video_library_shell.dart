import 'dart:async';

import 'package:flutter/material.dart';
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
import 'package:fushi/src/pages/implementations/media_server/media_server_browse_page.dart';
import 'package:fushi/src/pages/implementations/media_sources_page.dart';
import 'package:fushi/src/pages/implementations/module_settings_view.dart';
import 'package:fushi/src/pages/implementations/video_discovery_detail_page.dart';
import 'package:fushi/src/pages/implementations/video_discovery_page.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_scroll_chrome.dart'
    show fushiNotificationFromVisibleSubtree;
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart'
    show FushiShellActionsSlot, FushiShellTitleScope;
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
  ) onVideoScanCompleted;
  final VoidCallback onOpenScrapeTasks;
  final VoidCallback onLibraryChanged;

  /// 跑一轮库内自动补刮并回传当前待确认作品清单（见 [HomeVideoPage]）。
  /// null = 不接线（宿主测试），视频页的待确认提醒条静默不显示。
  final Future<List<VideoPendingScrapeWork>> Function()? loadPendingScrapeWorks;

  /// 允许宿主测试替换本地库叶子；生产环境保持 null，使用 [HomeVideoPage]。
  final Widget Function(
    BuildContext context,
    Widget navigation,
    VideoLibrarySection section,
  )? localLibraryPageBuilder;

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
  bool _mediaServersVisited = false;
  bool _sourcesVisited = false;
  bool _settingsVisited = false;

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
    _chrome.show();
    setState(() {
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
      if (value == VideoLibrarySection.settings) _settingsVisited = true;
      if (value == VideoLibrarySection.discover ||
          value == VideoLibrarySection.onlineSources ||
          value == VideoLibrarySection.extensions) {
        _onlineVisited.add(value);
      }
    });
  }

  bool get _showsLocalLibrary => switch (_section) {
        VideoLibrarySection.home ||
        VideoLibrarySection.series ||
        VideoLibrarySection.allVideos =>
          true,
        VideoLibrarySection.mediaServers ||
        VideoLibrarySection.discover ||
        VideoLibrarySection.onlineSources ||
        VideoLibrarySection.extensions ||
        VideoLibrarySection.sources ||
        VideoLibrarySection.settings =>
          false,
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
  Widget _dropScoped(bool Function() visible, Widget child) =>
      DropSurfaceScope(isActive: visible, child: child);

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
        // 发现紧跟本地库视图（2026-10-05 用户要求与媒体服务器对调）；媒体服务器
        // 是用户自己的远端库，排在发现之后；随后是来源 / 扩展，最后是管理类分区。
        if (StoreRestrictedCapability.externalDiscovery.isAvailable)
          LibrarySectionTab<VideoLibrarySection>(
            value: VideoLibrarySection.discover,
            label: t.library_view_discover,
          ),
        LibrarySectionTab<VideoLibrarySection>(
          value: VideoLibrarySection.mediaServers,
          label: t.video_library_media_servers,
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
        LibrarySectionTab<VideoLibrarySection>(
          value: VideoLibrarySection.settings,
          label: t.settings,
        ),
      ];
    final Widget navigation = LibrarySectionTabs<VideoLibrarySection>(
      tabs: tabs,
      selected: _section,
      onChanged: _select,
      focusIdPrefix: 'video-library-view',
      floating: true,
    );
    // 保留外壳给本 tab 的页面名（页头据它判断「标题已由外壳画出」），只把动作槽
    // 换成壳自己的，动作改由浮动动作组画。
    return FushiShellTitleScope(
      title: FushiShellTitleScope.maybeTitleOf(context) ?? t.nav_video,
      actionsSlot: _actionsSlot,
      child: FushiFloatingChromeScope(
        controller: _chrome,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            FushiFloatingChromeBar(tabs: navigation, slot: _actionsSlot),
            Expanded(
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScroll,
                child: SectionSwipeNavigator<VideoLibrarySection>(
                  sections: <VideoLibrarySection>[
                    for (final LibrarySectionTab<VideoLibrarySection> tab
                        in tabs)
                      tab.value,
                  ],
                  selected: _section,
                  onSelect: _select,
                  child: _buildSections(navigation),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSections(Widget navigation) {
    return Stack(
      children: <Widget>[
        Offstage(
          offstage: !_showsLocalLibrary,
          child: ExcludeFocus(
            excluding: !_showsLocalLibrary,
            child: TickerMode(
              enabled: _showsLocalLibrary,
              child: _dropScoped(
                () => _showsLocalLibrary,
                widget.localLibraryPageBuilder?.call(
                      context,
                      _navigationFor(_showsLocalLibrary, navigation),
                      _localSection,
                    ) ??
                    HomeVideoPage(
                      repo: widget.repository,
                      navigation:
                          _navigationFor(_showsLocalLibrary, navigation),
                      section: _localSection,
                      libraryRefreshSignal: widget.libraryRefreshSignal,
                      onOpenScrapeTasks: widget.onOpenScrapeTasks,
                      scrapeTaskController: widget.scrapeTaskController,
                      loadPendingScrapeWorks: widget.loadPendingScrapeWorks,
                      onOpenSources: () => _select(VideoLibrarySection.sources),
                    ),
              ),
            ),
          ),
        ),
        if (_mediaServersVisited)
          Offstage(
            offstage: _section != VideoLibrarySection.mediaServers,
            child: ExcludeFocus(
              excluding: _section != VideoLibrarySection.mediaServers,
              child: TickerMode(
                enabled: _section == VideoLibrarySection.mediaServers,
                child: _dropScoped(
                  () => _section == VideoLibrarySection.mediaServers,
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
                        systemBackActive: widget.systemBackActive &&
                            _section == VideoLibrarySection.mediaServers,
                        repo: widget.repository,
                        loadServers: widget.mediaServerServersLoader ??
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
            child: ExcludeFocus(
              excluding: _section != VideoLibrarySection.sources,
              child: TickerMode(
                enabled: _section == VideoLibrarySection.sources,
                child: _dropScoped(
                  () => _section == VideoLibrarySection.sources,
                  MediaSourcesPage(
                    mediaKind: 'video',
                    navigation: _navigationFor(
                      _section == VideoLibrarySection.sources,
                      navigation,
                    ),
                    onScrapeAll: widget.onScrapeAll,
                    onClearAllScrapeRecords:
                        widget.onClearAllScrapeRecords,
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
        if (_settingsVisited)
          Offstage(
            offstage: _section != VideoLibrarySection.settings,
            child: ExcludeFocus(
              excluding: _section != VideoLibrarySection.settings,
              child: TickerMode(
                enabled: _section == VideoLibrarySection.settings,
                child: _dropScoped(
                  () => _section == VideoLibrarySection.settings,
                  ModuleSettingsView(
                    destinationId: SettingsDestinationId.video,
                    navigation: _navigationFor(
                      _section == VideoLibrarySection.settings,
                      navigation,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
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
      child: ExcludeFocus(
        excluding: !active,
        child: TickerMode(
          enabled: active,
          child: _dropScoped(
            () => _section == section,
            build(section, _navigationFor(active, navigation)),
          ),
        ),
      ),
    );
  }

  Widget _buildOnlineSection(
    VideoLibrarySection section,
    Widget navigation,
  ) =>
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
