// Apple（Cupertino，iOS 27 / macOS 27）下载页「任务」的版式（用户 2026-11-24
// 拍板方案 A，效果图 `build/browse_cupertino_design/index.html`）。
//
// 挂在 [_DownloadTaskBrowserState] 上的 extension（part 文件）：筛选 / 排序 /
// 分组 / 折叠 / 批量 / 删除确认 / 清除已完成全部复用原 State 的字段与方法，本文件
// 只决定怎么画——业务状态只有一份，M3E 版式（原 build）一行不动。
//
// - iOS 档：列表最上方是宿主横幅（网络问题，Apple 下一行橙色说明），然后搜索框
//   （作品聚焦 = 搜索框下一枚可清除 token），一行「状态 pull-down …… ＋ ⋯」，
//   汇总组（总速度大数字 + 计数 + 执行设备 token +「全部暂停」），任务按状态分组
//   的 inset grouped 列表；类型 / 排序 / 方向 / 分组 / 折叠 / 选择 / 重试 / 清除
//   已完成 / 下载设置进「⋯」。
// - macOS 档（宽窗）：列表在左；右侧 280 宽窗格放汇总、状态（带计数，Mail
//   邮箱式）、类型 / 排序 / 分组 pull-down。
// - 「选择」= Apple 编辑模式：行首圆形勾选、底部批量栏（原 `_buildBatchBar`）。
// - 行：右滑暂停 / 继续，左滑删除（原删除确认，含「同时删除文件」）。
part of '../download_task_browser.dart';

enum _AppleDownloadMenuCommand {
  kind,
  sort,
  reverse,
  group,
  collapse,
  select,
  retryVisible,
  clearCompleted,
  settings,
}

/// macOS 档宽于此值（乘 [fushiAppleMacScale] 前）才分出右侧窗格。
const double _kAppleDownloadSidePaneBreakpoint = 760;

/// macOS 右侧窗格宽（乘 [fushiAppleMacScale] 前）。
const double _kAppleDownloadSidePaneWidth = 280;

/// 错峰进场只排前 8 行，之后的行与第 8 行同拍出现。
const int _kAppleDownloadStaggerCap = 8;

extension _AppleDownloadTaskBrowser on _DownloadTaskBrowserState {
  // ───────────── 汇总 ─────────────

  Widget _appleSummaryGroup() => FushiAppleGroupSurface(
    child: AppleDownloadSummaryRow(
      data: summarizeDownloadTasks(widget.tasks),
      executionDeviceLabel: widget.executionDeviceLabel,
      onOpenExecutionSettings: widget.onOpenExecutionSettings,
      onPauseAll: _allAction(DownloadBatchAction.pause),
      onResumeAll: _allAction(DownloadBatchAction.resume),
    ),
  );

  // ───────────── 工具 ─────────────

  Widget _applePullDown<T extends Object>({
    required String id,
    required String tooltip,
    required String label,
    required T selected,
    required List<T> values,
    required String Function(T) labelOf,
    required ValueChanged<T> onSelected,
    bool active = false,
    String Function(T)? itemKeyOf,
  }) => FushiOverflowMenu<T>(
    key: ValueKey<String>(id),
    tooltip: tooltip,
    onSelected: onSelected,
    padding: EdgeInsets.zero,
    items: <PopupMenuEntry<T>>[
      for (final T value in values)
        FushiPopupMenuItem<T>(
          key: itemKeyOf == null ? null : ValueKey<String>(itemKeyOf(value)),
          value: value,
          label: labelOf(value),
          selected: selected == value,
        ),
    ],
    child: FushiApplePopUpButtonFace(label: label, active: active),
  );

  Widget _appleStatusPullDown(Map<DownloadTaskStatusFilter, int> counts) =>
      _applePullDown<DownloadTaskStatusFilter>(
        id: 'download-task-status-filter',
        tooltip: t.download_task_status_filter,
        label: downloadTaskStatusFilterLabel(_statusFilter),
        active: _statusFilter != DownloadTaskStatusFilter.all,
        selected: _statusFilter,
        values: DownloadTaskStatusFilter.values,
        labelOf: (DownloadTaskStatusFilter filter) =>
            '${downloadTaskStatusFilterLabel(filter)}  ${counts[filter] ?? 0}',
        itemKeyOf: (DownloadTaskStatusFilter filter) =>
            'download-task-status-${filter.name}',
        onSelected: (DownloadTaskStatusFilter filter) =>
            _update(() => _statusFilter = filter),
      );

