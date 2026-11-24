import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiAppleMetrics, fushiAppleMacScale;

/// Apple 设计系统的 pop-up 按钮外观（iOS 27 / macOS 27），筛选胶囊、行内下拉、
/// 表单下拉的 Apple 分支共用这一份。
///
/// @design dual —— 只画 Apple 分支；MD3 分支由调用方（[LibraryFilterChip]、
/// `GamepadMenuDropdown`）各自走 M3E 形态。点击 / 焦点 / 菜单不在这里：调用方
/// 把它放进 `FushiPlainButton`、`FushiPopupMenuButton` 等可交互的壳里。
///
/// - iOS（触屏 / 桌面窄窗，[FushiAppleMetrics.desktop] 为 false）：内容层实色
///   `tertiarySystemFill` 灰胶囊、无描边，内容自适应宽度；15pt 文字 + 尾部
///   `chevron.up.chevron.down` 12pt 灰箭头；默认高 [iosHeight]。
/// - macOS（桌面宽窗）：pop-up button——`secondarySystemFill` 灰填充、圆角 6、
///   默认高 [macosHeight]，13pt 文字 + 尾部 10pt 上下双箭头（与设置页
///   `GlassSettingsPopUpButton` 同一规格）。
/// - [active]（筛选已生效）：中性表达——灰填充加深一档、文字 label 色
///   semibold；Apple 下拉按钮一律不带强调色。
/// - 不用玻璃：pop-up 按钮在 iOS 27 内容区里是实色控件，所以也不随玻璃画质档
///   变化（实色档与玻璃档外观一致）。
class FushiApplePopUpButtonFace extends StatelessWidget {
  const FushiApplePopUpButtonFace({
    this.label,
    super.key,
    this.labelWidget,
    this.leading,
    this.chevron,
    this.style,
    this.contentAlignment,
    this.active = false,
    this.enabled = true,
    this.height,
    this.expand = false,
    this.maxLabelWidth,
    this.paintFill = true,
    this.labelMaxLines = 1,
  }) : assert(label != null || labelWidget != null);

  /// iOS 默认高度（与库页行内控件 / 搜索胶囊同高）。
  static const double iosHeight = 36;

  /// macOS pop-up button 默认高度（regular control size）。
  static const double macosHeight = 22;

  /// 当前文案（选中值或维度名）。与 [labelWidget] 二选一。
  final String? label;

  /// 自定义文案控件（`DropdownMenuItem.child`、带小标题的两行值等）：套上本
  /// 外观的字号 / 颜色；给了它时高度按内容长（[height] 是最小高）。
  final Widget? labelWidget;

  /// 文案前的图标（下拉菜单的 leadingIcon）。
  final Widget? leading;

  /// 替换尾部上下双箭头（调用方显式给的自定义箭头；`SizedBox.shrink()` = 不要）。
  final Widget? chevron;

  /// 叠在本外观字号 / 颜色之上的文字样式（调用方的 `style` / `textStyle`）。
  final TextStyle? style;

  /// [expand] 时文案在剩余宽度里的对齐；null = 起始端。
  final AlignmentGeometry? contentAlignment;

  /// 筛选已生效：灰填充加深一档 + semibold 文字（不带强调色）。
  final bool active;
  final bool enabled;

  /// 定高；null = 按档位取 [iosHeight] / [macosHeight]。表单式（[labelMaxLines]
  /// > 1）时是最小高度。
  final double? height;

  /// 撑满父级宽度（表单 / 设置行里的整宽下拉）；false = 内容自适应宽度。
  final bool expand;

  /// 文案最大宽度（窄窗里长档位名不撑溢出整行）；null = 不限（[expand] 时忽略）。
  final double? maxLabelWidth;

  /// 自己画底。外层壳（`FushiPlainButton.fill`）负责画底与悬停 / 按下叠层时传
  /// false，再用 [fillOf] 把同一个底色交给壳。
  final bool paintFill;

  /// 文案最多几行；>1 时不定高，按内容长高（表单下拉的长选项）。
  final int labelMaxLines;

  /// 当前档位是否 macOS（桌面宽窗）。
  static bool desktopOf(BuildContext context) =>
      FushiAppleMetrics.of(context).desktop;

