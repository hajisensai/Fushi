part of '../video_fushi_page.dart';

/// 「跳转回退」：用户做了**非连续**跳转（进度条拖动 / 点击、细进度条、字幕列表点句、
/// 章节跳转、查词浮层「跳到此句」、遥控 / CLI 的绝对 seek、遥控打开收藏句）之前记下
/// 出发点，顶栏右上角的「↶ 返回 / ↷ 前进」像浏览器历史一样来回走。位置就是播放器轴
/// 毫秒（[JumpHistory]<int>），历史只活在本页本集，不落库。
///
/// 记录口径（与有声书 `onBeforeAudioJump` 同一套判据）：
/// - 入栈是**调用点显式声明**的：用户跳转入口在发 seek 之前调
///   [_recordVideoJumpDeparture]（落点已知）或包一层 [_recordVideoJumpAround]
///   （上 / 下一章这类落点要 seek 之后才知道的），并声明来源动作（[JumpSource]，
///   「跳转记录」面板的副标题）；跨度不足 [kVideoJumpThresholdMs] 的不算跳转（逐句、
///   几秒的修正）。
/// - 不入栈：±N 秒快进快退 / 横滑 / 双击（步进）、上 / 下一句与重播本句（逐句）、
///   续播恢复、制卡试听 / 关高级制卡回查词位置、句尾自动停、对轴弹窗里的试听与点波形、
///   AB 循环等程序化 seek——它们都不经过上面两个入口，天然绕过。
/// - media_kit 进度条走 fork 内部 `player.seek`，经 [VideoSeekBarJumpTracker]：
///   `onSeekStart` 记出发点、`onSeekEnd` 落点时判定；横滑 / 双击取相对基准时作废。
///
/// 呈现（所有者 2026-11-02 定稿，取代浮动胶囊）：
/// - 顶栏右上角动作区最前面一枚独立的按钮胶囊（[_videoJumpHistoryTopBarGroup]）：
///   ↶ 返回，走过返回后多出 ↷ 前进，位置只进 tooltip；长按 / 右键打开「跳转记录」
///   面板。跟着控制条一起显隐，控制条收着时跳转**不做任何提示**；设置关掉、超过
///   自动隐藏时长（[_videoJumpAutoHide]）、小窗 / 画中画 / 沉浸锁下不画。
/// - 「⋯」里有历史时多一行「跳转记录」。面板开着期间按住控制条。
/// - 控制条进度条（M3E 轨道）与细进度条上的落点刻度（只看不点）。
///
/// 顶栏与进度条都在 controls builder 里（窗口与全屏同一 builder），全屏路由不随页面
/// setState 重建，所以一切显隐都走 notifier（[_videoJumpHistoryRevision] /
/// [_videoJumpAutoHide]）。
extension _VideoJumpBack on _VideoFushiPageState {
  /// 历史所属的「哪一集」：换集 / 换片后旧集的毫秒在新集上没有意义，作废整段历史。
  String get _videoJumpScopeKey => '$_activeBookUid#$_currentEpisode';

  /// 历史是否属于当前这一集（build 里只读这个判据，不在 build 里改状态）。
  bool get _videoJumpHasHistory =>
      _videoJumpScope == _videoJumpScopeKey && !_videoJumpHistory.isEmpty;

  /// 读写历史前先核对作用域：换了集就清空并停掉自动隐藏计时（懒清，不用在每条换集
  /// 路径上各插一句）。只在事件回调里调，不在 build 里调（[JumpHistoryAutoHide.reset]
  /// 会通知监听者）。
  void _syncVideoJumpScope() {
    final String key = _videoJumpScopeKey;
    if (_videoJumpScope == key) return;
    final bool hadHistory = !_videoJumpHistory.isEmpty;
    _videoJumpScope = key;
    _videoJumpHistory.clear();
    _seekBarJumpTracker.cancel();
    if (hadHistory) _videoJumpAutoHide.reset();
  }

  /// 一次用户跳转即将从当前位置去 [targetMs]：跨度够大才压出发点。
  /// [fromMs] 缺省取 [VideoPlayerController.resumePositionMs]（有在途 seek 取其目标，
  /// 连续两次跳转时出发点是上一次的落点而不是滞后的旧 position）。
  void _recordVideoJumpDeparture(
    int targetMs, {
    int? fromMs,
    required JumpSource source,
  }) {
    if (_videoJumpRestoring || !mounted) return;
    final int? from = fromMs ?? _controller?.resumePositionMs;
    if (!isVideoPositionJump(fromMs: from, toMs: targetMs)) return;
    _syncVideoJumpScope();
    _videoJumpHistory.recordDeparture(from!, source: source);
    _onVideoJumpHistoryChanged(jumped: true);
  }

  /// 落点要 seek 之后才知道的跳转（上 / 下一章）：先记出发点，seek 发出后按在途目标
  /// 判跨度。
  Future<void> _recordVideoJumpAround(
    Future<void> Function() seek, {
    required JumpSource source,
  }) async {
    final VideoPlayerController? controller = _controller;
    final int? from = controller?.resumePositionMs;
    await seek();
    if (!mounted || !identical(controller, _controller)) return;
    final int? to = controller?.resumePositionMs;
    if (from == null || to == null) return;
    _recordVideoJumpDeparture(to, fromMs: from, source: source);
  }

