part of '../video_fushi_page.dart';

/// 竖屏播放（拍板台 P9AS-fvjJh）：方向策略、竖屏学习版式、竖屏查词卡。
///
/// 判据都在纯 Dart 的 `video_orientation_policy.dart`（可单测），版式几何在
/// `video_portrait_layout.dart`；这里只做页面接线：
///   * 方向：进入时按设置（横屏 / 按视频比例 / 跟随旋转），控件栏转屏按钮（移动端
///     复用「全屏」槽位）随时切换，可按作品记住。方向集唯一出口是主壳的
///     [_VideoFushiPageState._applyVideoOrientationLock]。
///   * 版式：手机竖屏看横版视频 = 视频贴顶 + 当前句 + 页签（字幕 / 选集 / 章节）+ 底部
///     纯图标浮动工具栏；平板竖屏左右分栏；竖版视频铺满（普通播放布局，右侧竖排按钮）。
///   * 查词：竖屏一律从底部升起半屏卡，拖动条可拉到视频下沿，视频暂停但始终看得见。
extension _VideoPortrait on _VideoFushiPageState {
  /// 「记住每部作品的方向」恢复出来的方向；开关关着 / 没记过时 null。
  VideoOrientationLock? get _rememberedOrientation {
    if (!appModel.videoRememberOrientation) return null;
    return VideoOrientationLock.fromRemembered(
      appModel.videoOrientationForWork(_activeBookUid),
    );
  }

  /// 视频尺寸出来 / 变了（换集、换源）时记下宽高比：竖屏版式据此判断竖版视频，
  /// 「按视频比例」进入方向据此决定横竖。只在比例真变时重建。
  void _syncVideoAspectRatio(VideoPlayerController controller) {
    if (!mounted) return;
    final double? aspect = videoAspectRatioOf(
      controller.videoWidth,
      controller.videoHeight,
    );
    if (aspect == null || aspect == _videoAspectRatio) return;
    final VideoOrientationLock before = _videoOrientationLock;
    _rebuild(() => _videoAspectRatio = aspect);
    if (_videoOrientationLock != before) {
      unawaited(_applyVideoOrientationLock());
    }
  }

  /// 偏好仓库通知：只在「竖屏时显示字幕列表」真变了时重建（仓库任何键变都会通知）。
  void _onPortraitPrefsChanged() {
    if (!mounted) return;
    final bool value = appModel.videoPortraitSubtitleList;
    if (value == _portraitSubtitleListPref) return;
    _rebuild(() => _portraitSubtitleListPref = value);
  }

  /// 屏幕此刻是不是竖的（看实际窗口尺寸，不看锁）。
  bool _screenIsPortrait(BuildContext context) {
    final Size size = MediaQuery.sizeOf(context);
    return size.height > size.width;
  }

  /// 控件栏转屏按钮（移动端复用「全屏」槽位）：转到另一边并锁住；开着「记住每部作品的
  /// 方向」时落库。
  void _toggleVideoScreenOrientation() {
    if (!isMobilePlatform) return;
    final VideoOrientationLock target = videoOrientationToggleTarget(
      screenIsPortrait: _screenIsPortrait(context),
    );
    _orientationOverride = target;
    if (appModel.videoRememberOrientation) {
      unawaited(
        appModel.setVideoOrientationForWork(
          _activeBookUid,
          target.storageValue,
        ),
      );
    }
    _pokeControlsVisible();
    unawaited(_applyVideoOrientationLock());
  }

  /// 此刻用哪种竖屏版式（[VideoPortraitLayoutKind.none] = 普通播放布局）。
  VideoPortraitLayoutKind _portraitLayoutKind(BuildContext context) {
    return resolveVideoPortraitLayout(
      mobile: isMobilePlatform,
      screen: MediaQuery.sizeOf(context),
      videoAspectRatio: _videoAspectRatio,
      showSubtitleList: _portraitSubtitleListPref,
      miniSurface: _miniSurface.value != VideoMiniSurface.none,
    );
  }

