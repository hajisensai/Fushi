part of '../video_fushi_page.dart';

/// 作品图谱 L2（docs/specs/2026-10-24-cross-media-links.md §2）：本集识别出的 OP / ED
/// → 可选自动跳过（默认关）、进度条上的段首 / 段尾刻度。画面上不出跳过按钮与曲名
/// 角标（BUG-3801 按用户决定删除）。
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
    // 立刻按当前位置判一次（刚进 OP 时识别结果才到，不必等下一次位置事件）。
    _themeSongTracker.onPosition(_controller?.positionMs);
  }
}
