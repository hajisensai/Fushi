import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/adaptive/page_backdrop_style.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 页面背景的装饰层：按 [PageBackdropSettings] 画一种预设（形状 / 渐变 / 波浪 /
/// 用户图片）。颜色一律取当前主题的 container 色阶，深浅色与动态取色自动跟随。
///
/// 纯装饰：不参与命中、不进无障碍树。路由层（`LibraryShapeBackdrop`）与设置页的
/// 预设缩略图共用这一个组件，缩略图传 `animate: false`。
class PageBackdropLayer extends StatefulWidget {
  const PageBackdropLayer({
    required this.settings,
    this.animate = true,
    super.key,
  });

  final PageBackdropSettings settings;

  /// false = 不跑「缓慢漂移」（缩略图、测试）。
  final bool animate;

  @override
  State<PageBackdropLayer> createState() => _PageBackdropLayerState();
}

class _PageBackdropLayerState extends State<PageBackdropLayer>
    with TickerProviderStateMixin {
  AnimationController? _controller;

  PageBackdropPreset get _preset => widget.settings.effectivePreset;

  bool get _spins => _preset == PageBackdropPreset.sunny;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  @override
  void didUpdateWidget(PageBackdropLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncMotion();
  }

  /// 开关 / 预设 / 系统减弱动态效果变化时启停（墨水屏与减弱动态效果下
  /// [fushiMotionDuration] 归零，即不动）。
  void _syncMotion() {
    final Duration duration = fushiMotionDuration(
      context,
      _spins ? FushiMotion.ambientSpin : FushiMotion.ambientDrift,
    );
    final bool wants =
        widget.animate &&
        widget.settings.motion &&
        _preset != PageBackdropPreset.plain &&
        duration > Duration.zero;
    if (!wants) {
      _controller?.dispose();
      _controller = null;
      return;
    }
    final AnimationController controller =
        _controller ?? AnimationController(vsync: this);
    _controller = controller;
    if (controller.duration == duration && controller.isAnimating) return;
    controller.duration = duration;
    if (_spins) {
      controller.repeat();
    } else {
      controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_preset == PageBackdropPreset.plain) return const SizedBox.shrink();
    final ColorScheme cs = Theme.of(context).colorScheme;
    final AnimationController? controller = _controller;
    return IgnorePointer(
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: ClipRect(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints c) {
                final Size size = Size(c.maxWidth, c.maxHeight);
                if (controller == null) return _content(cs, size, 0);
                return AnimatedBuilder(
                  animation: controller,
                  builder: (BuildContext context, Widget? _) =>
                      _content(cs, size, controller.value),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// [t] = 动画进度（0..1）；不动时恒 0。
  Widget _content(ColorScheme cs, Size size, double t) {
    if (size.isEmpty || !size.isFinite) return const SizedBox.shrink();
    final _BackdropPalette palette = _BackdropPalette(
      cs,
      widget.settings.strength.factor,
    );
    final Widget content = switch (_preset) {
      PageBackdropPreset.corner => _corner(palette, size),
      PageBackdropPreset.plain => const SizedBox.shrink(),
      PageBackdropPreset.confetti => _confetti(palette, size),
      PageBackdropPreset.mesh => _mesh(palette, size),
      PageBackdropPreset.arc => _arc(palette, size),
      PageBackdropPreset.wave => CustomPaint(
        size: size,
        painter: _WavePainter(palette),
      ),
      PageBackdropPreset.sunny => _sunny(palette, size, t * 2 * math.pi),
      PageBackdropPreset.custom => _image(cs, size),
    };
    if (_spins || t == 0) return content;
    // 漂移：极慢平移 + 轻微放大（放大量盖住平移露出的边）。
    final double e = FushiMotion.ambient.transform(t);
    return Transform.translate(
      offset: Offset(-0.019 * size.width * e, 0.0175 * size.height * e),
      child: Transform.scale(scale: 1.04 + 0.02 * e, child: content),
    );
  }

  Widget _corner(_BackdropPalette p, Size size) {
    final double unit = math.min(size.width, size.height);
    final double big = unit * 0.52;
    final double mid = unit * 0.38;
    final double small = unit * 0.25;
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: <Widget>[
        Positioned(
          right: -big * 0.15,
          top: -big * 0.28,
          width: big,
          height: big,
          child: _blob(
            MaterialShapes.cookie9Sided,
            p.primary,
            p.alpha(0.8, 0.35),
          ),
        ),
        Positioned(
          left: unit * 0.05,
          bottom: -mid * 0.2,
          width: mid,
          height: mid,
          child: _blob(
            MaterialShapes.clover4Leaf,
            p.tertiary,
            p.alpha(0.65, 0.32),
          ),
        ),
        Positioned(
          right: size.width * 0.24,
          bottom: -small * 0.2,
          width: small,
          height: small,
          child: _blob(
            MaterialShapes.cookie6Sided,
            p.secondary,
            p.alpha(0.6, 0.32),
          ),
        ),
      ],
    );
  }

  Widget _confetti(_BackdropPalette p, Size size) {
    final double unit = math.min(size.width, size.height);
    final List<Color> colors = <Color>[p.primary, p.secondary, p.tertiary];
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: <Widget>[
        for (final _ConfettiPiece piece in _confettiPieces)
          Positioned(
            left: piece.x * size.width - piece.size * unit / 2,
            top: piece.y * size.height - piece.size * unit / 2,
            width: piece.size * unit,
            height: piece.size * unit,
            child: Transform.rotate(
              angle: piece.rotation,
              child: _blob(
                piece.shape,
                colors[piece.colorIndex],
                p.alpha(0.85, 0.45),
              ),
            ),
          ),
      ],
    );
  }

  Widget _mesh(_BackdropPalette p, Size size) {
    final double u = math.max(size.width, size.height);
    Widget glow(Offset center, double radius, Color color, double alpha) =>
        Positioned(
          left: center.dx - radius,
          top: center.dy - radius,
          width: radius * 2,
          height: radius * 2,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: <Color>[
                  color.withValues(alpha: alpha),
                  color.withValues(alpha: alpha * 0.45),
                  color.withValues(alpha: 0),
                ],
                stops: const <double>[0, 0.45, 1],
              ),
            ),
          ),
        );
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: <Widget>[
        glow(
          Offset(size.width * 0.88, size.height * 0.08),
          u * 0.42,
          p.primary,
          p.alpha(0.95, 0.55),
        ),
        glow(
          Offset(size.width * 0.08, size.height * 0.92),
          u * 0.36,
          p.tertiary,
          p.alpha(0.9, 0.5),
        ),
        glow(
          Offset(size.width * 0.55, size.height * 1.05),
          u * 0.3,
          p.secondary,
          p.alpha(0.9, 0.5),
        ),
      ],
    );
  }

  Widget _arc(_BackdropPalette p, Size size) {
    final double u = math.min(size.width, size.height);
    final double sunny = u * 0.4;
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: <Widget>[
        Positioned.fill(child: CustomPaint(painter: _ArcPainter(p))),
        Positioned(
          left: u * 0.06 - sunny / 2,
          top: size.height - u * 0.04 - sunny / 2,
          width: sunny,
          height: sunny,
          child: _blob(MaterialShapes.sunny, p.tertiary, p.alpha(0.6, 0.3)),
        ),
      ],
    );
  }

  Widget _sunny(_BackdropPalette p, Size size, double angle) {
    final double u = math.max(size.width, size.height);
    final Offset center = Offset(size.width * 0.86, size.height * 0.92);
    Widget layer(double radius, Color color, double alpha, double phase) =>
        Positioned(
          left: center.dx - radius,
          top: center.dy - radius,
          width: radius * 2,
          height: radius * 2,
          child: Transform.rotate(
            angle: angle + phase,
            child: _blob(MaterialShapes.sunny, color, alpha),
          ),
        );
    return Stack(
      clipBehavior: Clip.hardEdge,
      children: <Widget>[
        layer(u * 0.42, p.primary, p.alpha(0.65, 0.3), 0),
        layer(u * 0.28, p.secondary, p.alpha(0.7, 0.35), 0.2),
      ],
    );
  }

  Widget _image(ColorScheme cs, Size size) {
    final PageBackdropSettings s = widget.settings;
    final String? path = s.imagePathFor(portrait: size.height > size.width);
    if (path == null) return const SizedBox.shrink();
    final double dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    // 只按视口解码（相机原图 8K 不整帧进 ImageCache）；各路由同一张图共用
    // 同一个 provider key，只解一次。
    final int decode = (math.max(size.width, size.height) * dpr).ceil().clamp(
      64,
      4096,
    );
    final ImageProvider provider = ResizeImage(
      FileImage(File(path)),
      width: decode,
      height: decode,
      policy: ResizeImagePolicy.fit,
      allowUpscaling: false,
    );
    Widget image = Image(
      image: provider,
      fit: BoxFit.cover,
      width: size.width,
      height: size.height,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
          const SizedBox.shrink(),
    );
    final double sigma = s.blur.sigma;
    if (sigma > 0) {
      image = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: sigma,
          sigmaY: sigma,
          tileMode: TileMode.clamp,
        ),
        child: image,
      );
    }
    final Color surface = cs.surface;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        image,
        // 遮罩：整页一层页面底色，保证文字对比度；顶部再加一道渐隐，
        // 标题与顶栏压在最亮 / 最花的天空上也读得清。
        ColoredBox(color: surface.withValues(alpha: s.scrim)),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                surface.withValues(alpha: math.min(1, s.scrim + 0.25)),
                surface.withValues(alpha: 0),
              ],
              stops: const <double>[0, 0.22],
            ),
          ),
        ),
      ],
    );
  }
}

