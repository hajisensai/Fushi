import 'package:fading_edge_scrollview/fading_edge_scrollview.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/shortcuts/gamepad_forwarding_action.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_dropdown.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi/src/utils/components/fushi_focusable.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_option_selection_page.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show FushiPlainButton, fushiClearGlassBezel, fushiClearGlassSettings;
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart'
    show showFushiMenu;
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart'
    show FushiAppleSwitch, FushiSegmentedButton;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassStepper, GlassTextField;

class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader(this.text, {super.key, this.padding});
  final String text;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context) && !isCupertinoPlatform(context)) {
      // Apple：与 [AdaptiveSettingsSection] 分组外标题同一口径——13 号 semibold
      // secondaryLabel，缩进到分组行文字起点（桌面 10 / 触屏 16）。调用方显式
      // 传的 padding 照旧生效（它们按自己所在容器排过版）。
      final FushiAppleMetrics apple = FushiAppleMetrics.of(context);
      return Padding(
        padding: padding ??
            EdgeInsets.fromLTRB(
              apple.desktop ? 10 : 16,
              16,
              16,
              apple.desktop ? 6 : 7,
            ),
        child: Text(text, style: settingsAppleSectionTitleStyle(context)),
      );
    }
    return Padding(
      padding: padding ?? const EdgeInsets.only(top: 16, bottom: 4),
      child: Text(text, style: FushiDesignTokens.of(context).type.sectionLabel),
    );
  }
}

/// Apple 分组外标题样式（13 号 semibold secondaryLabel）。[SettingsSectionHeader]
/// 与 [AdaptiveSettingsSection] 的分组外标题共用这一处。
TextStyle settingsAppleSectionTitleStyle(BuildContext context) =>
    FushiAppleMetrics.of(context)
        .footnoteStyle(context)
        .copyWith(fontWeight: FontWeight.w600);

const kSettingsSegmentedStyle = ButtonStyle(
  visualDensity: VisualDensity.compact,
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

const int kSettingsRowTitleMaxLines = 2;

/// 说明文字（subtitle）在**显式要求压缩**时的推荐行数上限。
///
/// BUG-1184 起这不再是默认值：[AdaptiveSettingsRow] 默认不钳说明文字的行数
/// （见 [AdaptiveSettingsRow.subtitleMaxLines]），因为设置行行高本就自由，
/// 硬钳 3 行只会在窄屏上把说明尾部（往往是路径、警告、生效条件）吃掉。
/// 只有密度敏感、确实需要固定行数的列表才显式传这个常量。
const int kSettingsRowSubtitleMaxLines = 3;
const double kSettingsStepperValueWidth = 72;

/// stepper 行 trailing（`−` / 读数 / `+`）的固有宽度：两个
/// `VisualDensity.compact` 的 [IconButton]（48 − 8 = 40）+ [Wrap] 的两处 4
/// 间距 + [kSettingsStepperValueWidth] 读数槽。读数走 [FittedBox] 缩放，所以
/// 这个盒子不随文字缩放变宽。
///
/// 之所以要写成常量：它是 [AdaptiveSettingsRow] 堆叠判据的输入之一（见
/// [AdaptiveSettingsRow.trailingWidth]）——判「这行还放不放得下标题」必须知道
/// trailing 到底占多宽，靠经验常数猜会把标题削没（BUG-2550）。
const double kSettingsStepperTrailingWidth =
    kSettingsStepperValueWidth + 2 * (40 + 4);

/// 行内布局下，标题至少要拿到的宽度（1x；随文字缩放放大）。
///
/// 标题默认 2 行 + ellipsis（[kSettingsRowTitleMaxLines]），低于这个宽度就只剩
/// 开头一两个字加省略号，配置项等于失效。判据与 BUG-1184 / BUG-1537 对说明文字
/// 的判断同一条：截断即失效，宁可让控件换到下一行（[AdaptiveSettingsRow] 本来就
/// 有这条堆叠退路）。96dp ≈ 7 个 CJK 字（bodyMedium 14）。
const double kSettingsRowLabelMinWidth = 96;
const double kSettingsPickerDefaultWidth = 220;
const double kSettingsPickerMinInlineWidth = 120;

/// An [AdaptiveSettingsPickerRow] with more options than this renders as a
/// chevron navigation row that pushes a bounded full-page selector instead of
/// an inline overlay dropdown / action sheet — the overlay's anchored height
/// would otherwise run a long list (app languages, dozens of Anki decks) off
/// the screen edge. Short option sets keep the inline control.
const int kSettingsPickerInlineLimit = 8;

class AdaptiveSettingsScaffold extends StatelessWidget {
  const AdaptiveSettingsScaffold({
    required this.title,
    required this.children,
    super.key,
    this.actions,
    this.padding,
    this.bottom,
  });

  final Widget title;
  final List<Widget> children;
  final List<Widget>? actions;
  final EdgeInsetsGeometry? padding;

  /// 钉在列表下方、不随内容滚动的一条（多选态的批量操作栏用）。为空时布局与
  /// 加它之前逐字相同。
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    final EdgeInsets mediaPadding = MediaQuery.of(context).padding;
    final EdgeInsetsGeometry listPadding = padding ??
        EdgeInsets.fromLTRB(
          cupertino ? 12 : 16,
          cupertino ? 10 : 8,
          cupertino ? 12 : 16,
          8 + mediaPadding.bottom,
        );

    if (cupertino) {
      return CupertinoPageScaffold(
        backgroundColor: CupertinoColors.systemGroupedBackground.resolveFrom(
          context,
        ),
        child: CustomScrollView(
          slivers: <Widget>[
            CupertinoSliverNavigationBar(
              largeTitle: title,
              trailing: actions != null && actions!.isNotEmpty
                  ? Row(mainAxisSize: MainAxisSize.min, children: actions!)
                  : null,
            ),
            SliverPadding(
              padding: listPadding,
              sliver: SliverList(delegate: SliverChildListDelegate(children)),
            ),
          ],
        ),
      );
    }

    final Widget list = ListView(padding: listPadding, children: children);
    return FushiToolScaffold.customTitle(
      title: title,
      actions: actions ?? const <Widget>[],
      body: bottom == null
          ? list
          : Column(
              children: <Widget>[Expanded(child: list), bottom!],
            ),
    );
  }
}

enum SettingsSectionTitlePlacement { outside, inside }

class AdaptiveSettingsSurface extends StatelessWidget {
  const AdaptiveSettingsSurface({
    required this.child,
    super.key,
    this.title,
    this.color,
    this.contentPadding = EdgeInsets.zero,
    this.titleTrailing,
    this.onTitleTap,
    this.borderRadius,
  });

  final Widget child;
  final String? title;
  final Color? color;
  final EdgeInsetsGeometry contentPadding;

  /// MD3 卡片圆角覆盖；null = `tokens.radii.groupRadius`。分段分组列表
  /// （[AdaptiveSettingsSection] 的 MD3 形态）按行在组里的位置给不同圆角。
  final BorderRadius? borderRadius;

  /// 内嵌标题右侧的尾随控件（如折叠 section 的展开箭头）。仅当 [title] 非空时渲染。
  final Widget? titleTrailing;

  /// 非空时把内嵌标题头变成可点击 + 可焦点驱动（Enter/手柄 A）的整头，用于折叠
  /// section 的展开/收起。为空时标题头是纯装饰文字，行为不变。
  final VoidCallback? onTitleTap;

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (title != null && title!.isNotEmpty)
          _buildContainedTitle(context, tokens, cupertino),
        Padding(padding: contentPadding, child: child),
      ],
    );

    if (cupertino) {
      return ClipRRect(
        borderRadius: tokens.radii.groupRadius,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
              context,
            ),
            borderRadius: tokens.radii.groupRadius,
          ),
          child: content,
        ),
      );
    }

    // 设置分组卡靠「填充分层」表达边界，不再在填充之上再叠一圈 1px
    // outlineVariant 描边：MD3 的 filled card 不描边，填充 + 描边是两套并存的
    // 边界信号。设置页一屏里原本还有输入框与分段控件的 colorScheme.outline
    // 描边（比卡片描边深一档）和 0.5px 行分隔线，三种强度的线叠在一起就是
    // 「描边很怪」的来源。
    //
    // eink 例外由 FushiCard 内部兜住：eink scheme 把所有 surface container 塌
    // 缩成背景色，卡片没有可分层的填充，此时它自己补一圈实描边
    // （fushi_material_components.dart 的 eink 分支），这里不传 borderColor。
    if (isGlassDesign(context)) {
      // 「玻璃」设计系统：iOS 26 inset grouped 分组——实色
      // secondarySystemGroupedBackground、圆角 iOS 24 / 桌面 12，不是玻璃。
      return FushiCard(
        padding: EdgeInsets.zero,
        borderRadius: FushiAppleMetrics.of(context).groupBorderRadius,
        color: color,
        child: content,
      );
    }
    return FushiCard(
      padding: EdgeInsets.zero,
      borderRadius: borderRadius ?? tokens.radii.groupRadius,
      color: color ?? tokens.surfaces.card,
      child: content,
    );
  }

  Widget _buildContainedTitle(
    BuildContext context,
    FushiDesignTokens tokens,
    bool cupertino,
  ) {
    // 折叠头（onTitleTap != null）是带尾随箭头的可点整头：箭头在 Row 里按
    // crossAxisAlignment.center 垂直居中，标题必须用上下对称 padding 才能与箭头
    // 在同一垂直中线上（否则上重下轻的标签 padding 会让标题比箭头低几像素）。
    // 静态内嵌小标题（onTitleTap == null）是行上方的标签，保持上重下轻贴住下方
    // 设置行，行为不变。
    final bool interactive = onTitleTap != null;
    final bool glassDesign = isGlassDesign(context);
    final Widget label = glassDesign && !cupertino
        ? Padding(
            // 「玻璃」设计系统：分组内标题是 13 号 secondaryLabel（iOS 分组
            // 标题口径；中文不做大写变换）。
            padding: interactive
                ? const EdgeInsets.fromLTRB(16, 12, 16, 12)
                : const EdgeInsets.fromLTRB(16, 10, 16, 2),
            child: Text(
              title!,
              style: FushiAppleMetrics.of(context).footnoteStyle(context),
            ),
          )
        : cupertino
        ? Padding(
            padding: interactive
                ? const EdgeInsets.fromLTRB(16, 10, 16, 10)
                : const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Text(
              title!.toUpperCase(),
              style: tokens.type.metadata.copyWith(
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
                fontWeight: FontWeight.w600,
              ),
            ),
          )
        : SettingsSectionHeader(
            title!,
            // MD3 分段分组列表：折叠头自己就是一张分段卡，与行同一个左缘（16）、
            // 同一档竖直留白。
            padding: interactive
                ? EdgeInsets.symmetric(
                    horizontal: tokens.spacing.rowHorizontal,
                    vertical: tokens.spacing.rowVertical + 4,
                  )
                : const EdgeInsets.fromLTRB(12, 10, 12, 4),
          );

    if (!interactive) return label;

    // 折叠头：标题 + 尾随箭头拼成整头，整头可点、可焦点驱动展开/收起。焦点驱动走
    // 与设置行一致的 _SettingsRowFocusTarget（Enter/手柄 A 触发 Activate），保证纯
    // 手柄/键盘用户也能展开折叠 section；无焦点根时退回平台原生可点组件。
    final Widget header = Row(
      children: <Widget>[
        Expanded(child: label),
        if (titleTrailing != null)
          Padding(
            padding: EdgeInsets.only(
              right: cupertino
                  ? 12
                  : (glassDesign ? 16 : tokens.spacing.rowHorizontal),
            ),
            child: titleTrailing!,
          ),
      ],
    );
    final bool hasFocusRoot = FushiFocusRoot.maybeControllerOf(context) != null;
    // 玻璃：iOS 单元格口径的实色行（按下 systemFill）。无焦点根时行自己是 Tab
    // 停靠点（Enter / 手柄 A 展开收起），有焦点根时交给外层焦点目标。
    final Widget tappable = glassDesign && !cupertino
        ? FushiAppleRow(
            onTap: onTitleTap,
            focusable: !hasFocusRoot,
            child: header,
          )
        : cupertino
        ? GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTitleTap,
            child: glassDesign
                ? FushiGlassPressHighlight(child: header)
                : header,
          )
        : InkWell(onTap: onTitleTap, child: header);
    if (!hasFocusRoot) {
      return cupertino
          ? FushiFocusable(
              onTap: onTitleTap!,
              borderRadius: BorderRadius.zero,
              child: header,
            )
          : tappable;
    }
    return _SettingsRowFocusTarget(
      onTap: onTitleTap!,
      autoHome: false,
      child: tappable,
    );
  }
}

/// MD3 分段分组列表：组首 / 组尾外侧的大圆角。
const double kSettingsSegmentOuterRadius = 24;

/// MD3 分段分组列表：分段之间（内侧）的小圆角。
const double kSettingsSegmentInnerRadius = 4;

/// MD3 分段分组列表：相邻分段卡之间的缝。
const double kSettingsSegmentGap = 2;

/// 分段分组列表里第 [index] 段（共 [count] 段）的圆角：外侧大、内侧小，独段
/// 四角都大。导航列表、搜索结果等自己拼分段卡的调用点也走这里，组内圆角规则
/// 只有这一处。
BorderRadius settingsSegmentRadius(int index, int count) {
  const Radius outer = Radius.circular(kSettingsSegmentOuterRadius);
  const Radius inner = Radius.circular(kSettingsSegmentInnerRadius);
  final bool first = index <= 0;
  final bool last = index >= count - 1;
  return BorderRadius.vertical(
    top: first ? outer : inner,
    bottom: last ? outer : inner,
  );
}

class AdaptiveSettingsSection extends StatefulWidget {
  const AdaptiveSettingsSection({
    required this.children,
    super.key,
    this.title,
    this.titlePlacement = SettingsSectionTitlePlacement.outside,
    this.surfaceColor,
    this.collapsible = false,
    this.initiallyExpanded = true,
    this.expanded,
    this.onExpansionChanged,
    this.summary,
  });

  final String? title;
  final List<Widget> children;
  final SettingsSectionTitlePlacement titlePlacement;
  final Color? surfaceColor;

  /// 为 true 时内嵌标题头带展开箭头、可点击折叠本 section 的内容。仅在标题内嵌
  /// （[SettingsSectionTitlePlacement.inside]）且 [title] 非空时才成立；否则退回
  /// 普通静态渲染。默认 false，保证所有既有调用点行为不变。
  final bool collapsible;

  /// 折叠 section 的初始展开态；仅 [collapsible] 为 true 时有意义。搜索命中折叠
  /// section 内的项时由上层传 true 强制展开定位。
  final bool initiallyExpanded;

  /// Optional controlled state. Only explicit user toggles call the callback.
  final bool? expanded;
  final ValueChanged<bool>? onExpansionChanged;
  final String? summary;

  @override
  State<AdaptiveSettingsSection> createState() =>
      _AdaptiveSettingsSectionState();
}

