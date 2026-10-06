import 'package:flutter/material.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_neutral_decor.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// [FushiTag] 的语义色调：调用方只说「这是什么状态」，配色由设计系统决定。
enum FushiTagTone { neutral, accent, success, warning, error }

/// A clickable MD3-style tag used in dictionary entries.
class FushiTag extends StatelessWidget {
  const FushiTag({
    required this.text,
    this.backgroundColor,
    this.message,
    this.trailingText,
    this.icon,
    this.foregroundColor,
    this.iconSize,
    this.style,
    this.tone,
    this.dense = false,
    super.key,
  }) : assert(
          backgroundColor != null || tone != null,
          'FushiTag needs a backgroundColor or a tone',
        );

  final IconData? icon;
  final String text;
  final String? message;
  final String? trailingText;

  /// 调用方自定底色（带语义：错误 / 可信 / 冲突计数）。设了 [tone] 时忽略。
  final Color? backgroundColor;

  /// 语义色调：设了就由设计系统配色，[backgroundColor] / [foregroundColor]
  /// 不再生效。
  /// - MD3：neutral = surfaceContainerHighest、accent = primaryContainer、
  ///   error = errorContainer（各配 on* 字）；success / warning 没有容器槽位，
  ///   取 [fushiStatusColor] 16% 淡底 + 状态色字；墨水屏页面底 + 描边。
  /// - Apple：一律空心胶囊（发丝分隔线描边、无底），语义只落在字色上
  ///   （secondaryLabel / 强调色 / 系统绿橙红），不再加圆点。
  final FushiTagTone? tone;

  /// true：不留外侧右间距（单独摆放的状态胶囊，而不是一串并排的标签）。
  final bool dense;
  final Color? foregroundColor;
  final double? iconSize;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    // 标签统一（2026-10-04）：不可交互的小标签一律矮一号——高 20–24、左右
    // 8、11 号 w500 字；和可交互的 chip（全胶囊、高 32）一眼分得开。
    // - MD3：圆角 6（tokens.radii.chipRadius，MD3 小组件圆角）；底色仍由调用
    //   方给（它带语义：错误 / 可信 / 冲突计数）；尾部计数改成中性的
    //   surfaceContainerHighest 小块，不再是 tertiaryContainer 彩块。
    // - Apple：空心胶囊（分隔线描边、无底）+ secondaryLabel 字，调用方的语义色只
    //   落在字前一颗 6px 圆点上（iOS 不铺饱和色块）。
    final bool apple = isGlassDesign(context);
    final FushiAppleColors? appleColors = apple ? appleColorsOf(context) : null;
    final FushiTagTone? tone = this.tone;
    final bool einkTone = tone != null && !apple && isEinkTheme(context);
    final ({Color background, Color foreground})? toned =
        tone == null ? null : _toneColors(context, tone, appleColors);
    final Color background =
        toned?.background ?? backgroundColor ?? scheme.secondaryContainer;
    // Apple：元信息标签不铺 systemFill 灰底（用户 2026-10-04「很多地方有底
    // 色」），只留发丝分隔线描边的空心胶囊，与 FushiTagChip 纯展示形态一致。
    final Color surface = appleColors != null ? Colors.transparent : background;
    final Color effectiveForeground = toned?.foreground ??
        appleColors?.secondaryLabel ??
        foregroundColor ??
        scheme.onSecondaryContainer;
    final TextStyle baseStyle = (textTheme.labelSmall ?? const TextStyle())
        .copyWith(fontSize: 11, fontWeight: FontWeight.w500, height: 1.2);
    final TextStyle effectiveStyle = appleColors != null
        ? baseStyle.copyWith(color: effectiveForeground)
        : (style ?? baseStyle.copyWith(color: effectiveForeground));
    // Apple 下调用方语义色只落在前面的圆点上；调用方常传 MD3 的 *Container
    // 色（Apple 配色里是中性灰），换回对应的基色圆点才看得出语义。
    final Color? appleDot = appleColors != null && tone == null
        ? _baseColorFor(scheme, background)
        : null;

