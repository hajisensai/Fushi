part of '../video_fushi_page.dart';

/// 「跳转回退」：用户做了**非连续**跳转（进度条拖动 / 点击、细进度条、字幕列表点句、
/// 章节跳转、查词浮层「跳到此句」、遥控 / CLI 的绝对 seek、遥控打开收藏句）之前记下
/// 出发点，浮动胶囊 [FushiJumpHistoryPill] 上的「← 返回 / 前进 →」像浏览器历史一样
/// 来回走。位置就是播放器轴毫秒（[JumpHistory]<int>），历史只活在本页本集，不落库。
///
/// 记录口径（与有声书 `onBeforeAudioJump` 同一套判据）：
/// - 入栈是**调用点显式声明**的：用户跳转入口在发 seek 之前调
///   [_recordVideoJumpDeparture]（落点已知）或包一层 [_recordVideoJumpAround]
///   （上 / 下一章这类落点要 seek 之后才知道的）；跨度不足
///   [kVideoJumpThresholdMs] 的不算跳转（逐句、几秒的修正）。
/// - 不入栈：±N 秒快进快退 / 横滑 / 双击（步进）、上 / 下一句与重播本句（逐句）、
///   续播恢复、制卡试听 / 关高级制卡回查词位置、句尾自动停、对轴弹窗里的试听与点波形、
///   AB 循环等程序化 seek——它们都不经过上面两个入口，天然绕过。
/// - media_kit 进度条走 fork 内部 `player.seek`，经 [VideoSeekBarJumpTracker]：
///   `onSeekStart` 记出发点、`onSeekEnd` 落点时判定；横滑 / 双击取相对基准时作废。
///
/// 显隐：没跳转过不画；有历史时，跳转 / 返回 / 前进后亮 [_videoJumpFlashDuration]，
/// 之后只随控制条（[_videoControlsVisible]）出现，自上次跳转起超过设置的自动隐藏时长
/// （`video_jump_pill_auto_hide_seconds`，默认 10 秒）后控制条出现也不画；小窗 / 画中画 / 沉浸锁下不画；
/// × 清空历史。胶囊挂在 controls builder 的 Stack 里（窗口与全屏同一 builder），
/// 全屏路由不随页面 setState 重建，所以显隐全走 notifier。
extension _VideoJumpBack on _VideoFushiPageState {
  /// 跳转 / 返回 / 前进之后胶囊在控制条收起时也亮着的时长。
  static const Duration _videoJumpFlashDuration = Duration(seconds: 6);

  /// 历史所属的「哪一集」：换集 / 换片后旧集的毫秒在新集上没有意义，作废整段历史。
  String get _videoJumpScopeKey => '$_activeBookUid#$_currentEpisode';

  /// 读历史前先核对作用域：换了集就清空（懒清，不用在每条换集路径上各插一句）。
  void _syncVideoJumpScope() {
    final String key = _videoJumpScopeKey;
    if (_videoJumpScope == key) return;
    _videoJumpScope = key;
    _videoJumpHistory.clear();
    _seekBarJumpTracker.cancel();
  }

  /// 一次用户跳转即将从当前位置去 [targetMs]：跨度够大才压出发点。
  /// [fromMs] 缺省取 [VideoPlayerController.resumePositionMs]（有在途 seek 取其目标，
  /// 连续两次跳转时出发点是上一次的落点而不是滞后的旧 position）。
  void _recordVideoJumpDeparture(int targetMs, {int? fromMs}) {
    if (_videoJumpRestoring || !mounted) return;
    final int? from = fromMs ?? _controller?.resumePositionMs;
    if (!isVideoPositionJump(fromMs: from, toMs: targetMs)) return;
    _syncVideoJumpScope();
    _videoJumpHistory.recordDeparture(from!);
    _onVideoJumpHistoryChanged();
  }

