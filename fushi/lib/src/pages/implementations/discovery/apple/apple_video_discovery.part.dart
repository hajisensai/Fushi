part of '../../video_discovery_page.dart';

/// 视频发现页头部的 Apple（Cupertino）画法（「浏览」页方案 A：视频保留 Hero 与
/// 货架，筛选收进一颗「筛选」）。业务状态（搜索词、分类、年份 / 地区 / 类型、
/// 排序）全在 [_VideoDiscoveryPageState]，这里只换控件：
///
/// - 分类（全部 / 动画 / 电影…）是 pull-down（第三层收成一颗按钮，不再是一排
///   [FushiSelectableChip]）；
/// - 在外壳里（浏览页 / 库页有动作槽）时页头动作（AI 下视频 / 订阅 / 任务 / ⋯）
///   登记进外壳的玻璃按钮组（拍板点 8），放不下按优先级收进「⋯」；
/// - iOS 档：第二行是分类 pull-down + 「筛选」（打开筛选面板）+ 排序；macOS 档：
///   分类 pull-down + 年份 / 地区 / 类型 / 排序平铺。
extension _AppleVideoDiscovery on _VideoDiscoveryPageState {
  bool get _appleActionsInShell =>
      FushiShellTitleScope.maybeActionsSlotOf(context) != null;

  Widget _buildAppleChrome() => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      if (_headerVisible || _appleActionsInShell) _buildHeader(),
      _buildAppleControls(),
    ],
  );

  Widget _buildAppleControls() {
    final double page = appleDiscoveryPageInset(context);
    final bool mac = fushiAppleUsesMacMetrics(context);
    // 页头不画（嵌在浏览页 / Apple 平台）且不在外壳动作槽里时，AI 入口回到搜索行。
    final ValueChanged<String?>? onAiAcquire =
        _headerVisible || _appleActionsInShell
        ? null
        : widget.actions.onAiAcquire;
    final List<discovery.VideoDiscoveryCategory?> categories =
        <discovery.VideoDiscoveryCategory?>[
          null,
          ...discovery.VideoDiscoveryCategory.values,
        ];
    final int activeFilters =
        (_year != 0 ? 1 : 0) +
        (_region.isNotEmpty ? 1 : 0) +
        (_genre.isNotEmpty ? 1 : 0);
    final Widget categoryMenu = AppleDiscoveryPullDown<int>(
      key: const ValueKey<String>('video-discovery-category-pull-down'),
      keyPrefix: 'video-discovery-category',
      values: <int>[for (int i = 0; i < categories.length; i++) i],
      selected: categories.indexOf(_category),
      active: _category != null,
      labelOf: (int i) => _categoryLabel(categories[i]),
      onSelected: (int i) {
        final discovery.VideoDiscoveryCategory? next = categories[i];
        if (_category == next) return;
        _updateState(() => _category = next);
        unawaited(_reload());
      },
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(page, 0, page, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: FushiSearchField(
                  fieldKey: const ValueKey<String>('video-discovery-search'),
                  clearButtonKey: const ValueKey<String>(
                    'video-discovery-search-clear',
                  ),
                  focusId: const FushiFocusId('video-discovery-search'),
                  controller: _searchController,
                  focusNode: _searchFocusNode,
                  hintText: t.video_discovery_search_hint,
                  onChanged: _scheduleSearch,
                  onSubmitted: _submitSearch,
                  onClear: _clearSearch,
                ),
              ),
              if (onAiAcquire != null) ...<Widget>[
                const SizedBox(width: 8),
                FushiIconButton(
                  key: const ValueKey<String>('video-discovery-ai-acquire'),
                  icon: FushiIcons.ai,
                  tooltip: t.ai_video_acquire_entry,
                  onTap: () => onAiAcquire(_searchController.text),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            child: Row(
              spacing: 8,
              children: <Widget>[
                categoryMenu,
                if (mac) ...<Widget>[
                  _buildYearField(),
                  _buildRegionMenu(),
                  _buildGenreMenu(),
                  _buildSortMenu(),
                ] else ...<Widget>[
                  FushiIconButton(
                    key: const ValueKey<String>('video-discovery-open-filters'),
                    icon: Icons.tune_rounded,
                    tooltip: t.game_filter,
                    badge: activeFilters > 0,
                    onTap: _openFilterSheet,
                  ),
                  _buildSortMenu(compact: true),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
