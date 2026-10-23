part of '../video_fushi_page.dart';

/// The disc supplies the picture and buttons. Flutter only forwards input and
/// binds a selected physical playlist to the existing learning pipeline.
extension _VideoDiscMenu on _VideoFushiPageState {
  Future<bool> _ensureDiscMenuRuntime(String playlistPath) async {
    final String? root = blurayDiscRootForPlaylistPath(playlistPath);
    if (root == null) return true; // Controller reports malformed input.
    try {
      final BlurayMenuInfo? info = await readBlurayMenuInfo(root);
      if (!mounted) return false;
      if (info?.requiresJava != true) return true;
      final BlurayJavaRuntimeManager manager = BlurayJavaRuntimeManager();
      if (await manager.probeJavaHome() != null) return mounted;
      if (!mounted) return false;
      if (!manager.canInstall) {
        if (!Platform.isWindows) return true;
        throw const VideoDiscMenuException('java-runtime-unavailable');
      }
      final bool installed =
          await _focusOwnership.guardOverlay(
            () => showAppDialog<bool>(
              context: context,
              barrierDismissible: false,
              builder: (_) => _BlurayJavaRuntimeInstallDialog(manager: manager),
            ),
          ) ??
          false;
      if (!installed && mounted) {
        _rebuild(() {
          _failed = true;
          _failReason = t.video_disc_runtime_required;
        });
      }
      return installed && mounted;
    } catch (error, stack) {
      ErrorLogService.instance.log('VideoDiscMenu.runtime', error, stack);
      if (mounted) {
        _rebuild(() {
          _failed = true;
          _failReason = t.video_disc_runtime_required;
        });
      }
      return false;
    }
  }

  bool _discExtractionAllowed(VideoPlayerController controller) {
    if (!controller.isBlurayNavigationSession) return true;
    if (controller.discMiningAvailable && !_discLearningBlocked) return true;
    final String message = switch (controller.discMiningUnavailableReason) {
      'multi-angle-source' => t.video_disc_angle_extraction_unavailable,
      'audio-track-unavailable' => t.video_disc_audio_selection_pending,
      'extraction-source-unavailable' => t.video_clip_export_input_missing,
      'encrypted-extraction-source' => t.video_disc_extraction_unavailable,
      _ => t.video_disc_title_binding_failed,
    };
    _showOsd(message, severity: ToastSeverity.warning);
    return false;
  }

  // Pending menus still own input so arrows cannot leak into seek/volume.
  // Dispatch below consumes them without sending commands until Top is ready.
  bool get _discOwnsInput =>
      _discLearningBlocked &&
      !_videoNavigablePanelOpen &&
      !_hasVisiblePopup &&
      ModalRoute.of(_videoControlsContext ?? context)?.isCurrent != false;

  void _reclaimDiscMenuFocusAfterAttachment(BuildContext hostContext) {
    if (!mounted ||
        !hostContext.mounted ||
        !_discOwnsInput ||
        ModalRoute.of(hostContext)?.isCurrent != true) {
      return;
    }
    // Runs after the replacement Focus host has attached and the old adaptive
    // controls have detached. Keep all page/popup focus policy centralized.
    _focusOwnership.reclaim(FocusReclaimCause.contentReady);
  }

  Future<void> _runDiscNavigation(String action) async {
    if (_controller?.discMenuEntryPending == true) return;
    try {
      await _controller?.discNavigation(action);
    } catch (error, stack) {
      ErrorLogService.instance.log('VideoDiscMenu.navigate', error, stack);
      if (mounted) {
        _showOsd(t.video_disc_navigation_failed, severity: ToastSeverity.error);
      }
    }
  }

