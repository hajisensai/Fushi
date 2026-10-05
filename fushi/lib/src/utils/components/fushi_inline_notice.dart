import 'package:flutter/material.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

/// [FushiInlineNotice] 的语义。决定默认图标与配色。
enum FushiNoticeSeverity { info, success, warning, error }

/// 页面 / 面板内嵌的提示横幅（「部分来源失败」「先开服务」「检测到迁移数据」
/// 这类说明条）的唯一实现。此前全 app 约十个横幅各写各的（tertiaryContainer
/// 卡、secondaryContainer 盒、裸 Row……），颜色、圆角、图标、密度都不一样，
/// Apple 下也没有分支；新增横幅一律用本组件。
///
/// - MD3：中性 surfaceContainerHigh 底（语义只在图标色上）圆角 12，前置单色
///   图标；
/// - Apple：tertiaryFill 实色底（内容层，不是玻璃）圆角 10，单色 SF 图标上
///   语义色（info 用强调色），文字 label 色；动作是无底强调色文字按钮；
/// - 墨水屏：无填充、前景色细描边（底色在灰阶下塌掉，描边才是边界）。
///
/// [title] 可选（加粗一行）；[message] 是正文（字符串或任意 widget，后者用于
/// 「文案 + 来源名」这类组合）；[actions] 默认排在正文下方，宽布局（本横幅
/// 自身宽 ≥ [inlineActionsMinWidth]）时与正文同一行、排在右侧（见
/// [actionsInline]）；[trailing] 排在正文右侧。
class FushiInlineNotice extends StatelessWidget {
  const FushiInlineNotice({
    required this.message,
    this.severity = FushiNoticeSeverity.info,
    this.icon,
    this.title,
    this.trailing,
    this.actions = const <Widget>[],
    this.showIcon = true,
    this.actionsInline,
    super.key,
  });

  /// 自动模式下动作并入正文同一行所需的横幅最小宽度。
  static const double inlineActionsMinWidth = 600;

  /// 正文：[String] 或 [Widget]。
  final Object message;
  final FushiNoticeSeverity severity;

  /// 覆盖默认图标（默认按 [severity] 取）。
  final IconData? icon;
  final String? title;
  final Widget? trailing;
  final List<Widget> actions;
  final bool showIcon;

  /// [actions] 是否与正文同一行（排在正文右侧）：null = 自动（横幅宽 ≥
  /// [inlineActionsMinWidth] 时同行，窄屏换到正文下方）；true 恒同行；false
  /// 恒在下方（旧行为）。
  final bool? actionsInline;

  static IconData _defaultIcon(FushiNoticeSeverity severity) {
    switch (severity) {
      case FushiNoticeSeverity.info:
        return Icons.info_outline_rounded;
      case FushiNoticeSeverity.success:
        return Icons.check_circle_outline_rounded;
      case FushiNoticeSeverity.warning:
        return Icons.warning_amber_rounded;
      case FushiNoticeSeverity.error:
        return Icons.error_outline_rounded;
    }
  }

  /// MD3 的 (底色, 前景色, 图标色)：一律中性 surfaceContainerHigh 底 +
  /// onSurface 文字，语义只体现在前置图标颜色上（用户 2026-10-04：去掉页面
  /// 上的彩色块；与 fushi_neutral_decor 的信息块同一规则）。
  static ({Color fill, Color foreground, Color iconColor}) _md3Colors(
    ColorScheme cs,
    FushiNoticeSeverity severity,
  ) {
    final bool dark = cs.brightness == Brightness.dark;
    final Color icon = switch (severity) {
      FushiNoticeSeverity.info => cs.primary,
      FushiNoticeSeverity.error => cs.error,
      FushiNoticeSeverity.success =>
        dark ? const Color(0xFF7DDC8C) : const Color(0xFF1E6B30),
      FushiNoticeSeverity.warning =>
        dark ? const Color(0xFFFFB870) : const Color(0xFF8F4A00),
    };
    return (
      fill: cs.surfaceContainerHigh,
      foreground: cs.onSurface,
      iconColor: icon,
    );
  }

