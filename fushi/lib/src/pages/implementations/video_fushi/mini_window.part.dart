// GENERATED-NOTE: video mini-window / picture-in-picture domain part.
part of '../video_fushi_page.dart';

/// 小窗域：桌面「无边框小窗」+ Android 系统画中画，以及 mini 档下本仓自绘的那套
/// 极简 chrome（顶部拖动带 + 退出钮、居中大三键、视频最下方的细进度条）。
///
/// 两种小窗**共用同一个密度档**（[VideoControlsDensity.mini]）却**不共用 chrome
/// 归属**：桌面小窗里窗口是空的、chrome 得本仓自己画；系统画中画里 Android 会在
/// 窗口上叠自己的播放控件，本仓再画一套就是两层按钮重影。判据收敛在
/// [VideoMiniSurface.systemOwnsChrome] 一处，本文件只消费结论。
///
/// iOS **不提供**系统画中画：本仓的画面是 libmpv 渲染进 Flutter texture 的，
/// iOS 的 `AVPictureInPictureController` 只能挂 `AVPlayerLayer` /
/// `AVSampleBufferDisplayLayer`，拿不到这条纹理；桌面那套「把主窗变小」在 iOS 也
/// 没有对应物。故 iOS 上入口整个不出现（[_miniWindowAvailable] 恒 false），而不是
/// 给一个按下去没反应的按钮。
extension _VideoMiniWindow on _VideoFushiPageState {
  /// 当前小窗表面。
  VideoMiniSurface get _miniWindowSurface => _miniSurface.value;

  /// 是否已经在小窗里（桌面小窗或系统画中画）。
  bool get _inMiniWindow => _miniWindowSurface != VideoMiniSurface.none;

  /// 本机有没有小窗可用：桌面恒有（主窗自己变形）；移动端取决于系统画中画，
  /// 只有 Android 有、且要 API 26+（见 [AndroidPictureInPicture.isSupported]）。
  bool get _miniWindowAvailable =>
      isDesktopPlatform || _pictureInPictureSupported;

  /// 当前画面宽高比；尺寸还没解析出来时退回 16:9（两个平台的小窗几何都要它，
  /// 且都不接受 0 / NaN）。
  double _miniWindowAspectRatio() {
    final VideoPlayerController? controller = _controller;
    final int? width = controller?.videoWidth;
    final int? height = controller?.videoHeight;
    if (width == null || height == null || width <= 0 || height <= 0) {
      return 16 / 9;
    }
    return width / height;
  }

  /// 起播 / 换集后问一次系统画中画可用性，并挂上进出回程。
  ///
  /// 放在 [State.initState] 而不是起播路径上：入口按钮的显隐要在首帧就定下来，
  /// 否则按钮会在用户眼皮底下冒出来。回程订阅同理——系统可以在 app 没参与的情况下
  /// 结束 PiP（用户点小窗上的关闭、或系统回收），漏订阅就会让 [_miniSurface] 永远
  /// 卡在 PiP 态、chrome 再也不回来。
  void _initMiniWindowSupport() {
    if (isDesktopPlatform) {
      // 本地换集 `pushReplacement`：旧页 dispose 晚于本页 initState。上一集在小窗里
      // 就把所有权接过来，旧页的 exit 因 owner 不符 no-op，小窗跨集保持（否则每换
      // 一集——含自动连播——小窗都弹回主窗，而挂角落看番正是小窗的核心场景）。
      if (DesktopMiniWindowMode.claim(owner: this)) {
        _miniSurface.value = VideoMiniSurface.desktopMiniWindow;
      }
      return;
    }
    if (!isMobilePlatform) return;
    _pictureInPictureSub = AndroidPictureInPicture.modeChanges.listen(
      _handlePictureInPictureChanged,
    );
    unawaited(
      AndroidPictureInPicture.isSupported().then((bool supported) {
        if (!mounted || supported == _pictureInPictureSupported) return;
        setState(() => _pictureInPictureSupported = supported);
      }),
    );
  }

