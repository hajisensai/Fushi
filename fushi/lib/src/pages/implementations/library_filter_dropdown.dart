import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import 'package:fushi/src/utils/components/fushi_control_metrics.dart';
import 'package:fushi/src/utils/components/fushi_search.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/utils.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassContainer, LiquidRoundedSuperellipse;

/// 库页搜索栏右侧的单选下拉筛选（书架与漫画库的阅读状态、游戏库的游玩状态共用；
/// 视频库的几个下拉复用 [LibraryFilterChip] 视觉）。
///
/// [value] 为 null = 不筛选。chip 在不筛选时显示维度名 [title]、不描主色；菜单里
/// 同一档位显示 [allLabel]（chip 回答「这个下拉管什么」，菜单项回答「选了会怎
/// 样」）。null 不能直接当菜单值——[PopupMenuButton] 把 null 结果当成「取消」，
/// 「全部」项永远选不中——所以菜单值统一包一层 [_FilterChoice]。
class LibraryFilterDropdown<T extends Object> extends StatelessWidget {
  const LibraryFilterDropdown({
    required this.value,
    required this.options,
    required this.labelOf,
    required this.title,
    required this.allLabel,
    required this.onSelected,
    super.key,
  });

  final T? value;

  /// 「全部」之后的菜单项顺序。
  final List<T> options;
  final String Function(T value) labelOf;
  final String title;
  final String allLabel;
  final ValueChanged<T?> onSelected;

  @override
  Widget build(BuildContext context) {
    final T? current = value;
    return FushiPopupMenuButton<_FilterChoice<T>>(
      tooltip: title,
      initialValue: _FilterChoice<T>(current),
      onSelected: (_FilterChoice<T> choice) => onSelected(choice.value),
      itemBuilder: (BuildContext context) => <PopupMenuEntry<_FilterChoice<T>>>[
        PopupMenuItem<_FilterChoice<T>>(
          value: _FilterChoice<T>(null),
          child: Text(allLabel),
        ),
        for (final T option in options)
          PopupMenuItem<_FilterChoice<T>>(
            value: _FilterChoice<T>(option),
            child: Text(labelOf(option)),
          ),
      ],
      child: LibraryFilterChip(
        label: current == null ? title : labelOf(current),
        active: current != null,
      ),
    );
  }
}

@immutable
class _FilterChoice<T extends Object> {
  const _FilterChoice(this.value);

  final T? value;