class _AdaptiveSettingsSectionState extends State<AdaptiveSettingsSection> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  void didUpdateWidget(AdaptiveSettingsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 搜索命中折叠 section 时，上层把 initiallyExpanded 由 false 翻成 true——同一
    // widget 身份下的 rebuild 里据此强制展开定位；用户手动收/展的态在无此翻转时保留。
    if (widget.collapsible &&
        widget.initiallyExpanded &&
        !oldWidget.initiallyExpanded) {
      _expanded = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.children.isEmpty) return const SizedBox.shrink();

    final bool cupertino = isCupertinoPlatform(context);
    final bool glassDesign = isGlassDesign(context) && !cupertino;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool titleInside =
        widget.titlePlacement == SettingsSectionTitlePlacement.inside;
    final bool collapsible = widget.collapsible &&
        titleInside &&
        (widget.title?.isNotEmpty ?? false);
    final bool expanded = widget.expanded ?? _expanded;
    // MD3：Android 16「设置」的分段分组列表（每行一张卡）。透明底的调用点
    // （分组只做分段与标题、填充交给外层卡）维持原来的单卡 + 分隔线形态。
    if (!cupertino &&
        !glassDesign &&
        widget.surfaceColor != Colors.transparent) {
      return _buildMd3Segmented(
        context,
        tokens,
        collapsible: collapsible,
        expanded: expanded,
      );
    }
    final List<Widget> rows = _withDividers(context, widget.children);
    final Widget rowsColumn = Column(
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );

    final Widget group;
    if (collapsible) {
      group = AdaptiveSettingsSurface(
        title: widget.title,
        color: widget.surfaceColor,
        onTitleTap: () {
          final bool next = !expanded;
          setState(() => _expanded = next);
          widget.onExpansionChanged?.call(next);
        },
        titleTrailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (widget.summary?.isNotEmpty ?? false)
              Flexible(
                child: Text(
                  widget.summary!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.metadata,
                ),
              ),
            AnimatedRotation(
              // 玻璃：iOS 披露箭头 chevron_forward 展开时转到朝下（1/4 圈）。
              turns: expanded ? (glassDesign ? 0.25 : 0.5) : 0.0,
              // eink 下动画归零（连续重绘=残影），箭头直接跳到目标朝向。
              duration: einkSafeDuration(
                context,
                const Duration(milliseconds: 180),
              ),
              child: glassDesign
                  ? const FushiAppleChevron()
                  : FushiIcon(
                      cupertino
                          ? CupertinoIcons.chevron_down
                          : Icons.expand_more,
                      size: cupertino ? 16 : 22,
                      color: cupertino
                          ? CupertinoColors.tertiaryLabel.resolveFrom(context)
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
            ),
          ],
        ),
        // 收起时行不入树（不可聚焦、不参与焦点驱动），只保留标题头；用 AnimatedSize
        // 平滑高度过渡，ClipRect 防过渡帧溢出。eink 下高度过渡同样归零。
        child: ClipRect(
          child: AnimatedSize(
            duration: einkSafeDuration(
              context,
              const Duration(milliseconds: 180),
            ),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child:
                expanded ? rowsColumn : const SizedBox(width: double.infinity),
          ),
        ),
      );
    } else {
      group = AdaptiveSettingsSurface(
        title: titleInside ? widget.title : null,
        color: widget.surfaceColor,
        child: rowsColumn,
      );
    }

    final FushiAppleMetrics? apple =
        glassDesign ? FushiAppleMetrics.of(context) : null;
    return Padding(
      // 玻璃：iOS inset grouped 分组之间的大间距（分组标题落在这段间距里）。
      padding: EdgeInsets.only(
        bottom: apple?.groupSpacing ?? (cupertino ? 14 : 12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (!titleInside && widget.title != null && widget.title!.isNotEmpty)
            apple != null
                ? Padding(
                    // 分组外标题：13 号 semibold secondaryLabel（macOS 系统设置
                    // 的分组标题口径），与行文字起点对齐缩进。
                    padding: EdgeInsets.fromLTRB(
                      apple.desktop ? 10 : 16,
                      0,
                      16,
                      apple.desktop ? 6 : 7,
                    ),
                    child: Text(
                      widget.title!,
                      style: settingsAppleSectionTitleStyle(context),
                    ),
                  )
                : cupertino
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                    child: Text(
                      widget.title!.toUpperCase(),
                      style: tokens.type.metadata.copyWith(
                        color: CupertinoColors.secondaryLabel.resolveFrom(
                          context,
                        ),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                : SettingsSectionHeader(
                    widget.title!,
                    padding: const EdgeInsets.only(bottom: 6),
                  ),
          group,
        ],
      ),
    );
  }

  /// MD3 分段分组列表（Android 16 / Material 3 Expressive 的 segmented list）：
  /// 组内每一行各是一张卡，卡与卡之间留 [kSettingsSegmentGap]；首行上圆角
  /// [kSettingsSegmentOuterRadius]、下圆角 [kSettingsSegmentInnerRadius]，中间行
  /// 四角都是小圆角，末行反过来，独行四角都是大圆角。行与行之间不再画分隔线——
  /// 分段的缝本身就是分隔。分组标题（titleSmall、primary、w600）在组上方；可折叠
  /// 分组的折叠头自己是第一张分段卡。墨水屏下卡片底塌缩成背景色，FushiCard 给每张
  /// 分段卡补实描边，分段边界照样可辨。
  Widget _buildMd3Segmented(
    BuildContext context,
    FushiDesignTokens tokens, {
    required bool collapsible,
    required bool expanded,
  }) {
    final String? title = widget.title;
    final bool hasTitle = title != null && title.isNotEmpty;
    final List<Widget> rows = widget.children;
    final int rowCount = rows.length;
    final int headerCount = collapsible ? 1 : 0;
    final int visibleCount = headerCount + (!collapsible || expanded ? rowCount : 0);

    Widget segment(int position, Widget child, {Key? key}) =>
        AdaptiveSettingsSurface(
          key: key,
          color: widget.surfaceColor,
          borderRadius: settingsSegmentRadius(position, visibleCount),
          child: child,
        );

    List<Widget> rowSegments() => <Widget>[
          for (int i = 0; i < rowCount; i++) ...<Widget>[
            if (i > 0 || collapsible)
              const SizedBox(height: kSettingsSegmentGap),
            segment(headerCount + i, rows[i]),
          ],
        ];

    final Widget group;
    if (collapsible) {
      final Widget header = AdaptiveSettingsSurface(
        title: title,
        color: widget.surfaceColor,
        borderRadius: settingsSegmentRadius(0, visibleCount),
        onTitleTap: () {
          final bool next = !expanded;
          setState(() => _expanded = next);
          widget.onExpansionChanged?.call(next);
        },
        titleTrailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (widget.summary?.isNotEmpty ?? false)
              Flexible(
                child: Text(
                  widget.summary!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.metadata,
                ),
              ),
            AnimatedRotation(
              turns: expanded ? 0.5 : 0.0,
              // eink 下动画归零（连续重绘=残影）。
              duration: einkSafeDuration(
                context,
                const Duration(milliseconds: 180),
              ),
              child: FushiIcon(
                Icons.expand_more,
                size: 22,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        child: const SizedBox(width: double.infinity),
      );
      group = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          header,
          // 收起时行不入树（不可聚焦、不参与焦点驱动）。
          ClipRect(
            child: AnimatedSize(
              duration: einkSafeDuration(
                context,
                const Duration(milliseconds: 180),
              ),
              curve: Curves.easeInOut,
              alignment: Alignment.topCenter,
              child: expanded
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: rowSegments(),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ),
        ],
      );
    } else {
      group = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: rowSegments(),
      );
    }

    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.spacing.card),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // 不可折叠分组的标题一律在组上方（内嵌位置在分段形态下没有「卡内
          // 顶部」可放）。
          if (hasTitle && !collapsible)
            Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spacing.rowHorizontal,
                0,
                tokens.spacing.rowHorizontal,
                tokens.spacing.gap,
              ),
              child: Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          group,
        ],
      ),
    );
  }

  List<Widget> _withDividers(BuildContext context, List<Widget> rows) {
    final bool cupertino = isCupertinoPlatform(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Color dividerColor = cupertino
        ? CupertinoColors.separator.resolveFrom(context)
        : Theme.of(context).colorScheme.outlineVariant;
    final List<Widget> result = <Widget>[];
    final bool glassDesign = isGlassDesign(context);
    for (int i = 0; i < rows.length; i++) {
      if (i > 0 && glassDesign && !cupertino) {
        // 「玻璃」设计系统：iOS inset grouped 的行分隔——物理 1px separator，
        // 从上一行的文字起点开始缩进（有行首图标时从图标后开始）、右端顶到
        // 分组边缘；最后一行之后没有分隔线。
        final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
        final double iconInset = _settingsRowHasIcon(rows[i - 1])
            ? metrics.iconTileSize + tokens.spacing.gap + 4
            : 0;
        result.add(
          Container(
            height: fushiHairline(context),
            margin: EdgeInsetsDirectional.only(
              start: metrics.rowHorizontal + iconInset,
            ),
            color: appleColorsOf(context).separator,
          ),
        );
      } else if (i > 0) {
        result.add(
          Divider(
            height: 1,
            thickness: 0.5,
            indent: cupertino ? 16 : tokens.spacing.rowHorizontal,
            endIndent: cupertino ? 0 : tokens.spacing.rowHorizontal,
            color: dividerColor,
          ),
        );
      }
      result.add(rows[i]);
    }
    return result;
  }

  static bool _settingsRowHasIcon(Widget row) => settingsRowHasLeadingIcon(row);
}

/// 不改变行外观、只在设置行外面套一层的包装（schema 派发、搜索落点等）实现它，
/// 让 [settingsRowHasLeadingIcon] 能看穿包装判断里面那一行有没有行首图标。
abstract interface class SettingsRowIconProbe {
  /// 本包装渲染出来的设置行是否带行首图标。
  bool get settingsRowHasIcon;
}

/// 行是否渲染行首图标（决定 iOS inset grouped 分隔线的缩进起点）。认识共享设置
/// 行族，并看穿 [KeyedSubtree] 与实现了 [SettingsRowIconProbe] 的包装；其它自定义
/// 行按无图标处理（分隔线从文字内边距起）。
bool settingsRowHasLeadingIcon(Widget row) => switch (row) {
      SettingsRowIconProbe(:final bool settingsRowHasIcon) =>
        settingsRowHasIcon,
      KeyedSubtree(:final Widget child) => settingsRowHasLeadingIcon(child),
      AdaptiveSettingsRow(:final bool showIcon, :final IconData? icon) =>
        showIcon && icon != null,
      AdaptiveSettingsSwitchRow(:final bool showIcon, :final IconData? icon) =>
        showIcon && icon != null,
      AdaptiveSettingsSwitchActionRow(
        :final bool showIcon,
        :final IconData? icon,
      ) =>
        showIcon && icon != null,
      AdaptiveSettingsNavigationRow(
        :final bool showIcon,
        :final IconData? icon,
      ) =>
        showIcon && icon != null,
      AdaptiveSettingsPickerRow(:final bool showIcon, :final IconData? icon) =>
        showIcon && icon != null,
      AdaptiveSettingsStepperRow(:final bool showIcon, :final IconData? icon) =>
        showIcon && icon != null,
      AdaptiveSettingsSliderRow(:final bool showIcon, :final IconData? icon) =>
        showIcon && icon != null,
      _ => false,
    };

class AdaptiveSettingsRow extends StatelessWidget {
  const AdaptiveSettingsRow({
    required this.title,
    super.key,
    this.subtitle,
    this.icon,
    this.showIcon = false,
    this.trailing,
    this.onTap,
    this.controlBelow = false,
    this.trailingFlexible = false,
    this.trailingWidth,
    this.titleMaxLines,
    this.subtitleMaxLines,
    this.horizontalPadding,
  });

  /// 覆盖本行的水平内边距；null = 用标准 `tokens.spacing.rowHorizontal`（16）。
  ///
  /// 存在的理由：这 16px 此前是硬编码、无逃生口的，而它同时是「设置行左边缘」的
  /// 事实标准。于是任何**自带内边距**的嵌入式正文（`SettingsCustomItem` 的 builder、
  /// `SettingsDestination.body` 逃生口）一旦把自己整体缩进 16，里面夹杂的
  /// [AdaptiveSettingsRow] 就变成 32，与同卡片其它行错开——「下载设置左右间距和其他
  /// 设置不一样」正是这一类。给出显式 0 让调用方声明「外层已经缩进过了」。
  final double? horizontalPadding;

  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool showIcon;

  /// Overrides how many lines the title may occupy before ellipsizing. When
  /// null the shared [kSettingsRowTitleMaxLines] default (2) is used, so every
  /// existing call site keeps its current behavior. Pass a larger finite value
  /// (never null-as-unbounded) for rows whose title can legitimately be long -
  /// e.g. a table-of-contents chapter name on a narrow phone - so it wraps
  /// instead of being clipped at two lines.
  final int? titleMaxLines;

  /// Overrides how many lines the subtitle (说明文字) may occupy before
  /// ellipsizing. Null = 不限行数：说明文字整段显示。
  ///
  /// BUG-1184：此前说明文字硬钳 [kSettingsRowSubtitleMaxLines]（3 行）+ ellipsis，
  /// 且没有 [titleMaxLines] 那样的逃生口。设置行本身只有 minHeight 约束、行高自由，
  /// 所以这个上限不是为了防溢出，纯粹是自伤——窄屏上 label 被 `Expanded` 压窄，
  /// 一条稍长的说明（尤其带路径/警告拼接的那些）第 4 行起直接被吃掉，用户看不到
  /// 配置项到底在说什么。说明文字的唯一职责就是解释配置项，截断即等于失效，因此
  /// 默认改为不限；需要压缩的场景（列表密度敏感处）显式传一个有限值。
  ///
  /// BUG-1537：上面那次修复只改了 maxLines，说明文字的 `Text` 仍恒传
  /// `TextOverflow.ellipsis`——而 ellipsis 配 `maxLines: null` 在 Flutter 里不是
  /// 「不生效」，是把整段压成**单行**，比原来的 3 行更糟。所以 overflow 必须跟着
  /// 本字段联动（见 [_SettingsLabel]），守卫在
  /// `test/settings/settings_row_subtitle_wrap_test.dart`。
  final int? subtitleMaxLines;

  /// CONTRACT: [trailing] must be self-sizing. With [controlBelow] false it is
  /// placed as a NON-flex child of a Row that also has an `Expanded` label, so
  /// RenderFlex measures it with UNBOUNDED main-axis width. A trailing whose
  /// top-level layout demands width (a bare `Expanded`/`Flexible(tight)`, or a
  /// `DropdownMenu(expandedInsets: …)` without a bounding `SizedBox`) throws
  /// "RenderFlex children have non-zero flex but incoming width constraints are
  /// unbounded". Bound such controls (e.g. `SizedBox(width: …)`, as
  /// [AdaptiveSettingsPickerRow] does), set [trailingFlexible] for a control
  /// that should shrink-and-scroll, or pass them via [controlBelow] instead.
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool controlBelow;

  /// When true (and [controlBelow] is false), [trailing] is hosted as a
  /// `Flexible(fit: loose)` child of the inline Row instead of a non-flex one,
  /// so it receives BOUNDED main-axis constraints. Use this for an intrinsically
  /// wide control wrapped in a horizontal scroll view (e.g. a `SegmentedButton`
  /// in [AdaptiveSettingsSegmentedRow]): with bounded width the scroll view
  /// actually scrolls instead of overflowing the row. Self-sizing controls
  /// (switches, steppers) must leave this false so the label stays greedy.
  final bool trailingFlexible;

