import 'package:flutter/material.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

/// 统一的「加载中」占位：指示器居中，下方可选一行 13–14 号次要色说明文字。
///
/// 取代散落在各页的 `Center(child: CircularProgressIndicator())`，让三种外观
/// 一处决定：
/// - MD3：Material 3 Expressive LoadingIndicator（主色形状连续变形 + 旋转，
///   [contained] 时铺 primaryContainer 圆底）；
/// - Apple：iOS / macOS 菊花（系统灰，常规半径 10，[compact] 时小号 8）；
/// - 墨水屏：一枚静止的沙漏（任何持续动画在墨水屏上都是局部刷新闪烁）。
///
/// 默认撑满父级并居中（页面级占位）；放在列表行、按钮等小地方时用
/// [compact]（指示器缩小、不留外边距）。
class FushiLoadingView extends StatelessWidget {
  const FushiLoadingView({
    super.key,
    this.message,
    this.compact = false,
    this.contained = false,
    this.color,
    this.semanticsLabel,
  });

  /// 指示器下方的说明文字（如「正在加载词典…」）；null 不显示。
  final String? message;

  /// 小号形态：MD3 指示器 32、Apple 菊花半径 8，文字 13 号。
  final bool compact;

  /// MD3 下 LoadingIndicator 是否带 primaryContainer 圆底（M3 Expressive 的
  /// contained 变体，适合压在图片 / 复杂背景上）。
  final bool contained;

  /// 指示器颜色；null = 设计系统默认（MD3 primary / Apple 系统灰）。
  final Color? color;

  /// 无说明文字时给读屏的标签。
  final String? semanticsLabel;

  Widget _indicator(BuildContext context) {
    if (isEinkTheme(context)) {
      return SizedBox.square(
        dimension: compact ? 24 : 36,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: FushiIcon(
            Icons.hourglass_top,
            color: color ?? Theme.of(context).colorScheme.primary,
          ),
        ),
      );
    }
    if (isGlassDesign(context)) {
      return fushiAppleActivityIndicator(
        context,
        size: compact ? 20 : 28,
        color: color,
      );
    }
    return FushiExpressiveLoadingIndicator(
      size: compact ? 32 : 48,
      contained: contained,
      color: color,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? text = message;
    final Color textColor = isGlassDesign(context)
        ? appleColorsOf(context).secondaryLabel
        : theme.colorScheme.onSurfaceVariant;
    Widget body = Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _indicator(context),
        if (text != null && text.isNotEmpty) ...<Widget>[
          SizedBox(height: compact ? 8 : 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
              fontSize: compact ? 13 : 14,
              color: textColor,
            ),
          ),
        ],
      ],
    );
    body = Semantics(
      liveRegion: true,
      label: text == null || text.isEmpty ? semanticsLabel : null,
      child: body,
    );
    if (compact) return body;
    return Center(
      child: Padding(padding: const EdgeInsets.all(24), child: body),
    );
  }
}