  @override
  bool operator ==(Object other) =>
      other is _FilterChoice<T> && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

/// 库页工具行里筛选胶囊的高度：与并排的搜索框同高（[fushiInlineControlHeight]：
/// MD3 40 / Apple 36），同一行中线一致（用户 2026-10-04：并排控件要一样高）。
double libraryFilterChipHeight(BuildContext context) =>
    fushiInlineControlHeight(context);

/// 库页搜索框高度，见 [libraryFilterChipHeight]。
double librarySearchFieldHeight(BuildContext context) =>
    fushiInlineControlHeight(context);

/// 下拉筛选 chip 视觉（书架 / 漫画库 / 视频库 / 游戏库共用）。
///
/// MD3（M3 Expressive filter chip）：与搜索框同高的全胶囊；未激活 = surfaceContainerHigh
/// 填充（与并排的填充式搜索框同一语言）+ onSurfaceVariant 字；激活 =
/// secondaryContainer 填充 + 前置对勾 + onSecondaryContainer 字。
/// Apple（iOS / macOS 26 弹出按钮）：无色透明液态玻璃胶囊 + 上下双箭头；激活 =
/// 强调色淡染的玻璃 + 强调色字。降低透明度时两者回落实色。
///
/// eink：primary / outline / onSurfaceVariant 全塌成前景色，激活与未激活逐像素
/// 相同；改反色填充表达激活（chipTheme / segmentedButtonTheme 同一套处理）。
class LibraryFilterChip extends StatelessWidget
    implements FushiShapedMenuTrigger {
  const LibraryFilterChip({
    required this.label,
    required this.active,
    super.key,
  });

  final String label;
  final bool active;

  /// 与下面画出来的胶囊同一个形状：[FushiPopupMenuButton] 用它裁剪悬停 / 按压
  /// 状态层（2026-10-05 用户反馈：灰色反馈范围与高亮 chip 对不上）。
  @override
  ShapeBorder menuTriggerShape(BuildContext context) => isEinkTheme(context)
      ? RoundedRectangleBorder(
          borderRadius: const OutlineInputBorder().borderRadius,
        )
      : const StadiumBorder();

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    if (eink) return _buildEink(context, colors);
    final bool glass = isGlassDesign(context);
    final double height = libraryFilterChipHeight(context);
    final FushiAppleColors apple = appleColorsOf(context);
    final Color foreground = glass
        ? (active ? apple.accent : apple.label)
        : (active ? colors.onSecondaryContainer : colors.onSurfaceVariant);
    final TextStyle? textStyle =
        Theme.of(context).textTheme.labelLarge?.copyWith(
              color: foreground,
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
            );
    final Widget row = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (active && !glass) ...<Widget>[
          Icon(Icons.check_rounded, size: 18, color: foreground),
          const SizedBox(width: 6),
        ],
        // 长档位名（德语等）在窄窗口里不能把整条工具栏撑溢出。
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 160),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textStyle,
          ),
        ),
        const SizedBox(width: 4),
        glass
            ? Icon(
                CupertinoIcons.chevron_up_chevron_down,
                size: 12,
                color: foreground,
              )
            : Icon(Icons.expand_more_rounded, size: 18, color: foreground),
      ],
    );
    if (glass) {
      final bool dark = colors.brightness == Brightness.dark;
      // 未激活：macOS 26 弹出按钮的无色透明玻璃（只有高光边）。激活：同一枚
      // 胶囊淡染强调色（默认单色强调色 = 浅色下淡黑 / 深色下淡白）。
      return GlassContainer(
        useOwnLayer: true,
        quality: fushiGlassQuality(context),
        settings: active
            ? fushiGlassSettings(
                context,
                tint: apple.accent.withValues(alpha: dark ? 0.26 : 0.12),
              )
            : fushiClearGlassSettings(context),
        shape: LiquidRoundedSuperellipse(borderRadius: height / 2),
        child: Container(
          height: height,
          padding: const EdgeInsetsDirectional.only(start: 12, end: 10),
          alignment: Alignment.center,
          child: row,
        ),
      );
    }
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      height: height,
      padding: EdgeInsetsDirectional.only(start: active ? 8 : 12, end: 8),
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        color: active
            ? FushiDesignTokens.of(context).surfaces.selected
            : FushiDesignTokens.of(context).surfaces.search,
        shape: const StadiumBorder(),
      ),
      child: row,
    );
  }

  Widget _buildEink(BuildContext context, ColorScheme colors) {
    // 墨水屏：primary / outline 全塌成前景色，改反色填充表达激活。
    final Color foreground = active ? colors.surface : colors.onSurfaceVariant;
    return Container(
      height: libraryFilterChipHeight(context),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: active ? colors.onSurface : null,
        border: Border.all(color: active ? colors.primary : colors.outline),
        // 与并排的搜索框（`const OutlineInputBorder()`）同一个圆角来源。
        borderRadius: const OutlineInputBorder().borderRadius,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // 长档位名（德语等）在窄窗口里不能把整条工具栏撑溢出。
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: foreground),
            ),
          ),
          FushiIcon(Icons.arrow_drop_down, size: 18, color: foreground),
        ],
      ),
    );
  }
}

/// 库页搜索框（书架 / 漫画库 / 视频库 / 游戏库共用一个形态）：共享 M3E 搜索栏
/// [FushiSearchBar]（MD3 填充胶囊、Apple 搜索胶囊），
/// 高度见 [librarySearchFieldHeight]。有搜索词时尾部出清除钮。搜索词只影响本次
/// 会话、不落库，由调用方持有 [controller]。
class LibrarySearchField extends StatelessWidget {
  const LibrarySearchField({
    required this.fieldKey,
    required this.controller,
    required this.hintText,
    required this.onChanged,
    required this.onClear,
    super.key,
  });

  /// 挂在输入框本体上的 key（测试 / 集成测试按它定位）。
  final Key? fieldKey;
  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String> onChanged;

  /// 清除按钮：调用方负责 `controller.clear()` 并清自己的搜索状态。
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    // 共享 M3E 搜索栏（FushiSearchBar）：形态与其它搜索框同一实现（MD3 填充
    // 胶囊 / Apple 搜索胶囊、紧凑清除钮），行为上补齐 IME 组字期间不过滤、
    // Esc 清空。高度仍按库页工具条的行内控件高。
    return SizedBox(
      height: librarySearchFieldHeight(context),
      child: FushiSearchBar(
        fieldKey: fieldKey,
        controller: controller,
        hintText: hintText,
        onQueryChanged: onChanged,
        onClear: onClear,
      ),
    );
  }
}