  /// [trailing] 的固有宽度（dp），由知道自己多宽的调用方声明（如
  /// [AdaptiveSettingsStepperRow] 传 [kSettingsStepperTrailingWidth]）。
  ///
  /// 只影响**堆叠判据**：给出它，这行就按「padding + 图标 + 标题最低可读宽
  /// （[kSettingsRowLabelMinWidth]）+ 间距 + 本值」判断还放不放得下行内布局，
  /// 而不是套那个与 trailing 无关的经验常数。不给（默认）= 维持原经验值。
  ///
  /// 它**不**参与布局本身：trailing 仍是自尺寸的非 flex 子，本值只是声明，
  /// 写错不会把控件拉宽或压窄，只会让堆叠点偏移。
  final double? trailingWidth;

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // Auto-stack a non-flex trailing under the label only when the row is
    // genuinely too narrow to host both side by side — NOT on every typical
    // phone. The label is already `Expanded` and the trailing is self-sizing,
    // so the inline Row never overflows down to fairly small widths; the column
    // layout is only an improvement when there is no horizontal room left.
    //
    // The threshold must follow text scale: at 1x a label + a switch/stepper
    // fit comfortably below any real phone row width (≈320–380dp), so a
    // fixed 360 wrongly stacked nearly every row — worse at high UI scale, where
    // the app shrinks the logical width and pushed `maxWidth` under 360. Scaling
    // the threshold with the effective text scale keeps it modest at 1x (so
    // normal rows stay horizontal) while still stacking when large text or a
    // wider non-flex trailing, like a stepper with a fixed readout slot,
    // genuinely needs the extra room. Capped so absurd scales don't demand an
    // impossible width.
    //
    // BUG-2550：那个经验值只在 trailing 窄（switch ~60）时成立。trailing 一旦真的
    // 宽——stepper 是 [kSettingsStepperTrailingWidth]（160）——220 就远低于这行真正
    // 需要的宽度：行宽刚好卡在阈值上时，标题拿到的是
    // `220 + 42 − 32(padding) − 42(icon) − 12(gap) − 160(stepper) ≈ 16dp`，
    // 一个汉字都装不下，于是「字体大小 / 字体粗细 / 段落间距」在阅读设置面板里
    // 全被 ellipsis 削成开头一个字。所以**声明了固有宽度的 trailing** 改按真实需求
    // 算阈值（padding + 图标 + 标题最低可读宽 + 间距 + trailing 实宽），没声明的
    // 维持原经验值不动（它们的窄屏行为另有守卫钉着）。
    final double textScale = MediaQuery.textScalerOf(context).scale(1);
    final double horizontalInset =
        horizontalPadding ?? (cupertino ? 16 : tokens.spacing.rowHorizontal);
    final double? declaredTrailingWidth = trailingWidth;
    final double stackThreshold = declaredTrailingWidth == null
        ? (220.0 * textScale).clamp(220.0, 420.0)
        : 2 * horizontalInset +
            (kSettingsRowLabelMinWidth * textScale).clamp(
              kSettingsRowLabelMinWidth,
              2 * kSettingsRowLabelMinWidth,
            ) +
            (tokens.spacing.gap + 4) +
            declaredTrailingWidth;
    // 左栏图标占固定宽（badge ~30 + 间距 gap+4 = 12）：堆叠判断必须把它计入
    // 需求，否则窄 pane（如视频快捷设置侧栏）里带图标的行仍按无图标阈值走
    // 行内布局，label+trailing 少了一个图标位而右溢出。
    final double iconExtra = (showIcon && icon != null) ? 42.0 : 0.0;
    final Widget content = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // BUG-1184：flexible trailing 此前被排除在堆叠判定外（`!trailingFlexible`），
        // 理由是它「会自己 shrink-and-scroll，不会溢出」。不溢出 ≠ 看得清：flexible
        // trailing 与 `Expanded` 标题按 flex 五五分整行宽，360dp 上标题只剩 ~130px，
        // 于是标题被压成两行省略号、控件也缩进一条窄滚动条——两边都读不了。窄到放不下
        // 时同样该让出整行给标题、控件独占下一行，与非 flex trailing 完全同一条规则。
        final bool stackControls = controlBelow ||
            (trailing != null &&
                constraints.maxWidth < stackThreshold + iconExtra);
        return Padding(
          padding: EdgeInsets.symmetric(
            horizontal: horizontalPadding ??
                (cupertino ? 16 : tokens.spacing.rowHorizontal),
            // MD3 分段行（Android 16 设置）：行内布局也取 rowVertical（12），
            // 配合下面的最小高，单行行高 64、带说明的行更舒展。
            vertical: stackControls || (!cupertino && !isGlassDesign(context))
                ? tokens.spacing.rowVertical
                : tokens.spacing.gap,
          ),
          child: stackControls
              ? _buildColumnLayout(context)
              : _buildRowLayout(context),
        );
      },
    );

    if (onTap == null) return content;
    final bool hasFocusRoot = FushiFocusRoot.maybeControllerOf(context) != null;
    if (cupertino) {
      // Cupertino 是隐藏内部能力，维持原有两分支（结构恒定化只做 Material
      // 主路径）。无焦点根时 FushiFocusable 保持方向键可达（GestureDetector
      // 本身不可聚焦）。
      if (!hasFocusRoot) {
        return FushiFocusable(
          onTap: onTap,
          borderRadius: BorderRadius.zero,
          child: content,
        );
      }
      return _SettingsRowFocusTarget(
        onTap: onTap!,
        child: ExcludeFocus(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: content,
          ),
        ),
      );
    }
    // Material：**结构恒定，行为按 hasFocusRoot 门控**。此前按有无焦点根换两棵
    // 不同的树（裸 InkWell vs 目标+ExcludeFocus 包裹），切「键盘/手柄焦点导航」
    // 实验开关时行子树整体重挂载，行里的 Switch 以新状态直接 mount——滑块动画
    // 消失（用户实报 2026-07-22）。恒定结构下两态语义不变：
    // - 有焦点根：目标可聚焦 + ExcludeFocus 生效 → 单停靠点（PR-0 契约）；
    // - 无焦点根：目标 skipTraversal + ExcludeFocus 直通 → InkWell/Switch 照旧
    //   参与原生 Tab 遍历，与旧「裸 InkWell」分支逐字节同语义。
    // 「玻璃」设计系统：行的点击面换成 [FushiAppleRow]（iOS 单元格的按下
    // systemFill 高亮）；焦点目标、ExcludeFocus 与 MD3 同一结构。行与 InkWell
    // 一样自带焦点节点：无焦点根时它是 Tab 停靠点（Enter / 手柄 A → onTap，强调
    // 色焦点描边）；有焦点根时被 ExcludeFocus 排除，由 _SettingsRowFocusTarget
    // 的 ActivateIntent 激活。focusable 恒为 true（只靠 ExcludeFocus 门控），
    // 切实验开关时树结构不变。
    final Widget tapSurface = isGlassDesign(context)
        ? FushiAppleRow(onTap: onTap, child: content)
        : InkWell(onTap: onTap, child: content);
    return _SettingsRowFocusTarget(
      onTap: onTap!,
      focusEnabled: hasFocusRoot,
      child: ExcludeFocus(
        excluding: hasFocusRoot,
        child: tapSurface,
      ),
    );
  }

  Widget _buildRowLayout(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: isCupertinoPlatform(context)
            ? 46
            : isGlassDesign(context)
                // 玻璃：iOS 行高 44（桌面 38）；外层 Padding 已有竖直 gap。
                ? FushiAppleMetrics.of(context).rowMinHeight -
                    2 * tokens.spacing.gap
                // MD3：40 + 上下各 12 = 单行 64（Android 16 设置行）。
                : tokens.density.controlHeight - tokens.spacing.gap,
      ),
      child: Row(
        children: [
          if (showIcon && icon != null) ...[
            _SettingsIcon(icon: icon!),
            SizedBox(width: tokens.spacing.gap + 4),
          ],
          Expanded(
            child: _SettingsLabel(
              title: title,
              subtitle: subtitle,
              titleMaxLines: titleMaxLines,
              subtitleMaxLines: subtitleMaxLines,
            ),
          ),
          if (trailing != null) ...[
            SizedBox(width: tokens.spacing.gap + 4),
            // A flexible trailing receives bounded width so an inner horizontal
            // scroll view scrolls instead of overflowing (see [trailingFlexible]).
            _buildInlineTrailing(trailing!, flexible: trailingFlexible),
          ],
        ],
      ),
    );
  }

  Widget _buildInlineTrailing(Widget child, {required bool flexible}) {
    final Widget aligned = Align(
      alignment: Alignment.centerRight,
      widthFactor: flexible ? null : 1,
      child: child,
    );
    if (!flexible) return aligned;
    return Flexible(fit: FlexFit.loose, child: aligned);
  }

  Widget _buildColumnLayout(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: isCupertinoPlatform(context)
            ? 58
            : tokens.density.controlHeight + tokens.spacing.gap + 4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (showIcon && icon != null) ...[
                _SettingsIcon(icon: icon!),
                SizedBox(width: tokens.spacing.gap + 4),
              ],
              Expanded(
                child: _SettingsLabel(
                  title: title,
                  subtitle: subtitle,
                  titleMaxLines: titleMaxLines,
                  subtitleMaxLines: subtitleMaxLines,
                ),
              ),
            ],
          ),
          if (trailing != null) ...[
            SizedBox(height: tokens.spacing.gap),
            Align(alignment: Alignment.centerLeft, child: trailing!),
          ],
        ],
      ),
    );
  }
}

class _SettingsRowFocusTarget extends StatefulWidget {
  const _SettingsRowFocusTarget({
    required this.onTap,
    required this.child,
    this.autoHome = true,
    this.focusEnabled = true,
  });

  final VoidCallback onTap;
  final Widget child;

  /// False = 目标保持挂载但不参与遍历/注册（无焦点根时的恒定结构模式，
  /// 见调用处注释）。透传 [FushiFocusTarget.enabled]。
  final bool focusEnabled;

  /// False for a collapsible section's fold header: it stays keyboard/gamepad
  /// reachable but passive focus auto-home skips it so the cursor lands on the
  /// first real setting row (see [FushiFocusTargetEntry.autoHome]).
  final bool autoHome;

  @override
  State<_SettingsRowFocusTarget> createState() =>
      _SettingsRowFocusTargetState();
}

class _SettingsRowFocusTargetState extends State<_SettingsRowFocusTarget> {
  late final FushiFocusId _focusId = FushiFocusId(
    'settings-row-${identityHashCode(this)}',
  );

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: FushiFocusTarget(
        id: _focusId,
        autoHome: widget.autoHome,
        enabled: widget.focusEnabled,
        child: widget.child,
      ),
    );
  }
}

class AdaptiveSettingsSwitchRow extends StatelessWidget {
  const AdaptiveSettingsSwitchRow({
    required this.title,
    required this.value,
    required this.onChanged,
    super.key,
    this.subtitle,
    this.icon,
    this.showIcon = false,
    this.horizontalPadding,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;

  /// 与 [AdaptiveSettingsNavigationRow.showIcon] 同款开关：true 且 [icon] 非空
  /// 才渲染左栏图标徽章。schema 层的 `showIcons` 经此透传（此前只转发 icon 不
  /// 转发 showIcon，值控件行声明的图标从不渲染，同卡片左栏对不齐）。
  final bool showIcon;
  final double? horizontalPadding;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsRow(
      title: title,
      subtitle: subtitle,
      icon: icon,
      showIcon: showIcon,
      horizontalPadding: horizontalPadding,
      trailing: isGlassDesign(context) && !isCupertinoPlatform(context)
          ? glassSettingsSwitch(
              context: context,
              value: value,
              onChanged: onChanged,
            )
          : adaptiveSwitch(
              context: context,
              value: value,
              onChanged: onChanged,
            ),
      onTap: onChanged == null ? null : () => onChanged!(!value),
    );
  }
}

/// 「玻璃」设计系统设置行的开关：与 [FushiSwitch] 的 Apple 分支同一枚
/// [FushiAppleSwitch]——经典 iOS / macOS 开关（触屏 51×31、桌面 38×22 全胶囊
/// 轨 + 正圆钮带柔和投影，弹簧过渡）。开启色恒为强调色（用户 2026-10-04 拍板）；
/// 开态圆钮取强调色上的前景色——默认单色主题深色下强调色是白，圆钮随之变黑，
/// 不会白上白；关态 systemFill 灰轨 + 白钮。禁用态与 [adaptiveSwitch] 同语义
/// （不可点、不可聚焦）。
///
/// 不再用库的 `GlassSwitch`（用户 2026-10-05 Windows 深色截图）：它的圆钮是
/// 比例写死的横向长胶囊（1.6 倍轨高），开态轨道还带一圈强调色外发光，压在
/// 深色分组卡上像白钮溢出 / 被裁；圆钮的玻璃透镜走 GlassEffect，在 Skia 上
/// 没有回退。设置页里同一屏同时出现两种开关（行内 FushiSwitch 与设置行）也
/// 不该长得不一样。
Widget glassSettingsSwitch({
  required BuildContext context,
  required bool value,
  required ValueChanged<bool>? onChanged,
}) {
  final FushiAppleColors apple = appleColorsOf(context);
  final Widget glassSwitch = FushiAppleSwitch(
    value: value,
    onChanged: onChanged,
    activeTrackColor: apple.accent,
    inactiveTrackColor: apple.fill,
  );
  if (onChanged != null) return glassSwitch;
  return IgnorePointer(
    child: ExcludeFocus(child: Opacity(opacity: 0.38, child: glassSwitch)),
  );
}

class AdaptiveSettingsSwitchActionRow extends StatelessWidget {
  const AdaptiveSettingsSwitchActionRow({
    required this.title,
    required this.value,
    required this.onChanged,
    super.key,
    this.subtitle,
    this.icon,
    this.showIcon = false,
    this.body,
    this.actions = const <Widget>[],
    this.panel,
    this.controlBelow = false,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;

  /// 见 [AdaptiveSettingsSwitchRow.showIcon]。
  final bool showIcon;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget? body;
  final List<Widget> actions;
  final Widget? panel;
  final bool controlBelow;

  @override
  Widget build(BuildContext context) {
    final Widget switchControl = adaptiveSwitch(
      context: context,
      value: value,
      onChanged: onChanged,
    );
    final bool stacked = controlBelow || body != null || panel != null;
    // TODO-977 UX：带展开调色板（panel）时，整行 onTap 不再切换开关——否则用户在
    // 面板/预览区域附近点一下就会误触把配置项关掉（用户反馈「经常点到背景给关了」）。
    // 此时只有 switch 控件本身能切换。无 panel 的普通开关行保持整行可点的旧行为。
    final bool rowTapTogglesSwitch = onChanged != null && panel == null;
    return AdaptiveSettingsRow(
      title: title,
      subtitle: subtitle,
      icon: icon,
      showIcon: showIcon,
      controlBelow: stacked,
      trailing: stacked
          ? _buildStackedTrailing(switchControl)
          : _buildInlineTrailing(switchControl),
      onTap: rowTapTogglesSwitch ? () => onChanged!(!value) : null,
    );
  }

  Widget _buildInlineTrailing(Widget switchControl) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ..._spacedActions(),
        if (actions.isNotEmpty) const SizedBox(width: 6),
        switchControl,
      ],
    );
  }

  Widget _buildStackedTrailing(Widget switchControl) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (body != null) Expanded(child: body!) else const Spacer(),
            ..._spacedActions(),
            if (actions.isNotEmpty) const SizedBox(width: 6),
            switchControl,
          ],
        ),
        if (panel != null) ...[const SizedBox(height: 8), panel!],
      ],
    );
  }

  List<Widget> _spacedActions() {
    final List<Widget> spaced = <Widget>[];
    for (int i = 0; i < actions.length; i++) {
      spaced.add(
        Padding(
          padding: EdgeInsets.only(left: i == 0 ? 0 : 4),
          child: actions[i],
        ),
      );
    }
    return spaced;
  }
}

/// Per-segment horizontal chrome (padding + border) baked into a Material
/// [SegmentedButton] segment under [kSettingsSegmentedStyle] (compact density,
/// shrink-wrap tap target). Deliberately on the generous side: when estimating
/// whether a strip fits, over-estimating the width makes us fall back to the
/// (non-clipping) horizontal scroll instead of forcing a too-tight full-width
/// layout — i.e. errors land on the safe, BUG-008-preserving side.
const double _kSegmentHorizontalChrome = 28.0;

