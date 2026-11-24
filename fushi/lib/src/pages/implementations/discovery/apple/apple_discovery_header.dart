/// 发现页头部控件的 Apple（Cupertino）分支（「浏览」页方案 A）：
///
/// - 一行：[来源 token] + 搜索框 + 第三层 pull-down（[appleFilters]）+ 行尾动作；
/// - 「全部源 ⌃」下拉取消：在来源列表里点某一行就是「只看这个源」，选中后搜索框
///   前出现来源 token「Nyaa ×」（UISearchToken 式），点 × 回到全部来源；
/// - 不画 M3E 筛选 chip 行（`leading`）：第三层筛选由调用方以 pull-down 给出。
///
/// 由 `DiscoveryHeaderControls` 在 `isGlassDesign` 为真时分派过来。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/pages/implementations/discovery/apple/apple_discovery_widgets.dart';
import 'package:fushi/src/utils/components/fushi_search.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_chips.dart'
    show fushiAppleChip;
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';

class AppleDiscoveryHeaderControls extends StatelessWidget {
  const AppleDiscoveryHeaderControls({
    required this.selectedSourceLabel,
    required this.onClearSource,
    required this.searchController,
    required this.searchFocusNode,
    required this.searchHintText,
    required this.onSearchSubmitted,
    required this.searchFocusId,
    required this.filters,
    required this.trailing,
    this.onSearchChanged,
    this.onSearchCleared,
    super.key,
  });

  /// 选中的单个来源名；null = 全部来源（不出 token）。
  final String? selectedSourceLabel;
  final VoidCallback onClearSource;
  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final String searchHintText;
  final ValueChanged<String> onSearchSubmitted;
  final ValueChanged<String>? onSearchChanged;
  final VoidCallback? onSearchCleared;
  final FushiFocusId searchFocusId;

  /// 搜索框右边的 pull-down（第三层筛选）。
  final List<Widget> filters;

  /// 不在外壳里时的行尾动作（AI / ⋯ / 刷新）。
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final double page = appleDiscoveryPageInset(context);
    final double gap = fushiAppleUsesMacMetrics(context) ? 8 : 8;
    final String? token = selectedSourceLabel;
    return Padding(
      padding: EdgeInsets.fromLTRB(page, 0, page, 8),
      child: Row(
        children: <Widget>[
          if (token != null) ...<Widget>[
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: KeyedSubtree(
                key: const ValueKey<String>('discovery_source_token'),
                child: fushiAppleChip(
                  context,
                  label: Text(
                    token,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  selected: true,
                  onTap: onClearSource,
                  onDeleted: onClearSource,
                  tooltip: t.discovery_all_sources,
                ),
              ),
            ),
            SizedBox(width: gap),
          ],
          Expanded(
            child: FushiSearchBar(
              fieldKey: const ValueKey<String>('discovery_search_field'),
              clearButtonKey: const ValueKey<String>('discovery_search_clear'),
              focusId: searchFocusId,
              controller: searchController,
              focusNode: searchFocusNode,
              hintText: searchHintText,
              onQueryChanged: onSearchChanged,
              onSubmitted: onSearchSubmitted,
              onClear: onSearchCleared,
            ),
          ),
          for (final Widget filter in filters) ...<Widget>[
            SizedBox(width: gap),
            filter,
          ],
          for (final Widget action in trailing) ...<Widget>[
            SizedBox(width: gap),
            action,
          ],
        ],
      ),
    );
  }
}
