/// 全屏歌词动画样式「莫奈」（移植自 folia-major `src/components/visualizer/monet/`，背景来自
/// `backgrounds/monet/`）。
///
/// 海报式版面：左列是歌手（斜体）、竖线、标题、专辑、歌词栏和一枚描述胶囊；右列是封面
/// 肖像（正方形向画面中间外扩，或带边框的竖长方形）；底部一条频谱。背景是处理过的封面
/// （去色 / 饱和度 / 水洗重着色 + 模糊 + 主题叠色 + 竖向纹理），缓慢漂移。换歌时各块按
/// folia 的延时依次滑入。可镜像（肖像在左、文字靠右）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/rendering.dart' show RendererBinding;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/monet/monet_audio_overlay.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/monet/monet_background.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/monet/monet_lyrics_model.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/monet/monet_rail.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/monet/monet_tuning.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 注册项。背景与译文都由样式自己画。
final LyricVisualizerEntry monetVisualizerEntry = LyricVisualizerEntry(
  mode: LyricVisualizerMode.monet,
  label: () => t.music_visualizer_mode_monet,
  description: () => t.music_visualizer_monet_description,
  icon: FushiIcons.image,
  tunings: monetTuningSpecs,
  sharedBackdrop: false,
  sharedSubtitle: false,
  builder: (LyricVisualizerContext c) => MonetVisualizer(context: c),
);

/// folia 海报入场缓动 `[0.25, 1, 0.5, 1]`。
const Cubic _kIntroCurve = Cubic(0.25, 1, 0.5, 1);

/// 莫奈样式本体。
class MonetVisualizer extends StatelessWidget {
  const MonetVisualizer({super.key, required this.context});

  final LyricVisualizerContext context;

  @override
  Widget build(BuildContext buildContext) => LyricVisualizerFrame(
    context: context,
    builder: (BuildContext bc, LyricVisualizerTicks ticks) =>
        _MonetStage(visualizer: context, ticks: ticks),
  );
}

class _MonetStage extends StatefulWidget {
  const _MonetStage({required this.visualizer, required this.ticks});

  final LyricVisualizerContext visualizer;
  final LyricVisualizerTicks ticks;

  @override
  State<_MonetStage> createState() => _MonetStageState();
}

class _MonetStageState extends State<_MonetStage> {
  final MonetRailController _rail = MonetRailController();
  late double _introStart = widget.ticks.value.elapsed;
  late final double _mountStart = widget.ticks.value.elapsed;
  int _lastTimeMs = 0;
  bool _capsuleHovered = false;

  @override
  void initState() {
    super.initState();
    _lastTimeMs = widget.ticks.value.timeMs;
    widget.ticks.addListener(_onTick);
  }