  /// 退页清理。桌面小窗必须在这里**同步发起**退出：页面没了、窗口却还是个无边框
  /// 置顶小窗，用户就只能去任务管理器了。
  ///
  /// 画中画订阅的 `cancel()` 刻意留在页面 [State.dispose] 里而不是搬进来：
  /// `cancel_subscriptions` lint 只认**类体内**的取消，写在 part 的 extension 上
  /// 它看不见，会对字段声明报一条假的「未取消」。
  void _disposeMiniWindow() {
    _miniChromeIntroTimer?.cancel();
    _miniChromeIntroTimer = null;
    _miniChromeRevealed.dispose();
    if (DesktopMiniWindowMode.isActive) {
      unawaited(
        DesktopMiniWindowMode.exit(
          owner: this,
          restoreAspectRatioLock: _lockWindowAspectRatio,
        ),
      );
    }
    _miniSurface.dispose();
  }

  /// 系统画中画进出的唯一写入点。
  void _handlePictureInPictureChanged(bool active) {
    if (!mounted) return;
    final VideoMiniSurface next =
        active ? VideoMiniSurface.pictureInPicture : VideoMiniSurface.none;
    if (_miniSurface.value == next) return;
    _miniSurface.value = next;
    // 密度档随表面变，控制条 theme / 字幕避让都要按新几何重算一帧。
    _rebuild(() {});
  }

  /// 切换小窗（快捷键与控制条按钮共用）。
  Future<void> _toggleVideoMiniWindow() async {
    if (_inMiniWindow) {
      await _exitVideoMiniWindow();
      return;
    }
    await _enterVideoMiniWindow();
  }

  /// 进小窗。桌面走主窗变形，移动端走系统画中画。
  Future<void> _enterVideoMiniWindow() async {
    if (_inMiniWindow || !_miniWindowAvailable) return;
    final double aspectRatio = _miniWindowAspectRatio();
    if (isDesktopPlatform) {
      // 小窗与全屏互斥：[DesktopMiniWindowMode.enter] 内部会先退全屏（它持有那条
      // 原语），这里只要保证本页自己的全屏路由也退掉，否则窗口缩成小窗了、栈上却
      // 还压着一张全屏路由，画面会是「小窗里一张全屏页」。
      final BuildContext? fullscreenContext = _videoControlsContext;
      if (_isVideoFullscreenRoute &&
          fullscreenContext != null &&
          fullscreenContext.mounted) {
        await _exitVideoFullscreen(fullscreenContext);
        if (!mounted) return;
      }
      await DesktopMiniWindowMode.enter(owner: this, aspectRatio: aspectRatio);
      if (!mounted) return;
      if (!DesktopMiniWindowMode.isActive) return;
      _miniSurface.value = VideoMiniSurface.desktopMiniWindow;
      // 小窗 chrome 常态不显（hover 不再唤起，见 [videoMiniChromeVisible]），但无边框
      // 小窗**没有系统标题栏**——第一次进来时若一个 chrome 都不出现，用户看不到退出钮、
      // 也找不到拖动带，只剩「记不记得快捷键」。故进小窗时引导性地亮一次再自行淡出：
      // 常态清爽与「有退路」两件事不冲突。换集认领（[_initMiniWindowSupport]）不走这里，
      // 免得每集都闪一下。
      _revealMiniChromeBriefly();
      _rebuild(() {});
      return;
    }
    // 移动端：只发请求，**不在这里置位**——真正进没进 PiP 由系统说了算，
    // 状态统一由 [_handlePictureInPictureChanged] 的回程写入。
    await AndroidPictureInPicture.enter(aspectRatio: aspectRatio);
  }

  /// 退小窗。系统画中画没有「从 app 内退出」的 API（只能由用户或系统结束），
  /// 故移动端这里只是 no-op，不假装做得到。
  Future<void> _exitVideoMiniWindow() async {
    if (_miniWindowSurface != VideoMiniSurface.desktopMiniWindow) return;
    await DesktopMiniWindowMode.exit(
      owner: this,
      restoreAspectRatioLock: _lockWindowAspectRatio,
    );
    if (!mounted) return;
    _miniSurface.value = VideoMiniSurface.none;
    _resetMiniChrome();
    _rebuild(() {});
  }

