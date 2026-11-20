import 'package:material_ui/material_ui.dart';

// =============================================================================
// 装满盒子的标题大字（W 原型 `fit()`）：整段标题按盒子二分取能放下的最大字号，
// 可以换行、完整显示，不出血、不裁成半个字；连最小字号都放不下就不画。
//
// 色块（[FushiCoverBlock]）的大字水印与唱片色块的标题都用它。画出来的（
// [CustomPaint] + [TextPainter]），不是 [Text]：作水印时不进语义树、不参与命中、
// `find.text(标题)` 只命中真正的标题；作标题时（[FushiFitTitle.semantic]）由外层
// [Semantics] 读一遍标题。
// =============================================================================

/// 大字在盒子里的竖直对齐。
enum FushiFitTitleAlign {
  /// 贴顶（水印：压在文字区上半，不跟底部的标题 / 副行抢位置）。
  top,

  /// 贴底（W 原型 `.big` 的 `justify-content: flex-end`）。
  bottom,
}

/// 原型 `.big > span { padding-top: .1em }`：字号判据里标题顶上留的气口（× 字号）。
const double kFushiFitTitleTopPad = 0.1;

/// 大字的默认字形：字重 w900、行高 0.92、字距 -0.04em（W 原型 `.big`）。
/// [fontSize] 与 [color] 由调用方给；字体继承 [base]。
TextStyle fushiFitTitleStyle(
  TextStyle base, {
  required double fontSize,
  required Color color,
}) => base.merge(
  TextStyle(
    fontSize: fontSize,
    fontWeight: FontWeight.w900,
    height: 0.92,
    letterSpacing: -0.04 * fontSize,
    color: color,
    decoration: TextDecoration.none,
  ),
);

TextPainter _layoutFitTitle(
  String text,
  TextStyle style,
  double maxWidth,
  TextDirection direction,
) => TextPainter(
  text: TextSpan(text: text, style: style),
  textDirection: direction,
  textAlign: TextAlign.start,
  textScaler: TextScaler.noScaling,
)..layout(maxWidth: maxWidth);

