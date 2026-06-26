// GENERATED-NOTE: extracted from video_hibiki_page.dart (TODO-590 batch8).
part of '../video_hibiki_page.dart';

/// Chapter domain methods extracted via part-of (TODO-590 batch8); shared
/// private scope. Behaviour-preserving: bodies are verbatim except the lone
/// `setState(() => _hasChapters = hasChapters)` rebuild inside
/// [_syncControllerChapterAvailability] is routed through the main shell's
/// `_rebuild(...)` forwarder (the established part paradigm — an extension
/// cannot call the @protected `State.setState` directly), and the two
/// references to the host's private `static const` chrome metrics
/// (`_videoBottomChromeBaseline` / `_videoChromeFadeDuration`) inside
/// [_buildChapterMarkersOverlay] are fully qualified through
/// `_VideoHibikiPageState.` — an extension cannot resolve a host class's
/// private static by bare name, so the qualification is mandatory and
/// otherwise byte-exact. Everything else is moved character-for-character.
///
/// Covers the chapter-availability controller listener lifecycle
/// ([_attachControllerChapterListener] / [_detachControllerChapterListener] /
/// [_onControllerChaptersChanged] / [_syncControllerChapterAvailability]) and
/// the chapter UI surfaces ([_buildChapterMarkersOverlay] /
/// [_buildChapterSidePanel] / [_showChapterPanel]).
///
/// The instance fields (`_chapterListenerController` / `_chapterListener` /
/// `_hasChapters`), the `debugShowChapterPanel` / `debugChapterCount`
/// @overrides, and every collaborator getter/method (`_videoUiScale`,
/// `_videoSeekBarTrackHeight`, `_videoChromeColorScheme`, `_isDesktopVideoControls`,
/// `_videoBottomSystemInset`, `_pokeControlsVisible`, `_showVideoSidePanel`,
/// the top-level `videoSeekBarTrackBand`) and the two `static const` chrome
/// metrics above stay in the main shell; the extension reads/calls instance
/// members through the shared private scope and the statics via the qualified
/// `_VideoHibikiPageState.` prefix.
extension _VideoChapter on _VideoHibikiPageState {
  void _attachControllerChapterListener(VideoPlayerController controller) {
    if (_chapterListenerController == controller && _chapterListener != null) {
      return;
    }
    _detachControllerChapterListener();
    void listener() => _onControllerChaptersChanged(controller);
    _chapterListenerController = controller;
    _chapterListener = listener;
    controller.addListener(listener);
  }

  void _detachControllerChapterListener() {
    final VideoPlayerController? controller = _chapterListenerController;
    final VoidCallback? listener = _chapterListener;
    if (controller != null && listener != null) {
      controller.removeListener(listener);
    }
    _chapterListenerController = null;
    _chapterListener = null;
  }

  /// controller 通知监听（TODO-424）：章节是 open 后异步填充的，就绪后翻转
  /// [_hasChapters] 触发一次 setState，让控制条章节入口按钮出现 / 消失（换集换成无章节
  /// 的片时也跟着隐藏）。只在「有无章节」真变化时 setState，避免 cue 同步等高频通知抖动。
  void _onControllerChaptersChanged(VideoPlayerController controller) {
    _syncControllerChapterAvailability(controller);
  }

  void _syncControllerChapterAvailability(VideoPlayerController controller) {
    if (!mounted) return;
    if (_controller != controller) return;
    final bool hasChapters = controller.chapters.isNotEmpty;
    if (hasChapters == _hasChapters) return;
    _rebuild(() => _hasChapters = hasChapters);
  }

