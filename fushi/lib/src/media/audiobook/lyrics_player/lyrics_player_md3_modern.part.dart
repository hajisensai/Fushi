part of 'lyrics_player_md3.dart';

// MD3 歌词模式「新版」播放控件（2026-10-31 用户拍板，设计稿
// `fushi/build/lyrics_mode_design/layout_v3.html`；经典布局见 [Md3LyricsPlayerDesign]，
// 两者由偏好 `lyrics_controls_style` 切换）。
//
// 窄屏：顶栏与经典一致；底部播放卡两态——
//  * 收起（迷你条，64dp）：封面 / 插图位 · 章名 + 时间 · 重播当前句 · 上一句 · 播放 ·
//    下一句，卡片底边一根直线进度；
//  * 展开（约 160dp，v2 方案 A）：头行封面位 + 章名 + 次要胶囊；进度条带两端时间；
//    五个统一 48 的主控钮（播放键只靠实色填充区分）。
//  点章名 / 时间区、点或拖顶部把手、在卡片上上滑 → 展开；点把手或下滑 → 收起。高度走
//  `FushiMotion.medium`，两套内容交叉淡化 `FushiMotion.short`。
//
// 宽屏：去掉左侧封面栏，正文横向占满；底部三个浮岛（左：封面位 + 书名 / 章名；中：
// 播放胶囊；右：全部次要动作 + ⋯ + 关闭），浮岛上方一根整宽直线进度（平时细、可拖、
// 悬停加粗 + 拖动钮 + 时间气泡）。右岛动作默认平铺，放不下才按优先级收进 ⋯（测宽
// 复用 [FushiTopBarOverflowFit]）。
//
// 进度一律画直线，不做流动波浪：位置每秒读一次，没有常驻动画。

/// 新版主控钮的统一边长（v2 方案 A：五颗钮同一尺寸，播放键靠实色区分）。
const double _kModernTransportSize = 48;

/// 宽屏右下动作钮：圆角方块按钮组（tonal 底，块间留缝）。
const OutlinedBorder _kModernTileShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(16)),
);

/// 新版封面 / 插图缩略图的高度（窄屏卡片 / 宽屏左岛）。宽度按原比例变化。
const double _kModernThumbHeight = 40;

/// 迷你条 / 展开卡的上下内边距与行距。
const double _kModernMiniPadding = 8;

/// 迷你条底边波浪进度的高度：波峰 ±4 + 3 描边，留 1 像素余量。
const double _kModernMiniWaveHeight = 12;
const double _kModernFullPadding = 12;
const double _kModernFullGap = 6;

/// 卡片顶部把手的命中区高度（视觉是 32×4 的短条）。只占内边距那一截，不压到
/// 按钮的视觉区域。
const double _kModernGrabHeight = 12;

// ---------------------------------------------------------------------------
// 几何
// ---------------------------------------------------------------------------

/// 新版窄屏几何：顶栏沿用经典（[_NarrowGeometry]），底部卡片按收起 / 展开两档
/// （卡片几何见共享的 [LyricsModernCardGeometry]）。各行高按当前文字缩放下的真实
/// 行高与触控目标取大（HBK048 同一思路）。
@immutable
class _ModernNarrowGeometry extends LyricsModernCardGeometry {
  const _ModernNarrowGeometry._({
    required this.base,
    required this.miniRowHeight,
    required super.miniHeight,
    required this.fullHeaderHeight,
    required this.fullSeekHeight,
    required super.fullHeight,
    required super.cardLeft,
    required super.cardRight,
    required super.cardBottom,
    required super.popupTopLimit,
  });

