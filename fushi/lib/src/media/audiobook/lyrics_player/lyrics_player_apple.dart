import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_control_layout.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_illustration_view.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_illustrations.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/media/shared/lyrics_shell/lyrics_shell_backgrounds.dart';
import 'package:fushi/src/media/shared/lyrics_shell/lyrics_shell_layout.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_speed_panel.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// Apple 设计系统（iOS / macOS 26 Liquid Glass）下的 Apple Music 风格歌词页。
///
/// 比例与参数照抄 Niratan 的 `ReaderLyricsModeView`（SwiftUI）：宽屏是「左封面 +
/// 播放面板、右歌词」双栏，强模糊封面铺底；窄屏不放封面，顶部书名 + 读数、底部
/// 一条透明液态玻璃胶囊控制条。歌词本身由下面的透明 WebView 渲染，这里只画背景、
/// 控件，并给出歌词矩形与 HTML 主题。
class AppleLyricsPlayerDesign extends LyricsPlayerDesign {
  const AppleLyricsPlayerDesign({this.mirrorProgress = 0});

  /// 宽屏左右互换进度（见 [LyricsPlayerData.sidesMirrored]）：0 = 面板在左、
  /// 1 = 面板在右，中间值 = 换位动画途中（由 `ReaderLyricsPlayerOverlay` 按
  /// `fushiMotionDuration` 驱动，墨水屏 / 减弱动态下直接跳到终值）。
  final double mirrorProgress;

  @override
  Rect lyricsRect(BuildContext context, Size size, EdgeInsets padding) {
    if (lyricsPlayerIsWide(size)) {
      return LyricsShellAppleWideLayout(
        size,
        padding,
        mirror: mirrorProgress,
      ).lyricsRect;
    }
    return LyricsShellAppleNarrowLayout(size, padding).lyricsRect;
  }

  @override
  Widget buildBackground(
    BuildContext context,
    LyricsPlayerData data, {
    double bleedTop = 0,
  }) {
    // 模糊封面各层按画布比例铺，与页面几何无关：整张画布照画即可。
    return LyricsShellAppleBackground(
      cover: data.cover,
      accent: appleColorsOf(context).accent,
    );
  }

  @override
  Widget buildChrome(
    BuildContext context,
    LyricsPlayerData data,
    LyricsPlayerCallbacks callbacks, {
    required Size size,
    required EdgeInsets padding,
    required Rect lyricsRect,
  }) {
    // 歌词页恒是深底（模糊封面 + 压暗渐变），即使 app 是浅色也要用深色档的
    // 白字 / 深色玻璃 / 悬停底，否则浅色档的黑字与玻璃压在黑底上直接看不见。
    return FushiAppleDarkTier(
      child: lyricsPlayerIsWide(size)
          ? _WideChrome(
              data: data,
              callbacks: callbacks,
              layout: LyricsShellAppleWideLayout(
                size,
                padding,
                mirror: mirrorProgress,
              ),
              padding: padding,
            )
          : _NarrowChrome(
              data: data,
              callbacks: callbacks,
              layout: LyricsShellAppleNarrowLayout(size, padding),
              padding: padding,
            ),
    );
  }

  @override
  LyricsHtmlTheme htmlTheme(BuildContext context, LyricsPlayerData data) {
    // Niratan `ReaderLyricsVisualSpec`：白字靠透明度阶梯分层，左对齐，上下文行
    // 不模糊；查词高亮用白 30%（深底上唯一不抢当前行的高亮色）。
    return LyricsHtmlTheme(
      textColor: Colors.white,
      currentColor: Colors.white,
      accentColor: Colors.white.withValues(alpha: 0.3),
      selectionTextColor: Colors.white,
      contextOpacities: const <double>[0.46, 0.36, 0.3, 0.26],
      browsingOpacity: 0.6,
      deselectedScale: 0.96,
      anchorY: 0.46,
      edgeFade: 0.08,
      alignStart: true,
      contextBlurPx: 0,
      rowRadius: 16,
    );
  }
}

// ---------------------------------------------------------------------------
// 几何：lyricsRect 与控件层必须出自同一份计算，否则歌词与面板会错位。
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// 宽屏控件层
// ---------------------------------------------------------------------------

class _WideChrome extends StatelessWidget {
  const _WideChrome({
    required this.data,
    required this.callbacks,
    required this.layout,
    required this.padding,
  });