  @override
  void didUpdateWidget(covariant _MonetStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.ticks, widget.ticks)) {
      oldWidget.ticks.removeListener(_onTick);
      widget.ticks.addListener(_onTick);
    }
    final LyricVisualizerContext a = oldWidget.visualizer;
    final LyricVisualizerContext b = widget.visualizer;
    if (a.seed != b.seed || !identical(a.timeline, b.timeline)) {
      // 换歌：海报整组重新入场（folia introKey），歌词栏直接就位。
      _rail.reset();
      _introStart = widget.ticks.value.elapsed;
    }
  }

  void _onTick() {
    final int now = widget.ticks.value.timeMs;
    // 从尾部跳回开头（单曲循环）也重播入场。
    if (_lastTimeMs > 2000 && now < 100) {
      _introStart = widget.ticks.value.elapsed;
    }
    _lastTimeMs = now;
  }

  @override
  void dispose() {
    widget.ticks.removeListener(_onTick);
    _rail.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.ticks,
    builder: (BuildContext c, Widget? _) => LayoutBuilder(
      builder: (BuildContext lc, BoxConstraints box) =>
          _buildStage(widget.ticks.value, box.biggest),
    ),
  );

  Widget _buildStage(LyricVisualizerTick tick, Size size) {
    final LyricVisualizerContext v = widget.visualizer;
    final LyricVisualizerPalette pal = v.palette;
    final MonetConfig cfg = MonetConfig.from(v.tuning);
    final bool motion = v.motion;
    final double w = size.width;
    final double h = size.height;
    if (!w.isFinite || !h.isFinite || w <= 0 || h <= 0) {
      return const SizedBox.shrink();
    }

    double intro(double delay, double duration, [double? from]) {
      if (!motion) return 1;
      final double p =
          ((tick.elapsed - (from ?? _introStart) - delay) / duration).clamp(
            0.0,
            1.0,
          );
      return _kIntroCurve.transform(p);
    }

    final double fs = cfg.fontScale * v.fontScale;
    final double ls = monetLargeScreenScale(w);
    final double lyricFont = monetLyricFontPx(w, fs);
    final double inactiveFont = monetInactiveFontPx(w, fs);
    final double translationFont = monetTranslationFontPx(w, fs);
    final bool mirrored = cfg.mirrored;
    final double side = mirrored ? -1 : 1;
    final bool showPortrait = cfg.showPortrait && monetShowsPortrait(w);

    final double rowW = math.min(
      w,
      (kMonetRowBaseMaxWidthPx * ls).roundToDouble(),
    );
    final double portraitColW = showPortrait
        ? monetClamp(
            220,
            w * 0.28,
            (kMonetPortraitBaseMaxPx * ls).roundToDouble(),
          )
        : 0;
    final double textColW = math.max(0, rowW - portraitColW);
    final double padX = monetTextPadX(w);
    final double padY = monetTextPadY(w);
    final double colContentW = math.max(0, textColW - padX * 2);
    final double glow = monetGlowBufferPx(lyricFont);
    final double railBoxW = math.min(
      colContentW + glow * 2,
      (kMonetRailBaseMaxWidthPx * ls).roundToDouble(),
    );
    final double railW = math.max(0, railBoxW - glow * 2);
    final double railH = monetRailHeightPx(h, lyricFont, ls);
    final double innerW = monetClamp(
      210,
      w * 0.26,
      (kMonetPortraitInnerBaseMaxPx * ls).roundToDouble(),
    );
    // 标题右侧要给外扩的正方形封面 / 拖过去的偏移让出位置（folia headerMaxWidth）。
    final double bleed = showPortrait && cfg.squarePortrait
        ? kMonetSquareBleed * innerW - 48
        : 0;
    final double shift = showPortrait
        ? math.min(0.0, cfg.portraitOffsetX).abs()
        : 0;
    final double headerMaxW = math.max(
      192,
      colContentW - math.max(0, bleed) - shift,
    );

    final Color primary = pal.text;
    final TextAlign align = mirrored ? TextAlign.right : TextAlign.left;
    final CrossAxisAlignment cross = mirrored
        ? CrossAxisAlignment.end
        : CrossAxisAlignment.start;

    final String artist = (v.artist?.trim().isNotEmpty ?? false)
        ? v.artist!.trim()
        : 'Monet';
    final String album = (v.album?.trim().isNotEmpty ?? false)
        ? v.album!.trim()
        : 'Monet';
    final String title = (v.title?.trim().isNotEmpty ?? false)
        ? v.title!.trim()
        : 'Monet';

    final double aArtist = intro(0.15, 1.2);
    final double aLine = intro(0.5, 1.5);
    final double aTitle = intro(0.3, 1.3);
    final double aRail = intro(0.65, 1.2);
    final double aDesc = intro(0.95, 1.0);
    final double aAudio = intro(0.8, 1.2);
    final double aPortrait = intro(0.25, 1.6, _mountStart);

    final Widget header = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: headerMaxW),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: cross,
        children: <Widget>[
          Opacity(
            opacity: aArtist,
            child: Transform.translate(
              offset: Offset(-30 * side * (1 - aArtist), -10 * (1 - aArtist)),
              child: Text(
                artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: align,
                style: TextStyle(
                  color: primary.withValues(alpha: 0.96),
                  fontSize: monetClamp(16, w * 0.018, 28.8 * ls),
                  fontStyle: FontStyle.italic,
                  letterSpacing: 0,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Transform(
            alignment: Alignment.topCenter,
            transform: Matrix4.diagonal3Values(1, aLine, 1),
            child: Container(
              width: 1,
              height: 56,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(1),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    primary.withValues(alpha: 0.72),
                    primary.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );

    final Widget titleBlock = Opacity(
      opacity: aTitle,
      child: Transform.translate(
        offset: Offset(-40 * side * (1 - aTitle), 0),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: headerMaxW),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: cross,
            children: <Widget>[
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: align,
                style: TextStyle(
                  color: primary,
                  fontSize: monetClamp(23.2, w * 0.033, 44.8 * ls),
                  fontWeight: FontWeight.w600,
                  height: 1.06,
                  letterSpacing: 0,
                  shadows: <Shadow>[
                    Shadow(
                      offset: const Offset(0, 14),
                      blurRadius: 36,
                      color: pal.background.withValues(alpha: 0.28),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                album.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: align,
                style: TextStyle(
                  color: pal.secondary.withValues(alpha: 0.84),
                  fontSize: 14,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final Widget rail = Opacity(
      opacity: aRail,
      child: Transform.translate(
        offset: Offset(0, 20 * (1 - aRail)),
        child: SizedBox(
          width: railW,
          height: railH,
          child: RepaintBoundary(
            child: CustomPaint(
              painter: MonetRailPainter(
                controller: _rail,
                frame: MonetRailFrame(
                  runtime: v.runtime,
                  timeMs: tick.timeMs,
                  now: tick.elapsed,
                  motion: motion,
                  palette: pal,
                  fontPx: lyricFont,
                  inactiveScale: monetInactiveScale(lyricFont, inactiveFont),
                  translationFontPx: translationFont,
                  alignEnd: mirrored,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final List<Widget> column = <Widget>[
      header,
      const SizedBox(height: 12),
      titleBlock,
      const SizedBox(height: 24),
      Flexible(child: rail),
      if (cfg.descriptionVisibility != 'hidden')
        _capsule(pal, cfg.descriptionVisibility == 'always', aDesc, motion),
    ];

    final Widget textColumn = SizedBox(
      width: textColW,
      height: h,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: padX, vertical: padY),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: cross,
          children: column,
        ),
      ),
    );

    final List<Widget> row = <Widget>[
      textColumn,
      if (showPortrait)
        _portraitColumn(
          v: v,
          cfg: cfg,
          width: w,
          height: h,
          colW: portraitColW,
          innerW: innerW,
          side: side,
          appear: aPortrait,
        ),
    ];

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        RepaintBoundary(
          child: MonetBackground(
            coverPath: v.coverPath,
            palette: pal,
            config: cfg,
            elapsed: tick.elapsed,
            motion: motion,
          ),
        ),
        Center(
          child: SizedBox(
            width: rowW,
            height: h,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: mirrored ? row.reversed.toList() : row,
            ),
          ),
        ),
        if (cfg.showAudio)
          Positioned(
            bottom: 0,
            left: mirrored ? null : 0,
            right: mirrored ? 0 : null,
            width: math.min(450, w * 0.55),
            height: 40,
            child: Opacity(
              opacity: aAudio,
              child: Transform.translate(
                offset: Offset(0, 15 * (1 - aAudio)),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: monetAudioPadX(w)),
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: MonetAudioPainter(
                      color: primary,
                      line: cfg.audioLine,
                      still: !motion,
                      pulse: v.runtime.pulseAt(tick.timeMs),
                      seconds: tick.elapsed,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 描述胶囊：自动隐藏时鼠标移上去才出现，没有鼠标的设备常显（folia `[@media(hover:none)]`）。
  Widget _capsule(
    LyricVisualizerPalette pal,
    bool always,
    double appear,
    bool motion,
  ) {
    final bool hasMouse =
        RendererBinding.instance.mouseTracker.mouseIsConnected;
    final bool visible = always || _capsuleHovered || !hasMouse;
    return Opacity(
      opacity: appear,
      child: Transform.translate(
        offset: Offset(0, 10 * (1 - appear)),
        child: Transform.scale(
          scale: 0.9 + 0.1 * appear,
          child: MouseRegion(
            opaque: false,
            onEnter: (_) => setState(() => _capsuleHovered = true),
            onExit: (_) => setState(() => _capsuleHovered = false),
            child: Padding(
              // folia 的 hover 区比胶囊大一圈（before:-inset-x-6 -bottom-6）。
              padding: const EdgeInsets.only(top: 16, bottom: 8),
              child: AnimatedOpacity(
                opacity: visible ? 1 : 0,
                duration: motion
                    ? const Duration(milliseconds: 200)
                    : Duration.zero,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: pal.text.withValues(alpha: 0.16)),
                    color: pal.background.withValues(alpha: 0.18),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: pal.accent,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          t.music_visualizer_mode_monet.toUpperCase(),
                          style: TextStyle(
                            color: pal.text.withValues(alpha: 0.9),
                            fontSize: 12,
                            letterSpacing: 0,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _portraitColumn({
    required LyricVisualizerContext v,
    required MonetConfig cfg,
    required double width,
    required double height,
    required double colW,
    required double innerW,
    required double side,
    required double appear,
  }) {
    final LyricVisualizerPalette pal = v.palette;
    final bool mirrored = cfg.mirrored;
    final double edge = monetPortraitEdgePad(width);
    final double avail = math.max(0, colW - 12 - edge);
    final double inner = math.min(innerW, avail);
    final Widget image = _MonetPortraitImage(
      path: v.coverPath,
      motion: v.motion,
    );
    Widget frame;
    if (cfg.squarePortrait) {
      final double big = inner * (1 + kMonetSquareBleed);
      frame = SizedBox(
        width: inner,
        height: big,
        child: OverflowBox(
          minWidth: big,
          maxWidth: big,
          minHeight: big,
          maxHeight: big,
          // 正方形朝画面中间外扩，靠屏幕边的一侧与竖长方形对齐。
          alignment: mirrored ? Alignment.centerLeft : Alignment.centerRight,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(32),
              color: pal.text.withValues(alpha: 0.08),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  offset: const Offset(0, 36),
                  blurRadius: 80,
                  color: pal.background.withValues(alpha: 0.45),
                ),
                BoxShadow(
                  offset: const Offset(0, 20),
                  blurRadius: 42,
                  color: pal.accent.withValues(alpha: 0.22),
                ),
                BoxShadow(
                  spreadRadius: 1,
                  color: pal.text.withValues(alpha: 0.06),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(32),
              child: image,
            ),
          ),
        ),
      );
    } else {
      frame = SizedBox(
        width: inner,
        height: inner / 0.74,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(34.4),
            border: Border.all(color: pal.text.withValues(alpha: 0.1)),
            color: pal.background.withValues(alpha: 0.15),
            boxShadow: <BoxShadow>[
              BoxShadow(
                offset: const Offset(0, 24),
                blurRadius: 60,
                color: pal.background.withValues(alpha: 0.35),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(29.6),
              child: ColoredBox(
                color: pal.text.withValues(alpha: 0.08),
                child: image,
              ),
            ),
          ),
        ),
      );
    }
    final Widget moved = Transform.translate(
      offset: Offset(cfg.portraitOffsetX * side, 0),
      child: frame,
    );
    final Widget entering = Opacity(
      opacity: appear,
      child: Transform(
        alignment: Alignment.center,
        transform: Matrix4.translationValues(50 * side * (1 - appear), 0, 0)
          ..rotateZ(side * (1 - appear) * math.pi / 180)
          ..scaleByDouble(0.95 + 0.05 * appear, 0.95 + 0.05 * appear, 1, 1),
        child: moved,
      ),
    );
    return SizedBox(
      width: colW,
      height: height,
      child: Padding(
        padding: EdgeInsets.only(
          left: mirrored ? edge : 12,
          right: mirrored ? 12 : edge,
        ),
        child: Align(
          alignment: width >= 1024
              ? (mirrored ? Alignment.centerLeft : Alignment.centerRight)
              : Alignment.center,
          child: entering,
        ),
      ),
    );
  }
}

/// 封面肖像：新封面先解码好再叠上去交叉淡入（folia `MonetPortraitImage`），框里不留空白。
class _MonetPortraitImage extends StatefulWidget {
  const _MonetPortraitImage({required this.path, required this.motion});

  final String? path;
  final bool motion;

  @override
  State<_MonetPortraitImage> createState() => _MonetPortraitImageState();
}

class _MonetPortraitImageState extends State<_MonetPortraitImage> {
  String? _shown;
  String? _wanted;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _want(widget.path);
  }

  @override
  void didUpdateWidget(covariant _MonetPortraitImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _want(widget.path);
  }

  void _want(String? path) {
    if (path == _wanted) return;
    _wanted = path;
    if (path == null || path.isEmpty || !File(path).existsSync()) {
      // 没封面：保留上一张（folia 淡出但留着），这里直接清掉，框露出底色。
      if (_shown != null) setState(() => _shown = null);
      return;
    }
    unawaited(
      precacheImage(
        FileImage(File(path)),
        context,
        onError: (Object _, StackTrace? _) {},
      ).then((_) {
        if (mounted && _wanted == path) setState(() => _shown = path);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final String? shown = _shown;
    return AnimatedSwitcher(
      duration: widget.motion
          ? const Duration(milliseconds: 900)
          : Duration.zero,
      switchInCurve: Curves.easeInOut,
      switchOutCurve: Curves.easeInOut,
      layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
        fit: StackFit.expand,
        children: <Widget>[...previous, ?current],
      ),
      child: shown == null
          ? const SizedBox.expand(key: ValueKey<String>('monet-empty'))
          : Image(
              key: ValueKey<String>(shown),
              image: FileImage(File(shown)),
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              gaplessPlayback: true,
            ),
    );
  }
}
