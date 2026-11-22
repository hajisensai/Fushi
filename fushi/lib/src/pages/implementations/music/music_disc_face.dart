import 'dart:io';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/music_disc_art.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// 一张真盘面（专辑目录里的盘面扫描图，[MusicDiscArtIndex] 认出的本地文件），
/// 曲库唱片色块、播放页转盘、CD 详情页共用。
///
/// 扫描图不直接按内切圆裁（用户 2026-11-22：「没有对准」「外面还是白色的中间」）：
/// 先量出扫描图里光盘的真实位置（[MusicDiscFaceGeometryCache]），再
/// - 把**印刷区**圆心对到组件中心、印刷区外缘对到组件边缘——转起来不晃，透明
///   塑料边扫出来的那圈白不画；
/// - 印刷区内缘以内（透明轮毂与轴孔）挖空，透出底下（封面 / 背景），只叠一层
///   极淡的白和两道细环读作透明塑料；投影也在轮毂处裁掉，孔里不是一团阴影；
/// - 外缘一道细亮边，浅色盘面在浅色背景上也有轮廓。
///
/// 几何没量好之前整张透明，量好后淡入（同一张图量一次、进程内缓存，之后不再闪）。
/// [turns] 给了就整张盘面绕印刷区圆心转（投影不转）。组件取约束里的短边作盘径、
/// 在约束里居中。
class MusicDiscFace extends StatefulWidget {
  const MusicDiscFace({
    required this.path,
    this.shadows = const <BoxShadow>[],
    this.turns,
    super.key,
  });

  final String path;
  final List<BoxShadow> shadows;
  final Animation<double>? turns;

  @override
  State<MusicDiscFace> createState() => _MusicDiscFaceState();
}

class _MusicDiscFaceState extends State<MusicDiscFace> {
  MusicDiscFaceGeometry? _geometry;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(MusicDiscFace old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) _load();
  }

  void _load() {
    final String path = widget.path;
    final MusicDiscFaceGeometryCache cache =
        MusicDiscFaceGeometryCache.instance;
    _geometry = cache.peek(path);
    if (_geometry != null) return;
    cache.load(path).then((MusicDiscFaceGeometry g) {
      if (!mounted || widget.path != path) return;
      setState(() => _geometry = g);
    });
  }

  @override
  Widget build(BuildContext context) {
    final MusicDiscFaceGeometry geometry =
        _geometry ?? MusicDiscFaceGeometry.fallback;
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double side = math.min(c.maxWidth, c.maxHeight);
        if (!side.isFinite || side <= 0) return const SizedBox.shrink();
        Widget print = _DiscPrint(
          path: widget.path,
          geometry: geometry,
          side: side,
          devicePixelRatio: dpr,
        );
        final Animation<double>? turns = widget.turns;
        if (turns != null) {
          print = RotationTransition(turns: turns, child: print);
        }
        return Center(
          child: SizedBox.square(
            dimension: side,
            child: AnimatedOpacity(
              opacity: _geometry == null ? 0 : 1,
              duration: fushiMotionDuration(context, FushiMotion.short),
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  if (widget.shadows.isNotEmpty)
                    ClipPath(
                      clipper: MusicDiscHubClipper(
                        hubFraction: geometry.hubFraction,
                      ),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: widget.shadows,
                        ),
                      ),
                    ),
                  print,
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 印刷区（圆环：轮毂外缘到印刷区外缘）+ 透明部分的细节。
class _DiscPrint extends StatelessWidget {
  const _DiscPrint({
    required this.path,
    required this.geometry,
    required this.side,
    required this.devicePixelRatio,
  });

  final String path;
  final MusicDiscFaceGeometry geometry;
  final double side;
  final double devicePixelRatio;

  @override
  Widget build(BuildContext context) {
    // 原图缩放到「印刷区半径 = 组件半径」，印刷区圆心对到组件中心。
    final double width = side / 2 / geometry.radiusX;
    final double height = side / 2 / geometry.radiusY;
    final int decodeWidth = (width * devicePixelRatio).round().clamp(64, 4096);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        ClipPath(
          clipper: _DiscPrintClipper(hubFraction: geometry.hubFraction),
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              Positioned(
                left: side / 2 - geometry.centerX * width,
                top: side / 2 - geometry.centerY * height,
                width: width,
                height: height,
                child: Image(
                  image: ResizeImage.resizeIfNeeded(
                    decodeWidth,
                    null,
                    FileImage(File(path)),
                  ),
                  fit: BoxFit.fill,
                  excludeFromSemantics: true,
                  // 扫描图损坏 / 被删时只剩透明部分与投影，不让解码失败冒成
                  // FlutterError（BUG-2496）。
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            ],
          ),
        ),
        CustomPaint(
          painter: _DiscClearPartsPainter(hubFraction: geometry.hubFraction),
        ),
      ],
    );
  }
}

