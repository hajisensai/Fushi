import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/media/drag_drop/drop_surface_scope.dart';
import 'package:fushi/src/media/source_library/source_library_row.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/pages/implementations/media_sources_page.dart';
import 'package:fushi/src/pages/implementations/module_settings_view.dart';
import 'package:fushi/src/pages/implementations/video_discovery_detail_page.dart';
import 'package:fushi/src/pages/implementations/video_discovery_page.dart';
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
    required this.onScrapeSource,
    required this.onVideoScanCompleted,
    required this.onOpenScrapeTasks,
    required this.onLibraryChanged,
    this.discoveryController,
    this.discoveryActions = const VideoDiscoveryActions(),
    this.localLibraryPageBuilder,
    this.discoveryPageBuilder,
    super.key,
  });

  final VideoBookRepository repository;
  final Listenable libraryRefreshSignal;
  final VideoSourceScrapeTaskController scrapeTaskController;
  final Future<void> Function() onScrapeAll;
  final Future<void> Function(SourceLibraryRow source) onScrapeSource;
  final Future<void> Function(
    SourceLibraryRow source,
    SourceScanSummary summary,
  ) onVideoScanCompleted;
  final VoidCallback onOpenScrapeTasks;
  final VoidCallback onLibraryChanged;

  /// 在线发现的数据端口。生产环境由发现聚合服务注入；null 时页面呈现可重试的空态。
  final VideoDiscoveryController? discoveryController;

  /// 详情页的资源、字幕、订阅和播放动作端口。
  final VideoDiscoveryActions discoveryActions;

  /// 允许宿主测试替换本地库叶子；生产环境保持 null，使用 [HomeVideoPage]。
  final Widget Function(
    BuildContext context,
    Widget navigation,
    VideoLibrarySection section,
  )? localLibraryPageBuilder;

  /// 仅供宿主定制或 widget 测试注入发现页，不改变惰性构建/保活语义。
  final Widget Function(BuildContext context, Widget navigation)?
      discoveryPageBuilder;

  @override
  State<VideoLibraryShell> createState() => _VideoLibraryShellState();
}

class _VideoLibraryShellState extends State<VideoLibraryShell> {
  VideoLibrarySection _section = VideoLibrarySection.home;
  VideoLibrarySection _localSection = VideoLibrarySection.home;
  bool _discoverVisited = false;
  bool _sourcesVisited = false;
  bool _settingsVisited = false;

  void _select(VideoLibrarySection value) {
    if (value == _section) return;
    setState(() {
      _section = value;
      if (value == VideoLibrarySection.home ||
          value == VideoLibrarySection.series ||
          value == VideoLibrarySection.allVideos) {
        _localSection = value;
      }
      if (value == VideoLibrarySection.discover) _discoverVisited = true;
      if (value == VideoLibrarySection.sources) _sourcesVisited = true;
      if (value == VideoLibrarySection.settings) _settingsVisited = true;
    });
  }

  bool get _showsLocalLibrary => switch (_section) {
        VideoLibrarySection.home ||
        VideoLibrarySection.series ||
        VideoLibrarySection.allVideos =>
          true,
        VideoLibrarySection.discover ||
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
    final Widget navigation = LibrarySectionTabs<VideoLibrarySection>(
      tabs: <LibrarySectionTab<VideoLibrarySection>>[
        LibrarySectionTab<VideoLibrarySection>(
          value: VideoLibrarySection.home,
          label: t.nav_home,
        ),
        // 与书 / 漫画 / 游戏的发现视图同 key（同概念一词,原 video_discovery_tab 已删）。
        LibrarySectionTab<VideoLibrarySection>(
          value: VideoLibrarySection.discover,
          label: t.library_view_browse,
        ),
        LibrarySectionTab<VideoLibrarySection>(
          value: VideoLibrarySection.series,
          label: t.series,
        ),
        LibrarySectionTab<VideoLibrarySection>(
          value: VideoLibrarySection.allVideos,
          label: t.video_library_all_videos,
        ),
        LibrarySectionTab<VideoLibrarySection>(
          value: VideoLibrarySection.sources,
          label: t.library_view_import,
        ),
        LibrarySectionTab<VideoLibrarySection>(
          value: VideoLibrarySection.settings,
          label: t.settings,
        ),
      ],
      selected: _section,
      onChanged: _select,
      focusIdPrefix: 'video-library-view',
    );
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
                      onOpenSources: () => _select(VideoLibrarySection.sources),
                    ),
              ),
            ),
          ),
        ),
        if (_discoverVisited)
          Offstage(
            offstage: _section != VideoLibrarySection.discover,
            child: ExcludeFocus(
              excluding: _section != VideoLibrarySection.discover,
              child: TickerMode(
                enabled: _section == VideoLibrarySection.discover,
                child: _dropScoped(
                  () => _section == VideoLibrarySection.discover,
                  widget.discoveryPageBuilder?.call(
                        context,
                        _navigationFor(
                          _section == VideoLibrarySection.discover,
                          navigation,
                        ),
                      ) ??
                      VideoDiscoveryPage(
                        navigation: _navigationFor(
                          _section == VideoLibrarySection.discover,
                          navigation,
                        ),
                        controller: widget.discoveryController,
                        actions: widget.discoveryActions,
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