  final LyricsPlayerData data;
  final LyricsPlayerCallbacks callbacks;
  final LyricsShellAppleWideLayout layout;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    // 只用 Positioned 摆放画了东西的块；Stack / Center 本身不吃指针，空白处
    // 的点击、滚轮落到下面的歌词 WebView。
    return Stack(
      children: <Widget>[
        Positioned(
          left: layout.panelLeft,
          top: layout.top,
          width: layout.panelWidth,
          height: layout.height,
          child: Center(
            child: _PlayerPanel(
              data: data,
              callbacks: callbacks,
              layout: layout,
            ),
          ),
        ),
        Positioned(
          top: padding.top + layout.headerTop,
          right: padding.right + layout.chromePad,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // 布局「顶部」区的按钮（出厂 书籍模式 / 左右互换）；有退书回调时
              // × 直接退书回书架、「书籍模式」键回正文（反馈 QvYpZODImz）。
              for (final Widget button in _appleControlButtons(
                data.wideControls.itemsIn(LyricsControlSlot.top),
                data,
                callbacks,
                wide: true,
                header: true,
              )) ...<Widget>[button, const SizedBox(width: 8)],
              _LyricsIconButton(
                key: const ValueKey<String>('lyrics_close_button'),
                icon: CupertinoIcons.xmark,
                diameter: 38,
                iconSize: 18,
                color: Colors.white.withValues(alpha: 0.74),
                tooltip: callbacks.onExitBook != null
                    ? t.lyrics_exit_to_library
                    : t.floating_lyric_close,
                onPressed: callbacks.onExitBook ?? callbacks.onClose,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Niratan `playerPanel`：封面 → 书名与读数 → 进度条 → 播放键 → 小按钮行。
class _PlayerPanel extends StatelessWidget {
  const _PlayerPanel({
    required this.data,
    required this.callbacks,
    required this.layout,
  });

  final LyricsPlayerData data;
  final LyricsPlayerCallbacks callbacks;
  final LyricsShellAppleWideLayout layout;

  @override
  Widget build(BuildContext context) {
    final SizedBox gap = SizedBox(height: layout.panelSpacing);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 封面让位：读数换成竖排（窄面板 / 长标签语言）时元数据会比预留槽位高，
        // Niratan 是裁掉书名顶端，这里改为封面等比缩小——书名永远完整可见。
        Flexible(
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              // 播放走过书中插图时封面位换成插图（见 lyrics_illustration_view）。
              child: LyricsIllustrationArtworkSlot(
                controller: data.illustrations,
                side: layout.artworkSize,
                borderRadius: const BorderRadius.all(Radius.circular(12)),
                onOpen: callbacks.onOpenIllustration == null
                    ? null
                    : (int index) => callbacks.onOpenIllustration!(
                        index,
                        returnToCover: false,
                      ),
                cover: _Artwork(
                  cover: data.cover,
                  size: layout.artworkSize,
                  isPlaying: data.isPlaying,
                ),
              ),
            ),
          ),
        ),
        gap,
        ConstrainedBox(
          constraints: BoxConstraints(minHeight: layout.metadataHeight),
          child: Align(
            alignment: Alignment.bottomLeft,
            child: _WideMetadata(title: data.title, clock: data.clock),
          ),
        ),
        gap,
        SizedBox(
          height: kLyricsShellAppleScrubberHeight,
          child: _LyricsScrubber(clock: data.clock, onSeek: callbacks.onSeek),
        ),
        gap,
        _TransportRow(
          data: data,
          callbacks: callbacks,
          spacing: layout.controlSpacing,
          sideDiameter: 48,
          sideIconSize: 28,
          playDiameter: 64,
          playIconSize: data.isPlaying ? 42 : 38,
        ),
        gap,
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            // 布局「播放卡工具条」区的按钮，⋯ 恒在末尾。
            for (final Widget button in _appleControlButtons(
              data.wideControls.itemsIn(LyricsControlSlot.toolbar),
              data,
              callbacks,
              wide: true,
              header: false,
            )) ...<Widget>[button, const SizedBox(width: 10)],
            _MoreButton(onMore: callbacks.onMore),
          ],
        ),
      ],
    );
  }
}

/// 封面卡：圆角 12（连续曲率）、播放中深投影、暂停缩到 0.88（弹簧回弹）。
class _Artwork extends StatefulWidget {
  const _Artwork({
    required this.cover,
    required this.size,
    required this.isPlaying,
  });

  final ImageProvider? cover;
  final double size;
  final bool isPlaying;

  @override
  State<_Artwork> createState() => _ArtworkState();
}

class _ArtworkState extends State<_Artwork> {
  ImageStream? _stream;
  late final ImageStreamListener _listener = ImageStreamListener(
    _onImage,
    onError: (Object error, StackTrace? stackTrace) {
      // 封面解码失败：保持默认书封比例，不是错误。
    },
  );

  /// 封面宽高比。Niratan 是 scaledToFit 进正方形槽位，所以先拿到真实比例再
  /// 定卡片尺寸——圆角与投影要贴着封面本身，而不是贴着正方形槽位。
  double? _aspect;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant _Artwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cover != widget.cover) _resolve();
  }

  void _resolve() {
    final ImageProvider? cover = widget.cover;
    if (cover == null) {
      _stream?.removeListener(_listener);
      _stream = null;
      return;
    }
    final ImageStream stream = cover.resolve(
      createLocalImageConfiguration(context),
    );
    if (stream.key == _stream?.key) return;
    _stream?.removeListener(_listener);
    _stream = stream..addListener(_listener);
  }

  void _onImage(ImageInfo info, bool synchronousCall) {
    final double aspect = info.image.width / math.max(info.image.height, 1);
    info.dispose();
    if (!mounted || aspect == _aspect) return;
    setState(() => _aspect = aspect);
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool motion = fushiExpressiveMotionEnabled(context);
    final bool playing = widget.isPlaying;
    final double size = widget.size;
    final ImageProvider? cover = widget.cover;
    // 书封多是竖版：比例未知前按 0.7 占位，避免解码完成时卡片跳变太大。
    final double aspect = _aspect ?? 0.7;
    final double cardW = aspect >= 1 ? size : size * aspect;
    final double cardH = aspect >= 1 ? size / aspect : size;
    const BorderRadius radius = BorderRadius.all(Radius.circular(12));
    final Widget face = cover == null
        ? ColoredBox(
            color: Colors.white.withValues(alpha: 0.12),
            child: Center(
              child: Icon(
                CupertinoIcons.book,
                size: size * 0.18,
                color: Colors.white.withValues(alpha: 0.48),
              ),
            ),
          )
        : Image(
            image: cover,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
            errorBuilder: (BuildContext context, Object e, StackTrace? st) =>
                ColoredBox(color: Colors.white.withValues(alpha: 0.12)),
          );
    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: AnimatedScale(
          scale: playing ? 1 : 0.88,
          duration: motion ? const Duration(milliseconds: 600) : Duration.zero,
          curve: const _SpringCurve(),
          child: AnimatedContainer(
            duration: motion
                ? const Duration(milliseconds: 350)
                : Duration.zero,
            curve: Curves.easeOut,
            width: cover == null ? size : cardW,
            height: cover == null ? size : cardH,
            decoration: ShapeDecoration(
              shape: const RoundedSuperellipseBorder(borderRadius: radius),
              shadows: <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: playing ? 0.38 : 0.22),
                  blurRadius: playing ? 26 : 14,
                  offset: Offset(0, playing ? 14 : 8),
                ),
              ],
            ),
            child: ClipRSuperellipse(borderRadius: radius, child: face),
          ),
        ),
      ),
    );
  }
}