/// Width reserved for a segment that carries no text label (icon-only segments
/// such as the 深色模式 light/system/dark strip), in logical pixels.
const double _kSegmentIconOnlyWidth = 44.0;

/// M3 Expressive 连接式按钮组每段比 Material 分段估宽多出的宽度：选中段的
/// 内边距 12 + 对勾 18 + 间距 8 + 16 = 54，而 [_kSegmentHorizontalChrome] 只算 28；
/// 段宽按最宽段等宽排，所以每段都按这个差值补（见 AdaptiveSettingsSegmentedRow
/// 的 MD3 分支）。
const double _kConnectedGroupSegmentExtra = 26.0;

/// Average advance width of one label glyph relative to the font size. CJK /
/// fullwidth glyphs are ~1em wide; Latin (and most other narrow scripts) are
/// ~0.55em — estimated at 0.62em so the guess stays conservative (wide) without
/// grossly over-shooting for long Latin labels (which would force strips into
/// the scroll fallback that actually fit).
const double _kSegmentWideGlyphWidthFactor = 1.0;
const double _kSegmentNarrowGlyphWidthFactor = 0.62;

/// Estimated advance width of [label] (logical pixels) at [scaledFont],
/// classifying each rune as wide (CJK/fullwidth, >= U+1100) or narrow.
double _segmentLabelContentWidth(String label, double scaledFont) =>
    estimateLabelAdvanceWidth(
      label: label,
      fontSize: scaledFont,
      textScaleFactor: 1.0,
    );

/// 估算一排 MD3 tab（库页顶栏 [LibrarySectionTabs]）按各自文案取宽时的自然总宽
/// （逻辑像素）。[horizontalPaddingPerTab] 是单侧 label 内边距。
///
/// 逐段求和，不是「段数 × 最宽段」——后者是等宽分段条 [estimateSegmentedStripWidth]
/// 的算法，tab 各自取宽，用错会高估近一倍。
///
/// 字号 / 文字缩放在这里就地取自 tokens 与 [MediaQuery]，调用点不再重复那三行样板，
/// 也不必自己碰 `fontSize`——顶栏字号是共享组件层的决策，页面侧不该重开。
double estimateSectionTabBarWidth(
  BuildContext context,
  List<String> labels, {
  required double horizontalPaddingPerTab,
}) {
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  final double fontSize = tokens.type.controlLabel.fontSize ?? 14.0;
  final double textScaleFactor = MediaQuery.textScalerOf(context).scale(1);
  double total = 0.0;
  for (final String label in labels) {
    total += estimateLabelAdvanceWidth(
          label: label,
          fontSize: fontSize,
          textScaleFactor: textScaleFactor,
        ) +
        horizontalPaddingPerTab * 2;
  }
  return total;
}

/// 一段标签文案的估算横向进距（逻辑像素），CJK / 全角按 1em、其余按 0.62em。
///
/// Build 期可算（只依赖文案 / 字号 / 文字缩放，不依赖布局），供两类顶栏控件共用：
/// [segmentedStripCellWidth]（分段条的等宽单元格）与库页顶栏 [LibrarySectionTabs]
/// 的 tab 自然宽。两者的换行 / 滚动兜底判据必须出自同一张字宽表，否则同一批文案
/// 在两个控件上会得出不同的「摆得下吗」结论。
double estimateLabelAdvanceWidth({
  required String label,
  required double fontSize,
  required double textScaleFactor,
}) {
  final double scaledFont = fontSize * textScaleFactor;
  double width = 0.0;
  for (final int rune in label.runes) {
    width += scaledFont *
        (rune >= 0x1100
            ? _kSegmentWideGlyphWidthFactor
            : _kSegmentNarrowGlyphWidthFactor);
  }
  return width;
}

/// Estimated width (logical pixels) of ONE segment cell of a Material
/// segmented strip: the widest segment's content, floored at [minSegmentWidth],
/// plus per-segment chrome. Material [SegmentedButton] lays EVERY segment out
/// at the same width — the widest segment's intrinsic width (framework
/// `_calculateHorizontalChildSize`) — so this is the building block for the
/// strip's natural width.
double segmentedStripCellWidth({
  required List<String?> segmentLabels,
  required double fontSize,
  required double textScaleFactor,
  double minSegmentWidth = 0.0,
}) {
  final double scaledFont = fontSize * textScaleFactor;
  double cell = minSegmentWidth;
  for (final String? label in segmentLabels) {
    final double content = (label == null || label.isEmpty)
        ? _kSegmentIconOnlyWidth
        : _segmentLabelContentWidth(label, scaledFont);
    final double candidate = content + _kSegmentHorizontalChrome;
    if (candidate > cell) cell = candidate;
  }
  return cell;
}

/// Estimates the intrinsic width (logical pixels) a Material segmented strip
/// would occupy if laid out at its natural size, WITHOUT actually building it.
///
/// Used by [AdaptiveSettingsSegmentedRow] and [FushiSegmentedStrip] to decide,
/// inside a [LayoutBuilder], whether the strip fits (→ bounded equal-width
/// layout) or must fall back to a horizontal scroll view (→ narrow pane, keep
/// every segment reachable per BUG-008). It does not need to be exact — only
/// conservative: a slight over-estimate prefers the safe scrolling path.
///
/// BUG-1719 (顶栏下沉): the estimate MUST model the framework's equal-width
/// layout — `segmentCount × widestCell` — NOT the sum of each segment's own
/// width. The old per-segment sum under-estimated any strip whose labels differ
/// in length, so 「fits」 was declared for widths that could not actually hold
/// the equal-width layout; the framework then clamped every cell below the
/// widest label, which wrapped to two lines and grew the strip 8px taller than
/// its siblings (the game capture-workbench top bar visibly sank on tab
/// switch).
///
/// [segmentLabels] is one entry per segment: the label's text, or `null` for an
/// icon-only segment. [fontSize] is the segment label font size and
/// [textScaleFactor] the active text scaler — both widen the estimate so large
/// text or high UI scale correctly falls back to scrolling.
double estimateSegmentedStripWidth({
  required List<String?> segmentLabels,
  required double fontSize,
  required double textScaleFactor,
  double minSegmentWidth = 0.0,
}) {
  if (segmentLabels.isEmpty) return 0.0;
  return segmentLabels.length *
      segmentedStripCellWidth(
        segmentLabels: segmentLabels,
        fontSize: fontSize,
        textScaleFactor: textScaleFactor,
        minSegmentWidth: minSegmentWidth,
      );
}

class AdaptiveSettingsSegmentedRow<T extends Object> extends StatelessWidget {
  const AdaptiveSettingsSegmentedRow({
    required this.title,
    required this.segments,
    required this.selected,
    required this.onChanged,
    super.key,
    this.subtitle,
    this.icon,
    this.showIcon = false,
    this.controlBelow = true,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;

  /// 见 [AdaptiveSettingsSwitchRow.showIcon]。
  final bool showIcon;
  final List<ButtonSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  /// A segmented strip is an intrinsically WIDE, multi-option control. Hosted
  /// inline ([controlBelow] false) it shares the row with an `Expanded` label,
  /// and RenderFlex splits the width by flex (≈50/50) — so a strip wider than
  /// its share is clipped/scrolled and trailing segments fall off the right
  /// edge (the reported 设计系统/深色模式 bug, BUG-008). Default is therefore
  /// [controlBelow] true: the strip gets its own full-width row below the
  /// label, showing every segment and scrolling only when the pane is genuinely
  /// narrower than the strip. Pass `controlBelow: false` only for a short strip
  /// that must sit inline next to a short label.
  final bool controlBelow;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context) && !isCupertinoPlatform(context)) {
      return _buildGlass(context);
    }
    if (!isCupertinoPlatform(context)) return _buildMd3(context);
    // A segmented row is a discrete-valued control: register it as a SINGLE
    // gamepad/keyboard focus stop (like the stepper/slider rows) so geometric
    // focus navigation can land on it, and D-pad Left/Right steps the segment
    // in place (clamped at the ends, no wrap). Without this wrapper the row
    // carries no FushiFocusTarget (its
    // AdaptiveSettingsRow has no onTap), so it is invisible to directional
    // navigation — the cursor skips the whole layout section.
    final int currentIndex = segments.indexWhere(
      (ButtonSegment<T> s) => s.value == selected,
    );
    void selectAt(int index) {
      if (segments.isEmpty) return;
      final int clamped = index.clamp(0, segments.length - 1);
      final T value = segments[clamped].value;
      if (value != selected) onChanged(value);
    }

    // Extract each segment's label text (null for icon-only segments) so the
    // pure-function width estimate can decide whether the strip fits full-width.
    final List<String?> segmentLabels =
        segments.map<String?>((ButtonSegment<T> s) {
      final Widget? label = s.label;
      return label is Text ? label.data : null;
    }).toList(growable: false);

    final Widget strip = adaptiveSegmentedButton<T>(
      context: context,
      segments: segments,
      selected: <T>{selected},
      onSelectionChanged: (Set<T> values) {
        if (values.isEmpty) return;
        onChanged(values.first);
      },
      style: kSettingsSegmentedStyle,
    );

    return AdaptiveSettingsRow(
      title: title,
      subtitle: subtitle,
      icon: icon,
      showIcon: showIcon,
      controlBelow: controlBelow,
      // The segmented strip is intrinsically wide and wrapped in a horizontal
      // scroll view; host it as a flexible (bounded-width) trailing so it
      // shrink-and-scrolls on narrow panes instead of overflowing the row.
      trailingFlexible: true,
      trailing: _GamepadAdjustableValue(
        focusIdPrefix: 'settings-segmented',
        onIncrement: () => selectAt(currentIndex + 1),
        onDecrement: () => selectAt(currentIndex - 1),
        child: _SegmentedStripHost(
          controlBelow: controlBelow,
          segmentLabels: segmentLabels,
          strip: strip,
        ),
      ),
    );
  }

  /// 「玻璃」（Apple）设计系统：多选一按 [settingsChoiceUsesSegments] 二选一——
  /// 选项少且短（设计系统、深色模式、玻璃材质、悬浮球自动恢复这类）是行右侧
  /// 紧凑的 iOS 分段控件（选中段 = 强调色实底），否则是 macOS / iOS 的弹出菜单
  /// 按钮（当前值 + `chevron.up.chevron.down` → 玻璃菜单，当前项打勾）。两种
  /// 都是一个焦点停靠点：左右键逐项切换；弹出按钮另有 Enter / 手柄 A 打开菜单。
  Widget _buildGlass(BuildContext context) {
    final int currentIndex = segments.indexWhere(
      (ButtonSegment<T> s) => s.value == selected,
    );
    final List<String> labels = <String>[
      for (final ButtonSegment<T> s in segments) _segmentMenuLabel(s),
    ];
    final List<IconData?> icons = <IconData?>[
      for (final ButtonSegment<T> s in segments) _segmentIcon(s),
    ];
    void pick(int index) {
      final T value = segments[index].value;
      if (value != selected) onChanged(value);
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final List<String> fitLabels = <String>[
          for (final ButtonSegment<T> s in segments) _segmentFitLabel(s),
        ];
        final bool useSegments = settingsChoiceUsesSegments(
          labels: fitLabels,
          controlWidth: appleSegmentedControlWidth(fitLabels),
          rowWidth: constraints.maxWidth,
        );
        return AdaptiveSettingsRow(
          title: title,
          subtitle: subtitle,
          icon: icon,
          showIcon: showIcon,
          trailing: useSegments
              ? AppleSettingsSegmentedControl(
                  semanticLabel: title,
                  labels: fitLabels,
                  tooltips: labels,
                  icons: icons,
                  selectedIndex: currentIndex < 0 ? null : currentIndex,
                  onChanged: pick,
                )
              : GlassSettingsPopUpButton(
                  semanticLabel: title,
                  labels: labels,
                  icons: icons,
                  selectedIndex: currentIndex < 0 ? null : currentIndex,
                  onChanged: pick,
                ),
        );
      },
    );
  }

  /// MD3（Android 16 设置）：同一条 [settingsChoiceUsesSegments] 判据——少而短
  /// 的选项是行右侧紧凑的 MD3 分段按钮（不再撑满整行）；否则当前值写进说明行，
  /// 点整行弹出 MD3 菜单（当前项打勾）。
  Widget _buildMd3(BuildContext context) {
    final int currentIndex = segments.indexWhere(
      (ButtonSegment<T> s) => s.value == selected,
    );
    void selectAt(int index) {
      if (segments.isEmpty) return;
      final int clamped = index.clamp(0, segments.length - 1);
      final T value = segments[clamped].value;
      if (value != selected) onChanged(value);
    }

    final List<String?> stripLabels = segments.map<String?>((ButtonSegment<T> s) {
      final Widget? label = s.label;
      return label is Text ? label.data : null;
    }).toList(growable: false);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // MD3 下 adaptiveSegmentedButton 渲染的是 M3 Expressive 连接式按钮组
    // （FushiConnectedButtonGroup）：段内边距 16+16（选中段带对勾时 12 + 18 图标
    // + 8 间距 + 16），段宽取最宽段（equalExtents），段间 2dp 缝。Material
    // SegmentedButton 的估宽（每段 +28）因此每段少算 26、还漏了缝——判据以为
    // 「放得下行内」，实际控件比估宽宽一截把整行右溢（窄视频面板 312 宽的
    // 「字幕位置」行溢出 15px）。这里按连接式按钮组的真实几何补齐。
    final double stripWidth = estimateSegmentedStripWidth(
          segmentLabels: stripLabels,
          fontSize: tokens.type.controlLabel.fontSize ?? 14.0,
          textScaleFactor: MediaQuery.textScalerOf(context).scale(1),
        ) +
        segments.length * _kConnectedGroupSegmentExtra +
        (segments.length - 1).clamp(0, segments.length) * 2;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool useSegments = settingsChoiceUsesSegments(
          labels: <String>[
            for (final ButtonSegment<T> s in segments) _segmentFitLabel(s),
          ],
          controlWidth: stripWidth,
          rowWidth: constraints.maxWidth,
        );
        if (!useSegments) {
          return SettingsChoiceMenuRow(
            title: title,
            subtitle: subtitle,
            icon: icon,
            showIcon: showIcon,
            labels: <String>[
              for (final ButtonSegment<T> s in segments) _segmentMenuLabel(s),
            ],
            selectedIndex: currentIndex < 0 ? null : currentIndex,
            onChanged: selectAt,
          );
        }
        return AdaptiveSettingsRow(
          title: title,
          subtitle: subtitle,
          icon: icon,
          showIcon: showIcon,
          trailingWidth: stripWidth,
          trailing: _GamepadAdjustableValue(
            focusIdPrefix: 'settings-segmented',
            onIncrement: () => selectAt(currentIndex + 1),
            onDecrement: () => selectAt(currentIndex - 1),
            child: adaptiveSegmentedButton<T>(
              context: context,
              segments: segments,
              selected: <T>{selected},
              onSelectionChanged: (Set<T> values) {
                if (values.isEmpty) return;
                onChanged(values.first);
              },
              style: kSettingsSegmentedStyle,
            ),
          ),
        );
      },
    );
  }

  /// 菜单 / 弹出按钮里显示的文字：文字段取文字，纯图标段取 tooltip。
  static String _segmentMenuLabel(ButtonSegment<Object> segment) {
    final Widget? label = segment.label;
    if (label is Text && (label.data?.isNotEmpty ?? false)) return label.data!;
    return segment.tooltip ?? '';
  }

  /// 判据与分段控件用的文字：纯图标段为空串（按图标宽计），其余同菜单文字。
  static String _segmentFitLabel(ButtonSegment<Object> segment) {
    final Widget? label = segment.label;
    if (label is Text && (label.data?.isNotEmpty ?? false)) return label.data!;
    if (_segmentIcon(segment) != null) return '';
    return segment.tooltip ?? '';
  }

  static IconData? _segmentIcon(ButtonSegment<Object> segment) {
    final Widget? icon = segment.icon;
    if (icon is FushiIcon) return icon.icon;
    if (icon is Icon) return icon.icon;
    return null;
  }
}

