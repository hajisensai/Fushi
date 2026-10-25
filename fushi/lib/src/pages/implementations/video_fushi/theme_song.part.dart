part of '../video_fushi_page.dart';

/// 作品图谱 L2（docs/specs/2026-10-24-cross-media-links.md §2）：本集识别出的 OP / ED
/// → 「跳过片头 / 片尾」按钮、可选自动跳过、OP 期间角落「♪ 曲名 · 在音乐库打开」、
/// 进度条上的段首 / 段尾刻度。
///
/// 数据：`video_theme_song_spans` 按集缓存（[loadThemeSongSpansForEpisode]）。缓存里
/// 没有这一集时，排一次**只针对这一集**的识别（[ThemeSongDetector.detect]），识别完再读；
/// 整个合集的批量识别由连接编辑 / 曲目页触发，不在播放时扫整部作品（BD 原盘一集解码要读
/// 整个 7 GB 文件，与正在播放的读盘抢带宽）。
///
/// 状态都在 [_themeSongTracker]（纯状态机）里；本扩展只做装配。
extension _VideoThemeSong on _VideoFushiPageState {
  /// 换了视频源后调：清掉上一集的段，按新源重新读 / 识别。远端 / 网页 / 原盘导航会话
  /// 没有可解码的本地文件，直接清空。
  void _refreshThemeSongSpans(
    VideoPlayerController controller,
    String? videoPath,
  ) {
    final int seq = ++_themeSongLoadSeq;
    _themeSongTracker
      ..setSpans(const <ThemeSongSpan>[])
      ..attach(controller.positionMsListenable);
    if (videoPath == null ||
        _isRemote ||
        _webMode ||
        controller.isBlurayNavigationSession ||
        !isLocalVideoFilePath(videoPath)) {
      return;
    }
    final String bookUid = _activeBookUid;
    final FushiDatabase db = appModel.database;
    unawaited(() async {
      final VideoBookRow? row = await db.getVideoBookByBookUid(bookUid);
      if (row == null) return;
      final String wanted = platformPathKey(videoPath);
      int? episodeIndex;
      for (final ({int index, String path}) f in themeSongFilesOf(row)) {
        if (platformPathKey(f.path) == wanted) {
          episodeIndex = f.index;
          break;
        }
      }
      if (episodeIndex == null) return;
      Future<List<ThemeSongSpan>> read() => loadThemeSongSpansForEpisode(
        db,
        bookUid: bookUid,
        episodeIndex: episodeIndex!,
        episodeDurationMs: controller.durationMs,
      );
      List<ThemeSongSpan> spans = await read();
      if (!mounted || seq != _themeSongLoadSeq) return;
      _applyThemeSongSpans(spans);
      // 这一集还有没识别（或缓存已失效）的连接：只识别这一集，完了再读一次。
      final ThemeSongDetectionReport report = await themeSongDetectorFor(
        db,
      ).detect(onlyBookUid: bookUid, onlyEpisodeIndex: episodeIndex);
      if (report.episodesCompared == 0) return;
      spans = await read();
      if (!mounted || seq != _themeSongLoadSeq) return;
      _applyThemeSongSpans(spans);
    }());
  }

  void _applyThemeSongSpans(List<ThemeSongSpan> spans) {
    _themeSongTracker.setSpans(spans);
    _themeSongChapters.value = <VideoChapter>[
      for (final ThemeSongSpan s in spans) ...<VideoChapter>[
        VideoChapter(
          index: -1,
          title: s.title,
          start: Duration(milliseconds: s.startMs),
        ),
        VideoChapter(
          index: -1,
          title: s.title,
          start: Duration(milliseconds: s.endMs),
        ),
      ],
    ];
    // 刻度层挂不挂取决于有无刻度（[_buildChapterMarkersOverlay]），段从无到有要重建一次。
    _rebuild(() {});
    // 立刻按当前位置判一次（暂停在 OP 里打开时，按钮不必等下一次位置事件）。
    _themeSongTracker.onPosition(_controller?.positionMs);
  }

  void _skipThemeSong(ThemeSongSpan span) {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    unawaited(controller.seekMs(_themeSongTracker.skip(span)));
  }

  /// 「在音乐库打开」：在视频页之上压曲目页（音乐模块的曲目详情）。视频暂停，回来
  /// 后焦点经 [PageFocusOwnership.guardOverlay] 归还正文。
  void _openThemeSongTrack(ThemeSongSpan span) {
    final VideoPlayerController? controller = _controller;
    if (controller != null && controller.isPlaying) {
      unawaited(controller.pause());
    }
    final NavigatorState navigator = Navigator.of(context);
    unawaited(
      _focusOwnership.guardOverlay<void>(
        () => navigator.push<void>(
          adaptivePageRoute<void>(
            context: context,
            builder: (_) => MusicTrackDetailPage(trackUid: span.trackUid),
          ),
        ),
      ),
    );
  }

  Widget _buildThemeSongOverlay() {
    final ColorScheme cs = _videoChromeColorScheme(context);
    // 跳过按钮底部避让与自动连播卡同源（进度条真实几何，见 [_buildAutoAdvanceOverlay]）。
    final ({double bottom, double height}) band = videoSeekBarTrackBand(
      trackCenter: _videoSeekBarTrackCenter,
      tickHeight: _videoSeekBarTrackHeight * _controlsDensityScale,
    );
    return Positioned.fill(
      child: SafeArea(
        child: VideoThemeSongOverlay(
          tracker: _themeSongTracker,
          showNowPlaying: appModel.videoThemeSongNowPlaying,
          onSkip: _skipThemeSong,
          onOpenTrack: _openThemeSongTrack,
          surfaceColor: _osdSurfaceColor(cs),
          textColor: _osdTextColor(cs),
          skipBottomInset: band.bottom + band.height + 16 * _videoUiScale,
          nowPlayingTopInset: _videoButtonBarHeight + 8 * _videoUiScale,
          uiScale: _videoUiScale,
        ),
      ),
    );
  }
}