  String _appleKindLabel(int value) => value < 0
      ? t.download_task_kind_all
      : downloadTaskKindLabel(DownloadTaskKind.values[value]);

  Widget _appleKindPullDown() => _applePullDown<int>(
    id: 'download-task-kind',
    tooltip: t.download_task_kind_filter,
    label: _appleKindLabel(_kind?.index ?? -1),
    active: _kind != null,
    selected: _kind?.index ?? -1,
    values: <int>[
      -1,
      for (final DownloadTaskKind kind in DownloadTaskKind.values) kind.index,
    ],
    labelOf: _appleKindLabel,
    onSelected: (int value) => _update(
      () => _kind = value < 0 ? null : DownloadTaskKind.values[value],
    ),
  );

  Widget _appleSortPullDown() => _applePullDown<DownloadTaskSort>(
    id: 'download-task-sort',
    tooltip: t.sort_by,
    label: _sortLabel(_sort),
    selected: _sort,
    values: DownloadTaskSort.values,
    labelOf: _sortLabel,
    onSelected: (DownloadTaskSort value) => _update(() => _sort = value),
  );

  Widget _appleGroupPullDown() => _applePullDown<DownloadTaskGrouping>(
    id: 'download-task-group',
    tooltip: t.download_task_group_by,
    label: _groupLabel(_grouping),
    selected: _grouping,
    values: DownloadTaskGrouping.values,
    labelOf: _groupLabel,
    onSelected: (DownloadTaskGrouping value) =>
        _update(() => _grouping = value),
  );

  /// 「⋯」里点了类型 / 排序 / 分组：在同一锚点弹出第二层选项。
  Future<void> _appleOpenChoice<T>(
    BuildContext anchor, {
    required List<T> values,
    required T selected,
    required String Function(T) labelOf,
    required ValueChanged<T> onSelected,
  }) async {
    final T? picked = await showFushiMenu<T>(
      context: anchor,
      position: appleDownloadMenuPosition(anchor),
      items: <PopupMenuEntry<T>>[
        for (final T value in values)
          FushiPopupMenuItem<T>(
            value: value,
            label: labelOf(value),
            selected: value == selected,
          ),
      ],
    );
    if (picked != null && mounted) onSelected(picked);
  }

  void _appleOnMenu(
    BuildContext anchor,
    _AppleDownloadMenuCommand command,
    List<DownloadTaskEntry> visible,
    List<DownloadTaskEntry> rendered,
  ) {
    switch (command) {
      case _AppleDownloadMenuCommand.kind:
        unawaited(
          _appleOpenChoice<int>(
            anchor,
            values: <int>[
              -1,
              for (final DownloadTaskKind kind in DownloadTaskKind.values)
                kind.index,
            ],
            selected: _kind?.index ?? -1,
            labelOf: _appleKindLabel,
            onSelected: (int value) => _update(
              () => _kind = value < 0 ? null : DownloadTaskKind.values[value],
            ),
          ),
        );
      case _AppleDownloadMenuCommand.sort:
        unawaited(
          _appleOpenChoice<DownloadTaskSort>(
            anchor,
            values: DownloadTaskSort.values,
            selected: _sort,
            labelOf: _sortLabel,
            onSelected: (DownloadTaskSort value) =>
                _update(() => _sort = value),
          ),
        );
      case _AppleDownloadMenuCommand.group:
        unawaited(
          _appleOpenChoice<DownloadTaskGrouping>(
            anchor,
            values: DownloadTaskGrouping.values,
            selected: _grouping,
            labelOf: _groupLabel,
            onSelected: (DownloadTaskGrouping value) =>
                _update(() => _grouping = value),
          ),
        );
      case _AppleDownloadMenuCommand.reverse:
        _update(() => _reverse = !_reverse);
      case _AppleDownloadMenuCommand.collapse:
        _update(() {
          _collapseAll = !_collapseAll;
          _expandedGroups.clear();
        });
      case _AppleDownloadMenuCommand.select:
        _update(() => _selectionMode = true);
      case _AppleDownloadMenuCommand.retryVisible:
        unawaited(
          _runBatchOn(
            List<DownloadTaskEntry>.of(visible),
            DownloadBatchAction.retry,
          ),
        );
      case _AppleDownloadMenuCommand.clearCompleted:
        unawaited(_confirmClearCompleted(List<DownloadTaskEntry>.of(rendered)));
      case _AppleDownloadMenuCommand.settings:
        widget.onOpenExecutionSettings?.call();
    }
  }

