import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart'
    show
        FushiToolbarItem,
        FushiTopBarOverflowFit,
        fushiTopBarActionsBudget,
        kFushiFloatingTopBarTitleMinWidth;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show FushiIconButtonControl;
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiPopupMenuItem;
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart'
    show FushiPopupMenuButton;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// [FushiAdaptiveActionStrip] 里的一个动作。
@immutable
class FushiAdaptiveAction {
  const FushiAdaptiveAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.key,
    this.foldedKey,
    this.inlineBuilder,
    this.foldedEntries,
    this.foldedDividerBefore = false,
    this.inlineSlots = 1,
  }) : assert(inlineSlots >= 1);

  final IconData icon;

  /// 平铺时的 tooltip / 无障碍文案，收进「⋯」后的菜单文字。
  final String label;

  /// null = 禁用（平铺钮置灰、菜单项禁用）。
  final VoidCallback? onPressed;
  final bool selected;

  /// 平铺成图标钮时的 key。
  final Key? key;

  /// 收进「⋯」后菜单项的 key。
  final Key? foldedKey;

  /// 自定义平铺形态（如自带弹出菜单的按钮）；null = 普通图标钮。宽度应与普通
  /// 图标钮一致（48 触控目标），测宽按这个槽位算。
  final WidgetBuilder? inlineBuilder;

  /// 自定义收进「⋯」后的菜单条目（如把子菜单项就地展开）；null = 一条
  /// 「图标 + 文字」项。条目的 value 是被选中时要执行的回调。
  final List<PopupMenuEntry<VoidCallback>> Function(BuildContext context)?
  foldedEntries;

  /// 收进「⋯」后，本动作前画一条分隔线（分组）。
  final bool foldedDividerBefore;

  /// 自定义平铺形态占几个 48dp 槽位（如「− 100% +」字号步进器占 3 个）。测宽
  /// 按这个数算，不按"一个动作 = 一个槽位"低估。普通图标钮保持 1。
  final int inlineSlots;
}

/// 默认展开、空间不足才收起的动作条（用户 2026-10-06 拍板）。
///
/// [actions] 按给出顺序（= 优先级，最后一个最低）先全部平铺成 48dp 命中区的图标
/// 钮，宽度放不下时从最低优先级起依次收进「⋯」溢出菜单，全放得下就不画「⋯」。
/// 测宽与展开回差复用顶栏同一套 [FushiTopBarOverflowFit]（与
/// `FushiFloatingTopBar.adaptiveOverflow` 同一份实现），不另写测宽逻辑。
///
/// 预算 = [maxWidth]（给了就用）否则 屏宽 - [reservedWidth]。放在 AppBar 的
/// actions 里时必须用 [reservedWidth] 扣掉返回钮与标题的保底宽度（见
/// [fushiTopBarActionsBudget]）；放在窄面板里的调用方自己量好宽度传 [maxWidth]。
class FushiAdaptiveActionStrip extends StatefulWidget {
  const FushiAdaptiveActionStrip({
    required this.actions,
    super.key,
    this.maxWidth,
    this.reservedWidth = 0,
    this.moreKey,
    this.moreTooltip,
    this.foldFromStart = false,
  });

  final List<FushiAdaptiveAction> actions;

  /// true = 优先级反过来（列表**最后**一个最高）：放不下时从列表**开头**起收进
  /// 「⋯」，「⋯」排在最前。给「最常用的动作（全屏等）习惯排在最右」的页面用，
  /// 既不打乱既有排布，又保证最常用的最后收。
  final bool foldFromStart;

  /// true = 优先级反过来（列表**最后**一个最高）：放不下时从列表**开头**起收进
  /// 「⋯」，「⋯」排在最前。给「最常用的动作（全屏等）习惯排在最右」的页面用，
  /// 既不打乱既有排布，又保证最常用的最后收。
  final double? maxWidth;
  final double reservedWidth;

  /// 「⋯」按钮的 key。
  final Key? moreKey;
  final String? moreTooltip;

  /// AppBar 场景的 [reservedWidth]：返回钮胶囊（64）+ 标题保底
  /// （[kFushiFloatingTopBarTitleMinWidth]）+ 间距 8，与
  /// [fushiTopBarActionsBudget]（leadingCount 1、有标题）同口径。
  static const double titleBarReservedWidth =
      64 + kFushiFloatingTopBarTitleMinWidth + 8;

