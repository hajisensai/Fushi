import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'package:fushi/src/controls/control_layout.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

/// 由 [ControlLayoutEditor] 交给宿主的「造一个槽位放置区」入口：宿主在舞台预览里
/// 按自己的几何排布槽位，每个槽位调它一次拿到可投放区域。
///
/// [alignment] 是区内按钮的排布方向（左区靠左、中区居中、右区靠右——与真实栏里
/// 的位置一致）；[direction] 为 [Axis.vertical] 时按钮竖排（视频屏幕两侧的竖条）。
typedef ControlSlotRegionBuilder<S> = Widget Function(
  S slot, {
  bool growToContent,
  WrapAlignment alignment,
  Axis direction,
});

/// 宿主描述舞台预览：拿到 [ControlSlotRegionBuilder]，把各槽位排成播放器 / 阅读器
/// 的方位图。hidden 槽不在舞台上（编辑器自己画成「移出」放置区）。
typedef ControlStageBuilder<S> = Widget Function(
  BuildContext context,
  ControlSlotRegionBuilder<S> buildSlotRegion,
);

/// 编辑器上方说明文字的样式：与设置行的说明一致（Apple 13 号 secondaryLabel；
/// MD3 bodyMedium onSurfaceVariant）。
TextStyle? controlLayoutEditorHintStyle(BuildContext context) {
  final ThemeData theme = Theme.of(context);
  if (isGlassDesign(context)) {
    return theme.textTheme.bodySmall?.copyWith(
      color: appleColorsOf(context).secondaryLabel,
    );
  }
  return theme.textTheme.bodyMedium?.copyWith(
    color: theme.colorScheme.onSurfaceVariant,
  );
}

/// 编辑器与舞台共用的视觉参数：两套设计系统各一份。集中在这里是为了让宿主画的
/// 栏 / 竖条 / 文字线与编辑器画的放置区、按钮用同一组颜色和尺寸，不各自猜。
@immutable
class ControlEditorStyle {
  const ControlEditorStyle._({
    required this.apple,
    required this.motion,
    required this.panel,
    required this.panelRadius,
    required this.bar,
    required this.barRadius,
    required this.accent,
    required this.dropFill,
    required this.idleDash,
    required this.icon,
    required this.label,
    required this.secondaryLabel,
    required this.textLine,
    required this.pill,
    required this.hoverFill,
    required this.error,
    required this.lifted,
    required this.iconSize,
    required this.buttonExtent,
  });

  factory ControlEditorStyle.of(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final bool motion =
        !eink && !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    if (isGlassDesign(context)) {
      final FushiAppleColors a = appleColorsOf(context);
      final bool dark = cs.brightness == Brightness.dark;
      return ControlEditorStyle._(
        apple: true,
        motion: motion,
        panel: a.secondaryGroupedBackground,
        panelRadius: const BorderRadius.all(Radius.circular(12)),
        bar: a.tertiaryGroupedBackground,
        barRadius: 24,
        accent: a.accent,
        dropFill: a.accent.withValues(alpha: 0.12),
        idleDash: a.separator,
        icon: a.label,
        label: a.label,
        secondaryLabel: a.secondaryLabel,
        textLine: a.label.withValues(alpha: 0.16),
        pill: Colors.transparent,
        hoverFill: a.tertiaryFill,
        error: a.destructive,
        lifted: dark ? a.tertiaryGroupedBackground : a.groupedBackground,
        iconSize: 20,
        buttonExtent: 36,
      );
    }
    // MD3：容器色阶走设计令牌（group = surfaceContainerLow、card =
    // surfaceContainer、search = surfaceContainerHigh、overlay = Highest），
    // 不在本文件里重开局部 MD3 决定。
    final FushiSurfaceColors s = FushiDesignTokens.of(context).surfaces;
    return ControlEditorStyle._(
      apple: false,
      motion: motion,
      panel: s.group,
      panelRadius: const BorderRadius.all(Radius.circular(16)),
      bar: s.card,
      barRadius: 12,
      accent: cs.primary,
      dropFill: cs.primaryContainer.withValues(alpha: 0.3),
      idleDash: cs.outlineVariant,
      icon: cs.onSurfaceVariant,
      label: cs.onSurface,
      secondaryLabel: cs.onSurfaceVariant,
      // 墨水屏上 0.2 透明度的灰条会被抖动成噪点，改用实色描边色。
      textLine: eink ? cs.outlineVariant : cs.onSurface.withValues(alpha: 0.2),
      pill: s.search,
      hoverFill: cs.onSurface.withValues(alpha: 0.08),
      error: cs.error,
      lifted: s.overlay,
      iconSize: 24,
      buttonExtent: 40,
    );
  }

  final bool apple;

  /// 是否做弹簧 / 浮起动效（墨水屏与系统「减少动画」下关）。
  final bool motion;
  final Color panel;
  final BorderRadius panelRadius;
  final Color bar;
  final double barRadius;
  final Color accent;
  final Color dropFill;
  final Color idleDash;
  final Color icon;
  final Color label;
  final Color secondaryLabel;
  final Color textLine;
  final Color pill;
  final Color hoverFill;
  final Color error;
  final Color lifted;
  final double iconSize;
  final double buttonExtent;

  Duration duration(int milliseconds) =>
      motion ? Duration(milliseconds: milliseconds) : Duration.zero;
}

/// 舞台面板：阅读器 / 播放器的缩略画面（MD3 surfaceContainerLow 圆角 16；
/// Apple secondaryGroupedBackground 圆角 12）。最小高度按宽度等比（[heightRatio]），
/// 内容更高时整体长高——外层设置页本来就纵向滚动，长高不截断任何东西。
class ControlStagePanel extends StatelessWidget {
  const ControlStagePanel({
    super.key,
    required this.child,
    this.heightRatio = 0.56,
    this.minHeight = 220,
    this.maxHeight = 400,
    this.background,
  });

