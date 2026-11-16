import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_fit_title.dart';

// =============================================================================
// 装满盒子的**真文字**标题：与 [FushiFitTitle] 同一判据（[fushiFitTitleFontSize]：
// 整段标题在 minSize～maxSize 里二分取盒子放得下的最大字号，可换行、完整显示），
// 但画成 [Text] 而不是 CustomPaint——读屏、文字查找、选区都照常。
//
// [FushiFitTitle] 是水印 / 唱片大字（不进语义树、不参与 `find.text`）；条目本身
// 的标题（发现页媒体块、拼贴首块的标题区）要被读出、被找到，用本组件。字号由
// 本组件按盒子定，页面只给字阶（字重 / 行高 / 颜色）与上下限。
// =============================================================================

/// 铺满父级盒子的装盒标题（真 [Text]）。
///
/// 字号在 [minSize]～[maxSize] 里取盒子放得下的最大值，字距与判据一致取
/// −0.04em；字号由盒子定，不再随系统字号缩放——盒子本身由调用方按系统字号
/// 预留（大字体下盒子更大，字号随之取到上限）。连 [minSize] 都放不下时（盒子按
/// 最小字号预留，正常标题走不到这里）按 [minSize] 排满盒高、末行省略，绝不
/// 溢出。
class FushiFitText extends StatelessWidget {
  const FushiFitText({
    required this.text,
    required this.style,
    required this.minSize,
    required this.maxSize,
    this.alignBottom = false,
    super.key,
  });

  final String text;

  /// 字重 / 行高 / 颜色（字号由本组件定，传进来的字号不用）。
  final TextStyle style;
  final double minSize;
  final double maxSize;

  /// 盒内贴底；默认贴顶。
  final bool alignBottom;

  @override
  Widget build(BuildContext context) {
    final TextDirection direction = Directionality.of(context);
    // 判据与绘制必须是同一份样式：先并进环境默认样式（字体族等），两边都用它。
    final TextStyle resolved = DefaultTextStyle.of(context).style.merge(style);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        final double height = constraints.maxHeight;
        double? fitted;
        if (width.isFinite && width > 0) {
          fitted = fushiFitTitleFontSize(
            text: text,
            style: resolved,
            box: Size(width, height.isFinite ? height : double.maxFinite),
            minSize: minSize,
            maxSize: maxSize,
            direction: direction,
          );
        }
        final double size = fitted ?? minSize;
        int? maxLines;
        if (fitted == null && height.isFinite) {
          final double line = size * (resolved.height ?? 1.2);
          maxLines = math.max(1, (height / line).floor());
        }
        return Align(
          alignment: alignBottom
              ? AlignmentDirectional.bottomStart
              : AlignmentDirectional.topStart,
          child: Text(
            text,
            style: resolved.copyWith(
              fontSize: size,
              letterSpacing: -0.04 * size,
            ),
            textScaler: TextScaler.noScaling,
            maxLines: maxLines,
            overflow: maxLines == null
                ? TextOverflow.visible
                : TextOverflow.ellipsis,
          ),
        );
      },
    );
  }
}