  @override
  State<FushiAdaptiveActionStrip> createState() =>
      _FushiAdaptiveActionStripState();
}

class _FushiAdaptiveActionStripState extends State<FushiAdaptiveActionStrip> {
  final FushiTopBarOverflowFit _fit = FushiTopBarOverflowFit();

  /// 预算：[FushiAdaptiveActionStrip.maxWidth]（给了就用）否则屏宽扣
  /// [FushiAdaptiveActionStrip.reservedWidth]。故意**不用 LayoutBuilder**：设置页
  /// 页头等胶囊会对 actions 取固有宽度，LayoutBuilder 不支持固有尺寸查询。
  double _budget(BuildContext context) =>
      widget.maxWidth ??
      MediaQuery.sizeOf(context).width - widget.reservedWidth;

  Widget _inline(BuildContext context, FushiAdaptiveAction a) {
    final WidgetBuilder? custom = a.inlineBuilder;
    if (custom != null) return custom(context);
    return FushiIconButtonControl(
      key: a.key,
      tooltip: a.label,
      isSelected: a.selected,
      icon: FushiIcon(a.icon),
      onPressed: a.onPressed,
    );
  }

  List<PopupMenuEntry<VoidCallback>> _foldedItems(
    BuildContext context,
    List<FushiAdaptiveAction> folded,
  ) {
    return <PopupMenuEntry<VoidCallback>>[
      for (final FushiAdaptiveAction a
          in folded) ...<PopupMenuEntry<VoidCallback>>[
        if (a.foldedDividerBefore) const PopupMenuDivider(),
        if (a.foldedEntries != null)
          ...a.foldedEntries!(context)
        else
          FushiPopupMenuItem<VoidCallback>(
            key: a.foldedKey,
            value: a.onPressed ?? () {},
            icon: a.icon,
            label: a.label,
            enabled: a.onPressed != null,
          ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final List<FushiAdaptiveAction> actions = widget.actions;
    if (actions.isEmpty) return const SizedBox.shrink();
    return Builder(
      builder: (BuildContext context) {
        // 测宽按优先级从高到低排；foldFromStart 时列表末尾优先级最高，反过来喂。
        // 占多个槽位的动作（[FushiAdaptiveAction.inlineSlots]）按槽位数展开成多颗
        // 占位项，平铺颗数再换算回「放得下的整数个动作」。
        final List<FushiAdaptiveAction> byPriority = widget.foldFromStart
            ? actions.reversed.toList()
            : actions;
        final int slotsFit = _fit.visibleFor(
          groups: <List<FushiToolbarItem>>[
            <FushiToolbarItem>[
              for (final FushiAdaptiveAction a in byPriority)
                for (int i = 0; i < a.inlineSlots; i++)
                  FushiToolbarItem(
                    icon: a.icon,
                    label: a.label,
                    onPressed: a.onPressed,
                  ),
            ],
          ],
          budget: _budget(context),
        );
        int visible = 0;
        int usedSlots = 0;
        for (final FushiAdaptiveAction a in byPriority) {
          if (usedSlots + a.inlineSlots > slotsFit) break;
          usedSlots += a.inlineSlots;
          visible++;
        }
        final List<FushiAdaptiveAction> shown = widget.foldFromStart
            ? actions.sublist(actions.length - visible)
            : actions.sublist(0, visible);
        final List<FushiAdaptiveAction> folded = widget.foldFromStart
            ? actions.sublist(0, actions.length - visible)
            : actions.sublist(visible);
        final Widget? more = folded.isEmpty
            ? null
            : FushiPopupMenuButton<VoidCallback>(
                key: widget.moreKey,
                tooltip: widget.moreTooltip ?? t.common_more_actions,
                icon: const FushiIcon(FushiIcons.more),
                onSelected: (VoidCallback run) => run(),
                itemBuilder: (BuildContext context) =>
                    _foldedItems(context, folded),
              );
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (more != null && widget.foldFromStart) more,
            for (final FushiAdaptiveAction a in shown) _inline(context, a),
            if (more != null && !widget.foldFromStart) more,
          ],
        );
      },
    );
  }
}