  /// 「⋯」菜单；[withFilters] = 类型 / 排序 / 分组也在里面（iOS 档；macOS 档
  /// 它们在右侧窗格）。
  Widget _appleMoreMenu(
    List<DownloadTaskEntry> visible,
    List<DownloadTaskEntry> rendered, {
    required bool withFilters,
  }) {
    final bool canRetry = visible.any(
      (DownloadTaskEntry task) => task.actions.retry != null,
    );
    final bool canClear = canClearCompletedDownloadTasks(
      selectCompletedDownloadTasks(rendered),
    );
    FushiPopupMenuItem<_AppleDownloadMenuCommand> item(
      _AppleDownloadMenuCommand value,
      IconData icon,
      String label, {
      bool selected = false,
      bool enabled = true,
    }) => FushiPopupMenuItem<_AppleDownloadMenuCommand>(
      key: ValueKey<String>('download-task-more-${value.name}'),
      value: value,
      icon: icon,
      label: label,
      selected: selected,
      enabled: enabled,
    );
    return Builder(
      builder: (BuildContext anchor) =>
          FushiOverflowMenu<_AppleDownloadMenuCommand>(
            key: const ValueKey<String>('download-task-more'),
            tooltip: t.common_more_actions,
            onSelected: (_AppleDownloadMenuCommand command) =>
                _appleOnMenu(anchor, command, visible, rendered),
            items: <PopupMenuEntry<_AppleDownloadMenuCommand>>[
              if (withFilters) ...<PopupMenuEntry<_AppleDownloadMenuCommand>>[
                item(
                  _AppleDownloadMenuCommand.kind,
                  FushiIcons.filterList,
                  '${t.download_task_kind_label} · '
                  '${_appleKindLabel(_kind?.index ?? -1)}',
                ),
                item(
                  _AppleDownloadMenuCommand.sort,
                  FushiIcons.sort,
                  '${t.sort_by} · ${_sortLabel(_sort)}',
                ),
              ],
              item(
                _AppleDownloadMenuCommand.reverse,
                FushiIcons.swapVert,
                t.download_task_sort_direction,
                selected: _reverse,
              ),
              if (withFilters)
                item(
                  _AppleDownloadMenuCommand.group,
                  FushiIcons.collection,
                  '${t.download_task_group_by} · ${_groupLabel(_grouping)}',
                ),
              if (_grouping != DownloadTaskGrouping.none)
                item(
                  _AppleDownloadMenuCommand.collapse,
                  _collapseAll ? FushiIcons.expandMore : FushiIcons.expandLess,
                  _collapseAll
                      ? t.download_task_groups_expand
                      : t.download_task_groups_collapse,
                ),
              const PopupMenuDivider(),
              item(
                _AppleDownloadMenuCommand.select,
                FushiIcons.checklist,
                t.batch_select,
              ),
              if (canRetry)
                item(
                  _AppleDownloadMenuCommand.retryVisible,
                  FushiIcons.refresh,
                  t.retry,
                  enabled: !_batchRunning,
                ),
              if (canClear)
                item(
                  _AppleDownloadMenuCommand.clearCompleted,
                  FushiIcons.deleteSweep,
                  t.download_clear_finished,
                  enabled: !_batchRunning,
                ),
              if (widget.onOpenExecutionSettings !=
                  null) ...<PopupMenuEntry<_AppleDownloadMenuCommand>>[
                const PopupMenuDivider(),
                item(
                  _AppleDownloadMenuCommand.settings,
                  FushiIcons.settings,
                  t.download_settings,
                ),
              ],
            ],
          ),
    );
  }