/// SwiftUI `.spring(response: 0.5, dampingFraction: 0.78)` 的闭式解：欠阻尼，
/// 有一点回弹；0.6 秒内收敛到 <0.3%。
class _SpringCurve extends Curve {
  const _SpringCurve();

  static const double _duration = 0.6;
  static const double _omega = 2 * math.pi / 0.5;
  static const double _zeta = 0.78;

  @override
  double transformInternal(double t) {
    final double time = t * _duration;
    final double wd = _omega * math.sqrt(1 - _zeta * _zeta);
    final double envelope = math.exp(-_zeta * _omega * time);
    return 1 -
        envelope *
            (math.cos(wd * time) + _zeta * _omega / wd * math.sin(wd * time));
  }
}

const TextStyle _kMetricStyle = TextStyle(
  fontSize: 11,
  fontWeight: FontWeight.w500,
  height: 1.25,
  color: Color(0x8FFFFFFF), // 白 0.56
  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
);

/// 书名 + 读数（Niratan `lyricsPlayerMetadata`）。
class _WideMetadata extends StatelessWidget {
  const _WideMetadata({required this.title, required this.clock});

  final String title;
  final LyricsPlayerClock clock;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            height: 1.25,
            color: Colors.white.withValues(alpha: 0.94),
          ),
        ),
        const SizedBox(height: 6),
        // 读数每秒变一次：只重建这一小块，不经整个覆盖层。
        _PeriodicRebuild(
          interval: const Duration(seconds: 1),
          builder: (BuildContext context) =>
              _MetricRow(metrics: _metricsOf(clock.stats)),
        ),
      ],
    );
  }
}

typedef _Metric = ({String label, String value});

String _progressText(LyricsPlayerStats stats) {
  final int? cur = stats.currentChars;
  final int? total = stats.totalChars;
  final double? percent = stats.percent;
  if (cur == null || total == null || percent == null) return '—';
  return '${t.reader_stats_position_progress(current: cur, total: total)}'
      ' · ${percent.toStringAsFixed(2)}%';
}

List<_Metric> _metricsOf(LyricsPlayerStats stats) {
  return <_Metric>[
    (
      label: t.stat_metric_speed,
      value: t.reader_stats_chars_per_hour(n: stats.charsPerHour),
    ),
    (label: t.reading_progress, value: _progressText(stats)),
    (
      label: t.stat_metric_time,
      value: formatLyricsPlayerTime(
        Duration(milliseconds: stats.sessionDurationMs),
      ),
    ),
  ];
}

/// 「速度 / 进度 / 时长」三段：放得下排一行，放不下换成竖排
/// （SwiftUI `ViewThatFits(in: .horizontal)`）。
class _MetricRow extends StatelessWidget {
  const _MetricRow({required this.metrics});

  final List<_Metric> metrics;

  static const double _rowSpacing = 12;

