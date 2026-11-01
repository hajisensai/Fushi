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

/// 宽屏浮岛：外边距、岛间距、进度线命中带高度、时间行与进度线的间距。
const double _kModernWideMargin = 24;
const double _kModernIslandGap = 16;
const double _kModernSeekBand = 24;

/// 宽屏底栏自动隐藏后，歌词区底边离窗口底边的距离（留给贴底的细进度线）。
const double _kModernImmersiveBottom = 16;

/// 宽屏左岛 / 两端时间的字号档位：按窗口宽度分三档（与左岛最大宽同一套断点），
/// 大屏上底栏文字跟着放大，不再是固定 14 / 11（大屏上看不清）。档位只取
/// [FushiTypography] 的角色（不写裸字号），跟随用户字体与字号缩放。
@immutable
class _ModernWideText {
  const _ModernWideText._({
    required this.title,
    required this.detail,
    required this.thumbHeight,
    required this.maxInfoWidth,
  });

  factory _ModernWideText.of(BuildContext context, double width) {
    final FushiTypography type = context.fushiType;
    if (width >= 1900) {
      return _ModernWideText._(
        title: type.titleLargeEmphasized,
        detail: type.labelLarge,
        thumbHeight: 56,
        maxInfoWidth: 420,
      );
    }
    if (width >= 1200) {
      return _ModernWideText._(
        title: type.titleMediumEmphasized,
        detail: type.labelLarge,
        thumbHeight: 52,
        maxInfoWidth: 340,
      );
    }
    return _ModernWideText._(
      title: type.labelLargeEmphasized,
      detail: type.labelMedium,
      thumbHeight: 44,
      maxInfoWidth: 260,
    );
  }

  /// 书名。
  final TextStyle title;

  /// 章名 · 进度、进度线两端时间。
  final TextStyle detail;

  /// 左岛封面位高度。
  final double thumbHeight;

  /// 左岛最大宽。
  final double maxInfoWidth;
}

/// 右岛动作收进 ⋯ 的优先级（高 → 低）：放不下时从末尾起收。显示顺序仍按用户的
/// 按钮布局（[LyricsControlLayout]）。
const List<LyricsControlItem> _kModernWidePriority = <LyricsControlItem>[
  LyricsControlItem.speed,
  LyricsControlItem.replayCue,
  LyricsControlItem.mask,
  LyricsControlItem.typography,
  LyricsControlItem.bookMode,
  LyricsControlItem.studyTimer,
  LyricsControlItem.statistics,
];

/// 倍速键（tonal 文字按钮）比一颗图标钮多占的宽度估计（测宽时先扣掉）。
const double _kModernSpeedButtonWidth = 76;

// ---------------------------------------------------------------------------
// 几何
// ---------------------------------------------------------------------------

/// 新版窄屏几何：顶栏沿用经典（[_NarrowGeometry]），底部卡片按收起 / 展开两档。
/// 各行高按当前文字缩放下的真实行高与触控目标取大（HBK048 同一思路）。
@immutable
class _ModernNarrowGeometry {
  const _ModernNarrowGeometry._({
    required this.base,
    required this.miniRowHeight,
    required this.miniHeight,
    required this.fullHeaderHeight,
    required this.fullSeekHeight,
    required this.fullHeight,
    required this.cardLeft,
    required this.cardRight,
    required this.cardBottom,
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
    );
  }

  final _NarrowGeometry base;
  final double miniRowHeight;
  final double miniHeight;
  final double fullHeaderHeight;
  final double fullSeekHeight;
  final double fullHeight;
  final double cardLeft;
  final double cardRight;
  final double cardBottom;

  double get cardWidth => cardRight - cardLeft;

  /// 展开进度 [t]（0 = 收起，1 = 展开；动画途中取中间值）下的卡片高度。
  double heightAt(double t) => miniHeight + (fullHeight - miniHeight) * t;

  /// 卡片顶边（展开进度 [t]）。
  double cardTopAt(double t) => math.max(0, cardBottom - heightAt(t));

  /// 插图弹出卡的最大框：宽取卡宽的 60%，高不超过 320、也不顶到顶栏（顶栏底到
  /// 卡片顶之间再各留 12）。
  Size popupSizeAt(double t) => Size(
    cardWidth * 0.6,
    math.max(0, math.min(320, cardTopAt(t) - base.topBarBottom - 24)),
  );
}

