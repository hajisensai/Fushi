import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/media/downloads/download_batch.dart';
import 'package:fushi/src/media/downloads/download_task_delete_confirm.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/src/utils/components/batch_action_bar.dart';

enum DownloadTaskSort { created, title, progress, status }

enum DownloadTaskGrouping { none, collection, kind, status }

String downloadTaskKindLabel(DownloadTaskKind kind) => switch (kind) {
  DownloadTaskKind.video => t.anime_download_kind_video,
  DownloadTaskKind.novel => t.books,
  DownloadTaskKind.audiobook => t.discovery_kind_audiobook,
  DownloadTaskKind.game => t.nav_game,
  DownloadTaskKind.manga => t.manga_library,
};

String downloadTaskStatusLabel(DownloadTaskStatus status) => switch (status) {
  DownloadTaskStatus.attention => t.download_task_status_attention,
  DownloadTaskStatus.active => t.download_task_status_active,
  DownloadTaskStatus.queued => t.download_status_queued,
  DownloadTaskStatus.paused => t.download_task_status_paused,
  DownloadTaskStatus.completed => t.download_task_status_completed,
  DownloadTaskStatus.cancelled => t.download_status_cancelled,
};

List<DownloadTaskEntry> selectDownloadTasks(
  List<DownloadTaskEntry> tasks, {
  String query = '',
  DownloadTaskKind? kind,
  DownloadTaskStatus? status,
  DownloadTaskSort sort = DownloadTaskSort.created,
  bool reverse = false,
}) {
  final List<DownloadTaskEntry> result = filterByMediaSearch(
    tasks
        .where(
          (DownloadTaskEntry task) =>
              (kind == null || task.kind == kind) &&
              (status == null || task.status == status),
        )
        .toList(),
    query,
    (DownloadTaskEntry task) => <String>[
      task.title,
      if (task.collectionTitle != null) task.collectionTitle!,
      ...task.searchTerms,
    ],
  );
  int compareNullable(num? a, num? b) {
    // Unknown observations stay at the end in either direction.
    if (a == null) return b == null ? 0 : 1;
    if (b == null) return -1;
    return reverse ? a.compareTo(b) : b.compareTo(a);
  }

  result.sort((DownloadTaskEntry a, DownloadTaskEntry b) {
    final int primary = switch (sort) {
      DownloadTaskSort.created => compareNullable(a.createdAt, b.createdAt),
      DownloadTaskSort.progress => compareNullable(a.progress, b.progress),
      DownloadTaskSort.title =>
        (reverse ? -1 : 1) *
            a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      DownloadTaskSort.status =>
        (reverse ? -1 : 1) * a.status.index.compareTo(b.status.index),
    };
    if (primary != 0) return primary;
    final int byTime = (b.createdAt ?? 0).compareTo(a.createdAt ?? 0);
    return byTime != 0 ? byTime : a.id.compareTo(b.id);
  });
  return result;
}

/// One filter, one ordering and one scroll surface for all download engines.
class DownloadTaskBrowser extends StatefulWidget {
  const DownloadTaskBrowser({required this.tasks, super.key});
  final List<DownloadTaskEntry> tasks;

  @override
  State<DownloadTaskBrowser> createState() => _DownloadTaskBrowserState();
}