    return Padding(
      padding: EdgeInsetsDirectional.only(
        end: dense ? 0 : tokens.spacing.gap / 2,
      ),
      child: Material(
        color: surface,
        shape: appleColors != null
            ? StadiumBorder(
                side: BorderSide(color: appleColors.separator, width: 0.8),
              )
            : RoundedRectangleBorder(
                borderRadius: tokens.radii.chipRadius,
                side: einkTone
                    ? BorderSide(color: scheme.outline)
                    : BorderSide.none,
              ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: message == null
              ? null
              : () {
                  FushiToast.show(
                    backgroundColor: background,
                    textColor: toned?.foreground ??
                        foregroundColor ??
                        scheme.onSecondaryContainer,
                    msg: message!,
                    toastLength: Toast.LENGTH_SHORT,
                    gravity: ToastGravity.BOTTOM,
                  );
                },
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 22),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (appleDot != null) ...[
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: appleDot,
                        shape: BoxShape.circle,
                      ),
                      child: const SizedBox(width: 6, height: 6),
                    ),
                    const SizedBox(width: 5),
                  ],
                  if (icon != null) ...[
                    FushiIcon(
                      icon,
                      color: effectiveForeground,
                      size: iconSize ?? 12,
                    ),
                    const SizedBox(width: 4),
                  ],
                  Flexible(
                    child: Text(
                      text,
                      style: effectiveStyle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (trailingText != null) ...[
                    const SizedBox(width: 4),
                    Flexible(
                      child: DecoratedBox(
                        decoration: ShapeDecoration(
                          color: appleColors?.separator ??
                              scheme.surfaceContainerHighest,
                          shape: appleColors != null
                              ? const StadiumBorder()
                              : RoundedRectangleBorder(
                                  borderRadius: tokens.radii.chipRadius,
                                ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          child: Text(
                            trailingText!,
                            style: baseStyle.copyWith(
                              fontSize: 10,
                              color: appleColors?.secondaryLabel ??
                                  scheme.onSurfaceVariant,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// [tone] 的 (底色, 字色)。Apple 底色恒为 systemFill（由调用处套），这里
  /// 只决定字色。
  static ({Color background, Color foreground}) _toneColors(
    BuildContext context,
    FushiTagTone tone,
    FushiAppleColors? apple,
  ) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    if (apple != null) {
      final Color foreground = switch (tone) {
        FushiTagTone.neutral => apple.secondaryLabel,
        FushiTagTone.accent => apple.accent,
        FushiTagTone.success => apple.success,
        FushiTagTone.warning => apple.warning,
        FushiTagTone.error => apple.destructive,
      };
      return (background: apple.fill, foreground: foreground);
    }
    if (isEinkTheme(context)) {
      return (background: cs.surface, foreground: cs.onSurface);
    }
    switch (tone) {
      case FushiTagTone.neutral:
        return (
          background: cs.surfaceContainerHighest,
          foreground: cs.onSurfaceVariant,
        );
      case FushiTagTone.accent:
        return (
          background: cs.primaryContainer,
          foreground: cs.onPrimaryContainer,
        );
      case FushiTagTone.error:
        return (
          background: cs.errorContainer,
          foreground: cs.onErrorContainer,
        );
      case FushiTagTone.success:
      case FushiTagTone.warning:
        final Color status = fushiStatusColor(
          context,
          tone == FushiTagTone.success
              ? FushiStatusTone.success
              : FushiStatusTone.warning,
        );
        return (
          background: status.withValues(alpha: 0.16),
          foreground: status,
        );
    }
  }

  /// MD3 容器色 → 对应基色（primaryContainer → primary 等）；其它原样。
  static Color _baseColorFor(ColorScheme cs, Color color) {
    if (color == cs.primaryContainer) return cs.primary;
    if (color == cs.secondaryContainer) return cs.secondary;
    if (color == cs.tertiaryContainer) return cs.tertiary;
    if (color == cs.errorContainer) return cs.error;
    return color;
  }
}