/// 新版宽屏几何：浮岛 / 进度线 / 时间行 / 歌词矩形出自同一份计算。
@immutable
class _ModernWideGeometry {
  const _ModernWideGeometry._({
    required this.islandHeight,
    required this.islandTop,
    required this.left,
    required this.right,
    required this.seekBand,
    required this.timeTop,
    required this.lyrics,
    required this.text,
  });

  factory _ModernWideGeometry.of(
    BuildContext context,
    Size size,
    EdgeInsets padding,
  ) {
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final _ModernWideText text = _ModernWideText.of(context, size.width);
    final double textLines =
        scaler.scale(text.title.fontSize ?? 14) * 1.4 +
        scaler.scale(text.detail.fontSize ?? 12) * 1.4;
    final double islandHeight = math
        .max(64, math.max(textLines, text.thumbHeight) + 16)
        .ceilToDouble();
    final double left = padding.left + _kModernWideMargin;
    final double right = math.max(
      left + 1,
      size.width - padding.right - _kModernWideMargin,
    );
    final double islandBottom = math.max(
      islandHeight,
      size.height - padding.bottom - 20,
    );
    final double islandTop = islandBottom - islandHeight;
    final Rect seekBand = Rect.fromLTRB(
      left,
      islandTop - 10 - _kModernSeekBand,
      right,
      islandTop - 10,
    );
    final double timeHeight = scaler.scale(text.detail.fontSize ?? 12) * 1.4;
    final double timeTop = seekBand.top - timeHeight;
    final double lyricsTop = padding.top + 28;
    final Rect lyrics = Rect.fromLTRB(
      padding.left + 40,
      lyricsTop,
      math.max(padding.left + 41, size.width - padding.right - 40),
      math.max(lyricsTop + 1, timeTop - 12),
    );
    return _ModernWideGeometry._(
      islandHeight: islandHeight,
      islandTop: islandTop,
      left: left,
      right: right,
      seekBand: seekBand,
      timeTop: timeTop,
      lyrics: lyrics,
      text: text,
    );
  }

  final double islandHeight;

  /// 底栏文字档位（左岛 / 时间）。
  final _ModernWideText text;
  final double islandTop;
  final double left;
  final double right;

  /// 进度线的命中带（整宽，24 高；线画在带子中间）。
  final Rect seekBand;

  /// 进度线上方左右两端时间的顶边。
  final double timeTop;
  final Rect lyrics;

  /// 底栏隐藏后的歌词矩形：底边一直伸到贴底细进度线上方。
  Rect immersiveLyrics(Size size, EdgeInsets padding) => Rect.fromLTRB(
    lyrics.left,
    lyrics.top,
    lyrics.right,
    math.max(
      lyrics.bottom,
      size.height - padding.bottom - _kModernImmersiveBottom,
    ),
  );

  /// 插图弹出卡的最大框：320×460（1920 宽及以上 400×560），高度不超过可用空间。
  Size popupSize(Size page, EdgeInsets padding) {
    final bool big = page.width >= 1900;
    final double maxH = timeTop - 12 - (padding.top + 16);
    return Size(
      math.min(big ? 400.0 : 320.0, (right - left) * 0.5),
      math.max(0, math.min(big ? 560.0 : 460.0, maxH)),
    );
  }
}

// ---------------------------------------------------------------------------
// 外观
// ---------------------------------------------------------------------------

/// 新版 MD3 歌词播放器外观（经典见 [Md3LyricsPlayerDesign]）。
class Md3ModernLyricsPlayerDesign extends LyricsPlayerDesign {
  const Md3ModernLyricsPlayerDesign({
    required this.compactExpanded,
    this.wideChromeHidden = false,
    this.wideLyricsExpanded = false,
  });

  /// 窄屏播放卡展开（目标态）。歌词矩形直接按目标态算：WebView 不随卡片高度逐帧
  /// 改尺寸（平台视图逐帧 resize 既费又会让歌词重锚抖动），卡片自己做高度动画。
  final bool compactExpanded;

  /// 宽屏底栏（三浮岛 + 时间 + 进度线）已自动隐藏：淡出、不吃指针，只留一根
  /// 贴底细进度线。窄屏忽略。
  final bool wideChromeHidden;