  factory _ModernNarrowGeometry.of(
    BuildContext context,
    Size size,
    EdgeInsets padding,
  ) {
    final _NarrowGeometry base = _NarrowGeometry.of(context, size, padding);
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final TextDirection dir = Directionality.of(context);
    final FushiTypography type = context.fushiType;
    final ThemeData theme = Theme.of(context);
    double line(TextStyle? style) {
      if (style == null) return 0;
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

    // 迷你条一行：48 的钮，或章名 + 时间两行字（360 宽时时间也是两行）。
    final double miniRow = math.max(
      _kModernTransportSize,
      math.max(
        line(type.labelMediumEmphasized) + line(type.labelSmall),
        2 * line(type.labelSmall),
      ),
    );
    final double mini = _kModernMiniPadding * 2 + miniRow;
    // 头行：44 缩略图 / 章名 / 次要胶囊（外高 48 = 按钮命中区）。
    final double header = math.max(
      base.tapDimension,
      line(type.labelMediumEmphasized),
    );
    final double seek = math.max(28, line(theme.textTheme.labelMedium));
    final double full =
        _kModernFullPadding * 2 +
        header +
        _kModernFullGap +
        seek +
        _kModernFullGap +
        _kModernTransportSize;
    return _ModernNarrowGeometry._(
      base: base,
      miniRowHeight: miniRow,
      miniHeight: mini,
      fullHeaderHeight: header,
      fullSeekHeight: seek,
      fullHeight: full,
      cardLeft: padding.left + 12,
      cardRight: math.max(padding.left + 13, size.width - padding.right - 12),
      cardBottom: math.max(1, size.height - padding.bottom - 12),
      popupTopLimit: base.topBarBottom,
    );
  }

  final _NarrowGeometry base;
  final double miniRowHeight;
  final double fullHeaderHeight;
  final double fullSeekHeight;
}

// ---------------------------------------------------------------------------
// 外观
// ---------------------------------------------------------------------------

/// 新版 MD3 歌词播放器外观（经典见 [Md3LyricsPlayerDesign]）。
class Md3ModernLyricsPlayerDesign extends LyricsPlayerDesign {
  const Md3ModernLyricsPlayerDesign({required this.compactExpanded});

  /// 窄屏播放卡展开（目标态）。歌词矩形直接按目标态算：WebView 不随卡片高度逐帧
  /// 改尺寸（平台视图逐帧 resize 既费又会让歌词重锚抖动），卡片自己做高度动画。
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
    final _ModernNarrowGeometry geometry = _ModernNarrowGeometry.of(
      context,
      size,
      padding,
    );
    final double top = padding.top + 8 + geometry.base.topBarHeight + 8;
    final double bottom = geometry.cardTopAt(compactExpanded ? 1 : 0) - 8;
    return Rect.fromLTRB(
      padding.left,
      top,
      size.width - padding.right,
      math.max(top + 1, bottom),
    );
  }

  // 新版宽屏没有歌词底板（正文横向占满），窄屏本来就不画。
  @override
  Widget buildBackground(BuildContext context, LyricsPlayerData data) =>
      FushiMeshBackdrop(
        plateRect: _noLyricsPlate,
        // 与经典布局同：静态网格渐变，配色变化时交叉过渡一次。
        animate: false,
        colorTransition: true,
      );

  @override
  Widget buildChrome(
    BuildContext context,
    LyricsPlayerData data,
    LyricsPlayerCallbacks callbacks, {
    required Size size,
    required EdgeInsets padding,
    required Rect lyricsRect,
  }) {
    if (lyricsPlayerIsWide(size)) {
      return _ModernWideChrome(
        data: data,
        callbacks: callbacks,
        size: size,
        padding: padding,
        geometry: LyricsModernWideGeometry.of(context, size, padding),
      );
    }
    final _ModernNarrowGeometry geometry = _ModernNarrowGeometry.of(
      context,
      size,
      padding,
    );
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        Positioned(
          top: padding.top + 8,
          left: padding.left + 16,
          right: padding.right + 8,
          height: geometry.base.topBarHeight,
          child: _NarrowTopBar(data: data, callbacks: callbacks),
        ),
        Positioned.fill(
          child: _ModernNarrowCardHost(
            data: data,
            callbacks: callbacks,
            size: size,
            geometry: geometry,
          ),
        ),
      ],
    );
  }

  // 与经典同一套歌词配色 / 排版。
  @override
  LyricsHtmlTheme htmlTheme(BuildContext context, LyricsPlayerData data) =>
      const Md3LyricsPlayerDesign().htmlTheme(context, data);
}

/// 新版不画歌词底板（顶层函数：背景按解析器身份判断要不要重画）。
Rect? _noLyricsPlate(Size page, EdgeInsets padding) => null;

// ---------------------------------------------------------------------------
// 共用小件
// ---------------------------------------------------------------------------

