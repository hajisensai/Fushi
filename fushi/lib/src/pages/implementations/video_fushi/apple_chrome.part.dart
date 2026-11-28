part of '../video_fushi_page.dart';

/// 视频播放器 Apple（Cupertino，判据唯一是 `isGlassDesign(context)` →
/// [_appleChrome]）外观：方案 C「分层」（Apple TV app / AVKit 式，用户 2026-11-24
/// 拍板，效果图 `fushi/build/video_player_cupertino_design/index.html`），按用户修改
/// 去掉画面中央的大三键。M3E（含 iOS / macOS 上的 M3E 用户）完全不走这里。
///
/// - 左上：返回玻璃圆钮 + 靠左标题；右上：一枚玻璃胶囊（少量动作 + 唯一的「⋯」）。
/// - 桌面（macOS 宽窗）：底部一条单行宽浮动玻璃条——播放 / −N / +N · 前导簇 ·
///   已播时间 · 进度条（行内）· 剩余时间 · 后随簇。
/// - 触屏（iOS 横屏）：进度条 + 两端时间一行（fork 原生进度条，横滑 seek 预览照旧），
///   其下左右两枚玻璃胶囊（左：播放 / −N / +N · 前导簇；右：后随簇）。
/// - 画面中央任何时候都不放控件（[_m3eCenterControlsBar] 对 Apple 恒空）。
///
/// 区域归属是纯函数 [planVideoAppleChrome]；放不下时逐颗收进「⋯」仍是
/// [VideoControlBar] 的判据；密度档（full / compact / mini）照旧，mini 档整条顶栏 /
/// 底栏收起，小窗 chrome（[_buildMiniWindowTopChrome]）不动。
///
/// 显隐：所有玻璃与玻璃上的内容都挂在 media_kit 控制条子树里，由 fork 的同一条
/// 淡入淡出进度驱动（[fushiChromeFade] → 玻璃着色器 visibility，内容
/// [FushiGlassPresenceFade] 同值 Opacity），玻璃底与内容是一个整体，不会一先一后；
/// 底部条另随显隐下沉 10（[VideoM3eChromeSlide]，玻璃与内容同一个 Transform）。
extension _VideoAppleChrome on _VideoFushiPageState {
  /// 排版形态：桌面控制条（含 Windows / Linux 的 Apple 外观）走单行条，触屏走
  /// AVKit iOS 骨架。不看平台。
  VideoAppleChromeForm get _appleChromeForm => _isDesktopVideoControls
      ? VideoAppleChromeForm.desktop
      : VideoAppleChromeForm.touch;

  /// 当前布局的区域规划（[planVideoAppleChrome]）。
  VideoAppleChromePlan _appleChromePlan(VideoControlLayout layout) =>
      planVideoAppleChrome(
        layout: layout,
        form: _appleChromeForm,
        renders: _shouldRenderControlItem,
      );

  /// 桌面 Apple：进度条在底部条行内（fork 不再单独画进度条）。
  bool get _appleInlineSeekLane =>
      _appleChrome &&
      _isDesktopVideoControls &&
      _controlsDensity.showBottomButtonBar &&
      _controlsDensity.showSeekBar;

  /// 进度条两端时间的字样（AVKit：13pt 等宽数字、白色降一级透明度）。
  TextStyle get _appleTimeLabelStyle => TextStyle(
    height: 1.0,
    fontSize:
        (context.fushiType.bodySmall.fontSize ?? 13) *
        _videoUiScale *
        _controlsDensityScale,
    fontWeight: FontWeight.w500,
    color: videoChromeNeutralForeground.withValues(alpha: 0.85),
    fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
  );

  /// 触屏：进度条两端给时间标签让出的宽度（含与轨道的间距）。与 fork 进度条
  /// `seekBarMargin`、章节刻度层同源（[_videoSeekBarSideInset]）。
  double get _appleTouchTimeLabelReserve =>
      videoAppleTimeLabelMaxWidth(
        _appleTimeLabelStyle,
        MediaQuery.textScalerOf(context),
      ) +
      10 * _videoUiScale * _controlsDensityScale;

  // ---------------------------------------------------------------------------
  // 顶栏
  // ---------------------------------------------------------------------------