  /// 换集 / 换源后把小窗几何更新到新画面比例（非小窗态 no-op）。
  Future<void> _syncMiniWindowAspectRatio() async {
    if (_miniWindowSurface != VideoMiniSurface.desktopMiniWindow) return;
    await DesktopMiniWindowMode.updateAspectRatio(_miniWindowAspectRatio());
  }

  // ── mini 档自绘 chrome ──────────────────────────────────────────────────

  /// 切换 mini chrome 显隐（快捷键 [ShortcutAction.videoToggleMiniChrome] 的执行体）。
  ///
  /// 只在**本仓负责画 chrome** 的那一档有意义：常规窗口里 chrome 归 media_kit（hover
  /// 唤起是那边的语义），系统画中画里归系统。两种情形一律早退，而不是翻一个没人读的
  /// 标志位——否则从小窗退回主窗后再进小窗，chrome 会带着上一次在主窗里按出来的状态。
  void _toggleMiniChrome() {
    // 只对桌面小窗表面：常规窄窗口的 mini 档 chrome 跟 hover 走（见
    // [videoMiniChromeVisible]），翻这个标志位在那里没人读。
    if (_miniWindowSurface != VideoMiniSurface.desktopMiniWindow) return;
    _miniChromeIntroTimer?.cancel();
    _miniChromeIntroTimer = null;
    _miniChromeRevealed.value = !_miniChromeRevealed.value;
  }

  /// 进小窗时把 chrome 亮出来一小会儿再自行收起（唯一的自动显隐路径）。
  void _revealMiniChromeBriefly() {
    _miniChromeIntroTimer?.cancel();
    _miniChromeRevealed.value = true;
    _miniChromeIntroTimer = Timer(
      _VideoFushiPageState._miniChromeIntroDuration,
      () {
        _miniChromeIntroTimer = null;
        if (!mounted) return;
        _miniChromeRevealed.value = false;
      },
    );
  }

  /// 退小窗复位：下次进小窗从「常态清爽」开始，不继承上一次按出来的显隐状态。
  void _resetMiniChrome() {
    _miniChromeIntroTimer?.cancel();
    _miniChromeIntroTimer = null;
    _miniChromeRevealed.value = false;
  }

