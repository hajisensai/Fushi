import 'package:material_ui/material_ui.dart';

// =============================================================================
// 出血标题大字（色块 / 海报块 / 正在播放行背后那行被裁掉的粗大标题）。
//
// 纯装饰：用 [CustomPaint] + [TextPainter] 画，不是 [Text] widget——不进语义树
// （读屏不会把标题读两遍）、不参与命中、`find.text(标题)` 也只命中真正的标题。
// 起点按阅读方向量：LTR 从左缘 [FushiBleedTitlePainter.start] 起往右排，RTL 从
// 右缘起往左排；横移量沿阅读方向为正（往末端），RTL 下自动翻转。
// =============================================================================

/// 画出血大字的画笔。[shift] 是悬停横移的动画（可空），[shiftOffset] 是叠加在
/// 动画值上的静态偏移；两者都沿阅读方向计（正 = 往末端）。
class FushiBleedTitlePainter extends CustomPainter {
  FushiBleedTitlePainter({
    required this.text,
    required this.style,
    required this.direction,
    required this.start,
    this.top,
    this.bottom,
    this.shift,
    this.shiftOffset = 0,
  }) : assert(top == null || bottom == null),
       super(repaint: shift);

  /// 大字内容（换行折成空格，单行排）。
  final String text;

  /// 完整样式（已合并默认字体，含字号 / 字重 / 行高 / 字距 / 颜色）。
  final TextStyle style;

  final TextDirection direction;

  /// 起始边到大字起点的距离（可为负：出血到色块外）。
  final double start;

  /// 顶边距；与 [bottom] 二选一，都为空时贴顶。
  final double? top;

  /// 底边距（负值 = 往下出血）。
  final double? bottom;

  final Animation<double>? shift;
  final double shiftOffset;

  /// 当前沿阅读方向的横移量。
  double get effectiveShift => (shift?.value ?? 0) + shiftOffset;

  TextPainter _layout() => TextPainter(
    text: TextSpan(text: text.replaceAll('\n', ' '), style: style),
    textDirection: direction,
    maxLines: 1,
    textScaler: TextScaler.noScaling,
  )..layout();

  Offset _origin(Size size, Size text) {
    final double s = effectiveShift;
    final double dx = direction == TextDirection.rtl
        ? size.width - start - text.width - s
        : start + s;
    final double? b = bottom;
    final double dy = b != null ? size.height - b - text.height : (top ?? 0);
    return Offset(dx, dy);
  }

  /// 大字在画布（尺寸 [size]）里的外框；测试用来量起点与镜像。
  Rect titleRect(Size size) {
    final TextPainter painter = _layout();
    final Size textSize = painter.size;
    painter.dispose();
    return _origin(size, textSize) & textSize;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (text.isEmpty) return;
    final TextPainter painter = _layout();
    painter.paint(canvas, _origin(size, painter.size));
    painter.dispose();
  }

  @override
  bool shouldRepaint(covariant FushiBleedTitlePainter old) =>
      old.text != text ||
      old.style != style ||
      old.direction != direction ||
      old.start != start ||
      old.top != top ||
      old.bottom != bottom ||
      old.shift != shift ||
      old.shiftOffset != shiftOffset;

  // 装饰层不进语义树（外层另有 ExcludeSemantics 兜底）。
  @override
  SemanticsBuilderCallback? get semanticsBuilder => null;
}

/// 铺满父级（放在 `Positioned.fill` 里）的出血大字：字重 w900、行高 0.82、字距
/// -0.05em、不跟系统字号缩放，样式与色块设计稿 `.wm` 一致。字体继承
/// [DefaultTextStyle]，与原先的 `Text` 水印同字形。
class FushiBleedTitle extends StatelessWidget {
  const FushiBleedTitle({
    required this.text,
    required this.textSize,
    required this.color,
    required this.start,
    this.top,
    this.bottom,
    this.shift,
    this.shiftOffset = 0,
    this.direction,
    super.key,
  });

  final String text;

  /// 字号（逻辑像素，不随系统字号缩放）。
  final double textSize;
  final Color color;
  final double start;
  final double? top;
  final double? bottom;
  final Animation<double>? shift;
  final double shiftOffset;

  /// 排版方向；为空取 [Directionality]。
  final TextDirection? direction;

  @override
  Widget build(BuildContext context) {
    final TextStyle style = DefaultTextStyle.of(context).style.merge(
      TextStyle(
        fontSize: textSize,
        fontWeight: FontWeight.w900,
        height: 0.82,
        letterSpacing: -0.05 * textSize,
        color: color,
        decoration: TextDecoration.none,
      ),
    );
    return IgnorePointer(
      child: ExcludeSemantics(
        child: CustomPaint(
          size: Size.infinite,
          painter: FushiBleedTitlePainter(
            text: text,
            style: style,
            direction: direction ?? Directionality.of(context),
            start: start,
            top: top,
            bottom: bottom,
            shift: shift,
            shiftOffset: shiftOffset,
          ),
        ),
      ),
    );
  }
}