/// 单选项文字的「视觉宽度」权重：CJK 等全角字记 2、其余记 1（≈ 4 个汉字 =
/// 8 个拉丁字母）。
int settingsChoiceLabelWeight(String label) {
  int weight = 0;
  for (final int rune in label.runes) {
    weight += rune >= 0x2E80 ? 2 : 1;
  }
  return weight;
}

/// 单选项用「分段控件」还是「菜单 / 弹出按钮」的**唯一判据**，Apple 与 MD3
/// 的设置行（分段行、Apple 选择器行）都只问这里，调用点不各自挑。
///
/// 对齐 macOS 系统设置（外观用分段、长列表用弹出菜单）与 Android 16 设置：
/// - 2–3 个选项、每个不超过 ≈ 6 个汉字 / 12 个字母；或 4 个选项、每个不超过
///   ≈ 4 个汉字 / 8 个字母；纯图标段（[labels] 里为空串）算短；
/// - 且控件估宽 [controlWidth] 不超过行宽 [rowWidth] 的 55%（放不下就退回
///   菜单，不把标题挤成一个字）。
bool settingsChoiceUsesSegments({
  required List<String> labels,
  required double controlWidth,
  required double rowWidth,
}) {
  final int count = labels.length;
  if (count < 2 || count > 4) return false;
  final int limit = count <= 3 ? 12 : 8;
  for (final String label in labels) {
    if (settingsChoiceLabelWeight(label) > limit) return false;
  }
  if (!rowWidth.isFinite) return true;
  return controlWidth <= rowWidth * 0.55;
}

/// [AppleSettingsSegmentedControl] 的估宽（纯函数，供判据在布局前用）。与
/// [FushiSegmentedButton] 的 Apple 分支同一口径：等宽段，每段 = 最宽文字 + 28，
/// 两侧轨道内边距共 6；纯图标段按 20 宽计。
double appleSegmentedControlWidth(List<String> labels) {
  double widest = 0;
  for (final String label in labels) {
    final double w =
        label.isEmpty ? 20 : settingsChoiceLabelWeight(label) * 7.0;
    if (w > widest) widest = w;
  }
  return labels.length * (widest + 28) + 6;
}

/// 「Apple」设计系统设置行的分段控件：直接用全应用统一的液态玻璃分段控件
/// （[FushiSegmentedButton] 的 Apple 分支 = liquid_glass_widgets 的
/// `GlassSegmentedControl`，玻璃透镜滑块、选中态跟随强调色），这里只负责
/// 「行右侧、随内容收宽」的摆放与焦点：整枚控件是一个停靠点
/// （[_GamepadAdjustableValue]），左右键 / 手柄十字键逐段切换。
class AppleSettingsSegmentedControl extends StatelessWidget {
  const AppleSettingsSegmentedControl({
    required this.labels,
    required this.selectedIndex,
    required this.onChanged,
    super.key,
    this.icons,
    this.tooltips,
    this.semanticLabel,
  });

  /// 段文字；空串 = 纯图标段（取 [icons] 同位图标）。
  final List<String> labels;
  final List<IconData?>? icons;

  /// 每段的读屏 / 悬停文字（纯图标段必须有）。
  final List<String>? tooltips;
  final int? selectedIndex;
  final ValueChanged<int> onChanged;
  final String? semanticLabel;

  void _step(int delta) {
    if (labels.isEmpty) return;
    final int current = selectedIndex ?? (delta > 0 ? -1 : 0);
    final int next = (current + delta).clamp(0, labels.length - 1);
    if (next != selectedIndex) onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final List<ButtonSegment<int>> segments = <ButtonSegment<int>>[
      for (int i = 0; i < labels.length; i++)
        ButtonSegment<int>(
          value: i,
          label: labels[i].isEmpty ? null : Text(labels[i]),
          icon: labels[i].isEmpty && icons != null && i < icons!.length
              ? FushiIcon(icons![i])
              : null,
          tooltip: tooltips != null && i < tooltips!.length
              ? tooltips![i]
              : (labels[i].isEmpty ? null : labels[i]),
        ),
    ];
    return Semantics(
      container: true,
      label: semanticLabel,
      child: _GamepadAdjustableValue(
        focusIdPrefix: 'settings-apple-segmented',
        onIncrement: () => _step(1),
        onDecrement: () => _step(-1),
        // 无界宽宿主（行内非 flex trailing）里 FushiSegmentedButton 按内容取宽。
        child: FushiSegmentedButton<int>(
          segments: segments,
          selected: <int>{if (selectedIndex != null) selectedIndex!},
          emptySelectionAllowed: selectedIndex == null,
          showSelectedIcon: false,
          onSelectionChanged: (Set<int> values) {
            if (values.isEmpty) return;
            if (values.first != selectedIndex) onChanged(values.first);
          },
        ),
      ),
    );
  }
}

/// MD3（Android 16 设置的 ListPreference）单选行：当前值写在说明行第一行
/// （原说明另起一行接在后面），点整行在行上弹出 MD3 菜单（[showFushiMenu]，
/// 当前项打勾）。焦点：整行是一个停靠点，Enter / 手柄 A 打开菜单，菜单里方向键
/// 选项、Enter 确认、Esc 取消。
class SettingsChoiceMenuRow extends StatefulWidget {
  const SettingsChoiceMenuRow({
    required this.title,
    required this.labels,
    required this.selectedIndex,
    required this.onChanged,
    super.key,
    this.subtitle,
    this.icon,
    this.showIcon = false,
    this.placeholder,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool showIcon;
  final List<String> labels;
  final int? selectedIndex;
  final ValueChanged<int> onChanged;
  final String? placeholder;

  @override
  State<SettingsChoiceMenuRow> createState() => _SettingsChoiceMenuRowState();
}

class _SettingsChoiceMenuRowState extends State<SettingsChoiceMenuRow> {
  final GlobalKey _rowKey = GlobalKey();
  bool _open = false;

  Future<void> _openMenu() async {
    if (_open || widget.labels.isEmpty) return;
    final BuildContext? anchor = _rowKey.currentContext;
    if (anchor == null) return;
    final RenderBox box = anchor.findRenderObject()! as RenderBox;
    final RenderBox overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 菜单盖在行的标题位置上展开（Android 设置的 ListPreference 弹出形态）。
    final Offset origin = box.localToGlobal(
      Offset(tokens.spacing.rowHorizontal, 0),
      ancestor: overlay,
    );
    _open = true;
    final int? picked = await showFushiMenu<int>(
      context: context,
      position: RelativeRect.fromRect(
        origin & Size(box.size.width - 2 * tokens.spacing.rowHorizontal, box.size.height),
        Offset.zero & overlay.size,
      ),
      initialValue: widget.selectedIndex,
      semanticLabel: widget.title,
      items: <PopupMenuEntry<int>>[
        for (int i = 0; i < widget.labels.length; i++)
          CheckedPopupMenuItem<int>(
            value: i,
            checked: i == widget.selectedIndex,
            child: Text(widget.labels[i]),
          ),
      ],
    );
    _open = false;
    if (!mounted || picked == null) return;
    if (picked != widget.selectedIndex) widget.onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final int? selected = widget.selectedIndex;
    final String value =
        selected != null && selected >= 0 && selected < widget.labels.length
            ? widget.labels[selected]
            : (widget.placeholder ?? '');
    final String? description = widget.subtitle;
    final String summary = description == null || description.isEmpty
        ? value
        : (value.isEmpty ? description : '$value\n$description');
    return KeyedSubtree(
      key: _rowKey,
      child: AdaptiveSettingsRow(
        title: widget.title,
        subtitle: summary.isEmpty ? null : summary,
        icon: widget.icon,
        showIcon: widget.showIcon,
        onTap: _openMenu,
      ),
    );
  }
}

/// 「玻璃」设计系统的弹出菜单按钮（macOS pop-up button / iOS 26 pull-down）：
/// 当前值 + 小号 `chevron.up.chevron.down`，点开 [showFushiMenu] 的玻璃菜单，
/// 当前项打勾。桌面是带 tertiaryFill 底的紧凑胶囊（macOS 弹出按钮的 bezel），
/// 触屏是无底的 secondaryLabel 文字（iOS 设置行尾的 pull-down 形态）。
///
/// 焦点：有 [FushiFocusRoot] 时整枚按钮是一个焦点目标——左右键逐项切换、
/// Enter / 手柄 A 打开菜单（菜单打开后焦点落在当前项，方向键在项间移动）；
/// 没有焦点根时按钮自身可 Tab、Enter 打开。
class GlassSettingsPopUpButton extends StatefulWidget {
  const GlassSettingsPopUpButton({
    required this.labels,
    required this.selectedIndex,
    required this.onChanged,
    super.key,
    this.icons,
    this.placeholder,
    this.semanticLabel,
    this.maxLabelWidth = 240,
  });

  final List<String> labels;

  /// 与 [labels] 等长；菜单项行首图标（可空）。
  final List<IconData?>? icons;
  final int? selectedIndex;
  final ValueChanged<int> onChanged;
  final String? placeholder;
  final String? semanticLabel;

  /// 当前值文字的最大宽：超长选项省略，不把行标题挤没。
  final double maxLabelWidth;

  @override
  State<GlassSettingsPopUpButton> createState() =>
      _GlassSettingsPopUpButtonState();
}

class _GlassSettingsPopUpButtonState extends State<GlassSettingsPopUpButton> {
  final GlobalKey _anchorKey = GlobalKey();
  bool _open = false;

  void _step(int delta) {
    if (widget.labels.isEmpty) return;
    final int current = widget.selectedIndex ?? (delta > 0 ? -1 : 0);
    final int next = (current + delta).clamp(0, widget.labels.length - 1);
    if (next != widget.selectedIndex) widget.onChanged(next);
  }

  Future<void> _openMenu() async {
    if (_open || widget.labels.isEmpty) return;
    final BuildContext? anchor = _anchorKey.currentContext;
    if (anchor == null) return;
    final RenderBox box = anchor.findRenderObject()! as RenderBox;
    final RenderBox overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final Offset topLeft = box.localToGlobal(
      Offset(0, box.size.height + 4),
      ancestor: overlay,
    );
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final List<IconData?>? icons = widget.icons;
    _open = true;
    final int? picked = await showFushiMenu<int>(
      context: context,
      position: RelativeRect.fromRect(
        topLeft & Size(box.size.width, 0),
        Offset.zero & overlay.size,
      ),
      initialValue: widget.selectedIndex,
      semanticLabel: widget.semanticLabel,
      constraints: BoxConstraints(
        minWidth: box.size.width < 180 ? 180 : box.size.width,
        maxWidth: 360,
      ),
      items: <PopupMenuEntry<int>>[
        for (int i = 0; i < widget.labels.length; i++)
          PopupMenuItem<int>(
            value: i,
            height: metrics.desktop ? 32 : 44,
            child: Row(
              children: <Widget>[
                if (icons != null && i < icons.length && icons[i] != null) ...[
                  FushiIcon(icons[i], size: metrics.desktop ? 15 : 18),
                  const SizedBox(width: 10),
                ],
                Flexible(
                  child: Text(
                    widget.labels[i],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    _open = false;
    if (!mounted || picked == null) return;
    if (picked != widget.selectedIndex) widget.onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final bool desktop = metrics.desktop;
    final int? selected = widget.selectedIndex;
    final String value = selected != null &&
            selected >= 0 &&
            selected < widget.labels.length
        ? widget.labels[selected]
        : (widget.placeholder ?? '');
    final IconData? valueIcon = selected != null &&
            widget.icons != null &&
            selected >= 0 &&
            selected < widget.icons!.length
        ? widget.icons![selected]
        : null;
    final Color fg = desktop ? apple.label : apple.secondaryLabel;
    final TextStyle style = metrics.subtitleStyle(context).copyWith(
          fontSize: desktop ? 13 : 17,
          color: fg,
        );
    final Widget face = Container(
      key: _anchorKey,
      constraints: BoxConstraints(minHeight: desktop ? 28 : 34),
      padding: EdgeInsets.only(left: desktop ? 12 : 8, right: desktop ? 10 : 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (valueIcon != null && value.isEmpty)
            FushiIcon(valueIcon, size: desktop ? 14 : 17, color: fg)
          else
            ConstrainedBox(
              // 触屏行窄（≈ 360），当前值再收一截，给行标题留出位置。
              constraints: BoxConstraints(
                maxWidth: desktop
                    ? widget.maxLabelWidth
                    : (widget.maxLabelWidth < 150 ? widget.maxLabelWidth : 150),
              ),
              child: Text(
                value,
                style: style,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          SizedBox(width: desktop ? 6 : 5),
          FushiIcon(
            CupertinoIcons.chevron_up_chevron_down,
            size: desktop ? 10 : 13,
            color: desktop ? apple.secondaryLabel : apple.tertiaryLabel,
          ),
        ],
      ),
    );
    final bool hasFocusRoot = FushiFocusRoot.maybeControllerOf(context) != null;
    Widget button = FushiPlainButton(
      onPressed: _openMenu,
      borderRadius: BorderRadius.circular(desktop ? 13 : 17),
      semanticLabel: widget.semanticLabel,
      child: face,
    );
    // macOS 26 弹出按钮（Niratan「Klee ⌃⌄」）是无色透明玻璃胶囊，不是
    // systemFill 灰块；iOS 行尾仍是无 bezel 的「值 ⌃⌄」纯文字。desktop 按
    // 平台恒定，不会在运行中增删这层。
    if (desktop) {
      button = fushiClearGlassBezel(context, radius: 13, child: button);
    }
    if (!hasFocusRoot) return button;
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _openMenu();
            return null;
          },
        ),
      },
      child: _GamepadAdjustableValue(
        focusIdPrefix: 'settings-popup',
        onIncrement: () => _step(1),
        onDecrement: () => _step(-1),
        child: button,
      ),
    );
  }
}

/// Hosts the segmented [strip] in a FULL-WIDTH box that occupies the whole row
/// ([controlBelow] true), so every segmented box in the same section is the same
/// width (TODO-882). Only the box's CHILD varies with whether the strip fits:
/// when it fits, the [SegmentedButton] takes the full width directly (every
/// segment equally sized, no scroll); when it does not, the intrinsic-width strip
/// is placed in a horizontal scroll view INSIDE the full-width box (BUG-008:
/// every segment stays reachable, nothing clipped off the edge).
///
/// A segmented strip in a config row is intrinsically wide. Giving a controlBelow
/// strip its own full-width row and stretching it (Material [SegmentedButton]
/// under a `double.infinity` width divides the space equally between segments)
/// reads as a deliberate, balanced control. Previously a fitting strip stretched
/// while a too-wide one fell back to a bare scroll view sized to its narrow
/// intrinsic width — so two boxes in one section rendered at different widths
/// (the TODO-882 bug). Now the outer box is unconditionally full-width and only
/// the inner content differs.
///
/// When hosted inline ([controlBelow] false) the strip shares the row with the
/// label and must stay scroll-only, exactly as before, so it never steals the
/// label's width.
class _SegmentedStripHost extends StatelessWidget {
  const _SegmentedStripHost({
    required this.controlBelow,
    required this.segmentLabels,
    required this.strip,
  });

  final bool controlBelow;
  final List<String?> segmentLabels;
  final Widget strip;

  @override
  Widget build(BuildContext context) {
    final Widget scrolling = HorizontalDragScrollable(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: strip,
      ),
    );

    // Inline strips never stretch (they would crowd the label); keep the old
    // shrink-and-scroll behaviour untouched.
    if (!controlBelow) return scrolling;

    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double fontSize = tokens.type.controlLabel.fontSize ?? 14.0;
    final double textScale = MediaQuery.textScalerOf(context).scale(1);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double available = constraints.maxWidth;
        final double estimated = estimateSegmentedStripWidth(
          segmentLabels: segmentLabels,
          fontSize: fontSize,
          textScaleFactor: textScale,
        );
        // A controlBelow strip ALWAYS occupies the full row width so that every
        // segmented box in the same section reads as equal-width (TODO-882: a
        // short strip stretched to fill and a long strip falling back to its
        // intrinsic width previously rendered at different widths). The outer
        // box is therefore unconditionally `width: double.infinity`; only the
        // CHILD differs: when the strip fits we hand the SegmentedButton the
        // bounded full width directly (equal-width segments, no scroll); when it
        // does not fit we put the intrinsic-width strip in a horizontal scroll
        // view so the full-width box still scrolls to the last segment (BUG-008:
        // never clip trailing segments off the edge).
        final bool fits = available.isFinite && estimated <= available;
        return SizedBox(
          width: double.infinity,
          child: fits ? strip : scrolling,
        );
      },
    );
  }
}

/// 独立分段条：直接放在页面/对话框正文里（**不**经过
/// [AdaptiveSettingsSegmentedRow] 那种设置行）的自适应 [SegmentedButton]。
/// 装得下就按自然宽度铺开，装不下就横向滚动，永不把尾部分段裁到画布外。
///
/// BUG-1184：下载设置等页面直接写了裸 `SegmentedButton`。Material 的分段布局把
/// 每段宽度钳到 `可用宽 / 段数`（framework `segmented_button.dart` 的
/// `_calculateHorizontalChildSize`），所以窄屏上**不会**抛 overflow，而是静默
/// 把标签裁字——`qBittorrent`、`Built-in engine (desktop only)` 这类不可断行的
/// 长标签在 360dp 下只剩几个字符，用户根本认不出选项是什么。设置行里的分段控件
/// 早就用 [_SegmentedStripHost] 解决了同一问题（BUG-008），但那套逻辑是私有的、
/// 只服务设置行。本类把同一条契约开放给任意调用点，消除「两套分段控件、只有一套
/// 不裁字」这个特殊情况——而不是在每个调用点各自补一层滚动。
///
/// [alignment] 只在装得下时生效（默认左对齐，与既有裸调用点的外观一致）；装不下
/// 时整条让位给横向滚动视图。
class FushiSegmentedStrip<T extends Object> extends StatelessWidget {
  const FushiSegmentedStrip({
    required this.segments,
    required this.selected,
    required this.onChanged,
    super.key,
    this.style,
    this.alignment = Alignment.centerLeft,
    this.minSegmentWidth,
  });

  final List<ButtonSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onChanged;
  final ButtonStyle? style;
  final AlignmentGeometry alignment;

  /// Uniform per-segment width floor (logical pixels), applied only while the
  /// widened strip still fits its host. Callers that host several strips in one
  /// view pass a shared floor so they read as the same control regardless of
  /// per-strip label lengths; when the floor does not fit, the strip falls back
  /// to its natural width, then to horizontal scrolling -- the floor never
  /// forces a scroll that the natural width would avoid.
  ///
  /// 库页顶栏曾是本参数最大的消费者（TODO-2937 的统一段宽），2026-08-24 起顶栏改走
  /// MD3 tabs（[LibrarySectionTabs]），四页观感一致由「同一个控件」保证，不再需要
  /// 估算出来的等宽下限。
  final double? minSegmentWidth;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double fontSize = tokens.type.controlLabel.fontSize ?? 14.0;
    final double textScale = MediaQuery.textScalerOf(context).scale(1);
    // 与 [_SegmentedStripHost] 同一份估算：只取 Text 段的文案，图标段按固定宽计。
    final List<String?> segmentLabels =
        segments.map<String?>((ButtonSegment<T> s) {
      final Widget? label = s.label;
      return label is Text ? label.data : null;
    }).toList(growable: false);

    final Widget strip = adaptiveSegmentedButton<T>(
      context: context,
      segments: segments,
      selected: <T>{selected},
      onSelectionChanged: (Set<T> values) {
        if (values.isEmpty) return;
        onChanged(values.first);
      },
      style: style,
    );

    // 分段条自然宽是纯 build 期可算量（只依赖标签/字号/缩放，不依赖布局）。
    // 先算出来：页头（[FushiHeaderCrampScope]）用它判定「左边是否摆得下」，
    // LayoutBuilder 里再用同一个值决定滚动兜底。
    final double naturalWidth = estimateSegmentedStripWidth(
      segmentLabels: segmentLabels,
      fontSize: fontSize,
      textScaleFactor: textScale,
    );
    final double preferredWidth = estimateSegmentedStripWidth(
      segmentLabels: segmentLabels,
      fontSize: fontSize,
      textScaleFactor: textScale,
      minSegmentWidth: minSegmentWidth ?? 0.0,
    );
    FushiHeaderCrampScope.maybeOf(
      context,
    )?.reportTitleNaturalWidth(preferredWidth);
    final int selectedIndex = segments.indexWhere(
      (ButtonSegment<T> s) => s.value == selected,
    );

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double available = constraints.maxWidth;
        // BUG-1719: fits => pin the strip to the estimated equal-width total
        // (>= its real intrinsic width) with a tight SizedBox instead of
        // handing the framework loose constraints: under a too-tight bounded
        // width the framework clamps every cell BELOW the widest label, the
        // label wraps and the whole strip grows 8px taller than its siblings
        // (the capture-workbench top bar visibly sank on tab switch). Priority:
        // uniform-floor width, then natural width, then horizontal scroll --
        // in every tier a cell is never narrower than the widest label, so the
        // strip's geometry is stable across hosts and window widths.
        final double? target =
            !available.isFinite || preferredWidth <= available
                ? preferredWidth
                : (naturalWidth <= available ? naturalWidth : null);
        if (target != null) {
          return Align(
            alignment: alignment,
            child: SizedBox(width: target, child: strip),
          );
        }
        // 与上面 [_SegmentedStripHost] 同一契约：装不下就横向滚动，且桌面端要能用
        // 鼠标左键拖着滚（默认 dragDevices 不含 mouse，否则只有滚轮能动）。段内
        // 只有点击目标、没有横拖手势，不存在竞技场之争。
        // 滚动兜底带两侧渐隐 + 选中段自动滚入可视区（可发现性：此前被截断的
        // 尾部分段没有任何「还有更多」的提示，用户以为 tab 没了）。
        return HorizontalDragScrollable(
          child: _SegmentedStripScroller(
            strip: strip,
            segmentLabels: segmentLabels,
            selectedIndex: selectedIndex,
            fontSize: fontSize,
            textScale: textScale,
          ),
        );
      },
    );
  }
}