  InlineSpan _span(_Metric metric) => TextSpan(
    text: '${metric.label}: ',
    children: <InlineSpan>[
      TextSpan(
        text: metric.value,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final TextDirection direction = Directionality.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        double total = _rowSpacing * (metrics.length - 1);
        for (final _Metric metric in metrics) {
          final TextPainter painter = TextPainter(
            text: TextSpan(
              style: _kMetricStyle,
              children: <InlineSpan>[_span(metric)],
            ),
            textDirection: direction,
            textScaler: scaler,
            maxLines: 1,
          )..layout();
          total += painter.width;
          painter.dispose();
        }
        final List<Widget> items = <Widget>[
          for (final _Metric metric in metrics)
            Text.rich(
              _span(metric),
              style: _kMetricStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
        ];
        if (total <= constraints.maxWidth) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (int i = 0; i < items.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(width: _rowSpacing),
                items[i],
              ],
            ],
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (int i = 0; i < items.length; i++) ...<Widget>[
              if (i > 0) const SizedBox(height: 3),
              items[i],
            ],
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 窄屏控件层
// ---------------------------------------------------------------------------

class _NarrowChrome extends StatelessWidget {
  const _NarrowChrome({
    required this.data,
    required this.callbacks,
    required this.layout,
    required this.padding,
  });

  final LyricsPlayerData data;
  final LyricsPlayerCallbacks callbacks;
  final LyricsShellAppleNarrowLayout layout;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final Rect bar = layout.barRect;
    // 布局「播放卡工具条」区的按钮分到播放键两侧：前一半在左、后一半在右（⋯
    // 恒在右侧末尾）。出厂 倍速 / 计时 | 重播。
    final List<Widget> buttons = _appleControlButtons(
      data.compactControls.itemsIn(LyricsControlSlot.toolbar),
      data,
      callbacks,
      wide: false,
      header: false,
    );
    final int split = (buttons.length + 1) ~/ 2;
    final ({List<Widget> leading, List<Widget> trailing}) toolbar = (
      leading: buttons.sublist(0, split),
      trailing: buttons.sublist(split),
    );
    // 标题下方的插图卡框：与宽屏封面位同一套弹出逻辑，贴标题行左缘往下展开，
    // 底边不压到播放卡（各留 12），高不超过 320。
    final double popupTop =
        layout.headerTop + kLyricsShellAppleNarrowHeaderHeight + 12;
    final double popupHeight = math.max(
      0,
      math.min(320, bar.top - 12 - popupTop),
    );
    final double popupWidth = bar.width * 0.6;
    return Stack(
      children: <Widget>[
        Positioned(
          left: bar.left,
          top: popupTop,
          width: popupWidth,
          height: popupHeight,
          child: LyricsIllustrationPopupCard(
            controller: data.illustrations,
            width: popupWidth,
            height: popupHeight,
            borderRadius: const BorderRadius.all(Radius.circular(14)),
            alignment: AlignmentDirectional.topStart,
            onOpen: callbacks.onOpenIllustration == null
                ? null
                : (int index) => callbacks.onOpenIllustration!(
                    index,
                    returnToCover: false,
                  ),
          ),
        ),
        Positioned(
          left: padding.left + 18,
          right: padding.right + 10,
          top: layout.headerTop,
          height: kLyricsShellAppleNarrowHeaderHeight,
          child: Row(
            children: <Widget>[
              // 窄屏左上角返回键（iOS 没有系统返回键；此前只有右上角 ×，用户
              // 认不出它是「返回」，2026-10-09 反馈）。
              _LyricsIconButton(
                key: const ValueKey<String>('lyrics_player_back'),
                icon: CupertinoIcons.chevron_left,
                diameter: 38,
                iconSize: 18,
                color: Colors.white.withValues(alpha: 0.74),
                tooltip: t.back,
                onPressed: callbacks.onClose,
              ),
              const SizedBox(width: 6),
              _NarrowIllustrationEntry(data: data, callbacks: callbacks),
              Expanded(
                // 书名行也是插图入口（与左侧缩略图同一动作）。
                child: LyricsIllustrationTapTarget(
                  controller: data.illustrations,
                  onOpen: callbacks.onOpenIllustration == null
                      ? null
                      : (int index) => callbacks.onOpenIllustration!(
                          index,
                          returnToCover: true,
                        ),
                  child: _NarrowHeader(title: data.title, clock: data.clock),
                ),
              ),
              // 布局「顶部」区的按钮（出厂 遮罩 / Aa / 统计）。
              ..._appleControlButtons(
                data.compactControls.itemsIn(LyricsControlSlot.top),
                data,
                callbacks,
                wide: false,
                header: true,
              ),
              // 左上角返回键回正文；× 直接退书回书架（反馈 QvYpZODImz）。
              if (callbacks.onExitBook != null)
                _LyricsIconButton(
                  key: const ValueKey<String>('lyrics_close_button'),
                  icon: CupertinoIcons.xmark,
                  diameter: 38,
                  iconSize: 18,
                  color: Colors.white.withValues(alpha: 0.74),
                  tooltip: t.lyrics_exit_to_library,
                  onPressed: callbacks.onExitBook!,
                ),
            ],
          ),
        ),
        Positioned.fromRect(
          rect: bar,
          child: _GlassControlBar(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 14, 10),
              child: Column(
                children: <Widget>[
                  SizedBox(
                    height: kLyricsShellAppleScrubberHeight,
                    child: _LyricsScrubber(
                      clock: data.clock,
                      onSeek: callbacks.onSeek,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Expanded(
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: _SideGroup(
                            alignment: Alignment.centerLeft,
                            children: toolbar.leading,
                          ),
                        ),
                        _TransportRow(
                          data: data,
                          callbacks: callbacks,
                          spacing: 4,
                          sideDiameter: 44,
                          sideIconSize: 24,
                          playDiameter: 52,
                          playIconSize: data.isPlaying ? 34 : 31,
                        ),
                        Expanded(
                          child: _SideGroup(
                            alignment: Alignment.centerRight,
                            children: <Widget>[
                              ...toolbar.trailing,
                              _MoreButton(onMore: callbacks.onMore),
                            ],
                          ),
                        ),
                      ],
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
}

/// 窄屏插图入口（Apple 窄屏本不放封面，Niratan 同款）：听到过插图后才在书名
/// 左侧出现一枚小缩略图——新插图到达时换成它并带提示点，点它看插图大图，看完
/// 回到「最近一张」的常态。一张都没听到时不占位。
class _NarrowIllustrationEntry extends StatelessWidget {
  const _NarrowIllustrationEntry({required this.data, required this.callbacks});

  final LyricsPlayerData data;
  final LyricsPlayerCallbacks callbacks;

  static const double _size = 36;

  @override
  Widget build(BuildContext context) {
    final LyricsIllustrationController? c = data.illustrations;
    if (c == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: c,
      builder: (BuildContext context, Widget? _) {
        if (!c.hasReached) return const SizedBox.shrink();
        final int cache = (_size * MediaQuery.devicePixelRatioOf(context))
            .round();
        return Padding(
          padding: const EdgeInsetsDirectional.only(end: 10),
          child: LyricsIllustrationCompactArtwork(
            controller: c,
            onOpen: callbacks.onOpenIllustration == null
                ? null
                : (int index) =>
                      callbacks.onOpenIllustration!(index, returnToCover: true),
            builder: (BuildContext context, ImageProvider? illustration) =>
                ClipRSuperellipse(
                  borderRadius: const BorderRadius.all(Radius.circular(8)),
                  child: SizedBox.square(
                    dimension: _size,
                    child: Image(
                      image: ResizeImage.resizeIfNeeded(
                        cache,
                        null,
                        illustration ?? c.items[c.reached].image,
                      ),
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.medium,
                      gaplessPlayback: true,
                      errorBuilder: (_, Object e, StackTrace? s) => ColoredBox(
                        color: Colors.white.withValues(alpha: 0.12),
                      ),
                    ),
                  ),
                ),
          ),
        );
      },
    );
  }
}

/// 控制条两侧的按钮组：窄到放不下时整组等比缩小，而不是溢出报错。
class _SideGroup extends StatelessWidget {
  const _SideGroup({required this.alignment, required this.children});

  final Alignment alignment;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: alignment,
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

class _NarrowHeader extends StatelessWidget {
  const _NarrowHeader({required this.title, required this.clock});

  final String title;
  final LyricsPlayerClock clock;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            height: 1.25,
            color: Colors.white.withValues(alpha: 0.94),
          ),
        ),
        const SizedBox(height: 2),
        _PeriodicRebuild(
          interval: const Duration(seconds: 1),
          builder: (BuildContext context) {
            // 窄屏只有一行：去掉标签，只留数值，用 · 分隔。
            final String line = _metricsOf(
              clock.stats,
            ).map((_Metric m) => m.value).join('  ·  ');
            return Text(
              line,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _kMetricStyle,
            );
          },
        ),
      ],
    );
  }
}

/// 透明液态玻璃胶囊（iOS 26 `glassEffect(.regular)` 的大面积浮动条配方）。
/// 系统「降低透明度」时 [fushiClearGlassSettings] 自己回落实色。
class _GlassControlBar extends StatelessWidget {
  const _GlassControlBar({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GlassContainer(
      useOwnLayer: true,
      quality: fushiGlassQuality(context, prominent: true),
      settings: fushiClearGlassSettings(context, bar: true),
      shape: const LiquidRoundedSuperellipse(borderRadius: 30),
      child: child,
    );
  }
}

// ---------------------------------------------------------------------------
// 共用控件
// ---------------------------------------------------------------------------

/// 按固定间隔重建子树（读数 / 播放位置的只读轮询）。
class _PeriodicRebuild extends StatefulWidget {
  const _PeriodicRebuild({required this.interval, required this.builder});

  final Duration interval;
  final WidgetBuilder builder;

  @override
  State<_PeriodicRebuild> createState() => _PeriodicRebuildState();
}

class _PeriodicRebuildState extends State<_PeriodicRebuild> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.interval, (Timer _) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  // 自带重绘边界：按间隔重建的读数只重录这一小块，不连带整个控件层。
  @override
  Widget build(BuildContext context) =>
      RepaintBoundary(child: widget.builder(context));
}

/// 无底色白色图标按钮（Niratan `LyricsPlayerIconButton`）：白 0.88、黑 0.28
/// 柔投影；悬停 / 按下 / 键盘焦点环交给 [FushiPlainButton]（Tab 聚焦、Enter 触发）。
class _LyricsIconButton extends StatelessWidget {
  const _LyricsIconButton({
    required this.icon,
    required this.diameter,
    required this.iconSize,
    required this.tooltip,
    this.onPressed,
    this.onPressedWithRect,
    this.color,
    this.iconKey,
    super.key,
  });

  final IconData icon;
  final double diameter;
  final double iconSize;
  final String tooltip;
  final VoidCallback? onPressed;

  /// 需要锚定菜单的按钮：回调里带本按钮的全局矩形与 context。
  final ValueChanged<LyricsMenuAnchor>? onPressedWithRect;
  final Color? color;

  /// 给 [AnimatedSwitcher] 区分新旧图标用。
  final Key? iconKey;

  @override
  Widget build(BuildContext context) {
    final ValueChanged<LyricsMenuAnchor>? withRect = onPressedWithRect;
    final Widget glyph = Icon(
      icon,
      key: iconKey,
      size: iconSize,
      color: color ?? Colors.white.withValues(alpha: 0.88),
      shadows: <Shadow>[
        Shadow(
          color: Colors.black.withValues(alpha: 0.28),
          blurRadius: 12,
          offset: const Offset(0, 5),
        ),
      ],
    );
    return FushiTooltip(
      message: tooltip,
      child: FushiPlainButton(
        semanticLabel: tooltip,
        borderRadius: BorderRadius.circular(diameter / 2),
        onPressed: withRect == null
            ? onPressed
            : () => withRect(
                LyricsMenuAnchor(
                  rect: _globalRectOf(context),
                  context: context,
                ),
              ),
        child: SizedBox(
          width: diameter,
          height: diameter,
          child: Center(
            child: AnimatedSwitcher(
              duration: fushiExpressiveMotionEnabled(context)
                  ? const Duration(milliseconds: 200)
                  : Duration.zero,
              transitionBuilder: (Widget child, Animation<double> anim) =>
                  FadeTransition(
                    opacity: anim,
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.6, end: 1).animate(anim),
                      child: child,
                    ),
                  ),
              child: glyph,
            ),
          ),
        ),
      ),
    );
  }
}

Rect _globalRectOf(BuildContext context) {
  final RenderObject? box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return Rect.zero;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// ⏮ ▶/⏸ ⏭。
class _TransportRow extends StatelessWidget {
  const _TransportRow({
    required this.data,
    required this.callbacks,
    required this.spacing,
    required this.sideDiameter,
    required this.sideIconSize,
    required this.playDiameter,
    required this.playIconSize,
  });

  final LyricsPlayerData data;
  final LyricsPlayerCallbacks callbacks;
  final double spacing;
  final double sideDiameter;
  final double sideIconSize;
  final double playDiameter;
  final double playIconSize;

  @override
  Widget build(BuildContext context) {
    final bool playing = data.isPlaying;
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        _LyricsIconButton(
          icon: CupertinoIcons.backward_end_fill,
          diameter: sideDiameter,
          iconSize: sideIconSize,
          tooltip: t.floating_lyric_previous,
          onPressed: callbacks.onPreviousCue,
        ),
        SizedBox(width: spacing),
        _LyricsIconButton(
          icon: playing ? CupertinoIcons.pause_fill : CupertinoIcons.play_fill,
          iconKey: ValueKey<bool>(playing),
          diameter: playDiameter,
          iconSize: playIconSize,
          tooltip: playing ? t.pause : t.play,
          onPressed: callbacks.onPlayPause,
        ),
        SizedBox(width: spacing),
        _LyricsIconButton(
          icon: CupertinoIcons.forward_end_fill,
          diameter: sideDiameter,
          iconSize: sideIconSize,
          tooltip: t.floating_lyric_next,
          onPressed: callbacks.onNextCue,
        ),
      ],
    );
  }
}

/// 布局里一个区的按钮，按顺序渲染（[LyricsControlLayout]）。页面没给回调的按钮
/// 与当前形态下无意义的按钮（左右互换只在宽屏）不画。[header] = 页眉那组 38 号
/// 淡白色键，否则是播放面板里的 34 号键。
List<Widget> _appleControlButtons(
  List<LyricsControlItem> items,
  LyricsPlayerData data,
  LyricsPlayerCallbacks callbacks, {
  required bool wide,
  required bool header,
}) {
  final double diameter = header ? 38 : 34;
  final double iconSize = header ? 18 : 19;
  final Color? color = header ? Colors.white.withValues(alpha: 0.74) : null;
  Widget? build(LyricsControlItem item) {
    switch (item) {
      case LyricsControlItem.speed:
        return _SpeedButton(
          speed: data.speed,
          onChanged: callbacks.onSpeedChanged,
          onSpeedPanel: callbacks.onSpeedPanel,
        );
      case LyricsControlItem.studyTimer:
        final VoidCallback? onToggle = callbacks.onToggleStatsTimer;
        if (onToggle == null) return null;
        // 文案是「按下去会怎样」（与阅读器顶栏计时键同口径）。
        final bool paused = data.statsTimerPaused;
        return _LyricsIconButton(
          key: const ValueKey<String>('lyrics_study_timer_button'),
          icon: paused ? CupertinoIcons.timer_fill : CupertinoIcons.timer,
          iconKey: ValueKey<bool>(paused),
          diameter: diameter,
          iconSize: iconSize,
          color: color,
          tooltip: paused
              ? t.reader_stats_clock_resume
              : t.reader_stats_clock_pause,
          onPressed: onToggle,
        );
      case LyricsControlItem.replayCue:
        final VoidCallback? onReplay = callbacks.onReplayCue;
        if (onReplay == null) return null;
        return _LyricsIconButton(
          key: const ValueKey<String>('lyrics_replay_cue_button'),
          icon: CupertinoIcons.arrow_counterclockwise,
          diameter: diameter,
          iconSize: iconSize,
          color: color,
          tooltip: t.lyrics_sentence_replay,
          onPressed: onReplay,
        );
      case LyricsControlItem.mask:
        final bool masked = data.lyricsMasked;
        return _LyricsIconButton(
          icon: masked ? CupertinoIcons.eye_slash : CupertinoIcons.eye,
          iconKey: ValueKey<bool>(masked),
          diameter: diameter,
          iconSize: iconSize,
          color: color,
          tooltip: t.lyrics_blur,
          onPressed: callbacks.onToggleMask,
        );
      case LyricsControlItem.typography:
        final ValueChanged<LyricsMenuAnchor>? onTypography =
            callbacks.onTypography;
        if (onTypography == null) return null;
        return _LyricsIconButton(
          key: const ValueKey<String>('lyrics_typography_button'),
          icon: CupertinoIcons.textformat_size,
          diameter: diameter,
          iconSize: iconSize,
          color: color,
          tooltip: t.lyrics_typography_title,
          onPressedWithRect: onTypography,
        );
      case LyricsControlItem.statistics:
        return _LyricsIconButton(
          key: const ValueKey<String>('lyrics_statistics_button'),
          icon: CupertinoIcons.chart_bar,
          diameter: diameter,
          iconSize: iconSize,
          color: color,
          tooltip: t.reading_statistics,
          onPressed: callbacks.onOpenStatistics,
        );
      case LyricsControlItem.bookMode:
        // 没有退书回调时 × 本身就是「回正文」，再摆一颗同义键只是重复。
        if (callbacks.onExitBook == null) return null;
        return _LyricsIconButton(
          key: const ValueKey<String>('lyrics_return_to_book_button'),
          icon: CupertinoIcons.book,
          diameter: diameter,
          iconSize: iconSize,
          color: color,
          tooltip: t.book_mode,
          onPressed: callbacks.onClose,
        );
      case LyricsControlItem.swapSides:
        final VoidCallback? onSwap = callbacks.onSwapSides;
        if (onSwap == null || !wide) return null;
        return _LyricsIconButton(
          key: const ValueKey<String>('lyrics_swap_sides_button'),
          icon: CupertinoIcons.arrow_right_arrow_left,
          diameter: diameter,
          iconSize: iconSize,
          color: color,
          tooltip: t.lyrics_layout_swap_sides,
          onPressed: onSwap,
        );
    }
  }

  return <Widget>[for (final LyricsControlItem item in items) ?build(item)];
}

class _MoreButton extends StatelessWidget {
  const _MoreButton({required this.onMore});

  final ValueChanged<LyricsMenuAnchor> onMore;

  @override
  Widget build(BuildContext context) {
    return _LyricsIconButton(
      icon: CupertinoIcons.ellipsis,
      diameter: 34,
      iconSize: 19,
      tooltip: t.common_more_actions,
      onPressedWithRect: onMore,
    );
  }
}

/// 倍速小文字按钮，点开锚定在按钮上的倍速面板（与普通阅读模式快捷设置同一条
/// `AudiobookSpeedSlider`），拖动实时生效。
class _SpeedButton extends StatelessWidget {
  const _SpeedButton({
    required this.speed,
    required this.onChanged,
    this.onSpeedPanel,
  });

  final double speed;
  final ValueChanged<double> onChanged;

  /// 页面弹面板（面板开着期间停表）；null 时按钮自己弹。
  final ValueChanged<LyricsMenuAnchor>? onSpeedPanel;

  @override
  Widget build(BuildContext context) {
    final String label = formatLyricsSpeed(speed);
    return FushiTooltip(
      message: t.playback_speed,
      child: FushiPressScale(
        child: FushiPlainButton(
          semanticLabel: '${t.playback_speed} $label',
          borderRadius: BorderRadius.circular(17),
          onPressed: () {
            final ValueChanged<LyricsMenuAnchor>? viaPage = onSpeedPanel;
            final RenderObject? box = context.findRenderObject();
            if (viaPage != null && box is RenderBox && box.hasSize) {
              viaPage(
                LyricsMenuAnchor(
                  rect: box.localToGlobal(Offset.zero) & box.size,
                  context: context,
                ),
              );
              return;
            }
            unawaited(
              showLyricsSpeedPanel(
                anchorContext: context,
                speed: speed,
                onChanged: onChanged,
              ),
            );
          },
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7),
              child: Center(
                widthFactor: 1,
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white.withValues(alpha: 0.88),
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                    shadows: <Shadow>[
                      Shadow(
                        color: Colors.black.withValues(alpha: 0.28),
                        blurRadius: 12,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 进度条
// ---------------------------------------------------------------------------

class _SeekByIntent extends Intent {
  const _SeekByIntent(this.delta);

  final Duration delta;
}

/// Niratan `lyricsScrubber`：胶囊轨道白 0.2、填充白 0.72；悬停 / 拖动 / 键盘
/// 焦点时填充 0.94、粗 5→9。拖动中显示本地值，松手才 [onSeek]。键盘左右键 ±5 秒。
class _LyricsScrubber extends StatefulWidget {
  const _LyricsScrubber({required this.clock, required this.onSeek});

  final LyricsPlayerClock clock;
  final ValueChanged<Duration> onSeek;

  @override
  State<_LyricsScrubber> createState() => _LyricsScrubberState();
}

class _LyricsScrubberState extends State<_LyricsScrubber> {
  Timer? _timer;
  bool _hovered = false;
  bool _focused = false;

  /// 拖动中的本地进度（0–1）；null = 跟随播放器。
  double? _dragFraction;

  /// 松手后到播放器真正跳过去之间的短暂空窗：先显示目标位置，避免进度条
  /// 回弹到旧位置再跳回来。
  Duration? _pendingSeek;
  DateTime _pendingSince = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    // 只重建进度条这一小块（250ms 足够顺滑且省电），不经整个覆盖层。
    _timer = Timer.periodic(const Duration(milliseconds: 250), (Timer _) {
      if (mounted && _dragFraction == null) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Duration get _duration {
    final Duration d = widget.clock.duration;
    return d.isNegative ? Duration.zero : d;
  }

  Duration _displayed() {
    final Duration duration = _duration;
    final double? drag = _dragFraction;
    if (drag != null) {
      return Duration(milliseconds: (duration.inMilliseconds * drag).round());
    }
    final Duration position = widget.clock.position;
    final Duration? pending = _pendingSeek;
    if (pending != null) {
      final bool arrived = (position - pending).inMilliseconds.abs() < 1500;
      final bool expired =
          DateTime.now().difference(_pendingSince) >
          const Duration(milliseconds: 1200);
      if (arrived || expired) {
        _pendingSeek = null;
      } else {
        return pending;
      }
    }
    if (position.isNegative) return Duration.zero;
    return position > duration ? duration : position;
  }

  void _seekTo(Duration target) {
    final Duration duration = _duration;
    if (duration <= Duration.zero) return;
    final Duration clamped = target.isNegative
        ? Duration.zero
        : (target > duration ? duration : target);
    setState(() {
      _pendingSeek = clamped;
      _pendingSince = DateTime.now();
      _dragFraction = null;
    });
    widget.onSeek(clamped);
  }

  void _updateDrag(double dx, double width) {
    if (_duration <= Duration.zero) return;
    setState(() => _dragFraction = (dx / math.max(width, 1)).clamp(0.0, 1.0));
  }

  void _endDrag() {
    final double? fraction = _dragFraction;
    if (fraction == null) return;
    _seekTo(
      Duration(milliseconds: (_duration.inMilliseconds * fraction).round()),
    );
  }

  // 自带重绘边界：250ms 一次的进度刷新只重录进度条，不连带整个控件层。
  @override
  Widget build(BuildContext context) =>
      RepaintBoundary(child: _buildScrubber(context));

  Widget _buildScrubber(BuildContext context) {
    final Duration duration = _duration;
    final Duration shown = _displayed();
    final double fraction = duration.inMilliseconds > 0
        ? (shown.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0;
    final bool active = _hovered || _focused || _dragFraction != null;
    final bool motion = fushiExpressiveMotionEnabled(context);
    final Color focusColor = appleColorsOf(context).accent;
    final TextStyle timeStyle = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      height: 1.2,
      color: Colors.white.withValues(alpha: 0.52),
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    final Duration remaining = duration - shown;
    return Semantics(
      slider: true,
      label: t.reading_progress,
      value: formatLyricsPlayerTime(shown),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            height: 14,
            child: FocusableActionDetector(
              mouseCursor: SystemMouseCursors.click,
              shortcuts: const <ShortcutActivator, Intent>{
                SingleActivator(LogicalKeyboardKey.arrowLeft): _SeekByIntent(
                  Duration(seconds: -5),
                ),
                SingleActivator(LogicalKeyboardKey.arrowRight): _SeekByIntent(
                  Duration(seconds: 5),
                ),
              },
              actions: <Type, Action<Intent>>{
                _SeekByIntent: CallbackAction<_SeekByIntent>(
                  onInvoke: (_SeekByIntent intent) {
                    _seekTo(_displayed() + intent.delta);
                    return null;
                  },
                ),
              },
              onShowHoverHighlight: (bool value) =>
                  setState(() => _hovered = value),
              onShowFocusHighlight: (bool value) =>
                  setState(() => _focused = value),
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  final double width = constraints.maxWidth;
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (TapDownDetails d) =>
                        _updateDrag(d.localPosition.dx, width),
                    onTapUp: (TapUpDetails d) => _endDrag(),
                    onTapCancel: () {
                      // 横拖接管了手势：保留本地值，交给 drag 回调收尾。
                    },
                    onHorizontalDragStart: (DragStartDetails d) =>
                        _updateDrag(d.localPosition.dx, width),
                    onHorizontalDragUpdate: (DragUpdateDetails d) =>
                        _updateDrag(d.localPosition.dx, width),
                    onHorizontalDragEnd: (DragEndDetails d) => _endDrag(),
                    onHorizontalDragCancel: () =>
                        setState(() => _dragFraction = null),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween<double>(end: active ? 1 : 0),
                      duration: motion
                          ? const Duration(milliseconds: 160)
                          : Duration.zero,
                      curve: Curves.easeInOut,
                      builder: (BuildContext context, double a, Widget? child) {
                        return CustomPaint(
                          size: Size(width, 14),
                          painter: _TrackPainter(
                            fraction: fraction,
                            thickness: lerpDouble(5, 9, a)!,
                            fillAlpha: lerpDouble(0.72, 0.94, a)!,
                            focusColor: _focused ? focusColor : null,
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 5),
          Row(
            children: <Widget>[
              Text(formatLyricsPlayerTime(shown), style: timeStyle),
              const Spacer(),
              Text(
                '-${formatLyricsPlayerTime(remaining.isNegative ? Duration.zero : remaining)}',
                style: timeStyle,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TrackPainter extends CustomPainter {
  const _TrackPainter({
    required this.fraction,
    required this.thickness,
    required this.fillAlpha,
    required this.focusColor,
  });

  final double fraction;
  final double thickness;
  final double fillAlpha;
  final Color? focusColor;

  @override
  void paint(Canvas canvas, Size size) {
    final double top = (size.height - thickness) / 2;
    final Radius radius = Radius.circular(thickness / 2);
    final Rect track = Rect.fromLTWH(0, top, size.width, thickness);
    canvas.drawRRect(
      RRect.fromRectAndRadius(track, radius),
      Paint()..color = Colors.white.withValues(alpha: 0.2),
    );
    if (fraction > 0) {
      // 填充与轨道同一胶囊裁切：进度很小时左端仍是圆头，不会画出方块。
      canvas.save();
      canvas.clipRRect(RRect.fromRectAndRadius(track, radius));
      canvas.drawRect(
        Rect.fromLTWH(0, top, size.width * fraction, thickness),
        Paint()..color = Colors.white.withValues(alpha: fillAlpha),
      );
      canvas.restore();
    }
    final Color? focus = focusColor;
    if (focus != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(track.inflate(3), Radius.circular(thickness)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = focus,
      );
    }
  }

  @override
  bool shouldRepaint(_TrackPainter old) =>
      old.fraction != fraction ||
      old.thickness != thickness ||
      old.fillAlpha != fillAlpha ||
      old.focusColor != focusColor;
}
