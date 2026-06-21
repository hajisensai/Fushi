// GENERATED-NOTE: extracted from video_hibiki_page.dart (TODO-590 batch15).
part of '../video_hibiki_page.dart';

/// Fullscreen domain methods extracted via part-of (TODO-590 batch15); shared
/// private scope. Behaviour-preserving: every body is moved character-for-
/// character except the two `State.setState(...)` rebuilds inside
/// [_pushNeutralizedVideoFullscreen] (`_videoFullscreenActive = true`) and
/// [_onVideoFullscreenRouteClosed] (`_videoFullscreenActive = false`), which are
/// routed through the main shell's `_rebuild(...)` forwarder — the established
/// part paradigm, since an extension cannot call the @protected `State.setState`
/// directly. No `@override` member is moved, so no forwarder is needed; no host
/// `static` member is referenced, so no `_VideoHibikiPageState.`-qualification is
/// required (unlike batch11/12). Every symbol the bodies touch is an instance
/// getter/field/method resolved through the shared private scope (`isFullscreen`,
/// `exitFullscreen`, `isMobilePlatform`, `_videoFullscreenTransitioning`,
/// `_videoFullscreenActive`, `_videoFullscreenRoute`, `_controller`,
/// `_refocusVideo`, `_videoWithSubtitlePanel`, `_videoFitMode`,
/// `videoFitModeToBoxFit`, `_videoControlIconSize`, `_handleBackOrExit`,
/// `defaultEnterNativeFullscreen`, `defaultExitNativeFullscreen`, etc.).
///
/// Covers the self-built fullscreen-route lifecycle
/// ([_toggleVideoFullscreen] / [_pushNeutralizedVideoFullscreen] /
/// [_onVideoFullscreenRouteClosed] / [_exitVideoFullscreen]), the fullscreen
/// toggle button ([_buildFullscreenButton]), and the orientation/immersive
/// native-fullscreen enter/exit callbacks that replace media_kit defaults
/// ([_enterVideoNativeFullscreen] / [_exitVideoNativeFullscreen]).
///
/// The orientation lifecycle helpers that bracket the native callbacks
/// ([_lockLandscapeForVideo] / [_applyVideoImmersiveMode] /
/// [_restoreOrientationOnExit]) intentionally stay in the main shell — they are
/// page enter/exit orientation ownership, not fullscreen toggling. The dangling
/// doc comment that was orphaned above `_toggleVideoFullscreen` (it describes the
/// desktop controls theme, whose method `_desktopControlsTheme` left for
/// controls_theme.part.dart in batch11) is left untouched in the main shell — it
/// is a batch11 leftover, not part of this fullscreen block, so it is not moved.
extension _VideoFullscreen on _VideoHibikiPageState {
  Future<void> _toggleVideoFullscreen(BuildContext context) {
    // BUG-221: 移动端永不进 media_kit 全屏路由（横屏沉浸态即唯一形态）。统一在此单一收口
    // no-op，杜绝任何入口（双击 / 全屏按钮 / 快捷键 / 右键菜单）把移动端推进全屏路由——
    // 全屏路由会带来「退全屏弹回竖屏」与「全屏 PopScope 吞第一次返回的两段式退出」。桌面
    // 不受影响（窗口全屏走 native window，返回行为本就合理）。
    if (isMobilePlatform) return Future<void>.value();
    return isFullscreen(context)
        ? _exitVideoFullscreen(context)
        : _pushNeutralizedVideoFullscreen(context);
  }

