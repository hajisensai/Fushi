/// Apple（Cupertino，iOS 27 / macOS 27）发现页的行件（「浏览」页方案 A，设计稿
/// `build/browse_cupertino_design/index.html`）：
///
/// - [AppleDiscoverySourceGlyph]：中性灰圆角方块 glyph（有站点图标用图标，没有就写
///   名字首两个字母），不按来源 id 取色；
/// - [AppleDiscoverySourceRow]：一个来源一行 inset grouped 行，能力 / 出处降为副行
///   文字，加载失败时副行变红、行尾换「重试」；
/// - [AppleDiscoveryAddSourceRow]：组末强调色「添加来源…」行；
/// - [AppleDiscoveryPullDown]：第三层筛选的 pull-down 按钮（按钮上写当前值）；
/// - [AppleDiscoveryFootnote]：分组下的说明文字（原引导提示条降级而来）。
///
/// 颜色只用 [appleColorsOf] 系统色（label / fill / 唯一强调色 / 状态色）。只在
/// `isGlassDesign` 为真时由各发现页选用；M3E 不经过这里。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/pages/implementations/library_filter_dropdown.dart'
    show LibraryFilterChip;
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_generated_cover.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 列表行 glyph 的边长：iOS 30、macOS 24（设计稿间距表「列表行」）。
double appleDiscoveryRowGlyphSize(BuildContext context) =>
    FushiAppleMetrics.of(context).desktop
    ? 24 * fushiAppleMacScale(context)
    : 30;

/// 中性灰圆角方块 glyph：systemFill 底 + secondaryLabel 首字母；有 [icon] 时铺图标。
/// 纯装饰，不进语义树（名称在旁边另有一份）。
class AppleDiscoverySourceGlyph extends StatelessWidget {
  const AppleDiscoverySourceGlyph({
    required this.name,
    this.icon,
    this.size,
    this.iconData,
    super.key,
  });

  final String name;

  /// 站点图标；null = 首字母。
  final ImageProvider? icon;

  /// 用字形代替首字母（文件夹行、添加行）。
  final IconData? iconData;

  /// 边长；null = [appleDiscoveryRowGlyphSize]。
  final double? size;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors colors = appleColorsOf(context);
    final double side = size ?? appleDiscoveryRowGlyphSize(context);
    final BorderRadius radius = BorderRadius.circular(side * 0.26);
    final String initials = fushiGeneratedCoverInitials(name);
    final Widget fallback = iconData != null
        ? Center(
            child: FushiIcon(
              iconData!,
              size: side * 0.58,
              color: colors.secondaryLabel,
            ),
          )
        : Center(
            child: Padding(
              padding: EdgeInsets.all(side * 0.18),
              child: FittedBox(
                fit: BoxFit.contain,
                child: Text(
                  initials.isEmpty ? '?' : initials,
                  maxLines: 1,
                  textScaler: TextScaler.noScaling,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    height: 1,
                    letterSpacing: 0.3,
                    color: colors.secondaryLabel,
                  ),
                ),
              ),
            ),
          );
    final ImageProvider? image = icon;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: side,
        child: ClipRSuperellipse(
          borderRadius: radius,
          child: ColoredBox(
            color: colors.fill,
            child: image == null
                ? fallback
                : Image(
                    image: image,
                    fit: BoxFit.cover,
                    errorBuilder:
                        (BuildContext context, Object _, StackTrace? __) =>
                            fallback,
                  ),
          ),
        ),
      ),
    );
  }
}

/// 来源副行：能力（可浏览 / 仅搜索）、出处（预置 / 用户添加）等以「 · 」连成一行。
String appleDiscoveryCaption(Iterable<String> parts) =>
    parts.where((String p) => p.trim().isNotEmpty).join(' · ');

/// 一个来源的 inset grouped 行：glyph + 源名 + 副行 + 行尾 chevron（点进来源）。
/// [failed] 时副行写红色「无法连接」，行尾换「重试」文字钮。
class AppleDiscoverySourceRow extends StatelessWidget {
  const AppleDiscoverySourceRow({
    required this.name,
    required this.onTap,
    this.caption,
    this.icon,
    this.failed = false,
    this.onRetry,
    this.focusId,
    this.trailing,
    super.key,
  });

  final String name;
  final VoidCallback onTap;

  /// 副行（[appleDiscoveryCaption] 拼好的能力 / 出处）。
  final String? caption;
  final ImageProvider? icon;
  final bool failed;
  final VoidCallback? onRetry;
  final FushiFocusId? focusId;