  /// 竖屏学习版式在场时，把「打开字幕列表 / 选集 / 章节」改成切到下半屏对应页签。
  /// 返回 true = 已处理（调用方不再开横屏那套侧栏 / 横轨）。
  bool _routeToPortraitPane(VideoPortraitTab tab) {
    if (!mounted) return false;
    if (_portraitLayoutKind(context) == VideoPortraitLayoutKind.none) {
      return false;
    }
    _portraitTab.value = tab;
    return true;
  }

  /// 竖屏学习版式（[kind] 非 none）：视频条 + 当前句 + 页签 + 浮动工具栏。
  Widget _buildPortraitLayout(
    VideoPlayerController controller,
    Widget video,
    VideoPortraitLayoutKind kind,
  ) {
    // 横屏时开着的选集横轨在竖屏版式里不渲染（选集是页签），但它的可见标记还会让控件
    // 层整体忽略指针——转进竖屏时收掉它、切到选集页签。
    if (_episodeListVisible.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_episodeListVisible.value) return;
        _closeEpisodeList();
        _portraitTab.value = VideoPortraitTab.episodes;
      });
    }
    final Widget layout = VideoPortraitLayout(
      key: const ValueKey<String>('video-portrait-layout'),
      kind: kind,
      videoAspectRatio: _videoAspectRatio,
      video: _webMode ? _wrapWebVideoSurface(video) : video,
      currentCue: VideoPortraitCurrentCue(
        listenable: controller,
        currentCue: () => controller.currentCue,
        onLookup: _handleSubtitleListLookup,
        onTapCue: _handleSubtitleJumpTap,
        emptyHint: t.video_portrait_no_cue,
        fontFamily: appModel.subtitleFontFamily,
        fontSize: 22 * _videoUiScale,
      ),
      pane: (EdgeInsets insets) => VideoPortraitPane(
        tabs: _portraitTabs(controller),
        selected: _portraitTab,
        onSelect: (VideoPortraitTab tab) => _portraitTab.value = tab,
        insets: insets,
        trailing: <Widget>[_portraitMineQueueButton()],
      ),
      toolbar: _portraitToolbar(controller),
    );
    // 设置 / 速度 / 画质等侧栏挂在整页上（手机竖屏是贴底面板），不压进视频那一条。
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[layout, _buildVideoSidePanelOverlay(controller)],
    );
  }

  /// 下半屏页签：字幕列表常驻；有选集（播放列表）才出选集，有内封章节才出章节。
  List<VideoPortraitTabSpec> _portraitTabs(VideoPlayerController controller) {
    return <VideoPortraitTabSpec>[
      VideoPortraitTabSpec(
        tab: VideoPortraitTab.subtitles,
        icon: FushiIcons.subtitles,
        label: t.video_subtitle_list,
        builder: (BuildContext context, EdgeInsets insets) => LayoutBuilder(
          builder: (BuildContext _, BoxConstraints box) =>
              _buildSubtitleJumpPanel(
                controller,
                key: const ValueKey<String>('video-portrait-subtitle-panel'),
                width: box.maxWidth,
                safeInsets: EdgeInsets.only(bottom: insets.bottom),
                colorScheme: _videoChromeColorScheme(context),
              ),
        ),
      ),
      if (_isPlaylist)
        VideoPortraitTabSpec(
          tab: VideoPortraitTab.episodes,
          icon: FushiIcons.playlist,
          label: t.video_episode_list,
          builder: (BuildContext context, EdgeInsets insets) => Padding(
            padding: insets,
            child: Align(
              alignment: Alignment.topCenter,
              child: VideoEpisodePanel(
                key: const ValueKey<String>('video-portrait-episode-panel'),
                episodes: _episodePanelEntries(),
                currentIndex: _currentEpisode,
                onTapEpisode: _handleEpisodeListTap,
                onClose: () => _portraitTab.value = VideoPortraitTab.subtitles,
                colorScheme: Theme.of(context).colorScheme,
                title: t.video_episode_list,
                emptyHint: t.video_episode_list_empty,
                seasonLabelOf: _episodeSeasonLabel,
                fontSize: _episodePanelFontSize,
              ),
            ),
          ),
        ),
      if (_hasChapters)
        VideoPortraitTabSpec(
          tab: VideoPortraitTab.chapters,
          icon: FushiIcons.numberedList,
          label: t.video_chapters,
          builder: (BuildContext context, EdgeInsets insets) => Padding(
            padding: insets,
            // 当前章随播放位置变，跟着播放器重建。
            child: ListenableBuilder(
              listenable: controller,
              builder: (BuildContext _, Widget? __) =>
                  _buildChapterSidePanel(controller),
            ),
          ),
        ),
    ];
  }

  /// 页签行尾部的「待写入 Anki」入口：只在「看完再制卡」列表里有卡时出现，角标是张数。
  Widget _portraitMineQueueButton() {
    return ValueListenableBuilder<int>(
      valueListenable: _stagedMineCount,
      builder: (BuildContext context, int count, Widget? _) {
        if (count <= 0) return const SizedBox.shrink();
        return FushiPressScale(
          child: FushiIconButtonControl(
            key: const ValueKey<String>('video-portrait-mine-queue'),
            tooltip: t.video_mine_queue_title,
            icon: FushiBadgeControl.count(
              count: count,
              child: const FushiIcon(FushiIcons.ankiCard),
            ),
            onPressed: () => unawaited(_openVideoMineQueue()),
          ),
        );
      },
    );
  }

  /// 底部纯图标浮动工具栏：上一句 / 播放 / 下一句 / 循环本句 / 收藏本句。
  Widget _portraitToolbar(VideoPlayerController controller) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        controller,
        controller.loopCurrentCueListenable,
      ]),
      builder: (BuildContext context, Widget? _) {
        final AudioCue? cue = _currentCueForAction();
        final bool favorited = cue != null && _isCueFavorited(cue);
        return videoPortraitToolbar(
          items: <FushiToolbarItem>[
            FushiToolbarItem(
              key: const ValueKey<String>('video-portrait-prev-cue'),
              icon: FushiIcons.skipPrevious,
              label: t.video_control_previous_cue,
              onPressed: () =>
                  unawaited(_skipCueAndPokeControls(forward: false)),
            ),
            FushiToolbarItem(
              key: const ValueKey<String>('video-portrait-play'),
              icon: controller.isPlaying ? FushiIcons.pause : FushiIcons.play,
              label: t.video_control_play_pause,
              emphasized: true,
              onPressed: () => unawaited(controller.playOrPause()),
            ),
            FushiToolbarItem(
              key: const ValueKey<String>('video-portrait-next-cue'),
              icon: FushiIcons.skipNext,
              label: t.video_control_next_cue,
              onPressed: () =>
                  unawaited(_skipCueAndPokeControls(forward: true)),
            ),
            FushiToolbarItem(
              key: const ValueKey<String>('video-portrait-loop-cue'),
              icon: FushiIcons.repeatOne,
              label: ShortcutAction.videoToggleLoopCurrentSubtitle.label,
              selected: controller.loopCurrentCue,
              onPressed: _toggleLoopCurrentCue,
            ),
            FushiToolbarItem(
              key: const ValueKey<String>('video-portrait-favorite'),
              icon: FushiIcons.star,
              label: ShortcutAction.videoToggleFavoriteSentence.label,
              selected: favorited,
              onPressed: () => unawaited(_toggleFavoriteCurrentCue()),
            ),
          ],
        );
      },
    );
  }

  /// 竖屏（任何竖屏版式）时查词卡强制从底部升起。
  ///
  /// 这个判据在根 Overlay 浮层栈的 layout 回调里被读（mixin 的停靠判断），不能借本页
  /// `context` 查 MediaQuery（浮层可能比本页 element 活得久、且不在本页 build 里）——
  /// 直接看平台视图的物理尺寸。
  bool get _portraitLookupDock {
    if (!mounted || !isMobilePlatform) return false;
    final Size? size =
        WidgetsBinding.instance.platformDispatcher.implicitView?.physicalSize;
    return size != null && size.height > size.width;
  }

  /// 竖屏查词卡最高升到的位置：学习版式 = 视频条下沿（视频始终看得见）；画面铺满时 = 0。
  /// 取版式 build 时记下的值（[_VideoFushiPageState._portraitVideoBottom]），理由同上。
  double _portraitLookupTopReserve(Size screen) =>
      _portraitVideoBottom.clamp(0, screen.height).toDouble();

  /// 竖屏查词卡高度：拖动中跟手，否则收起半屏 / 拉满到视频下沿。
  double _portraitLookupSheetHeight(Size screen) {
    final double reserve = _portraitLookupTopReserve(screen);
    final double full = math.max(0, screen.height - reserve);
    final double? dragging = _portraitLookupDragHeight;
    if (dragging != null) return dragging.clamp(0, full).toDouble();
    return videoPortraitLookupSheetHeight(
      screen: screen,
      videoBottom: reserve,
      expanded: _portraitLookupExpanded,
    );
  }

  /// 竖屏查词卡顶上的拖动条（根 Overlay 浮层栈里、卡片上沿之上）：上拉拉满到视频下沿，
  /// 下拉收回半屏；点一下在两档间切换。卡片本体是原生 WebView，拖动条必须是卡片外的
  /// Flutter 层才收得到手势。
  Widget _buildPortraitLookupDragHandle(Size screen, ColorScheme cs) {
    final double height = _portraitLookupSheetHeight(screen);
    // 与 resolvePopupRect 停靠分支同一几何（纵向留白 6），拖动条贴在卡片上沿外侧。
    final Rect dock = dockedPopupRect(
      screen: screen,
      dockedHeight: height,
      topReserve: _portraitLookupTopReserve(screen),
    );
    const double handleHeight = 28;
    return Positioned(
      left: 0,
      right: 0,
      top: math.max(0, dock.top - handleHeight),
      height: handleHeight,
      child: Semantics(
        button: true,
        label: t.video_portrait_lookup_resize,
        child: GestureDetector(
          key: const ValueKey<String>('video-portrait-lookup-handle'),
          behavior: HitTestBehavior.opaque,
          onTap: () => _rebuild(() {
            _portraitLookupExpanded = !_portraitLookupExpanded;
            _portraitLookupDragHeight = null;
          }),
          onVerticalDragStart: (DragStartDetails _) =>
              _rebuild(() => _portraitLookupDragHeight = height),
          onVerticalDragUpdate: (DragUpdateDetails details) => _rebuild(
            () => _portraitLookupDragHeight =
                (_portraitLookupDragHeight ?? height) - details.delta.dy,
          ),
          onVerticalDragEnd: (DragEndDetails details) {
            final double reserve = _portraitLookupTopReserve(screen);
            final double full = screen.height - reserve;
            final double half = screen.height / 2;
            final double current = _portraitLookupDragHeight ?? height;
            final double velocity = details.primaryVelocity ?? 0;
            // 甩动看方向，慢拖看停在哪档更近。
            final bool expand = velocity.abs() > 300
                ? velocity < 0
                : (current - full).abs() < (current - half).abs();
            _rebuild(() {
              _portraitLookupExpanded = expand;
              _portraitLookupDragHeight = null;
            });
          },
          onVerticalDragCancel: () =>
              _rebuild(() => _portraitLookupDragHeight = null),
          child: Center(
            child: Container(
              width: 40,
              height: 5,
              // M3 底部面板拖动条：全圆角胶囊。
              decoration: ShapeDecoration(
                shape: const StadiumBorder(),
                color: cs.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