  Future<void> _pushNeutralizedVideoFullscreen(BuildContext context) async {
    if (_videoFullscreenTransitioning || isFullscreen(context)) return;
    if (!context.mounted) return;
    _videoFullscreenTransitioning = true;
    final VideoStateInheritedWidget inherited = VideoStateInheritedWidget.of(
      context,
    );
    final VideoState stateValue = inherited.state;
    final contextNotifierValue = inherited.contextNotifier;
    final videoViewParametersNotifierValue =
        inherited.videoViewParametersNotifier;
    final VideoController controllerValue = stateValue.widget.controller;
    // 字幕跳转列表「真 push-aside」（TODO-121）在全屏路由里也要包裹自建的 Video，需本页
    // 持有的 [VideoPlayerController]（face：cues / currentCueIndex / skipToCue）。全屏只在
    // 播放中触发、_controller 必非空，缺失则退化为不包面板（画面占满，等价旧全屏）。
    final VideoPlayerController? playerController = _controller;
    final Future<void> Function() enterNativeFullscreen =
        stateValue.widget.onEnterFullscreen;
    final Future<void> Function() exitNativeFullscreen =
        stateValue.widget.onExitFullscreen;
    final MaterialVideoControlsTheme? mobileTheme =
        MaterialVideoControlsTheme.maybeOf(context);
    final MaterialDesktopVideoControlsTheme? desktopTheme =
        MaterialDesktopVideoControlsTheme.maybeOf(context);

    try {
      // 先置位再 push：同一帧里窗口侧 controls 经 [VideoControlsFocusGate] 卸载、
      // 全屏侧 controls 挂载，保证共享 [_videoFocusNode] 任意时刻只被一个 Focus
      // 持有（见 _videoFullscreenActive 的文档）。
      if (mounted) _rebuild(() => _videoFullscreenActive = true);
      final PageRouteBuilder<void> fullscreenRoute = PageRouteBuilder<void>(
        pageBuilder: (_, __, ___) => Material(
          child: HibikiAppUiScaleNeutralizer(
            child: MaterialVideoControlsTheme(
              normal:
                  mobileTheme?.normal ?? kDefaultMaterialVideoControlsThemeData,
              fullscreen: mobileTheme?.fullscreen ??
                  kDefaultMaterialVideoControlsThemeDataFullscreen,
              child: MaterialDesktopVideoControlsTheme(
                normal: desktopTheme?.normal ??
                    kDefaultMaterialDesktopVideoControlsThemeData,
                fullscreen: desktopTheme?.fullscreen ??
                    kDefaultMaterialDesktopVideoControlsThemeDataFullscreen,
                child: VideoStateInheritedWidget(
                  state: stateValue,
                  contextNotifier: contextNotifierValue,
                  videoViewParametersNotifier: videoViewParametersNotifierValue,
                  disposeNotifiers: false,
                  child: FullscreenInheritedWidget(
                    parent: stateValue,
                    child: VideoStateInheritedWidget(
                      state: stateValue,
                      contextNotifier: contextNotifierValue,
                      videoViewParametersNotifier:
                          videoViewParametersNotifierValue,
                      disposeNotifiers: false,
                      child: ValueListenableBuilder<VideoViewParameters>(
                        valueListenable: videoViewParametersNotifierValue,
                        builder:
                            (BuildContext _, VideoViewParameters params, __) {
                          final Widget fullscreenVideo = Video(
                            controller: controllerValue,
                            width: null,
                            height: null,
                            // 全屏 fit 跟随窗口同一 [_videoFitMode] 偏好（TODO-152 子B），
                            // 不再用 notifier 默认 `params.fit`（contain）——保证用户选的
                            // 画面比例在窗口与全屏一致。其余 params 字段（fill/alignment
                            // /aspectRatio 等）照旧走 notifier。
                            fit: videoFitModeToBoxFit(_videoFitMode),
                            fill: params.fill,
                            alignment: params.alignment,
                            aspectRatio: params.aspectRatio,
                            filterQuality: params.filterQuality,
                            controls: params.controls,
                            wakelock: false,
                            // 全屏路由也显式禁用内置 SubtitleView（TODO-080/092，
                            // BUG-190）。虽然与窗口侧共享同一
                            // videoViewParametersNotifier（窗口侧已设 visible:false 会
                            // 传播过来），但这里不依赖隐式传播，直接覆盖成 visible:false
                            // 消除「全屏路由快照时窗口侧 didUpdate 尚未把配置写进
                            // notifier」的时机竞态——字幕在全屏也只由可点 overlay 承载。
                            subtitleViewConfiguration:
                                const SubtitleViewConfiguration(visible: false),
                            focusNode: params.focusNode,
                            onEnterFullscreen: enterNativeFullscreen,
                            onExitFullscreen: exitNativeFullscreen,
                          );
                          // 字幕跳转列表「真 push-aside」（TODO-121）：全屏路由自建的
                          // Video 同样包进 Row[Expanded(Video), 面板列]，面板可见时全屏
                          // 画面真挤窄、不被遮（与窗口侧 [_buildVideoBody] 同一 helper）。
                          //
                          // 音量/亮度 HUD 与 mpv 式 OSD 不在这里重挂：全屏 Video 设
                          // `controls: params.controls`（共享窗口侧同一 controls builder
                          // [_buildVideoControls]），其内 [_buildVideoControlsInner] 已
                          // 无门控挂载 [_buildLevelHudOverlay] / [_buildOsdOverlay]，且
                          // [VideoControlsFocusGate] 只在窗口侧（`!inFullscreenRoute`）
                          // 卸载 controls、全屏侧返回 child 照常渲染。故全屏 HUD 由共享
                          // controls 提供，勿在此重复挂一层（TODO-563 复核：重挂会双叠）。
                          if (playerController == null) return fullscreenVideo;
                          return _videoWithSubtitlePanel(
                            playerController,
                            fullscreenVideo,
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      );
      _videoFullscreenRoute = fullscreenRoute;
      // 全屏路由关闭的唯一汇聚点：Esc / F / 全屏按钮 / 双击 / 系统返回全部
      // 经由路由 future 完成，无论哪条退出路径都在这里复位 + 归还焦点。
      Navigator.of(
        context,
        rootNavigator: true,
      ).push<void>(fullscreenRoute).whenComplete(_onVideoFullscreenRouteClosed);
      await enterNativeFullscreen();
    } finally {
      _videoFullscreenTransitioning = false;
      // post-frame：等全屏路由 build 完、共享节点被全屏侧 Focus attach+reparent 之后
      // 再 requestFocus。同步调用可能跑在路由 build 之前——随后的 reparent 会把
      // primary focus 丢给全屏路由的 ModalScope，进全屏后快捷键直接死掉（实测见
      // video_fullscreen_focus_gate_test.dart 的机制复现）。
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _refocusVideo());
      }
    }
  }

  /// 全屏路由从栈上消失后：复位 [_videoFullscreenActive] 让窗口侧 controls 重挂
  /// （其 [Focus] 在 initState 重新 attach [_videoFocusNode]），并在重挂完成的
  /// 下一帧把键盘焦点收回视频。这是所有退全屏路径共用的收口，替代在每个退出
  /// 入口各补一次 refocus。
  void _onVideoFullscreenRouteClosed() {
    _videoFullscreenRoute = null;
    if (!mounted) return;
    _rebuild(() => _videoFullscreenActive = false);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refocusVideo());
  }

  Future<void> _exitVideoFullscreen(BuildContext context) async {
    if (_videoFullscreenTransitioning || !isFullscreen(context)) return;
    if (!context.mounted) return;
    _videoFullscreenTransitioning = true;
    try {
      await Navigator.of(context).maybePop();
      if (context.mounted) {
        FullscreenInheritedWidget.of(context).parent.refreshView();
      }
    } finally {
      _videoFullscreenTransitioning = false;
      // 焦点归还由 [_onVideoFullscreenRouteClosed]（路由 future 收口）负责：
      // 此刻窗口侧 controls 可能尚未重挂，节点仍是孤儿，这里 refocus 只是兜底。
      if (mounted) _refocusVideo();
    }
  }

  Widget _buildFullscreenButton({required bool desktop}) {
    // BUG-221: 移动端不提供全屏按钮。移动端视频全程横屏沉浸（[_lockLandscapeForVideo] +
    // [_applyVideoImmersiveMode]），画面已占满，「全屏」无额外语义；进 media_kit 全屏路由
    // 反而引入「退全屏弹回竖屏 + 两段式返回」（全屏路由吞第一次返回）。移动端永不进全屏，
    // 故隐藏入口（与双击不再全屏、[_toggleVideoFullscreen] 移动端 no-op 一致）。
    if (isMobilePlatform) return const SizedBox.shrink();
    return Builder(
      builder: (BuildContext buttonContext) {
        final Widget icon = Icon(
          isFullscreen(buttonContext)
              ? Icons.fullscreen_exit
              : Icons.fullscreen,
          size: _videoControlIconSize,
        );
        return desktop
            ? MaterialDesktopCustomButton(
                icon: icon,
                onPressed: () =>
                    unawaited(_toggleVideoFullscreen(buttonContext)),
              )
            : MaterialCustomButton(
                icon: icon,
                onPressed: () =>
                    unawaited(_toggleVideoFullscreen(buttonContext)),
              );
      },
    );
  }

  /// BUG-221: media_kit 全屏「进入」回调，**替换** media_kit 默认
  /// [defaultEnterNativeFullscreen]。窗口侧与自建全屏路由的 [Video] 都传这个，
  /// 经由 media_kit 的 `state.widget.onEnterFullscreen` 链路生效。
  ///
  /// 移动端：语义与 [_lockLandscapeForVideo] + [_applyVideoImmersiveMode] 一致——
  /// 只允许两个横屏 + 沉浸隐栏，**永不 `setPreferredOrientations([])`**（病根是
  /// media_kit 默认退全屏时放开全部方向把设备弹回竖屏）。
  ///
  /// 桌面：**保留** media_kit 默认 [defaultEnterNativeFullscreen]，它经 MethodChannel
  /// `Utils.EnterNativeFullscreen` 把 OS 窗口切真原生全屏（覆盖任务栏）。桌面分支不碰
  /// 设备方向，无竖屏问题；之前若在桌面 no-op 会悄悄砍掉桌面「全屏 = OS 窗口真全屏」
  /// （改动前窗口侧 Video 未传回调、落 media_kit 默认 = 桌面真全屏），属本修复范围外的
  /// 桌面回归，故桌面转调默认回调原样保留。
  Future<void> _enterVideoNativeFullscreen() async {
    if (!isMobilePlatform) return defaultEnterNativeFullscreen();
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.immersiveSticky,
      overlays: <SystemUiOverlay>[],
    );
    await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  /// BUG-221: media_kit 全屏「退出」回调，**替换** media_kit 默认
  /// [defaultExitNativeFullscreen]。
  ///
  /// 移动端：media_kit 默认退全屏时调 `setPreferredOrientations([])` 放开全部方向
  /// （含竖屏/倒置），让设备转回竖屏 = 用户感知的「竖屏模式」。本回调退全屏时**仍只允许
  /// 两个横屏**（视频页全程横屏，方向唯一拥有者），系统栏保持沉浸隐藏（与窗口态一致，
  /// 不在退全屏瞬间闪回系统栏）。真正放开方向交给退页时的 [_restoreOrientationOnExit]。
  ///
  /// 桌面：**保留** media_kit 默认 [defaultExitNativeFullscreen]（MethodChannel
  /// `Utils.ExitNativeFullscreen` 把 OS 窗口还原回非全屏），与进入回调对称。桌面分支不碰
  /// 设备方向，无竖屏问题。
  Future<void> _exitVideoNativeFullscreen() async {
    if (!isMobilePlatform) return defaultExitNativeFullscreen();
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.immersiveSticky,
      overlays: <SystemUiOverlay>[],
    );
    await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }
}
