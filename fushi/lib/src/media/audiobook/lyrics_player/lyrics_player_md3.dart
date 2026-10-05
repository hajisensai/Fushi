import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_speed_panel.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_tag.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

// MD3（Material 3 Expressive）歌词播放页。
//
// 宽屏（横屏 / 桌面窗口）：左栏封面卡 + 书名 + 读数 chip + 波浪进度条 + 播放键组，
// 右栏是歌词 WebView（透明底），背后垫一块半透明大圆角底板；右上角关闭。
// 窄屏（手机竖屏）：不放封面（用户原话「显示封面的话手机可能放不下」），顶栏书名
// + 一行读数，中间全屏歌词，底部悬浮控制条。
//
// 配色全部读 Theme.of(context).colorScheme——覆盖层外壳已经用封面动态取色换掉了
// 整棵子树的 ColorScheme，所以这里拿到的就是封面色。
//
// 控件层只在画了东西的地方吃指针：根是不铺满的 Stack + Positioned，空白处让给
// 下面的歌词 WebView。歌词底板因此只能画在背景层里（WebView 在控件层下面）。

/// MD3 extra-large 圆角（28）：封面卡、歌词底板、窄屏控制条同一档。复用令牌
/// 里的 28（底部弹层同档），不另起一个数。
const double _kLargeRadius = FushiRadii.sheetValue;
const BorderRadius _kLargeBorderRadius = BorderRadius.all(
  Radius.circular(_kLargeRadius),
);

/// 窄屏底部控制条的高度（不含外边距）：进度条 36 + 时间约 18 + 间距 8 + 按钮行
/// 64 + 上下内边距各 14，再留几像素给系统字号放大。
const double _kNarrowBarHeight = 160;

/// 窄屏顶栏高度。
const double _kNarrowTopBarHeight = 56;

/// 背景流动一周的时长：几十秒一圈，慢到不抢歌词的注意力。
const Duration _kMeshPeriod = Duration(seconds: 48);

/// mesh 重画间隔（≈30fps）。
const int _kMeshFrameMicros = 33000;

/// 所有 mesh 实例共用的相位时钟（页面与标题栏里的两份背景同相位）。
final Stopwatch _meshClock = Stopwatch()..start();

// ---------------------------------------------------------------------------
// 几何
// ---------------------------------------------------------------------------

/// 宽屏双栏几何。背景（画歌词底板）与 [Md3LyricsPlayerDesign.lyricsRect] /
/// 控件层共用同一份计算，三者才对得齐。
@immutable
class _WideGeometry {
  const _WideGeometry._({
    required this.panel,
    required this.plate,
    required this.lyrics,
  });

  factory _WideGeometry.of(Size size, EdgeInsets padding) {
    final double hPad = (size.width * 0.04).clamp(20.0, 56.0);
    final double left = padding.left + hPad;
    final double right = size.width - padding.right - hPad;
    final double top = padding.top + 20;
    final double bottom = math.max(top + 1, size.height - padding.bottom - 20);
    final double contentWidth = math.max(1, right - left);
    // 左栏比例参考 Niratan playerPanel（宽 32%、夹在 220–430），MD3 的控件更大
    // 一号，取 36% 夹在 260–440。
    final double maxPanel = math.min(440, contentWidth * 0.44);
    final double panelWidth = (contentWidth * 0.36).clamp(
      math.min(260.0, maxPanel),
      maxPanel,
    );
    final double gap = (contentWidth * 0.04).clamp(20.0, 64.0);
    final Rect panel = Rect.fromLTRB(left, top, left + panelWidth, bottom);
    final Rect plate = Rect.fromLTRB(
      math.min(right - 1, panel.right + gap),
      top,
      right,
      bottom,
    );
    // 歌词矩形在底板里内缩：顶部留 64 给右上角关闭键（不让它压在首行上）。
    final Rect lyrics = Rect.fromLTRB(
      plate.left + 8,
      math.min(plate.bottom - 1, plate.top + 64),
      math.max(plate.left + 9, plate.right - 8),
      math.max(plate.top + 65, plate.bottom - 8),
    );
    return _WideGeometry._(panel: panel, plate: plate, lyrics: lyrics);
  }

  final Rect panel;
  final Rect plate;
  final Rect lyrics;
}

/// 窄屏控制条矩形（悬浮卡片：左右下各留 12 外边距）。
Rect _narrowBarRect(Size size, EdgeInsets padding) {
  final double bottom = size.height - padding.bottom - 12;
  return Rect.fromLTRB(
    padding.left + 12,
    math.max(0, bottom - _kNarrowBarHeight),
    math.max(padding.left + 13, size.width - padding.right - 12),
    math.max(1, bottom),
  );
}

// ---------------------------------------------------------------------------
// 外观
// ---------------------------------------------------------------------------

class Md3LyricsPlayerDesign extends LyricsPlayerDesign {
  const Md3LyricsPlayerDesign();

  @override
  Rect lyricsRect(Size size, EdgeInsets padding) {
    if (lyricsPlayerIsWide(size)) {
      return _WideGeometry.of(size, padding).lyrics;
    }
    final double top = padding.top + 8 + _kNarrowTopBarHeight + 8;
    final double bottom = _narrowBarRect(size, padding).top - 8;
    return Rect.fromLTRB(
      padding.left,
      top,
      size.width - padding.right,
      math.max(top + 1, bottom),
    );
  }

