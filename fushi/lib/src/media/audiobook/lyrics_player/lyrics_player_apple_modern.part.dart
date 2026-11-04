part of 'lyrics_player_apple.dart';

// Apple 设计系统的歌词模式「新版」播放控件（`LyricsControlsStyle.modern`；经典见
// [AppleLyricsPlayerDesign]）。布局与交互与 MD3 新版一致——几何 / 测宽 /
// 读数 / 卡片展开交互出自共享的 lyrics_player_modern_shared.dart，这里只换成 Apple
// 现有的件：模糊封面背景、白字透明度阶梯、无底 / 实色圆底的白色图标键、Niratan
// 胶囊进度条、实色悬浮卡片（`fushiAppleSolidFloatingDecoration`）。
//
// 宽屏：正文横向占满；底部无底板（一层渐隐压暗），上方整宽进度线 + 两端时间、
// 中间一行读数；左：完整封面 + 书名 / 章名；中：实色圆底的 −10 秒 / 上一句 /
// 下一句 / +10 秒 + 更大的播放键（Apple 原样白色大字形，不用多边形）；右：圆角
// 方块按钮组（全部次要动作，放不下按优先级收进 ⋯）+ 关闭。底栏常驻、不自动收起。
//
// 窄屏：页眉沿用经典（返回 · 书名读数 · 顶部区按钮 · ⋯ · ×）；底部实色悬浮卡两态：
// 收起 = 迷你条（封面 · 章名时间 · 重播 · 上一句 · 播放 · 下一句 + 底边细进度），
// 展开 = 头行封面 + 章名 + 次要键、Niratan 进度条带两端时间、五颗主控键。

/// 窄屏迷你条 / 展开卡里的封面缩略图高度。
const double _kAppleModernThumbHeight = 40;

/// 窄屏迷你条：主控键边长 / 播放键边长。
const double _kAppleModernMiniButton = 44;
const double _kAppleModernMiniPlay = 48;

/// 窄屏展开卡：主控键 / 播放键边长、内边距、行距。
const double _kAppleModernFullButton = 44;
const double _kAppleModernFullPlay = 52;
const double _kAppleModernFullPadding = 14;
const double _kAppleModernFullGap = 8;

/// 迷你条：内容上边距、底边细进度带高（3 线 + 上下留白）。
const double _kAppleModernMiniTop = 8;
const double _kAppleModernMiniLineBand = 14;

/// 卡片顶部把手命中区高度（视觉是 36×5 的短条）。
const double _kAppleModernGrabHeight = 12;

/// 卡片圆角（连续曲率）。
const BorderRadius _kAppleModernCardRadius = BorderRadius.all(
  Radius.circular(26),
);

/// 窄屏卡片的字（字阶角色 + 深底白字，不写裸字号）。
@immutable
class _AppleModernText {
  const _AppleModernText._({required this.title, required this.miniLabel});