/// 分段条溢出滚动器：横向滚动 + 两侧渐隐边缘 + 选中段自动滚入可视区。
///
/// 渐隐边缘明示「这排还有更多段」——此前的硬截断没有任何提示，手机窄屏上用户
/// 以为尾部 tab 不存在。选中段偏移用与 [estimateSegmentedStripWidth] 同一套
/// 每段估宽累加（纯 build 期可算，不需要真实测量），误差被余量吸收。
class _SegmentedStripScroller extends StatefulWidget {
  const _SegmentedStripScroller({
    required this.strip,
    required this.segmentLabels,
    required this.selectedIndex,
    required this.fontSize,
    required this.textScale,
  });

  final Widget strip;
  final List<String?> segmentLabels;
  final int selectedIndex;
  final double fontSize;
  final double textScale;

  @override
  State<_SegmentedStripScroller> createState() =>
      _SegmentedStripScrollerState();
}

class _SegmentedStripScrollerState extends State<_SegmentedStripScroller> {
  final ScrollController _controller = ScrollController();

  /// 让相邻段露出一截的余量：既是视觉提示（还有前/后段），也抵消估宽误差。
  static const double _kRevealMargin = 24.0;

  @override
  void initState() {
    super.initState();
    // 首帧后定位（jump 不动画）：打开页面时选中段就在可视区内。
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _ensureSelectedVisible(animate: false),
    );
  }

  @override
  void didUpdateWidget(covariant _SegmentedStripScroller oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      _ensureSelectedVisible(animate: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Material lays every segment out at the SAME width (the widest cell), so
  /// the offset estimate uses the uniform per-cell width too; estimation error
  /// is absorbed by [_kRevealMargin].
  double get _cellWidth => segmentedStripCellWidth(
        segmentLabels: widget.segmentLabels,
        fontSize: widget.fontSize,
        textScaleFactor: widget.textScale,
      );

  void _ensureSelectedVisible({required bool animate}) {
    if (!mounted || !_controller.hasClients) return;
    final int index = widget.selectedIndex;
    if (index < 0 || index >= widget.segmentLabels.length) return;
    final double start = index * _cellWidth;
    final double end = start + _cellWidth;
    final ScrollPosition position = _controller.position;
    final double viewport = position.viewportDimension;
    double? target;
    if (start - _kRevealMargin < position.pixels) {
      target = start - _kRevealMargin;
    } else if (end + _kRevealMargin > position.pixels + viewport) {
      target = end + _kRevealMargin - viewport;
    }
    if (target == null) return;
    final double clamped = target.clamp(0.0, position.maxScrollExtent);
    if (animate) {
      _controller.animateTo(
        clamped,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
    } else {
      _controller.jumpTo(clamped);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FadingEdgeScrollView.fromSingleChildScrollView(
      child: SingleChildScrollView(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        child: widget.strip,
      ),
    );
  }
}

/// Registers a STANDALONE [adaptiveSegmentedButton] (one NOT hosted by an
/// [AdaptiveSettingsSegmentedRow] — e.g. a segmented selector inside a dialog
/// header) as a single gamepad/keyboard focus stop, with D-pad Left/Right
/// cycling the selection in place. Without this the segmented strip is a cluster
/// of native buttons that the directional [FushiFocusController] — which walks
/// only registered targets — skips entirely. Pass the already-built segmented
/// button (or its scroll wrapper) as [child]; it is excluded from inner focus
/// traversal so this is the one stop, while staying mouse/touch-tappable.
class FushiAdjustableSegmented<T extends Object> extends StatelessWidget {
  const FushiAdjustableSegmented({
    required this.values,
    required this.selected,
    required this.onChanged,
    required this.child,
    super.key,
    this.focusIdPrefix = 'segmented',
    this.focusId,
  });

  /// The segment values in display order; [selected] must be one of them.
  final List<T> values;
  final T selected;
  final ValueChanged<T> onChanged;
  final Widget child;
  final String focusIdPrefix;
  final FushiFocusId? focusId;

  @override
  Widget build(BuildContext context) {
    final int currentIndex = values.indexOf(selected);
    void selectAt(int index) {
      if (values.isEmpty) return;
      final int clamped = index.clamp(0, values.length - 1);
      final T value = values[clamped];
      if (value != selected) onChanged(value);
    }

    return _GamepadAdjustableValue(
      focusIdPrefix: focusIdPrefix,
      focusId: focusId,
      onIncrement: () => selectAt(currentIndex + 1),
      onDecrement: () => selectAt(currentIndex - 1),
      child: child,
    );
  }
}

class AdaptiveSettingsPickerOption<T> {
  const AdaptiveSettingsPickerOption({
    required this.value,
    required this.label,
  });

  final T value;
  final String label;
}

class AdaptiveSettingsPickerRow<T> extends StatelessWidget {
  const AdaptiveSettingsPickerRow({
    required this.title,
    required this.options,
    required this.selected,
    required this.onChanged,
    super.key,
    this.subtitle,
    this.icon,
    this.showIcon = false,
    this.placeholder,
    this.materialWidth,
    this.controlBelow = false,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;

  /// 见 [AdaptiveSettingsSwitchRow.showIcon]。仅作用于行内 picker 分支；超过
  /// [kSettingsPickerInlineLimit] 的整页选择器分支沿用「有 icon 即显示」旧契约。
  final bool showIcon;
  final List<AdaptiveSettingsPickerOption<T>> options;
  final T selected;
  final ValueChanged<T> onChanged;
  final String? placeholder;
  final double? materialWidth;
  final bool controlBelow;

  @override
  Widget build(BuildContext context) {
    if (options.length > kSettingsPickerInlineLimit) {
      return _buildFullPageRow(context);
    }
    final bool cupertino = isCupertinoPlatform(context);
    if (!cupertino && isGlassDesign(context)) return _buildGlass(context);
    return AdaptiveSettingsRow(
      title: title,
      subtitle: subtitle,
      icon: icon,
      showIcon: showIcon,
      controlBelow: cupertino ? false : controlBelow,
      trailingFlexible: !cupertino && !controlBelow,
      trailing: cupertino
          ? _buildCupertinoTrailing(context)
          : _buildMaterialDropdown(context),
      onTap: cupertino ? () => _showCupertinoPicker(context) : null,
    );
  }

  /// 「Apple」设计系统：与分段行同一条 [settingsChoiceUsesSegments] 判据——
  /// 少而短的选项是行右侧的 [AppleSettingsSegmentedControl]，否则是
  /// [GlassSettingsPopUpButton]；都恒在行右侧，不撑满、不换行到标题下方。
  Widget _buildGlass(BuildContext context) {
    final List<String> labels = <String>[
      for (final AdaptiveSettingsPickerOption<T> option in options) option.label,
    ];
    void pick(int index) => onChanged(options[index].value);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool useSegments = settingsChoiceUsesSegments(
          labels: labels,
          controlWidth: appleSegmentedControlWidth(labels),
          rowWidth: constraints.maxWidth,
        );
        return AdaptiveSettingsRow(
          title: title,
          subtitle: subtitle,
          icon: icon,
          showIcon: showIcon,
          trailing: useSegments
              ? AppleSettingsSegmentedControl(
                  semanticLabel: title,
                  labels: labels,
                  selectedIndex: _selectedIndex,
                  onChanged: pick,
                )
              : GlassSettingsPopUpButton(
                  semanticLabel: title,
                  labels: labels,
                  selectedIndex: _selectedIndex,
                  placeholder: placeholder,
                  onChanged: pick,
                ),
        );
      },
    );
  }

  /// Long option sets route to a bounded full-page selector
  /// ([FushiOptionSelectionPage]) instead of an anchored overlay that could
  /// overflow the screen. The chosen entry is reported through [onChanged];
  /// backing out (null result) leaves the selection unchanged. Index-keyed so
  /// the page never needs `==`/hashCode on [T].
  Widget _buildFullPageRow(BuildContext context) {
    return AdaptiveSettingsNavigationRow(
      title: title,
      subtitle: _selectedLabel ?? placeholder,
      icon: icon,
      showIcon: icon != null,
      onTap: () async {
        final int? index = await pickOption<int>(
          context,
          title: title,
          selected: _selectedIndex,
          options: <FushiOptionSelectionOption<int>>[
            for (int i = 0; i < options.length; i++)
              FushiOptionSelectionOption<int>(
                value: i,
                label: options[i].label,
              ),
          ],
        );
        if (index != null) onChanged(options[index].value);
      },
    );
  }

  Widget _buildMaterialDropdown(BuildContext context) {
    // GamepadMenuDropdown renders a stock DropdownMenu on Android (engine
    // delivers real key events) and a gamepad-enterable MenuAnchor on desktop
    // (a polled gamepad's D-pad is focus-traversal, not arrow keys, so it can't
    // enter a stock DropdownMenu's menu). Index-keyed so the Android path stays
    // DropdownMenu<int> — entries map option index → label.
    Widget buildDropdown(double? width) {
      return GamepadMenuDropdown<int>(
        width: width,
        label: title,
        hintText: placeholder,
        selected: _selectedIndex,
        onChanged: (int index) => onChanged(options[index].value),
        entries: <GamepadDropdownEntry<int>>[
          for (int i = 0; i < options.length; i++)
            (value: i, label: options[i].label),
        ],
      );
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double maxWidth = constraints.maxWidth;
        if (controlBelow || materialWidth == double.infinity) {
          return buildDropdown(
            maxWidth.isFinite ? maxWidth : kSettingsPickerDefaultWidth,
          );
        }

        final double requestedWidth =
            materialWidth ?? kSettingsPickerDefaultWidth;
        if (!maxWidth.isFinite) return buildDropdown(requestedWidth);
        final double minWidth = maxWidth < kSettingsPickerMinInlineWidth
            ? maxWidth
            : kSettingsPickerMinInlineWidth;
        return buildDropdown(
          requestedWidth.clamp(minWidth, maxWidth).toDouble(),
        );
      },
    );
  }

  Widget _buildCupertinoTrailing(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Color labelColor = CupertinoColors.secondaryLabel.resolveFrom(
      context,
    );
    final Color chevronColor = CupertinoColors.tertiaryLabel.resolveFrom(
      context,
    );
    final String label = _selectedLabel ?? placeholder ?? '';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.42,
          ),
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: tokens.type.metadata.copyWith(color: labelColor),
          ),
        ),
        const SizedBox(width: 6),
        FushiIcon(CupertinoIcons.chevron_down, size: 16, color: chevronColor),
      ],
    );
  }

  Future<void> _showCupertinoPicker(BuildContext context) {
    return showCupertinoModalPopup<void>(
      context: context,
      builder: (BuildContext sheetContext) {
        return CupertinoActionSheet(
          title: Text(title),
          message: subtitle == null ? null : Text(subtitle!),
          actions: [
            for (final option in options)
              CupertinoActionSheetAction(
                isDefaultAction: option.value == selected,
                onPressed: () {
                  Navigator.pop(sheetContext);
                  onChanged(option.value);
                },
                child: Text(option.label),
              ),
          ],
          // app 内文案统一走 slang t.*：MaterialLocalizations 跟系统 locale，
          // 与应用内语言切换脱节（用户把界面切中文后按钮仍是英文）。
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(sheetContext),
            child: Text(t.cancel),
          ),
        );
      },
    );
  }

  String? get _selectedLabel {
    for (final option in options) {
      if (option.value == selected) return option.label;
    }
    return null;
  }

  int? get _selectedIndex {
    for (int i = 0; i < options.length; i++) {
      if (options[i].value == selected) return i;
    }
    return null;
  }
}