  /// 宽屏歌词矩形伸到底（[_ModernWideGeometry.immersiveLyrics]）。与
  /// [wideChromeHidden] 分开：外壳等底栏淡出完再一次性改矩形（WebView 只 resize
  /// 一次，不逐帧）；显示时两者同时复位，底栏淡入前歌词已让位。
  final bool wideLyricsExpanded;

  @override
  Rect lyricsRect(BuildContext context, Size size, EdgeInsets padding) {
    if (lyricsPlayerIsWide(size)) {
      final _ModernWideGeometry g = _ModernWideGeometry.of(
        context,
        size,
        padding,
      );
      return wideLyricsExpanded ? g.immersiveLyrics(size, padding) : g.lyrics;
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
        geometry: _ModernWideGeometry.of(context, size, padding),
        hidden: wideChromeHidden,
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

/// 每秒读一次 [FushiPlaybackClock] 的位置 / 时长，变了才重建这一小块（自带重绘
/// 边界）。播放 / 暂停一样每秒一次：没有逐帧刷新。
class _ClockSecondsBuilder extends StatefulWidget {
  const _ClockSecondsBuilder({required this.clock, required this.builder});

  final LyricsPlayerClock clock;
  final Widget Function(BuildContext context, Duration position, Duration total)
  builder;

  @override
  State<_ClockSecondsBuilder> createState() => _ClockSecondsBuilderState();
}

class _ClockSecondsBuilderState extends State<_ClockSecondsBuilder> {
  late int _second = widget.clock.position.inSeconds;
  late int _total = widget.clock.duration.inSeconds;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  @override
  void didUpdateWidget(covariant _ClockSecondsBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.clock, widget.clock)) _poll();
  }

  void _poll() {
    if (!mounted) return;
    final int second = widget.clock.position.inSeconds;
    final int total = widget.clock.duration.inSeconds;
    if (second != _second || total != _total) {
      setState(() {
        _second = second;
        _total = total;
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: widget.builder(
      context,
      Duration(seconds: _second),
      Duration(seconds: _total),
    ),
  );
}

/// 剩余时间文案 `-m:ss`。
String _remainingText(Duration position, Duration total) =>
    '-${formatLyricsPlayerTime(total > position ? total - position : Duration.zero)}';

/// 封面 / 插图缩略图：固定高 [height]，宽按图片原比例（夹在 0.5–1.6 倍高之间，
/// 超出的部分按原比例留边、不裁切）。比例变化（封面 ↔ 插图）时宽度按
/// `FushiMotion.short` 过渡。无图画 primaryContainer 底 + 书本图标。
class _AspectThumb extends StatefulWidget {
  const _AspectThumb({required this.image, required this.height});

  final ImageProvider? image;
  final double height;

  @override
  State<_AspectThumb> createState() => _AspectThumbState();
}

class _AspectThumbState extends State<_AspectThumb> {
  double _aspect = 0.72;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant _AspectThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.image != widget.image) _resolve();
  }

  ImageProvider? get _sized {
    final ImageProvider? image = widget.image;
    if (image == null) return null;
    final int cache =
        (widget.height * 1.6 * MediaQuery.devicePixelRatioOf(context)).round();
    return ResizeImage.resizeIfNeeded(cache, null, image);
  }

  void _resolve() {
    final ImageStream? next = _sized?.resolve(
      createLocalImageConfiguration(context),
    );
    if (next != null && next.key == _stream?.key) return;
    _detach();
    if (next == null) return;
    final ImageStreamListener listener = ImageStreamListener((
      ImageInfo info,
      bool _,
    ) {
      final double w = info.image.width.toDouble();
      final double h = info.image.height.toDouble();
      info.dispose();
      if (!mounted || w <= 0 || h <= 0) return;
      final double aspect = w / h;
      if ((aspect - _aspect).abs() > 0.001) setState(() => _aspect = aspect);
    }, onError: (Object error, StackTrace? stack) {});
    _stream = next..addListener(listener);
    _listener = listener;
  }

  void _detach() {
    final ImageStreamListener? listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final double h = widget.height;
    final ImageProvider? image = _sized;
    final double target = image == null
        ? h
        : (h * _aspect).clamp(h * 0.5, h * 1.6);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: target),
      duration: fushiMotionDuration(context, FushiMotion.short),
      curve: FushiMotion.standard,
      builder: (BuildContext context, double width, Widget? child) =>
          SizedBox(width: width, height: h, child: child),
      child: ClipRRect(
        borderRadius: FushiM3eShape.smallRadius,
        child: image == null
            ? ColoredBox(
                color: cs.primaryContainer,
                child: Center(
                  child: FushiIcon(
                    FushiIcons.books,
                    size: h * 0.5,
                    color: cs.onPrimaryContainer,
                  ),
                ),
              )
            : ColoredBox(
                color: FushiDesignTokens.of(context).surfaces.overlay,
                child: Image(
                  image: image,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                  gaplessPlayback: true,
                ),
              ),
      ),
    );
  }
}