  bool _handleDiscMenuKey(KeyEvent event) {
    // macOS：Cmd+W 直接退出原盘会话（整段会话都算，正片播放中也是）。
    if (Platform.isMacOS &&
        event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyW &&
        HardwareKeyboard.instance.isMetaPressed &&
        _controller?.isBlurayNavigationSession == true) {
      unawaited(_exitDiscSession());
      return true;
    }
    if (!_discOwnsInput ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      // 按住期间焦点 / 浮层变了：松开沿照样要收掉圆环，否则它卡在屏幕中间。
      if (event is KeyUpEvent &&
          _discExitHold.release(LogicalKeyboardKey.escape)) {
        return true;
      }
      return false;
    }
    // Esc 是会话键而不是盘的 Return：短按呼出 / 退出控制栏，按住约 1 秒直接退出。
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _handleDiscExitHoldEdge(event, LogicalKeyboardKey.escape);
      return true;
    }
    final String? action = blurayMenuKeyAction(event.logicalKey);
    if (action == null) return false;
    // 操作盘菜单不呼出控制栏；控制栏开着时算一次操作，重新计 3 秒。
    if (_discMenuChromeVisible.value) _pokeDiscMenuChrome();
    if (_controller?.discMenuEntryPending == true) return true;
    if (event is KeyDownEvent ||
        event is KeyRepeatEvent && action != 'select') {
      unawaited(_runDiscNavigation(action));
    }
    return true;
  }

  bool _handleDiscMenuGamepad(GamepadButton button) {
    if (!_discOwnsInput) return false;
    if (button == GamepadButton.b) {
      // 手柄 B 与 Esc 同语义：短按呼出 / 退出控制栏，按住约 1 秒直接退出。松开沿
      // 经 [_handleDiscMenuGamepadRelease]。
      _discExitHold.press(GamepadButton.b);
      return true;
    }
    final String? action = blurayMenuGamepadAction(button);
    if (action == null) return false;
    if (_discMenuChromeVisible.value) _pokeDiscMenuChrome();
    if (_controller?.discMenuEntryPending == true) return true;
    unawaited(_runDiscNavigation(action));
    return true;
  }

  bool _handleDiscMenuGamepadRelease(GamepadButton button) {
    if (button != GamepadButton.b || !_discExitHold.active) return false;
    if (_discExitHold.release(GamepadButton.b)) _discSessionBack();
    return true;
  }

  void _handleDiscExitHoldEdge(KeyEvent event, Object source) {
    if (event is KeyDownEvent) {
      _discExitHold.press(source);
    } else if (event is KeyUpEvent) {
      if (_discExitHold.release(source)) _discSessionBack();
    }
    // KeyRepeatEvent：按住期间的自动重复不是新的一次按下。
  }

  /// 原盘菜单画面（会话的菜单阶段）正在显示：控制栏、点击层级、Esc 语义只在这时生效；
  /// 进了正片就是普通播放器。
  bool get _discSessionSurfaceActive => _discLearningBlocked;

  /// 桌面端「播放原盘时自动全屏」：只对从库里显式进入的原盘会话生效。
  bool get _wantsDiscAutoFullscreen =>
      widget.openBlurayMenu &&
      !isMobilePlatform &&
      appModel.videoDiscAutoFullscreen;

  /// 「返回」在原盘会话里的第一步（页面浮层已由调用方先关）：控制栏收着就只把它呼出来
  /// 并返回 true；开着返回 false，调用方照常退出。
  bool _discSessionShowBarOnBack() {
    if (!_discSessionSurfaceActive || _discSessionExitRequested) return false;
    if (resolveDiscSessionBack(barVisible: _discMenuChromeVisible.value) !=
        DiscSessionBackRoute.showBar) {
      return false;
    }
    _pokeDiscMenuChrome();
    return true;
  }

  /// Esc / 手柄 B 短按：先关页面浮层，再按控制栏状态呼出或退出。
  void _discSessionBack() {
    if (_dismissTopForegroundLayer()) return;
    if (_discSessionShowBarOnBack()) return;
    unawaited(_exitDiscSession());
  }

  /// 退出整个原盘会话回到详情页：会话进过的全屏先退（窗口按进入前状态还原），再离开
  /// 本页。不经页面浮层表——调用方要么已关过（短按），要么用户明确要直接走（按满 /
  /// Cmd+W / 「退出原盘」）。
  Future<void> _exitDiscSession() async {
    _discExitHold.cancel();
    if (!mounted || _discSessionExitRequested) return;
    // 退出意图一旦成立，返回链上的「先呼出控制栏」那一步就不再拦它。
    _discSessionExitRequested = true;
    final BuildContext? controlsContext = _videoControlsContext;
    if (controlsContext != null &&
        controlsContext.mounted &&
        isFullscreen(controlsContext)) {
      await _exitVideoFullscreen(controlsContext);
      if (!mounted) return;
    }
    // 与 Esc / 系统返回同一个退出汇聚点（落库与 pop 之间不 await，BUG-2119）。
    await _handleBackOrExit();
  }

  void _syncDiscTrackSelection(VideoPlayerController controller) {
    final BlurayDiscTrackSelection selection = resolveBlurayDiscTrackSelection(
      discOwnsTracks: controller.discOwnsTracks,
      nativeAudioId: controller.activeAudioTrackId,
      nativeSubtitleId: controller.resolvedDiscSubtitleTrackId,
      nativeSubtitleStreamIndex: controller.activeSubtitleStreamIndex,
      currentSubtitleSource: _currentSubtitleSource,
      currentSecondarySubtitleSource: _currentSecondarySubtitleSource,
    );
    final List<SubtitleTrack> tracks = controller.subtitleTracks;
    final bool tracksChanged = !identical(_discLastSubtitleTracks, tracks);
    if (_currentAudioTrackId == selection.audioId &&
        _currentSubtitleSource == selection.subtitleSource &&
        _currentSecondarySubtitleSource == selection.secondarySubtitleSource &&
        !tracksChanged &&
        (!controller.discOwnsTracks ||
            (_delayMs == 0 && _secondaryDelayMs == null))) {
      return;
    }
    _rebuild(() {
      if (controller.discOwnsTracks) {
        _delayMs = 0;
        _secondaryDelayMs = null;
      }
      _currentAudioTrackId = selection.audioId;
      _currentSubtitleSource = selection.subtitleSource;
      _currentSecondarySubtitleSource = selection.secondarySubtitleSource;
      if (tracksChanged) {
        _discLastSubtitleTracks = tracks;
        _discSubtitleTracksRevision++;
        _subtitleMenuSourcesPath = null;
        _subtitleMenuLoading = false;
      }
    });
    if (tracksChanged &&
        !_discLearningBlocked &&
        _videoSidePanel.value?.kind == _VideoSidePanelKind.subtitle) {
      unawaited(_ensureSubtitleMenuSourcesLoaded());
    }
  }

  void _onDiscNavigationChanged() {
    final VideoPlayerController? controller = _controller;
    if (!mounted ||
        controller == null ||
        !controller.isBlurayNavigationSession) {
      return;
    }
    _syncDiscTrackSelection(controller);
    final String? error = controller.discMenuError;
    if (error != null && !_failed) {
      unawaited(controller.pause());
      _rebuild(() {
        _failed = true;
        _failReason = error.contains('java-runtime-unavailable')
            ? t.video_disc_runtime_required
            : error == 'navigation-open-failed'
            ? t.video_disc_menu_open_failed
            : t.video_disc_navigation_failed;
      });
    }
    final bool blocked =
        controller.discMenuActive || !controller.discTitleReady;
    if (blocked && !_discMenuWasActive) {
      // These panels are replaced by the authored menu surface. Clear their
      // ownership too, otherwise invisible panels keep swallowing menu arrows.
      if (_videoSidePanel.value != null) _hideVideoSidePanel();
      if (_subtitleListVisible.value) _closeSubtitleJumpList();
      if (_episodeListVisible.value) _closeEpisodeList();
      _hideVideoControlEditOverlay(revealControls: false);
      _watchTracker?.dispose();
      _watchTracker = null;
      _watchTrackerCoverageKey = null;
      _miningDraft.clear();
      _lastLookupCue = null;
      _lastLookupSentence = '';
      _subtitleLookupHighlight = null;
      _clearClipExportState();
      _pausedForLookup = false;
      if (_hasVisiblePopup) _popNestedPopupAt(0);
      // Reveal the menu chrome once on entry so it can be found, then let it fade.
      // The previous chrome may have unmounted under the pointer / focus without
      // an exit callback, so its holds do not survive into this menu visit.
      _discMenuChromeHovered = false;
      _discMenuChromeFocused = false;
      _pokeDiscMenuChrome();
    }
    _discMenuWasActive = blocked;
    final String? selected = controller.selectedDiscPlaylistPath;
    if (selected != _discBindingPath ||
        _discNativeGeneration != controller.discTitleGeneration) {
      _discNativeGeneration = controller.discTitleGeneration;
      _episodeLoadSeq++;
      // 换了光盘标题：旧标题的图形字幕整轨转文字作废，强杀在途抽轨（见 _applyLoad）。
      _cancelGraphicSubtitleOcr();
      _discBindingPath = selected;
      final int generation = ++_discBindingGeneration;
      if (selected != null) {
        unawaited(
          _bindDiscPlaylist(
            controller,
            selected,
            generation,
            controller.discTitleGeneration,
          ),
        );
      }
    } else if (!blocked) {
      _ensureWatchTracker(controller, _title ?? '');
    }
  }

  Future<void> _bindDiscPlaylist(
    VideoPlayerController controller,
    String path,
    int generation,
    int nativeGeneration,
  ) async {
    bool current() =>
        mounted &&
        identical(_controller, controller) &&
        generation == _discBindingGeneration &&
        controller.selectedDiscPlaylistPath == path &&
        controller.discTitleGeneration == nativeGeneration;
    try {
      // Menu-only bonus titles can be absent from the importer's filtered list.
      // They get their row through the importer's own rules (disc source, disc
      // collection, META disc name) — a hand-built sourceless row is invisible
      // to every scrape entry point, which select books by source.
      final VideoBookRow? row = await ensureBlurayTitleInLibrary(
        appModel.database,
        path,
      );
      if (!current() || row == null) return;
      final VideoBookRow selected = row;
      // Identity changes atomically before enabling title playback consumers.
      _rebuild(() {
        _discBookUid = selected.bookUid;
        _bookRow = selected;
        final int episode = _episodes.indexWhere(
          (_PlaylistEpisodeRef entry) => entry.bookUid == selected.bookUid,
        );
        _currentEpisode = episode < 0 ? 0 : episode;
        _title = selected.title;
        _currentVideoPath = path;
        // Stored choices remain library candidates; the disc VM owns startup.
        _currentSubtitleSource = null;
        _currentSecondarySubtitleSource = null;
        _currentAudioTrackId = null;
        _delayMs = 0;
        _secondaryDelayMs = null;
        _subtitleMenuSources = const <SubtitleSource>[];
        _importedSubtitleSources = const <SubtitleSource>[];
        _favoritedVideoSentences.clear();
        _danmakuVisibleItems = const <VideoDanmakuItem>[];
        _subtitleMenuSourcesPath = null;
        _subtitleMenuLoading = false;
      });
      _titleNotifier.value = selected.title;
      await controller.bindDiscTitle(
        playlistPath: path,
        bookUid: selected.bookUid,
        expectedGeneration: nativeGeneration,
      );
      if (!current()) return;
      if (controller.discMiningAvailable) _setupThumbnailPreview(path);
      _ensureWatchTracker(controller, selected.title);
      _syncDiscTrackSelection(controller);
      unawaited(_refreshFavoritedCueCache());
    } catch (error, stack) {
      ErrorLogService.instance.log('VideoDiscMenu.bindTitle', error, stack);
      if (current()) {
        _showOsd(
          t.video_disc_title_binding_failed,
          severity: ToastSeverity.error,
        );
      }
    }
  }

  /// 原盘菜单顶栏的自动隐藏：任何指针活动都把它唤出，静置
  /// [_VideoFushiPageState._videoControlsHoverDuration] 后淡出（与常规控制条同节奏）。
  /// 指针悬停或焦点停在顶栏上时不排隐藏。
  void _pokeDiscMenuChrome() {
    if (!mounted) return;
    _discMenuChromeVisible.value = true;
    _discMenuChromeHideTimer?.cancel();
    if (_discMenuChromeHovered || _discMenuChromeFocused) return;
    _discMenuChromeHideTimer = Timer(kDiscSessionBarIdleDuration, () {
      if (mounted) _discMenuChromeVisible.value = false;
    });
  }

  void _hideDiscMenuChrome() {
    _discMenuChromeHideTimer?.cancel();
    _discMenuChromeVisible.value = false;
  }

  void _setDiscMenuChromeHovered(bool hovered) {
    _discMenuChromeHovered = hovered;
    _pokeDiscMenuChrome();
  }

  void _setDiscMenuChromeFocused(bool focused) {
    _discMenuChromeFocused = focused;
    _pokeDiscMenuChrome();
  }

  Offset? _discPointerPoint(
    VideoPlayerController controller,
    Offset position,
    Size viewport,
  ) => blurayMenuPointerPosition(
    position: position,
    viewport: viewport,
    video: Size(
      (controller.videoWidth ?? 0).toDouble(),
      (controller.videoHeight ?? 0).toDouble(),
    ),
    fit: videoFitModeToBoxFit(_videoFitMode),
  );

  /// 把一次点击交给原盘，返回盘是否接收（点中按钮）。第 0 步实测：HDMV 点空白时
  /// `discnav mouse-click` 返回「未接收」，点中按钮返回成功（见 spec 第 0 步）。
  Future<bool> _clickDiscMenu(
    VideoPlayerController controller,
    Offset point,
  ) async {
    try {
      return await controller.clickDiscMenu(point.dx, point.dy);
    } catch (error, stack) {
      ErrorLogService.instance.log('VideoDiscMenu.pointer', error, stack);
      if (mounted) {
        _showOsd(t.video_disc_navigation_failed, severity: ToastSeverity.error);
      }
      // 报过错了：不再按「点空白」去切控制栏。
      return true;
    }
  }

  /// 原盘画面上的一次点击，按层级分流（spec「点空白呼出控制栏」拍板）：开着浮层
  /// （页面浮层 / 控制栏）只关它；点在盘按钮上交给盘；只有真正的空白才呼出控制栏。
  Future<void> _onDiscSurfaceTap(
    VideoPlayerController controller,
    Offset position,
    Size viewport,
  ) async {
    if (_discMultiTouch) return; // 两指点击由 [_onDiscSurfacePointerUp] 处理。
    if (_dismissTopForegroundLayer()) return;
    final VideoDiscNavigationState? state = controller.discNavigationState;
    final bool bdj = state?.bdjDetected == true;
    final Offset? point = _discPointerPoint(controller, position, viewport);
    switch (resolveDiscSurfaceTap(
      overlayOpen: _discMenuChromeVisible.value,
      insideVideo: point != null,
      menuInteractive: state?.menuActive == true,
      bdj: bdj,
      inTopBand: isInDiscSessionTopBand(position, viewport),
      menuStarting: controller.discMenuEntryPending,
    )) {
      case DiscSurfaceTapRoute.dismissOverlay:
        _hideDiscMenuChrome();
      case DiscSurfaceTapRoute.toggleBar:
        _pokeDiscMenuChrome();
      case DiscSurfaceTapRoute.ignore:
        break;
      case DiscSurfaceTapRoute.forwardToDisc:
        if (point == null) return;
        final bool consumed = await _clickDiscMenu(controller, point);
        if (consumed || !mounted) return;
        switch (resolveUnconsumedDiscClick(
          bdj: bdj,
          discTitle: state?.title ?? 0,
        )) {
          case DiscUnconsumedClickRoute.closeDiscPopup:
            unawaited(_runDiscNavigation('popup'));
          case DiscUnconsumedClickRoute.showBar:
            _pokeDiscMenuChrome();
          case null:
            break;
        }
    }
  }

  void _onDiscSurfacePointerDown(PointerDownEvent event) {
    _discSurfacePointers++;
    if (_discSurfacePointers >= 2) _discMultiTouch = true;
  }

  void _onDiscSurfacePointerUp(PointerEvent event) {
    if (_discSurfacePointers > 0) _discSurfacePointers--;
    if (_discSurfacePointers > 0 || !_discMultiTouch) return;
    _discMultiTouch = false;
    if (event is! PointerUpEvent) return;
    // 两指点击：BD-J 盘（没有按钮几何）的控制栏呼出方式，HDMV 上同样可用。
    if (_discMenuChromeVisible.value) {
      _hideDiscMenuChrome();
    } else {
      _pokeDiscMenuChrome();
    }
  }

  void _onDiscSurfaceHover(Offset position, Size viewport) {
    // 鼠标移到屏幕顶部呼出控制栏；控制栏开着时任何移动都算操作、重新计时。
    if (_discMenuChromeVisible.value ||
        isInDiscSessionTopBand(position, viewport)) {
      _pokeDiscMenuChrome();
    }
  }

  /// 原盘画面上的指针层。只有**点击**交给原盘（选中并激活所点按钮）；指针移动只用来
  /// 唤出顶栏。
  ///
  /// 不转发移动：libbluray 把每一次指针位置都当成「选中该处按钮」
  /// （graphics_controller.c `_mouse_move`），而盘上带 auto-action 的按钮一被选中
  /// 就执行导航命令。鼠标从刚展开的子菜单移开时会掠过别的按钮（页签 / 父项），菜单
  /// 随之被切回、收起；BD-J 同理（移动即 `MOUSE_MOVED`，改焦点）。原盘菜单按遥控器
  /// 设计，指针在上面只该有「点哪按哪」一种语义，与触屏一致。
  Widget _buildDiscMenuSurface(VideoPlayerController controller) {
    if (controller.discMenuEntryPending) return const SizedBox.expand();
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return MouseRegion(
          cursor: SystemMouseCursors.basic,
          onHover: (PointerHoverEvent event) =>
              _onDiscSurfaceHover(event.localPosition, constraints.biggest),
          child: Listener(
            onPointerDown: _onDiscSurfacePointerDown,
            onPointerUp: _onDiscSurfacePointerUp,
            onPointerCancel: _onDiscSurfacePointerUp,
            child: GestureDetector(
              key: const ValueKey<String>('disc-session-surface'),
              behavior: HitTestBehavior.opaque,
              onTapUp: (TapUpDetails details) {
                unawaited(
                  _onDiscSurfaceTap(
                    controller,
                    details.localPosition,
                    constraints.biggest,
                  ),
                );
                _focusOwnership.reclaim(FocusReclaimCause.gesture);
              },
              // Claim press gestures so authored buttons never become speed/seek.
              onLongPress: () {},
              child: const SizedBox.expand(),
            ),
          ),
        );
      },
    );
  }

  /// 按住 Esc / 手柄 B 时屏幕中央的圆环进度。
  Widget _buildDiscExitHoldRing() =>
      DiscExitHoldRing(holding: _discExitHold.holding, color: Colors.white);

  /// 原盘启动动画：只在从库里显式进原盘会话、带了封面、且设置开着时出现。动画本身
  /// 在减弱动态效果 / 墨水屏下时长为零、什么都不画。
  Widget _wrapDiscLaunchTransition(Widget child) {
    final ImageProvider? cover = widget.discLaunchCover;
    if (!widget.openBlurayMenu ||
        cover == null ||
        !appModel.videoDiscLaunchAnimation) {
      return child;
    }
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        child,
        Positioned.fill(
          child: DiscLaunchCoverTransition(
            key: const ValueKey<String>('disc-launch-transition'),
            cover: cover,
            origin: widget.discLaunchOrigin,
          ),
        ),
      ],
    );
  }

  /// 原盘菜单的顶栏：与播放时的顶栏同一套部件——MD3 Expressive 下返回键并进标题
  /// 浮动胶囊，Apple 下是玻璃圆钮 + 标题；右侧「主菜单 / 弹出菜单」是同款按钮组，窄屏
  /// 收进「⋯」。整条随 [_discMenuChromeVisible] 淡出，隐藏时不吃点击（点穿给原盘）。
  Widget _buildDiscMenuChrome(VideoPlayerController controller) {
    final bool apple = _appleChrome;
    final bool desktop = _isDesktopVideoControls;
    final double scale = _videoUiScale;
    // 控制栏里的返回 = 退出原盘（回详情页），不再是「先呼出控制栏」那一步。
    final Widget back = FushiTooltip(
      message: t.video_disc_exit,
      child: KeyedSubtree(
        key: const ValueKey<String>('bluray-menu-exit'),
        child: _chromeIconButton(
          icon: _videoControlItemIcon(VideoControlItem.back),
          desktop: desktop,
          onPressed: () => unawaited(_exitDiscSession()),
        ),
      ),
    );
    final List<VideoBarEntry> actions = <VideoBarEntry>[
      if (!controller.discMenuEntryPending)
        ..._discNavigationBarEntries(desktop: desktop),
      // 原盘菜单替换了整套常规控制条，全屏键必须在这里另给一份（同一执行体与
      // 移动端门控：[_buildFullscreenButton] / [_activateVideoControlItem]）。
      if (!isMobilePlatform)
        _videoBarEntry(
          VideoControlItem.fullscreen,
          controller,
          slot: VideoControlSlot.topRight,
          cluster: VideoBarCluster.start,
          child: FushiTooltip(
            message: _videoControlItemTooltip(VideoControlItem.fullscreen),
            child: KeyedSubtree(
              key: const ValueKey<String>('bluray-menu-fullscreen'),
              child: _buildFullscreenButton(desktop: desktop),
            ),
          ),
        ),
    ];
    final Widget title = ValueListenableBuilder<String?>(
      valueListenable: _titleNotifier,
      builder: (BuildContext _, String? value, __) => Text(
        value ?? '',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: _discMenuTitleStyle(),
      ),
    );
    return BlurayDiscMenuChrome(
      visible: _discMenuChromeVisible,
      transitionDuration: _videoControlsTransitionDuration,
      slideEnabled: !apple,
      hiddenOffset: Offset(0, -24 * scale),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      onHoverChanged: _setDiscMenuChromeHovered,
      onFocusChanged: _setDiscMenuChromeFocused,
      child: VideoTopBarSlots(
        titlePlacement: VideoTopBarTitlePlacement.left,
        leftLead: apple
            ? VideoGlassSurface(enabled: true, child: back)
            : const SizedBox.shrink(),
        leftTail: const SizedBox.shrink(),
        title: apple
            ? Align(
                alignment: AlignmentDirectional.centerStart,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8 * scale),
                  child: title,
                ),
              )
            : Align(
                alignment: AlignmentDirectional.centerStart,
                child: VideoM3eFloatingSurface(
                  enabled: true,
                  padding: EdgeInsets.fromLTRB(
                    4 * scale,
                    4 * scale,
                    16 * scale,
                    4 * scale,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      back,
                      SizedBox(width: 4 * scale),
                      Flexible(child: title),
                    ],
                  ),
                ),
              ),
        rightLead: actions.isEmpty
            ? const SizedBox.shrink()
            : VideoGlassSurface(
                enabled: apple,
                padding: EdgeInsets.symmetric(horizontal: 4 * scale),
                child: VideoControlBar(
                  fill: false,
                  clusterStyle: _m3eFloatingBarStyle(verticalAlignment: 0),
                  moreButtonBuilder: (VoidCallback open) =>
                      _videoBarMoreButton(open, desktop: desktop),
                  singleActionButtonBuilder: (VideoBarMenuAction action) =>
                      _videoBarSingleActionButton(action, desktop: desktop),
                  onMenuOpenChanged: _onVideoBarMenuOpenChanged,
                  entries: actions,
                ),
              ),
        rightTail: const SizedBox.shrink(),
      ),
    );
  }

  TextStyle _discMenuTitleStyle() =>
      _m3eChrome ? _m3eTopBarTitleStyle() : _videoControlTitleStyle();

  /// 原盘「主菜单 / 弹出菜单」两个导航钮。播放正片时挂在常规顶栏右上按钮组的头部
  /// （[_topBarSlotGroup]），随控制条一起显隐；菜单模式挂在 [_buildDiscMenuChrome]。
  /// 两处同一份条目，窄屏时都按优先级收进「⋯」。
  List<VideoBarEntry> _discNavigationBarEntries({required bool desktop}) {
    VideoBarEntry entry(
      String key,
      IconData icon,
      String label,
      String action,
    ) {
      void run() {
        _pokeControlsVisible();
        _pokeDiscMenuChrome();
        unawaited(_runDiscNavigation(action));
      }

      return VideoBarEntry(
        // 原盘会话里它们是主导航：比它们先收起的只剩全屏 / 设置以外的一切。
        priority: 87,
        menuAction: VideoBarMenuAction(
          icon: icon,
          label: label,
          onSelected: run,
        ),
        child: FushiTooltip(
          message: label,
          child: KeyedSubtree(
            key: ValueKey<String>(key),
            child: _chromeIconButton(
              icon: icon,
              desktop: desktop,
              onPressed: run,
            ),
          ),
        ),
      );
    }

    return <VideoBarEntry>[
      entry('bluray-menu-top', FushiIcons.toc, t.video_disc_top_menu, 'menu'),
      entry(
        'bluray-menu-popup',
        FushiIcons.menu,
        t.video_disc_popup_menu,
        'popup',
      ),
    ];
  }
}