  /// 顶栏（fork `topButtonBar`）：左上返回圆钮 + 靠左标题，右上玻璃胶囊。
  List<Widget> _appleTopButtonBar(
    VideoPlayerController controller,
    VideoControlLayout layout, {
    required bool desktop,
  }) {
    if (!_controlsDensity.showTopBar) return const <Widget>[];
    final VideoAppleChromePlan plan = _appleChromePlan(layout);
    return <Widget>[
      Expanded(
        child: VideoTopBarSlots(
          leftLead: plan.showBack
              ? _appleBackButton(controller, desktop: desktop)
              : const SizedBox.shrink(),
          leftTail: const SizedBox.shrink(),
          title: plan.showTitle
              ? Padding(
                  padding: EdgeInsetsDirectional.only(
                    start: 10 * _videoUiScale,
                  ),
                  child: _topBarTitleText(
                    alignment: AlignmentDirectional.centerStart,
                  ),
                )
              : const SizedBox.shrink(),
          titlePlacement: VideoTopBarTitlePlacement.left,
          rightLead: _appleTopTrailingGroup(
            controller,
            layout,
            plan,
            desktop: desktop,
          ),
          rightTail: const SizedBox.shrink(),
        ),
      ),
    ];
  }

  /// 左上返回：一枚玻璃圆钮（与其它控制条按钮同一执行体）。
  Widget _appleBackButton(
    VideoPlayerController controller, {
    required bool desktop,
  }) {
    return VideoGlassSurface(
      enabled: true,
      child: FushiTooltip(
        message: _videoControlItemTooltip(VideoControlItem.back),
        child: _chromeIconButton(
          icon: _videoControlItemIcon(VideoControlItem.back),
          desktop: desktop,
          onPressed: () => _activateVideoControlItem(
            VideoControlItem.back,
            controller,
            sourceSlot: VideoControlSlot.topLeft,
          ),
        ),
      ),
    );
  }

  /// 右上玻璃胶囊：网页托管 / 跳转回退 / 原盘菜单（有才出现）· 规划里的右上按钮 ·
  /// 「⋯」。
  ///
  /// 有条件出现的按钮与其余按钮**同在这一枚胶囊里**，作为普通条目出现 / 消失
  /// （iOS / macOS 27 工具栏的做法：一组相关动作共用一块玻璃，按钮增减时胶囊
  /// 平滑伸缩），不另起玻璃形状——单独一颗圆钮紧挨胶囊会被液态玻璃融成一团、
  /// 中间一道颈缩。胶囊宽度变化走 [FushiAnimatedSize]（[FushiMotion.short]），跳转
  /// 按钮自带插入时的弹簧缩放 + 淡入（强调态 [FushiToolbarButton]）。
  ///
  /// 「⋯」是整套 chrome 唯一的常驻溢出菜单：被移出播放器的全部动作（M3E 分在右上 /
  /// 右下两个「⋯」）、触屏收进来的截图、跳转记录都在这里；传输组（播放 / ±N）恒在
  /// 底部条，不进菜单。跳转记录随历史变化、全屏路由不随页面 setState 重建，所以整组
  /// 包一层 [ListenableBuilder]（与 M3E 右上组同一个 listenable）。
  Widget _appleTopTrailingGroup(
    VideoPlayerController controller,
    VideoControlLayout layout,
    VideoAppleChromePlan plan, {
    required bool desktop,
  }) {
    return ListenableBuilder(
      listenable: _videoJumpToolbarListenable,
      builder: (BuildContext jumpContext, Widget? _) {
        final VideoBarEntry? jumpMenu = _videoJumpHistoryMenuEntry(jumpContext);
        final Widget? webHosting = _webHostingButton(desktop: desktop);
        final List<VideoBarEntry> entries = <VideoBarEntry>[
          // 有条件出现的条目钉死（不参与收起）、带身份键：插在前面时后面的按钮
          // 不错位继承状态。
          if (webHosting != null)
            VideoBarEntry(
              slotKey: const ValueKey<String>('video_web_hosting_top_bar'),
              child: webHosting,
            ),
          for (final ({Key key, Widget button}) b in _videoJumpHistoryButtons(
            jumpContext,
            desktop: desktop,
          ))
            VideoBarEntry(slotKey: b.key, child: b.button),
          if (controller.isBlurayNavigationSession)
            ..._discNavigationBarEntries(desktop: desktop),
          for (final VideoApplePlacement p in plan.topTrailing)
            _appleBarEntry(
              p,
              controller,
              desktop: desktop,
              // 触屏的设置钮是唯一的设置入口，不收进「⋯」（pinnedOnTouch）。
              pinned:
                  !desktop &&
                  p.item == VideoControlItem.settings &&
                  p.item.pinnedOnTouch,
            ),
          ..._foldedBarEntries(
            layout,
            controller,
            slot: VideoControlSlot.topRight,
            include: (VideoControlItem item) => !videoAppleFoldedExcludes(item),
          ),
          for (final VideoApplePlacement p in plan.extraFolded)
            VideoBarEntry(
              cluster: VideoBarCluster.end,
              folded: true,
              menuAction: _videoBarMenuAction(
                p.item,
                controller,
                slot: p.sourceSlot,
              ),
              child: const SizedBox.shrink(),
            ),
          if (jumpMenu != null) jumpMenu,
        ];
        if (entries.isEmpty) return const SizedBox.shrink();
        return VideoGlassSurface(
          enabled: true,
          padding: EdgeInsets.symmetric(horizontal: 4 * _videoUiScale),
          // 玻璃是子树背后的 Positioned.fill 兄弟层：胶囊宽度随 [FushiAnimatedSize]
          // 逐帧变化，玻璃跟着一起伸缩（右端锚定，向左长出 / 收回）。
          child: FushiAnimatedSize(
            duration: fushiMotionDuration(context, FushiMotion.short),
            curve: FushiMotion.standard,
            alignment: AlignmentDirectional.centerEnd,
            child: VideoControlBar(
              fill: false,
              moreButtonBuilder: (VoidCallback open) =>
                  _videoBarMoreButton(open, desktop: desktop),
              singleActionButtonBuilder: (VideoBarMenuAction action) =>
                  _videoBarSingleActionButton(action, desktop: desktop),
              onMenuOpenChanged: _onVideoBarMenuOpenChanged,
              entries: entries,
            ),
          ),
        );
      },
    );
  }