/// 封面位（兼插图入口）：有新插图时换成插图缩略图 + 红点，点它看大图。
Widget _modernArtwork(
  LyricsPlayerData data,
  LyricsPlayerCallbacks callbacks, {
  required double height,
}) => LyricsIllustrationCompactArtwork(
  controller: data.illustrations,
  onOpen: callbacks.onOpenIllustration == null
      ? null
      : (int index) =>
            callbacks.onOpenIllustration!(index, returnToCover: true),
  builder: (BuildContext context, ImageProvider? illustration) =>
      _AspectThumb(image: illustration ?? data.cover, height: height),
);

/// 主控钮（统一 48）：−10 秒 / 上一句 / 下一句 / +10 秒是 tonal 圆钮，播放键是
/// 实色 Expressive 播放键（同 48，靠填充色区分）。
List<Widget> _modernTransportButtons(
  LyricsPlayerData data,
  LyricsPlayerCallbacks callbacks, {
  bool relativeSeek = true,
  bool replay = false,
}) {
  const ButtonStyle fixed = ButtonStyle(
    fixedSize: WidgetStatePropertyAll<Size>(Size.square(_kModernTransportSize)),
  );
  Widget tonal({
    required Key key,
    required String tooltip,
    required VoidCallback onPressed,
    required IconData icon,
  }) => FushiIconButtonControl.filledTonal(
    key: key,
    style: fixed,
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
      size: _kModernTransportSize,
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

/// 窄屏播放卡 + 插图弹出卡：两者随展开进度一起动（卡高 `FushiMotion.medium`，
/// spatial 弹簧；弹出卡底边跟着卡片顶边走）。
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
    final bool expanded = data.compactControlsExpanded;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: expanded ? 1 : 0),
      duration: fushiMotionDuration(context, FushiMotion.medium),
      curve: FushiSpringCurve.spatial,
      builder: (BuildContext context, double t, Widget? card) {
        final double top = geometry.cardTopAt(t);
        final Size popup = geometry.popupSizeAt(t);
        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned(
              left: geometry.cardLeft,
              bottom: size.height - top + 12,
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
            Positioned(
              left: geometry.cardLeft,
              width: geometry.cardWidth,
              top: top,
              height: geometry.heightAt(t),
              child: card!,
            ),
          ],
        );
      },
      child: _SpringEntrance(
        child: _ModernNarrowCard(
          data: data,
          callbacks: callbacks,
          geometry: geometry,
        ),
      ),
    );
  }
}

class _ModernNarrowCard extends StatefulWidget {
  const _ModernNarrowCard({
    required this.data,
    required this.callbacks,
    required this.geometry,
  });

  final LyricsPlayerData data;
  final LyricsPlayerCallbacks callbacks;
  final _ModernNarrowGeometry geometry;

  @override
  State<_ModernNarrowCard> createState() => _ModernNarrowCardState();
}

class _ModernNarrowCardState extends State<_ModernNarrowCard> {
  /// 本次竖向拖动累计位移（向上为负）。
  double _dragDy = 0;

  bool get _expanded => widget.data.compactControlsExpanded;

  void _set(bool expanded) {
    if (expanded == _expanded) return;
    widget.callbacks.onCompactControlsExpandedChanged?.call(expanded);
  }