  /// mini 档顶部那条带：整条可拖动窗口 + 右端一个「退出小窗」钮。
  ///
  /// 拖动带只占顶部一条，不是整个画面：整面拖动会把「点画面暂停」「点字幕查词」
  /// 一起吃掉——而字幕悬停制卡正是小窗要保住的能力（[VideoSubtitleOverlay] 就在
  /// 本层之下的同一棵 Stack 里，零改动继续工作）。
  Widget _buildMiniWindowTopChrome() {
    final VideoControlsDensitySpec density = _controlsDensity;
    if (!density.showCenterTransport) return const SizedBox.shrink();
    // 这条带（拖动入口 + 退出钮）是桌面小窗专属：常规窗口被挤窄到 mini 档时自己有
    // 标题栏可拖、也没有小窗可退——画出来只剩一条没用的渐变，退出钮还是死的
    // （_exitVideoMiniWindow 因 surface≠desktopMiniWindow 早退）。
    if (_miniWindowSurface != VideoMiniSurface.desktopMiniWindow) {
      return const SizedBox.shrink();
    }
    final double height = 32 * _videoUiScale;
    final Widget bar = SizedBox(
      height: height,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[Color(0x73000000), Color(0x00000000)],
          ),
        ),
        child: Row(
          children: <Widget>[
            const Spacer(),
            _miniWindowIconButton(
              icon: Icons.close_fullscreen_rounded,
              tooltip: t.video_mini_window_exit,
              onPressed: () => unawaited(_exitVideoMiniWindow()),
            ),
          ],
        ),
      ),
    );
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: ListenableBuilder(
        // 桌面小窗里显隐只认显式唤出（快捷键 / 进小窗那次引导），**不认 hover**——
        // 否则鼠标从角落里的小窗上扫过就弹一层按钮，正是用户报的「太乱」。常规窗口
        // 被挤窄到 mini 档（surface none）则跟 hover 走——见 [videoMiniChromeVisible]
        // 的第二道门。判据是纯函数，页面与测试同源。
        listenable: Listenable.merge(<Listenable>[
          _miniChromeRevealed,
          _videoControlsVisible,
        ]),
        builder: (BuildContext context, _) => FadingChromeGate(
          visible: videoMiniChromeVisible(
            spec: density,
            surface: _miniWindowSurface,
            revealed: _miniChromeRevealed.value,
            controlsVisible: _videoControlsVisible.value,
          ),
          duration: _videoControlsTransitionDuration,
          // 桌面小窗是无边框的，系统不再提供标题栏抓手，这条带就是唯一的拖动入口。
          // 移动端（系统画中画）永远走不到这里：那边 showCenterTransport 恒 false。
          // 不用 window_manager 的 DragToMoveArea：它自带 onDoubleTap → maximize()，
          // 双击拖动带会把置顶无边框的小窗直接最大化成铺满整屏的 mini chrome，退出
          // 时再对一个最大化态窗口 setBounds 得到畸形态。只要拖动。
          child: isDesktopPlatform
              ? GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onPanStart: (_) => unawaited(windowManager.startDragging()),
                  child: bar,
                )
              : bar,
        ),
      ),
    );
  }

  /// mini 档居中大三键（回退 N 秒 / 播放暂停 / 前进 N 秒），即系统画中画那种观感。
  ///
  /// 不复用底部那条 [_centeredBottomControlBar]：mini 档整行底栏已被 theme 收掉
  /// （小窗里一条 56px 的按钮行能吃掉画面的三分之一），这三个键改用居中大圆钮，
  /// 触达面积反而比底栏更大。
  Widget _buildMiniWindowCenterControls(VideoPlayerController controller) {
    final VideoControlsDensitySpec density = _controlsDensity;
    if (!density.showCenterTransport) return const SizedBox.shrink();
    final ColorScheme cs = _videoChromeColorScheme(context);
    // 与底栏那两个 ±10s 键同一个常量（见 [_buildBottomSlotButton] 的
    // seekBackward / seekForward 分支）：小窗里换个位置，语义必须还是同一个键。
    const int seekMs = 10000;
    return Positioned.fill(
      child: ListenableBuilder(
        // 与顶部那条带同源：桌面小窗只认显式唤出、常规窄窗口跟 hover（见
        // [videoMiniChromeVisible]）。
        listenable: Listenable.merge(<Listenable>[
          _miniChromeRevealed,
          _videoControlsVisible,
        ]),
        builder: (BuildContext context, _) => FadingChromeGate(
          visible: videoMiniChromeVisible(
            spec: density,
            surface: _miniWindowSurface,
            revealed: _miniChromeRevealed.value,
            controlsVisible: _videoControlsVisible.value,
          ),
          duration: _videoControlsTransitionDuration,
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _miniWindowRoundButton(
                  icon: Icons.fast_rewind_rounded,
                  tooltip: t.video_bottom_seek_back,
                  colorScheme: cs,
                  onPressed: () => unawaited(_seekRelative(-seekMs)),
                ),
                SizedBox(width: 16 * _videoUiScale),
                ListenableBuilder(
                  listenable: controller,
                  builder: (BuildContext context, _) => _miniWindowRoundButton(
                    icon: controller.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    tooltip: t.video_bottom_play_pause,
                    colorScheme: cs,
                    primary: true,
                    // 不再 [_pokeControlsVisible]：mini chrome 的显隐已与 media_kit
                    // 控制条解绑（[videoMiniChromeVisible]），续命那条控制条在小窗里
                    // 既画不出东西、又会让字幕为它避让一格。
                    onPressed: () => unawaited(controller.playOrPause()),
                  ),
                ),
                SizedBox(width: 16 * _videoUiScale),
                _miniWindowRoundButton(
                  icon: Icons.fast_forward_rounded,
                  tooltip: t.video_bottom_seek_forward,
                  colorScheme: cs,
                  onPressed: () => unawaited(_seekRelative(seekMs)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 视频最下方那条主题色细进度条（开关 + mini 档的进度指示，见
  /// [videoSlimProgressBarVisible]）。
  ///
  /// 挂在 controls Stack 里而不是 Video 外层：全屏路由复用同一个 controls builder，
  /// 挂这里全屏时也跟着走；且它与控制条读同一个 [_videoControlsVisible]，不会出现
  /// 「控制条已经回来了、细线还挂着」的重影。
  Widget _buildVideoSlimProgressBar(VideoPlayerController controller) {
    final VideoControlsDensitySpec density = _controlsDensity;
    final bool enabled = appModel.videoSlimProgressBar;
    final ColorScheme cs = _videoChromeColorScheme(context);
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      // 细线吃不吃指针要跟着四个遮挡门控走，而它们**不改** [_videoControlsVisible]
      // 之外的任何东西 → 只订阅可见性会漏：控制条本就隐着时开沉浸锁，可见性没变、
      // 细线却该立刻停止接受 seek。细线挂在 media_kit 控制条那层 [IgnorePointer]
      // **之外**，不在这里订阅就是这四个门控唯一漏掉的可点区。
      child: ListenableBuilder(
        listenable: Listenable.merge(<Listenable>[
          _immersiveLocked,
          _videoSidePanel,
          _episodeListVisible,
          _videoControlEditMode,
        ]),
        builder: (BuildContext context, _) {
          final bool interactive = !_immersiveLocked.value &&
              _videoSidePanel.value == null &&
              !_episodeListVisible.value &&
              !_videoControlEditMode.value;
          return ValueListenableBuilder<bool>(
            valueListenable: _videoControlsVisible,
            builder: (BuildContext context, bool controlsVisible, _) {
              final bool visible = videoSlimProgressBarVisible(
                spec: density,
                surface: _miniWindowSurface,
                preferenceEnabled: enabled,
                controlsVisible: controlsVisible,
              );
              if (!visible) return const SizedBox.shrink();
              return VideoSlimProgressBar(
                positionMs: () => controller.positionMs,
                durationMs: () => controller.durationMs,
                // 播放器 chrome 的「主题色」口径：裸压固定深色 scrim 的前景必须取亮 tone
                // primary，直接用 cs.primary 在浅色 / eink 主题下是深色、黑压黑不可见。
                color: _videoChromeAccent(cs),
                height: 3 * _videoUiScale,
                // 点 / 横拖这条线直接跳转（小窗里它是唯一的进度控件，常规档它是控制条
                // 淡出后唯一还在的那条）。命中带随「界面大小」一起缩放，与线本身同源。
                hitTestHeight: 12 * _videoUiScale,
                onSeekFraction: interactive
                    ? (double fraction) =>
                        unawaited(_seekToProgressFraction(fraction))
                    : null,
              );
            },
          );
        },
      ),
    );
  }

  Widget _miniWindowIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      icon: Icon(icon),
      iconSize: 18 * _videoUiScale,
      color: videoChromeNeutralForeground,
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.all(4 * _videoUiScale),
      constraints: const BoxConstraints(),
    );
  }

  Widget _miniWindowRoundButton({
    required IconData icon,
    required String tooltip,
    required ColorScheme colorScheme,
    required VoidCallback onPressed,
    bool primary = false,
  }) {
    final double size = (primary ? 56 : 40) * _videoUiScale;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: _osdSurfaceColor(colorScheme),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(
              icon,
              size: size * 0.5,
              color: videoChromeNeutralForeground,
            ),
          ),
        ),
      ),
    );
  }
}