  /// 进度条（seek bar）章节刻度层（TODO-432）：在 seek bar 同一几何上画每章一条竖线。
  ///
  /// media_kit 的 seek bar 不暴露注入自定义子层的钩子（其 build 写死 Stack：轨道 + 缓冲 +
  /// 进度 + 滑块），故刻度只能作为 controls Stack 里独立的 [Positioned] 兄弟层叠上去。几何
  /// 对齐（与 [_mobileControlsTheme] / [_desktopControlsTheme] 喂给 media_kit 的同一套值
  /// 同源）：水平左右各内缩 16px 对齐 `seekBarMargin`（轨道宽 = 控件区宽 − 32），竖直由纯
  /// 函数 [videoSeekBarTrackBand] 按平台算出刻度带的 `bottom`/`height`（移动端进度条被抬到
  /// 按钮条上方、桌面骑在按钮行上沿）。[VideoChapterMarkers] 内部把 [VideoChapter.start] /
  /// 总时长换算成 `[0,1)` 比例画线（[chapterMarkerFractions]）。
  ///
  /// 仅当前视频有内封章节（[_hasChapters]）时挂；可见性随控制条（[_videoControlsVisible]）
  /// 与 seek bar 同步淡入淡出。SafeArea 吃全屏路由的系统安全区，与 media_kit 控制条
  /// `padding`（全屏 = MediaQuery.padding）对齐，保证窗口 / 全屏两条路径都不错位。
  Widget _buildChapterMarkersOverlay(VideoPlayerController controller) {
    if (!_hasChapters) return const SizedBox.shrink();
    // 刻度竖线高度：比轨道再高一截（约轨道高 + 8px×缩放），让标记探出轨道上下、清晰可见，
    // 但不至于像整条容器那样高出一大块。
    final double tickHeight = _videoSeekBarTrackHeight + 8.0 * _videoUiScale;
    final ({double bottom, double height}) band = videoSeekBarTrackBand(
      isDesktop: _isDesktopVideoControls,
      buttonBarHeight: _videoButtonBarHeight,
      seekBarButtonGap: _videoSeekBarButtonGap,
      seekBarContainerHeight: _videoSeekBarContainerHeight,
      seekBarTrackHeight: _videoSeekBarTrackHeight,
      bottomChromeBaseline: _VideoHibikiPageState._videoBottomChromeBaseline,
      bottomSystemInset: _videoBottomSystemInset(),
      tickHeight: tickHeight,
    );
    final ColorScheme cs = _videoChromeColorScheme(context);
    return Positioned.fill(
      child: SafeArea(
        // 全屏安全区与 media_kit 控制条 padding 对齐；窗口态安全区为 0 不影响。
        child: ValueListenableBuilder<bool>(
          valueListenable: _videoControlsVisible,
          builder: (BuildContext _, bool controlsVisible, __) {
            return IgnorePointer(
              child: AnimatedOpacity(
                opacity: controlsVisible ? 1.0 : 0.0,
                duration: _VideoHibikiPageState._videoChromeFadeDuration,
                child: Padding(
                  // 水平内缩 16px 对齐 seekBarMargin；竖直由 band 锚定到 seek bar 轨道。
                  padding: EdgeInsets.only(
                    left: 16,
                    right: 16,
                    bottom: band.bottom,
                  ),
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: SizedBox(
                      height: band.height,
                      width: double.infinity,
                      child: VideoChapterMarkers(
                        controller: controller,
                        // 高对比刻度色：进度条用 primary，刻度改用 onSurface 让它在
                        // 已播 / 未播段都可见（避免与 primary 进度填充同色被吞）。
                        color: cs.onSurface.withValues(alpha: 0.7),
                        thickness: 2.0 * _videoUiScale,
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 进度条 hover 缩略图预览层（TODO-669，方案 A）：桌面 hover seek bar 时在指针
  /// 上方弹该时间点的画面缩略图 + 时间戳。几何与章节刻度层同源——`Padding(left/right:16)`
  /// 对齐 `seekBarMargin`、轨道带由 [videoSeekBarTrackBand] 锚定，浮层贴在轨道带**上方**。
  ///
  /// [_thumbnailPreview] 为 null（移动端 / 未就绪）时不挂；hover 位置 / 状态由调度器
  /// （经 fork `onHoverPosition` → [_onSeekBarHover] → request）驱动，本层只渲染。
  /// [IgnorePointer] 纯视觉，不拦 seek bar 自身拖动；随控制条 [_videoControlsVisible]
  /// 淡入淡出（控制条隐时 hover 也无意义）。
  Widget _buildThumbnailPreviewOverlay(VideoPlayerController controller) {
    final VideoThumbnailPreviewController? preview = _thumbnailPreview;
    if (preview == null) return const SizedBox.shrink();
    // 缩略图轨道竖直锚点：与刻度层同样的 band，浮层底缘抬到轨道带上沿 + 间距。
    final double tickHeight = _videoSeekBarTrackHeight + 8.0 * _videoUiScale;
    final ({double bottom, double height}) band = videoSeekBarTrackBand(
      isDesktop: _isDesktopVideoControls,
      buttonBarHeight: _videoButtonBarHeight,
      seekBarButtonGap: _videoSeekBarButtonGap,
      seekBarContainerHeight: _videoSeekBarContainerHeight,
      seekBarTrackHeight: _videoSeekBarTrackHeight,
      bottomChromeBaseline: _VideoHibikiPageState._videoBottomChromeBaseline,
      bottomSystemInset: _videoBottomSystemInset(),
      tickHeight: tickHeight,
    );
    // 浮层底缘 = 轨道带上沿（band.bottom + band.height）+ 一个小间距。
    final double previewBottom =
        band.bottom + band.height + 6.0 * _videoUiScale;
    final ColorScheme cs = _videoChromeColorScheme(context);
    return Positioned.fill(
      child: SafeArea(
        child: ValueListenableBuilder<bool>(
          valueListenable: _videoControlsVisible,
          builder: (BuildContext _, bool controlsVisible, __) {
            return IgnorePointer(
              child: Padding(
                // 水平内缩 16px 对齐 seekBarMargin；轨道内宽由内部 LayoutBuilder 取。
                padding: const EdgeInsets.only(left: 16, right: 16),
                child: LayoutBuilder(
                  builder: (BuildContext _, BoxConstraints constraints) {
                    return Stack(
                      children: <Widget>[
                        VideoThumbnailPreviewOverlay(
                          controller: preview,
                          trackWidth: constraints.maxWidth,
                          bottomOffset: previewBottom,
                          colorScheme: cs,
                          uiScale: _videoUiScale,
                          controlsVisible: controlsVisible,
                        ),
                      ],
                    );
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// 内封章节面板（TODO-424）：列出 [controller] 的章节，点击跳转，高亮当前章。
  /// 当前章由 [controller] 的播放位置对照各章起点同步算出（[VideoPlayerController
  /// .chapterIndexForPosition]），无需异步轮询 libmpv `chapter`。
  Widget _buildChapterSidePanel(VideoPlayerController controller) {
    final int current = controller.chapterIndexForPosition(
      controller.positionMs ?? 0,
    );
    return VideoChapterPanel(
      controller: controller,
      currentIndex: current,
      colorScheme: _videoChromeColorScheme(context),
      emptyHint: t.video_chapters_empty,
      onTapChapter: (VideoChapter chapter) {
        _pokeControlsVisible();
        unawaited(controller.seekToChapter(chapter.index));
      },
    );
  }

  /// 打开章节面板（控制条章节按钮 / 快捷键共用）。
  void _showChapterPanel(
    VideoPlayerController _, {
    VideoControlSlot? sourceSlot,
  }) {
    _showVideoSidePanel(
      _VideoSidePanelKind.chapters,
      sourceSlot: sourceSlot,
    );
  }
}