  static Color _appleIconColor(
    FushiAppleColors apple,
    FushiNoticeSeverity severity,
  ) {
    switch (severity) {
      case FushiNoticeSeverity.info:
        return apple.accent;
      case FushiNoticeSeverity.success:
        return apple.success;
      case FushiNoticeSeverity.warning:
        return apple.warning;
      case FushiNoticeSeverity.error:
        return apple.destructive;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool eink = isEinkTheme(context);
    final bool glass = isGlassDesign(context);

    final Color? fill;
    final Color foreground;
    final Color iconColor;
    final BorderRadius radius;
    if (eink) {
      fill = null;
      foreground = cs.onSurface;
      iconColor = cs.onSurface;
      radius = tokens.radii.controlRadius;
    } else if (glass) {
      final FushiAppleColors apple = appleColorsOf(context);
      fill = apple.tertiaryFill;
      foreground = apple.label;
      iconColor = _appleIconColor(apple, severity);
      radius = const BorderRadius.all(Radius.circular(10));
    } else {
      final ({Color fill, Color foreground, Color iconColor}) c = _md3Colors(
        cs,
        severity,
      );
      fill = c.fill;
      foreground = c.foreground;
      iconColor = c.iconColor;
      radius = tokens.radii.controlRadius;
    }

    final TextStyle body = (theme.textTheme.bodyMedium ?? const TextStyle())
        .copyWith(color: foreground);
    final Object message = this.message;
    final Widget messageWidget = message is Widget
        ? DefaultTextStyle.merge(style: body, child: message)
        : Text(message.toString(), style: body);
    final String? title = this.title;

    Widget textColumn({required bool withActions}) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (title != null && title.isNotEmpty) ...<Widget>[
          Text(
            title,
            style: (theme.textTheme.titleSmall ?? const TextStyle()).copyWith(
              color: foreground,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: tokens.spacing.gap / 2),
        ],
        messageWidget,
        if (withActions && actions.isNotEmpty) ...<Widget>[
          SizedBox(height: tokens.spacing.gap),
          Wrap(
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap / 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: actions,
          ),
        ],
      ],
    );

    Widget notice(bool inline) => DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: radius,
        border: eink ? Border.all(color: cs.onSurface) : null,
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.rowHorizontal - 2,
          vertical: tokens.spacing.rowVertical,
        ),
        child: Row(
          // 同行动作时整行垂直居中（按钮比正文高），否则图标贴正文首行。
          crossAxisAlignment: inline
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.start,
          children: <Widget>[
            if (showIcon) ...<Widget>[
              Padding(
                // 图标与正文首行垂直对齐（20 号图标 vs 正文行高约 20）。
                padding: EdgeInsets.only(top: inline ? 0 : 1),
                child: FushiIcon(
                  icon ?? _defaultIcon(severity),
                  size: 20,
                  color: iconColor,
                ),
              ),
              SizedBox(width: tokens.spacing.gap + 2),
            ],
            Expanded(child: textColumn(withActions: !inline)),
            if (inline) ...<Widget>[
              SizedBox(width: tokens.spacing.gap),
              // 动作组可伸缩：按钮多 / 文案长时在分到的宽度内换行，而不是把整行
              // 撑出横向溢出（视频页在线服务横幅曾溢出 282px）。
              Flexible(
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: tokens.spacing.gap,
                  runSpacing: tokens.spacing.gap / 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: actions,
                ),
              ),
            ],
            if (trailing != null) ...<Widget>[
              SizedBox(width: tokens.spacing.gap),
              Flexible(
                child: DefaultTextStyle.merge(
                  style: TextStyle(color: foreground),
                  child: trailing!,
                ),
              ),
            ],
          ],
        ),
      ),
    );

    if (actions.isEmpty || actionsInline == false) return notice(false);
    if (actionsInline == true) return notice(true);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) =>
          notice(constraints.maxWidth >= inlineActionsMinWidth),
    );
  }
}