class AdaptiveSettingsTextField extends StatefulWidget {
  const AdaptiveSettingsTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.initialValue,
    this.hintText,
    this.labelText,
    this.obscureText = false,
    this.keyboardType = TextInputType.text,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
    this.suffixIcon,
    this.focusId,
  }) : assert(controller == null || initialValue == null);

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? initialValue;
  final String? hintText;
  final String? labelText;
  final bool obscureText;
  final TextInputType keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final Widget? suffixIcon;

  /// Explicit geometric-focus id; when null a stable per-instance fallback is
  /// used so the field is always a directional-navigation anchor (see below).
  final FushiFocusId? focusId;

  @override
  State<AdaptiveSettingsTextField> createState() =>
      _AdaptiveSettingsTextFieldState();
}

class _AdaptiveSettingsTextFieldState extends State<AdaptiveSettingsTextField> {
  // A settings text field MUST register with the directional focus controller,
  // otherwise it is invisible to geometric navigation: when an arrow key escapes
  // the focused (single-line) field, [FushiFocusController.move] cannot locate
  // the active entry and dead-reckons to the FIRST registered row — which can
  // sit ABOVE the field, so Down jumps up (BUG-048). [FushiTextField] only
  // registers when given a focusId, so we always supply one. The id is owned by
  // the State (stable across rebuilds), mirroring [_SettingsRowFocusTarget].
  late final FushiFocusId _fallbackFocusId = FushiFocusId(
    'settings-textfield-${identityHashCode(this)}',
  );

  @override
  Widget build(BuildContext context) {
    return FushiTextField(
      controller: widget.controller,
      focusNode: widget.focusNode,
      initialValue: widget.initialValue,
      hintText: widget.hintText,
      labelText: widget.labelText,
      obscureText: widget.obscureText,
      keyboardType: widget.keyboardType,
      textInputAction: widget.textInputAction,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      suffixIcon: widget.suffixIcon,
      focusId: widget.focusId ?? _fallbackFocusId,
    );
  }
}

/// 设置页里**表单式**小节（下载后端配置、在线服务配置这类一列裸排输入框的段落）
/// 的唯一输入框原语。
///
/// 与 [AdaptiveSettingsTextField] 的分工：那个是「一行一设置」的行式设置项（走
/// [AdaptiveSettingsRow]，自带标题/副标题/图标）；本组件是表单段落里裸排的字段，
/// 标签长在输入框自己的 `labelText` 上，并自带字段间距。
///
/// **宽度契约：恒为可用宽度（`double.infinity`）**，左右基线由所在小节承接
/// （`rowHorizontal`，与普通设置行同一条），字段自身绝不再加一层 `maxWidth`。
///
/// BUG-1858：此前设置页并存三种输入框宽度——下载设置的字段自己缩到 480、那两段
/// 正文又收进 560、其余分类的设置行（[AdaptiveSettingsTextField]）撑满 pane。
/// 用户 2026-08-25 实报「这里和别的输入框宽度不一样」并拍板统一成撑满，两层限宽
/// 随之删除。要再引入宽度上限，只能加在这里（全 app 一处），不能各段自设。
class SettingsFormField extends StatelessWidget {
  const SettingsFormField({
    required this.label,
    required this.onChanged,
    super.key,
    this.initialValue,
    this.controller,
    this.focusNode,
    this.hintText,
    this.helperText,
    this.errorText,
    this.obscureText = false,
    this.keyboardType,
    this.suffixIcon,
    this.bottomSpacing = 8,
  }) : assert(
          initialValue == null || controller == null,
          'initialValue 与 controller 二选一',
        );

  /// 浮动标签（`InputDecoration.labelText`）。
  final String label;

  /// 与 [controller] 二选一：一次性初值。
  final String? initialValue;
  final TextEditingController? controller;
  final FocusNode? focusNode;

  /// 输入后即消失的占位提示。
  final String? hintText;

  /// 常驻说明（`helperText`）：讲清输入框自身讲不完的生效边界，最多 3 行。
  final String? helperText;

  /// 非 null 时以错误态渲染并在下方显示该文案。
  final String? errorText;

  /// 遮蔽输入（密码 / API key）。同时关掉输入建议与自动纠错。
  final bool obscureText;
  final TextInputType? keyboardType;

  /// 贴在输入框尾部的操作按钮（`InputDecoration.suffixIcon`）。
  ///
  /// 存在的理由：一个值只能有一个输入控件。字段旁边另起一个下拉去写同一个值，
  /// 两处必然对不上（BUG-2618），所以「从候选里挑一个填进来」这类操作一律挂在
  /// 字段自己身上。
  final Widget? suffixIcon;

  /// 字段之间的垂直间距（落在字段下方）。
  final double bottomSpacing;

  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) return _buildGlass(context);
    return Padding(
      padding: EdgeInsets.only(bottom: bottomSpacing),
      child: SizedBox(
        width: double.infinity,
        child: TextFormField(
          initialValue: initialValue,
          controller: controller,
          focusNode: focusNode,
          obscureText: obscureText,
          enableSuggestions: !obscureText,
          autocorrect: !obscureText,
          keyboardType: keyboardType,
          decoration: InputDecoration(
            labelText: label,
            hintText: hintText,
            helperText: helperText,
            helperMaxLines: 3,
            errorText: errorText,
            suffixIcon: suffixIcon,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
          onChanged: onChanged,
        ),
      ),
    );
  }

  /// 「玻璃」设计系统：[GlassTextField]（玻璃输入框）。它没有浮动标签 /
  /// helper / error，标签放在框上方、说明与错误放在框下方（iOS 表单写法），
  /// 宽度契约（恒撑满）与间距不变。只给初值时交给有状态的宿主持有控制器。
  Widget _buildGlass(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final String? error = errorText;
    final String? helper = helperText;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomSpacing),
      child: SizedBox(
        width: double.infinity,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 4),
              child: Text(
                label,
                style: tokens.type.metadata.copyWith(
                  color: error != null ? colors.error : null,
                ),
              ),
            ),
            _GlassFormInput(
              initialValue: initialValue,
              controller: controller,
              focusNode: focusNode,
              hintText: hintText,
              obscureText: obscureText,
              keyboardType: keyboardType,
              suffixIcon: suffixIcon,
              onChanged: onChanged,
            ),
            if (error != null || helper != null)
              Padding(
                padding: const EdgeInsets.only(left: 4, top: 4),
                child: Text(
                  error ?? helper!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.metadata.copyWith(
                    color:
                        error != null ? colors.error : colors.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// [SettingsFormField] 玻璃分支的输入框宿主：[GlassTextField] 没有
/// `initialValue`，只给初值时由这里持有控制器。
class _GlassFormInput extends StatefulWidget {
  const _GlassFormInput({
    required this.onChanged,
    this.initialValue,
    this.controller,
    this.focusNode,
    this.hintText,
    this.obscureText = false,
    this.keyboardType,
    this.suffixIcon,
  });

  final String? initialValue;
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? hintText;
  final bool obscureText;
  final TextInputType? keyboardType;
  final Widget? suffixIcon;
  final ValueChanged<String> onChanged;

  @override
  State<_GlassFormInput> createState() => _GlassFormInputState();
}

class _GlassFormInputState extends State<_GlassFormInput> {
  TextEditingController? _owned;

  @override
  void dispose() {
    _owned?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final TextEditingController controller = widget.controller ??
        (_owned ??= TextEditingController(text: widget.initialValue ?? ''));
    return GlassTextField(
      controller: controller,
      focusNode: widget.focusNode,
      placeholder: widget.hintText,
      obscureText: widget.obscureText,
      keyboardType: widget.keyboardType,
      suffixIcon: widget.suffixIcon,
      textStyle: tokens.type.listTitle,
      placeholderStyle: tokens.type.listSubtitle,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      shape: fushiGlassShapeOf(tokens.radii.controlRadius),
      quality: fushiGlassQuality(context),
      onChanged: widget.onChanged,
    );
  }
}

class AdaptiveSettingsStepperRow extends StatelessWidget {
  const AdaptiveSettingsStepperRow({
    required this.title,
    required this.value,
    required this.step,
    required this.min,
    required this.max,
    required this.format,
    required this.onChanged,
    super.key,
    this.subtitle,
    this.icon,
    this.showIcon = false,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;

  /// 见 [AdaptiveSettingsSwitchRow.showIcon]。
  final bool showIcon;
  final double value;
  final double step;
  final double min;
  final double max;
  final String Function(double) format;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsRow(
      title: title,
      subtitle: subtitle,
      icon: icon,
      showIcon: showIcon,
      // BUG-2550：stepper 是最宽的自尺寸 trailing，把实宽报给行，让「窄到标题
      // 放不下」时真的堆叠，而不是把标题削成一个字。
      trailingWidth: kSettingsStepperTrailingWidth,
      trailing: _KeyboardStepper(
        value: value,
        step: step,
        min: min,
        max: max,
        format: format,
        onChanged: onChanged,
      ),
    );
  }
}

class _AdjustUpIntent extends Intent {
  const _AdjustUpIntent();
}

class _AdjustDownIntent extends Intent {
  const _AdjustDownIntent();
}

/// Wraps a value control (stepper / slider / seek bar) as a SINGLE keyboard &
/// gamepad focus stop whose Left/Right adjust the value in place instead of
/// moving focus. The control's own descendants are removed from focus traversal
/// ([ExcludeFocus]) so this wrapper is the one stop; they stay mouse-clickable.
///
/// Up/Down deliberately do NOT adjust the value — they fall through so the user
/// can move focus to the next/previous row. Binding Up/Down to adjust would trap
/// vertical navigation and silently change the focused control's value while the
/// user is only trying to scroll past it.
///
/// On desktop/Apple the gamepad D-pad arrives as a [GamepadButtonIntent] (not
/// arrow keys): Left/Right adjust + consume (return true) so focus does NOT
/// move; Up/Down (and others) are NOT consumed (return false) so the press
/// falls through to directional focus traversal between rows. On Android the
/// engine delivers the D-pad as arrow keys, handled by the [Shortcuts] below —
/// which mirror that contract: only Left/Right are bound.
class _GamepadAdjustableValue extends StatefulWidget {
  const _GamepadAdjustableValue({
    required this.focusIdPrefix,
    required this.onIncrement,
    required this.onDecrement,
    required this.child,
    this.focusId,
    this.autofocus = false,
  });

  final String focusIdPrefix;
  final FushiFocusId? focusId;

  /// 挂载即抢焦点（弹出面板里唯一的调值控件用）。
  final bool autofocus;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;
  final Widget child;

  @override
  State<_GamepadAdjustableValue> createState() =>
      _GamepadAdjustableValueState();
}

class _GamepadAdjustableValueState extends State<_GamepadAdjustableValue> {
  late final FushiFocusId _fallbackFocusId = FushiFocusId(
    '${widget.focusIdPrefix}-${identityHashCode(this)}',
  );

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: <Type, Action<Intent>>{
        _AdjustUpIntent: CallbackAction<_AdjustUpIntent>(
          onInvoke: (_) {
            widget.onIncrement();
            return null;
          },
        ),
        _AdjustDownIntent: CallbackAction<_AdjustDownIntent>(
          onInvoke: (_) {
            widget.onDecrement();
            return null;
          },
        ),
        // 只消费 D-pad 左/右（调值），其余按键**显式转发**给祖先，让它们真的到得了
        // 页面（Y 聚焦搜索、LT/RT 换 tab、D-pad 上下在行间移焦）。原先那句「Flutter
        // 停在第一个 ENABLED 的 action」不成立：Actions.maybeInvoke 上溯停在第一个
        // **注册了该 Intent 类型**的层，enabled 只决定要不要 invoke，所以靠 isEnabled
        // 让位实际是把这些按键静默吞掉。见 [GamepadButtonForwardingAction]。
        GamepadButtonIntent: GamepadButtonForwardingAction(
          ancestorContext: context,
          handle: (GamepadButton button) {
            if (button == GamepadButton.dpadRight) {
              widget.onIncrement();
              return true;
            }
            if (button == GamepadButton.dpadLeft) {
              widget.onDecrement();
              return true;
            }
            return false;
          },
        ),
      },
      child: Shortcuts(
        // Left/Right only — Up/Down are left unbound so they bubble to
        // directional focus traversal (move between rows). See class doc.
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.arrowRight): _AdjustUpIntent(),
          SingleActivator(LogicalKeyboardKey.arrowLeft): _AdjustDownIntent(),
        },
        child: FushiFocusTarget(
          id: widget.focusId ?? _fallbackFocusId,
          autofocus: widget.autofocus,
          child: ExcludeFocus(child: widget.child),
        ),
      ),
    );
  }
}