  @override
  Widget buildBackground(
    BuildContext context,
    LyricsPlayerData data, {
    double bleedTop = 0,
  }) => _Md3Backdrop(bleedTop: bleedTop);

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
      final _WideGeometry geometry = _WideGeometry.of(size, padding);
      return Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fromRect(
            rect: geometry.panel,
            child: _WidePanel(data: data, callbacks: callbacks),
          ),
          Positioned(
            top: geometry.plate.top + 12,
            right: size.width - geometry.plate.right + 12,
            child: FushiIconButtonControl.filledTonal(
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              onPressed: callbacks.onClose,
              icon: const FushiIcon(Icons.close_rounded),
            ),
          ),
        ],
      );
    }
    final Rect bar = _narrowBarRect(size, padding);
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        Positioned(
          top: padding.top + 8,
          left: padding.left + 16,
          right: padding.right + 8,
          height: _kNarrowTopBarHeight,
          child: _NarrowTopBar(data: data, callbacks: callbacks),
        ),
        Positioned.fromRect(
          rect: bar,
          child: _NarrowControlBar(data: data, callbacks: callbacks),
        ),
      ],
    );
  }

  @override
  LyricsHtmlTheme htmlTheme(BuildContext context, LyricsPlayerData data) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return LyricsHtmlTheme(
      textColor: cs.onSurfaceVariant,
      currentColor: cs.primary,
      accentColor: cs.primaryContainer,
      selectionTextColor: cs.onPrimaryContainer,
      contextOpacities: const <double>[0.62, 0.48, 0.38, 0.3],
      browsingOpacity: 0.7,
      deselectedScale: 0.94,
      anchorY: 0.42,
      edgeFade: 0.06,
      alignStart: true,
      contextBlurPx: 0,
      rowRadius: 16,
      hoverFill: cs.onSurface.withValues(alpha: 0.08),
    );
  }
}

// ---------------------------------------------------------------------------
// 背景：封面动态色的流动 mesh
// ---------------------------------------------------------------------------

/// 不透明背景：surface 底上叠四团缓慢漂移的径向渐变（primary / tertiary /
/// secondary 容器色 + 一团低透明 primary），宽屏再垫歌词底板。动效关闭（减少
/// 动态效果 / 墨水屏）时静止在相位 0。
class _Md3Backdrop extends StatefulWidget {
  const _Md3Backdrop({required this.bleedTop});

  /// 画布顶上延伸到标题栏底下的高度（见 [LyricsPlayerDesign.buildBackground]）。
  final double bleedTop;

  @override
  State<_Md3Backdrop> createState() => _Md3BackdropState();
}