Widget _blob(RoundedPolygon shape, Color color, double alpha) => DecoratedBox(
  decoration: ShapeDecoration(
    color: color.withValues(alpha: alpha),
    shape: MaterialShapeBorder(shape: shape),
  ),
);

/// 背景层用到的三种 container 色与不透明度换算（强度系数 × 明 / 暗基准）。
class _BackdropPalette {
  _BackdropPalette(ColorScheme cs, this.factor)
    : primary = cs.primaryContainer,
      secondary = cs.secondaryContainer,
      tertiary = cs.tertiaryContainer,
      dark = cs.brightness == Brightness.dark;

  final Color primary;
  final Color secondary;
  final Color tertiary;
  final bool dark;
  final double factor;

  double alpha(double light, double darkBase) =>
      math.min(1, (dark ? darkBase : light) * factor);

  @override
  bool operator ==(Object other) =>
      other is _BackdropPalette &&
      other.primary == primary &&
      other.secondary == secondary &&
      other.tertiary == tertiary &&
      other.dark == dark &&
      other.factor == factor;

  @override
  int get hashCode => Object.hash(primary, secondary, tertiary, dark, factor);
}

class _ArcPainter extends CustomPainter {
  _ArcPainter(this.p);

  final _BackdropPalette p;

  @override
  void paint(Canvas canvas, Size size) {
    final double u = math.min(size.width, size.height);
    final double r = u * 0.62;
    final Offset center = Offset(size.width, 0);
    canvas.drawCircle(
      center,
      r,
      Paint()..color = p.primary.withValues(alpha: p.alpha(0.75, 0.32)),
    );
    canvas.drawCircle(
      center,
      r * 1.18,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = u * 0.012
        ..color = p.primary.withValues(alpha: p.alpha(0.8, 0.4)),
    );
    canvas.drawCircle(
      center,
      r * 1.32,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = u * 0.006
        ..color = p.secondary.withValues(alpha: p.alpha(0.8, 0.4)),
    );
  }

