import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
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
/// - MD3（M3E）：按语义着色的 tonal 色块（info = secondaryContainer、success /
///   warning = tertiaryContainer、error = errorContainer），图标 / 文字 / 动作
///   按钮一律用对应的 on- 色，圆角 16（M3E large）；
/// - Apple：tertiaryFill 实色底（内容层，不是玻璃）圆角 10，单色 SF 图标上
///   语义色（info 用强调色），文字 label 色；动作是无底强调色文字按钮；
/// - 墨水屏：无填充、前景色细描边（底色在灰阶下塌掉，描边才是边界）。
///
/// [title] 可选（加粗一行）；[message] 是正文（字符串或任意 widget，后者用于
/// 「文案 + 来源名」这类组合）；[actions] 在放得下时与正文同一行、贴横幅右侧
/// （正文吃掉其余全部宽度），放不下时换到正文下方（见 [actionsInline]）；
/// [trailing] 排在正文右侧。
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

  /// 同行时动作组最多占内容宽度（图标之后）的比例；超出在这个宽度内换行。
  static const double inlineActionsMaxFraction = 0.45;

  /// 同行时正文至少要留的可读宽度，按正文字号的倍数计（约 16 个汉字）。
  static const double inlineBodyMinEm = 16;

  /// 正文：[String] 或 [Widget]。
  final Object message;
  final FushiNoticeSeverity severity;

  /// 覆盖默认图标（默认按 [severity] 取）。
  final IconData? icon;
  final String? title;
  final Widget? trailing;
  final List<Widget> actions;
  final bool showIcon;

  /// [actions] 是否与正文同一行（排在横幅右侧）：null = 自动——按实测量：动作组
  /// 的内在宽度（封顶 [inlineActionsMaxFraction]）让出后，正文还剩至少
  /// [inlineBodyMinEm] 个字宽就同行，否则换到正文下方；true 恒同行；false
  /// 恒在下方。
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

  /// MD3（M3E）圆角：large 档 16（卡片 / 提示块同形）。
  static const double _md3RadiusValue = 16;

  /// MD3 的 (底色, 前景色, 图标色)：按语义着色的 M3E tonal 色块，图标 / 文字
  /// / 动作都用对应的 on- 色（用户 2026-10-06 拍板「改色块」，覆盖 10-04「去掉
  /// 页面上的彩色块」那条中性底决定）。ColorScheme 没有 success / warning 角色，
  /// 二者共用 tertiaryContainer，语义靠图标区分。
  static ({Color fill, Color foreground, Color iconColor}) _md3Colors(
    ColorScheme cs,
    FushiNoticeSeverity severity,
  ) {
    final (Color fill, Color on) = switch (severity) {
      FushiNoticeSeverity.info => (
        cs.secondaryContainer,
        cs.onSecondaryContainer,
      ),
      FushiNoticeSeverity.success || FushiNoticeSeverity.warning => (
        cs.tertiaryContainer,
        cs.onTertiaryContainer,
      ),
      FushiNoticeSeverity.error => (cs.errorContainer, cs.onErrorContainer),
    };
    return (fill: fill, foreground: on, iconColor: on);
  }

  /// 让色块里的动作 / trailing 控件（FushiTextButton / FushiIconButton /
  /// tonal 按钮等）默认取色块的 on- 色：它们的默认前景读 colorScheme 的
  /// primary / onSurfaceVariant / secondaryContainer，原样放在 tonal 底上会
  /// 撞色（tonal 按钮与 secondaryContainer 底同色直接隐形）。
  static ThemeData _md3ActionTheme(ThemeData theme, Color fill, Color on) {
    final ColorScheme cs = theme.colorScheme;
    return theme.copyWith(
      colorScheme: cs.copyWith(
        primary: on,
        onPrimary: fill,
        secondaryContainer: Color.alphaBlend(on.withValues(alpha: 0.12), fill),
        onSecondaryContainer: on,
        onSurface: on,
        onSurfaceVariant: on,
        outline: on.withValues(alpha: 0.6),
      ),
      iconTheme: theme.iconTheme.copyWith(color: on),
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
    final bool tonal = !eink && !glass;
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
      radius = const BorderRadius.all(Radius.circular(_md3RadiusValue));
    }

    // MD3 色块里的动作 / trailing 换成 on- 色主题；墨水屏与 Apple 原样。
    Widget onTone(Widget child) => tonal
        ? Theme(
            data: _md3ActionTheme(theme, fill!, foreground),
            child: IconTheme.merge(
              data: IconThemeData(color: foreground),
              child: child,
            ),
          )
        : child;

    final TextStyle body = (theme.textTheme.bodyMedium ?? const TextStyle())
        .copyWith(color: foreground);
    final Object message = this.message;
    final Widget messageWidget = message is Widget
        ? DefaultTextStyle.merge(style: body, child: message)
        : Text(message.toString(), style: body);
    final String? title = this.title;

    final Widget textColumn = Column(
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
      ],
    );

    final _NoticeActionsPlacement placement = switch (actionsInline) {
      null => _NoticeActionsPlacement.auto,
      true => _NoticeActionsPlacement.inline,
      false => _NoticeActionsPlacement.below,
    };

    return DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: radius,
        border: eink ? Border.all(color: cs.onSurface) : null,
      ),
      child: Padding(
        // M3E 色块内边距：MD3 水平 16（与列表行同距），其它设计系统沿用旧值。
        padding: EdgeInsets.symmetric(
          horizontal: tonal
              ? tokens.spacing.rowHorizontal
              : tokens.spacing.rowHorizontal - 2,
          vertical: tokens.spacing.rowVertical,
        ),
        child: Row(
          crossAxisAlignment: placement == _NoticeActionsPlacement.inline
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: _NoticeContentLayout(
                hasIcon: showIcon,
                hasActions: actions.isNotEmpty,
                placement: placement,
                iconGap: tokens.spacing.gap + 2,
                actionsGap: tokens.spacing.gap,
                bodyMinWidth: (body.fontSize ?? 14) * inlineBodyMinEm,
                actionsMaxFraction: inlineActionsMaxFraction,
                children: <Widget>[
                  if (showIcon)
                    FushiIcon(
                      icon ?? _defaultIcon(severity),
                      size: 20,
                      color: iconColor,
                    ),
                  textColumn,
                  if (actions.isNotEmpty)
                    onTone(
                      Wrap(
                        spacing: tokens.spacing.gap,
                        runSpacing: tokens.spacing.gap / 2,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: actions,
                      ),
                    ),
                ],
              ),
            ),
            if (trailing != null) ...<Widget>[
              SizedBox(width: tokens.spacing.gap),
              Flexible(
                child: onTone(
                  DefaultTextStyle.merge(
                    style: TextStyle(color: foreground),
                    child: trailing!,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 动作组相对正文的位置。
enum _NoticeActionsPlacement { auto, inline, below }

/// 横幅主体（图标 + 正文 + 动作组）的排布。
///
/// 此前同行动作是 `Row[Expanded(正文), Flexible(Wrap(动作))]`：两者 flex 相同，
/// Row 把剩余宽度对半分，Wrap 在 loose 约束下只撑到内容宽，`WrapAlignment.end`
/// 不生效——宽屏上正文被压到一半宽、按钮停在横幅正中，右半边空着（反馈
/// hIEGAdQjkL）；是否同行也只看写死的 600 断点。这里按实测排：
///
/// - 同行：动作组按内在宽度（封顶内容宽 × [actionsMaxFraction]，但不窄于它最宽
///   那颗按钮）贴右排，超出封顶在该宽度内换行；正文吃掉其余全部宽度；整行垂直
///   居中。
/// - 自动模式下，让出动作组后正文还剩 ≥ [bodyMinWidth] 才同行，否则动作换到
///   正文下方（与正文左对齐），图标贴正文首行。
///
/// 子节点依次是：图标（[hasIcon]）、正文、动作组（[hasActions]）。
class _NoticeContentLayout extends MultiChildRenderObjectWidget {
  const _NoticeContentLayout({
    required this.hasIcon,
    required this.hasActions,
    required this.placement,
    required this.iconGap,
    required this.actionsGap,
    required this.bodyMinWidth,
    required this.actionsMaxFraction,
    required super.children,
  });

  final bool hasIcon;
  final bool hasActions;
  final _NoticeActionsPlacement placement;
  final double iconGap;
  final double actionsGap;
  final double bodyMinWidth;
  final double actionsMaxFraction;

  @override
  _RenderNoticeContent createRenderObject(BuildContext context) =>
      _RenderNoticeContent(
        hasIcon: hasIcon,
        hasActions: hasActions,
        placement: placement,
        iconGap: iconGap,
        actionsGap: actionsGap,
        bodyMinWidth: bodyMinWidth,
        actionsMaxFraction: actionsMaxFraction,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderNoticeContent renderObject,
  ) {
    renderObject
      ..hasIcon = hasIcon
      ..hasActions = hasActions
      ..placement = placement
      ..iconGap = iconGap
      ..actionsGap = actionsGap
      ..bodyMinWidth = bodyMinWidth
      ..actionsMaxFraction = actionsMaxFraction;
  }
}

class _NoticeParentData extends ContainerBoxParentData<RenderBox> {}

/// 一次排布的结果；`performLayout` 与 `computeDryLayout` 共用同一套计算。
class _NoticeArrangement {
  const _NoticeArrangement({
    required this.size,
    required this.iconOffset,
    required this.bodyOffset,
    required this.actionsOffset,
  });

  final Size size;
  final Offset iconOffset;
  final Offset bodyOffset;
  final Offset actionsOffset;
}

class _RenderNoticeContent extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _NoticeParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _NoticeParentData> {
  _RenderNoticeContent({
    required bool hasIcon,
    required bool hasActions,
    required _NoticeActionsPlacement placement,
    required double iconGap,
    required double actionsGap,
    required double bodyMinWidth,
    required double actionsMaxFraction,
  }) : _hasIcon = hasIcon,
       _hasActions = hasActions,
       _placement = placement,
       _iconGap = iconGap,
       _actionsGap = actionsGap,
       _bodyMinWidth = bodyMinWidth,
       _actionsMaxFraction = actionsMaxFraction;

  bool _hasIcon;
  set hasIcon(bool value) {
    if (value == _hasIcon) return;
    _hasIcon = value;
    markNeedsLayout();
  }

  bool _hasActions;
  set hasActions(bool value) {
    if (value == _hasActions) return;
    _hasActions = value;
    markNeedsLayout();
  }

  _NoticeActionsPlacement _placement;
  set placement(_NoticeActionsPlacement value) {
    if (value == _placement) return;
    _placement = value;
    markNeedsLayout();
  }

  double _iconGap;
  set iconGap(double value) {
    if (value == _iconGap) return;
    _iconGap = value;
    markNeedsLayout();
  }

  double _actionsGap;
  set actionsGap(double value) {
    if (value == _actionsGap) return;
    _actionsGap = value;
    markNeedsLayout();
  }

  double _bodyMinWidth;
  set bodyMinWidth(double value) {
    if (value == _bodyMinWidth) return;
    _bodyMinWidth = value;
    markNeedsLayout();
  }

  double _actionsMaxFraction;
  set actionsMaxFraction(double value) {
    if (value == _actionsMaxFraction) return;
    _actionsMaxFraction = value;
    markNeedsLayout();
  }

  RenderBox? get _icon => _hasIcon ? firstChild : null;
  RenderBox get _body => _hasIcon ? childAfter(firstChild!)! : firstChild!;
  RenderBox? get _actions => _hasActions ? lastChild : null;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _NoticeParentData) {
      child.parentData = _NoticeParentData();
    }
  }

  double _iconExtent(double Function(RenderBox icon) measure) {
    final RenderBox? icon = _icon;
    return icon == null ? 0 : measure(icon) + _iconGap;
  }

  /// 同行时动作组可用的最大宽度：内在宽度封顶 [_actionsMaxFraction]，但不窄于
  /// 它最宽的那颗按钮（再窄按钮本身就要被压坏）。
  double _inlineActionsWidth(RenderBox actions, double contentWidth) {
    // 单行自然宽度用无界干布局量：RenderWrap 的 maxIntrinsicWidth 不计 spacing，
    // 按它排会差几颗间距的宽度而折成两行。
    final double natural = actions.getDryLayout(const BoxConstraints()).width;
    final double cap = math.max(
      contentWidth * _actionsMaxFraction,
      actions.getMinIntrinsicWidth(double.infinity),
    );
    return math.min(natural, cap);
  }

  _NoticeArrangement _arrange(
    BoxConstraints constraints,
    ChildLayouter layoutChild,
  ) {
    final RenderBox? icon = _icon;
    final RenderBox body = _body;
    final RenderBox? actions = _actions;
    final Size iconSize = icon == null
        ? Size.zero
        : layoutChild(icon, BoxConstraints.loose(constraints.biggest));
    final double iconExtent = icon == null ? 0 : iconSize.width + _iconGap;
    final double contentWidth = math.max(0, constraints.maxWidth - iconExtent);

    bool inline = false;
    double actionsMax = 0;
    if (actions != null) {
      actionsMax = contentWidth.isFinite
          ? _inlineActionsWidth(actions, contentWidth)
          : double.infinity;
      inline = switch (_placement) {
        _NoticeActionsPlacement.inline => true,
        _NoticeActionsPlacement.below => false,
        _NoticeActionsPlacement.auto =>
          !contentWidth.isFinite ||
              contentWidth - actionsMax - _actionsGap >= _bodyMinWidth,
      };
    }

    if (actions != null && inline) {
      final Size actionsSize = layoutChild(
        actions,
        BoxConstraints(maxWidth: math.min(actionsMax, contentWidth)),
      );
      final double bodyMax = math.max(
        0,
        contentWidth - actionsSize.width - _actionsGap,
      );
      final Size bodySize = layoutChild(
        body,
        BoxConstraints(maxWidth: bodyMax),
      );
      final double width = constraints.hasBoundedWidth
          ? constraints.maxWidth
          : iconExtent + bodySize.width + _actionsGap + actionsSize.width;
      final double height = math.max(
        iconSize.height,
        math.max(bodySize.height, actionsSize.height),
      );
      final Size size = constraints.constrain(Size(width, height));
      double centered(Size child) => (size.height - child.height) / 2;
      return _NoticeArrangement(
        size: size,
        iconOffset: Offset(0, centered(iconSize)),
        bodyOffset: Offset(iconExtent, centered(bodySize)),
        actionsOffset: Offset(
          size.width - actionsSize.width,
          centered(actionsSize),
        ),
      );
    }

    final Size bodySize = layoutChild(
      body,
      BoxConstraints(maxWidth: contentWidth),
    );
    final Size actionsSize = actions == null
        ? Size.zero
        : layoutChild(actions, BoxConstraints(maxWidth: contentWidth));
    final double actionsTop = actions == null
        ? bodySize.height
        : bodySize.height + _actionsGap;
    final double width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : iconExtent + math.max(bodySize.width, actionsSize.width);
    // 图标与正文首行垂直对齐（20 号图标 vs 正文行高约 20）。
    const double iconTop = 1;
    final double height = math.max(
      icon == null ? 0 : iconTop + iconSize.height,
      actionsTop + actionsSize.height,
    );
    return _NoticeArrangement(
      size: constraints.constrain(Size(width, height)),
      iconOffset: const Offset(0, iconTop),
      bodyOffset: Offset(iconExtent, 0),
      actionsOffset: Offset(iconExtent, actionsTop),
    );
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) =>
      _arrange(constraints, ChildLayoutHelper.dryLayoutChild).size;

  @override
  void performLayout() {
    final _NoticeArrangement a = _arrange(
      constraints,
      ChildLayoutHelper.layoutChild,
    );
    size = a.size;
    final RenderBox? icon = _icon;
    if (icon != null) {
      (icon.parentData! as _NoticeParentData).offset = a.iconOffset;
    }
    (_body.parentData! as _NoticeParentData).offset = a.bodyOffset;
    final RenderBox? actions = _actions;
    if (actions != null) {
      (actions.parentData! as _NoticeParentData).offset = a.actionsOffset;
    }
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    final RenderBox? actions = _actions;
    return _iconExtent((RenderBox i) => i.getMinIntrinsicWidth(height)) +
        math.max(
          _body.getMinIntrinsicWidth(height),
          actions?.getMinIntrinsicWidth(height) ?? 0,
        );
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    final RenderBox? actions = _actions;
    return _iconExtent((RenderBox i) => i.getMaxIntrinsicWidth(height)) +
        _body.getMaxIntrinsicWidth(height) +
        (actions == null
            ? 0
            : _actionsGap + actions.getMaxIntrinsicWidth(height));
  }

  @override
  double computeMinIntrinsicHeight(double width) => _arrange(
    BoxConstraints(maxWidth: width),
    ChildLayoutHelper.dryLayoutChild,
  ).size.height;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      computeMinIntrinsicHeight(width);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);
}
