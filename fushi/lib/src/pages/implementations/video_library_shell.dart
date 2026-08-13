import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
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

  @override
  Widget build(BuildContext context) {
    final Widget navigation = FushiAdjustableSegmented<VideoLibrarySection>(
      values: VideoLibrarySection.values,
      selected: _section,
      onChanged: _select,
      focusIdPrefix: 'video-library-view',
      focusId: const FushiFocusId('video-library-view-sections'),
      child: FushiSegmentedStrip<VideoLibrarySection>(
        segments: <ButtonSegment<VideoLibrarySection>>[
          ButtonSegment<VideoLibrarySection>(
            value: VideoLibrarySection.home,
            label: Text(t.nav_home),
          ),
          ButtonSegment<VideoLibrarySection>(
            value: VideoLibrarySection.discover,
            label: Text(t.video_discovery_tab),
          ),
          ButtonSegment<VideoLibrarySection>(
            value: VideoLibrarySection.series,
            label: Text(t.series),
          ),
          ButtonSegment<VideoLibrarySection>(
            value: VideoLibrarySection.allVideos,
            label: Text(t.video_library_all_videos),
          ),
          ButtonSegment<VideoLibrarySection>(
            value: VideoLibrarySection.sources,
            label: Text(t.library_view_import),
          ),
          ButtonSegment<VideoLibrarySection>(
            value: VideoLibrarySection.settings,
            label: Text(t.settings),
          ),
        ],
        selected: _section,
        onChanged: _select,
      ),
    );
    return Stack(
      children: <Widget>[
        Offstage(
          offstage: !_showsLocalLibrary,
          child: ExcludeFocus(
            excluding: !_showsLocalLibrary,
            child: TickerMode(
              enabled: _showsLocalLibrary,
              child: widget.localLibraryPageBuilder?.call(
                    context,
                    _navigationFor(_showsLocalLibrary, navigation),
                    _localSection,
                  ) ??
                  HomeVideoPage(
                    repo: widget.repository,
                    navigation: _navigationFor(_showsLocalLibrary, navigation),
                    section: _localSection,
                    libraryRefreshSignal: widget.libraryRefreshSignal,
                    onOpenScrapeTasks: widget.onOpenScrapeTasks,
                    scrapeTaskController: widget.scrapeTaskController,
                    onOpenSources: () => _select(VideoLibrarySection.sources),
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
                child: widget.discoveryPageBuilder?.call(
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
        if (_sourcesVisited)
          Offstage(
            offstage: _section != VideoLibrarySection.sources,
            child: ExcludeFocus(
              excluding: _section != VideoLibrarySection.sources,
              child: TickerMode(
                enabled: _section == VideoLibrarySection.sources,
                child: MediaSourcesPage(
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
        if (_settingsVisited)
          Offstage(
            offstage: _section != VideoLibrarySection.settings,
            child: ExcludeFocus(
              excluding: _section != VideoLibrarySection.settings,
              child: TickerMode(
                enabled: _section == VideoLibrarySection.settings,
                child: ModuleSettingsView(
                  destinationId: SettingsDestinationId.video,
                  navigation: _navigationFor(
                    _section == VideoLibrarySection.settings,
                    navigation,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