  void _onDragEnd(DragEndDetails details) {
    final double v = details.primaryVelocity ?? 0;
    final double dy = _dragDy;
    _dragDy = 0;
    if (v < -200 || dy < -24) {
      _set(true);
    } else if (v > 200 || dy > 24) {
      _set(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final _ModernNarrowGeometry g = widget.geometry;
    final bool expanded = _expanded;
    final Duration fade = fushiMotionDuration(context, FushiMotion.short);
    final double contentHeight = expanded ? g.fullHeight : g.miniHeight;
    final Widget content = AnimatedSwitcher(
      duration: fade,
      switchInCurve: FushiMotion.enter,
      switchOutCurve: FushiMotion.exit,
      layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
        alignment: Alignment.topCenter,
        clipBehavior: Clip.hardEdge,
        children: <Widget>[...previous, if (current != null) current],
      ),
      child: KeyedSubtree(
        key: ValueKey<bool>(expanded),
        // 内容按自己的自然高度排（卡高动画途中被裁，不被压扁）。
        child: OverflowBox(
          alignment: Alignment.topCenter,
          minHeight: contentHeight,
          maxHeight: contentHeight,
          child: expanded
              ? _ModernFullContent(
                  data: widget.data,
                  callbacks: widget.callbacks,
                  geometry: g,
                )
              : _ModernMiniContent(
                  data: widget.data,
                  callbacks: widget.callbacks,
                  geometry: g,
                  onExpand: () => _set(true),
                ),
        ),
      ),
    );
    return GestureDetector(
      key: const ValueKey<String>('lyrics_modern_card'),
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: (_) => _dragDy = 0,
      onVerticalDragUpdate: (DragUpdateDetails d) => _dragDy += d.delta.dy,
      onVerticalDragEnd: _onDragEnd,
      child: _PlayerCard(
        padding: EdgeInsets.zero,
        child: ClipRRect(
          borderRadius: _kLargeBorderRadius,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              content,
              Positioned(
                top: 0,
                height: _kModernGrabHeight,
                left: 0,
                right: 0,
                child: Center(
                  child: _GrabHandle(
                    expanded: expanded,
                    onToggle: () => _set(!expanded),
                  ),
                ),
              ),
            ],
          ),
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
                _modernArtwork(data, callbacks, height: _kModernThumbHeight),
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
                          return _ClockSecondsBuilder(
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
                                  final String left = _remainingText(
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
                    _modernArtwork(
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
            child: _ClockSecondsBuilder(
              clock: data.clock,
              builder:
                  (
                    BuildContext context,
                    Duration position,
                    Duration total,
                  ) => Row(
                    children: <Widget>[
                      Text(formatLyricsPlayerTime(position), style: timeStyle),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FushiWavySeekBar(
                          debugLabel: 'lyrics-md3-seek',
                          clock: data.clock,
                          isPlaying: data.isPlaying,
                          onSeek: callbacks.onSeek,
                          strokeWidth: 5,
                          barHeight: geometry.fullSeekHeight,
                          showTimes: false,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(_remainingText(position, total), style: timeStyle),
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
    required this.hidden,
  });

  final LyricsPlayerData data;
  final LyricsPlayerCallbacks callbacks;
  final Size size;
  final EdgeInsets padding;
  final _ModernWideGeometry geometry;

  /// 底栏已自动隐藏（见 [Md3ModernLyricsPlayerDesign.wideChromeHidden]）。
  final bool hidden;

  /// 中岛（播放胶囊）宽：五颗 48 的钮 + 间距 2 + 胶囊内边距 8。
  double get _centerWidth {
    final int buttons = callbacks.onSeekRelative == null ? 3 : 5;
    return buttons * _kModernTransportSize + (buttons - 1) * 2 + 16;
  }

  @override
  Widget build(BuildContext context) {
    final _ModernWideGeometry g = geometry;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextStyle timeStyle = g.text.detail.tabular.copyWith(
      color: cs.onSurfaceVariant,
    );
    final double center = (g.left + g.right) / 2;
    final double centerLeft = center - _centerWidth / 2;
    final double centerRight = center + _centerWidth / 2;
    final double leftWidth = math.max(
      0,
      math.min(g.text.maxInfoWidth, centerLeft - _kModernIslandGap - g.left),
    );
    final Duration fade = fushiMotionDuration(context, FushiMotion.medium);
    // 底栏件：隐藏时淡出且不吃指针（第一下点击只唤出底栏，不误触看不见的钮）。
    Widget chrome(Widget child) => IgnorePointer(
      ignoring: hidden,
      child: AnimatedOpacity(
        opacity: hidden ? 0 : 1,
        duration: fade,
        curve: FushiMotion.standard,
        child: child,
      ),
    );
    final double rightBudget = math.max(
      0,
      g.right - centerRight - _kModernIslandGap,
    );
    final Size popup = g.popupSize(size, padding);
    final Color island = fushiFloatingToolbarPalette(context).container;
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
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
          child: chrome(
            IgnorePointer(
              child: _ClockSecondsBuilder(
                clock: data.clock,
                builder:
                    (BuildContext context, Duration position, Duration total) =>
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: <Widget>[
                            Text(
                              formatLyricsPlayerTime(position),
                              style: timeStyle,
                            ),
                            Text(
                              _remainingText(position, total),
                              style: timeStyle,
                            ),
                          ],
                        ),
              ),
            ),
          ),
        ),
        Positioned.fromRect(
          rect: g.seekBand,
          child: chrome(
            FushiWavySeekBar(
              debugLabel: 'lyrics-md3-seek',
              clock: data.clock,
              // 隐藏时收平：看不见的波浪不该继续逐帧跑。
              isPlaying: data.isPlaying && !hidden,
              onSeek: callbacks.onSeek,
              strokeWidth: 5,
              barHeight: g.seekBand.height,
              showTimes: false,
            ),
          ),
        ),
        // 底栏隐藏时贴底的细进度线（只看不点：点哪儿都先唤出底栏）。
        Positioned(
          left: g.left,
          right: size.width - g.right,
          bottom: padding.bottom + (_kModernImmersiveBottom - 3) / 2,
          height: 3,
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: hidden ? 1 : 0,
              duration: fade,
              curve: FushiMotion.standard,
              child: _ClockSecondsBuilder(
                clock: data.clock,
                builder:
                    (
                      BuildContext context,
                      Duration position,
                      Duration total,
                    ) => ClipRRect(
                      key: const ValueKey<String>(
                        'lyrics_modern_immersive_progress',
                      ),
                      borderRadius: const BorderRadius.all(Radius.circular(2)),
                      child: LinearProgressIndicator(
                        value: total.inSeconds > 0
                            ? (position.inSeconds / total.inSeconds).clamp(
                                0.0,
                                1.0,
                              )
                            : 0,
                        minHeight: 3,
                        color: cs.primary,
                        backgroundColor: cs.onSurface.withValues(alpha: 0.12),
                      ),
                    ),
              ),
            ),
          ),
        ),
        if (leftWidth >= g.islandHeight)
          Positioned(
            left: g.left,
            top: g.islandTop,
            width: leftWidth,
            height: g.islandHeight,
            child: chrome(
              _SpringEntrance(
                child: _ModernInfoIsland(
                  data: data,
                  callbacks: callbacks,
                  color: island,
                  text: g.text,
                ),
              ),
            ),
          ),
        Positioned(
          left: centerLeft,
          top: g.islandTop,
          width: _centerWidth,
          height: g.islandHeight,
          child: chrome(
            _SpringEntrance(
              delay: 0.08,
              child: FushiFloatingPill(
                color: island,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: _modernTransportButtons(data, callbacks),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          right: size.width - g.right,
          top: g.islandTop,
          height: g.islandHeight,
          child: chrome(
            _SpringEntrance(
              delay: 0.16,
              child: _ModernActionIsland(
                data: data,
                callbacks: callbacks,
                budget: rightBudget,
                color: island,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 左岛：封面位（兼插图入口）+ 书名 / 章名 · 全书进度。
class _ModernInfoIsland extends StatelessWidget {
  const _ModernInfoIsland({
    required this.data,
    required this.callbacks,
    required this.color,
    required this.text,
  });

  final LyricsPlayerData data;
  final LyricsPlayerCallbacks callbacks;
  final Color color;

  /// 字号档位（随窗口宽度）。
  final _ModernWideText text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String chapter = (data.chapterLabel ?? '').trim();
    return FushiFloatingPill(
      color: color,
      shape: const RoundedRectangleBorder(borderRadius: _kLargeBorderRadius),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: <Widget>[
          _modernArtwork(data, callbacks, height: text.thumbHeight),
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
                  _StatsBuilder(
                    clock: data.clock,
                    builder: (BuildContext context, LyricsPlayerStats stats) {
                      final double? percent = stats.percent;
                      return Text(
                        <String>[
                          if (chapter.isNotEmpty) chapter,
                          if (percent != null) '${percent.toStringAsFixed(1)}%',
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.detail.tabular.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 右岛：全部次要动作（按用户布局的显示顺序）+ ⋯ + 关闭。默认平铺；放不下时按
/// [_kModernWidePriority] 从低优先级起收进 ⋯（收进去的按钮经
/// [LyricsMenuAnchor.collapsedItems] 交给页面排在菜单最前）。测宽复用
/// [FushiTopBarOverflowFit]（顶栏同一套，含展开回差）。
class _ModernActionIsland extends StatefulWidget {
  const _ModernActionIsland({
    required this.data,
    required this.callbacks,
    required this.budget,
    required this.color,
  });

  final LyricsPlayerData data;
  final LyricsPlayerCallbacks callbacks;

  /// 右岛可用的最大宽度。
  final double budget;
  final Color color;

  @override
  State<_ModernActionIsland> createState() => _ModernActionIslandState();
}

class _ModernActionIslandState extends State<_ModernActionIsland> {
  final FushiTopBarOverflowFit _fit = FushiTopBarOverflowFit();

  /// 宽屏右岛的按钮：布局的「工具条」区 + 「顶部」区（左右互换在新版里没有意义，
  /// 不画），去掉当前形态下不渲染的（没有回调 / 书籍模式在没有退书回调时）。
  List<LyricsControlItem> _items() {
    final LyricsControlLayout layout = widget.data.wideControls;
    return <LyricsControlItem>[
      for (final LyricsControlItem item in <LyricsControlItem>[
        ...layout.itemsIn(LyricsControlSlot.toolbar),
        ...layout.itemsIn(LyricsControlSlot.top),
      ])
        if (item != LyricsControlItem.swapSides &&
            _md3ControlButton(
                  item,
                  widget.data,
                  widget.callbacks,
                  wide: true,
                  tonal: false,
                ) !=
                null)
          item,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final LyricsPlayerData data = widget.data;
    final LyricsPlayerCallbacks callbacks = widget.callbacks;
    final List<LyricsControlItem> items = _items();
    final double slot = fushiTopBarActionSlotWidth(context);
    // 按优先级排成一组交给测宽；倍速键比图标钮宽，关闭键恒在，先从预算里扣掉。
    final List<LyricsControlItem> byPriority = <LyricsControlItem>[
      for (final LyricsControlItem p in _kModernWidePriority)
        if (items.contains(p)) p,
      for (final LyricsControlItem i in items)
        if (!_kModernWidePriority.contains(i)) i,
    ];
    final bool hasSpeed = items.contains(LyricsControlItem.speed);
    final double budget =
        widget.budget - slot - (hasSpeed ? _kModernSpeedButtonWidth - slot : 0);
    final List<FushiToolbarItem> probe = <FushiToolbarItem>[
      for (final LyricsControlItem item in byPriority)
        FushiToolbarItem(
          icon: lyricsControlItemIcon(item),
          label: lyricsControlItemLabel(item),
          onPressed: null,
        ),
    ];
    final int visible = _fit.visibleFor(
      groups: <List<FushiToolbarItem>>[probe],
      budget: budget,
      pinnedMenu: true,
      slotWidth: slot,
      padding: 16,
    );
    final Set<LyricsControlItem> shown = byPriority.take(visible).toSet();
    final List<LyricsControlItem> collapsed = <LyricsControlItem>[
      for (final LyricsControlItem item in items)
        if (!shown.contains(item)) item,
    ];
    final VoidCallback? onExitBook = callbacks.onExitBook;
    final List<Widget> buttons = <Widget>[
      for (final LyricsControlItem item in items)
        if (shown.contains(item))
          ?_md3ControlButton(item, data, callbacks, wide: true, tonal: false),
      _MoreButton(onMore: callbacks.onMore, collapsedItems: collapsed),
      FushiIconButtonControl(
        key: const ValueKey<String>('lyrics_close_button'),
        tooltip: onExitBook != null
            ? t.lyrics_exit_to_library
            : MaterialLocalizations.of(context).closeButtonTooltip,
        onPressed: onExitBook ?? callbacks.onClose,
        icon: const FushiIcon(FushiIcons.close),
      ),
    ];
    return FushiFloatingPill(
      color: widget.color,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < buttons.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: kFushiFloatingToolbarItemGap),
            buttons[i],
          ],
        ],
      ),
    );
  }
}