  /// 落点要 seek 之后才知道的跳转（上 / 下一章）：先记出发点，seek 发出后按在途目标
  /// 判跨度。
  Future<void> _recordVideoJumpAround(Future<void> Function() seek) async {
    final VideoPlayerController? controller = _controller;
    final int? from = controller?.resumePositionMs;
    await seek();
    if (!mounted || !identical(controller, _controller)) return;
    final int? to = controller?.resumePositionMs;
    if (from == null || to == null) return;
    _recordVideoJumpDeparture(to, fromMs: from);
  }

  /// [_recordVideoJumpDeparture] 的 cue 版本：落点按 [VideoPlayerController.skipToCue]
  /// 同一换算（cue 起点 + 字幕延迟 = 播放器轴）估算；它那 180 ms 前导余量不影响
  /// 15 秒判据，故不计。
  void _recordVideoCueJumpDeparture(AudioCue cue) {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    _recordVideoJumpDeparture(
      (cue.startMs + controller.delayMs).clamp(0, 1 << 30),
    );
  }

  /// 章节面板点某章：落点就是章起点。
  void _recordVideoChapterJumpDeparture(int chapterIndex) {
    final List<VideoChapter> chapters =
        _controller?.chapters ?? const <VideoChapter>[];
    if (chapterIndex < 0 || chapterIndex >= chapters.length) return;
    _recordVideoJumpDeparture(chapters[chapterIndex].start.inMilliseconds);
  }

  /// media_kit 进度条按下（theme `onSeekStart`）。
  void _onSeekBarJumpStart(VideoPlayerController controller) {
    _seekBarJumpTracker.begin(
      controller.resumePositionMs,
      relativeBaseCaptureCount: controller.relativeSeekBaseCaptureCount,
    );
  }

  /// 挂到 [VideoPlayerController.onExternalSeekNotified]：media_kit 进度条 / 横滑 /
  /// 双击的落点（theme `onSeekEnd` → `notifyExternalSeek`），只有进度条那次会入栈。
  void _attachVideoJumpHistory(VideoPlayerController controller) {
    controller.onExternalSeekNotified = (int targetMs) {
      if (!mounted || !identical(controller, _controller)) return;
      final int? origin = _seekBarJumpTracker.commit(
        targetMs,
        relativeBaseCaptureCount: controller.relativeSeekBaseCaptureCount,
      );
      if (origin == null) return;
      _recordVideoJumpDeparture(targetMs, fromMs: origin);
    };
  }

  void _onVideoJumpHistoryChanged() {
    if (!mounted) return;
    _videoJumpFlashTimer?.cancel();
    final bool flash = !_videoJumpHistory.isEmpty;
    if (flash) {
      _videoJumpFlashTimer = Timer(_videoJumpFlashDuration, () {
        if (mounted) _videoJumpPillFlashing.value = false;
      });
    }
    _videoJumpPillFlashing.value = flash;
    _armVideoJumpPillAutoHide(active: flash);
    _videoJumpHistoryRevision.value++;
  }

  /// 每次历史变化重新计时自动隐藏（时长现读偏好，0 = 不自动隐藏）。
  void _armVideoJumpPillAutoHide({required bool active}) {
    _videoJumpPillExpireTimer?.cancel();
    _videoJumpPillExpired.value = false;
    final int seconds = appModel.videoJumpPillAutoHideSeconds;
    if (!active || seconds <= 0) return;
    _videoJumpPillExpireTimer = Timer(Duration(seconds: seconds), () {
      if (mounted) _videoJumpPillExpired.value = true;
    });
  }

  Future<void> _walkVideoJumpHistory({required bool forward}) async {
    if (_videoJumpRestoring) return;
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    _syncVideoJumpScope();
    final int? here = controller.resumePositionMs;
    if (here == null) return;
    final int? target = forward
        ? _videoJumpHistory.goForward(here)
        : _videoJumpHistory.goBack(here);
    if (target == null) return;
    _videoJumpRestoring = true;
    _seekBarJumpTracker.cancel();
    _onVideoJumpHistoryChanged();
    try {
      await controller.seekMs(target);
    } finally {
      _videoJumpRestoring = false;
    }
  }