  /// 当前档位的默认高度。
  static double defaultHeightOf(BuildContext context) => desktopOf(context)
      ? macosHeight * fushiAppleMacScale(context)
      : iosHeight;

  /// 按钮底色（见 [paintFill]）。
  static Color fillOf(BuildContext context, {bool active = false}) {
    final FushiAppleColors apple = appleColorsOf(context);
    // 不带强调色（用户 2026-11-24「下拉框还是有强调色」）：生效时只把灰填充
    // 加深一档（iOS tertiary → secondary、macOS secondary → fill）。
    if (desktopOf(context)) {
      return active ? apple.fill : apple.secondaryFill;
    }
    return active ? apple.secondaryFill : apple.tertiaryFill;
  }

  /// 按钮圆角：iOS 27 / macOS 27 的 pop-up 按钮都是全胶囊（Tahoe 起 macOS
  /// 控件改成胶囊形），两档一致。
  static BorderRadius radiusOf(BuildContext context, double height) =>
      BorderRadius.circular(height / 2);

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final bool desktop = desktopOf(context);
    final double k = fushiAppleMacScale(context);
    final double h = height ?? defaultHeightOf(context);
    final bool multiline = labelMaxLines > 1 || labelWidget != null;
    final Color foreground = enabled ? apple.label : apple.tertiaryLabel;
    final Color chevronColor = enabled
        ? apple.secondaryLabel
        : apple.tertiaryLabel;
    final TextStyle base =
        (Theme.of(context).textTheme.bodyMedium ?? const TextStyle()).copyWith(
          fontSize: desktop ? 13 * k : 15,
          fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          color: foreground,
          height: 1.2,
          leadingDistribution: TextLeadingDistribution.even,
        );
    final TextStyle textStyle = base
        .merge(style)
        .copyWith(color: enabled ? style?.color ?? foreground : foreground);
    Widget text = labelWidget != null
        ? DefaultTextStyle(
            style: textStyle,
            maxLines: labelMaxLines,
            overflow: TextOverflow.ellipsis,
            child: labelWidget!,
          )
        : Text(
            label!,
            maxLines: labelMaxLines,
            softWrap: labelMaxLines > 1,
            overflow: labelMaxLines > 1 ? null : TextOverflow.ellipsis,
            style: textStyle,
          );
    if (expand) {
      text = Expanded(
        child: Align(
          alignment: contentAlignment ?? AlignmentDirectional.centerStart,
          child: text,
        ),
      );
    } else if (maxLabelWidth != null) {
      text = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxLabelWidth!),
        child: text,
      );
    } else {
      text = Flexible(child: text);
    }
    final double chevronSize = desktop ? 10 * k : 12;
    final Widget row = IconTheme.merge(
      data: IconThemeData(color: foreground, size: desktop ? 14 * k : 17),
      child: Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        children: <Widget>[
          if (leading != null) ...<Widget>[
            leading!,
            SizedBox(width: desktop ? 5 * k : 8),
          ],
          text,
          SizedBox(width: desktop ? 5 * k : 6),
          IconTheme.merge(
            data: IconThemeData(color: chevronColor, size: chevronSize),
            child:
                chevron ??
                Icon(
                  CupertinoIcons.chevron_up_chevron_down,
                  size: chevronSize,
                  color: chevronColor,
                ),
          ),
        ],
      ),
    );
    return AnimatedContainer(
      duration: fushiMotionDuration(context, FushiMotion.short),
      curve: FushiMotion.standard,
      height: multiline ? null : h,
      constraints: multiline ? BoxConstraints(minHeight: h) : null,
      padding: EdgeInsetsDirectional.only(
        start: desktop ? 8 * k : 14,
        end: desktop ? 6 * k : 11,
        top: multiline ? (desktop ? 3 * k : 6) : 0,
        bottom: multiline ? (desktop ? 3 * k : 6) : 0,
      ),
      alignment: expand
          ? AlignmentDirectional.centerStart
          : AlignmentDirectional.center,
      decoration: BoxDecoration(
        color: paintFill ? fillOf(context, active: active) : null,
        borderRadius: radiusOf(context, h),
      ),
      child: row,
    );
  }
}