  /// 一颗按钮在 [VideoControlBar] 里的条目（与 M3E 同一执行体 / 收起优先级）。
  /// [pinned] 为 true 时不参与收起。
  VideoBarEntry _appleBarEntry(
    VideoApplePlacement p,
    VideoPlayerController controller, {
    required bool desktop,
    VideoBarCluster cluster = VideoBarCluster.start,
    bool pinned = false,
  }) {
    final Widget child = p.item == VideoControlItem.volume
        ? _buildVolumeButton(controller, desktop: desktop, slot: p.sourceSlot)
        : _buildBottomSlotButton(
            p.item,
            controller,
            desktop: desktop,
            slot: p.sourceSlot,
          );
    if (pinned) {
      return VideoBarEntry(cluster: cluster, child: child);
    }
    return _videoBarEntry(
      p.item,
      controller,
      slot: p.sourceSlot,
      cluster: cluster,
      child: child,
    );
  }

  // ---------------------------------------------------------------------------
  // 底栏
  // ---------------------------------------------------------------------------

  /// 底栏（fork `bottomButtonBar`）：桌面单行条 / 触屏两枚胶囊。
  List<Widget> _appleBottomButtonBar(
    VideoPlayerController controller,
    VideoControlLayout layout, {
    required bool desktop,
  }) {
    if (!_controlsDensity.showBottomButtonBar) return const <Widget>[];
    final VideoAppleChromePlan plan = _appleChromePlan(layout);
    final double k = _videoUiScale * _controlsDensityScale;
    final Widget bar = desktop
        ? _appleDesktopBar(controller, plan, k: k)
        : _appleTouchBar(controller, plan, k: k);
    return <Widget>[
      Expanded(
        // 显隐时整条（玻璃 + 内容同一个 Transform）下沉 10。
        child: VideoM3eChromeSlide(
          enabled: true,
          visible: _mediaKitControlsVisible,
          hiddenOffset: Offset(0, 10 * k),
          hiddenScale: 1,
          child: bar,
        ),
      ),
    ];
  }