  void _clearVideoJumpHistory() {
    _videoJumpHistory.clear();
    _seekBarJumpTracker.cancel();
    _onVideoJumpHistoryChanged();
  }

  /// 鼠标进 / 出胶囊（qUeubxE-fM）。悬停开始那一帧控制条可见时，把悬停算作控制条
  /// 活跃：按住控制条（[_controlsHoldJumpPill]），并唤回 media_kit 在鼠标落上胶囊那一刻
  /// 已经 onExit 收起的控制条（MouseTracker 先发 exit 再发 enter，按住来得比收起晚一拍）。
  /// 闪现态（控制条本就隐藏）只冻结胶囊，不把控制条唤出来。
  void _onVideoJumpPillHoverChanged(bool hovering) {
    if (!mounted) return;
    _videoJumpPillHovered.value = hovering;
    // 悬停期间布局冻结、胶囊一直在；移开后从头计时，不让它在鼠标刚离开那一刻消失。
    if (!hovering && !_videoJumpHistory.isEmpty) {
      _armVideoJumpPillAutoHide(active: true);
    }
    final bool hold =
        hovering && videoJumpPillHoverHoldsControls(_videoJumpPillLayout);
    if (hold == _controlsHoldJumpPill) return;
    _controlsHoldJumpPill = hold;
    _syncControlsHold();
    if (hold) _pokeControlsVisible();
  }

  /// controls builder Stack 里的胶囊层：顶部居中；控制条显示时坐在顶栏下方（与顶部锚
  /// 字幕避让顶栏同一几何 [_subtitleControlsTopReserve]），控制条收起时贴顶。
  /// 鼠标悬停期间位置与显隐冻结（[resolveVideoJumpPillLayout]，qUeubxE-fM）。
  Widget _buildVideoJumpHistoryPillOverlay() {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        _videoJumpHistoryRevision,
        _videoJumpPillFlashing,
        _videoJumpPillExpired,
        _videoJumpPillHovered,
        _videoControlsVisible,
        _miniSurface,
        _immersiveLocked,
      ]),
      builder: (BuildContext context, _) {
        _syncVideoJumpScope();
        if (_videoJumpHistory.isEmpty ||
            _inMiniWindow ||
            _immersiveLocked.value) {
          return const SizedBox.shrink();
        }
        final bool chromeShown = _videoControlsVisible.value;
        final VideoJumpPillLayout layout = resolveVideoJumpPillLayout(
          hovered: _videoJumpPillHovered.value,
          frozen: _videoJumpPillLayout,
          live: VideoJumpPillLayout(
            top: chromeShown
                ? _subtitleControlsTopReserve()
                : _videoTopBarMargin().top + 8,
            visible: videoJumpPillLiveVisible(
              chromeShown: chromeShown,
              flashing: _videoJumpPillFlashing.value,
              expired: _videoJumpPillExpired.value,
            ),
            chromeShown: chromeShown,
          ),
        );
        _videoJumpPillLayout = layout;
        final int? back = _videoJumpHistory.backTarget;
        final int? forward = _videoJumpHistory.forwardTarget;
        return AnimatedPositioned(
          key: const ValueKey<String>('video_jump_history_pill'),
          duration: fushiMotionDuration(context, FushiMotion.medium),
          curve: FushiMotion.standard,
          top: layout.top,
          left: 0,
          right: 0,
          child: RepaintBoundary(
            child: VideoHoverHoldRegion(
              onHoverChanged: _onVideoJumpPillHoverChanged,
              child: FushiJumpHistoryPill(
                visible: layout.visible,
                backLabel: back == null ? null : formatJumpHistoryTime(back),
                forwardLabel: forward == null
                    ? null
                    : formatJumpHistoryTime(forward),
                onBack: () => unawaited(_walkVideoJumpHistory(forward: false)),
                onForward: () =>
                    unawaited(_walkVideoJumpHistory(forward: true)),
                onClear: _clearVideoJumpHistory,
              ),
            ),
          ),
        );
      },
    );
  }
}