class _BlurayJavaRuntimeInstallDialog extends StatefulWidget {
  const _BlurayJavaRuntimeInstallDialog({required this.manager});
  final BlurayJavaRuntimeManager manager;
  @override
  State<_BlurayJavaRuntimeInstallDialog> createState() =>
      _BlurayJavaRuntimeInstallDialogState();
}

class _BlurayJavaRuntimeInstallDialogState
    extends State<_BlurayJavaRuntimeInstallDialog> {
  bool _installing = false;
  bool _failed = false;
  double? _progress;

  Future<void> _install() async {
    setState(() {
      _installing = true;
      _failed = false;
    });
    try {
      await widget.manager.install(
        onProgress: (int received, int? total) {
          if (mounted) {
            setState(
              () => _progress = total == null || total <= 0
                  ? null
                  : (received / total).clamp(0.0, 1.0),
            );
          }
        },
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error, stack) {
      ErrorLogService.instance.log(
        'VideoDiscMenu.installRuntime',
        error,
        stack,
      );
      if (mounted) {
        setState(() {
          _failed = true;
          _installing = false;
        });
      }
    }
  }

  @override
  void dispose() {
    widget.manager.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_installing,
    child: FushiAlertDialog(
      title: Text(t.video_disc_runtime_install),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(t.video_disc_runtime_description),
          if (_installing) ...<Widget>[
            const SizedBox(height: 16),
            FushiLinearProgressIndicator(value: _progress),
          ],
          if (_failed) ...<Widget>[
            const SizedBox(height: 16),
            Text(t.video_disc_runtime_install_failed),
          ],
        ],
      ),
      actions: <Widget>[
        FushiTextButton(
          onPressed: () {
            widget.manager.cancel();
            Navigator.of(context).pop(false);
          },
          child: Text(t.cancel),
        ),
        FushiFilledButton(
          onPressed: _installing ? null : _install,
          child: Text(t.video_disc_runtime_install),
        ),
      ],
    ),
  );
}