  /// 覆盖行尾（如行 ⋯ 菜单）；null = chevron / 重试。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors colors = appleColorsOf(context);
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final VoidCallback? retry = onRetry;
    final Widget tail =
        trailing ??
        (failed && retry != null
            ? _AppleTextAction(label: t.retry, onTap: retry)
            : const FushiAppleChevron());
    return FushiPressScale(
      child: AdaptiveSettingsRow(
        focusId: focusId,
        title: name,
        titleMaxLines: 1,
        leading: AppleDiscoverySourceGlyph(name: name, icon: icon),
        subtitleLeading: failed
            ? Text(
                t.discovery_source_load_failed,
                style: metrics
                    .subtitleStyle(context)
                    .copyWith(color: colors.destructive),
              )
            : null,
        subtitle: failed ? null : caption,
        subtitleMaxLines: 1,
        trailing: tail,
        onTap: onTap,
      ),
    );
  }
}

/// 组末强调色「添加来源…」行（去处由调用方给：设置 › 在线服务 / 扩展页）。
class AppleDiscoveryAddSourceRow extends StatelessWidget {
  const AppleDiscoveryAddSourceRow({
    required this.onTap,
    this.subtitle,
    super.key,
  });

  final VoidCallback onTap;

  /// 去处说明（「管理来源」/ iOS「连接服务器」）。
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final double side = appleDiscoveryRowGlyphSize(context);
    return FushiPressScale(
      child: AdaptiveSettingsRow(
        key: const ValueKey<String>('discovery_guide_manage'),
        focusId: const FushiFocusId('discovery-add-source'),
        title: '${t.discovery_source_add_title}…',
        subtitle: subtitle,
        subtitleMaxLines: 1,
        leading: SizedBox.square(
          dimension: side,
          child: Center(
            child: FushiIcon(
              FushiIcons.add,
              size: side * 0.75,
              color: appleColorsOf(context).accent,
            ),
          ),
        ),
        onTap: onTap,
      ),
    );
  }
}

/// 行尾的强调色文字动作（「重试」）：命中区撑满行高、不自成焦点停靠点（行本身
/// 可聚焦，Enter 走行的 onTap）。
class _AppleTextAction extends StatelessWidget {
  const _AppleTextAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    return Semantics(
      button: true,
      child: FushiPressScale(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Text(
              label,
              style: metrics
                  .titleStyle(context)
                  .copyWith(color: appleColorsOf(context).accent),
            ),
          ),
        ),
      ),
    );
  }
}

/// 第三层筛选的 pull-down 按钮（拍板点 4）：按钮上写当前值（「小说 ⌄」），点开
/// 是公共菜单（`showFushiMenu`，当前项打勾）。外观是公共 Apple pop-up 按钮面
/// （[LibraryFilterChip] 的 Apple 分支），焦点 / Enter 由 [FushiOverflowMenu] 给。
class AppleDiscoveryPullDown<T> extends StatelessWidget {
  const AppleDiscoveryPullDown({
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onSelected,
    required this.keyPrefix,
    this.active = false,
    this.tooltip,
    this.chipLabelOf,
    super.key,
  });

  final List<T> values;
  final T selected;
  final String Function(T value) labelOf;

  /// 按钮上显示的文案（null = 同 [labelOf]）：「全部」项在按钮上显示维度名
  /// （「年份 ⌄」）时用。
  final String Function(T value)? chipLabelOf;
  final ValueChanged<T> onSelected;

  /// 菜单项 key 前缀（`<prefix>_<index>`），测试与焦点定位用。
  final String keyPrefix;

  /// 筛选已偏离默认值（灰底加深一档、semibold）。
  final bool active;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return FushiOverflowMenu<T>(
      key: ValueKey<String>('$keyPrefix-pull-down'),
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      onSelected: onSelected,
      items: <PopupMenuEntry<T>>[
        for (int i = 0; i < values.length; i++)
          FushiPopupMenuItem<T>(
            key: ValueKey<String>('${keyPrefix}_$i'),
            value: values[i],
            label: labelOf(values[i]),
            selected: values[i] == selected,
          ),
      ],
      child: LibraryFilterChip(
        label: (chipLabelOf ?? labelOf)(selected),
        active: active,
      ),
    );
  }
}

/// 分组下的说明文字（脚注）：iOS footnote 13 / macOS 11，secondaryLabel，左右与
/// 分组卡内文字对齐。
class AppleDiscoveryFootnote extends StatelessWidget {
  const AppleDiscoveryFootnote({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        metrics.rowHorizontal,
        7,
        metrics.rowHorizontal,
        0,
      ),
      child: Text(text, style: metrics.footnoteStyle(context)),
    );
  }
}

/// 页边：Apple 档 iOS 16 / macOS 24（设计稿间距表「页边」）。
double appleDiscoveryPageInset(BuildContext context) =>
    fushiAppleUsesMacMetrics(context)
    ? 24
    : FushiDesignTokens.of(context).spacing.page;

/// lockup 获取式按钮的「浏览」文案（`discovery_source_action_browse`）。
String appleDiscoveryBrowseLabel() => t.discovery_source_action_browse;
