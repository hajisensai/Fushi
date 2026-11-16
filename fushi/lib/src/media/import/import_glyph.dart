/// 导入面色块的共用装饰：多边形 glyph 与拖放 / 添加来源的虚线框（导入稿 v2）。
///
/// 只放不带文案的部件：导入对话框外框（[ImportDialogFrame]）与来源块也用它们。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:fushi/src/utils/components/fushi_generated_cover.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

/// glyph 的形状：MD3 按 [seed] 哈希挑一个 M3E 多边形（同 seed 恒同形）；Apple
/// 是圆角方块（与发现页来源块同一套语言）。
ShapeBorder importGlyphShape(
  BuildContext context,
  String seed,
  double size, {
  BorderSide side = BorderSide.none,
}) {
  if (isGlassDesign(context)) {
    return RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(size * 0.3),
      side: side,
    );
  }
  return MaterialShapeBorder(
    side: side,
    shape: switch (fushiTitleHash(seed) % 8) {
      0 => MaterialShapes.cookie4Sided,
      1 => MaterialShapes.cookie6Sided,
      2 => MaterialShapes.cookie9Sided,
      3 => MaterialShapes.clover4Leaf,
      4 => MaterialShapes.pentagon,
      5 => MaterialShapes.sunny,
      6 => MaterialShapes.gem,
      _ => MaterialShapes.softBurst,
    },
  );
}

/// 块内的多边形 glyph：底是块的前景色，图标是块的底色（稿 `.glyph`）。纯装饰，
/// 不进语义树（名称在旁边另有一份）。
///
/// [turns] 是静止姿态的旋转（悬停时由块传入，如 −10°）；[spinning] 时连续转圈
/// （不弹对话框的方式进行中，IM14），减弱动效下保持静止。
class ImportGlyph extends StatefulWidget {
  const ImportGlyph({
    required this.icon,
    required this.colors,
    required this.seed,
    this.size = 46,
    this.turns = 0,
    this.spinning = false,
    super.key,
  });

  final IconData icon;
  final FushiCoverBlockColors colors;

  /// 形状种子（方式 id / 来源 id），同 seed 同形。
  final String seed;
  final double size;
  final double turns;
  final bool spinning;

  @override
  State<ImportGlyph> createState() => _ImportGlyphState();
}

class _ImportGlyphState extends State<ImportGlyph>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: FushiMotion.ambientBreathBusy,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncSpin();
  }

  @override
  void didUpdateWidget(covariant ImportGlyph oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncSpin();
  }

  void _syncSpin() {
    final bool run = widget.spinning && fushiMotionEnabled(context);
    if (run && !_spin.isAnimating) {
      _spin.repeat();
    } else if (!run && _spin.isAnimating) {
      _spin
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double size = widget.size;
    final Widget glyph = SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: widget.colors.onContainer,
          shape: importGlyphShape(context, widget.seed, size),
        ),
        child: Center(
          child: FushiIcon(
            widget.icon,
            size: size * 0.46,
            color: widget.colors.container,
          ),
        ),
      ),
    );
    return ExcludeSemantics(
      child: AnimatedRotation(
        turns: widget.turns,
        duration: fushiMotionDuration(context, FushiMotion.medium),
        curve: FushiMotion.release,
        child: RotationTransition(turns: _spin, child: glyph),
      ),
    );
  }
}

/// 圆角矩形描边：[dashed] 时画虚线（拖放 / 添加来源的通用视觉语言），否则实线
/// （墨水屏与拖放悬停态用实线）。
class ImportDashedBorderPainter extends CustomPainter {
  const ImportDashedBorderPainter({
    required this.color,
    required this.radius,
    this.dashed = true,
    this.strokeWidth = 2,
    this.inset = 0,
  });

  final Color color;
  final double radius;
  final bool dashed;
  final double strokeWidth;

  /// 描边向内缩进的距离（引导首块的内框是 8，拖放态收到 4）。
  final double inset;

  static const double _dash = 8;
  static const double _gap = 6;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    final RRect rrect = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(inset + strokeWidth / 2),
      Radius.circular(math.max(0, radius - inset)),
    );
    if (!dashed) {
      canvas.drawRRect(rrect, paint);
      return;
    }
    final Path outline = Path()..addRRect(rrect);
    for (final ui.PathMetric metric in outline.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        final double end = math.min(distance + _dash, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance += _dash + _gap;
      }
    }
  }

  @override
  bool shouldRepaint(ImportDashedBorderPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.radius != radius ||
      oldDelegate.dashed != dashed ||
      oldDelegate.strokeWidth != strokeWidth ||
      oldDelegate.inset != inset;
}
