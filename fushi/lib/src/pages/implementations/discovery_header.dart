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

/// 发现页头部：来源下拉 + 搜索框（可选前置行，如媒体域分段）。
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

  /// 控件行之上的附加行（如媒体域分段按钮）。
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Widget? leadingRow = leading;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (leadingRow != null)
            Padding(
              padding: EdgeInsets.only(bottom: tokens.spacing.gap),
              child: leadingRow,
            ),
          Row(
            children: <Widget>[
              // 隐式切源（点进某来源的目录）后下拉必须跟着变：DropdownMenu 的
              // initialSelection 只在初次构建生效，外面套一层随选中值变化的 key
              // 强制重建，否则下拉会一直停在旧值上骗用户。
              KeyedSubtree(
                key: ValueKey<String>('discovery_source_$selectedSourceId'),
                child: DropdownMenu<String>(
                  key: const ValueKey<String>('discovery_source_menu'),
                  initialSelection: selectedSourceId,
                  requestFocusOnTap: false,
                  onSelected: (String? value) =>
                      onSourceSelected(value ?? kDiscoveryAllSourcesId),
                  dropdownMenuEntries: <DropdownMenuEntry<String>>[
                    DropdownMenuEntry<String>(
                      value: kDiscoveryAllSourcesId,
                      label: t.discovery_all_sources,
                    ),
                    for (final DiscoverySourceOption source in sources)
                      DropdownMenuEntry<String>(
                        value: source.id,
                        label: source.label,
                      ),
                  ],
                ),
              ),
              SizedBox(width: tokens.spacing.gap),
              Expanded(
                child: FushiSearchField(
                  fieldKey: const ValueKey<String>('discovery_search_field'),
                  clearButtonKey:
                      const ValueKey<String>('discovery_search_clear'),
                  focusId: searchFocusId,
                  controller: searchController,
                  focusNode: searchFocusNode,
                  hintText: searchHintText,
                  onChanged: onSearchChanged ?? (String _) {},
                  onSubmitted: onSearchSubmitted,
                  onClear: onSearchCleared,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
