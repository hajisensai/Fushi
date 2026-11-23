import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiAppleMetrics;

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
/// - [active]（筛选已生效）：底换成强调色淡染、文字与箭头换强调色。
/// - 不用玻璃：pop-up 按钮在 iOS 27 内容区里是实色控件，所以也不随玻璃画质档
///   变化（实色档与玻璃档外观一致）。
class FushiApplePopUpButtonFace extends StatelessWidget {
  const FushiApplePopUpButtonFace({
    required this.label,
    super.key,
    this.active = false,
    this.enabled = true,
    this.height,
    this.expand = false,
    this.maxLabelWidth,
    this.paintFill = true,
    this.labelMaxLines = 1,
  });

  /// iOS 默认高度（与库页行内控件 / 搜索胶囊同高）。
  static const double iosHeight = 36;

  /// macOS pop-up button 默认高度（regular control size）。
  static const double macosHeight = 22;

  /// 当前文案（选中值或维度名）。
  final String label;

  /// 筛选已生效：强调色淡染底 + 强调色文字。
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
  static double defaultHeightOf(BuildContext context) =>
      desktopOf(context) ? macosHeight : iosHeight;

  /// 按钮底色（见 [paintFill]）。
  static Color fillOf(BuildContext context, {bool active = false}) {
    final FushiAppleColors apple = appleColorsOf(context);
    if (active) {
      final bool dark =
          Theme.of(context).colorScheme.brightness == Brightness.dark;
      return apple.accent.withValues(alpha: dark ? 0.24 : 0.14);
    }
    return desktopOf(context) ? apple.secondaryFill : apple.tertiaryFill;
  }

  /// 按钮圆角：macOS 圆角 6（高于 24 的大号控件 7），iOS 全胶囊。
  static BorderRadius radiusOf(BuildContext context, double height) =>
      BorderRadius.circular(
        desktopOf(context) ? (height > 24 ? 7 : 6) : height / 2,
      );

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final bool desktop = desktopOf(context);
    final double h = height ?? defaultHeightOf(context);
    final bool multiline = labelMaxLines > 1;
    final Color foreground = !enabled
        ? apple.tertiaryLabel
        : (active ? apple.accent : apple.label);
    final Color chevron = !enabled
        ? apple.tertiaryLabel
        : (active ? apple.accent : apple.secondaryLabel);
    final TextStyle style =
        (Theme.of(context).textTheme.bodyMedium ?? const TextStyle()).copyWith(
          fontSize: desktop ? 13 : 15,
          fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          color: foreground,
          height: 1.2,
          leadingDistribution: TextLeadingDistribution.even,
        );
    Widget text = Text(
      label,
      maxLines: labelMaxLines,
      softWrap: multiline,
      overflow: multiline ? null : TextOverflow.ellipsis,
      style: style,
    );
    if (expand) {
      text = Expanded(child: text);
    } else if (maxLabelWidth != null) {
      text = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxLabelWidth!),
        child: text,
      );
    } else {
      text = Flexible(child: text);
    }
    final Widget row = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      children: <Widget>[
        text,
        SizedBox(width: desktop ? 5 : 6),
        Icon(
          CupertinoIcons.chevron_up_chevron_down,
          size: desktop ? 10 : 12,
          color: chevron,
        ),
      ],
    );
    return AnimatedContainer(
      duration: fushiMotionDuration(context, FushiMotion.short),
      curve: FushiMotion.standard,
      height: multiline ? null : h,
      constraints: multiline ? BoxConstraints(minHeight: h) : null,
      padding: EdgeInsetsDirectional.only(
        start: desktop ? 8 : 14,
        end: desktop ? 6 : 11,
        top: multiline ? 6 : 0,
        bottom: multiline ? 6 : 0,
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