  final Widget child;
  final double heightRatio;
  final double minHeight;
  final double maxHeight;

  /// 覆盖面板底色（例如视频的模拟画面渐变）。
  final Gradient? background;

  @override
  Widget build(BuildContext context) {
    final ControlEditorStyle style = ControlEditorStyle.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double height = constraints.hasBoundedWidth
            ? (constraints.maxWidth * heightRatio).clamp(minHeight, maxHeight)
            : minHeight;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: background == null ? style.panel : null,
            gradient: background,
            borderRadius: style.panelRadius,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: height),
            child: Padding(
              padding: EdgeInsets.all(style.apple ? 10 : 12),
              child: child,
            ),
          ),
        );
      },
    );
  }
}

/// 舞台上的一条顶栏 / 底栏：左 / 中 / 右三个放置区按真实位置排（左区靠左、中区
/// 居中、右区靠右，各最多占三分之一、宽度随内容）。MD3 是 surfaceContainer 圆角
/// 12 的条；Apple 是液态玻璃胶囊。很窄时三个区竖着叠（仍按左 / 中 / 右对齐）。
class ControlStageBar extends StatelessWidget {
  const ControlStageBar({
    super.key,
    required this.start,
    this.center,
    required this.end,
  });

  final Widget start;
  final Widget? center;
  final Widget end;

  /// 低于这个内宽时三区改竖叠：三等分后每区连一颗按钮都放不下。
  static const double stackedBelowWidth = 240;

  @override
  Widget build(BuildContext context) {
    final ControlEditorStyle style = ControlEditorStyle.of(context);
    final Widget? middle = center;
    // LayoutBuilder 放在玻璃外面：玻璃容器可能查询固有尺寸，LayoutBuilder 不支持。
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool stacked = constraints.maxWidth < stackedBelowWidth;
        final Widget content = stacked
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: start),
                  if (middle != null) ...<Widget>[
                    const SizedBox(height: 4),
                    Align(alignment: Alignment.center, child: middle),
                  ],
                  const SizedBox(height: 4),
                  Align(alignment: AlignmentDirectional.centerEnd, child: end),
                ],
              )
            : Row(
                children: <Widget>[
                  Expanded(
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      heightFactor: 1,
                      child: start,
                    ),
                  ),
                  if (middle != null)
                    Expanded(
                      child: Align(
                        alignment: Alignment.center,
                        heightFactor: 1,
                        child: middle,
                      ),
                    ),
                  Expanded(
                    child: Align(
                      alignment: AlignmentDirectional.centerEnd,
                      heightFactor: 1,
                      child: end,
                    ),
                  ),
                ],
              );
        return _StageChrome(
          radius: style.barRadius,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: style.buttonExtent),
            child: content,
          ),
        );
      },
    );
  }
}

/// 舞台上的竖条（视频屏幕两侧的按钮竖排）：与 [ControlStageBar] 同材质。
class ControlStageRail extends StatelessWidget {
  const ControlStageRail({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ControlEditorStyle style = ControlEditorStyle.of(context);
    return _StageChrome(
      radius: style.apple ? style.buttonExtent / 2 + 4 : style.barRadius,
      padding: const EdgeInsets.all(4),
      child: child,
    );
  }
}

/// 栏 / 竖条的材质：MD3 实色圆角条；Apple 液态玻璃（浮在内容上的控件层）。
class _StageChrome extends StatelessWidget {
  const _StageChrome({
    required this.radius,
    required this.padding,
    required this.child,
  });

  final double radius;
  final EdgeInsets padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ControlEditorStyle style = ControlEditorStyle.of(context);
    final Widget padded = Padding(padding: padding, child: child);
    if (style.apple) {
      return GlassContainer(
        useOwnLayer: true,
        quality: fushiGlassQuality(context),
        settings: fushiGlassSettings(context),
        shape: LiquidRoundedSuperellipse(borderRadius: radius),
        child: padded,
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: style.bar,
        borderRadius: BorderRadius.all(Radius.circular(radius)),
      ),
      child: padded,
    );
  }
}

/// 模拟正文的几行文字线（label 色低透明度圆角条），让舞台读出「这是一页书」。
class ControlStageTextLines extends StatelessWidget {
  const ControlStageTextLines({
    super.key,
    this.widthFactors = defaultWidthFactors,
    this.centered = false,
  });

  static const List<double> defaultWidthFactors = <double>[
    0.96,
    0.9,
    0.98,
    0.86,
    0.94,
    0.58,
    0.92,
  ];