/// 印刷区圆环的裁切：外圆减轮毂圆。
class _DiscPrintClipper extends CustomClipper<Path> {
  const _DiscPrintClipper({required this.hubFraction});

  final double hubFraction;

  @override
  Path getClip(Size size) {
    final Offset c = size.center(Offset.zero);
    final double r = size.shortestSide / 2;
    return Path()
      ..fillType = PathFillType.evenOdd
      ..addOval(Rect.fromCircle(center: c, radius: r))
      ..addOval(Rect.fromCircle(center: c, radius: r * hubFraction));
  }

  @override
  bool shouldReclip(covariant _DiscPrintClipper oldClipper) =>
      oldClipper.hubFraction != hubFraction;
}

/// 盘面投影的裁切：组件外扩一圈（留给投影）减去轮毂圆，所以轮毂里连投影一起
/// 裁掉，盘外的投影照常画出来。
class MusicDiscHubClipper extends CustomClipper<Path> {
  const MusicDiscHubClipper({required this.hubFraction});

  /// 轮毂半径 / 盘面半径。
  final double hubFraction;

  @override
  Path getClip(Size size) {
    final double side = size.shortestSide;
    return Path()
      ..fillType = PathFillType.evenOdd
      ..addRect((Offset.zero & size).inflate(side * 0.5))
      ..addOval(
        Rect.fromCircle(
          center: size.center(Offset.zero),
          radius: side / 2 * hubFraction,
        ),
      );
  }

  @override
  bool shouldReclip(covariant MusicDiscHubClipper oldClipper) =>
      oldClipper.hubFraction != hubFraction;
}

/// 透明塑料部分：轮毂（轴孔到印刷区内缘）一层极淡的白、轴孔边与夹持环两道细
/// 亮环；外缘一道细亮边。
class _DiscClearPartsPainter extends CustomPainter {
  const _DiscClearPartsPainter({required this.hubFraction});

  final double hubFraction;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = size.center(Offset.zero);
    final double r = size.shortestSide / 2;
    final double hub = r * hubFraction;
    final double spindle = r * kMusicDiscSpindleFraction;
    final double line = math.max(1, r * 0.008);
    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addOval(Rect.fromCircle(center: c, radius: hub))
        ..addOval(Rect.fromCircle(center: c, radius: spindle)),
      Paint()..color = Colors.white.withValues(alpha: 0.12),
    );
    Paint ring(double alpha, double width) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..color = Colors.white.withValues(alpha: alpha);
    canvas
      ..drawCircle(c, spindle + line / 2, ring(0.45, line))
      ..drawCircle(c, spindle + (hub - spindle) * 0.55, ring(0.2, line))
      ..drawCircle(c, hub, ring(0.3, line))
      ..drawCircle(c, r - line / 2, ring(0.3, line));
  }

  @override
  bool shouldRepaint(covariant _DiscClearPartsPainter oldDelegate) =>
      oldDelegate.hubFraction != hubFraction;
}
