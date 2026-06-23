// GENERATED-NOTE: extracted from video_hibiki_page.dart (TODO-590 batch16).
part of '../video_hibiki_page.dart';

/// Video-layout / render-tree domain methods extracted via part-of (TODO-590
/// batch16); shared private scope. Behaviour-preserving: every body is moved
/// character-for-character with no edits — no `State.setState(...)` call lives in
/// this block (only a doc comment in [_buildSideLockButton] mentions setState),
/// so no `_rebuild(...)` forwarder is needed; no `@override` member is moved, so
/// no forwarder is needed; no host `static` member is referenced, so no
/// `_VideoHibikiPageState.`-qualification is required (unlike batch11/12). Every
/// symbol the bodies touch is an instance getter/field/method resolved through
/// the shared private scope.
///
/// This is the tail render-tree block: the contiguous run from [_buildVideoBody]
/// through [_buildSideLockButton] (the last method in the file). It covers the
/// page body and the full media_kit-controls subtree that ride into the
/// fullscreen route via the shared controls builder: the video body
/// ([_buildVideoBody]), the controls wrappers and inner tree
/// ([_buildVideoControls] / [_videoControlsHoverWrap] / [_buildCursorOverlay] /
/// [_buildVideoControlsInner]), the right-edge action rail and its hover
/// keep-alive helpers ([_railHoverKeepAlive] / [_lockButtonHoverKeepAlive] /
/// [_buildVideoSideActionRail] / [_buildVideoSideRailFor] /
/// [_mergeRailSafeAreaPadding]), the push-aside subtitle/episode side-panel
/// layout ([_videoWithSubtitlePanel]) and the left side lock button
/// ([_buildSideLockButton]).
///
/// `build(BuildContext)` (the @override entry point) stays in the main shell — it
/// only delegates to [_buildScaffold]. [_buildScaffold] / [_pageDropTarget] and
/// the pointer/gesture handlers ([_handleVideoPointerUp] / [_handleDoubleTapSeek]
/// / [_isVideoChromePointer] / [_handleSecondaryTap] / [_buildVideoContextMenuItems])
/// also stay in the main shell: they sit between `build` and [_buildVideoBody] and
/// are not part of this contiguous render-tree run (cutting them would require
/// splitting a non-contiguous subset).
extension _VideoLayout on _VideoHibikiPageState {
  /// 视频本体：media_kit [Video] + 可点字幕 overlay。查词浮层栈不在这里渲染——它走
  /// 根 Overlay（[_syncPopupOverlay] / [_buildPopupOverlay]），以便全屏时浮在全屏
  /// 路由之上。每次 build 在 post-frame 同步根 Overlay 与当前栈。
  Widget _buildVideoBody(
    VideoPlayerController controller,
    VideoController videoController,
  ) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncPopupOverlay());
    final ({
      MaterialVideoControlsThemeData mobile,
      MaterialDesktopVideoControlsThemeData desktop,
    }) controlsTheme = _currentVideoControlsTheme(
      controller,
      _controlLayout,
    );
    // 两层主题嵌套：[AdaptiveVideoControls] 按平台互斥择一渲染（桌面读 Desktop
    // 主题、移动读 Material 主题），故同时提供两套互不干扰，让字幕/音轨/设置入口
    // 在桌面、移动、全屏三种场景都可达。嵌套顺序不影响——各自被对应平台 controls 读取。
    // 'B' 切换字幕模糊（TODO-134）现已并入可重映射注册表（video scope），随其它视频键
    // 一起经 media_kit 的 keyboardShortcuts 整表安装，不再需要本页内层的独立
    // CallbackShortcuts；press-edge-only（includeRepeats:false）由
    // buildVideoPlayerShortcutsFromRegistry 对该 action 保留。
    return VideoControlsThemePair(
      mobile: controlsTheme.mobile,
      desktop: controlsTheme.desktop,
      // 字幕跳转列表「真 push-aside」（TODO-121）：面板可见时把 Video 包进
      // Row[Expanded(Video), 面板列]，画面真挤窄、不被遮（见 [_videoWithSubtitlePanel]）。
      child: _videoWithSubtitlePanel(
        controller,
        Video(
          controller: videoController,
          // 用本页持有的 FocusNode 替换 Video 内置的匿名节点，以便覆盖层（对话框 /
          // bottom sheet / 文件选择器）关闭后能主动把键盘焦点还给它，恢复空格等内置
          // 快捷键（见 [_refocusVideo]）。
          focusNode: _videoFocusNode,
          // 禁用 media_kit 内置 SubtitleView（TODO-080/092，BUG-190）：字幕统一由
          // [VideoSubtitleOverlay] 单层承载（cue 同步 + 逐字查词）。SubtitleView 默认
          // visible:true，会把 libmpv 解析的字幕渲染成一整块不可点 Text（白字 +
          // 0xaa000000 半透明黑底），叠在可点 overlay 之上 → 点字幕穿透到 media_kit
          // 自己的手势层（落句首词/点不到句中/呼出键盘，080-3）、随字幕轨异步刷新时有
          // 时无（080-1 随机透明）、横竖屏 Video 子树重建时残留黑底（092）。这里显式
          // visible:false 让 video_texture.dart 的 `if(...visible && ...)` 不渲染
          // SubtitleView；窗口与全屏共享 videoViewParametersNotifier，全屏路由侧再显式
          // 覆盖一次（不靠隐式传播，消除快照时机竞态）。
          subtitleViewConfiguration: const SubtitleViewConfiguration(
            visible: false,
          ),
          // 窗口模式画面缩放/比例由用户偏好 [_videoFitMode] 决定（TODO-152 子B），
          // 新安装默认 [VideoFitMode.contain] → `BoxFit.contain` 保持比例完整适应；
          // 已有用户偏好 [cover]/[fill] 会按持久化值恢复；
          // 不会被新安装初始值覆盖。
          // 根因背景：media_kit 默认 `BoxFit.contain` 在「媒体框宽高比 ≠ 视频宽高比」时
          // 两侧补黑。桌面虽有窗口比例锁（[_syncWindowAspectRatioLock] → window_manager
          // `setAspectRatio`），但其 Windows 实现只在用户**拖动窗口边框**时（WM_SIZING）
          // 约束比例、不矫正当前窗口尺寸 → 非全屏非最大化的当前窗口若比例不等于视频，
          // contain 仍留黑边（平台限制）。用户改选 [VideoFitMode.cover] 即铺满并裁切
          // 超出边缘（比例锁稳态下窗口贴合视频比例 → cover≈contain 几乎不裁）；
          // [VideoFitMode.fill] 则拉伸填满。
          // 字幕是独立 overlay 层（[VideoSubtitleOverlay]，不在 [Video] 内）不受裁切影响。
          // 全屏路由的 Video 在其 builder 内读同一 [_videoFitMode] 换算，跟随同偏好。
          fit: videoFitModeToBoxFit(_videoFitMode),
          // letterbox/pillarbox 填充色固定纯黑（TODO-053）：cover 稳态下无外围，但
          // 视频解码前 / 极端比例残留边缘仍按播放器惯例用黑底，不跟随主题 surface。
          fill: Colors.black,
          // 字幕 overlay + 拖拽挂载都包进 controls builder：media_kit 全屏推独立 root
          // 路由并复用同一 controls，故 overlay 随全屏一起进路由，全屏时字幕仍显示且
          // 可点查词、拖字幕也能挂载（见 [_buildVideoControls]）。
          controls: (VideoState state) =>
              _buildVideoControls(state, controller),
          // BUG-221: 替换 media_kit 默认全屏方向回调，禁止移动端退全屏时
          // `setPreferredOrientations([])` 弹回竖屏。自建全屏路由（[_pushNeutralizedVideoFullscreen]）
          // 经 `state.widget.onEnterFullscreen`/`onExitFullscreen` 取的就是这俩，故窗口侧设
          // 一次即覆盖全部全屏方向行为。移动端门控在 helper 内（只锁横屏，永不放开方向）；
          // 桌面转调 media_kit 默认回调，保留「全屏 = OS 窗口真全屏」（不碰设备方向）。
          onEnterFullscreen: _enterVideoNativeFullscreen,
          onExitFullscreen: _exitVideoNativeFullscreen,
        ),
      ),
    );
  }

  /// media_kit `controls` builder：默认桌面控制条 + 可点字幕 [VideoSubtitleOverlay]
  /// 叠加。返回的 widget 同时用于普通与全屏路由（media_kit 复用同一 builder），
  /// 故全屏时字幕一并显示。
  Widget _buildVideoControls(
    VideoState state,
    VideoPlayerController controller,
  ) {
    // 拖字幕文件到正在播放的视频上 → 即时挂载（asbplayer 式）。包在 controls
    // overlay 层（而非 [_buildVideoBody] 外层）：media_kit 全屏推独立 root 路由、
    // 复用同一 controls builder，故拖拽目标随全屏一起进路由——窗口与全屏两种场景
    // 用同一个目标都能挂载（覆盖 overlay 即视频可视区）。仅桌面三端启用
    // （[HibikiFileDropTarget] 内部门控），其余平台透传 child 零开销。只取第一个
    // 受支持字幕；拖入纯视频/图片等忽略。desktop_drop 只接管 OS 文件拖放、不吃
    // Flutter 指针事件，故内层字幕点击查词（onCharTap）不受影响；不夺焦故无需
    // _refocusVideo。
    //
    // [VideoControlsFocusGate]：全屏路由在栈上时卸载窗口侧本子树（全屏侧实例因
    // 能看到 FullscreenInheritedWidget 不受影响），保证共享 [_videoFocusNode]
    // 任意时刻只被一个 Focus 持有——否则退全屏后节点被摘成永久孤儿、全部快捷键
    // 死亡（见 gate 的类文档，TODO-040/042 根因）。顺带保证 [_videoControlsContext]
    // 在全屏期间必是全屏子树的 context（窗口侧 Builder 不再运行），Esc/F 的
    // isFullscreen 判定不会被窗口侧重建覆写。
    return VideoControlsFocusGate(
      fullscreenRouteActive: _videoFullscreenActive,
      child: _buildVideoControlsInner(state, controller),
    );
  }

  ({
    MaterialVideoControlsThemeData mobile,
    MaterialDesktopVideoControlsThemeData desktop,
  }) _currentVideoControlsTheme(
    VideoPlayerController controller,
    VideoControlLayout layout,
  ) {
    return (
      mobile: _mobileControlsTheme(controller, layout),
      desktop: _desktopControlsTheme(controller, layout),
    );
  }

  /// 桌面 hover 追踪层（TODO-129）：覆盖整个视频控制区，镜像 media_kit 自己的
  /// `MouseRegion.onEnter/onHover/onExit` 翻 [_videoControlsVisible]，让字幕动态避让进度
  /// 条。`opaque:false`：不阻断 hover hit-test 继续下探到 media_kit 的 `MouseRegion`，
  /// 故 media_kit 控制条仍照常被鼠标唤起、字幕逐字查词 / 点击不受影响（与字幕层
  /// BUG-198 同款 non-opaque 纪律）。仅桌面挂 hover；移动端无 hover 语义，可见性走
  /// [_handleVideoPointerUp] 的点画面 toggle，故透传 child 零开销。本层与字幕 overlay
  /// 同在 controls builder 内，全屏复用同一 builder → 窗口与全屏共用同一追踪。
  Widget _videoControlsHoverWrap({required Widget child}) {
    if (!_isDesktopVideoControls) return child;
    return MouseRegion(
      opaque: false,
      // 鼠标移动也唤回视频左侧锁 / 解锁按钮（TODO-126）。[_pokeLockButton] 不被锁 gate
      // （[_markControlsVisible] 在沉浸态强制 false），故沉浸态解锁按钮淡出后能被鼠标唤回。
      // onExit 不立即收起锁按钮——交给 [_pokeLockButton] 的 2s 计时器自然淡出（无操作淡出）。
      onEnter: _handleVideoControlsHover,
      onHover: _handleVideoControlsHover,
      onExit: _handleVideoControlsHoverExit,
      child: child,
    );
  }

  /// OS 光标隐藏统一胜出层（TODO-318 / BUG-258）。放在 controls Stack **最顶层**
  /// （front-most），cursor 解析按 front-to-back 取第一个非 defer：故隐藏时本层 `none`
  /// 胜过下方所有 chrome（锁按钮 rail / 字幕面板 / OSD 等）的 click cursor。`opaque:false`
  /// 不阻断指针下探（按钮 hover / 点击照常到下层 chrome），故不回归 BUG-198 hover 穿透；
  /// `IgnorePointer` 在不隐藏时彻底让出（cursor: defer 透明）。仅桌面有 OS 光标，移动端
  /// 调用方根本不挂本层。
  Widget _buildCursorOverlay() {
    return Positioned.fill(
      child: ValueListenableBuilder<bool>(
        valueListenable: _cursorHidden,
        builder: (BuildContext _, bool hidden, __) {
          if (!hidden) return const SizedBox.shrink();
          return const MouseRegion(
            opaque: false,
            cursor: SystemMouseCursors.none,
          );
        },
      ),
    );
  }

  /// [_buildVideoControls] 的实体（gate 之内）：拖放目标 + controls + 字幕 overlay
  /// + OSD。
  Widget _buildVideoControlsInner(
    VideoState state,
    VideoPlayerController controller,
  ) {
    return ValueListenableBuilder<VideoControlLayout>(
      valueListenable: _controlLayoutNotifier,
      builder: (BuildContext context, VideoControlLayout layout, _) {
        final ({
          MaterialVideoControlsThemeData mobile,
          MaterialDesktopVideoControlsThemeData desktop,
        }) controlsTheme = _currentVideoControlsTheme(controller, layout);
        return VideoControlsThemePair(
          mobile: controlsTheme.mobile,
          desktop: controlsTheme.desktop,
          child: _videoControlsHoverWrap(
            child: HibikiFileDropTarget(
              debugLabel: 'video-playback-controls',
              onDrop: (List<String> paths, Offset _) {
                _handlePlaybackDrop(controller, paths);
              },
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerUp: _handleVideoPointerUp,
                // 桌面右键 = 视频上下文菜单（TODO-048c）。GestureDetector 只接管次按钮
                // （右键）的 tap，左键双击全屏仍走外层 Listener.onPointerUp（两路指针语义互不
                // 干扰）。onSecondaryTapUp 提供右键松手处的 globalPosition 作 showMenu 锚点。
                // 移动端无次按钮、永不触发，但 [_handleSecondaryTap] 内再门控一次（双保险）。
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onSecondaryTapUp: (TapUpDetails details) =>
                      _handleSecondaryTap(details.globalPosition),
                  onLongPressStart: _handleVideoLongPressStart,
                  onLongPressMoveUpdate: _handleVideoLongPressMoveUpdate,
                  onLongPressEnd: _handleVideoLongPressEnd,
                  // TODO-754：桌面边缘竖拖 = 左半区调亮度 / 右半区调音量（与移动端
                  // media_kit 内建竖滑同语义；handler 内 [_isDesktopVideoControls] 门控，
                  // 移动端走 media_kit 手势避免双份）。竖直裸拖与「长按横拖调速」经手势
                  // 竞技场天然分流（后者需先长按 + 横向），互不冲突。
                  onVerticalDragStart: _handleVideoEdgeDragStart,
                  onVerticalDragUpdate: _handleVideoEdgeDragUpdate,
                  onVerticalDragEnd: _handleVideoEdgeDragEnd,
                  child: Stack(
                    children: <Widget>[
                      // Builder 捕获 media_kit controls 子树内的 context（[_videoControlsContext]），
                      // 供覆盖后的键盘快捷键调用全屏 helper（isFullscreen/toggle/exitFullscreen）——
                      // 本页 build context 是它们的祖先，找不到 media_kit 的 Fullscreen/VideoState
                      // InheritedWidget。全屏复用同一 builder，故全屏路由会重新捕获其子树 context。
                      Positioned.fill(
                        child: Builder(
                          builder: (BuildContext controlsContext) {
                            _videoControlsContext = controlsContext;
                            // 锁定 / 沉浸模式（TODO-101）：用 IgnorePointer 拦掉送往 media_kit
                            // controls 的所有指针事件——其 MouseRegion.onHover/onEnter 收不到
                            // 鼠标移动 → 控制条不再被唤起（顶/底栏按钮不弹）。IgnorePointer 只
                            // 过滤指针，不影响键盘：media_kit 的 CallbackShortcuts + Focus 是
                            // MouseRegion 的祖先（见 media_kit material_desktop.dart），快捷键照常
                            // 收键；字幕逐字查词由更上层 [VideoSubtitleOverlay] 承载（在本 Stack
                            // AdaptiveVideoControls 之上），点字幕仍能查词。可见性走 ValueNotifier
                            // 让全屏路由也响应（BUG-120 同源）。
                            //
                            // 侧栏 / 字幕列表打开时也一并 gate（BUG-253 / TODO-329）：overlay 盖在
                            // 控制条上，但 media_kit 自己的 MouseRegion 仍会在鼠标移过透明背景区时
                            // 把控制条弹回到 overlay 后面，且其 `hideMouseOnControlsRemoval` 会在
                            // 控制条 2s 自动收起后隐藏视频区光标（用户报「沉浸/锁屏下鼠标放字幕被
                            // 隐藏」的画面区分支）。把 [IgnorePointer] 同时绑 [_videoSidePanel] 与
                            // [_subtitleListVisible]，overlay 期间 media_kit 收不到 hover → 背景控制条
                            // 不再冒出来、其 cursor:none 也不接管光标。键盘仍不受影响（同上）。
                            // BUG-371：[_subtitleListVisible] 不再 gate media_kit
                            // controls 指针——字幕跳转列表是 push-aside 侧栏（画面挤窄、
                            // 不遮控制条），开列表时 media_kit 顶 / 底栏按钮应继续可点
                            // （左侧按钮可用）；仅沉浸锁 / 真 overlay 面板 / 剧集列表 /
                            // 编辑态拦截指针。
                            return ListenableBuilder(
                              listenable: Listenable.merge(
                                <Listenable>[
                                  _immersiveLocked,
                                  _videoSidePanel,
                                  _episodeListVisible,
                                  _videoControlEditMode,
                                ],
                              ),
                              builder: (BuildContext _, __) => IgnorePointer(
                                ignoring: _immersiveLocked.value ||
                                    _videoSidePanel.value != null ||
                                    _episodeListVisible.value ||
                                    _videoControlEditMode.value,
                                child: AdaptiveVideoControls(state),
                              ),
                            );
                          },
                        ),
                      ),
                      // 进度条章节刻度层（TODO-432）：叠在 seek bar 同一几何上画每章一条竖线。
                      // IgnorePointer 纯视觉、不拦 seek bar 拖动；随控制条显隐、仅有章节时画。
                      _buildChapterMarkersOverlay(controller),
                      Positioned.fill(
                        child: VideoDanmakuOverlay(
                          items: _danmakuItems,
                          enabled: appModel.videoDanmakuEnabled,
                          maxActive: appModel.videoDanmakuMaxActive,
                          positionMs: () => controller.positionMs ?? 0,
                        ),
                      ),
                      Positioned.fill(
                        child: VideoSubtitleOverlay(
                          controller: controller,
                          onCharTap: _handleSubtitleLookupTap,
                          // TODO-756a 桌面 Shift-鼠标悬停查词：与点击查词同链路
                          // （[_handleSubtitleLookupTap] → [_lookupAt]，内部已 _immersiveAllowsLookup
                          // 门控），故按住 Shift 悬停字幕字符与点击该字符行为一致。移动端无 hover、
                          // 自然不触发；节流由 VideoSubtitleOverlay 内部承载。
                          onCharHover: _handleSubtitleLookupTap,
                          // TODO-756b：开了“悬停即查词”则纯悬停（无需 Shift）即查词；
                          // 关闭退回 756a 的 Shift+悬停。视频与阅读器共享 instance。
                          hoverAutoLookupEnabled:
                              ReaderHibikiSource.instance.hoverAutoLookup,
                          onHoverChanged: _handleSubtitleHover,
                          hitTester: _subtitleHitTester,
                          // 当前句已收藏时在字幕盒角标实心星（TODO-301）。读同一收藏缓存
                          // [_favoritedVideoSentences]（[_isCueFavorited]）；收藏 / 取消收藏
                          // 后 setState 触发本 builder 重建，标记即时更新。
                          isCueFavorited: _isCueFavorited,
                          blurEnabled: appModel.videoSubtitleBlur,
                          fontSize: _subtitleStyle.fontSize,
                          textColor: _subtitleStyle.resolveTextColor(
                            _subtitleTextColor(
                                _videoChromeColorScheme(context)),
                          ),
                          fontWeight:
                              _subtitleStyle.resolveFontWeight(_videoUiScale),
                          shadowColor: _subtitleStyle.resolveShadowColor(
                            _subtitleShadowColor(
                                _videoChromeColorScheme(context)),
                          ),
                          shadowThickness:
                              _subtitleStyle.resolveShadowThickness(
                            _videoUiScale,
                          ),
                          backgroundColor:
                              _subtitleStyle.resolveBackgroundColor(
                            _subtitleBackgroundColor(
                              _videoChromeColorScheme(context),
                            ),
                          ),
                          backgroundOpacity: _subtitleStyle.backgroundOpacity,
                          bottomPadding: _subtitleStyle.bottomPadding,
                          // 控制条可见性驱动动态避让（TODO-129）：进度条出现时字幕底缘对
                          // 进度条上缘取下限（max，非加法——BUG-226 防顶飞）、隐藏落回。全屏
                          // 复用同一 builder + ValueNotifier，故窗口与全屏都跟随（BUG-120 同源）。
                          controlsVisible: _videoControlsVisible,
                          // 进度条上缘距视频底边的真实高度（按平台控制条几何加总 + 随界面
                          // 缩放，BUG-238）。旧默认常量 56 既不随缩放、又低于默认基线 75 →
                          // 移动端 `max(75, 56)=75` 把字幕留在被抬高的进度条下面被遮（用户报
                          // 「只动一点点」）。显式传入真实几何让移动端真正抬升盖过进度条；
                          // 桌面仍只让一个按钮行高（保 BUG-228 观感）。TODO-568：移动端改抬到
                          // **可见轨道上缘 + 呼吸间距**（≈101×缩放，而非旧的整段热区高 140），
                          // 字幕骑进度条上方一点点、不顶飞 ~47×缩放 的透明命中区空白。
                          controlsBottomReserve:
                              _subtitleControlsBottomReserve(),
                          fontFamily: appModel.appFontFamily,
                        ),
                      ),
                      _buildOsdOverlay(),
                      _buildAutoAdvanceOverlay(),
                      _buildLevelHudOverlay(),
                      _buildVideoSideActionRail(controller),
                      _buildVideoSidePanelOverlay(controller),
                      _buildVideoControlPopoverOverlay(controller),
                      ValueListenableBuilder<bool>(
                        valueListenable: _videoControlEditMode,
                        builder: (BuildContext _, bool editing, __) {
                          if (!editing) return const SizedBox.shrink();
                          return Positioned.fill(
                            child: VideoControlLayoutEditOverlay(
                              layout: layout,
                              onLayoutChanged: _setVideoControlLayout,
                              onClose: _hideVideoControlEditOverlay,
                              // TODO-554：触屏保留「设置」按钮入口不可移除。
                              isTouchControls: !_isDesktopVideoControls,
                            ),
                          );
                        },
                      ),
                      // TODO-318：光标隐藏统一胜出层放 Stack 最顶（front-most），隐藏时其
                      // cursor:none 胜过下方所有 chrome 的 click cursor；桌面才挂（移动端无 OS 光标）。
                      if (_isDesktopVideoControls) _buildCursorOverlay(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 给浮动 rail 的按钮列套「hover 保活」MouseRegion（BUG-283）。`opaque:false`：不阻断
  /// 指针下探到下层 chrome / media_kit（按钮点击、画面 hover 不受影响，沿用 BUG-198 的
  /// non-opaque 纪律）。鼠标进按钮列即置 [_railHovered]=true → rail 显隐判据据此保持显示，
  /// 杜绝「opaque 按钮遮挡 media_kit MouseRegion 触发 onExit → 收 rail → 重新 onEnter」的
  /// 闪烁振荡；同时 [_pokeControlsVisible] 喂合成 hover 让底层控制条一并保活（media_kit 自
  /// 身设计的续命路径）。移出按钮列置 false，rail 可见性回落到 [_videoControlsVisible]，鼠标
  /// 落回画面会命中 media_kit region 自然续命、2s 后随控制条一起淡出。仅桌面挂（移动端无
  /// hover，透传 child 零开销）。
  Widget _railHoverKeepAlive({required Widget child}) {
    if (!_isDesktopVideoControls) return child;
    return MouseRegion(
      opaque: false,
      onEnter: (_) {
        _railHovered.value = true;
        _pokeControlsVisible();
      },
      onHover: (_) {
        // 鼠标在按钮列内移动时持续保活：续命 media_kit 控制条隐藏定时，避免停留期 timer
        // 到期把底层控制条收走（rail 本身由 [_railHovered] 顶住、不受影响）。
        _railHovered.value = true;
        _pokeControlsVisible();
      },
      onExit: (_) => _railHovered.value = false,
      child: child,
    );
  }

  /// 给侧边锁 / 解锁（沉浸）按钮套「hover 保活」MouseRegion（TODO-388，BUG-294）。与
  /// [_railHoverKeepAlive] 同款：`opaque:false` 不阻断指针下探（按钮点击 / 画面 hover 不受
  /// 影响），鼠标进按钮置 [_lockButtonHovered]=true 顶住可见、并 [_pokeLockButton] 续命自动
  /// 淡出定时；移出置 false，可见性回落到 [_lockButtonVisible] 的 2s 自然淡出。仅桌面挂
  /// （移动端无 hover，透传 child 零开销，沿用 [_railHoverKeepAlive] 的纪律）。
  Widget _lockButtonHoverKeepAlive({required Widget child}) {
    if (!_isDesktopVideoControls) return child;
    return MouseRegion(
      opaque: false,
      onEnter: (_) {
        _lockButtonHovered.value = true;
        _pokeLockButton();
      },
      onHover: (_) {
        _lockButtonHovered.value = true;
        _pokeLockButton();
      },
      onExit: (_) => _lockButtonHovered.value = false,
      child: child,
    );
  }

  /// 浮动侧栏（TODO-274/312 phase 2）：把 screenLeft / screenRight 两个屏幕侧槽
  /// （竖直居中浮条）的自定义按钮分别渲染。默认配置右侧保留学习按钮，左侧承接
  /// 可调整的沉浸锁；用户把按钮拖到任一侧后按真实 slot 显示。
  ///
  /// TODO-421 phase 1：topLeft / topRight 两个顶部槽不再渲染成「固定顶栏下方的浮动竖条」
  /// ——用户嫌它名不副实（选「Top bar (左/右)」却落在顶栏下方）。改为把这两槽的按钮注入
  /// 固定顶栏行本身（[_topBarSlotGroup] → [_desktopControlsTheme] / [_mobileControlsTheme]
  /// 的 `topButtonBar`），此处只剩屏幕左 / 右两条浮条。
  Widget _buildVideoSideActionRail(VideoPlayerController controller) {
    Widget right({bool immersiveOnly = false}) => _buildVideoSideRailFor(
          controller,
          VideoControlSlot.screenRight,
          Alignment.centerRight,
          const EdgeInsets.only(right: 12),
          immersiveOnly: immersiveOnly,
        );
    Widget left({bool immersiveOnly = false}) => _buildVideoSideRailFor(
          controller,
          VideoControlSlot.screenLeft,
          Alignment.centerLeft,
          const EdgeInsets.only(left: 12),
          immersiveOnly: immersiveOnly,
        );
    return Positioned.fill(
      // rail 的显隐由「控制条可见」**或**「鼠标正悬在 rail 上」决定（BUG-283）：后者保证
      // hover 期间 rail 永不被 media_kit 控制条的瞬时 visible 抖动收走，根除 opaque 按钮
      // 遮挡 media_kit MouseRegion 触发 onExit → 收 rail → 重新 onEnter 的闪烁振荡。
      child: ListenableBuilder(
        listenable: Listenable.merge(<Listenable>[
          _videoControlsVisible,
          _railHovered,
          _immersiveLocked,
          _videoSidePanel,
          _subtitleListVisible,
          _episodeListVisible,
          _videoControlEditMode,
        ]),
        builder: (BuildContext context, __) {
          final bool controlsVisible = _videoControlsVisible.value;
          final bool railHovered = _railHovered.value;
          if (_videoSidePanel.value != null) {
            return const SizedBox.shrink();
          }
          if (_immersiveLocked.value) {
            final bool lockOnSideRail =
                _slotChipItems(VideoControlSlot.screenLeft)
                        .contains(VideoControlItem.immersiveLock) ||
                    _slotChipItems(VideoControlSlot.screenRight)
                        .contains(VideoControlItem.immersiveLock);
            if (!lockOnSideRail) {
              return Stack(children: <Widget>[_buildSideLockButton()]);
            }
            return Stack(
              children: <Widget>[
                left(immersiveOnly: true),
                right(immersiveOnly: true),
              ],
            );
          }
          if (_videoSideActionRailStronglySuppressed) {
            return const SizedBox.shrink();
          }
          if (!controlsVisible && !railHovered) return const SizedBox.shrink();
          return Stack(
            children: <Widget>[left(), right()],
          );
        },
      ),
    );
  }

  /// 单条浮动侧栏：渲染 [slot] 槽的学习按钮成一列圆形按钮，靠 [alignment] 贴边。
  /// 槽为空返回空白（不占位）。
  ///
  /// TODO-388：rail 按钮与其它控件一致地吃「界面大小」+「主题」（之前硬编码
  /// `Colors.black`/`Colors.white` 背景与图标、且 `IconButton` 不传 `iconSize` →
  /// 永远默认 24px、不随 appUiScale 缩放，也不随主题色变）。改为图标尺寸走
  /// [_videoControlIconSize]（base × [_videoUiScale]），背景 / 图标走
  /// [_videoChromeColorScheme]（与侧边锁按钮 [_buildSideLockButton] 同源），让左 / 右
  /// 浮动 rail 与底栏 / 顶栏 / 侧边锁按钮在缩放与配色上完全统一。
  Widget _buildVideoSideRailFor(
    VideoPlayerController controller,
    VideoControlSlot slot,
    AlignmentGeometry alignment,
    EdgeInsetsGeometry padding, {
    bool immersiveOnly = false,
  }) {
    // TODO-399 decision 3b: rails render EVERY chip-renderable item the user
    // placed here (learning + transport/nav keys), not just the five learning
    // keys. Rails are pure custom overlays with no media_kit chrome, so adding
    // transport keys here never collides / doubles with the bottom bar.
    final List<VideoControlItem> items = <VideoControlItem>[
      for (final VideoControlItem item in _slotChipItems(slot))
        if (!immersiveOnly || item == VideoControlItem.immersiveLock) item,
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    final ColorScheme cs = _videoChromeColorScheme(context);

    Widget buttonFor(VideoControlItem item) {
      final LayerLink? popoverLink = item == VideoControlItem.speed
          ? _controlPopoverLinkFor(slot, item)
          : null;
      // TODO-635：去掉 rail 按钮外层圆形半透明 `Material(surface@0.55)` 背景——
      // 用户嫌左 / 右浮条按钮的圆底碍眼，要求只留裸图标浮在画面上。IconButton 自带
      // InkWell 仍提供点击涟漪，故去掉 Material 容器不丢点击反馈。图标仍走主题强调色
      // cs.primary + iconSize 走 _videoControlIconSize（吃 appUiScale，TODO-388/604 不变）。
      final Widget button = IconButton(
        tooltip: _videoControlItemTooltip(item),
        iconSize: _videoControlIconSize,
        icon: Icon(_videoControlItemIcon(item)),
        // TODO-604：图标用主题强调色 cs.primary，与底栏 / 顶栏按钮的
        // buttonBarButtonColor 同源；此前用 cs.onSurface（中性前景）导致左 / 右侧
        // 浮条按钮看上去「没吃到主题配色」、与底 / 顶栏不一致。
        color: cs.primary,
        onPressed: () => _activateVideoControlItem(
          item,
          controller,
          popoverLink: popoverLink,
          sourceSlot: slot,
        ),
      );
      if (popoverLink == null) return button;
      return _controlPopoverAnchor(
        kind: _VideoControlPopoverKind.speed,
        link: popoverLink,
        desktop: _isDesktopVideoControls,
        sourceSlot: slot,
        sourceItem: VideoControlItem.speed,
        child: button,
      );
    }

    return Align(
      alignment: alignment,
      // TODO-658/BUG-383: 圆角 / 刘海手机（styles.xml `shortEdges` 把画面画进 cutout 区，
      // 故 `viewPadding.left/right` 非零）上，旧实现 `SafeArea`（按 viewPadding 内缩四边）
      // **外套** `Padding(只 left/right:12)` 的控件自有 margin = 两段**相加**双重内缩，把
      // 左 / 右浮条推离侧边形成对称大留白。改为**逐边取 max**（控件 margin 与系统安全区取
      // 较大者，而非叠加）：既不被圆角真正裁掉（仍 ≥ 安全区），又消除多余留白（安全区 ≥
      // 12 时控件正贴安全区内缘、不再额外 +12）。竖直方向同理 max 兜底横屏顶 / 底 cutout。
      child: Padding(
        padding: _mergeRailSafeAreaPadding(padding),
        // 只在真正的按钮列上挂 keep-alive hover（不是整片 Positioned.fill）——否则鼠标
        // 在画面任意处都会被当成「悬在 rail 上」、rail 永不淡出（BUG-283）。
        child: _railHoverKeepAlive(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final VideoControlItem item in items) ...<Widget>[
                buttonFor(item),
                if (item != items.last) const SizedBox(height: 8),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 浮动侧栏内缩：把控件自有 margin [railMargin] 与系统安全区（[MediaQuery.viewPadding]，
  /// 含圆角 / 刘海 cutout）**逐边取 max** 合并（TODO-658/BUG-383）。
  ///
  /// 取 max 而非旧 `SafeArea`(安全区) + `Padding`(margin) 的**相加**：相加在 `shortEdges`
  /// cutout 手机上让左 / 右浮条被双重内缩、推离侧边留大白边；逐边取 max 保证控件既不被圆角
  /// 裁掉（结果 ≥ 安全区），又不在安全区已够大时再叠 margin（结果 = max，不再额外加 12）。
  EdgeInsets _mergeRailSafeAreaPadding(EdgeInsetsGeometry railMargin) {
    final EdgeInsets margin = railMargin.resolve(Directionality.of(context));
    final EdgeInsets safe = MediaQuery.of(context).viewPadding;
    return EdgeInsets.fromLTRB(
      math.max(margin.left, safe.left),
      math.max(margin.top, safe.top),
      math.max(margin.right, safe.right),
      math.max(margin.bottom, safe.bottom),
    );
  }

  /// 把 [video]（media_kit `Video` 控件）与字幕跳转列表面板组成「真 push-aside」横向
  /// 布局（TODO-121，asbplayer 同款）。面板可见时返回 `Row[Expanded(video), 面板列]`：
  /// `Expanded` 收窄 `Video` 的 `Container` 宽度 → libmpv 纹理的 `FittedBox` 真正缩窄
  /// （画面整体左移、不被遮），而面板作为同级兄弟列占右侧固定宽度（不再 overlay 盖画面）。
  /// 隐藏时面板列宽收成 0、`Video` 占满整行（像素级等价于无面板的旧布局）。
  ///
  /// 窗口与全屏两条路径都各自调本函数包裹自己那棵 `Video`（窗口在 [_buildVideoBody]，
  /// 全屏在 [_pushNeutralizedVideoFullscreen] 自建的全屏路由里）——media_kit 全屏推独立
  /// root 路由、复用同一 controls builder，但 `Video` 控件由我们两处分别构建，故两路径
  /// 都能真挤窄、且字幕 overlay（在 `Video` controls 内 `Positioned.fill`）随收窄后的
  /// `Video` 区自动受限，不会画到被挤走的右侧或飘上面板。
  ///
  /// 可见性走 [_subtitleListVisible]（[ValueNotifier]，全屏路由也响应，BUG-120 同源）。
  /// 面板列宽按界面宽取 ~28%（横屏右侧栏，clamp 240..420），参照 asbplayer / YouTube
  /// transcript 侧栏占比。
  Widget _videoWithSubtitlePanel(
    VideoPlayerController controller,
    Widget video,
  ) {
    // TODO-637：字幕列表是「带 × 的非阻塞侧栏」——画面区不再叠任何 barrier。此前
    // BUG-256 在画面区叠一层不透明（opaque）的「点画面关列表」barrier，它罩在画面
    // 字幕 overlay（[VideoSubtitleOverlay] 的查词手势）之上吃掉所有画面点击 → 列表
    // 开着时画面字幕查不了词（TODO-636 根因）。删 barrier 后画面区是裸 [video]，画面
    // 字幕命中恢复、可查词；关列表统一走 × / Esc / 控制条字幕按钮，三者都经
    // [_closeSubtitleJumpList]（单一真相源：清挖词选择 + 隐藏列表 + 唤回控制条 +
    // 归还焦点；见 _subtitleJumpSidePanel.onClose 与 _toggleSubtitleJumpList 的关闭
    // 分支）。barrier 删除后列表锁定（TODO-611，原本
    // 唯一作用是把 barrier 门控成 no-op）失去意义，一并移除（TODO-634）。
    //
    // TODO-638：剧集列表也是 push-aside 侧栏，与字幕列表共享同一右栏槽位（同时只一个
    // 可见，互斥由 _toggleEpisodeList / _toggleSubtitleJumpList 保证）。Row 同时监听两个
    // 可见性 notifier，渲染两列面板——隐藏的那列宽度收成 0（_subtitleJumpSidePanel /
    // _episodeSidePanel 内部 AnimatedSize 处理伸缩），故画面只被当前打开的那个侧栏挤窄。
    return ListenableBuilder(
      listenable: Listenable.merge(
        <Listenable>[_subtitleListVisible, _episodeListVisible],
      ),
      builder: (BuildContext _, __) {
        final bool visible = _subtitleListVisible.value;
        final bool episodeVisible = _episodeListVisible.value;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(child: video),
            _subtitleJumpSidePanel(controller, visible),
            _episodeSidePanel(episodeVisible),
          ],
        );
      },
    );
  }

  /// 视频左侧锁 / 解锁按钮（TODO-126，前身 TODO-101 左上角常驻解锁层 [_buildLockOverlay]）。
  /// 移到**视频正左边、垂直居中**，像侧边锁：
  ///   - 非沉浸态（[_immersiveLocked] 为 false）：图标显示**开着的锁** [Icons.lock_open_outlined]
  ///     （未锁状态），点击进入沉浸（取代原 topButtonBar 里的锁按钮，TODO-101）。跟随 hover /
  ///     tap 唤起、2s 自动淡出，不再占顶栏。
  ///   - 沉浸态（true）：图标显示**关着的锁** [Icons.lock_outline]（已锁状态），点击退出沉浸。
  ///     这是沉浸态下唯一常驻可见 chrome，作为清晰可发现的默认退出口；其余 chrome 全被抑制。
  ///
  /// 图标是**状态语义**（锁住=闭锁图标），与悬浮字幕锁 / OSD（[_toggleImmersiveLock] 里
  /// 锁定用 [Icons.lock_outline] / 解锁用 [Icons.lock_open_outlined]）/ Android FloatingLyricService
  /// / Windows floating_lyric_window 统一（TODO-153/BUG-216，原先反成「动作提示」语义=锁住却
  /// 显示开锁，与用户预期相反）。tooltip 仍是**动作语义**（锁住时「点击解锁」合理）。
  ///
  /// 可见性走独立的 [_lockButtonVisible]（[_pokeLockButton] 唤回，不被锁 gate）：无操作 2s 后
  /// 淡出（[AnimatedOpacity]），鼠标移动 / 触屏点画面唤回。淡出后 [IgnorePointer] 不拦点击，
  /// 但 Esc / Shift+L 始终可解锁（守卫已钉）——故淡出不会让用户失去退出口。
  ///
  /// 它是 controls Stack 里独立的 [Positioned] 兄弟层（不在 gate `AdaptiveVideoControls`
  /// 的 [IgnorePointer] 之内），故沉浸态下仍可点。可见性走 [ValueNotifier]，全屏路由也响应
  /// （与字幕跳转面板 / OSD 同源，BUG-120）。
  Widget _buildSideLockButton() {
    final ColorScheme cs = _videoChromeColorScheme(context);
    final double iconSize = _videoControlIconSize;
    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      child: SafeArea(
        child: Align(
          alignment: Alignment.centerLeft,
          child: ValueListenableBuilder<bool>(
            valueListenable: _immersiveLocked,
            builder: (BuildContext _, bool locked, __) {
              // TODO-388（BUG-294）：可见性 = 自动淡出 [_lockButtonVisible] **或** 鼠标正悬
              // 在按钮上 [_lockButtonHovered]（与屏幕右侧 rail 的 _videoControlsVisible ||
              // _railHovered 判据同款）。hover 期间永远顶住显示，根除「鼠标静止在按钮上、2s
              // 定时器仍把它从光标正下方淡出」的消失 bug。
              return ListenableBuilder(
                listenable: Listenable.merge(<Listenable>[
                  _lockButtonVisible,
                  _lockButtonHovered,
                ]),
                builder: (BuildContext __, ___) {
                  final bool visible =
                      _lockButtonVisible.value || _lockButtonHovered.value;
                  return IgnorePointer(
                    ignoring: !visible,
                    child: AnimatedOpacity(
                      opacity: visible ? 1.0 : 0.0,
                      // TODO-435：与 media_kit 控制条同源的淡入淡出时长 + 曲线，
                      // 让锁按钮与控制条一致地淡入淡出（旧实现 200ms + 默认 linear）。
                      duration: _videoControlsTransitionDuration,
                      curve: Curves.easeInOut,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 8),
                        // hover 保活：鼠标进按钮置 [_lockButtonHovered]=true 顶住显示 +
                        // [_pokeLockButton] 续命淡出定时器；移出置 false 回落到自然淡出。
                        // 与屏幕右侧 rail 的 [_railHoverKeepAlive] 同款（用户要求「改成和屏幕
                        // 右侧按钮一样」）。
                        child: _lockButtonHoverKeepAlive(
                          child: Material(
                            color: cs.surface.withValues(alpha: 0.55),
                            shape: const CircleBorder(),
                            clipBehavior: Clip.antiAlias,
                            child: IconButton(
                              tooltip: locked
                                  ? t.video_immersive_unlock
                                  : t.video_menu_lock,
                              iconSize: iconSize,
                              // TODO-604：与左 / 右侧浮条按钮、底 / 顶栏按钮统一用主题
                              // 强调色 cs.primary（此前 cs.onSurface 中性前景看上去没吃主题色）。
                              color: cs.primary,
                              // 状态语义（TODO-153/BUG-216）：锁住=闭锁图标、未锁=开锁图标。
                              icon: Icon(
                                locked
                                    ? Icons.lock_outline
                                    : Icons.lock_open_outlined,
                              ),
                              onPressed: _toggleImmersiveLock,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}