/// 主控钮（统一 48）：−10 秒 / 上一句 / 下一句 / +10 秒是 tonal 圆钮，播放键是
/// 实色 Expressive 播放键（同 48，靠填充色区分）。
List<Widget> _modernTransportButtons(
  LyricsPlayerData data,
  LyricsPlayerCallbacks callbacks, {
  bool relativeSeek = true,
  bool replay = false,
  bool plain = false,
}) {
  const ButtonStyle fixed = ButtonStyle(
    fixedSize: WidgetStatePropertyAll<Size>(Size.square(_kModernTransportSize)),
  );
  // [plain]：宽屏无底板底栏（用户 2026-11-03 参考图）——实心 tonal 圆钮放大到 52，
  // 播放键 64（多边形）。
  const ButtonStyle wideFixed = ButtonStyle(
    fixedSize: WidgetStatePropertyAll<Size>(
      Size.square(kLyricsModernWideTransportSize),
    ),
  );
  Widget tonal({
    required Key key,
    required String tooltip,
    required VoidCallback onPressed,
    required IconData icon,
  }) => FushiIconButtonControl.filledTonal(
    key: key,
    style: plain ? wideFixed : fixed,
    iconSize: plain ? 26 : null,
    tooltip: tooltip,
    onPressed: onPressed,
    icon: FushiIcon(icon),
  );
  final ValueChanged<int>? seekBy = relativeSeek
      ? callbacks.onSeekRelative
      : null;
  final VoidCallback? onReplay = replay ? callbacks.onReplayCue : null;
  return <Widget>[
    if (seekBy != null)
      tonal(
        key: const ValueKey<String>('lyrics_seek_back_button'),
        tooltip: '-10s',
        onPressed: () => seekBy(-10),
        icon: FushiIcons.replay10,
      ),
    if (onReplay != null)
      FushiIconButtonControl(
        key: const ValueKey<String>('lyrics_replay_cue_button'),
        style: fixed,
        tooltip: t.lyrics_sentence_replay,
        onPressed: onReplay,
        icon: const FushiIcon(FushiIcons.replay),
      ),
    tonal(
      key: const ValueKey<String>('lyrics_previous_cue_button'),
      tooltip: t.prev_sentence,
      onPressed: callbacks.onPreviousCue,
      icon: FushiIcons.skipPrevious,
    ),
    FushiExpressivePlayButton(
      key: const ValueKey<String>('lyrics_play_button'),
      isPlaying: data.isPlaying,
      size: plain ? kLyricsModernWidePlaySize : _kModernTransportSize,
      onPressed: callbacks.onPlayPause,
    ),
    tonal(
      key: const ValueKey<String>('lyrics_next_cue_button'),
      tooltip: t.next_sentence,
      onPressed: callbacks.onNextCue,
      icon: FushiIcons.skipNext,
    ),
    if (seekBy != null)
      tonal(
        key: const ValueKey<String>('lyrics_seek_forward_button'),
        tooltip: '+10s',
        onPressed: () => seekBy(10),
        icon: FushiIcons.forward10,
      ),
  ];
}

// ---------------------------------------------------------------------------
// 窄屏：可收起的播放卡
// ---------------------------------------------------------------------------

/// 窄屏播放卡 + 插图弹出卡（随展开进度一起动，见 [LyricsModernCardHost]）；卡片
/// 的展开 / 收起交互见 [LyricsModernCollapsibleCard]。
class _ModernNarrowCardHost extends StatelessWidget {
  const _ModernNarrowCardHost({
    required this.data,
    required this.callbacks,
    required this.size,
    required this.geometry,
  });

  final LyricsPlayerData data;
  final LyricsPlayerCallbacks callbacks;
  final Size size;
  final _ModernNarrowGeometry geometry;

  @override
  Widget build(BuildContext context) {
    final _ModernNarrowGeometry g = geometry;
    return LyricsModernCardHost(
      data: data,
      callbacks: callbacks,
      size: size,
      geometry: g,
      popupBorderRadius: FushiM3eShape.cardRadius,
      card: LyricsSpringEntrance(
        child: LyricsModernCollapsibleCard(
          expanded: data.compactControlsExpanded,
          onExpandedChanged: callbacks.onCompactControlsExpandedChanged,
          miniHeight: g.miniHeight,
          fullHeight: g.fullHeight,
          handleHeight: _kModernGrabHeight,
          miniBuilder: (BuildContext context, VoidCallback onExpand) =>
              _ModernMiniContent(
                data: data,
                callbacks: callbacks,
                geometry: g,
                onExpand: onExpand,
              ),
          fullBuilder: (BuildContext context) =>
              _ModernFullContent(data: data, callbacks: callbacks, geometry: g),
          surface: (BuildContext context, Widget content) => _PlayerCard(
            padding: EdgeInsets.zero,
            child: ClipRRect(borderRadius: _kLargeBorderRadius, child: content),
          ),
          handleBuilder:
              (BuildContext context, bool expanded, VoidCallback onToggle) =>
                  _GrabHandle(expanded: expanded, onToggle: onToggle),
        ),
      ),
    );
  }
}

