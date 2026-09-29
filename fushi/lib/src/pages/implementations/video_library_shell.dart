import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/media/drag_drop/drop_surface_scope.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi_engine/media/video/metadata/video_library_scrape_sweep.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/pages/implementations/media_server/media_server_browse_page.dart';
import 'package:fushi/src/pages/implementations/media_sources_page.dart';
import 'package:fushi/src/pages/implementations/module_settings_view.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/utils.dart';

/// 视频专用六分区壳。
///
/// 首页、系列和全部视频共用一个 [HomeVideoPage] State；发现、来源和设置各自
/// 惰性构建并保活，避免视频页挂载时就触发在线请求，也保证切换分区后搜索词和滚动位置不丢失。
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

  /// 分区页签的唯一身份。页签同一时刻只交给看得见的那个分区（[_navigationFor]），
  /// 切分区时它从旧分区的页头挪到新分区的页头；给它一个壳持有的 [GlobalKey]，
  /// 挪位置就是**同一个** State 换父节点，[TabController] 还停在旧下标、随后
  /// 滑到新下标。没有这把 key，每个分区都挂一份全新的页签、以目标下标起步，指示条
  /// 就只剩首页 / 系列 / 全部视图之间（它们共用一个 [HomeVideoPage]）会滑动。
  final GlobalKey _navigationKey = GlobalKey(
    debugLabel: 'video-library-sections',
  );

  void _select(VideoLibrarySection value) {
    if (value == _section) return;
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
    });
  }

  bool get _showsLocalLibrary => switch (_section) {
        VideoLibrarySection.home ||
        VideoLibrarySection.series ||
        VideoLibrarySection.allVideos =>
          true,
        VideoLibrarySection.mediaServers ||
        VideoLibrarySection.sources ||
        VideoLibrarySection.settings =>
          false,
      };

  Widget _navigationFor(bool active, Widget navigation) =>
      active ? navigation : const SizedBox.shrink();

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
        // 媒体服务器是用户自己的库（只是远端的），排在本地库视图之后、管理类分区之前。
        // 在线发现 2026-09-27 起只住在顶层「浏览」模块（`browse_page.dart`）。
        LibrarySectionTab<VideoLibrarySection>(
          value: VideoLibrarySection.mediaServers,
          label: t.video_library_media_servers,
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
      key: _navigationKey,
      tabs: tabs,
      selected: _section,
      onChanged: _select,
      focusIdPrefix: 'video-library-view',
    );
    return SectionSwipeNavigator<VideoLibrarySection>(
      sections: <VideoLibrarySection>[
        for (final LibrarySectionTab<VideoLibrarySection> tab in tabs)
          tab.value,
      ],
      selected: _section,
      onSelect: _select,
      child: _buildSections(navigation),
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
}