  factory _AppleModernText.of(BuildContext context) {
    final FushiTypography type = context.fushiType;
    final Color label = Colors.white.withValues(alpha: 0.94);
    return _AppleModernText._(
      title: type.titleSmallEmphasized.copyWith(
        color: label,
        fontWeight: FontWeight.w700,
      ),
      miniLabel: type.labelMediumEmphasized.copyWith(
        color: label,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  /// 展开卡头行（章名 / 书名）。
  final TextStyle title;

  /// 迷你条章名。
  final TextStyle miniLabel;
}

/// 新版 Apple 歌词播放器外观。
class AppleModernLyricsPlayerDesign extends LyricsPlayerDesign {
  const AppleModernLyricsPlayerDesign({required this.compactExpanded});

  /// 窄屏播放卡展开（目标态）。歌词矩形直接按目标态算：WebView 不随卡片高度逐帧
  /// 改尺寸，卡片自己做高度动画。
  final bool compactExpanded;

  @override
  Rect lyricsRect(BuildContext context, Size size, EdgeInsets padding) {
    if (lyricsPlayerIsWide(size)) {
      final LyricsModernWideGeometry g = LyricsModernWideGeometry.of(
        context,
        size,
        padding,
      );
      return g.lyrics;
    }
    final _AppleModernNarrowGeometry g = _AppleModernNarrowGeometry.of(
      context,
      size,
      padding,
    );
    final Rect header = g.layout.lyricsRect;
    final double bottom = g.cardTopAt(compactExpanded ? 1 : 0) - 6;
    return Rect.fromLTRB(
      header.left,
      header.top,
      header.right,
      math.max(header.top + 1, bottom),
    );
  }

  @override
  Widget buildBackground(BuildContext context, LyricsPlayerData data) =>
      const AppleLyricsPlayerDesign().buildBackground(context, data);

  @override
  Widget buildChrome(
    BuildContext context,
    LyricsPlayerData data,
    LyricsPlayerCallbacks callbacks, {
    required Size size,
    required EdgeInsets padding,
    required Rect lyricsRect,
  }) {
    // 几何在深色档之外算（与 [lyricsRect] 同一 context，歌词矩形与控件不会错位）；
    // 歌词页恒是深底，控件用深色档的白字 / 悬停底。
    final bool wide = lyricsPlayerIsWide(size);
    return FushiAppleDarkTier(
      child: wide
          ? _AppleModernWideChrome(
              data: data,
              callbacks: callbacks,
              size: size,
              padding: padding,
              geometry: LyricsModernWideGeometry.of(context, size, padding),
            )
          : _AppleModernNarrowChrome(
              data: data,
              callbacks: callbacks,
              size: size,
              padding: padding,
              geometry: _AppleModernNarrowGeometry.of(context, size, padding),
            ),
    );
  }

  @override
  LyricsHtmlTheme htmlTheme(BuildContext context, LyricsPlayerData data) =>
      const AppleLyricsPlayerDesign().htmlTheme(context, data);
}

// ---------------------------------------------------------------------------
// 共用小件
// ---------------------------------------------------------------------------

/// 封面位（兼插图入口）：Apple 外观的占位与留边底色。
Widget _appleModernArtwork(
  LyricsPlayerData data,
  LyricsPlayerCallbacks callbacks, {
  required double height,
  bool uncropped = false,
}) => lyricsModernArtwork(
  data,
  callbacks,
  height: height,
  uncropped: uncropped,
  borderRadius: const BorderRadius.all(Radius.circular(8)),
  backdrop: Colors.white.withValues(alpha: 0.08),
  placeholder: (BuildContext context) => ColoredBox(
    color: Colors.white.withValues(alpha: 0.12),
    child: Center(
      child: Icon(
        CupertinoIcons.book,
        size: height * 0.45,
        color: Colors.white.withValues(alpha: 0.48),
      ),
    ),
  ),
);

/// 主控键：−10 秒 / [重播] / 上一句 / 播放 / 下一句 / +10 秒。侧键是实色圆底
/// （新版布局的「实心圆」），播放键保持 Apple 原样的无底白色大字形。按下带
/// [FushiPressScale] 缩放。
List<Widget> _appleModernTransport(
  LyricsPlayerData data,
  LyricsPlayerCallbacks callbacks, {
  required double side,
  required double play,
  bool relativeSeek = true,
  bool replay = false,
}) {
  final double sideIcon = (side * 0.48).roundToDouble();
  final bool playing = data.isPlaying;
  Widget sideButton({
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) => FushiPressScale(
    child: _LyricsIconButton(
      key: key,
      icon: icon,
      diameter: side,
      iconSize: sideIcon,
      tooltip: tooltip,
      onPressed: onPressed,
    ),
  );
  final ValueChanged<int>? seekBy = relativeSeek
      ? callbacks.onSeekRelative
      : null;
  final VoidCallback? onReplay = replay ? callbacks.onReplayCue : null;
  return <Widget>[
    if (seekBy != null)
      sideButton(
        key: const ValueKey<String>('lyrics_seek_back_button'),
        icon: CupertinoIcons.gobackward_10,
        tooltip: '-10s',
        onPressed: () => seekBy(-10),
      ),
    if (onReplay != null)
      FushiPressScale(
        child: _LyricsIconButton(
          key: const ValueKey<String>('lyrics_replay_cue_button'),
          icon: CupertinoIcons.arrow_counterclockwise,
          diameter: side,
          iconSize: sideIcon - 2,
          tooltip: t.lyrics_sentence_replay,
          onPressed: onReplay,
        ),
      ),
    sideButton(
      key: const ValueKey<String>('lyrics_previous_cue_button'),
      icon: CupertinoIcons.backward_end_fill,
      tooltip: t.floating_lyric_previous,
      onPressed: callbacks.onPreviousCue,
    ),
    FushiPressScale(
      child: _LyricsIconButton(
        key: const ValueKey<String>('lyrics_play_button'),
        icon: playing ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill,
        iconKey: ValueKey<bool>(playing),
        diameter: play,
        iconSize: (play * (playing ? 0.66 : 0.6)).roundToDouble(),
        tooltip: playing ? t.pause : t.play,
        onPressed: callbacks.onPlayPause,
      ),
    ),
    sideButton(
      key: const ValueKey<String>('lyrics_next_cue_button'),
      icon: CupertinoIcons.forward_end_fill,
      tooltip: t.floating_lyric_next,
      onPressed: callbacks.onNextCue,
    ),
    if (seekBy != null)
      sideButton(
        key: const ValueKey<String>('lyrics_seek_forward_button'),
        icon: CupertinoIcons.goforward_10,
        tooltip: '+10s',
        onPressed: () => seekBy(10),
      ),
  ];
}

/// 进度细线（只看不点）：Niratan 轨道配色的 3dp 胶囊，每秒刷新一次。跳转落点
/// 刻度比线高，上下溢出画，不改线占的高度（与有声书迷你播放条同一口径）。
class _AppleModernProgressLine extends StatelessWidget {
  const _AppleModernProgressLine({required this.clock, this.jumpMarks});

  final LyricsPlayerClock clock;

  /// 跳转记录的落点刻度（[FushiJumpProgressMarks]）；null / 两边都空 = 不画。
  final ({List<double> back, List<double> forward})? jumpMarks;

  @override
  Widget build(BuildContext context) {
    final Widget line = LyricsClockSecondsBuilder(
      clock: clock,
      builder: (BuildContext context, Duration position, Duration total) =>
          CustomPaint(
            size: Size.infinite,
            painter: _TrackPainter(
              fraction: total.inSeconds > 0
                  ? (position.inSeconds / total.inSeconds).clamp(0.0, 1.0)
                  : 0,
              thickness: 3,
              fillAlpha: 0.72,
              focusColor: null,
            ),
          ),
    );
    final ({List<double> back, List<double> forward})? marks = jumpMarks;
    if (marks == null || (marks.back.isEmpty && marks.forward.isEmpty)) {
      return line;
    }
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        Positioned.fill(child: line),
        Positioned(
          left: 0,
          right: 0,
          top: -4,
          bottom: -4,
          child: FushiJumpProgressMarks(
            back: marks.back,
            forward: marks.forward,
            tickHeight: 11,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 宽屏
// ---------------------------------------------------------------------------

class _AppleModernWideChrome extends StatelessWidget {
  const _AppleModernWideChrome({
    required this.data,
    required this.callbacks,
    required this.size,
    required this.padding,
    required this.geometry,
  });

  final LyricsPlayerData data;
  final LyricsPlayerCallbacks callbacks;
  final Size size;
  final EdgeInsets padding;
  final LyricsModernWideGeometry geometry;

  @override
  Widget build(BuildContext context) {
    final LyricsModernWideGeometry g = geometry;
    final TextStyle timeStyle = g.text.detail.tabular.copyWith(
      color: Colors.white.withValues(alpha: 0.56),
      fontWeight: FontWeight.w600,
    );
    final double centerWidth = lyricsModernWideCenterWidth(callbacks);
    final double center = (g.left + g.right) / 2;
    final double centerLeft = center - centerWidth / 2;
    final double centerRight = center + centerWidth / 2;
    final double leftWidth = math.max(
      0,
      math.min(
        g.text.maxInfoWidth,
        centerLeft - kLyricsModernIslandGap - g.left,
      ),
    );
    final double rightBudget = math.max(
      0,
      g.right - centerRight - kLyricsModernIslandGap,
    );
    final Size popup = g.popupSize(size, padding);
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        // 无底板：底下一层渐隐压暗（模糊封面本就偏暗，压得比 MD3 再深一点，
        // 白字在亮封面上也读得清）。不吃指针。
        Positioned(
          left: 0,
          right: 0,
          top: g.timeTop - 32,
          bottom: 0,
          child: const LyricsModernBottomScrim(color: Color(0x52000000)),
        ),
        // 插图弹出卡：从左岛缩略图上方弹出，贴左。
        Positioned(
          left: g.left,
          bottom: size.height - g.timeTop + 12,
          width: popup.width,
          height: popup.height,
          child: LyricsIllustrationPopupCard(
            controller: data.illustrations,
            width: popup.width,
            height: popup.height,
            borderRadius: const BorderRadius.all(Radius.circular(14)),
            onOpen: callbacks.onOpenIllustration == null
                ? null
                : (int index) => callbacks.onOpenIllustration!(
                    index,
                    returnToCover: false,
                  ),
          ),
        ),
        // 进度线上方两端时间，中间一行读数。
        Positioned(
          left: g.left,
          right: size.width - g.right,
          top: g.timeTop,
          height: g.seekBand.top - g.timeTop,
          child: IgnorePointer(
            child: LyricsClockSecondsBuilder(
              clock: data.clock,
              builder:
                  (BuildContext context, Duration position, Duration total) =>
                      Row(
                        children: <Widget>[
                          Text(
                            formatLyricsPlayerTime(position),
                            style: timeStyle,
                          ),
                          Expanded(
                            child: Center(
                              child: LyricsModernStatsLine(
                                clock: data.clock,
                                style: timeStyle,
                              ),
                            ),
                          ),
                          Text(
                            lyricsRemainingText(position, total),
                            style: timeStyle,
                          ),
                        ],
                      ),
            ),
          ),
        ),
        // 整宽进度线：Niratan 胶囊轨道（悬停 / 拖动 / 键盘焦点加粗）。
        Positioned.fromRect(
          rect: g.seekBand,
          child: _LyricsScrubber(
            clock: data.clock,
            onSeek: callbacks.onSeek,
            jumpMarks: data.jumpMarks,
            showTimes: false,
            trackHeight: g.seekBand.height,
          ),
        ),
        if (leftWidth >= g.islandHeight)
          Positioned(
            left: g.left,
            top: g.islandTop,
            width: leftWidth,
            height: g.islandHeight,
            child: LyricsSpringEntrance(
              child: _AppleModernInfoIsland(
                data: data,
                callbacks: callbacks,
                text: g.text,
              ),
            ),
          ),
        Positioned(
          left: centerLeft,
          top: g.islandTop,
          width: centerWidth,
          height: g.islandHeight,
          child: LyricsSpringEntrance(
            delay: 0.08,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: _appleModernTransport(
                  data,
                  callbacks,
                  side: kLyricsModernWideTransportSize,
                  play: kLyricsModernWidePlaySize,
                ),
              ),
            ),
          ),
        ),
        Positioned(
          right: size.width - g.right,
          top: g.islandTop,
          height: g.islandHeight,
          child: LyricsSpringEntrance(
            delay: 0.16,
            child: _AppleModernActionIsland(
              data: data,
              callbacks: callbacks,
              budget: rightBudget,
            ),
          ),
        ),
      ],
    );
  }
}

/// 左区（无底板）：完整封面（不裁切，兼插图入口）+ 书名 / 章名。
class _AppleModernInfoIsland extends StatelessWidget {
  const _AppleModernInfoIsland({
    required this.data,
    required this.callbacks,
    required this.text,
  });

  final LyricsPlayerData data;
  final LyricsPlayerCallbacks callbacks;

  /// 字号档位（随窗口宽度）。
  final LyricsModernWideText text;

  @override
  Widget build(BuildContext context) {
    final String chapter = (data.chapterLabel ?? '').trim();
    return Row(
      children: <Widget>[
        _appleModernArtwork(
          data,
          callbacks,
          height: text.thumbHeight,
          uncropped: true,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: LyricsIllustrationTapTarget(
            controller: data.illustrations,
            onOpen: callbacks.onOpenIllustration == null
                ? null
                : (int index) =>
                      callbacks.onOpenIllustration!(index, returnToCover: true),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  data.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.title.copyWith(
                    color: Colors.white.withValues(alpha: 0.94),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (chapter.isNotEmpty)
                  Text(
                    chapter,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.detail.tabular.copyWith(
                      color: Colors.white.withValues(alpha: 0.56),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 宽屏右下动作钮的槽位（无实色底，用户 2026-11-04「cupertino 新版底部键全部都
/// 不要有实心底」）：只定尺寸、居中、按下缩放。
Widget _appleModernTile(
  Widget child, {
  double width = kLyricsModernTileWidth,
}) => FushiPressScale(
  child: SizedBox(
    width: width,
    height: kLyricsModernTileHeight,
    child: Center(child: child),
  ),
);

/// 右岛：全部次要动作（按用户布局的显示顺序）+ ⋯ + 关闭。默认平铺；放不下时按
/// 优先级收进 ⋯（[lyricsModernActionSplit]，与 MD3 新版同一套测宽）。
class _AppleModernActionIsland extends StatefulWidget {
  const _AppleModernActionIsland({
    required this.data,
    required this.callbacks,
    required this.budget,
  });

  final LyricsPlayerData data;
  final LyricsPlayerCallbacks callbacks;

  /// 右岛可用的最大宽度。
  final double budget;

  @override
  State<_AppleModernActionIsland> createState() =>
      _AppleModernActionIslandState();
}

class _AppleModernActionIslandState extends State<_AppleModernActionIsland> {
  final FushiTopBarOverflowFit _fit = FushiTopBarOverflowFit();

  /// 方块里的一颗键（44 命中区）；当前形态下不渲染时 null。
  Widget? _button(LyricsControlItem item) {
    final List<Widget> built = _appleControlButtons(
      <LyricsControlItem>[item],
      widget.data,
      widget.callbacks,
      wide: true,
      header: false,
      diameterOverride: 44,
      iconSizeOverride: 20,
    );
    return built.isEmpty ? null : built.first;
  }

  @override
  Widget build(BuildContext context) {
    final LyricsPlayerData data = widget.data;
    final LyricsPlayerCallbacks callbacks = widget.callbacks;
    final List<LyricsControlItem> items = lyricsModernWideItems(
      data,
      (LyricsControlItem item) => _button(item) != null,
    );
    final LyricsModernActionSplit split = lyricsModernActionSplit(
      fit: _fit,
      items: items,
      budget: widget.budget,
      jumpActionCount: data.jumpActions.length,
    );
    final VoidCallback? onExitBook = callbacks.onExitBook;
    final List<Widget> buttons = <Widget>[
      if (data.jumpActions.isNotEmpty)
        _AppleJumpActions(items: data.jumpActions),
      for (final LyricsControlItem item in items)
        if (split.shown.contains(item))
          if (_button(item) case final Widget button)
            _appleModernTile(
              button,
              width: item == LyricsControlItem.speed
                  ? kLyricsModernSpeedTileWidth
                  : kLyricsModernTileWidth,
            ),
      _appleModernTile(
        _MoreButton(
          key: const ValueKey<String>('lyrics_more_button'),
          onMore: callbacks.onMore,
          collapsedItems: split.collapsed,
          diameter: 44,
          iconSize: 20,
        ),
      ),
      _appleModernTile(
        _LyricsIconButton(
          key: const ValueKey<String>('lyrics_close_button'),
          icon: CupertinoIcons.xmark,
          diameter: 44,
          iconSize: 19,
          tooltip: onExitBook != null
              ? t.lyrics_exit_to_library
              : t.floating_lyric_close,
          onPressed: onExitBook ?? callbacks.onClose,
        ),
      ),
    ];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < buttons.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: kLyricsModernTileGap),
          buttons[i],
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 窄屏
// ---------------------------------------------------------------------------

/// 窄屏几何：页眉沿用经典（[LyricsShellAppleNarrowLayout]），底部卡片横向位置与
/// 经典玻璃条相同（封顶 560 居中），高度按收起 / 展开两档；各行高按文字缩放下的
/// 真实行高与触控目标取大。
@immutable
class _AppleModernNarrowGeometry extends LyricsModernCardGeometry {
  const _AppleModernNarrowGeometry._({
    required this.layout,
    required this.miniRowHeight,
    required this.fullHeaderHeight,
    required super.miniHeight,
    required super.fullHeight,
    required super.cardLeft,
    required super.cardRight,
    required super.cardBottom,
    required super.popupTopLimit,
  });

  factory _AppleModernNarrowGeometry.of(
    BuildContext context,
    Size size,
    EdgeInsets padding,
  ) {
    final LyricsShellAppleNarrowLayout layout = LyricsShellAppleNarrowLayout(
      size,
      padding,
    );
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final TextDirection dir = Directionality.of(context);
    double line(TextStyle style) {
      final TextPainter painter = TextPainter(
        text: TextSpan(text: 'Hg', style: style),
        textScaler: scaler,
        textDirection: dir,
        maxLines: 1,
      )..layout();
      final double height = painter.height;
      painter.dispose();
      return height.ceilToDouble();
    }

    final _AppleModernText text = _AppleModernText.of(context);
    // 迷你条一行：48 的播放键，或章名 + 时间两行字（窄到放不下章名时时间两行）。
    final double miniRow = math.max(
      _kAppleModernMiniPlay,
      math.max(
        line(text.miniLabel) + line(_kMetricStyle),
        2 * line(_kMetricStyle),
      ),
    );
    final double mini =
        _kAppleModernMiniTop + miniRow + _kAppleModernMiniLineBand;
    // 头行：44 的键 / 章名。
    final double header = math.max(_kAppleModernFullButton, line(text.title));
    final double full =
        _kAppleModernFullPadding * 2 +
        header +
        _kAppleModernFullGap +
        kLyricsShellAppleScrubberHeight +
        _kAppleModernFullGap +
        _kAppleModernFullPlay;
    final Rect bar = layout.barRect;
    return _AppleModernNarrowGeometry._(
      layout: layout,
      miniRowHeight: miniRow,
      fullHeaderHeight: header,
      miniHeight: mini,
      fullHeight: full,
      cardLeft: bar.left,
      cardRight: math.max(bar.left + 1, bar.right),
      cardBottom: math.max(1, bar.bottom),
      popupTopLimit: layout.headerTop + kLyricsShellAppleNarrowHeaderHeight,
    );
  }

  final LyricsShellAppleNarrowLayout layout;
  final double miniRowHeight;
  final double fullHeaderHeight;
}

class _AppleModernNarrowChrome extends StatelessWidget {
  const _AppleModernNarrowChrome({
    required this.data,
    required this.callbacks,
    required this.size,
    required this.padding,
    required this.geometry,
  });

  final LyricsPlayerData data;
  final LyricsPlayerCallbacks callbacks;
  final Size size;
  final EdgeInsets padding;
  final _AppleModernNarrowGeometry geometry;

  @override
  Widget build(BuildContext context) {
    final _AppleModernNarrowGeometry g = geometry;
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        Positioned(
          left: padding.left + 18,
          right: padding.right + 10,
          top: g.layout.headerTop,
          height: kLyricsShellAppleNarrowHeaderHeight,
          child: _NarrowHeaderRow(
            data: data,
            callbacks: callbacks,
            showMore: true,
          ),
        ),
        Positioned.fill(
          child: LyricsModernCardHost(
            data: data,
            callbacks: callbacks,
            size: size,
            geometry: g,
            popupBorderRadius: const BorderRadius.all(Radius.circular(14)),
            card: LyricsSpringEntrance(
              child: LyricsModernCollapsibleCard(
                expanded: data.compactControlsExpanded,
                onExpandedChanged: callbacks.onCompactControlsExpandedChanged,
                miniHeight: g.miniHeight,
                fullHeight: g.fullHeight,
                handleHeight: _kAppleModernGrabHeight,
                miniBuilder: (BuildContext context, VoidCallback onExpand) =>
                    _AppleModernMiniContent(
                      data: data,
                      callbacks: callbacks,
                      geometry: g,
                      onExpand: onExpand,
                    ),
                fullBuilder: (BuildContext context) => _AppleModernFullContent(
                  data: data,
                  callbacks: callbacks,
                  geometry: g,
                ),
                // 悬浮面实色（Apple 设计系统组件规则）：系统材质实色 + 发丝描边。
                surface: (BuildContext context, Widget content) => DecoratedBox(
                  decoration: fushiAppleSolidFloatingDecoration(
                    context,
                    shape: const RoundedSuperellipseBorder(
                      borderRadius: _kAppleModernCardRadius,
                    ),
                  ),
                  child: ClipRSuperellipse(
                    borderRadius: _kAppleModernCardRadius,
                    child: content,
                  ),
                ),
                handleBuilder:
                    (
                      BuildContext context,
                      bool expanded,
                      VoidCallback onToggle,
                    ) => _AppleGrabHandle(
                      expanded: expanded,
                      onToggle: onToggle,
                    ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 卡片顶部把手：点它展开 / 收起（拖动由整张卡片接管）。键盘可聚焦，Enter 切换。
class _AppleGrabHandle extends StatelessWidget {
  const _AppleGrabHandle({required this.expanded, required this.onToggle});

  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final String label = expanded
        ? t.lyrics_controls_collapse
        : t.lyrics_controls_expand;
    return FushiTooltip(
      message: label,
      child: FushiPlainButton(
        key: const ValueKey<String>('lyrics_modern_grab_handle'),
        semanticLabel: label,
        borderRadius: const BorderRadius.all(Radius.circular(6)),
        onPressed: onToggle,
        child: SizedBox(
          width: 96,
          height: _kAppleModernGrabHeight,
          child: Center(
            child: Container(
              width: 36,
              height: 5,
              decoration: ShapeDecoration(
                color: Colors.white.withValues(alpha: 0.32),
                shape: const StadiumBorder(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 收起态（迷你条）：封面位 · 章名 + 时间（点它展开）· 重播 · 上一句 · 播放 ·
/// 下一句；底边一根细进度线。窄到放不下章名时省掉章名、时间改两行。
class _AppleModernMiniContent extends StatelessWidget {
  const _AppleModernMiniContent({
    required this.data,
    required this.callbacks,
    required this.geometry,
    required this.onExpand,
  });

  final LyricsPlayerData data;
  final LyricsPlayerCallbacks callbacks;
  final _AppleModernNarrowGeometry geometry;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final String chapter = (data.chapterLabel ?? '').trim();
    final String label = chapter.isEmpty ? data.title : chapter;
    const TextStyle timeStyle = _kMetricStyle;
    return Stack(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            12,
            _kAppleModernMiniTop,
            6,
            _kAppleModernMiniLineBand,
          ),
          child: SizedBox(
            height: geometry.miniRowHeight,
            child: Row(
              children: <Widget>[
                _appleModernArtwork(
                  data,
                  callbacks,
                  height: _kAppleModernThumbHeight,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Semantics(
                    button: true,
                    label: t.lyrics_controls_expand,
                    child: GestureDetector(
                      key: const ValueKey<String>('lyrics_modern_mini_info'),
                      behavior: HitTestBehavior.opaque,
                      onTap: onExpand,
                      child: LayoutBuilder(
                        builder: (BuildContext context, BoxConstraints c) {
                          final bool compact = c.maxWidth < 96;
                          return LyricsClockSecondsBuilder(
                            clock: data.clock,
                            builder:
                                (
                                  BuildContext context,
                                  Duration position,
                                  Duration total,
                                ) {
                                  final String elapsed = formatLyricsPlayerTime(
                                    position,
                                  );
                                  final String left = lyricsRemainingText(
                                    position,
                                    total,
                                  );
                                  return Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      if (!compact && label.isNotEmpty)
                                        Text(
                                          label,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: _AppleModernText.of(
                                            context,
                                          ).miniLabel,
                                        ),
                                      if (compact) ...<Widget>[
                                        Text(elapsed, style: timeStyle),
                                        Text(left, style: timeStyle),
                                      ] else
                                        Text(
                                          '$elapsed · $left',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: timeStyle,
                                        ),
                                    ],
                                  );
                                },
                          );
                        },
                      ),
                    ),
                  ),
                ),
                ..._appleModernTransport(
                  data,
                  callbacks,
                  side: _kAppleModernMiniButton,
                  play: _kAppleModernMiniPlay,
                  relativeSeek: false,
                  replay: true,
                ),
              ],
            ),
          ),
        ),
        // 底边细进度（只显示、不可拖）。
        Positioned(
          left: 18,
          right: 18,
          bottom: 6,
          height: 3,
          child: _AppleModernProgressLine(
            clock: data.clock,
            jumpMarks: data.jumpMarks,
          ),
        ),
      ],
    );
  }
}

/// 展开态：头行封面位 + 章名 + 次要键；Niratan 进度条带两端时间；五颗主控键。
class _AppleModernFullContent extends StatelessWidget {
  const _AppleModernFullContent({
    required this.data,
    required this.callbacks,
    required this.geometry,
  });

  final LyricsPlayerData data;
  final LyricsPlayerCallbacks callbacks;
  final _AppleModernNarrowGeometry geometry;

  @override
  Widget build(BuildContext context) {
    final String chapter = (data.chapterLabel ?? '').trim();
    final double inner = geometry.cardWidth - _kAppleModernFullPadding * 2 - 4;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        _kAppleModernFullPadding + 2,
        _kAppleModernFullPadding,
        _kAppleModernFullPadding - 2,
        _kAppleModernFullPadding,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            height: geometry.fullHeaderHeight,
            child: Row(
              children: <Widget>[
                _appleModernArtwork(
                  data,
                  callbacks,
                  height: _kAppleModernThumbHeight,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: LyricsIllustrationTapTarget(
                    controller: data.illustrations,
                    onOpen: callbacks.onOpenIllustration == null
                        ? null
                        : (int index) => callbacks.onOpenIllustration!(
                            index,
                            returnToCover: true,
                          ),
                    child: Text(
                      chapter.isEmpty ? data.title : chapter,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _AppleModernText.of(context).title,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: math.max(0, inner * 0.62),
                  ),
                  child: _SideGroup(
                    alignment: Alignment.centerRight,
                    children: _appleControlButtons(
                      data.compactControls.itemsIn(LyricsControlSlot.toolbar),
                      data,
                      callbacks,
                      wide: false,
                      header: false,
                      diameterOverride: 40,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: _kAppleModernFullGap),
          SizedBox(
            height: kLyricsShellAppleScrubberHeight,
            child: _LyricsScrubber(
              clock: data.clock,
              onSeek: callbacks.onSeek,
              jumpMarks: data.jumpMarks,
            ),
          ),
          const SizedBox(height: _kAppleModernFullGap),
          SizedBox(
            height: _kAppleModernFullPlay,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: SizedBox(
                width: math.max(
                  4 * _kAppleModernFullButton + _kAppleModernFullPlay,
                  inner - 16,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: _appleModernTransport(
                    data,
                    callbacks,
                    side: _kAppleModernFullButton,
                    play: _kAppleModernFullPlay,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