  /// 工具行末尾：＋ 添加 与 ⋯；编辑模式时换成「完成」。
  List<Widget> _appleToolbarActions(
    List<DownloadTaskEntry> visible,
    List<DownloadTaskEntry> rendered, {
    required bool withFilters,
  }) {
    if (_selectionMode) {
      return <Widget>[
        AppleDownloadTextAction(
          key: const ValueKey<String>('download-task-select-done'),
          label: t.dialog_done,
          onTap: _exitSelection,
        ),
      ];
    }
    // 在浏览页外壳里时「＋」已在导航栏玻璃按钮组（拍板点 8），页内不重复。
    final bool addInShell =
        FushiShellTitleScope.maybeActionsSlotOf(context) != null;
    return <Widget>[
      if (widget.onAddTask != null && !addInShell)
        FushiIconButton(
          key: const ValueKey<String>('download-task-add'),
          tooltip: t.download_task_add,
          icon: FushiIcons.add,
          onTap: widget.onAddTask,
        ),
      _appleMoreMenu(visible, rendered, withFilters: withFilters),
    ];
  }

  Widget _appleSearchField() => FushiSearchBar(
    fieldKey: const ValueKey<String>('download-task-search'),
    controller: _search,
    focusNode: _searchFocus,
    escapeBehavior: FushiSearchEscapeBehavior.clearThenUnfocus,
    hintText: t.download_task_search_hint,
    onQueryChanged: (_) => _update(() {}),
    onSubmitted: (_) => _update(() {}),
    onClear: () => _update(() {}),
  );

  Widget? _appleWorkFocusToken() {
    final DownloadTaskWorkFocus? focus = widget.workFocus;
    if (focus == null) return null;
    return AppleDownloadWorkFocusToken(
      label: t.download_task_work_focus_label(title: focus.title),
      onClear: widget.onClearWorkFocus,
    );
  }

  // ───────────── 行 ─────────────

  /// 编辑模式行首的圆形勾选（iOS 编辑模式）。
  Widget _appleCheckCircle(bool selected) {
    final FushiAppleColors apple = appleColorsOf(context);
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final double size = (metrics.desktop ? 18 : 22) * metrics.scale;
    return AnimatedContainer(
      duration: fushiMotionDuration(context, FushiMotion.short),
      curve: FushiMotion.standard,
      width: size,
      height: size,
      decoration: ShapeDecoration(
        color: selected ? apple.accent : const Color(0x00000000),
        shape: CircleBorder(
          side: selected
              ? BorderSide.none
              : BorderSide(color: apple.tertiaryLabel, width: 1.5),
        ),
      ),
      child: selected
          ? FushiIcon(FushiIcons.check, size: size * 0.7, color: apple.onAccent)
          : null,
    );
  }

