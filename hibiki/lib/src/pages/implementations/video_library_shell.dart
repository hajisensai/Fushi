import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/media/source_library/source_library_row.dart';
import 'package:hibiki/src/media/source_library/source_library_scanner.dart';
import 'package:hibiki/src/media/video/metadata/video_source_scrape_task.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_library_section.dart';
import 'package:hibiki/src/pages/implementations/home_video_page.dart';
import 'package:hibiki/src/pages/implementations/media_sources_page.dart';
import 'package:hibiki/utils.dart';

/// 视频专用四分区壳。前三个分区共用同一个 [HomeVideoPage] State，来源页按需保活。
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

  @override
  State<VideoLibraryShell> createState() => _VideoLibraryShellState();
}

class _VideoLibraryShellState extends State<VideoLibraryShell> {
  VideoLibrarySection _section = VideoLibrarySection.home;
  bool _sourcesVisited = false;

  void _select(VideoLibrarySection value) {
    if (value == _section) return;
    setState(() {
      _section = value;
      if (value == VideoLibrarySection.sources) _sourcesVisited = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final Widget navigation = HibikiAdjustableSegmented<VideoLibrarySection>(
      values: VideoLibrarySection.values,
      selected: _section,
      onChanged: _select,
      focusIdPrefix: 'video-library-view',
      focusId: const HibikiFocusId('video-library-view-sections'),
      child: HibikiSegmentedStrip<VideoLibrarySection>(
        segments: <ButtonSegment<VideoLibrarySection>>[
          ButtonSegment<VideoLibrarySection>(
            value: VideoLibrarySection.home,
            label: Text(t.nav_home),
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
            label: Text(t.library_view_sources),
          ),
        ],
        selected: _section,
        onChanged: _select,
      ),
    );
    return Stack(
      children: <Widget>[
        Offstage(
          offstage: _section == VideoLibrarySection.sources,
          child: TickerMode(
            enabled: _section != VideoLibrarySection.sources,
            child: HomeVideoPage(
              repo: widget.repository,
              navigation: navigation,
              section: _section,
              libraryRefreshSignal: widget.libraryRefreshSignal,
              onOpenScrapeTasks: widget.onOpenScrapeTasks,
              scrapeTaskController: widget.scrapeTaskController,
              onOpenSources: () => _select(VideoLibrarySection.sources),
            ),
          ),
        ),
        if (_sourcesVisited)
          Offstage(
            offstage: _section != VideoLibrarySection.sources,
            child: TickerMode(
              enabled: _section == VideoLibrarySection.sources,
              child: MediaSourcesPage(
                mediaKind: 'video',
                navigation: navigation,
                onScrapeAll: widget.onScrapeAll,
                onScrapeSource: widget.onScrapeSource,
                onVideoScanCompleted: widget.onVideoScanCompleted,
                scrapeTaskController: widget.scrapeTaskController,
                onOpenScrapeTasks: widget.onOpenScrapeTasks,
                onLibraryChanged: widget.onLibraryChanged,
              ),
            ),
          ),
      ],
    );
  }
}