  /// [_recordVideoJumpDeparture] 的 cue 版本：落点按 [VideoPlayerController.skipToCue]
  /// 同一换算（cue 起点 + 字幕延迟 = 播放器轴）估算；它那 180 ms 前导余量不影响
  /// 15 秒判据，故不计。
  void _recordVideoCueJumpDeparture(
    AudioCue cue, {
    required JumpSource source,
  }) {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    _recordVideoJumpDeparture(
      (cue.startMs + controller.delayMs).clamp(0, 1 << 30),
      source: source,
    );
  }

  /// 章节面板点某章：落点就是章起点。
  void _recordVideoChapterJumpDeparture(int chapterIndex) {
    final List<VideoChapter> chapters =
        _controller?.chapters ?? const <VideoChapter>[];
    if (chapterIndex < 0 || chapterIndex >= chapters.length) return;
    _recordVideoJumpDeparture(
      chapters[chapterIndex].start.inMilliseconds,
      source: JumpSource.chapter,
    );
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
      _recordVideoJumpDeparture(
        targetMs,
        fromMs: origin,
        source: JumpSource.progressBar,
      );
    };
  }

  /// 历史变了：[jumped] = 刚发生一次跳转（含返回 / 前进 / 面板跳转），顶栏图标重新
  /// 计时自动隐藏。控制条收着时不做任何提示（不再闪现）。
  void _onVideoJumpHistoryChanged({required bool jumped}) {
    if (!mounted) return;
    if (jumped) _videoJumpAutoHide.markJump();
    _videoJumpHistoryRevision.value++;
  }

  /// 走 [steps] 步：负 = 返回 N 步，正 = 前进 N 步（顶栏按钮是 ±1，面板任意步）。
  Future<void> _walkVideoJumpSteps(int steps) async {
    if (_videoJumpRestoring || steps == 0) return;
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    _syncVideoJumpScope();
    final int? here = controller.resumePositionMs;
    if (here == null) return;
    final int? target = steps > 0
        ? _videoJumpHistory.goForwardSteps(here, steps)
        : _videoJumpHistory.goBackSteps(here, -steps);
    if (target == null) return;
    _videoJumpRestoring = true;
    _seekBarJumpTracker.cancel();
    _onVideoJumpHistoryChanged(jumped: true);
    try {
      await controller.seekMs(target);
    } finally {
      _videoJumpRestoring = false;
    }
  }

  Future<void> _walkVideoJumpHistory({required bool forward}) =>
      _walkVideoJumpSteps(forward ? 1 : -1);

  void _clearVideoJumpHistory() {
    _videoJumpHistory.clear();
    _seekBarJumpTracker.cancel();
    _videoJumpAutoHide.reset();
    _onVideoJumpHistoryChanged(jumped: false);
  }

  /// 打开「跳转记录」面板。[from] 取 controls 子树里的 context（全屏时面板要压在
  /// 全屏路由之上）；失效时退回页面 context。面板开着期间按住控制条。
  Future<void> _openVideoJumpHistoryPanel(BuildContext? from) async {
    if (!mounted) return;
    _syncVideoJumpScope();
    final VideoPlayerController? controller = _controller;
    final int here =
        controller?.resumePositionMs ?? controller?.positionMs ?? 0;
    final BuildContext target = from != null && from.mounted ? from : context;
    _controlsHoldJumpPanel = true;
    _syncControlsHold();
    _pokeControlsVisible();
    try {
      await showJumpHistoryPanel<int>(
        context: target,
        history: _videoJumpHistory,
        labelOf: formatJumpHistoryTime,
        currentLabel: formatJumpHistoryTime(here),
        onWalk: (int steps) => unawaited(_walkVideoJumpSteps(steps)),
        onClear: _clearVideoJumpHistory,
      );
    } finally {
      if (mounted) {
        _controlsHoldJumpPanel = false;
        _syncControlsHold();
        _pokeControlsVisible();
        _focusOwnership.reclaim(FocusReclaimCause.overlayClosed);
      }
    }
  }

  /// 顶栏「跳转记录」那组按钮与「⋯」菜单行要跟着重建的状态源。
  Listenable get _videoJumpToolbarListenable => Listenable.merge(<Listenable>[
    _videoJumpHistoryRevision,
    _videoJumpAutoHide,
    _miniSurface,
    _immersiveLocked,
  ]);

  /// 顶栏图标此刻该不该画（共用判据 + 小窗 / 画中画 / 沉浸锁）。
  bool get _videoJumpToolbarShown =>
      jumpHistoryToolbarVisible(
        enabled: appModel.jumpHistoryToolbar,
        hasHistory: _videoJumpHasHistory,
        expired: _videoJumpAutoHide.expired,
      ) &&
      !_inMiniWindow &&
      !_immersiveLocked.value;

  /// 「⋯」溢出菜单里的「跳转记录」常驻行（有历史时才有；顶栏图标关掉 / 自动隐藏后
  /// 仍能打开面板）。
  VideoBarEntry? _videoJumpHistoryMenuEntry(BuildContext from) {
    if (!_videoJumpHasHistory) return null;
    final FushiToolbarItem item = jumpHistoryPanelMenuItem(
      onOpen: () => unawaited(_openVideoJumpHistoryPanel(from)),
    );
    return VideoBarEntry(
      cluster: VideoBarCluster.end,
      folded: true,
      menuAction: VideoBarMenuAction(
        icon: item.icon,
        label: item.label,
        onSelected: () => item.onPressed?.call(),
      ),
      child: const SizedBox.shrink(),
    );
  }

  /// 顶栏右上角动作区最前面的「↶ / ↷」按钮胶囊（不画时零尺寸）。按钮定义取共用件
  /// [jumpHistoryToolbarItems]（tooltip / 长按 / key 三页同源），外观走控制条统一的
  /// [_chromeIconButton]（secondary tonal 强调，插入时弹簧缩放 + 淡入）。
  Widget _videoJumpHistoryTopBarGroup(
    BuildContext from, {
    required bool desktop,
  }) {
    if (!_videoJumpToolbarShown) return const SizedBox.shrink();
    final int? back = _videoJumpHistory.backTarget;
    final int? forward = _videoJumpHistory.forwardTarget;
    final List<FushiToolbarItem> items = jumpHistoryToolbarItems(
      backLabel: back == null ? null : formatJumpHistoryTime(back),
      forwardLabel: forward == null ? null : formatJumpHistoryTime(forward),
      onBack: () {
        _pokeControlsVisible();
        unawaited(_walkVideoJumpHistory(forward: false));
      },
      onForward: () {
        _pokeControlsVisible();
        unawaited(_walkVideoJumpHistory(forward: true));
      },
      onOpenPanel: () => unawaited(_openVideoJumpHistoryPanel(from)),
    );
    if (items.isEmpty) return const SizedBox.shrink();
    Widget buttonFor(FushiToolbarItem item) {
      final Widget button = _chromeIconButton(
        icon: item.icon,
        desktop: desktop,
        tone: _m3eChrome
            ? VideoM3eButtonTone.secondary
            : VideoM3eButtonTone.neutral,
        onPressed: () => item.onPressed?.call(),
      );
      return KeyedSubtree(
        key: item.key,
        child: FushiTooltip(
          message: item.tooltip ?? item.label,
          child: GestureDetector(
            onLongPress: item.onLongPress,
            onSecondaryTap: item.onLongPress,
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: 1),
              duration: fushiMotionDuration(context, FushiMotion.medium),
              curve: FushiMotion.release,
              builder: (BuildContext _, double v, Widget? child) => Opacity(
                opacity: v.clamp(0.0, 1.0),
                child: Transform.scale(scale: 0.6 + 0.4 * v, child: child),
              ),
              child: Semantics(
                label: item.label,
                excludeSemantics: true,
                button: true,
                onTap: item.onPressed,
                onLongPress: item.onLongPress,
                child: button,
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: EdgeInsetsDirectional.only(end: 8 * _videoUiScale),
      child: VideoGlassSurface(
        enabled: _appleChrome,
        padding: items.length > 1
            ? EdgeInsets.symmetric(horizontal: 4 * _videoUiScale)
            : EdgeInsets.zero,
        child: VideoControlBar(
          key: const ValueKey<String>('video_jump_history_top_bar'),
          fill: false,
          clusterStyle: _m3eFloatingBarStyle(verticalAlignment: 0),
          moreButtonBuilder: (VoidCallback _) => const SizedBox.shrink(),
          entries: <VideoBarEntry>[
            for (final FushiToolbarItem item in items)
              VideoBarEntry(
                cluster: VideoBarCluster.start,
                child: buttonFor(item),
              ),
          ],
        ),
      ),
    );
  }

  /// 进度条上的落点刻度层（与轨道同宽、竖直居中于 [height] 高的盒子；只看不点）。
  /// 设置关掉 / 无历史 / 时长未知时零尺寸。走 notifier 重建（全屏路由同样跟随）。
  Widget _videoJumpProgressMarks({
    required VideoPlayerController controller,
    required double tickWidth,
    required double tickHeight,
    bool rtl = false,
  }) {
    return ListenableBuilder(
      listenable: _videoJumpHistoryRevision,
      builder: (BuildContext _, Widget? __) {
        if (!appModel.jumpHistoryProgressMarks || !_videoJumpHasHistory) {
          return const SizedBox.shrink();
        }
        final int? durationMs = controller.durationMs;
        final ({List<double> back, List<double> forward}) marks =
            jumpHistoryMarkFractions<int>(_videoJumpHistory, (int ms) {
              final double? f = videoJumpMarkFraction(ms, durationMs);
              return f == null || !rtl ? f : 1 - f;
            });
        return FushiJumpProgressMarks(
          back: marks.back,
          forward: marks.forward,
          tickWidth: tickWidth,
          tickHeight: tickHeight,
        );
      },
    );
  }
}