  List<VideoBarEntry> _appleLeadingEntries(
    VideoPlayerController controller,
    VideoAppleChromePlan plan, {
    required bool desktop,
  }) {
    return <VideoBarEntry>[
      for (final VideoApplePlacement p in plan.transport)
        _appleBarEntry(
          p,
          controller,
          desktop: desktop,
          // 传输组恒在（画面中央不再有第二套），放不下时最后才收（±N 仍可收，
          // 播放 / 暂停本就是钉死项）。
        ),
      for (final VideoApplePlacement p in plan.bottomLeading)
        _appleBarEntry(p, controller, desktop: desktop),
    ];
  }

  List<VideoBarEntry> _appleTrailingEntries(
    VideoPlayerController controller,
    VideoAppleChromePlan plan, {
    required bool desktop,
  }) {
    return <VideoBarEntry>[
      for (final VideoApplePlacement p in plan.bottomTrailing)
        _appleBarEntry(
          p,
          controller,
          desktop: desktop,
          cluster: VideoBarCluster.end,
          pinned:
              !desktop &&
              p.item == VideoControlItem.settings &&
              p.item.pinnedOnTouch,
        ),
    ];
  }

  Widget _appleCluster(List<VideoBarEntry> entries, {required bool desktop}) {
    if (entries.isEmpty) return const SizedBox.shrink();
    return VideoControlBar(
      fill: false,
      moreButtonBuilder: (VoidCallback open) =>
          _videoBarMoreButton(open, desktop: desktop),
      singleActionButtonBuilder: (VideoBarMenuAction action) =>
          _videoBarSingleActionButton(action, desktop: desktop),
      onMenuOpenChanged: _onVideoBarMenuOpenChanged,
      entries: entries,
    );
  }

  /// 桌面：一条单行宽浮动玻璃条，进度条在行内。
  Widget _appleDesktopBar(
    VideoPlayerController controller,
    VideoAppleChromePlan plan, {
    required double k,
  }) {
    final Player? player = controller.videoController?.player;
    final bool times = plan.showPositionIndicator && player != null;
    final bool lane = _controlsDensity.showSeekBar;
    final double height = _videoButtonBarHeight * _controlsDensityScale;
    return VideoGlassSurface(
      enabled: true,
      radius: math.min(height / 2, kVideoAppleCapsuleMaxRadius),
      padding: EdgeInsets.symmetric(horizontal: 6 * k),
      child: VideoAppleBarRow(
        gap: 6 * k,
        minLaneWidth: lane ? 120 * k : 0,
        trailingReserve: height,
        leading: _appleCluster(
          _appleLeadingEntries(controller, plan, desktop: true),
          desktop: true,
        ),
        elapsed: times
            ? VideoAppleTimeLabel(
                player: player,
                style: _appleTimeLabelStyle,
                remaining: false,
              )
            : null,
        lane: lane ? _appleInlineSeekLaneContent(controller) : null,
        remaining: times
            ? VideoAppleTimeLabel(
                player: player,
                style: _appleTimeLabelStyle,
                remaining: true,
              )
            : null,
        trailing: _appleCluster(
          _appleTrailingEntries(controller, plan, desktop: true),
          desktop: true,
        ),
      ),
    );
  }

