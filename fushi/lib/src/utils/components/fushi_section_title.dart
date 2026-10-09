import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiAppleMetrics;

/// [FushiSectionTitle] 的两种层级。
enum FushiSectionTitleLevel {
  /// 分组标题：贴在一组列表 / 卡片上方的小标题（设置分组、详情页「信息」组）。
  /// MD3 = titleSmall 主色 w600；Apple = 13 号 semibold secondaryLabel 灰字
  /// （即 [FushiTypeRoles.sectionLabel]，与 `SettingsSectionHeader` 同一个样式）。
  group,

  /// 内容区块标题：页面里一段内容的标题（「选集」「章节（12）」「最近添加」）。
  /// MD3 Expressive = titleLarge w600 onSurface；Apple = iOS Title 2（22 号粗体）
  /// label 色、收紧字距（App Store / 音乐「区块大标题」口径）。
  content,
}

/// 统一的分组 / 区块标题。
///
/// 取代页面里散落的手写小标题（`Text(..., style: titleMedium)`、
/// `titleLarge.copyWith(fontWeight: w700)`、`labelLarge.copyWith(color: primary)`
/// 等），让两套设计系统的标题层级各自一处决定。可选 [trailing] 放在同一行
/// 末尾（如「查看全部」文字按钮、计数、排序菜单），基线对齐、标题单行省略。
///
/// 用法：
/// ```dart
/// FushiSectionTitle('选集')                                     // 内容区块
/// FushiSectionTitle.group('外观')                               // 分组标题
/// FushiSectionTitle('最近添加', trailing: FushiTextButton(...))  // 带尾部动作
/// ```
///
/// 内边距默认只给上下（[padding] 可覆盖）：横向对齐交给所在列表 / 页面的
/// 页边距，避免标题与下方内容左缘错位。
class FushiSectionTitle extends StatelessWidget {
  const FushiSectionTitle(
    this.text, {
    super.key,
    this.trailing,
    this.padding,
    this.level = FushiSectionTitleLevel.content,
  });

  /// 分组标题（[FushiSectionTitleLevel.group]）。
  const FushiSectionTitle.group(
    this.text, {
    super.key,
    this.trailing,
    this.padding,
  }) : level = FushiSectionTitleLevel.group;

  final String text;

  /// 行尾控件（同一行右侧）；null 不占位。
  final Widget? trailing;

  /// 外边距；null 按层级给默认上下间距（content 上 24 下 8，group 上 16 下 6）。
  final EdgeInsetsGeometry? padding;

  final FushiSectionTitleLevel level;

  /// 当前设计系统下该层级的标题样式（供需要自绘标题的地方复用同一口径）。
  static TextStyle styleOf(BuildContext context, FushiSectionTitleLevel level) {
    final ThemeData theme = Theme.of(context);
    if (level == FushiSectionTitleLevel.group) {
      return FushiDesignTokens.of(context).type.sectionLabel;
    }
    // Apple 色板扩展只挂在 Apple 设计系统的主题上（墨水屏不挂），据此分流。
    final FushiAppleColors? apple = theme.extension<FushiAppleColors>();
    if (apple != null) {
      // titleLarge 即 22 号（iOS Title 2 同字号），Apple 口径加粗、收紧字距。
      final bool desktop = FushiAppleMetrics.of(context).desktop;
      return (theme.textTheme.titleLarge ?? const TextStyle()).copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: desktop ? -0.2 : -0.35,
        height: 1.25,
        color: apple.label,
      );
    }
    return (theme.textTheme.titleLarge ?? const TextStyle()).copyWith(
      fontWeight: FontWeight.w600,
      color: theme.colorScheme.onSurface,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool group = level == FushiSectionTitleLevel.group;
    final EdgeInsetsGeometry resolvedPadding =
        padding ??
        (group
            ? const EdgeInsets.only(top: 16, bottom: 6)
            : const EdgeInsets.only(top: 24, bottom: 8));
    final Widget title = Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: styleOf(context, level),
    );
    return Padding(
      padding: resolvedPadding,
      child: Semantics(
        header: true,
        child: trailing == null
            ? title
            : Row(
                children: <Widget>[
                  Expanded(child: title),
                  const SizedBox(width: 8),
                  trailing!,
                ],
              ),
      ),
    );
  }
}
