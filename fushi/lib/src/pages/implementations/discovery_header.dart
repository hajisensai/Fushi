/// 发现页统一头部控件：**来源筛选下拉 + 搜索框**。
///
/// 三个域的发现页（书/有声书与 galgame 走 `MediaDiscoveryPage`，漫画走
/// `MangaDiscoveryPage`）头部形状由本组件给出唯一真相：左侧「全部来源 / 具体
/// 来源」下拉，右侧搜索框。用户在任一模块看到的发现页结构因此一致。
///
/// 各域的「来源」实体互不相同（发现源 adapter / Mihon 与 Aidoku 在线源），所以
/// 本组件只吃 [DiscoverySourceOption] 这层最小公共结构 `(id, label)`，不绑任何
/// 域模型——想让新的域接进来只需把自己的来源映射成一串 (id, label)。
library;

import 'package:flutter/material.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/utils.dart';

/// 「全部来源」哨兵 id（`DropdownMenu` 泛型不便用 null）。真实来源 id 不得为空串。
const String kDiscoveryAllSourcesId = '';

/// 下拉里的一个来源选项。
class DiscoverySourceOption {
  const DiscoverySourceOption({required this.id, required this.label});

  /// 域内稳定 id；空串是「全部来源」哨兵，不可用作真实来源 id。
  final String id;

  /// 展示名（站名/来源名，不走 i18n）。
  final String label;
}

/// 发现页头部（四个域统一）：
///
/// - 第一行：来源下拉（宽屏）+ 搜索胶囊（MD3 填充 / Apple 玻璃，[FushiSearchField]）
///   + 行尾动作（✨ AI 下载、刷新…）；
/// - 第二行：筛选（[leading]，媒体域分段 / 筛选 chip）左对齐**单行**，放不下横滑；
///   手机宽度下来源下拉也挪到这一行行首。
class DiscoveryHeaderControls extends StatelessWidget {
  const DiscoveryHeaderControls({
    required this.sources,
    required this.selectedSourceId,
    required this.onSourceSelected,
    required this.searchController,
    required this.searchFocusNode,
    required this.searchHintText,
    required this.onSearchSubmitted,
    super.key,
    this.leading,
    this.trailing = const <Widget>[],
    this.onSearchChanged,
    this.onSearchCleared,
    this.searchFocusId = const FushiFocusId('discovery-search'),
  });

  /// 可选来源（不含「全部来源」，本组件自己在最前面补）。
  final List<DiscoverySourceOption> sources;

  /// 当前选中的来源 id；[kDiscoveryAllSourcesId] = 全部来源。
  final String selectedSourceId;

  final ValueChanged<String> onSourceSelected;

  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final String searchHintText;
  final ValueChanged<String> onSearchSubmitted;
  final ValueChanged<String>? onSearchChanged;
  final VoidCallback? onSearchCleared;

  /// 搜索框的焦点条目 id。`FushiFocusController` 按 id 覆盖注册，两个发现页
  /// （统一发现页 / 漫画发现页）可能同时挂在树上，各自传独立 id 才不会互顶。
  final FushiFocusId searchFocusId;

  /// 筛选行内容（如媒体域分段按钮 + 筛选 chip）：排在第二行、单行横滑。
  final Widget? leading;

  /// 搜索框之后、同一行的附加按钮（页头不渲染时页头动作挪到这里，如刷新）。
  final List<Widget> trailing;

  /// 低于此宽度时来源下拉让出搜索行，挪到筛选行行首（手机上与搜索框、✨ 挤在
  /// 一行时搜索框只剩一指宽）。
  static const double compactWidth = 600;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool compact = constraints.maxWidth < compactWidth;
        final Widget sourceMenu = _buildSourceMenu(
          context,
          tokens,
          // 手机：下拉挪到筛选行行首后收窄，别把后面的筛选 chip 挤出半屏。
          width: compact ? 168 : null,
        );
        final Widget? filterRow = leading;
        // 第二行：左对齐单行，放不下就横滑（不再折行把搜索框以下的内容一层层
        // 往下推）。手机上来源下拉也在这一行行首。
        final List<Widget> rowTwo = <Widget>[
          if (compact) sourceMenu,
          if (filterRow != null) ...<Widget>[
            if (compact)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: tokens.spacing.gap),
                child: const SizedBox(
                  height: 24,
                  child: FushiVerticalDivider(width: 1),
                ),
              ),
            filterRow,
          ],
        ];
        return Padding(
          padding: EdgeInsets.fromLTRB(
            tokens.spacing.page,
            0,
            tokens.spacing.page,
            tokens.spacing.gap,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  if (!compact) ...<Widget>[
                    sourceMenu,
                    SizedBox(width: tokens.spacing.gap),
                  ],
                  Expanded(
                    child: FushiSearchField(
                      fieldKey: const ValueKey<String>(
                        'discovery_search_field',
                      ),
                      clearButtonKey: const ValueKey<String>(
                        'discovery_search_clear',
                      ),
                      focusId: searchFocusId,
                      controller: searchController,
                      focusNode: searchFocusNode,
                      hintText: searchHintText,
                      onChanged: onSearchChanged ?? (String _) {},
                      onSubmitted: onSearchSubmitted,
                      onClear: onSearchCleared,
                    ),
                  ),
                  for (final Widget action in trailing) ...<Widget>[
                    SizedBox(width: tokens.spacing.gap),
                    action,
                  ],
                ],
              ),
              if (rowTwo.isNotEmpty) ...<Widget>[
                SizedBox(height: tokens.spacing.gap),
                HorizontalDragScrollable(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: rowTwo,
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildSourceMenu(
    BuildContext context,
    FushiDesignTokens tokens, {
    double? width,
  }) {
    // 隐式切源（点进某来源的目录）后下拉必须跟着变：DropdownMenu 的
    // initialSelection 只在初次构建生效，外面套一层随选中值变化的 key
    // 强制重建，否则下拉会一直停在旧值上骗用户。
    return KeyedSubtree(
      key: ValueKey<String>('discovery_source_$selectedSourceId'),
      child: FushiDropdownMenu<String>(
        key: const ValueKey<String>('discovery_source_menu'),
        initialSelection: selectedSourceId,
        width: width,
        requestFocusOnTap: false,
        // 与搜索框同一几何：DropdownMenu 默认是 56 高的 MD3 文本框，比
        // [kFushiSearchFieldHeight] 的搜索框高出一截、字号也大一号。压到同高 +
        // 同一排版令牌。
        textStyle: tokens.type.listTitle,
        inputDecorationTheme: Theme.of(context).inputDecorationTheme.copyWith(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(
            horizontal: tokens.spacing.rowHorizontal,
          ),
          constraints: const BoxConstraints.tightFor(
            height: kFushiSearchFieldHeight,
          ),
        ),
        onSelected: (String? value) =>
            onSourceSelected(value ?? kDiscoveryAllSourcesId),
        dropdownMenuEntries: <DropdownMenuEntry<String>>[
          DropdownMenuEntry<String>(
            value: kDiscoveryAllSourcesId,
            label: t.discovery_all_sources,
          ),
          for (final DiscoverySourceOption source in sources)
            DropdownMenuEntry<String>(value: source.id, label: source.label),
        ],
      ),
    );
  }
}