class _Md3BackdropState extends State<_Md3Backdrop>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);

  /// 流动相位（0–1，一周 [_kMeshPeriod]）。只驱动画家重绘，不重建。
  final ValueNotifier<double> _phase = ValueNotifier<double>(0);
  int _lastFrame = -1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool motion = fushiExpressiveMotionEnabled(context);
    if (motion && !_ticker.isActive) {
      _lastFrame = -1;
      _ticker.start();
    } else if (!motion && _ticker.isActive) {
      _ticker.stop();
      _phase.value = 0;
    }
  }

  void _onTick(Duration _) {
    // 漂移极慢，30fps 足够顺；整屏渐变每帧重画是白花 GPU。相位取全局共享时钟
    // 并量化到 33ms 一档（不取本 ticker 的 elapsed）：桌面标题栏里画的是同一张
    // 背景的另一个实例（[LyricsPlayerDesign.buildBackground] 的 bleedTop），两个
    // 实例同一帧必须是同一相位，接缝处才连续。
    final int frame = _meshClock.elapsedMicroseconds ~/ _kMeshFrameMicros;
    if (frame == _lastFrame) return;
    _lastFrame = frame;
    _phase.value =
        (frame * _kMeshFrameMicros / _kMeshPeriod.inMicroseconds) % 1.0;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final EdgeInsets padding = MediaQuery.paddingOf(context);
    final bool dark = cs.brightness == Brightness.dark;
    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final Size size = constraints.biggest;
          // 底板按页面尺寸（画布去掉顶上延伸的一截）算，再整体下移回画布坐标。
          final double bleed = widget.bleedTop;
          final Size page = Size(size.width, math.max(0, size.height - bleed));
          final Rect? plate = lyricsPlayerIsWide(page)
              ? _WideGeometry.of(page, padding).plate.translate(0, bleed)
              : null;
          return CustomPaint(
            size: size,
            isComplex: true,
            painter: _MeshPainter(
              phase: _phase,
              base: cs.surface,
              blobs: <Color>[
                cs.primaryContainer.withValues(alpha: dark ? 0.85 : 0.9),
                cs.tertiaryContainer.withValues(alpha: dark ? 0.75 : 0.8),
                cs.secondaryContainer.withValues(alpha: dark ? 0.7 : 0.75),
                cs.primary.withValues(alpha: dark ? 0.22 : 0.16),
              ],
              plate: plate,
              // 歌词底板：surfaceContainerLow 档（令牌 group）半透明，透出流动
              // 背景又压住对比度。
              plateColor: tokens.surfaces.group.withValues(
                alpha: dark ? 0.5 : 0.55,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _MeshPainter extends CustomPainter {
  _MeshPainter({
    required this.phase,
    required this.base,
    required this.blobs,
    required this.plate,
    required this.plateColor,
  }) : super(repaint: phase);

  final ValueListenable<double> phase;
  final Color base;
  final List<Color> blobs;
  final Rect? plate;
  final Color plateColor;

  // 每团的轨迹：中心 = (0.5 + ax·sin(2π·fx·t + px), 0.5 + ay·cos(2π·fy·t + py))，
  // fx / fy 取整数，一周后回到原点（循环无缝）。半径按对角线比例并缓慢呼吸。
  static const List<
    ({double ax, double ay, int fx, int fy, double px, double py, double r})
  >
  _orbits =
      <
        ({double ax, double ay, int fx, int fy, double px, double py, double r})
      >[
        (ax: 0.32, ay: 0.28, fx: 1, fy: 1, px: 0.0, py: 0.0, r: 0.62),
        (ax: 0.36, ay: 0.3, fx: 1, fy: 2, px: 2.1, py: 1.3, r: 0.55),
        (ax: 0.3, ay: 0.34, fx: 2, fy: 1, px: 4.2, py: 2.9, r: 0.5),
        (ax: 0.4, ay: 0.36, fx: 1, fy: 1, px: 3.3, py: 4.6, r: 0.42),
      ];

  @override
  void paint(Canvas canvas, Size size) {
    final Rect bounds = Offset.zero & size;
    canvas.drawRect(bounds, Paint()..color = base);
    final double t = phase.value * 2 * math.pi;
    final double diag = math.sqrt(
      size.width * size.width + size.height * size.height,
    );
    for (int i = 0; i < blobs.length && i < _orbits.length; i++) {
      final ({
        double ax,
        double ay,
        int fx,
        int fy,
        double px,
        double py,
        double r,
      })
      o = _orbits[i];
      final Offset center = Offset(
        size.width * (0.5 + o.ax * math.sin(o.fx * t + o.px)),
        size.height * (0.5 + o.ay * math.cos(o.fy * t + o.py)),
      );
      final double radius = diag * o.r * (1 + 0.08 * math.sin(t + i));
      final Rect circle = Rect.fromCircle(center: center, radius: radius);
      canvas.drawRect(
        bounds,
        Paint()
          ..shader = RadialGradient(
            colors: <Color>[blobs[i], blobs[i].withValues(alpha: 0)],
          ).createShader(circle),
      );
    }
    final Rect? plate = this.plate;
    if (plate != null && plate.width > 1 && plate.height > 1) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(plate, const Radius.circular(_kLargeRadius)),
        Paint()..color = plateColor,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MeshPainter old) =>
      old.phase != phase ||
      old.base != base ||
      old.plate != plate ||
      old.plateColor != plateColor ||
      !_sameColors(old.blobs, blobs);

  static bool _sameColors(List<Color> a, List<Color> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

// ---------------------------------------------------------------------------
// 宽屏左栏
// ---------------------------------------------------------------------------

class _WidePanel extends StatelessWidget {
  const _WidePanel({required this.data, required this.callbacks});

  final LyricsPlayerData data;
  final LyricsPlayerCallbacks callbacks;

  /// 封面以外的内容大约要的高度（书名 / chip / 进度 / 按钮两行 + 间距）。
  static const double _reservedHeight = 360;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        final double coverSide = math.min(
          width,
          constraints.maxHeight - _reservedHeight - 28,
        );
        // 太矮（横屏手机）就不放封面，免得封面挤成邮票。
        final bool showCover = coverSide >= 120;
        final Widget column = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (showCover) ...<Widget>[
              Center(
                child: _CoverTile(
                  cover: data.cover,
                  side: coverSide,
                  isPlaying: data.isPlaying,
                ),
              ),
              const SizedBox(height: 28),
            ],
            Text(
              data.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleLarge?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            _StatsChips(clock: data.clock),
            const SizedBox(height: 20),
            _WavySeekBar(
              clock: data.clock,
              isPlaying: data.isPlaying,
              onSeek: callbacks.onSeek,
              strokeWidth: 6,
              barHeight: 40,
            ),
            const SizedBox(height: 12),
            Center(
              child: _TransportGroup(
                isPlaying: data.isPlaying,
                callbacks: callbacks,
                playSize: 88,
                sideSize: FushiIconButtonSize.m,
                sideWidth: FushiIconButtonWidth.wide,
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 8,
                children: <Widget>[
                  _SpeedButton(
                    speed: data.speed,
                    onSpeedChanged: callbacks.onSpeedChanged,
                  ),
                  _MaskButton(
                    masked: data.lyricsMasked,
                    onPressed: callbacks.onToggleMask,
                  ),
                  if (callbacks.onTypography != null)
                    _TypographyButton(onTypography: callbacks.onTypography!),
                  FushiIconButtonControl(
                    tooltip: t.reading_statistics,
                    onPressed: callbacks.onOpenStatistics,
                    icon: const FushiIcon(Icons.insights_rounded),
                  ),
                  _MoreButton(onMore: callbacks.onMore),
                ],
              ),
            ),
          ],
        );
        // 极端窗口比例下的兜底：整栏等比缩小而不是溢出。
        return Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: SizedBox(width: width, child: column),
          ),
        );
      },
    );
  }
}

/// 大封面卡：圆角 28、按封面原比例放进 [side]×[side] 的方框。桌面悬停时朝指针
/// 轻微 3D 倾斜并上浮（阴影加深）；播放中略放大、暂停略缩小（弹簧）。
class _CoverTile extends StatefulWidget {
  const _CoverTile({
    required this.cover,
    required this.side,
    required this.isPlaying,
  });

  final ImageProvider? cover;
  final double side;
  final bool isPlaying;

  @override
  State<_CoverTile> createState() => _CoverTileState();
}

class _CoverTileState extends State<_CoverTile> with TickerProviderStateMixin {
  late final FushiSpring _playScale = FushiSpring(
    vsync: this,
    initial: widget.isPlaying ? 1 : 0,
    spring: fushiExpressiveDefaultSpatial,
  );

  /// 指针在卡片上的归一化位置（-1–1）；null = 没悬停。
  Offset? _hover;