  @override
  bool shouldRepaint(_ArcPainter oldDelegate) => oldDelegate.p != p;
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.p);

  final _BackdropPalette p;

  @override
  void paint(Canvas canvas, Size size) {
    final double u = math.min(size.width, size.height);
    void band(double base, double amp, double len, double phase, Color color) {
      final Path path = Path()..moveTo(0, size.height);
      for (double x = 0; x <= size.width; x += 6) {
        path.lineTo(x, base + amp * math.sin(x / len * 2 * math.pi + phase));
      }
      path
        ..lineTo(size.width, size.height)
        ..close();
      canvas.drawPath(path, Paint()..color = color);
    }

    band(
      size.height - u * 0.30,
      u * 0.025,
      u * 0.55,
      0,
      p.secondary.withValues(alpha: p.alpha(0.55, 0.3)),
    );
    band(
      size.height - u * 0.20,
      u * 0.03,
      u * 0.42,
      1.6,
      p.primary.withValues(alpha: p.alpha(0.7, 0.35)),
    );
    band(
      size.height - u * 0.10,
      u * 0.022,
      u * 0.33,
      3.1,
      p.tertiary.withValues(alpha: p.alpha(0.7, 0.35)),
    );
  }

  @override
  bool shouldRepaint(_WavePainter oldDelegate) => oldDelegate.p != p;
}

class _ConfettiPiece {
  const _ConfettiPiece({
    required this.x,
    required this.y,
    required this.size,
    required this.rotation,
    required this.shape,
    required this.colorIndex,
  });

  final double x;
  final double y;

  /// 边长（占视口短边的比例）。
  final double size;
  final double rotation;
  final RoundedPolygon shape;
  final int colorIndex;
}

/// 固定种子生成，每次启动、每台设备排布都一样；中间阅读区少放。
final List<_ConfettiPiece> _confettiPieces = () {
  final math.Random rnd = math.Random(7);
  final List<RoundedPolygon> shapes = <RoundedPolygon>[
    MaterialShapes.cookie9Sided,
    MaterialShapes.clover4Leaf,
    MaterialShapes.flower,
    MaterialShapes.pill,
    MaterialShapes.triangle,
    MaterialShapes.cookie6Sided,
    MaterialShapes.sunny,
    MaterialShapes.cookie4Sided,
    MaterialShapes.circle,
  ];
  return <_ConfettiPiece>[
    for (int i = 0; i < 18; i++)
      () {
        double x = rnd.nextDouble();
        final double y = rnd.nextDouble();
        if ((x - 0.5).abs() < 0.22 && (y - 0.5).abs() < 0.22) {
          x += x < 0.5 ? -0.2 : 0.2;
        }
        return _ConfettiPiece(
          x: x,
          y: y,
          size: 0.06 + rnd.nextDouble() * 0.12,
          rotation: rnd.nextDouble() * 2 * math.pi,
          shape: shapes[i % shapes.length],
          colorIndex: i % 3,
        );
      }(),
  ];
}();