class _DownloadTaskBrowserState extends State<DownloadTaskBrowser> {
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  DownloadTaskKind? _kind;
  DownloadTaskStatus? _status;
  DownloadTaskSort _sort = DownloadTaskSort.created;
  DownloadTaskGrouping _grouping = DownloadTaskGrouping.collection;
  bool _reverse = false;
  bool _collapseAll = false;
  final Map<String, bool> _expandedGroups = <String, bool>{};
  bool _selectionMode = false;
  /// 选中的任务 id。可见集合会随筛选 / 刷新变化，所以每次真正执行前都拿当前
  /// 可见列表与它取交集（见 [_selectedVisible]）——不这么做，批量动作会作用在
  /// 用户已经看不见、甚至已经不存在的条目上。
  final Set<String> _selectedIds = <String>{};

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// 选中集与**当前可见列表**的交集，按可见顺序排列。
  ///
  /// 选中集是纯 id，可见集合却会随筛选、搜索、分组折叠与后台刷新变化。批量动作
  /// 一律作用于这个交集：既避免动到用户已经筛掉的条目，也天然剔掉已经消失的
  /// 幽灵 id（任务跑完被清出列表、直链/mokuro 的自增 id 随进程重启作废）。
  List<DownloadTaskEntry> _selectedVisible(List<DownloadTaskEntry> visible) {
    return visible
        .where((DownloadTaskEntry task) => _selectedIds.contains(task.id))
        .toList();
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  void _toggleTask(String id) {
    setState(() {
      if (!_selectedIds.remove(id)) _selectedIds.add(id);
    });
  }

  /// 批量执行一个动作。
  ///
  /// 目标集在 await 之前就用 [List.of] 定死：执行期间列表会因后台刷新重建，跨
  /// await 两侧各读一次会让「报告里的条数」和「真正动过的条目」对不上。
  Future<void> _runBatch(
    List<DownloadTaskEntry> visible,
    DownloadBatchAction action, {
    bool deleteFiles = false,
  }) async {
    final List<DownloadTaskEntry> targets = List<DownloadTaskEntry>.of(
      _selectedVisible(visible),
    );
    if (targets.isEmpty) return;
    final DownloadBatchOutcome outcome = await runDownloadTaskBatch(
      tasks: targets,
      action: action,
      deleteFiles: deleteFiles,
    );
    if (!mounted) return;
    setState(() {
      // 已处理的条目退出选中：留着会让下一次批量重复作用在它们身上。
      for (final DownloadTaskEntry task in targets) {
        _selectedIds.remove(task.id);
      }
      if (_selectedIds.isEmpty) _selectionMode = false;
    });
    final String message = describeDownloadBatchOutcome(outcome);
    if (message.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  /// 批量删除：整批只问一次「要不要连文件一起删」。
  Future<void> _confirmBatchDelete(List<DownloadTaskEntry> visible) async {
    final List<DownloadTaskEntry> targets = _selectedVisible(visible);
    if (targets.isEmpty) return;
    // 「同时删除文件」只在选中集里真有条目兑现得了时才摆出来——mokuro / 直链
    // 只能把条目移出列表，勾了也删不掉盘上的东西。
    final bool offerDeleteFiles = targets.any(
      (DownloadTaskEntry task) => task.actions.delete != null,
    );
    final bool? deleteFiles = await showDownloadTaskDeleteConfirm(
      context,
      title: '',
      message: t.download_batch_delete_confirm(n: targets.length),
      keySuffix: 'batch',
      offerDeleteFiles: offerDeleteFiles,
    );
    if (deleteFiles == null || !mounted) return;
    await _runBatch(
      visible,
      DownloadBatchAction.delete,
      deleteFiles: deleteFiles,
    );
  }

  /// 选择态下的一行：勾选框 + 原卡片。
  ///
  /// 卡片被 [IgnorePointer] 罩住，整行点击一律翻转选中——选择态里卡片自带的
  /// 重试 / 删除按钮必须让位，否则「想勾第三条」会变成「把第三条删了」。
  Widget _selectableRow(DownloadTaskEntry task) {
    final bool selected = _selectedIds.contains(task.id);
    return InkWell(
      key: ValueKey<String>('download-entry-select-${task.id}'),
      onTap: () => _toggleTask(task.id),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Checkbox(
            value: selected,
            onChanged: (_) => _toggleTask(task.id),
          ),
          Expanded(
            child: IgnorePointer(child: task.builder(context)),
          ),
        ],
      ),
    );
  }

  /// 底部批量操作栏。动作按钮按「选中集里有几条真支持它」决定可用态。
  Widget _buildBatchBar(List<DownloadTaskEntry> visible) {
    final List<DownloadTaskEntry> selected = _selectedVisible(visible);
    final ThemeData theme = Theme.of(context);
    Widget action({
      required String id,
      required IconData icon,
      required String tooltip,
      required DownloadBatchAction batchAction,
      VoidCallback? onTap,
      Color? enabledColor,
    }) {
      final bool enabled =
          countDownloadTasksSupporting(selected, batchAction) > 0;
      return FushiIconButton(
        key: ValueKey<String>('download-batch-$id'),
        enabled: enabled,
        tooltip: tooltip,
        icon: icon,
        enabledColor: enabledColor,
        onTap: onTap ?? () => unawaited(_runBatch(visible, batchAction)),
      );
    }

    return BatchActionBar(
      selectedCount: selected.length,
      onSelectAll: () => setState(
        () => _selectedIds.addAll(
          visible.map((DownloadTaskEntry task) => task.id),
        ),
      ),
      onInvertSelection: () => setState(() {
        final Set<String> next = <String>{
          for (final DownloadTaskEntry task in visible)
            if (!_selectedIds.contains(task.id)) task.id,
        };
        _selectedIds
          ..clear()
          ..addAll(next);
      }),
      actions: <Widget>[
        action(
          id: 'resume',
          icon: Icons.play_arrow,
          tooltip: t.download_task_resume,
          batchAction: DownloadBatchAction.resume,
        ),
        action(
          id: 'pause',
          icon: Icons.pause,
          tooltip: t.download_task_pause,
          batchAction: DownloadBatchAction.pause,
        ),
        action(
          id: 'retry',
          icon: Icons.refresh,
          tooltip: t.retry,
          batchAction: DownloadBatchAction.retry,
        ),
        action(
          id: 'cancel',
          icon: Icons.close,
          tooltip: t.dialog_cancel,
          batchAction: DownloadBatchAction.cancel,
        ),
        action(
          id: 'clear',
          icon: Icons.playlist_remove,
          tooltip: t.download_clear_finished,
          batchAction: DownloadBatchAction.clear,
        ),
        action(
          id: 'delete',
          icon: Icons.delete_outline,
          tooltip: t.download_task_delete,
          batchAction: DownloadBatchAction.delete,
          enabledColor: theme.colorScheme.error,
          onTap: () => unawaited(_confirmBatchDelete(visible)),
        ),
      ],
    );
  }

  String _sortLabel(DownloadTaskSort value) => switch (value) {
    DownloadTaskSort.created => t.download_task_sort_created,
    DownloadTaskSort.title => t.sort_title,
    DownloadTaskSort.progress => t.download_task_sort_progress,
    DownloadTaskSort.status => t.download_task_sort_status,
  };

  String _groupLabel(DownloadTaskGrouping value) => switch (value) {
    DownloadTaskGrouping.none => t.download_task_group_none,
    DownloadTaskGrouping.collection => t.download_task_group_collection,
    DownloadTaskGrouping.kind => t.download_task_group_kind,
    DownloadTaskGrouping.status => t.download_task_group_status,
  };

  Widget _menu<T extends Object>({
    required String id,
    required String label,
    required T selected,
    required List<T> values,
    required String Function(T) labelOf,
    required ValueChanged<T> onSelected,
    required IconData icon,
  }) => FushiOverflowMenu<T>(
    key: ValueKey<String>(id),
    tooltip: label,
    onSelected: onSelected,
    items: <PopupMenuEntry<T>>[
      for (final T value in values)
        FushiPopupMenuItem<T>(
          value: value,
          label: labelOf(value),
          selected: selected == value,
        ),
    ],
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 18),
          const SizedBox(width: 6),
          Flexible(
            child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
          const Icon(Icons.arrow_drop_down, size: 18),
        ],
      ),
    ),
  );

  String _groupKey(DownloadTaskEntry task) => switch (_grouping) {
    DownloadTaskGrouping.none => '',
    DownloadTaskGrouping.collection => task.collectionKey ?? 'unassigned',
    DownloadTaskGrouping.kind => task.kind.name,
    DownloadTaskGrouping.status => task.status.name,
  };

  String _groupTitle(DownloadTaskEntry task) => switch (_grouping) {
    DownloadTaskGrouping.none => '',
    DownloadTaskGrouping.collection =>
      task.collectionKey == null
          ? t.download_task_collection_unassigned
          : task.collectionTitle ?? task.title,
    DownloadTaskGrouping.kind => downloadTaskKindLabel(task.kind),
    DownloadTaskGrouping.status => downloadTaskStatusLabel(task.status),
  };

  @override
  Widget build(BuildContext context) {
    final List<DownloadTaskEntry> visible = selectDownloadTasks(
      widget.tasks,
      query: _search.text,
      kind: _kind,
      status: _status,
      sort: _sort,
      reverse: _reverse,
    );
    final Map<String, List<DownloadTaskEntry>> groups =
        <String, List<DownloadTaskEntry>>{};
    for (final DownloadTaskEntry task in visible) {
      groups
          .putIfAbsent(_groupKey(task), () => <DownloadTaskEntry>[])
          .add(task);
    }
    // Flatten headers and visible members so every task remains lazily built.
    final List<Object> rows = <Object>[];
    for (final MapEntry<String, List<DownloadTaskEntry>> group
        in groups.entries) {
      if (_grouping != DownloadTaskGrouping.none) rows.add(group);
      if (_grouping == DownloadTaskGrouping.none ||
          (_expandedGroups['${_grouping.name}:${group.key}'] ??
              !_collapseAll)) {
        rows.addAll(group.value);
      }
    }
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: FushiSearchField(
            fieldKey: const ValueKey<String>('download-task-search'),
            controller: _search,
            focusNode: _searchFocus,
            hintText: t.download_task_search_hint,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => setState(() {}),
            onClear: () => setState(_search.clear),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                _menu<int>(
                  id: 'download-task-kind',
                  label: _kind == null
                      ? t.download_task_kind_all
                      : downloadTaskKindLabel(_kind!),
                  selected: _kind?.index ?? -1,
                  values: <int>[-1, 0, 1, 2, 3, 4],
                  labelOf: (int value) => value < 0
                      ? t.download_task_kind_all
                      : downloadTaskKindLabel(DownloadTaskKind.values[value]),
                  onSelected: (int value) => setState(
                    () => _kind = value < 0
                        ? null
                        : DownloadTaskKind.values[value],
                  ),
                  icon: Icons.filter_list,
                ),
                _menu<int>(
                  id: 'download-task-status',
                  label: _status == null
                      ? t.download_task_status_filter
                      : downloadTaskStatusLabel(_status!),
                  selected: _status?.index ?? -1,
                  values: <int>[-1, 0, 1, 2, 3, 4, 5],
                  labelOf: (int value) => value < 0
                      ? t.download_task_kind_all
                      : downloadTaskStatusLabel(
                          DownloadTaskStatus.values[value],
                        ),
                  onSelected: (int value) => setState(
                    () => _status = value < 0
                        ? null
                        : DownloadTaskStatus.values[value],
                  ),
                  icon: Icons.checklist,
                ),
                _menu<DownloadTaskSort>(
                  id: 'download-task-sort',
                  label: _sortLabel(_sort),
                  selected: _sort,
                  values: DownloadTaskSort.values,
                  labelOf: _sortLabel,
                  onSelected: (DownloadTaskSort value) =>
                      setState(() => _sort = value),
                  icon: Icons.sort,
                ),
                FushiIconButton(
                  tooltip: t.download_task_sort_direction,
                  icon: _reverse ? Icons.arrow_upward : Icons.arrow_downward,
                  onTap: () => setState(() => _reverse = !_reverse),
                ),
                _menu<DownloadTaskGrouping>(
                  id: 'download-task-group',
                  label: _groupLabel(_grouping),
                  selected: _grouping,
                  values: DownloadTaskGrouping.values,
                  labelOf: _groupLabel,
                  onSelected: (DownloadTaskGrouping value) =>
                      setState(() => _grouping = value),
                  icon: Icons.folder_copy_outlined,
                ),
                FushiIconButton(
                  key: const ValueKey<String>('download-task-select-mode'),
                  tooltip: _selectionMode ? t.dialog_cancel : t.batch_select,
                  icon: _selectionMode
                      ? Icons.close
                      : Icons.checklist_outlined,
                  onTap: () {
                    if (_selectionMode) {
                      _exitSelection();
                    } else {
                      setState(() => _selectionMode = true);
                    }
                  },
                ),
                if (_grouping != DownloadTaskGrouping.none)
                  FushiIconButton(
                    key: const ValueKey<String>('download-task-collapse-all'),
                    tooltip: _collapseAll
                        ? t.download_task_groups_expand
                        : t.download_task_groups_collapse,
                    icon: _collapseAll ? Icons.unfold_more : Icons.unfold_less,
                    onTap: () => setState(() {
                      _collapseAll = !_collapseAll;
                      _expandedGroups.clear();
                    }),
                  ),
                if (visible.any(
                  (DownloadTaskEntry task) => task.actions.retry != null,
                ))
                  TextButton(
                    onPressed: () {
                      for (final DownloadTaskEntry task in visible) {
                        unawaited(task.actions.retry?.call() ?? Future<void>.value());
                      }
                    },
                    child: Text(t.retry),
                  ),
                if (visible.any(
                  (DownloadTaskEntry task) => task.actions.clear != null,
                ))
                  TextButton(
                    onPressed: () {
                      for (final DownloadTaskEntry task in visible) {
                        unawaited(task.actions.clear?.call() ?? Future<void>.value());
                      }
                    },
                    child: Text(t.download_clear_finished),
                  ),
                Text(
                  '${visible.length} / ${widget.tasks.length}',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Text(
                    widget.tasks.isEmpty
                        ? t.anime_download_no_tasks
                        : t.download_task_no_match,
                  ),
                )
              : ListView.builder(
                  key: const PageStorageKey<String>('download-task-list'),
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                  findChildIndexCallback: (Key key) {
                    final int index = rows.indexWhere(
                      (Object row) =>
                          row is DownloadTaskEntry &&
                          key == ValueKey<String>('download-entry-${row.id}'),
                    );
                    return index < 0 ? null : index;
                  },
                  itemCount: rows.length,
                  itemBuilder: (BuildContext context, int index) {
                    final Object row = rows[index];
                    if (row is DownloadTaskEntry) {
                      return Padding(
                        key: ValueKey<String>('download-entry-${row.id}'),
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _selectionMode
                            ? _selectableRow(row)
                            : row.builder(context),
                      );
                    }
                    final MapEntry<String, List<DownloadTaskEntry>> group =
                        row as MapEntry<String, List<DownloadTaskEntry>>;
                    final String key = '${_grouping.name}:${group.key}';
                    final bool expanded = _expandedGroups[key] ?? !_collapseAll;
                    final int completed = group.value
                        .where(
                          (DownloadTaskEntry task) =>
                              task.status == DownloadTaskStatus.completed,
                        )
                        .length;
                    return Semantics(
                      expanded: expanded,
                      child: FushiListItem(
                        key: ValueKey<String>('download-group-$key'),
                        leading: Icon(
                          expanded ? Icons.expand_more : Icons.chevron_right,
                        ),
                        title: Text(_groupTitle(group.value.first)),
                        titleMaxLines: 2,
                        trailing: Text('$completed / ${group.value.length}'),
                        onTap: () =>
                            setState(() => _expandedGroups[key] = !expanded),
                      ),
                    );
                  },
                ),
        ),
        if (_selectionMode) _buildBatchBar(visible),
      ],
    );
  }
}
