import 'package:flutter/material.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

/// Used to show information or error messages across the application.
/// For example, this is used for the empty placeholder messages on the home
/// tabs when there are no media item entries in them.
class FushiPlaceholderMessage extends StatelessWidget {
  /// Instantiate a decorative information/error message with an icon.
  const FushiPlaceholderMessage({
    required this.icon,
    required this.message,
    this.color,
    this.iconSize,
    this.messageStyle,
    this.detail,
    this.action,
    super.key,
  });

  /// Decorative icon that is appropriate to relay the message even
  /// if a user may not understand the message.
  final IconData icon;

  /// A message to be shown below the icon that briefly explains the
  /// information or error to be relayed to the user.
  final String message;

  /// The color to be used for the icon and the message, if null,
  /// this is the unselected widget color defined by the app theme.
  final Color? color;

  /// The size of the icon in logical pixels.
  final double? iconSize;

  /// The text style to be used to display the message below the icon.
  final TextStyle? messageStyle;

  /// 次级说明（如折叠后的原始错误串）。bodySmall + onVariant，最多 3 行省略，
  /// 不抢 [message] 的主文案层级。
  final String? detail;

  /// 可选行动按钮（如空态的「导入」、错误态的「重试」），渲染在文案下方。
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) return _buildApple(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Color foreground = color ?? tokens.surfaces.onVariant;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(tokens.spacing.page),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.surfaces.group,
            borderRadius: tokens.radii.cardRadius,
          ),
          child: Padding(
            padding: EdgeInsets.all(tokens.spacing.card),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FushiIcon(
                  icon,
                  size: iconSize ??
                      Theme.of(context).textTheme.headlineMedium?.fontSize,
                  color: foreground,
                ),
                SizedBox(height: tokens.spacing.gap),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: messageStyle ??
                      Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: foreground,
                          ),
                ),
                if (detail != null) ...[
                  SizedBox(height: tokens.spacing.gap / 2),
                  Text(
                    detail!,
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: foreground,
                        ),
                  ),
                ],
                if (action != null) ...[
                  SizedBox(height: tokens.spacing.gap * 1.5),
                  action!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 玻璃设计系统：iOS 空状态（ContentUnavailableView）——无底色、居中，
  /// 大图标 secondaryLabel + 17 semibold 标题 + 15 号说明，不再是一块深灰卡。
  Widget _buildApple(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final TextTheme tt = Theme.of(context).textTheme;
    final Color foreground = color ?? apple.secondaryLabel;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FushiIcon(icon, size: iconSize ?? 48, color: foreground),
              const SizedBox(height: 14),
              Text(
                message,
                textAlign: TextAlign.center,
                style: messageStyle ??
                    tt.titleMedium?.copyWith(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: color ?? apple.label,
                    ),
              ),
              if (detail != null) ...[
                const SizedBox(height: 6),
                Text(
                  detail!,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: tt.bodyMedium?.copyWith(color: apple.secondaryLabel),
                ),
              ],
              if (action != null) ...[
                const SizedBox(height: 18),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