  /// 封面宽高比（宽 / 高）；解码前按常见书封 0.72。
  double _aspect = 0.72;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveAspect();
  }

  @override
  void didUpdateWidget(covariant _CoverTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cover != widget.cover) _resolveAspect();
    if (oldWidget.isPlaying != widget.isPlaying) {
      _playScale.animateTo(
        widget.isPlaying ? 1 : 0,
        animate: fushiExpressiveMotionEnabled(context),
      );
    }
  }

  /// 读封面真实尺寸：方形的有声书封面和竖长的书封都按原比例放，不硬裁。
  void _resolveAspect() {
    final ImageProvider? cover = widget.cover;
    final ImageStream? next = cover?.resolve(
      createLocalImageConfiguration(context),
    );
    if (next?.key == _stream?.key && next != null) return;
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
      final double aspect = (w / h).clamp(0.5, 1.5);
      if ((aspect - _aspect).abs() > 0.001) setState(() => _aspect = aspect);
    });
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
    _playScale.dispose();
    super.dispose();
  }

  void _onHover(PointerHoverEvent event) {
    if (!fushiExpressiveMotionEnabled(context)) return;
    final Size? size = context.size;
    if (size == null || size.isEmpty) return;
    setState(() {
      _hover = Offset(
        (event.localPosition.dx / size.width * 2 - 1).clamp(-1.0, 1.0),
        (event.localPosition.dy / size.height * 2 - 1).clamp(-1.0, 1.0),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final double side = widget.side;
    final double w = _aspect >= 1 ? side : side * _aspect;
    final double h = _aspect >= 1 ? side / _aspect : side;
    final ImageProvider? cover = widget.cover;
    final Widget face = ClipRRect(
      borderRadius: _kLargeBorderRadius,
      child: SizedBox(
        width: w,
        height: h,
        child: cover == null
            ? ColoredBox(
                color: FushiDesignTokens.of(context).surfaces.overlay,
                child: Center(
                  child: FushiIcon(
                    Icons.menu_book_rounded,
                    size: math.min(w, h) * 0.32,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              )
            : Image(
                image: cover,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
                gaplessPlayback: true,
              ),
      ),
    );
    final Offset tilt = _hover ?? Offset.zero;
    final double liftTarget = _hover == null ? 0 : 1;
    return MouseRegion(
      onHover: _onHover,
      onExit: (_) => setState(() => _hover = null),
      child: SizedBox(
        width: side,
        height: side,
        child: Center(
          child: TweenAnimationBuilder<Offset>(
            tween: Tween<Offset>(end: tilt),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            builder: (BuildContext context, Offset tiltValue, Widget? _) {
              return TweenAnimationBuilder<double>(
                tween: Tween<double>(end: liftTarget),
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                builder: (BuildContext context, double lift, Widget? _) {
                  return AnimatedBuilder(
                    animation: _playScale.animation,
                    builder: (BuildContext context, Widget? child) {
                      // 播放 1.0、暂停 0.92；悬停再放大 2%。
                      final double scale =
                          0.92 + 0.08 * _playScale.value + 0.02 * lift;
                      // 约 ±3.5°：指针在右边，卡片右侧朝里压（rotateY 正）。
                      final Matrix4 transform = Matrix4.identity()
                        ..setEntry(3, 2, 0.0012)
                        ..translateByDouble(0, -6 * lift, 0, 1)
                        ..rotateX(-tiltValue.dy * 0.06)
                        ..rotateY(tiltValue.dx * 0.06)
                        ..scaleByDouble(scale, scale, 1, 1);
                      return Transform(
                        alignment: Alignment.center,
                        transform: transform,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: _kLargeBorderRadius,
                            boxShadow: <BoxShadow>[
                              BoxShadow(
                                color: cs.shadow.withValues(
                                  alpha: 0.22 + 0.12 * lift,
                                ),
                                blurRadius: 24 + 16 * lift,
                                offset: Offset(0, 12 + 8 * lift),
                              ),
                            ],
                          ),
                          child: child,
                        ),
                      );
                    },
                    child: face,
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

// ---------------------------------------------------------------------------
// 读数
// ---------------------------------------------------------------------------

/// 千分位（读数 chip 用；与统计侧栏同口径的 1,234 写法）。
String _grouped(int n) {
  final String digits = n.abs().toString();
  final StringBuffer out = StringBuffer(n < 0 ? '-' : '');
  for (int i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

/// 全书进度文案：`当前 / 总 · xx.xx%`；未就绪为 null。
String? _progressText(LyricsPlayerStats stats) {
  final int? cur = stats.currentChars;
  final int? total = stats.totalChars;
  final double? percent = stats.percent;
  if (cur == null || total == null || percent == null) return null;
  return '${_grouped(cur)} / ${_grouped(total)} · '
      '${percent.toStringAsFixed(2)}%';
}

String _sessionText(LyricsPlayerStats stats) =>
    formatLyricsPlayerTime(Duration(milliseconds: stats.sessionDurationMs));

String _speedText(LyricsPlayerStats stats) =>
    t.reader_stats_chars_per_hour(n: _grouped(stats.charsPerHour));

/// 每秒读一次 [LyricsPlayerClock.stats]（只读），变了才重建这一小块。
class _StatsBuilder extends StatefulWidget {
  const _StatsBuilder({required this.clock, required this.builder});

  final LyricsPlayerClock clock;
  final Widget Function(BuildContext context, LyricsPlayerStats stats) builder;

  @override
  State<_StatsBuilder> createState() => _StatsBuilderState();
}

class _StatsBuilderState extends State<_StatsBuilder> {
  late LyricsPlayerStats _stats = widget.clock.stats;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  @override
  void didUpdateWidget(covariant _StatsBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.clock, widget.clock)) _stats = widget.clock.stats;
  }

  void _poll() {
    if (!mounted) return;
    final LyricsPlayerStats next = widget.clock.stats;
    if (next != _stats) setState(() => _stats = next);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _stats);
}

/// 宽屏读数：tonal 标签一行（阅读速度 / 全书进度 / 会话时长）。
class _StatsChips extends StatelessWidget {
  const _StatsChips({required this.clock});

  final LyricsPlayerClock clock;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    Widget chip(IconData icon, String text) => FushiTag(
      text: text,
      icon: icon,
      dense: true,
      backgroundColor: cs.secondaryContainer.withValues(alpha: 0.8),
      foregroundColor: cs.onSecondaryContainer,
    );
    return _StatsBuilder(
      clock: clock,
      builder: (BuildContext context, LyricsPlayerStats stats) {
        final String? progress = _progressText(stats);
        return Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            chip(Icons.speed_rounded, _speedText(stats)),
            if (progress != null) chip(Icons.menu_book_rounded, progress),
            chip(
              stats.tracking ? Icons.timer_outlined : Icons.timer_off_outlined,
              _sessionText(stats),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 波浪进度条
// ---------------------------------------------------------------------------

/// M3 Expressive 波浪进度条（可拖动）。共享的 FushiWavyLinearProgress 不能变平、
/// 没有 thumb，这里自绘：已播段是正弦波（播放中流动，暂停时振幅弹簧收到 0 变直
/// 线），未播段是平直轨道 + 尾端停止点，中间一根竖条 thumb（拖动时变粗变高），
/// 拖动时 thumb 上方冒时长气泡，松手才 [onSeek]。下方左右两端是已播 / -剩余。
///
/// 播放中用 Ticker 每帧读 [LyricsPlayerClock.position]，只重建这一小块；暂停时
/// 降到每 400ms 轮询一次（还要跟上外部跳转）。←/→ 键前后跳 5 秒。
class _WavySeekBar extends StatefulWidget {
  const _WavySeekBar({
    required this.clock,
    required this.isPlaying,
    required this.onSeek,
    required this.strokeWidth,
    required this.barHeight,
  });

  final LyricsPlayerClock clock;
  final bool isPlaying;
  final ValueChanged<Duration> onSeek;
  final double strokeWidth;
  final double barHeight;

  @override
  State<_WavySeekBar> createState() => _WavySeekBarState();
}

class _WavySeekBarState extends State<_WavySeekBar>
    with TickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  late final FushiSpring _amp = FushiSpring(
    vsync: this,
    spring: fushiExpressiveDefaultSpatial,
  );
  late final FushiSpring _drag = FushiSpring(vsync: this);
  final FocusNode _focusNode = FocusNode(debugLabel: 'lyrics-md3-seek');
  Timer? _idlePoll;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _phase = 0;

  /// 拖动中的比例（null = 没在拖）。
  double? _dragFraction;

  /// 刚松手 / 按键跳转的目标：播放器回报位置追上来之前先显示它，免得 thumb
  /// 弹回旧位置再跳过去。
  Duration? _pendingSeek;
  DateTime _pendingAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _position = widget.clock.position;
    _duration = widget.clock.duration;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion(animate: false);
  }

  @override
  void didUpdateWidget(covariant _WavySeekBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying) _syncMotion(animate: true);
  }

  bool get _motion => fushiExpressiveMotionEnabled(context);

  /// 播放态 → 振幅目标 + 刷新节奏。波浪只在「播放中且允许动效」时有。
  void _syncMotion({required bool animate}) {
    final bool wave = widget.isPlaying && _motion;
    _amp.animateTo(wave ? 1 : 0, animate: animate && _motion);
    if (widget.isPlaying || _amp.value > 0.001) {
      _idlePoll?.cancel();
      _idlePoll = null;
      if (!_ticker.isActive) _ticker.start();
    } else {
      _startIdlePoll();
    }
  }

  void _startIdlePoll() {
    _idlePoll ??= Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (!mounted) return;
      if (_readClock()) setState(() {});
    });
  }

  /// 读一次时钟；有变化返回 true。
  bool _readClock() {
    final Duration p = widget.clock.position;
    final Duration d = widget.clock.duration;
    final Duration? pending = _pendingSeek;
    if (pending != null) {
      final bool caughtUp = (p - pending).abs() < const Duration(seconds: 2);
      final bool stale =
          DateTime.now().difference(_pendingAt) > const Duration(seconds: 1);
      if (caughtUp || stale) _pendingSeek = null;
    }
    final bool changed = p != _position || d != _duration;
    _position = p;
    _duration = d;
    return changed;
  }

  void _onTick(Duration elapsed) {
    // 一个波长约 2.4 秒流过（慢而可感）。
    _phase = elapsed.inMicroseconds / 1e6 * (2 * math.pi / 2.4);
    _readClock();
    setState(() {});
    if (!widget.isPlaying && _amp.value <= 0.001 && _dragFraction == null) {
      _ticker.stop();
      _startIdlePoll();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _idlePoll?.cancel();
    _amp.dispose();
    _drag.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  double get _shownFraction {
    final double? drag = _dragFraction;
    if (drag != null) return drag;
    final int total = _duration.inMilliseconds;
    if (total <= 0) return 0;
    final Duration pos = _pendingSeek ?? _position;
    return (pos.inMilliseconds / total).clamp(0.0, 1.0);
  }

  Duration get _shownPosition {
    final double? drag = _dragFraction;
    if (drag != null) return _duration * drag;
    return _pendingSeek ?? _position;
  }

  double _fractionAt(double dx, double width) {
    if (width <= 0) return 0;
    final bool rtl = Directionality.of(context) == TextDirection.rtl;
    final double f = (dx / width).clamp(0.0, 1.0);
    return rtl ? 1 - f : f;
  }

  void _beginDrag(double fraction) {
    if (_duration <= Duration.zero) return;
    setState(() => _dragFraction = fraction);
    _drag.animateTo(1, animate: _motion);
    if (!_ticker.isActive) {
      _idlePoll?.cancel();
      _idlePoll = null;
      _ticker.start();
    }
  }

  void _endDrag({required bool commit}) {
    final double? fraction = _dragFraction;
    if (fraction == null) return;
    _drag.animateTo(0, animate: _motion);
    setState(() {
      _dragFraction = null;
      if (commit) {
        final Duration target = _duration * fraction;
        _pendingSeek = target;
        _pendingAt = DateTime.now();
        widget.onSeek(target);
      }
    });
  }

  void _seekBy(Duration delta) {
    if (_duration <= Duration.zero) return;
    final Duration base = _pendingSeek ?? _position;
    Duration target = base + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (target > _duration) target = _duration;
    setState(() {
      _pendingSeek = target;
      _pendingAt = DateTime.now();
    });
    widget.onSeek(target);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final bool rtl = Directionality.of(context) == TextDirection.rtl;
    const Duration step = Duration(seconds: 5);
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _seekBy(rtl ? -step : step);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _seekBy(rtl ? step : -step);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final double fraction = _shownFraction;
    final Duration shown = _shownPosition;
    final Duration remaining = _duration > shown
        ? _duration - shown
        : Duration.zero;
    final TextStyle? timeStyle = theme.textTheme.labelMedium?.copyWith(
      color: cs.onSurfaceVariant,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    final bool rtl = Directionality.of(context) == TextDirection.rtl;
    final Widget bar = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        final double half = widget.strokeWidth / 2;
        final double usable = math.max(0, width - widget.strokeWidth);
        final double thumbX = rtl
            ? width - half - usable * fraction
            : half + usable * fraction;
        final double drag = _drag.value.clamp(0.0, 1.2);
        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (TapDownDetails d) =>
                  _beginDrag(_fractionAt(d.localPosition.dx, width)),
              onTapUp: (_) => _endDrag(commit: true),
              onTapCancel: () => _endDrag(commit: false),
              onHorizontalDragStart: (DragStartDetails d) =>
                  _beginDrag(_fractionAt(d.localPosition.dx, width)),
              onHorizontalDragUpdate: (DragUpdateDetails d) {
                if (_dragFraction == null) return;
                setState(
                  () => _dragFraction = _fractionAt(d.localPosition.dx, width),
                );
              },
              onHorizontalDragEnd: (_) => _endDrag(commit: true),
              onHorizontalDragCancel: () => _endDrag(commit: false),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: CustomPaint(
                  size: Size(width, widget.barHeight),
                  painter: _SeekPainter(
                    fraction: fraction,
                    phase: _phase,
                    amplitude: 4 * _amp.value.clamp(0.0, 1.2),
                    strokeWidth: widget.strokeWidth,
                    activeColor: cs.primary,
                    trackColor: cs.secondaryContainer,
                    thumbWidth: 4 + 2 * drag,
                    thumbHeight: widget.barHeight * (0.6 + 0.25 * drag),
                    focused: _focused,
                    rtl: rtl,
                  ),
                ),
              ),
            ),
            // 拖动时的时长气泡（M3 slider value indicator：inverseSurface 胶囊）。
            Positioned(
              left: thumbX - 40,
              bottom: widget.barHeight - 2,
              width: 80,
              child: IgnorePointer(
                child: Center(
                  child: AnimatedOpacity(
                    opacity: _dragFraction == null ? 0 : 1,
                    duration: const Duration(milliseconds: 120),
                    child: AnimatedScale(
                      scale: _dragFraction == null ? 0.6 : 1,
                      alignment: Alignment.bottomCenter,
                      duration: const Duration(milliseconds: 180),
                      curve: Curves.easeOutBack,
                      child: DecoratedBox(
                        decoration: ShapeDecoration(
                          color: cs.inverseSurface,
                          shape: const StadiumBorder(),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          child: Text(
                            formatLyricsPlayerTime(shown),
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: cs.onInverseSurface,
                              fontFeatures: const <FontFeature>[
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    return Semantics(
      slider: true,
      value: formatLyricsPlayerTime(shown),
      child: Focus(
        focusNode: _focusNode,
        onKeyEvent: _onKey,
        onFocusChange: (bool focused) => setState(() => _focused = focused),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(height: widget.barHeight, child: bar),
            Row(
              children: <Widget>[
                Text(formatLyricsPlayerTime(shown), style: timeStyle),
                const Spacer(),
                Text('-${formatLyricsPlayerTime(remaining)}', style: timeStyle),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SeekPainter extends CustomPainter {
  _SeekPainter({
    required this.fraction,
    required this.phase,
    required this.amplitude,
    required this.strokeWidth,
    required this.activeColor,
    required this.trackColor,
    required this.thumbWidth,
    required this.thumbHeight,
    required this.focused,
    required this.rtl,
  });

  final double fraction;
  final double phase;
  final double amplitude;
  final double strokeWidth;
  final Color activeColor;
  final Color trackColor;
  final double thumbWidth;
  final double thumbHeight;
  final bool focused;
  final bool rtl;

  static const double _wavelength = 40;

  /// thumb 与两侧轨道之间的缝（M3 Expressive slider 的 track gap）。
  static const double _gap = 6;

  @override
  void paint(Canvas canvas, Size size) {
    if (rtl) {
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }
    final double cy = size.height / 2;
    final double half = strokeWidth / 2;
    final double left = half;
    final double right = size.width - half;
    final double usable = right - left;
    if (usable <= 0) return;
    final double x = left + usable * fraction.clamp(0.0, 1.0);
    final double gap = _gap + thumbWidth / 2;
    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    // 已播段：两端各用半个波长把振幅从 0 拉起，接 thumb 与起点都是平的。
    final double activeEnd = x - gap;
    if (activeEnd > left) {
      final Path wave = Path()..moveTo(left, cy);
      const double ramp = _wavelength / 2;
      for (double xx = left; xx <= activeEnd; xx += 1.5) {
        final double taper = math.min(
          ((xx - left) / ramp).clamp(0.0, 1.0),
          ((activeEnd - xx) / ramp).clamp(0.0, 1.0),
        );
        final double y =
            cy +
            amplitude *
                taper *
                math.sin((xx - left) / _wavelength * 2 * math.pi - phase);
        wave.lineTo(xx, y);
      }
      wave.lineTo(activeEnd, cy);
      canvas.drawPath(wave, stroke..color = activeColor);
    }

    // 未播段：平直轨道 + 尾端停止点。
    final double inactiveStart = x + gap;
    if (inactiveStart < right) {
      canvas.drawLine(
        Offset(inactiveStart, cy),
        Offset(right, cy),
        stroke..color = trackColor,
      );
      if (right - inactiveStart > strokeWidth * 2) {
        canvas.drawCircle(
          Offset(right, cy),
          half * 0.5,
          Paint()..color = activeColor,
        );
      }
    }

    // thumb：竖向胶囊；有键盘焦点时外圈一层淡主色光晕。
    final Rect thumb = Rect.fromCenter(
      center: Offset(x, cy),
      width: thumbWidth,
      height: math.min(size.height, thumbHeight),
    );
    if (focused) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          thumb.inflate(5),
          Radius.circular(thumbWidth / 2 + 5),
        ),
        Paint()..color = activeColor.withValues(alpha: 0.24),
      );
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(thumb, Radius.circular(thumbWidth / 2)),
      Paint()..color = activeColor,
    );
  }

  @override
  bool shouldRepaint(covariant _SeekPainter old) =>
      old.fraction != fraction ||
      old.phase != phase ||
      old.amplitude != amplitude ||
      old.strokeWidth != strokeWidth ||
      old.activeColor != activeColor ||
      old.trackColor != trackColor ||
      old.thumbWidth != thumbWidth ||
      old.thumbHeight != thumbHeight ||
      old.focused != focused ||
      old.rtl != rtl;
}

// ---------------------------------------------------------------------------
// 播放键组
// ---------------------------------------------------------------------------

/// 上一句 / 播放 / 下一句：M3 Expressive 标准按钮组（按下的变宽、邻居让出）。
class _TransportGroup extends StatelessWidget {
  const _TransportGroup({
    required this.isPlaying,
    required this.callbacks,
    required this.playSize,
    required this.sideSize,
    required this.sideWidth,
  });

  final bool isPlaying;
  final LyricsPlayerCallbacks callbacks;
  final double playSize;
  final FushiIconButtonSize sideSize;
  final FushiIconButtonWidth sideWidth;

  @override
  Widget build(BuildContext context) {
    return FushiButtonGroup(
      spacing: 8,
      children: <Widget>[
        FushiIconButtonControl.filledTonal(
          size: sideSize,
          width: sideWidth,
          tooltip: t.prev_sentence,
          onPressed: callbacks.onPreviousCue,
          icon: const FushiIcon(Icons.skip_previous_rounded),
        ),
        _ExpressivePlayButton(
          isPlaying: isPlaying,
          size: playSize,
          onPressed: callbacks.onPlayPause,
        ),
        FushiIconButtonControl.filledTonal(
          size: sideSize,
          width: sideWidth,
          tooltip: t.next_sentence,
          onPressed: callbacks.onNextCue,
          icon: const FushiIcon(Icons.skip_next_rounded),
        ),
      ],
    );
  }
}

/// 大号 Expressive 播放键：播放中是圆、暂停时是圆角方（圆角 = 边长 30%），两态
/// 之间按 default spatial 弹簧形变；按下整体缩 6%（fast spatial）。图标交叉缩放 +
/// 轻旋转切换。外形是显式 shape，所以 FushiFilledButton 自己的按压变形让位。
class _ExpressivePlayButton extends StatefulWidget {
  const _ExpressivePlayButton({
    required this.isPlaying,
    required this.size,
    required this.onPressed,
  });

  final bool isPlaying;
  final double size;
  final VoidCallback onPressed;

  @override
  State<_ExpressivePlayButton> createState() => _ExpressivePlayButtonState();
}

class _ExpressivePlayButtonState extends State<_ExpressivePlayButton>
    with TickerProviderStateMixin {
  late final FushiSpring _shape = FushiSpring(
    vsync: this,
    initial: widget.isPlaying ? 1 : 0,
    spring: fushiExpressiveDefaultSpatial,
  );
  late final FushiSpring _press = FushiSpring(vsync: this);

  @override
  void didUpdateWidget(covariant _ExpressivePlayButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying) {
      _shape.animateTo(
        widget.isPlaying ? 1 : 0,
        animate: fushiExpressiveMotionEnabled(context),
      );
    }
  }

  @override
  void dispose() {
    _shape.dispose();
    _press.dispose();
    super.dispose();
  }

  void _setPressed(bool pressed) {
    if (!fushiExpressiveMotionEnabled(context)) return;
    _press.animateTo(pressed ? 1 : 0, animate: true);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final double size = widget.size;
    final bool motion = fushiExpressiveMotionEnabled(context);
    final Widget icon = AnimatedSwitcher(
      duration: Duration(milliseconds: motion ? 220 : 0),
      switchInCurve: Curves.easeOutBack,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (Widget child, Animation<double> animation) =>
          RotationTransition(
            turns: Tween<double>(begin: -0.08, end: 0).animate(animation),
            child: ScaleTransition(scale: animation, child: child),
          ),
      child: FushiIcon(
        widget.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
        key: ValueKey<bool>(widget.isPlaying),
        size: size * 0.46,
      ),
    );
    return Tooltip(
      message: widget.isPlaying ? t.pause : t.play,
      child: Listener(
        onPointerDown: (_) => _setPressed(true),
        onPointerUp: (_) => _setPressed(false),
        onPointerCancel: (_) => _setPressed(false),
        child: AnimatedBuilder(
          animation: Listenable.merge(<Listenable>[
            _shape.animation,
            _press.animation,
          ]),
          builder: (BuildContext context, Widget? child) {
            final double pill = _shape.value;
            return Transform.scale(
              scale: 1 - 0.06 * _press.value,
              child: FushiFilledButton(
                onPressed: widget.onPressed,
                style: ButtonStyle(
                  fixedSize: WidgetStatePropertyAll<Size>(Size.square(size)),
                  minimumSize: WidgetStatePropertyAll<Size>(Size.square(size)),
                  padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
                    EdgeInsets.zero,
                  ),
                  backgroundColor: WidgetStatePropertyAll<Color>(cs.primary),
                  foregroundColor: WidgetStatePropertyAll<Color>(cs.onPrimary),
                  elevation: const WidgetStatePropertyAll<double>(0),
                  animationDuration: Duration.zero,
                  shape: WidgetStatePropertyAll<OutlinedBorder>(
                    FushiMorphBorder(
                      radius: size * 0.3,
                      startPill: pill,
                      endPill: pill,
                    ),
                  ),
                ),
                child: child!,
              ),
            );
          },
          child: icon,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 次要操作
// ---------------------------------------------------------------------------

/// tonal 倍速键：显示当前倍速，点开含拖动条的倍速面板（与普通阅读模式快捷
/// 设置同一条 `AudiobookSpeedSlider`），拖动实时生效。
class _SpeedButton extends StatelessWidget {
  const _SpeedButton({required this.speed, required this.onSpeedChanged});

  final double speed;
  final ValueChanged<double> onSpeedChanged;

  @override
  Widget build(BuildContext context) {
    final TextStyle? style = Theme.of(context).textTheme.labelLarge?.copyWith(
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    return Tooltip(
      message: t.playback_speed,
      child: Builder(
        builder: (BuildContext anchor) => FushiPressScale(
          child: FushiFilledButton.tonal(
            onPressed: () => showLyricsSpeedPanel(
              anchorContext: anchor,
              speed: speed,
              onChanged: onSpeedChanged,
            ),
            child: Text(formatLyricsSpeed(speed), style: style),
          ),
        ),
      ),
    );
  }
}

/// 遮罩（听力沉浸模糊）切换：toggle 图标键，开着时是选中态。
class _MaskButton extends StatelessWidget {
  const _MaskButton({required this.masked, required this.onPressed});

  final bool masked;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FushiIconButtonControl.filledTonal(
      tooltip: t.lyrics_blur,
      isSelected: masked,
      onPressed: onPressed,
      icon: const FushiIcon(Icons.visibility_rounded),
      selectedIcon: const FushiIcon(Icons.visibility_off_rounded),
    );
  }
}

/// ⋯ 更多：把按钮的全局矩形与 context 交给页面锚定菜单（菜单从它取主题）。
/// Aa：歌词文字快捷面板（字号 / 竖排 / 更多歌词设置）。
class _TypographyButton extends StatelessWidget {
  const _TypographyButton({required this.onTypography});

  final ValueChanged<LyricsMenuAnchor> onTypography;

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (BuildContext anchor) => FushiIconButtonControl(
        key: const ValueKey<String>('lyrics_typography_button'),
        tooltip: t.lyrics_typography_title,
        onPressed: () {
          final RenderObject? box = anchor.findRenderObject();
          if (box is! RenderBox || !box.hasSize) return;
          onTypography(
            LyricsMenuAnchor(
              rect: box.localToGlobal(Offset.zero) & box.size,
              context: anchor,
            ),
          );
        },
        icon: const FushiIcon(Icons.text_fields_rounded),
      ),
    );
  }
}

class _MoreButton extends StatelessWidget {
  const _MoreButton({required this.onMore});

  final ValueChanged<LyricsMenuAnchor> onMore;

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (BuildContext anchor) => FushiIconButtonControl(
        tooltip: MaterialLocalizations.of(context).moreButtonTooltip,
        onPressed: () {
          final RenderObject? box = anchor.findRenderObject();
          if (box is! RenderBox || !box.hasSize) return;
          onMore(
            LyricsMenuAnchor(
              rect: box.localToGlobal(Offset.zero) & box.size,
              context: anchor,
            ),
          );
        },
        icon: const FushiIcon(Icons.more_horiz_rounded),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 窄屏
// ---------------------------------------------------------------------------

/// 窄屏顶栏：书名 + 一行读数小字；右侧遮罩 / 统计 / 关闭。
class _NarrowTopBar extends StatelessWidget {
  const _NarrowTopBar({required this.data, required this.callbacks});

  final LyricsPlayerData data;
  final LyricsPlayerCallbacks callbacks;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                data.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: cs.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
              _StatsBuilder(
                clock: data.clock,
                builder: (BuildContext context, LyricsPlayerStats stats) {
                  final String? progress = _progressText(stats);
                  return Text(
                    <String>[
                      _speedText(stats),
                      if (progress != null) progress,
                      _sessionText(stats),
                    ].join('  ·  '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        _MaskButton(
          masked: data.lyricsMasked,
          onPressed: callbacks.onToggleMask,
        ),
        if (callbacks.onTypography != null)
          _TypographyButton(onTypography: callbacks.onTypography!),
        FushiIconButtonControl(
          tooltip: t.reading_statistics,
          onPressed: callbacks.onOpenStatistics,
          icon: const FushiIcon(Icons.insights_rounded),
        ),
        FushiIconButtonControl(
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          onPressed: callbacks.onClose,
          icon: const FushiIcon(Icons.close_rounded),
        ),
      ],
    );
  }
}

/// 窄屏底部悬浮控制条：surfaceContainer 圆角 28 卡片，波浪进度 + 时间，下面一行
/// 倍速 / 上一句·播放·下一句 / 更多。
class _NarrowControlBar extends StatelessWidget {
  const _NarrowControlBar({required this.data, required this.callbacks});

  final LyricsPlayerData data;
  final LyricsPlayerCallbacks callbacks;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainer,
      shape: const RoundedRectangleBorder(borderRadius: _kLargeBorderRadius),
      elevation: 3,
      shadowColor: cs.shadow.withValues(alpha: 0.4),
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.none,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _WavySeekBar(
              clock: data.clock,
              isPlaying: data.isPlaying,
              onSeek: callbacks.onSeek,
              strokeWidth: 5,
              barHeight: 36,
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 64,
              // 极窄宽度（< 320）下整行等比缩小，不溢出。
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 12,
                  children: <Widget>[
                    _SpeedButton(
                      speed: data.speed,
                      onSpeedChanged: callbacks.onSpeedChanged,
                    ),
                    _TransportGroup(
                      isPlaying: data.isPlaying,
                      callbacks: callbacks,
                      playSize: 64,
                      sideSize: FushiIconButtonSize.m,
                      sideWidth: FushiIconButtonWidth.narrow,
                    ),
                    _MoreButton(onMore: callbacks.onMore),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