/// [text] 按 [style]（字号由本函数定）排进 [box] 时能用的最大字号（在
/// [minSize]～[maxSize] 之间二分 12 次，与原型同一判据：排完的总高不超过盒高、
/// 每行都不超过盒宽）。最小字号也放不下时返回 null（调用方不画）。
///
/// 高度判据与原型一致地计入 `span` 的 `padding-top: .1em`（排完的总高 +
/// 0.1 × 字号 ≤ 盒高），字形顶上留出那一点气口。
///
/// [wrapAnywhere] 为 false（水印）时先按「词不拆开」求（最长的不可断片段——
/// 拉丁词——整个放得进盒宽，[TextPainter.minIntrinsicWidth]）：否则二分会为了
/// 字号把短标题逐字母拆成一列碎片；只有最小字号下词都放不进盒宽时才允许词内
/// 换行。为 true（W 原型 `.big`：唱片色块 / 专辑海报的标题大字）时照原型的
/// `overflow-wrap: anywhere` 只看盒高，词可以在任意处折行。
double? fushiFitTitleFontSize({
  required String text,
  required TextStyle style,
  required Size box,
  required double minSize,
  required double maxSize,
  required TextDirection direction,
  bool wrapAnywhere = false,
}) {
  if (text.trim().isEmpty || box.width <= 0 || box.height <= 0) return null;
  if (maxSize < minSize) return null;
  bool fits(double size, {required bool keepWords}) {
    final TextPainter painter = _layoutFitTitle(
      text,
      style.copyWith(fontSize: size, letterSpacing: -0.04 * size),
      box.width,
      direction,
    );
    final bool ok =
        painter.height + size * kFushiFitTitleTopPad <= box.height &&
        (!keepWords || painter.minIntrinsicWidth <= box.width + 0.5) &&
        painter.computeLineMetrics().every(
          (LineMetrics line) => line.width <= box.width + 0.5,
        );
    painter.dispose();
    return ok;
  }

  bool keepWords = !wrapAnywhere;
  if (!fits(minSize, keepWords: keepWords)) {
    if (!fits(minSize, keepWords: false)) return null;
    keepWords = false;
  }
  double lo = minSize;
  double hi = maxSize;
  if (fits(hi, keepWords: keepWords)) return hi;
  for (int k = 0; k < 12; k++) {
    final double mid = (lo + hi) / 2;
    if (fits(mid, keepWords: keepWords)) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return lo;
}

/// 画装盒大字的画笔。[style] 已含最终字号；[shift] 是悬停横移（可空），沿阅读
/// 方向为正（往末端），RTL 下自动翻转。
class FushiFitTitlePainter extends CustomPainter {
  FushiFitTitlePainter({
    required this.text,
    required this.style,
    required this.direction,
    required this.align,
    this.shift,
  }) : super(repaint: shift);

  final String text;
  final TextStyle style;
  final TextDirection direction;
  final FushiFitTitleAlign align;
  final Animation<double>? shift;

  /// 大字在画布（尺寸 [size]）里的外框（含当前横移）；测试用来量位置与镜像。
  Rect titleRect(Size size) {
    final TextPainter painter = _layoutFitTitle(
      text,
      style,
      size.width,
      direction,
    );
    final Rect rect = _origin(size, painter) & painter.size;
    painter.dispose();
    return rect;
  }

  Offset _origin(Size size, TextPainter painter) {
    final double s = shift?.value ?? 0;
    // 起始边对齐：LTR 贴左、RTL 贴右（TextPainter 的宽是最长行宽）。
    final double dx = direction == TextDirection.rtl
        ? size.width - painter.width - s
        : s;
    final double dy = align == FushiFitTitleAlign.bottom
        ? size.height - painter.height
        : 0;
    return Offset(dx, dy);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (text.isEmpty) return;
    final TextPainter painter = _layoutFitTitle(
      text,
      style,
      size.width,
      direction,
    );
    painter.paint(canvas, _origin(size, painter));
    painter.dispose();
  }

  @override
  bool shouldRepaint(covariant FushiFitTitlePainter old) =>
      old.text != text ||
      old.style != style ||
      old.direction != direction ||
      old.align != align ||
      old.shift != shift;

  @override
  SemanticsBuilderCallback? get semanticsBuilder => null;
}

/// 铺满父级盒子的装盒大字。字号在 [minSize]～[maxSize] 里取盒子放得下的最大值；
/// 放不下 [minSize] 时什么都不画（[SizedBox.shrink]）。
///
/// [semantic] 为 false（水印）时整块不进语义树；为 true（它就是标题，如唱片色块）
/// 时读一遍 [text]。
class FushiFitTitle extends StatelessWidget {
  const FushiFitTitle({
    required this.text,
    required this.color,
    required this.maxSize,
    required this.minSize,
    this.align = FushiFitTitleAlign.bottom,
    this.shift,
    this.direction,
    this.semantic = false,
    this.wrapAnywhere = false,
    super.key,
  });

  final String text;
  final Color color;

  /// 字号上下限（逻辑像素，不随系统字号缩放：字号本就由盒子定）。
  final double maxSize;
  final double minSize;
  final FushiFitTitleAlign align;

  /// 悬停横移（沿阅读方向为正）。
  final Animation<double>? shift;

  /// 排版方向；为空取 [Directionality]。
  final TextDirection? direction;

  /// true = 这就是标题（读屏读一遍）；false = 装饰水印（不进语义）。
  final bool semantic;

  /// 词可在任意处折行（W 原型 `.big` 的 `overflow-wrap: anywhere`），见
  /// [fushiFitTitleFontSize]。
  final bool wrapAnywhere;

  @override
  Widget build(BuildContext context) {
    final TextDirection dir = direction ?? Directionality.of(context);
    final TextStyle base = DefaultTextStyle.of(context).style;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size box = constraints.biggest;
        if (!box.isFinite) return const SizedBox.shrink();
        final TextStyle probe = fushiFitTitleStyle(
          base,
          fontSize: minSize,
          color: color,
        );
        final double? size = fushiFitTitleFontSize(
          text: text,
          style: probe,
          box: box,
          minSize: minSize,
          maxSize: maxSize,
          direction: dir,
          wrapAnywhere: wrapAnywhere,
        );
        if (size == null) {
          return semantic
              ? Semantics(label: text, child: const SizedBox.expand())
              : const SizedBox.shrink();
        }
        final Widget paint = CustomPaint(
          size: box,
          painter: FushiFitTitlePainter(
            text: text,
            style: fushiFitTitleStyle(base, fontSize: size, color: color),
            direction: dir,
            align: align,
            shift: shift,
          ),
        );
        return IgnorePointer(
          child: semantic
              ? Semantics(label: text, textDirection: dir, child: paint)
              : ExcludeSemantics(child: paint),
        );
      },
    );
  }
}
