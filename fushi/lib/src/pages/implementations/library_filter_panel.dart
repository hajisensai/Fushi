import 'dart:async' show unawaited;
import 'dart:math' as math;
import 'dart:ui' show SemanticsRole;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

// 库页「筛选」面板（游戏库 / 视频库共用，2026-10-14 用户定案）。
//
// 库页页头只留一行：筛选维度不再在页头下方铺一排下拉胶囊，而是页头动作里一颗
// 「筛选」按钮（偏离分区默认值时亮圆点），点开这个面板按分组列出全部维度。改动
// 即时生效，面板不必「确定」，底部只有一个「清除全部」。形态：
//
// - 宽窗（≥ [kFushiSheetWideBreakpoint]，Material = M3E）：锚定在「筛选」按钮
//   正下方的下拉面板（popover）——圆角 tonal 底 + 阴影、最大高度到窗口底可滚动、
//   从按钮处弹簧展开；点外部 / Esc / 手柄 B 关闭，打开时焦点进面板首项，关闭后
//   焦点回到筛选按钮。按钮被收进页头「⋯」时锚到「⋯」（页头右侧动作区下沿）。
//   触发控件经 [FushiActionOrigin] 取得（页头按钮 / 「⋯」派发时同步登记）。
// - 窄窗 / 手机、Apple 设计系统：全应用唯一的弹层入口 [adaptiveModalSheet]（底部
//   弹层 / Apple sheet），与改造前一致。
//
// - [showLibraryFilterPanel]：打开面板。[sections] 每次重建都重新求值，读的是
//   页面自己的筛选状态；改状态一律经 `update` 包一层，面板跟着重画。
// - [LibraryFilterSection]：分组标题 + 一组 chip（Wrap 换行）。
// - [LibraryFilterChoiceSection]：单选维度的便捷形态（M3E choice chip）。
// - [LibraryActiveFilterChip]：生效中的筛选条件，页头下方 chip 行里带 ✕ 的那枚。

/// 面板里改筛选状态的包装：先跑 [change]（页面自己 setState / 持久化），再让
/// 面板按新状态重画。
typedef LibraryFilterPanelUpdate = void Function(VoidCallback change);

/// 面板内容构建（每次重建都重新求值）。
typedef LibraryFilterSectionsBuilder =
    List<Widget> Function(
      BuildContext context,
      LibraryFilterPanelUpdate update,
    );

