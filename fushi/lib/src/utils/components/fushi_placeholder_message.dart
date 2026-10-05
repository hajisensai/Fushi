import 'package:flutter/material.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

/// [FushiPlaceholderMessage] 的语气：决定 M3E 图标色块的配色。
enum FushiPlaceholderTone {
  /// 空状态 / 一般说明：secondaryContainer 色块。
  neutral,

  /// 错误 / 加载失败：errorContainer 色块。
  error,
}

/// Used to show information or error messages across the application.
/// For example, this is used for the empty placeholder messages on the home
/// tabs when there are no media item entries in them.
///
/// 空状态 / 错误状态的唯一实现（M3 Expressive，2026-10-05）：
/// - MD3：不再压一块深灰卡；图标落在 72×72、24 圆角的饱和 container 色块里
///   （[tone] 决定 secondaryContainer / errorContainer），标题 titleMedium
///   emphasized、说明 bodyMedium onSurfaceVariant，挂载时色块弹入（spring）、
///   文案淡入上浮；墨水屏 / 减弱动态效果下静止。
/// - Apple：iOS ContentUnavailableView 口径（见 [_buildApple]），不受影响。
class FushiPlaceholderMessage extends StatelessWidget {
  /// Instantiate a decorative information/error message with an icon.
  const FushiPlaceholderMessage({
    required this.icon,
    required this.message,
    this.color,
    this.iconSize,
    this.messageStyle,
    this.detail,
    this.details = const <String>[],
    this.detailMaxLines = 3,
    this.action,
    this.tone = FushiPlaceholderTone.neutral,
    super.key,
  });

  /// 错误态用 [FushiPlaceholderTone.error]（MD3 图标色块换 errorContainer）。
  final FushiPlaceholderTone tone;

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

  /// 追加的次级说明行（如「接口提示 + 原始错误 + 代理提示」），排在 [detail]
  /// 之后、样式相同；空串跳过。
  final List<String> details;

  /// 每条说明行的最大行数（默认 3，超出省略）；null = 不限。
  final int? detailMaxLines;

  /// [detail] + [details] 中非空的行，按顺序。
  List<String> get _detailLines => <String>[
        if (detail != null && detail!.isNotEmpty) detail!,
        for (final String line in details)
          if (line.isNotEmpty) line,
      ];

  /// 可选行动按钮（如空态的「导入」、错误态的「重试」），渲染在文案下方。
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) return _buildApple(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final TextTheme tt = theme.textTheme;
    final bool eink = isEinkTheme(context);
    final bool error = tone == FushiPlaceholderTone.error;
    final Color container = error ? cs.errorContainer : cs.secondaryContainer;
    final Color onContainer =
        color ?? (error ? cs.onErrorContainer : cs.onSecondaryContainer);
    final Widget badge = Container(
      width: 72,
      height: 72,
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        color: eink ? Colors.transparent : container,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(24)),
          side: eink ? BorderSide(color: cs.outline) : BorderSide.none,
        ),
      ),
      child: FushiIcon(icon, size: iconSize ?? 32, color: onContainer),
    );
    final Widget text = Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          message,
          textAlign: TextAlign.center,
          style: messageStyle ??
              tt.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: color ?? cs.onSurface,
              ),
        ),
        for (final String line in _detailLines) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            line,
            textAlign: TextAlign.center,
            maxLines: detailMaxLines,
            overflow: detailMaxLines == null ? null : TextOverflow.ellipsis,
            style: tt.bodyMedium?.copyWith(
              color: color ?? cs.onSurfaceVariant,
            ),
          ),
        ],
        if (action != null) ...<Widget>[
          const SizedBox(height: 20),
          action!,
        ],
      ],
    );
    final Duration duration = fushiMotionDuration(
      context,
      const Duration(milliseconds: 500),
    );
    return Center(
      child: Padding(
        padding: EdgeInsets.all(tokens.spacing.page),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(
              begin: duration == Duration.zero ? 1 : 0,
              end: 1,
            ),
            duration: duration,
            curve: Curves.linear,
            builder: (BuildContext context, double t, Widget? _) {
              // 色块用 expressive spatial 弹入（带过冲），文案晚 80ms 淡入上浮。
              final double pop =
                  const Cubic(0.42, 1.67, 0.21, 0.90).transform(t);
              final double fade = Curves.easeOut.transform(
                ((t - 0.16) / 0.84).clamp(0.0, 1.0),
              );
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Transform.scale(scale: 0.6 + 0.4 * pop, child: badge),
                  const SizedBox(height: 16),
                  Opacity(
                    opacity: fade,
                    child: Transform.translate(
                      offset: Offset(0, 8 * (1 - fade)),
                      child: text,
                    ),
                  ),
                ],
              );
            },
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
              for (final String line in _detailLines) ...[
                const SizedBox(height: 6),
                Text(
                  line,
                  textAlign: TextAlign.center,
                  maxLines: detailMaxLines,
                  overflow: detailMaxLines == null
                      ? null
                      : TextOverflow.ellipsis,
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