/// The +/- controls of a stepper row, wrapped as a SINGLE keyboard/gamepad
/// focus stop. Tab lands here once (not once per button), and Left/Right
/// (D-pad or arrow keys) adjust the value in place (Right increment, Left
/// decrement) instead of leaking into directional focus traversal; Up/Down stay
/// free for row-to-row navigation. The inner buttons stay
/// mouse-clickable but are removed from focus traversal so they never become
/// separate, value-less tab stops.
///
/// The focus highlight comes from the app-wide [FushiFocusRing] (drawn around
/// whichever widget holds primary focus in keyboard/gamepad mode), so no local
/// border is reserved here — the control's layout is unchanged.
class _KeyboardStepper extends StatelessWidget {
  const _KeyboardStepper({
    required this.value,
    required this.step,
    required this.min,
    required this.max,
    required this.format,
    required this.onChanged,
  });

  final double value;
  final double step;
  final double min;
  final double max;
  final String Function(double) format;
  final ValueChanged<double> onChanged;

  void _increment() => onChanged((value + step).clamp(min, max));

  void _decrement() => onChanged((value - step).clamp(min, max));

  @override
  Widget build(BuildContext context) {
    final double clampedUp = (value + step).clamp(min, max);
    final double clampedDown = (value - step).clamp(min, max);
    if (isGlassDesign(context)) {
      // 「玻璃」设计系统：读数 + [GlassStepper]（胶囊玻璃 −/+）。总宽与 MD3
      // 版同为 [kSettingsStepperTrailingWidth]，行的堆叠判据不变；单焦点停靠点、
      // 左右调值与读屏语义仍由同一个 _GamepadAdjustableValue + Semantics 提供。
      return _GamepadAdjustableValue(
        focusIdPrefix: 'settings-stepper',
        onIncrement: _increment,
        onDecrement: _decrement,
        child: Semantics(
          container: true,
          slider: true,
          value: format(value),
          increasedValue: format(clampedUp),
          decreasedValue: format(clampedDown),
          onIncrease: value < max ? _increment : null,
          onDecrease: value > min ? _decrement : null,
          excludeSemantics: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                width: kSettingsStepperValueWidth,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.center,
                  child: Text(
                    format(value),
                    textAlign: TextAlign.center,
                    softWrap: false,
                    maxLines: 1,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              GlassStepper(
                value: value,
                min: min,
                max: max,
                step: step,
                width: kSettingsStepperTrailingWidth -
                    kSettingsStepperValueWidth -
                    4,
                quality: fushiGlassQuality(context),
                // 库默认 settings 带一层白色填充；步进器是控件层，取无色透明玻璃。
                settings: fushiClearGlassSettings(context),
                onChanged: (double next) => onChanged(next.clamp(min, max)),
              ),
            ],
          ),
        ),
      );
    }
    // Expose a single "adjustable" node so screen readers (TalkBack / VoiceOver
    // / Narrator) can raise and lower the value via the platform increment /
    // decrement actions — the keyboard arrow shortcuts below are invisible to
    // assistive tech, and the +/- buttons are no longer separate focus stops.
    // excludeSemantics collapses the inner buttons/label into this one node.
    return _GamepadAdjustableValue(
      focusIdPrefix: 'settings-stepper',
      onIncrement: _increment,
      onDecrement: _decrement,
      child: Semantics(
        container: true,
        slider: true,
        value: format(value),
        increasedValue: format(clampedUp),
        decreasedValue: format(clampedDown),
        onIncrease: value < max ? _increment : null,
        onDecrease: value > min ? _decrement : null,
        excludeSemantics: true,
        child: Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          runSpacing: 4,
          children: [
            _SettingsStepButton(
              icon: Icons.remove,
              onPressed: _decrement,
              tooltip: t.decrease,
            ),
            SizedBox(
              width: kSettingsStepperValueWidth,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.center,
                child: Text(
                  format(value),
                  textAlign: TextAlign.center,
                  softWrap: false,
                  maxLines: 1,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            ),
            _SettingsStepButton(
              icon: Icons.add,
              onPressed: _increment,
              tooltip: t.increase,
            ),
          ],
        ),
      ),
    );
  }
}

/// The slider equivalent of [_KeyboardStepper]: a single keyboard/gamepad focus
/// stop whose Left/Right (D-pad or arrow keys) nudge the slider by one step,
/// while the slider stays draggable by mouse/touch. Up/Down are left free for
/// row-to-row focus navigation.
class _KeyboardSlider extends StatelessWidget {
  const _KeyboardSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
    this.label,
    this.onChangeEnd,
    this.step,
    this.autofocus = false,
  });

  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String? label;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;
  final double? step;
  final bool autofocus;

  /// One D-pad/arrow nudge: an explicit [step], else one division, else 1/20 of
  /// the range (a sensible default for continuous sliders).
  double get _step =>
      step ?? (divisions != null ? (max - min) / divisions! : (max - min) / 20);

  void _adjust(double delta) {
    final double next = (value + delta).clamp(min, max);
    onChanged(next);
    onChangeEnd?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    return _GamepadAdjustableValue(
      focusIdPrefix: 'settings-slider',
      autofocus: autofocus,
      onIncrement: () => _adjust(_step),
      onDecrement: () => _adjust(-_step),
      child: Semantics(
        container: true,
        slider: true,
        onIncrease: value < max ? () => _adjust(_step) : null,
        onDecrease: value > min ? () => _adjust(-_step) : null,
        excludeSemantics: true,
        child: adaptiveSlider(
          context: context,
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          label: label,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      ),
    );
  }
}

/// A gamepad/keyboard-adjustable slider for BARE slider sites that are not full
/// settings rows (audio seek bars, playback speed). Same single-focus-stop +
/// D-pad Left/Right (and arrows) nudge-by-[step] behaviour as a slider row,
/// while drag still works for mouse/touch. [step] is the per-press increment
/// (e.g. 5000ms for a seek bar); falls back to one division / 1/20 range.
Widget gamepadSeekableSlider({
  required double value,
  required double max,
  required ValueChanged<double> onChanged,
  double min = 0,
  int? divisions,
  String? label,
  ValueChanged<double>? onChangeEnd,
  double? step,
  bool autofocus = false,
}) {
  return _KeyboardSlider(
    value: value,
    min: min,
    max: max,
    divisions: divisions,
    label: label,
    onChanged: onChanged,
    onChangeEnd: onChangeEnd,
    step: step,
    autofocus: autofocus,
  );
}

class AdaptiveSettingsSliderRow extends StatelessWidget {
  const AdaptiveSettingsSliderRow({
    required this.title,
    required this.value,
    required this.onChanged,
    super.key,
    this.subtitle,
    this.icon,
    this.showIcon = false,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.label,
    this.onChangeEnd,
    this.step,
    this.readout,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;

  /// 见 [AdaptiveSettingsSwitchRow.showIcon]。
  final bool showIcon;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String? label;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  /// Optional explicit gamepad/keyboard nudge step (overrides the
  /// division/default-based step) — for sliders whose natural increment differs
  /// from one division.
  final double? step;

  /// Optional live value readout appended to the displayed title as
  /// `Title (readout)` — fine-grained steps are pointless without a visible
  /// readout. Kept separate from [title] so the bare title remains the row's
  /// stable identity for focus-driven coverage tests and finders.
  final String? readout;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context) &&
        !isCupertinoPlatform(context) &&
        FushiAppleMetrics.of(context).desktop) {
      return _buildGlassDesktop(context);
    }
    if (!isCupertinoPlatform(context) && !isGlassDesign(context)) {
      return _buildMd3(context);
    }
    return AdaptiveSettingsRow(
      title: readout == null ? title : '$title ($readout)',
      subtitle: subtitle,
      icon: icon,
      showIcon: showIcon,
      controlBelow: true,
      trailing: _KeyboardSlider(
        value: value,
        min: min,
        max: max,
        divisions: divisions,
        label: label,
        onChanged: onChanged,
        onChangeEnd: onChangeEnd,
        step: step,
      ),
    );
  }

  /// MD3（Android 16 设置）：标题与说明在上，滑块在下方横跨整行，当前读数
  /// 在滑块右侧（labelLarge、等宽数字）。标题不再拼「(读数)」——读数已经
  /// 常驻在滑块旁。
  Widget _buildMd3(BuildContext context) {
    final String? valueText = readout ?? label;
    final ThemeData theme = Theme.of(context);
    return AdaptiveSettingsRow(
      title: title,
      subtitle: subtitle,
      icon: icon,
      showIcon: showIcon,
      controlBelow: true,
      trailing: Row(
        children: <Widget>[
          Expanded(
            child: _KeyboardSlider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              label: label,
              onChanged: onChanged,
              onChangeEnd: onChangeEnd,
              step: step,
            ),
          ),
          if (valueText != null && valueText.isNotEmpty)
            // 读数槽定宽（不是 minWidth）：读数长短不一（「28」与「1.0x」），
            // 槽宽随字变时同一页各行滑条的右端就参差不齐；超长读数在槽内
            // 等比缩小而不是把滑条挤短。
            SizedBox(
              width: 56,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text(
                  valueText,
                  textAlign: TextAlign.end,
                  maxLines: 1,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 「玻璃」桌面（macOS 系统设置）：标题与说明在左，滑块占行的右半边、
  /// 读数跟在滑块右侧（等宽数字，secondaryLabel），不再把滑块铺到标题下面
  /// 整行宽。trailingFlexible 让滑块拿到有界的「另一半」宽度，随列宽伸缩
  /// （设置页全宽，用户 2026-10-04）。窄到放不下时行照常把控件堆到标题下方。
  Widget _buildGlassDesktop(BuildContext context) {
    final String? valueText = readout ?? label;
    final FushiAppleColors apple = appleColorsOf(context);
    return AdaptiveSettingsRow(
      title: title,
      subtitle: subtitle,
      icon: icon,
      showIcon: showIcon,
      trailingFlexible: true,
      trailing: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double width =
              constraints.maxWidth.isFinite ? constraints.maxWidth : 280;
          return SizedBox(
            width: width,
            child: Row(
              children: <Widget>[
                Expanded(
                  child: _KeyboardSlider(
                    value: value,
                    min: min,
                    max: max,
                    divisions: divisions,
                    label: label,
                    onChanged: onChanged,
                    onChangeEnd: onChangeEnd,
                    step: step,
                  ),
                ),
                if (valueText != null && valueText.isNotEmpty) ...<Widget>[
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 40),
                    child: Text(
                      valueText,
                      textAlign: TextAlign.end,
                      maxLines: 1,
                      style: FushiAppleMetrics.of(context)
                          .subtitleStyle(context)
                          .copyWith(
                        color: apple.secondaryLabel,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class AdaptiveSettingsNavigationRow extends StatelessWidget {
  const AdaptiveSettingsNavigationRow({
    required this.title,
    required this.onTap,
    super.key,
    this.subtitle,
    this.icon,
    this.showIcon = false,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool showIcon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    final Color color = cupertino
        ? CupertinoColors.tertiaryLabel.resolveFrom(context)
        : Theme.of(context).colorScheme.onSurfaceVariant;
    if (isGlassDesign(context) && !cupertino) {
      // 玻璃：iOS 可导航行的行尾 chevron（chevron_forward，tertiaryLabel）。
      return AdaptiveSettingsRow(
        title: title,
        subtitle: subtitle,
        icon: icon,
        showIcon: showIcon && icon != null,
        onTap: onTap,
        trailing: const FushiAppleChevron(),
      );
    }
    return AdaptiveSettingsRow(
      title: title,
      subtitle: subtitle,
      icon: icon,
      showIcon: showIcon && icon != null,
      onTap: onTap,
      trailing: FushiIcon(
        cupertino ? CupertinoIcons.chevron_right : Icons.chevron_right,
        size: cupertino ? 18 : 20,
        color: color,
      ),
    );
  }
}

class _SettingsLabel extends StatelessWidget {
  const _SettingsLabel({
    required this.title,
    this.subtitle,
    this.titleMaxLines,
    this.subtitleMaxLines,
  });

  final String title;
  final String? subtitle;
  final int? titleMaxLines;
  final int? subtitleMaxLines;

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 玻璃：iOS 行文字——标题 17 label、说明 15 secondaryLabel（桌面 15 / 13）。
    final FushiAppleMetrics? apple = isGlassDesign(context) && !cupertino
        ? FushiAppleMetrics.of(context)
        : null;
    // MD3（Android 16 设置）：标题 bodyLarge onSurface、说明 bodyMedium
    // onSurfaceVariant。
    final ThemeData theme = Theme.of(context);
    final TextStyle? titleStyle = apple != null
        ? apple.titleStyle(context)
        : cupertino
            ? tokens.type.listTitle
            : theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurface,
              );
    final Color subtitleColor = cupertino
        ? CupertinoColors.secondaryLabel.resolveFrom(context)
        : theme.colorScheme.onSurfaceVariant;
    final TextStyle? subtitleStyle = apple != null
        ? apple.subtitleStyle(context)
        : cupertino
            ? theme.textTheme.bodySmall?.copyWith(color: subtitleColor)
            : theme.textTheme.bodyMedium?.copyWith(color: subtitleColor);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          title,
          style: titleStyle,
          overflow: TextOverflow.ellipsis,
          maxLines: titleMaxLines ?? kSettingsRowTitleMaxLines,
        ),
        if (subtitle != null && subtitle!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              subtitle!,
              style: subtitleStyle,
              // BUG-1184：null = 不钳行数，说明文字整段显示（见
              // [AdaptiveSettingsRow.subtitleMaxLines]）。
              //
              // overflow 必须跟着 maxLines 走，不能恒为 ellipsis：Flutter 的
              // ellipsis 在 maxLines 缺省时并不是「不生效」，而是把整段压成
              // **单行** + 省略号（RenderParagraph 实测：同一段文字 clip 排 8 行、
              // ellipsis 只排 1 行且 didExceedMaxLines=true）。BUG-1184 把默认从
              // 3 行改成 null 却留着 ellipsis，等于把说明文字从 3 行钳到 1 行——
              // 比修复前更糟。null 时交回 DefaultTextStyle（clip），换行显示整段。
              overflow: subtitleMaxLines == null ? null : TextOverflow.ellipsis,
              maxLines: subtitleMaxLines,
            ),
          ),
      ],
    );
  }
}

class _SettingsIcon extends StatelessWidget {
  const _SettingsIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (!cupertino && isGlassDesign(context)) {
      // 玻璃：行首只是一枚强调色图标，不画底色方块（用户 2026-10-04：图标
      // 不要填充底）。占位宽度沿用 iOS 图标位，保证各行文字左缘对齐。
      final double side = FushiAppleMetrics.of(context).iconTileSize;
      return SizedBox(
        width: side,
        height: side,
        child: FushiIcon(
          icon,
          size: side * 0.78,
          color: appleColorsOf(context).accent,
        ),
      );
    }
    if (!cupertino) {
      // MD3（Android 16 设置）：行首是一枚 24 的单色 onSurfaceVariant 图标，
      // 不再垫 secondaryContainer 色块；外框宽 30 与旧徽章同，各行文字左缘
      // 位置不变。
      return SizedBox(
        width: 30,
        child: Center(
          heightFactor: 1,
          child: FushiBadge(
            icon: icon,
            background: Colors.transparent,
            foreground: scheme.onSurfaceVariant,
            padding: EdgeInsets.zero,
            size: 24,
          ),
        ),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: tokens.radii.controlRadius,
      ),
      child: SizedBox(
        width: 28,
        height: 28,
        child: FushiIcon(icon, size: 18, color: scheme.onPrimary),
      ),
    );
  }
}

class _SettingsStepButton extends StatelessWidget {
  const _SettingsStepButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    if (isCupertinoPlatform(context)) {
      return CupertinoButton(
        padding: EdgeInsets.zero,
        minSize: 30,
        onPressed: onPressed,
        child: FushiIcon(icon, size: 18),
      );
    }
    return IconButton(
      icon: FushiIcon(icon, size: 18),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      onPressed: onPressed,
    );
  }
}