/// 库页工具行：搜索框 + 筛选胶囊组 + 行尾工具（多选 / 排序 / 刮削…）排成
/// **一条**整齐的行（用户 2026-10-04：原来搜索 / 筛选 / 工具分成三行，高度、
/// 对齐、间距各不相同，筛选换行后还居中）。
///
/// - 宽屏（≥ [wideBreakpoint]）：`[搜索 240–420] [筛选胶囊… 横滚] [工具]`——
///   筛选左对齐、放不下时横向滚动而不是换行；工具恒贴右。
/// - 窄屏：第一行 `[搜索(撑满)] [工具]`，第二行筛选胶囊整宽横滚。
///
/// - 窄屏且给了 [compactTrailing]：第一行搜索框**独占**整行（不与工具抢宽），
///   第二行 `[筛选胶囊… 横滚] [compactTrailing]`——行尾工具多的库页（游戏库：
///   刮削 / 排序 / 筛选 / 标签）在窄屏把次要动作收进溢出菜单，交给调用方装配。
///
/// 焦点顺序固定为 搜索 → 筛选 → 工具（[OrderedTraversalPolicy]），与布局无关。
/// 与下方内容的分隔靠留白，不画分隔线。
class LibraryToolbar extends StatelessWidget {
  const LibraryToolbar({
    required this.search,
    this.filters = const <Widget>[],
    this.trailing,
    this.compactTrailing,
    this.filtersKey,
    this.compactKey,
    super.key,
  });

  static const double wideBreakpoint = 640;
  static const double _hPad = 12;
  static const double _gap = 8;

  final Widget search;
  final List<Widget> filters;
  final Widget? trailing;

  /// 窄屏专用行尾工具（见类注释）；为 null 时窄屏沿用 [trailing] 贴在搜索框右侧。
  final Widget? compactTrailing;

  /// 挂在筛选横滚区上的 key。
  final Key? filtersKey;

  /// 窄屏布局时挂在整块工具条上的 key（测试按它判定走了窄屏两行布局）。
  final Key? compactKey;

  Widget _filterStrip({required bool wide}) {
    return HorizontalDragScrollable(
      child: SingleChildScrollView(
        key: filtersKey,
        scrollDirection: Axis.horizontal,
        // 上下各留 4：玻璃胶囊的投影不被横滚区裁掉。
        padding: EdgeInsets.symmetric(
          horizontal: wide ? 0 : _hPad,
          vertical: 4,
        ),
        child: Row(
          children: <Widget>[
            for (int i = 0; i < filters.length; i++) ...<Widget>[
              if (i > 0) const SizedBox(width: _gap),
              filters[i],
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        final bool wide = width >= wideBreakpoint;
        final Widget searchSlot = FocusTraversalOrder(
          order: const NumericFocusOrder(1),
          child: search,
        );
        final Widget? filterSlot = filters.isEmpty
            ? null
            : FocusTraversalOrder(
                order: const NumericFocusOrder(2),
                child: _filterStrip(wide: wide),
              );
        final Widget? trailingWidget =
            !wide && compactTrailing != null ? compactTrailing : trailing;
        final Widget? trailingSlot = trailingWidget == null
            ? null
            : FocusTraversalOrder(
                order: const NumericFocusOrder(3),
                child: trailingWidget,
              );
        final Widget body;
        if (wide) {
          final double searchWidth = (width * 0.32).clamp(240.0, 420.0);
          body = Padding(
            padding: const EdgeInsets.fromLTRB(_hPad, 4, _hPad, 4),
            child: Row(
              children: <Widget>[
                SizedBox(width: searchWidth, child: searchSlot),
                if (filterSlot != null) ...<Widget>[
                  const SizedBox(width: 12),
                  Expanded(child: filterSlot),
                ] else
                  const Spacer(),
                if (trailingSlot != null) ...<Widget>[
                  const SizedBox(width: _gap),
                  trailingSlot,
                ],
              ],
            ),
          );
        } else if (compactTrailing != null) {
          body = Padding(
            key: compactKey,
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: _hPad),
                  child: searchSlot,
                ),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: _hPad),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: filterSlot ?? const SizedBox.shrink(),
                      ),
                      trailingSlot!,
                    ],
                  ),
                ),
              ],
            ),
          );
        } else {
          body = Padding(
            key: compactKey,
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: _hPad),
                  child: Row(
                    children: <Widget>[
                      Expanded(child: searchSlot),
                      if (trailingSlot != null) ...<Widget>[
                        const SizedBox(width: _gap),
                        trailingSlot,
                      ],
                    ],
                  ),
                ),
                if (filterSlot != null) ...<Widget>[
                  const SizedBox(height: 4),
                  filterSlot,
                ],
              ],
            ),
          );
        }
        return FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: body,
        );
      },
    );
  }
}