  /// 桌面行内进度条道：fork 的桌面进度条（拖动 / 悬停 / 缩略图回调与原先同一套接线）
  /// + 章节 / OP·ED 刻度 + 跳转落点刻度 + 悬停缩略图，全在同一次布局里按道宽对齐
  /// （不再是控制条外按整宽内缩推算的兄弟层）。
  Widget _appleInlineSeekLaneContent(VideoPlayerController controller) {
    final double d = _controlsDensityScale;
    final double tickHeight =
        (_videoSeekBarTrackHeight + 8.0 * _videoUiScale) * d;
    final bool rtl = Directionality.of(context) == TextDirection.rtl;
    final VideoThumbnailPreviewController? preview = _thumbnailPreview;
    return LayoutBuilder(
      builder: (BuildContext _, BoxConstraints constraints) {
        final double h = constraints.maxHeight;
        final double laneWidth = constraints.maxWidth;
        final double bandTop = (h - tickHeight) / 2;
        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned.fill(
              child: Center(
                child: MaterialDesktopSeekBar(
                  onHoverPosition: _onSeekBarHover,
                  onSeekStart: () {
                    controller.clearSeekTargetSnap();
                    _onSeekBarJumpStart(controller);
                    // 行内进度条不在 fork 控制条状态里，拖动期间由宿主按住控制条
                    // （松手后 fork 收到放开即重排自动隐藏计时）。
                    _controlsHoldSeekDrag = true;
                    _syncControlsHold();
                  },
                  onSeekEnd: (Duration target) {
                    controller.notifyExternalSeek(target.inMilliseconds);
                    _controlsHoldSeekDrag = false;
                    _syncControlsHold();
                  },
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: bandTop,
              height: tickHeight,
              child: IgnorePointer(
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    ValueListenableBuilder<List<VideoChapter>>(
                      valueListenable: _themeSongChapters,
                      builder: (BuildContext _, List<VideoChapter> extra, __) {
                        if (!_hasChapters && extra.isEmpty) {
                          return const SizedBox.shrink();
                        }
                        return VideoChapterMarkers(
                          controller: controller,
                          color: _VideoFushiPageState._videoChromeNeutralFg
                              .withValues(alpha: 0.7),
                          thickness: 2.0 * _videoUiScale,
                          extraChapters: _themeSongChapters,
                        );
                      },
                    ),
                    _videoJumpProgressMarks(
                      controller: controller,
                      tickWidth: 3 * _videoUiScale * d,
                      tickHeight: tickHeight,
                      rtl: rtl,
                    ),
                  ],
                ),
              ),
            ),
            if (preview != null)
              VideoThumbnailPreviewOverlay(
                controller: preview,
                trackWidth: laneWidth,
                bottomOffset: bandTop + tickHeight + 6.0 * _videoUiScale,
                colorScheme: _videoChromeColorScheme(context),
                uiScale: _videoUiScale,
                // 本层挂在控制条子树里，控制条隐藏即整层淡出 / 卸载。
                controlsVisible: true,
              ),
          ],
        );
      },
    );
  }

  /// 触屏：进度条一行（fork 原生进度条 + 两端时间）+ 左右两枚玻璃胶囊。
  Widget _appleTouchBar(
    VideoPlayerController controller,
    VideoAppleChromePlan plan, {
    required double k,
  }) {
    final Player? player = controller.videoController?.player;
    final bool times =
        plan.showPositionIndicator &&
        player != null &&
        _controlsDensity.showSeekBar;
    final double barHeight = _videoButtonBarHeight * _controlsDensityScale;
    // 轨道中线相对按钮行容器上沿的位置：fork 进度条与按钮行都在控制条区底部对齐，
    // 按钮行容器下沿离控制条区底边 = 底部基线 + 系统 inset + 抬升（主题同一组量）。
    final double barBottom =
        _VideoFushiPageState._videoBottomChromeBaseline +
        _videoBottomSystemInset() +
        _floatingChromeBottomLift;
    final double trackAboveBarTop =
        _videoSeekBarTrackCenter - (barBottom + barHeight);
    final double labelHeight = 16 * k;
    final Widget capsules = VideoAppleBarRow(
      gap: 12 * k,
      minLaneWidth: 12 * k,
      trailingReserve: barHeight,
      leading: _appleTouchCapsule(
        _appleLeadingEntries(controller, plan, desktop: false),
        k: k,
      ),
      trailing: _appleTouchCapsule(
        _appleTrailingEntries(controller, plan, desktop: false),
        k: k,
      ),
    );
    if (!times) return capsules;
    final double side = _videoSeekBarSideInset - _videoAppleButtonBarSideInset;
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        Positioned.fill(child: capsules),
        // 两端时间挂在按钮行上方、与 fork 进度条轨道中线对齐（纯文字，不吃指针）。
        Positioned(
          left: 0,
          right: 0,
          top: -trackAboveBarTop - labelHeight / 2,
          height: labelHeight,
          child: IgnorePointer(
            child: FushiGlassPresenceFade(
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: side,
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: VideoAppleTimeLabel(
                        player: player,
                        style: _appleTimeLabelStyle,
                        remaining: false,
                      ),
                    ),
                  ),
                  const Spacer(),
                  SizedBox(
                    width: side,
                    child: Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: VideoAppleTimeLabel(
                        player: player,
                        style: _appleTimeLabelStyle,
                        remaining: true,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _appleTouchCapsule(List<VideoBarEntry> entries, {required double k}) {
    if (entries.isEmpty) return const SizedBox.shrink();
    return VideoGlassSurface(
      enabled: true,
      padding: EdgeInsets.symmetric(horizontal: 2 * k),
      child: _appleCluster(entries, desktop: false),
    );
  }
}