  final List<double> widthFactors;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final ControlEditorStyle style = ControlEditorStyle.of(context);
    final double thickness = style.apple ? 6 : 7;
    return ExcludeSemantics(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment:
            centered ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        children: <Widget>[
          for (final double factor in widthFactors)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4.5),
              child: FractionallySizedBox(
                widthFactor: factor,
                child: SizedBox(
                  height: thickness,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: style.textLine,
                      borderRadius: BorderRadius.all(
                        Radius.circular(thickness / 2),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 放置区在一次拖动里的状态：idle 平时；armed 正在拖、这里能放；hover 悬停在
/// 这里且能放；reject 悬停在这里但被拒；dimmed 正在拖、这里放不了（置灰）。
enum _DropState { idle, armed, hover, reject, dimmed }

/// 控制按钮布局拖拽编辑器的泛型骨架：舞台预览（宿主排布）+「可用按钮」托盘 +
/// 「移出」放置区 + 拖拽驳回提示。所有域知识（图标 / 标签 / 槽位名 / 驳回文案 /
/// 舞台几何 / chip 附加交互）由参数注入，本控件只管拖放状态机与 [ControlLayout]
/// 写操作。
///
/// 指针拖放与键盘 / 手柄搬运共用同一套放置判据：按钮可聚焦，Enter（手柄 A）
/// 拿起 → 方向键在槽位间移动（目标区高亮 / 置灰并给驳回原因）→ Enter 放下、
/// Esc（手柄 B）取消。
///
/// 视频页 `VideoControlLayoutEditor` 是第一个宿主；阅读器工具栏编辑器复用同一份。
class ControlLayoutEditor<S extends ControlSlotSpec,
    I extends ControlItemSpec<S>> extends StatefulWidget {
  const ControlLayoutEditor({
    required this.layout,
    required this.onLayoutChanged,
    required this.isTouchControls,
    required this.paletteItems,
    required this.paletteTitle,
    required this.stageBuilder,
    required this.iconOf,
    required this.labelOf,
    required this.slotLabelOf,
    required this.rejectionMessageOf,
    this.dragCanceledMessageOf,
    this.canRenderChip,
    this.wrapChip,
    this.paletteGroupOf,
    this.slotOrder,
    this.keyPrefix = 'control',
    super.key,
  });

  /// 当前生效布局（外部重置 / 持久化后经 rebuild 传入，didUpdateWidget 同步）。
  final ControlLayout<S, I> layout;

  /// 槽位 / 显隐变化后回调（持久化 + 实时生效由宿主负责）。
  final void Function(ControlLayout<S, I> layout)? onLayoutChanged;

  /// 触屏控件：[ControlItemSpec.pinnedOnTouch] 的按钮禁止拖入 hidden。
  final bool isTouchControls;

  /// 「可用按钮」托盘内容（拖出 = 新增一份副本）。
  final List<I> paletteItems;

  final String paletteTitle;

  final ControlStageBuilder<S> stageBuilder;

  final IconData Function(I item) iconOf;
  final String Function(I item) labelOf;
  final String Function(S slot) slotLabelOf;

  /// 拖放被拒时的提示文案（null = 不提示）。宿主按自己的规则解释为什么拒。
  final String? Function(I item, S target) rejectionMessageOf;

  /// 拖拽在任何目标外松手（Draggable 取消）时的提示；null / 返回 null = 不提示。
  final String? Function(I item)? dragCanceledMessageOf;

  /// 哪些按钮能画成单个 chip；null = 全部。画不成 chip 的按钮不出现在槽位里也不接受
  /// 拖放（例如视频的时间文本）。
  final bool Function(I item)? canRenderChip;

  /// 给 chip（已含 Draggable）套一层宿主交互，例如点击改绑自定义动作。
  final Widget Function(BuildContext context, I item, Widget chip)? wrapChip;

  /// 托盘分组：返回分组标题，同标题聚成一组（按首次出现顺序）；null = 不分组。
  final String Function(I item)? paletteGroupOf;

  /// 键盘 / 手柄搬运时方向键遍历槽位的视觉顺序；null = scheme 的槽位顺序。
  final List<S>? slotOrder;

  /// Widget key 前缀：`<prefix>-edit-slot-<slot>` / `<prefix>-chip-…` /
  /// `<prefix>-drag-chip-…`，宿主测试按这些 key 定位。
  final String keyPrefix;

  @override
  State<ControlLayoutEditor<S, I>> createState() =>
      _ControlLayoutEditorState<S, I>();
}

class _ControlLayoutEditorState<S extends ControlSlotSpec,
    I extends ControlItemSpec<S>> extends State<ControlLayoutEditor<S, I>> {
  late ControlLayout<S, I> _layout = widget.layout;
  String? _rejectionMessage;

  /// 指针正在拖的载荷（拖动期间各放置区据此高亮 / 置灰）。
  ControlDragData<S, I>? _pointerDrag;

  /// 指针当前悬停、且拒收的放置区（驳回原因浮层只在这时显示）。
  S? _hoverRejectSlot;

  /// 键盘 / 手柄拿起的载荷与当前目标槽。
  ControlDragData<S, I>? _keyboardDrag;
  S? _keyboardTarget;

  /// 刚落位的那颗按钮（做一次弹簧入场）；[_focusJustPlaced] = 键盘落位后把焦点
  /// 交给它，让用户能接着搬下一颗。
  ({S slot, int index})? _justPlaced;
  bool _focusJustPlaced = false;

  final FocusNode _rootFocus = FocusNode(
    debugLabel: 'ControlLayoutEditor',
    skipTraversal: true,
  );

  S get _hiddenSlot => _layout.scheme.hiddenSlot;

  bool _chipRenderable(I item) => widget.canRenderChip?.call(item) ?? true;

  List<S> get _navSlots => widget.slotOrder ?? _layout.scheme.slots;

  @override
  void didUpdateWidget(ControlLayoutEditor<S, I> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.layout != widget.layout) {
      _layout = widget.layout;
      // 外部重置 / 换布局后清掉上一轮的拖拽驳回提示与键盘搬运：它们描述的是旧
      // 布局上的那次操作，布局已换仍挂着会误导。
      _rejectionMessage = null;
      _keyboardDrag = null;
      _keyboardTarget = null;
    }
  }

  @override
  void dispose() {
    _rootFocus.dispose();
    super.dispose();
  }

  bool get _dragging => _pointerDrag != null || _keyboardDrag != null;

  /// 驳回原因浮层：只在「此刻正悬停 / 键盘指着一个拒收区」时出现。
  bool get _showRejectOverlay {
    if (_pointerDrag != null && _hoverRejectSlot != null) return true;
    final ControlDragData<S, I>? kd = _keyboardDrag;
    final S? target = _keyboardTarget;
    return kd != null && target != null && !_canAcceptPayload(kd, target);
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ControlEditorStyle style = ControlEditorStyle.of(context);
    final String? message = _rejectionMessage;
    final bool overlay = message != null && _showRejectOverlay;
    return Focus(
      focusNode: _rootFocus,
      includeSemantics: false,
      onKeyEvent: _handleEditorKey,
      child: FocusTraversalGroup(
        child: Padding(
          padding: EdgeInsets.all(tokens.spacing.card),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Stack(
                children: <Widget>[
                  widget.stageBuilder(context, _buildSlotRegion),
                  // 拖动中的驳回原因浮在舞台正中（正文区，没有放置区），不挤动
                  // 下方托盘——拖动时布局一跳，手指下的目标就换了。
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Align(
                        alignment: Alignment.center,
                        child: AnimatedSwitcher(
                          duration: style.duration(160),
                          child: overlay
                              ? _buildMessagePill(message, style)
                              : const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              if (!_dragging && message != null) ...<Widget>[
                SizedBox(height: tokens.spacing.gap),
                _buildMessageLine(message, style),
              ],
              SizedBox(height: tokens.spacing.gap * 2),
              LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  final Widget palette = _buildPalette();
                  final Widget removal = _buildSlotRegion(
                    _hiddenSlot,
                    tray: true,
                  );
                  if (constraints.maxWidth >= 640) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expanded(child: palette),
                        SizedBox(width: tokens.spacing.gap * 2),
                        SizedBox(width: 232, child: removal),
                      ],
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      palette,
                      SizedBox(height: tokens.spacing.gap * 1.5),
                      removal,
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessagePill(String message, ControlEditorStyle style) {
    final ThemeData theme = Theme.of(context);
    return ConstrainedBox(
      key: ValueKey<String>(message),
      constraints: const BoxConstraints(maxWidth: 360),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: style.lifted,
          borderRadius: const BorderRadius.all(Radius.circular(18)),
          border: Border.all(color: style.error.withValues(alpha: 0.6)),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                style.apple
                    ? CupertinoIcons.exclamationmark_circle
                    : Icons.block_outlined,
                size: 16,
                color: style.error,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: style.label,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessageLine(String message, ControlEditorStyle style) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(
            style.apple
                ? CupertinoIcons.exclamationmark_circle
                : Icons.info_outline,
            size: 16,
            color: style.error,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            message,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: style.error,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ),
      ],
    );
  }

  Widget _buildPalette() {
    final ThemeData theme = Theme.of(context);
    final ControlEditorStyle style = ControlEditorStyle.of(context);
    final List<String?> groupOrder = <String?>[];
    final Map<String?, List<I>> groups = <String?, List<I>>{};
    for (final I item in widget.paletteItems) {
      final String? group = widget.paletteGroupOf?.call(item);
      if (!groups.containsKey(group)) groupOrder.add(group);
      groups.putIfAbsent(group, () => <I>[]).add(item);
    }
    final TextStyle? titleStyle = style.apple
        ? theme.textTheme.labelLarge?.copyWith(
            color: style.secondaryLabel,
            fontWeight: FontWeight.w600,
          )
        : theme.textTheme.titleSmall?.copyWith(
            color: style.label,
            fontWeight: FontWeight.w700,
          );
    final TextStyle? groupStyle = theme.textTheme.labelMedium?.copyWith(
      color: style.secondaryLabel,
      fontWeight: FontWeight.w600,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            FushiIcon(
              Icons.dashboard_customize_outlined,
              size: 18,
              color: style.apple ? style.secondaryLabel : style.accent,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                widget.paletteTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: titleStyle,
              ),
            ),
          ],
        ),
        for (final String? group in groupOrder) ...<Widget>[
          if (group != null)
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 6),
              child: Text(
                group,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: groupStyle,
              ),
            )
          else
            const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final I item in groups[group]!)
                _buildDraggableChip(item, sourceSlot: null, sourceIndex: null),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildSlotRegion(
    S slot, {
    bool tray = false,
    bool growToContent = false,
    WrapAlignment alignment = WrapAlignment.start,
    Axis direction = Axis.horizontal,
  }) {
    final ThemeData theme = Theme.of(context);
    final ControlEditorStyle style = ControlEditorStyle.of(context);
    final List<({I item, int sourceIndex})> entries = _slotChipEntries(slot);
    final bool vertical = direction == Axis.vertical;
    return DragTarget<ControlDragData<S, I>>(
      key: ValueKey<String>(
        '${widget.keyPrefix}-edit-slot-${slot.storageValue}',
      ),
      onWillAcceptWithDetails:
          (DragTargetDetails<ControlDragData<S, I>> details) =>
              _handleDragWillAccept(details.data, slot),
      onAcceptWithDetails: (DragTargetDetails<ControlDragData<S, I>> details) {
        _moveItem(
          details.data,
          slot,
          targetIndex: _layout.itemsIn(slot).length,
        );
      },
      onLeave: (ControlDragData<S, I>? _) {
        if (_hoverRejectSlot == slot) {
          setState(() => _hoverRejectSlot = null);
        }
      },
      builder: (
        BuildContext context,
        List<ControlDragData<S, I>?> candidate,
        List<dynamic> rejected,
      ) {
        final _DropState state = _dropStateOf(
          slot,
          hoverAccept: candidate.isNotEmpty,
          hoverReject: rejected.isNotEmpty,
        );
        final Widget chips = Wrap(
          direction: direction,
          alignment: alignment,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: tray ? 6 : 2,
          runSpacing: tray ? 6 : 2,
          children: <Widget>[
            for (final ({I item, int sourceIndex}) entry in entries)
              KeyedSubtree(
                key: ValueKey<String>(
                  'placed-${slot.storageValue}-${entry.sourceIndex}-'
                  '${entry.item.storageValue}',
                ),
                child: _buildPlacedChip(
                  entry.item,
                  sourceSlot: slot,
                  sourceIndex: entry.sourceIndex,
                ),
              ),
          ],
        );

        if (tray || !growToContent) {
          // 「移出（隐藏）」放置区：虚线圆角框 + 眼睛划线图标 + 文案，拖进来即隐藏。
          // 归一化后 hidden 槽恒空，下面的 chip 区只给旧数据兜底；按钮多时在区内
          // 小范围滚动，不撑爆外层。滚动区不挂主控制器——编辑器嵌在设置弹窗 /
          // 设置详情页里，那里外层用 PrimaryScrollController 挂 Scrollbar。
          final bool active =
              state == _DropState.hover || state == _DropState.armed;
          final Color tint = state == _DropState.reject
              ? style.error
              : active
                  ? style.accent
                  : style.secondaryLabel;
          final Widget body = Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(
                      style.apple
                          ? CupertinoIcons.eye_slash
                          : Icons.visibility_off_outlined,
                      size: 20,
                      color: tint,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.slotLabelOf(slot),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: active ? style.accent : style.label,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                if (entries.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: tray ? 120 : 148),
                    child: SingleChildScrollView(
                      primary: false,
                      child: chips,
                    ),
                  ),
                ],
              ],
            ),
          );
          return _decorateRegion(
            state: state,
            style: style,
            radius: BorderRadius.all(Radius.circular(style.apple ? 12 : 16)),
            alwaysDashed: true,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                heightFactor: 1,
                child: body,
              ),
            ),
          );
        }

        final Widget content;
        if (entries.isEmpty) {
          // 空区：淡虚线占位，写着槽位名（「拖到这里」的位置提示）。
          final double extent = style.buttonExtent;
          content = ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: vertical ? extent : 72,
              minHeight: vertical ? 72 : extent,
            ),
            child: Align(
              widthFactor: 1,
              heightFactor: 1,
              child: vertical
                  ? Icon(
                      style.apple ? CupertinoIcons.plus : Icons.add,
                      size: 16,
                      color: style.secondaryLabel.withValues(alpha: 0.7),
                    )
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Text(
                        widget.slotLabelOf(slot),
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: style.secondaryLabel,
                        ),
                      ),
                    ),
            ),
          );
        } else {
          content = chips;
        }
        final double r = vertical
            ? style.buttonExtent / 2 + 2
            : (style.apple ? style.buttonExtent / 2 + 2 : 10);
        return _decorateRegion(
          state: state,
          style: style,
          radius: BorderRadius.all(Radius.circular(r)),
          alwaysDashed: entries.isEmpty,
          child: AnimatedSize(
            duration: style.duration(220),
            curve: FushiSpringCurve.spatial,
            alignment: switch (alignment) {
              WrapAlignment.center => Alignment.center,
              WrapAlignment.end => AlignmentDirectional.centerEnd,
              _ => AlignmentDirectional.centerStart,
            },
            child: Padding(padding: const EdgeInsets.all(2), child: content),
          ),
        );
      },
    );
  }

  /// 放置区的状态外观：可放 = 强调色虚线 + 浅底；悬停 = 加深；拒收 = 错误色；
  /// 放不了 = 置灰。[alwaysDashed] 的区（空区 / 移出区）平时也画淡虚线。
  Widget _decorateRegion({
    required _DropState state,
    required ControlEditorStyle style,
    required BorderRadius radius,
    required bool alwaysDashed,
    required Widget child,
  }) {
    Color fill = Colors.transparent;
    Color? dash = alwaysDashed ? style.idleDash : null;
    double width = 1.2;
    switch (state) {
      case _DropState.idle:
      case _DropState.dimmed:
        break;
      case _DropState.armed:
        dash = style.accent.withValues(alpha: 0.55);
        fill = style.dropFill.withValues(alpha: style.dropFill.a * 0.5);
      case _DropState.hover:
        dash = style.accent;
        fill = style.dropFill;
        width = 1.8;
      case _DropState.reject:
        dash = style.error;
        fill = style.error.withValues(alpha: 0.08);
        width = 1.8;
    }
    // 结构恒定：CustomPaint 永远在，只换 painter。按 dash 有无增删这一层会让
    // 拖动开始（idle → armed）时整棵区内子树重挂——源按钮的 Draggable 随之卸载，
    // 它的 onDragEnd 不再回调（Draggable 只在 mounted 时调），编辑器卡在「拖动中」，
    // 松手后的驳回原因永远不显示。
    final Widget box = CustomPaint(
      foregroundPainter: dash == null
          ? null
          : _DashedBorderPainter(
              color: dash,
              radius: radius,
              strokeWidth: width,
            ),
      child: AnimatedContainer(
        duration: style.duration(140),
        decoration: BoxDecoration(color: fill, borderRadius: radius),
        child: child,
      ),
    );
    return AnimatedOpacity(
      duration: style.duration(140),
      opacity: state == _DropState.dimmed ? 0.38 : 1,
      child: box,
    );
  }

  _DropState _dropStateOf(
    S slot, {
    required bool hoverAccept,
    required bool hoverReject,
  }) {
    if (hoverAccept) return _DropState.hover;
    if (hoverReject) return _DropState.reject;
    final ControlDragData<S, I>? kd = _keyboardDrag;
    if (kd != null && _keyboardTarget == slot) {
      return _canAcceptPayload(kd, slot) ? _DropState.hover : _DropState.reject;
    }
    final ControlDragData<S, I>? active = _pointerDrag ?? kd;
    if (active == null) return _DropState.idle;
    return _canAcceptPayload(active, slot)
        ? _DropState.armed
        : _DropState.dimmed;
  }

  List<({I item, int sourceIndex})> _slotChipEntries(S slot) {
    final List<I> items = _layout.itemsIn(slot);
    return <({I item, int sourceIndex})>[
      for (int index = 0; index < items.length; index++)
        if (_chipRenderable(items[index]))
          (item: items[index], sourceIndex: index),
    ];
  }

  Widget _buildPlacedChip(
    I item, {
    required S sourceSlot,
    required int sourceIndex,
  }) {
    final ({S slot, int index})? placed = _justPlaced;
    final bool justPlaced = placed != null &&
        placed.slot == sourceSlot &&
        placed.index == sourceIndex;
    final ControlEditorStyle style = ControlEditorStyle.of(context);
    return DragTarget<ControlDragData<S, I>>(
      onWillAcceptWithDetails:
          (DragTargetDetails<ControlDragData<S, I>> details) =>
              _handleDragWillAccept(details.data, sourceSlot),
      onAcceptWithDetails: (DragTargetDetails<ControlDragData<S, I>> details) {
        _moveItem(details.data, sourceSlot, targetIndex: sourceIndex);
      },
      builder: (
        BuildContext context,
        List<ControlDragData<S, I>?> candidate,
        List<dynamic> rejected,
      ) {
        // 落位弹簧：新落下的那颗从 0.6 弹到 1（只在挂载时跑一次）。
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: justPlaced ? 0.6 : 1, end: 1),
          duration: style.duration(420),
          curve: FushiSpringCurve.spatialFast,
          builder: (BuildContext context, double scale, Widget? child) =>
              Transform.scale(scale: scale, child: child),
          child: _buildDraggableChip(
            item,
            sourceSlot: sourceSlot,
            sourceIndex: sourceIndex,
            highlighted: candidate.isNotEmpty,
            focusOnMount: justPlaced && _focusJustPlaced,
          ),
        );
      },
    );
  }

  Widget _buildDraggableChip(
    I item, {
    required S? sourceSlot,
    required int? sourceIndex,
    bool highlighted = false,
    bool focusOnMount = false,
  }) {
    final ControlEditorStyle style = ControlEditorStyle.of(context);
    final ControlDragData<S, I> payload = ControlDragData<S, I>(
      item: item,
      sourceSlot: sourceSlot,
      sourceIndex: sourceIndex,
    );
    final Widget chip = _chipBody(
      item,
      payload: payload,
      highlighted: highlighted,
      focusOnMount: focusOnMount,
    );
    final Widget draggable = Draggable<ControlDragData<S, I>>(
      data: payload,
      hitTestBehavior: HitTestBehavior.opaque,
      feedback: _buildDragFeedback(item, style),
      childWhenDragging: Opacity(opacity: 0.3, child: chip),
      onDragStarted: () => _handlePointerDragStarted(payload),
      onDragEnd: (DraggableDetails _) => _handlePointerDragEnded(),
      onDraggableCanceled: (_, __) => _handleDragCanceled(item),
      child: chip,
    );
    return widget.wrapChip?.call(context, item, draggable) ?? draggable;
  }

  /// 拖起时手指下浮起的胶囊（图标 + 名称，带阴影、放大 1.05）。
  Widget _buildDragFeedback(I item, ControlEditorStyle style) {
    final ThemeData theme = Theme.of(context);
    return Material(
      type: MaterialType.transparency,
      child: Transform.scale(
        scale: 1.05,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: style.lifted,
            borderRadius: const BorderRadius.all(Radius.circular(20)),
            border: Border.all(color: style.accent.withValues(alpha: 0.45)),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.28),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: SizedBox(
              height: 40,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  FushiIcon(
                    widget.iconOf(item),
                    size: 20,
                    color: style.apple ? style.label : style.accent,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    widget.labelOf(item),
                    maxLines: 1,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: style.label,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _handlePointerDragStarted(ControlDragData<S, I> payload) {
    setState(() {
      _pointerDrag = payload;
      _hoverRejectSlot = null;
      _keyboardDrag = null;
      _keyboardTarget = null;
    });
  }

  void _handlePointerDragEnded() {
    if (!mounted) return;
    setState(() {
      _pointerDrag = null;
      _hoverRejectSlot = null;
    });
  }

  void _handleDragCanceled(I item) {
    final String? message = widget.dragCanceledMessageOf?.call(item);
    if (message == null || _rejectionMessage == message) return;
    setState(() => _rejectionMessage = message);
  }

  bool _isKeyboardPayload(ControlDragData<S, I> payload) {
    final ControlDragData<S, I>? kd = _keyboardDrag;
    return kd != null &&
        kd.item == payload.item &&
        kd.sourceSlot == payload.sourceSlot &&
        kd.sourceIndex == payload.sourceIndex;
  }

  bool _isPlacedOnStage(I item) =>
      _layout.slotsOf(item).any((S slot) => slot != _hiddenSlot);

  Widget _chipBody(
    I item, {
    required ControlDragData<S, I> payload,
    required bool highlighted,
    required bool focusOnMount,
  }) {
    final ControlEditorStyle style = ControlEditorStyle.of(context);
    final String label = widget.labelOf(item);
    final S? sourceSlot = payload.sourceSlot;
    final bool palette = sourceSlot == null;
    final bool lifted = _isKeyboardPayload(payload);
    final String sourceSlotKey = sourceSlot?.storageValue ?? 'palette';
    final String sourceIndexKey = payload.sourceIndex?.toString() ?? 'palette';
    final String keySuffix =
        '${item.storageValue}-$sourceSlotKey-$sourceIndexKey';
    final Widget shell = _ChipFocusShell(
      focusOnMount: focusOnMount,
      onKeyEvent: (KeyEvent event) => _handleChipKey(payload, event),
      builder: (BuildContext context, bool hovered, bool focused) => palette
          ? _paletteBody(item, style, hovered, focused || lifted, lifted)
          : _placedBody(
              item,
              style,
              hovered,
              focused || lifted || highlighted,
              lifted,
              highlighted,
            ),
    );
    final Widget semantics = Semantics(
      key: ValueKey<String>('${widget.keyPrefix}-chip-$keySuffix'),
      label: label,
      button: true,
      container: true,
      child: Listener(
        key: ValueKey<String>('${widget.keyPrefix}-drag-chip-$keySuffix'),
        behavior: HitTestBehavior.opaque,
        child: ExcludeSemantics(child: shell),
      ),
    );
    // 托盘胶囊自带文字，不再挂悬停名称；栏里的按钮只有图标，悬停 / 长按出名称。
    if (palette) return semantics;
    return FushiTooltip(message: label, child: semantics);
  }

  /// 栏里的按钮：与阅读器 chrome 同观感——MD3 无底 24 图标、Apple 单色 SF 图标，
  /// 悬停铺一层圆形状态底，键盘焦点 / 拿起时一圈强调色环。
  Widget _placedBody(
    I item,
    ControlEditorStyle style,
    bool hovered,
    bool ring,
    bool lifted,
    bool highlighted,
  ) {
    final double extent = style.buttonExtent;
    final Color fill = highlighted
        ? style.dropFill
        : hovered || lifted
            ? style.hoverFill
            : Colors.transparent;
    return AnimatedScale(
      scale: lifted ? 1.08 : 1,
      duration: style.duration(260),
      curve: FushiSpringCurve.spatialFast,
      child: AnimatedContainer(
        duration: style.duration(120),
        width: extent,
        height: extent,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: fill,
          shape: BoxShape.circle,
          border: Border.all(
            color: ring ? style.accent : Colors.transparent,
            width: 2,
          ),
          boxShadow: lifted
              ? <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.22),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ]
              : null,
        ),
        child: FushiIcon(
          widget.iconOf(item),
          size: style.iconSize,
          color: style.icon,
        ),
      ),
    );
  }

  /// 托盘胶囊：图标 + 名称，高 36。MD3 surfaceContainerHigh 胶囊；Apple 透明
  /// 液态玻璃胶囊。已放在栏里的按钮淡化并带小对勾（仍可再拖一份副本）。
  Widget _paletteBody(
    I item,
    ControlEditorStyle style,
    bool hovered,
    bool ring,
    bool lifted,
  ) {
    final ThemeData theme = Theme.of(context);
    final bool used = _isPlacedOnStage(item);
    const BorderRadius radius = BorderRadius.all(Radius.circular(18));
    final Widget row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: SizedBox(
        height: 36,
        // 托盘 Wrap 极窄时（320px 窄窗 × 界面缩放 2.0，胶囊只剩几十像素）名称可以
        // 省略到 0，但「图标 + 间距 + 对勾」的固定宽度（18 + 6 + 4 + 14）放不下就
        // 会横向溢出；此时只省掉对勾——「已放在栏里」仍由整颗胶囊淡化表达。
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool showUsedMark = used && constraints.maxWidth >= 42;
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                FushiIcon(widget.iconOf(item), size: 18, color: style.label),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    widget.labelOf(item),
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: style.label,
                    ),
                  ),
                ),
                if (showUsedMark) ...<Widget>[
                  const SizedBox(width: 4),
                  Icon(
                    style.apple ? CupertinoIcons.checkmark_alt : Icons.check,
                    size: 14,
                    color: style.accent,
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
    final Widget stateLayer = AnimatedContainer(
      duration: style.duration(120),
      decoration: BoxDecoration(
        color: hovered ? style.hoverFill : Colors.transparent,
        borderRadius: radius,
        border: Border.all(
          color: ring ? style.accent : Colors.transparent,
          width: 2,
        ),
      ),
      child: row,
    );
    final Widget pill = style.apple
        ? GlassContainer(
            useOwnLayer: true,
            quality: fushiGlassQuality(context),
            settings: fushiGlassSettings(context),
            shape: const LiquidRoundedSuperellipse(borderRadius: 18),
            child: stateLayer,
          )
        : DecoratedBox(
            decoration: BoxDecoration(color: style.pill, borderRadius: radius),
            child: stateLayer,
          );
    return AnimatedOpacity(
      duration: style.duration(160),
      opacity: used && !lifted ? 0.62 : 1,
      child: AnimatedScale(
        scale: lifted ? 1.05 : 1,
        duration: style.duration(260),
        curve: FushiSpringCurve.spatialFast,
        child: pill,
      ),
    );
  }

  // ── 键盘 / 手柄搬运 ───────────────────────────────────────────────

  static bool _isActivateKey(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter ||
      key == LogicalKeyboardKey.gameButtonA;

  /// 按钮上的按键：没在搬运时 Enter 拿起；搬运中一律放行，冒泡给编辑器根节点
  /// （方向键换目标 / Enter 放下 / Esc 取消）。
  KeyEventResult _handleChipKey(
    ControlDragData<S, I> payload,
    KeyEvent event,
  ) {
    if (event is! KeyDownEvent || _keyboardDrag != null) {
      return KeyEventResult.ignored;
    }
    if (!_isActivateKey(event.logicalKey)) return KeyEventResult.ignored;
    final List<S> slots = _navSlots;
    final S start = payload.sourceSlot ??
        slots.firstWhere(
          (S slot) => slot != _hiddenSlot,
          orElse: () => slots.first,
        );
    setState(() {
      _keyboardDrag = payload;
      _keyboardTarget = start;
      _rejectionMessage = _messageFor(payload, start);
    });
    return KeyEventResult.handled;
  }

  KeyEventResult _handleEditorKey(FocusNode node, KeyEvent event) {
    if (_keyboardDrag == null || event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.gameButtonB) {
      if (event is KeyDownEvent) _cancelKeyboardDrag();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowUp) {
      _stepKeyboardTarget(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowDown) {
      _stepKeyboardTarget(1);
      return KeyEventResult.handled;
    }
    if (_isActivateKey(key)) {
      if (event is KeyDownEvent) _dropKeyboardDrag();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab) _cancelKeyboardDrag();
    return KeyEventResult.ignored;
  }

  String? _messageFor(ControlDragData<S, I> payload, S target) =>
      _canAcceptPayload(payload, target)
          ? null
          : widget.rejectionMessageOf(payload.item, target);

  void _stepKeyboardTarget(int delta) {
    final ControlDragData<S, I>? payload = _keyboardDrag;
    final S? current = _keyboardTarget;
    if (payload == null || current == null) return;
    final List<S> slots = _navSlots;
    final int index = math.max(0, slots.indexOf(current));
    final S next = slots[(index + delta) % slots.length];
    setState(() {
      _keyboardTarget = next;
      _rejectionMessage = _messageFor(payload, next);
    });
  }

  void _cancelKeyboardDrag() {
    setState(() {
      _keyboardDrag = null;
      _keyboardTarget = null;
      _rejectionMessage = null;
    });
  }

  void _dropKeyboardDrag() {
    final ControlDragData<S, I>? payload = _keyboardDrag;
    final S? target = _keyboardTarget;
    if (payload == null || target == null) return;
    if (!_canAcceptPayload(payload, target)) {
      setState(() => _rejectionMessage = _messageFor(payload, target));
      return;
    }
    setState(() {
      _keyboardDrag = null;
      _keyboardTarget = null;
    });
    final bool moved = _moveItem(
      payload,
      target,
      targetIndex: _layout.itemsIn(target).length,
      byKeyboard: payload.sourceSlot != null,
    );
    // 被搬走的是栏里那颗（它已卸载）且没有新位置可接焦点（移出 / 未变化）：
    // 焦点交回编辑器根节点，Tab 仍能继续在编辑器里走。
    if (payload.sourceSlot != null && (!moved || target == _hiddenSlot)) {
      _rootFocus.requestFocus();
    }
  }

  // ── 放置判据与写操作 ─────────────────────────────────────────────

  bool _canAcceptPayload(ControlDragData<S, I> payload, S target) {
    final I item = payload.item;
    if (!_chipRenderable(item)) return false;
    if (!item.canMoveToSlot(target, isTouchControls: widget.isTouchControls)) {
      return false;
    }
    if (payload.sourceSlot == target) return true;
    return !_layout.itemsIn(target).contains(item);
  }

  bool _handleDragWillAccept(ControlDragData<S, I> payload, S target) {
    final bool accepted = _canAcceptPayload(payload, target);
    final String? message =
        accepted ? null : widget.rejectionMessageOf(payload.item, target);
    final S? hoverReject = accepted ? null : target;
    if (_rejectionMessage != message || _hoverRejectSlot != hoverReject) {
      setState(() {
        _rejectionMessage = message;
        _hoverRejectSlot = hoverReject;
      });
    }
    return accepted;
  }

  /// 返回布局是否真的变了。
  bool _moveItem(
    ControlDragData<S, I> payload,
    S target, {
    int? targetIndex,
    bool byKeyboard = false,
  }) {
    final ControlLayout<S, I> next =
        _layout.moveDraggedItem(payload, target, targetIndex: targetIndex);
    if (next == _layout) return false;
    final int placedIndex =
        target == _hiddenSlot ? -1 : next.itemsIn(target).indexOf(payload.item);
    setState(() {
      _layout = next;
      _rejectionMessage = null;
      _hoverRejectSlot = null;
      _justPlaced = placedIndex < 0 ? null : (slot: target, index: placedIndex);
      _focusJustPlaced = byKeyboard;
    });
    widget.onLayoutChanged?.call(next);
    return true;
  }
}

/// 单颗按钮的焦点 / 悬停外壳：可 Tab 聚焦（焦点环只在键盘高亮模式下显示），
/// 把按键交给编辑器的搬运状态机。不贡献语义（外层 Semantics 已是按钮节点）。
class _ChipFocusShell extends StatefulWidget {
  const _ChipFocusShell({
    required this.onKeyEvent,
    required this.builder,
    this.focusOnMount = false,
  });

  final KeyEventResult Function(KeyEvent event) onKeyEvent;
  final Widget Function(BuildContext context, bool hovered, bool focused)
      builder;
  final bool focusOnMount;

  @override
  State<_ChipFocusShell> createState() => _ChipFocusShellState();
}

class _ChipFocusShellState extends State<_ChipFocusShell> {
  final FocusNode _node = FocusNode(debugLabel: 'ControlLayoutEditorChip');
  bool _hovered = false;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    if (widget.focusOnMount) {
      // 键盘落位后新挂载的这颗接过焦点；挂载发生在 setState 触发的那一帧里，
      // 帧尾回调必然会跑。
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        if (mounted) _node.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool keyboardHighlight =
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    return Focus(
      focusNode: _node,
      includeSemantics: false,
      onFocusChange: (bool focused) => setState(() => _focused = focused),
      onKeyEvent: (FocusNode _, KeyEvent event) => widget.onKeyEvent(event),
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        onEnter: (PointerEnterEvent _) => setState(() => _hovered = true),
        onExit: (PointerExitEvent _) => setState(() => _hovered = false),
        child: widget.builder(context, _hovered, _focused && keyboardHighlight),
      ),
    );
  }
}

/// 圆角虚线描边（放置区占位 / 可放高亮 / 移出区）。
class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({
    required this.color,
    required this.radius,
    required this.strokeWidth,
  });

  final Color color;
  final BorderRadius radius;
  final double strokeWidth;

  static const double _dash = 5;
  static const double _gap = 4;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    final RRect rrect =
        radius.toRRect(Offset.zero & size).deflate(strokeWidth / 2);
    final Path path = Path()..addRRect(rrect);
    for (final PathMetric metric in path.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        final double end = math.min(distance + _dash, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance += _dash + _gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.radius != radius ||
      oldDelegate.strokeWidth != strokeWidth;
}