/// 卡片顶部把手：点它展开 / 收起（拖动由整张卡片接管）。键盘可聚焦，Enter 切换。
class _GrabHandle extends StatelessWidget {
  const _GrabHandle({required this.expanded, required this.onToggle});

  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String label = expanded
        ? t.lyrics_controls_collapse
        : t.lyrics_controls_expand;
    return Semantics(
      button: true,
      label: label,
      child: FushiTooltip(
        message: label,
        child: InkWell(
          key: const ValueKey<String>('lyrics_modern_grab_handle'),
          customBorder: const StadiumBorder(),
          onTap: onToggle,
          child: SizedBox(
            width: 96,
            height: _kModernGrabHeight,
            child: Center(
              child: Container(
                width: 32,
                height: 4,
                decoration: ShapeDecoration(
                  color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                  shape: const StadiumBorder(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 收起态（迷你条）：封面位 · 章名 + 时间（点它展开）· 重播当前句 · 上一句 ·
/// 播放 · 下一句；底边一根直线进度。窄到放不下章名时（360 宽）省掉章名、时间
/// 改两行。
class _ModernMiniContent extends StatelessWidget {
  const _ModernMiniContent({
    required this.data,
    required this.callbacks,
    required this.geometry,
    required this.onExpand,
  });

  final LyricsPlayerData data;
  final LyricsPlayerCallbacks callbacks;
  final _ModernNarrowGeometry geometry;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiTypography type = context.fushiType;
    final String chapter = (data.chapterLabel ?? '').trim();
    final TextStyle timeStyle = type.labelSmall.tabular.copyWith(
      color: cs.onSurfaceVariant,
    );
    return Stack(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            10,
            2 * _kModernMiniPadding - _kModernMiniWaveHeight,
            6,
            _kModernMiniWaveHeight,
          ),
          child: SizedBox(
            height: geometry.miniRowHeight,
            child: Row(
              children: <Widget>[
                lyricsModernArtwork(
                  data,
                  callbacks,
                  height: _kModernThumbHeight,
                ),
                const SizedBox(width: 8),
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
                          // 章名至少要 96 宽才放；否则（360 宽）只放时间两行。
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
                                      if (!compact && chapter.isNotEmpty)
                                        Text(
                                          chapter,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: type.labelMediumEmphasized
                                              .copyWith(color: cs.primary),
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
                ..._modernTransportButtons(
                  data,
                  callbacks,
                  relativeSeek: false,
                  replay: true,
                ),
              ],
            ),
          ),
        ),
        // 底边波浪进度（只显示、不可拖，与经典同一个 FushiWavySeekBar：播放中
        // 流动、暂停时振幅收成直线）。波峰 ±4 + 描边要 [_kModernMiniWaveHeight]
        // 高，收起态总高不变：按钮行整体上移，底下让出这条带。
        Positioned(
          left: 16,
          right: 16,
          bottom: 0,
          height: _kModernMiniWaveHeight,
          child: FushiWavySeekBar(
            debugLabel: 'lyrics-mini-seek',
            clock: data.clock,
            isPlaying: data.isPlaying,
            jumpMarks: data.jumpMarks,
            onSeek: null,
            strokeWidth: 3,
            barHeight: _kModernMiniWaveHeight,
            showTimes: false,
          ),
        ),
      ],
    );
  }
}

/// 展开态（v2 方案 A）：头行封面位 + 章名 + 次要胶囊；进度条带两端时间；五颗
/// 统一 48 的主控钮。
class _ModernFullContent extends StatelessWidget {
  const _ModernFullContent({
    required this.data,
    required this.callbacks,
    required this.geometry,
  });

  final LyricsPlayerData data;
  final LyricsPlayerCallbacks callbacks;
  final _ModernNarrowGeometry geometry;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String chapter = (data.chapterLabel ?? '').trim();
    final TextStyle? timeStyle = Theme.of(context).textTheme.labelMedium
        ?.copyWith(
          color: cs.onSurfaceVariant,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        );
    final bool narrow = geometry.cardWidth < 360;
    return Padding(
      padding: const EdgeInsets.all(_kModernFullPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            height: geometry.fullHeaderHeight,
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                return Row(
                  children: <Widget>[
                    lyricsModernArtwork(
                      data,
                      callbacks,
                      height: _kModernThumbHeight,
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
                        child: _TitleBlock(
                          title: chapter.isEmpty ? data.title : '',
                          chapterLabel: chapter.isEmpty ? null : chapter,
                          large: false,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: math.max(0, constraints.maxWidth * 0.62),
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: _SecondaryActions(
                          data: data,
                          callbacks: callbacks,
                          items: data.compactControls.itemsIn(
                            LyricsControlSlot.toolbar,
                          ),
                          wide: false,
                          padding: EdgeInsets.zero,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: _kModernFullGap),
          SizedBox(
            height: geometry.fullSeekHeight,
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
                          const SizedBox(width: 10),
                          Expanded(
                            child: FushiWavySeekBar(
                              debugLabel: 'lyrics-md3-seek',
                              clock: data.clock,
                              isPlaying: data.isPlaying,
                              jumpMarks: data.jumpMarks,
                              onSeek: callbacks.onSeek,
                              strokeWidth: 5,
                              barHeight: geometry.fullSeekHeight,
                              showTimes: false,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            lyricsRemainingText(position, total),
                            style: timeStyle,
                          ),
                        ],
                      ),
            ),
          ),
          const SizedBox(height: _kModernFullGap),
          SizedBox(
            height: _kModernTransportSize,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: narrow ? 4 : 14),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: SizedBox(
                  width: math.max(
                    5 * _kModernTransportSize,
                    geometry.cardWidth -
                        2 * _kModernFullPadding -
                        (narrow ? 8 : 28),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: _modernTransportButtons(data, callbacks),
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

// ---------------------------------------------------------------------------
// 宽屏：三浮岛
// ---------------------------------------------------------------------------

class _ModernWideChrome extends StatelessWidget {
  const _ModernWideChrome({
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
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextStyle timeStyle = g.text.detail.tabular.copyWith(
      color: cs.onSurfaceVariant,
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
        // 底栏没有胶囊底板（与音乐播放器同款，用户 2026-11-03）：底下一层渐隐压暗，
        // 保证按钮 / 文字在流体背景上可读。不吃指针。
        Positioned(
          left: 0,
          right: 0,
          top: g.timeTop - 32,
          bottom: 0,
          child: const LyricsModernBottomScrim(),
        ),
        // 插图弹出卡：从左岛缩略图上方弹出，贴左（竖排书盖住的是还没读到的左侧几列）。
        Positioned(
          left: g.left,
          bottom: size.height - g.timeTop + 12,
          width: popup.width,
          height: popup.height,
          child: LyricsIllustrationPopupCard(
            controller: data.illustrations,
            width: popup.width,
            height: popup.height,
            borderRadius: FushiM3eShape.cardRadius,
            onOpen: callbacks.onOpenIllustration == null
                ? null
                : (int index) => callbacks.onOpenIllustration!(
                    index,
                    returnToCover: false,
                  ),
          ),
        ),
        // 进度线上方两端时间。
        Positioned(
          left: g.left,
          right: size.width - g.right,
          top: g.timeTop,
          height: g.seekBand.top - g.timeTop,
          child: IgnorePointer(
            child: LyricsClockSecondsBuilder(
              clock: data.clock,
              builder:
                  (
                    BuildContext context,
                    Duration position,
                    Duration total,
                  ) => Row(
                    children: <Widget>[
                      Text(formatLyricsPlayerTime(position), style: timeStyle),
                      // 阅读速度 · 阅读进度 · 阅读时间：居中放在进度线上方，
                      // 不另占底栏一行。
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
        Positioned.fromRect(
          rect: g.seekBand,
          child: FushiWavySeekBar(
            debugLabel: 'lyrics-md3-seek',
            clock: data.clock,
            isPlaying: data.isPlaying,
            jumpMarks: data.jumpMarks,
            onSeek: callbacks.onSeek,
            strokeWidth: 5,
            barHeight: g.seekBand.height,
            showTimes: false,
          ),
        ),
        if (leftWidth >= g.islandHeight)
          Positioned(
            left: g.left,
            top: g.islandTop,
            width: leftWidth,
            height: g.islandHeight,
            child: LyricsSpringEntrance(
              child: _ModernInfoIsland(
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
                children: _modernTransportButtons(data, callbacks, plain: true),
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
            child: _ModernActionIsland(
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
class _ModernInfoIsland extends StatelessWidget {
  const _ModernInfoIsland({
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
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String chapter = (data.chapterLabel ?? '').trim();
    final TextStyle detail = text.detail.tabular.copyWith(
      color: cs.onSurfaceVariant,
    );
    return Row(
      children: <Widget>[
        lyricsModernArtwork(
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
                  style: text.title.copyWith(color: cs.onSurface),
                ),
                if (chapter.isNotEmpty)
                  Text(
                    chapter,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: detail,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 圆角方块动作钮（参考图：tonal 底的圆角方按钮组）：底色画在外面，按钮装进同尺寸
/// 同形状的填充槽（[FushiFillSlot]），state layer / 命中区撑满方块。
Widget _modernTile(
  BuildContext context,
  Widget child, {
  double width = kLyricsModernTileWidth,
}) {
  final ColorScheme cs = Theme.of(context).colorScheme;
  final Size extent = Size(width, kLyricsModernTileHeight);
  return DecoratedBox(
    decoration: ShapeDecoration(
      shape: _kModernTileShape,
      color: cs.secondaryContainer.withValues(alpha: 0.72),
    ),
    child: FushiFillSlot.wrap(
      extent: extent,
      shape: _kModernTileShape,
      child: SizedBox.fromSize(size: extent, child: child),
    ),
  );
}

/// 右岛：全部次要动作（按用户布局的显示顺序）+ ⋯ + 关闭。默认平铺；放不下时按
/// [kLyricsModernWidePriority] 从低优先级起收进 ⋯（收进去的按钮经
/// [LyricsMenuAnchor.collapsedItems] 交给页面排在菜单最前）。测宽复用
/// [FushiTopBarOverflowFit]（顶栏同一套，含展开回差）。
class _ModernActionIsland extends StatefulWidget {
  const _ModernActionIsland({
    required this.data,
    required this.callbacks,
    required this.budget,
  });

  final LyricsPlayerData data;
  final LyricsPlayerCallbacks callbacks;

  /// 右岛可用的最大宽度。
  final double budget;

  @override
  State<_ModernActionIsland> createState() => _ModernActionIslandState();
}

class _ModernActionIslandState extends State<_ModernActionIsland> {
  final FushiTopBarOverflowFit _fit = FushiTopBarOverflowFit();

  /// 宽屏右岛的按钮（[lyricsModernWideItems]），去掉当前形态下不渲染的（没有
  /// 回调 / 书籍模式在没有退书回调时）。
  List<LyricsControlItem> _items() => lyricsModernWideItems(
    widget.data,
    (LyricsControlItem item) =>
        _md3ControlButton(
          item,
          widget.data,
          widget.callbacks,
          wide: true,
          tonal: false,
        ) !=
        null,
  );

  @override
  Widget build(BuildContext context) {
    final LyricsPlayerData data = widget.data;
    final LyricsPlayerCallbacks callbacks = widget.callbacks;
    final List<LyricsControlItem> items = _items();
    final LyricsModernActionSplit split = lyricsModernActionSplit(
      fit: _fit,
      items: items,
      budget: widget.budget,
      jumpActionCount: data.jumpActions.length,
    );
    final Set<LyricsControlItem> shown = split.shown;
    final List<LyricsControlItem> collapsed = split.collapsed;
    final VoidCallback? onExitBook = callbacks.onExitBook;
    final List<Widget> buttons = <Widget>[
      if (data.jumpActions.isNotEmpty)
        FushiJumpHistoryActions(items: data.jumpActions),
      for (final LyricsControlItem item in items)
        if (shown.contains(item))
          if (_md3ControlButton(item, data, callbacks, wide: true, tonal: false)
              case final Widget button)
            _modernTile(
              context,
              button,
              width: item == LyricsControlItem.speed
                  ? kLyricsModernSpeedTileWidth
                  : kLyricsModernTileWidth,
            ),
      _modernTile(
        context,
        _MoreButton(onMore: callbacks.onMore, collapsedItems: collapsed),
      ),
      _modernTile(
        context,
        FushiIconButtonControl(
          key: const ValueKey<String>('lyrics_close_button'),
          tooltip: onExitBook != null
              ? t.lyrics_exit_to_library
              : MaterialLocalizations.of(context).closeButtonTooltip,
          onPressed: onExitBook ?? callbacks.onClose,
          icon: const FushiIcon(FushiIcons.close),
        ),
      ),
    ];
    // 无底板（与音乐播放器同款）：按钮直接平铺在背景上。
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < buttons.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: 6),
          buttons[i],
        ],
      ],
    );
  }
}
