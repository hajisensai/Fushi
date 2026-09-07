import 'package:flutter/material.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';

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

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
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
                  (DownloadTaskEntry task) => task.onRetry != null,
                ))
                  TextButton(
                    onPressed: () {
                      for (final DownloadTaskEntry task in visible) {
                        task.onRetry?.call();
                      }
                    },
                    child: Text(t.retry),
                  ),
                if (visible.any(
                  (DownloadTaskEntry task) => task.onClear != null,
                ))
                  TextButton(
                    onPressed: () {
                      for (final DownloadTaskEntry task in visible) {
                        task.onClear?.call();
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
                        child: row.builder(context),
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
      ],
    );
  }
}