  /// 编辑模式的一行：圆形勾选 + 原行（行内按钮让位，整行点按翻转选中）。
  Widget _appleSelectableRow(DownloadTaskEntry task) {
    final bool selected = _selectedIds.contains(task.id);
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    return Semantics(
      checked: selected,
      child: FushiAppleRow(
        key: ValueKey<String>('download-entry-select-${task.id}'),
        onTap: () => _toggleTask(task.id),
        child: Row(
          children: <Widget>[
            Padding(
              padding: EdgeInsetsDirectional.only(start: metrics.rowHorizontal),
              child: _appleCheckCircle(selected),
            ),
            Expanded(
              child: ExcludeFocus(
                child: IgnorePointer(child: task.builder(context)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  AppleDownloadSwipeAction? _appleLeadingSwipe(DownloadTaskEntry task) {
    if (_selectionMode) return null;
    for (final (DownloadBatchAction action, IconData icon, String label)
        in <(DownloadBatchAction, IconData, String)>[
          (DownloadBatchAction.pause, FushiIcons.pause, t.download_task_pause),
          (DownloadBatchAction.resume, FushiIcons.play, t.download_task_resume),
        ]) {
      if (downloadTaskBatchCallable(task, action) == null) continue;
      return AppleDownloadSwipeAction(
        icon: icon,
        label: label,
        onTriggered: () =>
            unawaited(_runBatchOn(<DownloadTaskEntry>[task], action)),
      );
    }
    return null;
  }

  AppleDownloadSwipeAction? _appleTrailingSwipe(DownloadTaskEntry task) {
    if (_selectionMode ||
        downloadTaskBatchCallable(task, DownloadBatchAction.delete) == null) {
      return null;
    }
    return AppleDownloadSwipeAction(
      icon: FushiIcons.delete,
      label: t.download_task_delete,
      destructive: true,
      onTriggered: () => unawaited(_confirmDelete(<DownloadTaskEntry>[task])),
    );
  }

  Widget _appleTaskRow(DownloadTaskEntry task, int index, int count) {
    final Widget row = DownloadTaskSegmentScope(
      index: index,
      count: count,
      child: _selectionMode ? _appleSelectableRow(task) : task.builder(context),
    );
    return AppleDownloadTaskSlice(
      key: ValueKey<String>('download-task-slice-${task.id}'),
      index: index,
      count: count,
      leading: _appleLeadingSwipe(task),
      trailing: _appleTrailingSwipe(task),
      child: row,
    );
  }

  Widget _appleGroupHeader(MapEntry<String, List<DownloadTaskEntry>> group) {
    final String key = '${_grouping.name}:${group.key}';
    final bool expanded = _groupExpanded(key);
    final double progress = downloadGroupProgress(group.value);
    final List<DownloadTaskEntry> deletable = group.value
        .where(
          (DownloadTaskEntry task) =>
              downloadTaskBatchCallable(task, DownloadBatchAction.delete) !=
              null,
        )
        .toList();
    return AppleDownloadSectionHeader(
      key: ValueKey<String>('download-group-$key'),
      title: _groupTitle(group.value.first),
      count: group.value.length,
      expanded: expanded,
      detail: !expanded && progress < 1 ? '${(progress * 100).round()}%' : null,
      onToggle: () => _update(() => _expandedGroups[key] = !expanded),
      trailing: !_selectionMode && deletable.isNotEmpty
          ? FushiIconButton(
              key: ValueKey<String>('download-group-delete-$key'),
              enabled: !_batchRunning,
              tooltip: t.download_task_group_delete,
              icon: FushiIcons.delete,
              size: 16,
              enabledColor: appleColorsOf(context).secondaryLabel,
              onTap: () => unawaited(_confirmDelete(deletable)),
            )
          : null,
    );
  }

  // ───────────── 版式 ─────────────

  Widget _buildApple(
    BuildContext context, {
    required List<DownloadTaskEntry> visible,
    required Map<String, List<DownloadTaskEntry>> groups,
    required List<DownloadTaskEntry> rendered,
    required Map<DownloadTaskStatusFilter, int> statusCounts,
  }) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final double page = tokens.spacing.page;
    final double k = metrics.scale;
    final double chromeInset = FushiFloatingChromeInset.of(context);
    final double bottomInset = MediaQuery.paddingOf(context).bottom;
    final double listBottomInset = _selectionMode ? 0 : bottomInset;
    final bool hasSummary = widget.tasks.isNotEmpty && !widget.loading;

    // 分组顺序：按状态分组时按生命周期排（需要处理 → 进行中 → … → 已完成），
    // 其余分组沿用首次出现的顺序（与 M3E 同）。
    final List<MapEntry<String, List<DownloadTaskEntry>>> sections =
        _grouping == DownloadTaskGrouping.none
        ? <MapEntry<String, List<DownloadTaskEntry>>>[]
        : groups.entries.toList();
    if (_grouping == DownloadTaskGrouping.status) {
      sections.sort(
        (
          MapEntry<String, List<DownloadTaskEntry>> a,
          MapEntry<String, List<DownloadTaskEntry>> b,
        ) => a.value.first.status.index.compareTo(b.value.first.status.index),
      );
    }
    // 扁平化：组标题与展开组的成员行，每行记下它在组里的位置（懒构建）。
    final List<(Object, int, int)> items = <(Object, int, int)>[];
    if (_grouping == DownloadTaskGrouping.none) {
      for (int i = 0; i < visible.length; i++) {
        items.add((visible[i], i, visible.length));
      }
    } else {
      for (final MapEntry<String, List<DownloadTaskEntry>> group in sections) {
        items.add((group, 0, 0));
        if (_groupExpanded('${_grouping.name}:${group.key}')) {
          for (int i = 0; i < group.value.length; i++) {
            items.add((group.value[i], i, group.value.length));
          }
        }
      }
    }

    Widget itemAt(BuildContext context, int index) {
      final (Object row, int segmentIndex, int count) = items[index];
      final int stagger = math.min(index, _kAppleDownloadStaggerCap);
      if (row is DownloadTaskEntry) {
        return FushiStaggeredEntrance(
          key: ValueKey<String>('download-entry-${row.id}'),
          index: stagger,
          child: _appleTaskRow(row, segmentIndex, count),
        );
      }
      return FushiStaggeredEntrance(
        index: stagger,
        child: _appleGroupHeader(
          row as MapEntry<String, List<DownloadTaskEntry>>,
        ),
      );
    }

    final bool none = widget.tasks.isEmpty;
    final Widget empty = none
        ? AppleDownloadEmptyState(
            icon: FushiIcons.downloading,
            message: t.anime_download_no_tasks,
            actionLabel: t.download_task_add,
            onAction: widget.onAddTask,
            actionKey: const ValueKey<String>('download-task-empty-add'),
          )
        : widget.workFocus != null && widget.onClearWorkFocus != null
        ? AppleDownloadEmptyState(
            icon: FushiIcons.searchOff,
            message: t.download_task_no_match,
            actionLabel: t.download_task_work_focus_clear,
            onAction: widget.onClearWorkFocus,
            actionKey: const ValueKey<String>(
              'download-task-empty-clear-work-focus',
            ),
          )
        : AppleDownloadEmptyState(
            icon: FushiIcons.searchOff,
            message: t.download_task_no_match,
          );

    final Widget body = widget.loading
        ? const SliverToBoxAdapter(child: AppleDownloadSkeleton())
        : items.isEmpty
        ? SliverFillRemaining(hasScrollBody: false, child: empty)
        : SliverList.builder(
            findChildIndexCallback: (Key key) {
              final int index = items.indexWhere(
                ((Object, int, int) item) =>
                    item.$1 is DownloadTaskEntry &&
                    key ==
                        ValueKey<String>(
                          'download-entry-${(item.$1 as DownloadTaskEntry).id}',
                        ),
              );
              return index < 0 ? null : index;
            },
            itemCount: items.length,
            itemBuilder: itemAt,
          );

    final MediaQueryData media = MediaQuery.of(context);

    Widget scroller({required bool sidePane}) {
      final Widget? token = _appleWorkFocusToken();
      final double gap = 8 * k;
      final Widget controls = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (sidePane)
            Row(
              children: <Widget>[
                Expanded(child: _appleSearchField()),
                SizedBox(width: gap),
                ..._appleToolbarActions(visible, rendered, withFilters: false),
              ],
            )
          else ...<Widget>[
            _appleSearchField(),
            SizedBox(height: gap),
            Row(
              children: <Widget>[
                _appleStatusPullDown(statusCounts),
                const Spacer(),
                ..._appleToolbarActions(visible, rendered, withFilters: true),
              ],
            ),
          ],
          if (token != null) ...<Widget>[SizedBox(height: gap), token],
          if (!sidePane && hasSummary) ...<Widget>[
            SizedBox(height: 3 * gap),
            _appleSummaryGroup(),
          ],
        ],
      );
      return FushiEntranceScope(
        replayKey: _statusFilter,
        child: MediaQuery(
          data: media.copyWith(
            padding: media.padding.copyWith(top: chromeInset),
          ),
          child: CustomScrollView(
            key: const PageStorageKey<String>('download-task-list'),
            slivers: <Widget>[
              SliverToBoxAdapter(child: SizedBox(height: chromeInset)),
              if (widget.header != null)
                SliverPadding(
                  padding: EdgeInsets.symmetric(horizontal: page),
                  sliver: SliverToBoxAdapter(child: widget.header),
                ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(page, gap, page, 0),
                sliver: SliverToBoxAdapter(
                  child: FushiStaggeredEntrance(index: 0, child: controls),
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  page,
                  _grouping == DownloadTaskGrouping.none ? 3 * gap : 0,
                  page,
                  listBottomInset + 24,
                ),
                sliver: body,
              ),
            ],
          ),
        ),
      );
    }

    Widget sidePaneContent() {
      final FushiAppleMetrics m = FushiAppleMetrics.of(context);
      Widget header(String text) => Padding(
        padding: EdgeInsetsDirectional.fromSTEB(
          m.rowHorizontal,
          m.groupSpacing,
          m.rowHorizontal,
          6,
        ),
        child: Text(text, style: m.footnoteStyle(context)),
      );
      Widget pullDownRow(String label, Widget pullDown) => ConstrainedBox(
        constraints: BoxConstraints(minHeight: m.rowMinHeight),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: m.rowHorizontal),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: m.titleStyle(context),
                ),
              ),
              pullDown,
            ],
          ),
        ),
      );
      const List<DownloadTaskStatusFilter> filters =
          DownloadTaskStatusFilter.values;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (hasSummary)
            FushiStaggeredEntrance(index: 0, child: _appleSummaryGroup()),
          FushiStaggeredEntrance(
            index: 1,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                header(t.download_task_status_filter),
                FushiAppleGroupSurface(
                  key: const ValueKey<String>('download-task-status-filter'),
                  child: Column(
                    children: <Widget>[
                      for (final DownloadTaskStatusFilter filter in filters)
                        AppleDownloadFilterRow(
                          key: ValueKey<String>(
                            'download-task-status-${filter.name}',
                          ),
                          label: downloadTaskStatusFilterLabel(filter),
                          count: statusCounts[filter] ?? 0,
                          selected: _statusFilter == filter,
                          onTap: () => _update(() => _statusFilter = filter),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          FushiStaggeredEntrance(
            index: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                header(t.download_task_display_section),
                FushiAppleGroupSurface(
                  child: Column(
                    children: <Widget>[
                      pullDownRow(
                        t.download_task_kind_label,
                        _appleKindPullDown(),
                      ),
                      pullDownRow(t.sort_by, _appleSortPullDown()),
                      pullDownRow(
                        t.download_task_group_by,
                        _appleGroupPullDown(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return FushiSearchFocusKeys(
      focusNode: _searchFocus,
      controller: _search,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool sidePane =
              fushiAppleUsesMacMetrics(context) &&
              constraints.maxWidth >= _kAppleDownloadSidePaneBreakpoint * k;
          final Widget main = sidePane
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(child: scroller(sidePane: true)),
                    SizedBox(
                      width: _kAppleDownloadSidePaneWidth * k,
                      child: FushiEntranceScope(
                        child: SingleChildScrollView(
                          key: const ValueKey<String>(
                            'download-task-side-pane',
                          ),
                          // 主列表才是主滚动视图（见 M3E 宽屏窗格同一注释）。
                          primary: false,
                          padding: EdgeInsets.fromLTRB(
                            0,
                            chromeInset + 8 * k,
                            page,
                            page + listBottomInset,
                          ),
                          child: sidePaneContent(),
                        ),
                      ),
                    ),
                  ],
                )
              : scroller(sidePane: false);
          return Column(
            children: <Widget>[
              Expanded(child: main),
              if (_selectionMode)
                Padding(
                  padding: EdgeInsets.only(bottom: bottomInset),
                  child: _buildBatchBar(rendered),
                ),
            ],
          );
        },
      ),
    );
  }
}
