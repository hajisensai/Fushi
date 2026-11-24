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
                  _appleYearPullDown(_year, _applyYearFilter),
                  _appleRegionPullDown(_region, (String value) {
                    _updateState(() => _region = value);
                    unawaited(_reload());
                  }),
                  _appleGenrePullDown(_genre, (String value) {
                    _updateState(() => _genre = value);
                    unawaited(_reload());
                  }),
                  _appleSortPullDown(),
                ] else ...<Widget>[
                  FushiIconButton(
                    key: const ValueKey<String>('video-discovery-open-filters'),
                    icon: Icons.tune_rounded,
                    tooltip: t.game_filter,
                    badge: activeFilters > 0,
                    onTap: _openAppleFilterSheet,
                  ),
                  _appleSortPullDown(),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 「全部作品 / 搜索结果」节头（Apple 货架头同一字阶，无「查看全部」）。
  Widget _buildAppleSectionHeader(String title, {required double top}) {
    final double page = appleDiscoveryPageInset(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(page, top, page, 4),
      child: AppleDiscoveryShelfHeader(title: title),
    );
  }

  /// 年份 pull-down（按钮上「全部」显示维度名「年份」）。
  Widget _appleYearPullDown(int value, ValueChanged<int> onChanged) {
    final int newestYear = DateTime.now().year + 2;
    return KeyedSubtree(
      key: const ValueKey<String>('video-discovery-filter-year'),
      child: AppleDiscoveryPullDown<int>(
        keyPrefix: 'video-discovery-year',
        tooltip: t.video_filter_year,
        values: <int>[0, for (int y = newestYear; y >= 1900; y--) y],
        selected: value,
        active: value != 0,
        labelOf: (int y) => y == 0 ? t.home_filter_all : '$y',
        chipLabelOf: (int y) => y == 0 ? t.video_filter_year : '$y',
        onSelected: onChanged,
      ),
    );
  }

  Widget _appleRegionPullDown(String value, ValueChanged<String> onChanged) =>
      KeyedSubtree(
        key: const ValueKey<String>('video-discovery-filter-region'),
        child: AppleDiscoveryPullDown<String>(
          keyPrefix: 'video-discovery-region',
          tooltip: t.video_work_countries,
          values: const <String>['', 'CN', 'JP', 'KR', 'US', 'GB', 'FR'],
          selected: value,
          active: value.isNotEmpty,
          labelOf: (String r) => r.isEmpty ? t.home_filter_all : r,
          chipLabelOf: (String r) => r.isEmpty ? t.video_work_countries : r,
          onSelected: onChanged,
        ),
      );

  Widget _appleGenrePullDown(String value, ValueChanged<String> onChanged) =>
      KeyedSubtree(
        key: const ValueKey<String>('video-discovery-filter-genre'),
        child: AppleDiscoveryPullDown<String>(
          keyPrefix: 'video-discovery-genre',
          tooltip: t.video_work_genres,
          values: <String>['', ..._availableGenres],
          selected: value,
          active: value.isNotEmpty,
          labelOf: (String g) => g.isEmpty ? t.home_filter_all : g,
          chipLabelOf: (String g) => g.isEmpty ? t.video_work_genres : g,
          onSelected: onChanged,
        ),
      );

  Widget _appleSortPullDown() => KeyedSubtree(
    key: const ValueKey<String>('video-discovery-filter-sort'),
    child: AppleDiscoveryPullDown<discovery.VideoDiscoverySort>(
      keyPrefix: 'video-discovery-sort',
      tooltip: '${t.sort_by}: ${_sortLabel(_sort)}',
      values: <discovery.VideoDiscoverySort>[
        for (final discovery.VideoDiscoverySort sort
            in discovery.VideoDiscoverySort.values)
          if (sort != discovery.VideoDiscoverySort.relevance || _searching)
            sort,
      ],
      selected: _sort,
      active: _sort != _defaultSort,
      labelOf: _sortLabel,
      chipLabelOf: (discovery.VideoDiscoverySort sort) =>
          sort == _defaultSort ? t.sort_by : _sortLabel(sort),
      onSelected: (discovery.VideoDiscoverySort value) {
        _updateState(() => _pickedSort = value);
        unawaited(_reload());
      },
    ),
  );

  /// iOS 档「筛选」面板：一组 inset 表单行（年份 / 地区 / 类型 各一颗
  /// pull-down）+ 重置 / 完成。确认才应用（与 M3E 面板同一语义）。
  Future<void> _openAppleFilterSheet() async {
    int year = _year;
    String region = _region;
    String genre = _genre;
    final bool? apply = await adaptiveModalSheet<bool>(
      context: context,
      useSafeArea: true,
      builder: (BuildContext sheetContext) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setSheetState) {
          final double page = appleDiscoveryPageInset(context);
          return SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(page, 0, page, page),
              child: Column(
                key: const ValueKey<String>('video-discovery-filter-sheet'),
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  AdaptiveSettingsSection(
                    title: t.game_filter,
                    children: <Widget>[
                      AdaptiveSettingsRow(
                        title: t.video_filter_year,
                        trailing: _appleYearPullDown(
                          year,
                          (int value) => setSheetState(() => year = value),
                        ),
                      ),
                      AdaptiveSettingsRow(
                        title: t.video_work_countries,
                        trailing: _appleRegionPullDown(
                          region,
                          (String value) => setSheetState(() => region = value),
                        ),
                      ),
                      AdaptiveSettingsRow(
                        title: t.video_work_genres,
                        trailing: _appleGenrePullDown(
                          genre,
                          (String value) => setSheetState(() => genre = value),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: <Widget>[
                      FushiTextButton(
                        key: const ValueKey<String>(
                          'video-discovery-reset-filters',
                        ),
                        onPressed: () => setSheetState(() {
                          year = 0;
                          region = '';
                          genre = '';
                        }),
                        child: Text(t.reset),
                      ),
                      const Spacer(),
                      FushiFilledButton(
                        key: const ValueKey<String>(
                          'video-discovery-apply-filters',
                        ),
                        onPressed: () => Navigator.pop(sheetContext, true),
                        child: Text(t.dialog_done),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (!mounted ||
        apply != true ||
        (year == _year && region == _region && genre == _genre)) {
      return;
    }
    _updateState(() {
      _year = year;
      _region = region;
      _genre = genre;
    });
    unawaited(_reload());
  }
}