/// 打开库页筛选面板。[sections] 返回各分组（通常是 [LibraryFilterSection] /
/// [LibraryFilterChoiceSection]，也可以夹开关行之类的非 chip 控件）；
/// [onClearAll] 是「清除全部」，只复位面板里的维度。
///
/// 必须在筛选按钮 onTap 的**同步段**里调用（第一个 `await` 之前），宽窗才拿得到
/// 锚点（[FushiActionOrigin.current]）；拿不到时退回 [adaptiveModalSheet]。
Future<void> showLibraryFilterPanel({
  required BuildContext context,
  required String title,
  required LibraryFilterSectionsBuilder sections,
  required String clearLabel,
  required VoidCallback onClearAll,
  Key? clearKey,
}) {
  final BuildContext? origin = FushiActionOrigin.current;
  final bool popover =
      origin != null &&
      !isCupertinoPlatform(context) &&
      !isGlassDesign(context) &&
      MediaQuery.sizeOf(context).width >= kFushiSheetWideBreakpoint;
  if (popover) {
    return _showLibraryFilterPopover(
      context: context,
      origin: origin,
      title: title,
      sections: sections,
      clearLabel: clearLabel,
      onClearAll: onClearAll,
      clearKey: clearKey,
    );
  }
  return adaptiveModalSheet<void>(
    context: context,
    builder: (BuildContext sheetContext) {
      return StatefulBuilder(
        builder: (BuildContext context, StateSetter setSheetState) {
          void update(VoidCallback change) {
            change();
            setSheetState(() {});
          }

          final FushiDesignTokens tokens = FushiDesignTokens.of(context);
          return FushiModalSheetFrame(
            title: title,
            leadingIcon: FushiIcons.filter,
            scrollable: true,
            bodyPadding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                ...sections(context, update),
                SizedBox(height: tokens.spacing.gap),
              ],
            ),
            footer: Row(
              children: <Widget>[
                const Spacer(),
                FushiTextButton(
                  key: clearKey,
                  onPressed: () => update(onClearAll),
                  child: Text(clearLabel),
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

/// 下拉面板与锚点 / 窗口边缘的间距。
const double _kPopoverGap = 8;
const double _kPopoverMargin = 16;

/// 下拉面板宽：一行放得下四五枚 chip，又不像居中面板那样铺满半个窗口。
const double _kPopoverWidth = 420;

/// 下拉面板至少给到的高度（锚点贴近窗口底时也不压成一条缝）。
const double _kPopoverMinHeight = 240;

/// 宽窗下拉面板：锚在 [origin]（筛选按钮或「⋯」）正下方、右缘对齐锚点右缘。
Future<void> _showLibraryFilterPopover({
  required BuildContext context,
  required BuildContext origin,
  required String title,
  required LibraryFilterSectionsBuilder sections,
  required String clearLabel,
  required VoidCallback onClearAll,
  Key? clearKey,
}) async {
  final NavigatorState navigator = Navigator.of(context);
  final RenderBox overlay =
      navigator.overlay!.context.findRenderObject()! as RenderBox;
  final RenderBox anchorBox = origin.findRenderObject()! as RenderBox;
  final Rect anchor = Rect.fromPoints(
    anchorBox.localToGlobal(Offset.zero, ancestor: overlay),
    anchorBox.localToGlobal(
      anchorBox.size.bottomRight(Offset.zero),
      ancestor: overlay,
    ),
  );
  final bool motion = fushiMotionEnabled(context);
  final CapturedThemes themes = InheritedTheme.capture(
    from: context,
    to: navigator.context,
  );
  await navigator.push<void>(
    RawDialogRoute<void>(
      barrierDismissible: true,
      // 下拉面板不压暗页面（M3 菜单 / 下拉同口径），点外部即关。
      barrierColor: Colors.transparent,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      transitionDuration: motion ? FushiMotion.medium : Duration.zero,
      traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
      pageBuilder:
          (
            BuildContext routeContext,
            Animation<double> animation,
            Animation<double> secondaryAnimation,
          ) => themes.wrap(
            _LibraryFilterPopover(
              anchor: anchor,
              animation: motion ? animation : null,
              title: title,
              sections: sections,
              clearLabel: clearLabel,
              onClearAll: onClearAll,
              clearKey: clearKey,
            ),
          ),
    ),
  );
  // 关闭后焦点回到触发它的按钮（被收进「⋯」时回到「⋯」）。
  if (origin.mounted) _firstFocusNodeIn(origin)?.requestFocus();
}

/// [context] 子树里第一个可聚焦节点（页头按钮自己的焦点节点）。
FocusNode? _firstFocusNodeIn(BuildContext context) {
  final FocusNode? outer = Focus.maybeOf(context, createDependency: false);
  FocusNode? found;
  void visit(Element element) {
    if (found != null) return;
    final FocusNode? node = Focus.maybeOf(element, createDependency: false);
    if (node != null &&
        node != outer &&
        node.canRequestFocus &&
        !node.skipTraversal) {
      found = node;
      return;
    }
    element.visitChildElements(visit);
  }

  context.visitChildElements(visit);
  return found;
}

class _LibraryFilterPopover extends StatefulWidget {
  const _LibraryFilterPopover({
    required this.anchor,
    required this.animation,
    required this.title,
    required this.sections,
    required this.clearLabel,
    required this.onClearAll,
    this.clearKey,
  });

  /// 锚点矩形（Navigator overlay 坐标）。
  final Rect anchor;

  /// 进出场动画；null = 无动效（墨水屏 / 减弱动态效果）。
  final Animation<double>? animation;
  final String title;
  final LibraryFilterSectionsBuilder sections;
  final String clearLabel;
  final VoidCallback onClearAll;
  final Key? clearKey;

  @override
  State<_LibraryFilterPopover> createState() => _LibraryFilterPopoverState();
}

class _LibraryFilterPopoverState extends State<_LibraryFilterPopover> {
  final FocusNode _contentNode = FocusNode(
    debugLabel: 'library-filter-popover',
    skipTraversal: true,
  );

  @override
  void initState() {
    super.initState();
    // 打开即把焦点放到面板首项（第一枚 chip），键盘 / 手柄不必先按一次 Tab。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final FocusNode node in _contentNode.traversalDescendants) {
        if (node.canRequestFocus) {
          node.requestFocus();
          return;
        }
      }
    });
  }

  @override
  void dispose() {
    _contentNode.dispose();
    super.dispose();
  }

  void _update(VoidCallback change) {
    change();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final MediaQueryData media = MediaQuery.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool eink = isEinkTheme(context);
    final Size screen = media.size;

    final double width = math.min(
      _kPopoverWidth,
      screen.width - _kPopoverMargin * 2,
    );
    // 锚点在右半边（页头动作）时右缘对齐锚点右缘，在左半边（chip 行里的生效
    // 条件）时左缘对齐锚点左缘；贴不下时夹回窗口内。
    final bool alignRight = widget.anchor.center.dx >= screen.width / 2;
    final double left =
        (alignRight ? widget.anchor.right - width : widget.anchor.left).clamp(
          _kPopoverMargin,
          math.max(_kPopoverMargin, screen.width - _kPopoverMargin - width),
        );
    final double top = widget.anchor.bottom + _kPopoverGap;
    final double maxHeight = math.max(
      _kPopoverMinHeight,
      screen.height - top - _kPopoverMargin - media.padding.bottom,
    );
    // 弹簧展开的原点：锚点中心在面板里的横向位置，纵向贴顶。
    final double originX = ((widget.anchor.center.dx - left) / width).clamp(
      0.0,
      1.0,
    );
    const BorderRadius radius = BorderRadius.all(Radius.circular(24));

    final Widget panel = Material(
      color: cs.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      elevation: eink ? 0 : 6,
      shadowColor: cs.shadow,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: eink ? BorderSide(color: cs.outline) : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: FushiDialogScope(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Row(
                children: <Widget>[
                  FushiIcon(
                    FushiIcons.filter,
                    color: cs.onSurfaceVariant,
                    size: 20,
                  ),
                  SizedBox(width: tokens.spacing.gap + 4),
                  Expanded(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tokens.type.listTitle.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: Focus(
                focusNode: _contentNode,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: widget.sections(context, _update),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: FushiTextButton(
                  key: widget.clearKey,
                  onPressed: () => _update(widget.onClearAll),
                  child: Text(widget.clearLabel),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    Widget body = Semantics(
      role: SemanticsRole.dialog,
      label: widget.title,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: panel,
      ),
    );
    final Animation<double>? animation = widget.animation;
    if (animation != null) {
      // M3E 下拉：从锚点处纵向弹簧展开 + 轻缩放（带一点回弹），透明度只吃
      // 前段并夹到 0..1（弹簧会过冲）。
      final Animation<double> spatial = CurvedAnimation(
        parent: animation,
        curve: FushiSpringCurve.spatial,
        reverseCurve: FushiMotion.exit,
      );
      final Animation<double> fade = fushiUnitClamped(
        CurvedAnimation(
          parent: animation,
          curve: const Interval(0, 0.5, curve: FushiMotion.enter),
          reverseCurve: FushiMotion.exit,
        ),
      );
      final Alignment alignment = Alignment(originX * 2 - 1, -1);
      body = FadeTransition(
        opacity: fade,
        child: AnimatedBuilder(
          animation: spatial,
          child: body,
          builder: (BuildContext context, Widget? child) => Transform(
            alignment: alignment,
            transform: Matrix4.diagonal3Values(
              0.92 + 0.08 * spatial.value,
              0.8 + 0.2 * spatial.value,
              1,
            ),
            child: child,
          ),
        ),
      );
    }
    return Stack(
      children: <Widget>[
        Positioned(left: left, top: top, width: width, child: body),
      ],
    );
  }
}

/// 筛选面板里的一个分组：分组标题 + 一组 chip（放不下换行）。
class LibraryFilterSection extends StatelessWidget {
  const LibraryFilterSection({
    required this.title,
    required this.children,
    super.key,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.only(
            top: tokens.spacing.gap * 2,
            bottom: tokens.spacing.gap,
          ),
          child: Text(title, style: tokens.type.sectionLabel),
        ),
        Wrap(
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: children,
        ),
      ],
    );
  }
}

/// 单选维度：每个档位一枚 choice chip，[allValue] 那一档显示 [allLabel]
/// （「全部」）。点已选中的档位不取消（单选维度总有一档生效）。
class LibraryFilterChoiceSection<T> extends StatelessWidget {
  const LibraryFilterChoiceSection({
    required this.title,
    required this.values,
    required this.selected,
    required this.allValue,
    required this.allLabel,
    required this.labelOf,
    required this.onSelected,
    this.avatarOf,
    super.key,
  });

  final String title;
  final List<T> values;
  final T selected;
  final T allValue;
  final String allLabel;
  final String Function(T value) labelOf;
  final ValueChanged<T> onSelected;

  /// 档位前的图标（可选）。
  final IconData? Function(T value)? avatarOf;

  @override
  Widget build(BuildContext context) {
    return LibraryFilterSection(
      title: title,
      children: <Widget>[
        for (final T value in values)
          FushiChoiceChip(
            avatar: switch (avatarOf?.call(value)) {
              final IconData icon => FushiIcon(icon, size: 18),
              null => null,
            },
            label: Text(value == allValue ? allLabel : labelOf(value)),
            selected: value == selected,
            onSelected: (_) {
              if (value != selected) onSelected(value);
            },
          ),
      ],
    );
  }
}

/// 页头下方 chip 行里的一枚生效中筛选条件：点 ✕（或手柄 X）移除这一条，
/// 点 chip 本身打开筛选面板。
class LibraryActiveFilterChip extends StatelessWidget {
  const LibraryActiveFilterChip({
    required this.label,
    required this.onRemove,
    this.onTap,
    super.key,
  });

  final String label;
  final VoidCallback onRemove;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final VoidCallback? tap = onTap;
    return FushiTagChip(
      label: label,
      selected: true,
      // 以 chip 自己为触发控件派发：宽窗筛选面板锚在这枚 chip 下方。
      onTap: tap == null
          ? null
          : () => unawaited(FushiActionOrigin.dispatch(context, tap)),
      onDeleted: onRemove,
    );
  }
}
