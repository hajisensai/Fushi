import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/media/downloads/download_batch.dart';
import 'package:fushi/src/media/downloads/download_task_delete_confirm.dart';
import 'package:fushi/src/media/downloads/download_task_entry.dart';
import 'package:fushi/src/utils/components/batch_action_bar.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show FushiFloatingChromeInset;
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_search.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

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

/// 一组任务的整体完成度（0..1）。
///
/// 已完成的任务记满，进度未知的记 0，按组内**全部**任务数取平均。分母刻意不用
/// 「有进度的任务数」——10 条里只有 1 条报了 100%，那样算出来就是 100%，会把刚
/// 开跑的一组说成已经下完。
double downloadGroupProgress(List<DownloadTaskEntry> tasks) {
  if (tasks.isEmpty) return 0;
  double sum = 0;
  for (final DownloadTaskEntry task in tasks) {
    sum += task.status == DownloadTaskStatus.completed
        ? 1
        : (task.progress ?? 0).clamp(0, 1).toDouble();
  }
  return sum / tasks.length;
}

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

/// 状态分段筛选（M3E 分段：全部 / 下载中 / 做种 / 已完成 / 出错）。
///
/// 与 [DownloadTaskStatus] 不是一一对应：「做种」来自 [DownloadTaskEntry.seeding]
/// （生命周期上它可能是完成也可能还在跑），「下载中」含排队、不含做种；已暂停 /
/// 已取消只在「全部」里。
enum DownloadTaskStatusFilter { all, downloading, seeding, completed, error }

bool downloadTaskMatchesStatusFilter(
  DownloadTaskEntry task,
  DownloadTaskStatusFilter filter,
) => switch (filter) {
  DownloadTaskStatusFilter.all => true,
  DownloadTaskStatusFilter.downloading =>
    !task.seeding &&
        (task.status == DownloadTaskStatus.active ||
            task.status == DownloadTaskStatus.queued),
  DownloadTaskStatusFilter.seeding => task.seeding,
  DownloadTaskStatusFilter.completed =>
    task.status == DownloadTaskStatus.completed,
  DownloadTaskStatusFilter.error => task.status == DownloadTaskStatus.attention,
};

String downloadTaskStatusFilterLabel(DownloadTaskStatusFilter filter) =>
    switch (filter) {
      DownloadTaskStatusFilter.all => t.download_task_status_all,
      DownloadTaskStatusFilter.downloading => t.download_task_status_downloading,
      DownloadTaskStatusFilter.seeding => t.download_task_status_seeding,
      DownloadTaskStatusFilter.completed => t.download_task_status_completed,
      DownloadTaskStatusFilter.error => t.download_task_status_error,
    };

/// 宽于此值时任务列表在左、汇总 / 筛选窗格在右。
const double kDownloadBrowserWideBreakpoint = 960;

/// One filter, one ordering and one scroll surface for all download engines.
///
/// M3E 形态（2026-10）：顶部汇总 hero（总速度 + 计数 chip + 执行设备 chip +
/// 全部暂停 / 继续按钮组）、状态分段、搜索与工具胶囊、错峰进场的任务卡；宽屏
/// 汇总与筛选挪进右侧窗格；数据未到时画骨架；[onAddTask] 给了就挂添加任务 FAB。
class DownloadTaskBrowser extends StatefulWidget {
  const DownloadTaskBrowser({
    required this.tasks,
    super.key,
    this.loading = false,
    this.onAddTask,
    this.executionDeviceLabel,
    this.onOpenExecutionSettings,
    this.header,
  });
  final List<DownloadTaskEntry> tasks;

  /// 列表最上方（汇总之前）随列表一起滚动的一块（网络问题横幅 / 加载失败提示）。
  final Widget? header;

  /// 首个数据快照还没到：画骨架而不是「暂无任务」。
  final bool loading;

  /// 添加任务（磁力 / 种子 / 链接）；null = 不挂 FAB、空状态不给按钮。
  final VoidCallback? onAddTask;

  /// 新任务的执行设备：null = 本机；非 null = 已配对互联主机的名字。
  final String? executionDeviceLabel;

  /// 点执行设备 chip：去下载设置改它。
  final VoidCallback? onOpenExecutionSettings;

  @override
  State<DownloadTaskBrowser> createState() => _DownloadTaskBrowserState();
}

class _DownloadTaskBrowserState extends State<DownloadTaskBrowser> {
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  DownloadTaskKind? _kind;
  DownloadTaskStatusFilter _statusFilter = DownloadTaskStatusFilter.all;
  DownloadTaskSort _sort = DownloadTaskSort.created;
  DownloadTaskGrouping _grouping = DownloadTaskGrouping.collection;
  bool _reverse = false;
  bool _collapseAll = false;
  final Map<String, bool> _expandedGroups = <String, bool>{};
  bool _selectionMode = false;
  /// 整批执行中：期间禁掉全部批量按钮。没有这道锁，连点两下就是整批跑两遍
  /// （同一 hash 被 addTorrent 两次 / 对已删条目再删一遍），也把 runDownloadTaskBatch
  /// 的串行保证在整批层面破掉了。
  bool _batchRunning = false;
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

  /// 选中集与**屏幕上真正渲染出来的行**的交集，按渲染顺序排列。
  ///
  /// 传进来的必须是 rows 里的 entry（见 build 末尾的 `_visibleEntries`），**不是**
  /// 筛选后的全集 `visible`：分组折叠时被收起来的成员仍在 `visible` 里，拿它当域
  /// 会让「全选 → 删除」把用户根本没看见的条目连同磁盘文件一起删掉——确认框写
  /// 「删除 15 个」而屏幕上只有 3 张卡。
  ///
  /// 选中集是纯 id，渲染集合会随筛选、搜索、分组折叠与后台刷新变化，所以每次都
  /// 现取交集：既避免动到用户看不见的条目，也天然剔掉已经消失的幽灵 id（任务跑完
  /// 被清出列表、直链/mokuro 的自增 id 随进程重启作废）。
  List<DownloadTaskEntry> _selectedVisible(List<DownloadTaskEntry> rendered) {
    return rendered
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

  /// 批量执行一个动作（目标集已定死）。
  ///
  /// [targets] 由调用方在**任何 await 之前**取好并定死：执行期间列表会因后台刷新
  /// 重建，跨 await 两侧各求一次交集会让「确认框里的 N」和「真正动过的条目」对不上。
  Future<void> _runBatchOn(
    List<DownloadTaskEntry> targets,
    DownloadBatchAction action, {
    bool deleteFiles = false,
  }) async {
    if (targets.isEmpty || _batchRunning) return;
    setState(() => _batchRunning = true);
    DownloadBatchOutcome outcome = const DownloadBatchOutcome();
    try {
      outcome = await runDownloadTaskBatch(
        tasks: targets,
        action: action,
        deleteFiles: deleteFiles,
        // 失败条目只在计数里体现是不够的：没有 stack trace 就没法查根因。
        onError: (Object error, StackTrace stackTrace) => debugPrint(
          '[fushi-downloads] batch ${action.name} failed: $error\n$stackTrace',
        ),
      );
    } finally {
      if (mounted) setState(() => _batchRunning = false);
    }
    if (!mounted) return;
    setState(() {
      // 已处理的条目退出选中：留着会让下一次批量重复作用在它们身上。
      for (final DownloadTaskEntry task in targets) {
        _selectedIds.remove(task.id);
      }
      _pruneSelection();
    });
    final String message = describeDownloadBatchOutcome(outcome);
    if (message.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(
      FushiSnackBar(content: Text(message)),
    );
  }

  /// 剔掉选中集里已经不存在的 id，并在真的空了之后退出选择态。
  ///
  /// 判据用**任务全集**而不是当前渲染集：被搜索或折叠暂时藏起来的选中项还活着，
  /// 拿渲染集判会让批量栏卡在「已选 0」——全部按钮禁用、看着像卡死，清空搜索后
  /// 那几条又带着选中态冒出来。
  void _pruneSelection() {
    final Set<String> alive = <String>{
      for (final DownloadTaskEntry task in widget.tasks) task.id,
    };
    _selectedIds.removeWhere((String id) => !alive.contains(id));
    if (_selectedIds.isEmpty) _selectionMode = false;
  }

  /// 批量删除：整批只问一次「要不要连文件一起删」。
  ///
  /// 目标集在弹确认框**之前**就定死并一路带到执行：确认框可能停留好几秒，期间
  /// 后台轮询会重建列表，跨 await 重算一次交集会让确认框里的 N 与实际删除量对不上，
  /// 甚至对已经消失的条目调 delete。
  Future<void> _confirmBatchDelete(List<DownloadTaskEntry> rendered) =>
      _confirmDelete(List<DownloadTaskEntry>.of(_selectedVisible(rendered)));

  /// 删除一个已定死的目标集（多选批量 / 整组删除共用）：整批只问一次「要不要连
  /// 文件一起删」。确认框里的 N 就是 [targets] 的条数。
  Future<void> _confirmDelete(List<DownloadTaskEntry> targets) async {
    if (targets.isEmpty || _batchRunning) return;
    // 「同时删除文件」只在选中集里真有条目兑现得了时才摆出来——mokuro / 直链
    // 只能把条目移出列表，勾了也删不掉盘上的东西（与单条删除确认框同一纪律）。
    final bool offerDeleteFiles = targets.any(
      (DownloadTaskEntry task) => task.actions.deletesFiles,
    );
    final bool? deleteFiles = await showDownloadTaskDeleteConfirm(
      context,
      title: '',
      message: t.download_batch_delete_confirm(n: targets.length),
      keySuffix: 'batch',
      offerDeleteFiles: offerDeleteFiles,
    );
    if (deleteFiles == null || !mounted) return;
    await _runBatchOn(
      targets,
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
          FushiCheckbox(
            value: selected,
            onChanged: (_) => _toggleTask(task.id),
          ),
          Expanded(
            // IgnorePointer 只挡指针。卡片里的重试/删除是真正可聚焦的按钮，光挡
            // 指针的话手柄/键盘用户方向键仍会走进去，按 Enter 直接删任务——
            // 「想勾第三条变成把第三条删了」在键盘路径上照样成立。
            child: ExcludeFocus(
              child: IgnorePointer(child: task.builder(context)),
            ),
          ),
        ],
      ),
    );
  }

  /// 底部批量操作栏。动作按钮按「选中集里有几条真支持它」决定可用态。
  ///
  /// [rendered] 必须是屏幕上真正渲染出来的行（rows 里的 entry），不是筛选后的
  /// 全集——分组折叠时被收起来的成员不该被「全选」卷进来。
  Widget _buildBatchBar(List<DownloadTaskEntry> rendered) {
    final List<DownloadTaskEntry> selected = _selectedVisible(rendered);
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
          !_batchRunning &&
          countDownloadTasksSupporting(selected, batchAction) > 0;
      return FushiIconButton(
        key: ValueKey<String>('download-batch-$id'),
        enabled: enabled,
        tooltip: tooltip,
        icon: icon,
        enabledColor: enabledColor,
        onTap: onTap ??
            () => unawaited(
                  _runBatchOn(
                    List<DownloadTaskEntry>.of(selected),
                    batchAction,
                  ),
                ),
      );
    }

    return BatchActionBar(
      selectedCount: selected.length,
      onSelectAll: () => setState(
        () => _selectedIds.addAll(
          rendered.map((DownloadTaskEntry task) => task.id),
        ),
      ),
      onInvertSelection: () => setState(() {
        final Set<String> next = <String>{
          for (final DownloadTaskEntry task in rendered)
            if (!_selectedIds.contains(task.id)) task.id,
        };
        _selectedIds
          ..clear()
          ..addAll(next);
      }),
      actions: <Widget>[
        action(
          id: 'resume',
          icon: FushiIcons.play,
          tooltip: t.download_task_resume,
          batchAction: DownloadBatchAction.resume,
        ),
        action(
          id: 'pause',
          icon: FushiIcons.pause,
          tooltip: t.download_task_pause,
          batchAction: DownloadBatchAction.pause,
        ),
        action(
          id: 'retry',
          icon: FushiIcons.refresh,
          tooltip: t.retry,
          batchAction: DownloadBatchAction.retry,
        ),
        action(
          id: 'cancel',
          icon: FushiIcons.close,
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
          icon: FushiIcons.delete,
          tooltip: t.download_task_delete,
          batchAction: DownloadBatchAction.delete,
          enabledColor: theme.colorScheme.error,
          onTap: () => unawaited(_confirmBatchDelete(rendered)),
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
    // M3E 工具胶囊：surfaceContainerHigh 全圆头，与搜索框同一层级。
    child: _ToolPill(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiIcon(icon, size: 18),
          const SizedBox(width: 6),
          Flexible(
            child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
          const FushiIcon(FushiIcons.dropDown, size: 18),
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

  /// 「全部暂停 / 全部继续」：对**全部**任务（不只当前筛选）执行，走与多选批量
  /// 同一个串行执行器——逐条 fire-and-forget 会把几十条暂停变成并发打同一后端。
  VoidCallback? _allAction(DownloadBatchAction action) {
    if (_batchRunning ||
        countDownloadTasksSupporting(widget.tasks, action) == 0) {
      return null;
    }
    return () => unawaited(
      _runBatchOn(List<DownloadTaskEntry>.of(widget.tasks), action),
    );
  }

  Widget _buildStatusFilter() => FushiSegmentedStrip<DownloadTaskStatusFilter>(
    key: const ValueKey<String>('download-task-status-filter'),
    segments: <ButtonSegment<DownloadTaskStatusFilter>>[
      for (final DownloadTaskStatusFilter filter
          in DownloadTaskStatusFilter.values)
        ButtonSegment<DownloadTaskStatusFilter>(
          value: filter,
          label: Text(downloadTaskStatusFilterLabel(filter)),
        ),
    ],
    selected: _statusFilter,
    onChanged: (DownloadTaskStatusFilter value) =>
        setState(() => _statusFilter = value),
  );

  Widget _buildTools(List<DownloadTaskEntry> visible) => Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 4,
    runSpacing: 4,
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
          () => _kind = value < 0 ? null : DownloadTaskKind.values[value],
        ),
        icon: FushiIcons.filterList,
      ),
      _menu<DownloadTaskSort>(
        id: 'download-task-sort',
        label: _sortLabel(_sort),
        selected: _sort,
        values: DownloadTaskSort.values,
        labelOf: _sortLabel,
        onSelected: (DownloadTaskSort value) => setState(() => _sort = value),
        icon: FushiIcons.sort,
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
        icon: FushiIcons.collection,
      ),
      FushiIconButton(
        key: const ValueKey<String>('download-task-select-mode'),
        tooltip: _selectionMode ? t.dialog_cancel : t.batch_select,
        icon: _selectionMode ? FushiIcons.close : FushiIcons.checklist,
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
          icon: _collapseAll ? FushiIcons.expandMore : FushiIcons.expandLess,
          onTap: () => setState(() {
            _collapseAll = !_collapseAll;
            _expandedGroups.clear();
          }),
        ),
      // 这两个「对可见集合全体执行」的入口与多选批量走同一个串行执行器：
      // 逐条 fire-and-forget 会把 40 条重试变成 40 路并发打向同一后端，
      // 且任何一条抛错都是没人接的 async 异常。
      if (visible.any((DownloadTaskEntry task) => task.actions.retry != null))
        FushiTextButton(
          key: const ValueKey<String>('download-task-retry-visible'),
          onPressed: _batchRunning
              ? null
              : () => unawaited(
                  _runBatchOn(
                    List<DownloadTaskEntry>.of(visible),
                    DownloadBatchAction.retry,
                  ),
                ),
          child: Text(t.retry),
        ),
      if (visible.any((DownloadTaskEntry task) => task.actions.clear != null))
        FushiTextButton(
          key: const ValueKey<String>('download-task-clear-visible'),
          onPressed: _batchRunning
              ? null
              : () => unawaited(
                  _runBatchOn(
                    List<DownloadTaskEntry>.of(visible),
                    DownloadBatchAction.clear,
                  ),
                ),
          child: Text(t.download_clear_finished),
        ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          '${visible.length} / ${widget.tasks.length}',
          style: context.fushiType.labelMedium.tabular.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    ],
  );

  /// 汇总 + 筛选（窄屏在列表顶上随列表滚动；宽屏是右侧窗格）。
  Widget _buildControls(List<DownloadTaskEntry> visible) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (widget.tasks.isNotEmpty && !widget.loading) ...<Widget>[
          DownloadSummaryHero(
            tasks: widget.tasks,
            executionDeviceLabel: widget.executionDeviceLabel,
            onOpenExecutionSettings: widget.onOpenExecutionSettings,
            onPauseAll: _allAction(DownloadBatchAction.pause),
            onResumeAll: _allAction(DownloadBatchAction.resume),
          ),
          SizedBox(height: tokens.spacing.gap + 4),
        ],
        _buildStatusFilter(),
        SizedBox(height: tokens.spacing.gap),
        FushiSearchBar(
          fieldKey: const ValueKey<String>('download-task-search'),
          controller: _search,
          focusNode: _searchFocus,
          hintText: t.download_task_search_hint,
          onQueryChanged: (_) => setState(() {}),
          onSubmitted: (_) => setState(() {}),
          onClear: () => setState(() {}),
        ),
        SizedBox(height: tokens.spacing.gap / 2),
        _buildTools(visible),
      ],
    );
  }

  Widget _buildGroupHeader(MapEntry<String, List<DownloadTaskEntry>> group) {
    final String key = '${_grouping.name}:${group.key}';
    final bool expanded = _expandedGroups[key] ?? !_collapseAll;
    final int completed = group.value
        .where(
          (DownloadTaskEntry task) =>
              task.status == DownloadTaskStatus.completed,
        )
        .length;
    // 组折叠后成员卡片连同各自的进度条一起消失，只剩「已完成 / 总数」这个整数
    // 计数——一组十集全在下载中时它恒为 0 / 10，看不出到底跑到哪了。所以组头
    // 自己带一份整体进度。
    final double groupProgress = downloadGroupProgress(group.value);
    final FushiMotionScheme motion = context.fushiMotion;
    return Semantics(
      expanded: expanded,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            FushiListItem(
              key: ValueKey<String>('download-group-$key'),
              leading: AnimatedRotation(
                turns: expanded ? 0 : -0.25,
                duration: motion.spatialFast.duration,
                curve: motion.spatialFast.curve,
                child: const FushiIcon(FushiIcons.expandMore),
              ),
              title: Text(
                _groupTitle(group.value.first),
                style: context.fushiType.titleSmallEmphasized,
              ),
              titleMaxLines: 2,
              // 百分比刻意放在第二行而不是并进 trailing：360px + 文字放大 2.0
              // 下，trailing 只放得下「已完成 / 总数」，再接一段就把整行撑溢出。
              subtitle: Text('${(groupProgress * 100).round()}%'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    '$completed / ${group.value.length}',
                    style: context.fushiType.labelLarge.tabular,
                  ),
                  // 整组删除：目标是这一组的全部成员（含折叠着的）——组头就是
                  // 这一组本身，确认框会写明条数。
                  if (!_selectionMode &&
                      countDownloadTasksSupporting(
                            group.value,
                            DownloadBatchAction.delete,
                          ) >
                          0)
                    FushiIconButton(
                      key: ValueKey<String>('download-group-delete-$key'),
                      enabled: !_batchRunning,
                      tooltip: t.download_task_group_delete,
                      icon: FushiIcons.delete,
                      onTap: () => unawaited(
                        // 只交可删的成员：确认框里的 N 必须等于真会删掉的条数。
                        _confirmDelete(
                          group.value
                              .where(
                                (DownloadTaskEntry task) =>
                                    downloadTaskBatchCallable(
                                      task,
                                      DownloadBatchAction.delete,
                                    ) !=
                                    null,
                              )
                              .toList(),
                        ),
                      ),
                    ),
                ],
              ),
              onTap: () => setState(() => _expandedGroups[key] = !expanded),
            ),
            if (!expanded && groupProgress < 1)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: FushiLinearProgressIndicator(
                  key: ValueKey<String>('download-group-progress-$key'),
                  value: groupProgress,
                  minHeight: 2,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSkeleton() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiSkeletonShimmer(
      child: Column(
        key: const ValueKey<String>('download-task-skeleton'),
        children: <Widget>[
          for (int i = 0; i < 4; i++)
            Padding(
              padding: EdgeInsets.only(bottom: tokens.spacing.gap),
              child: FushiCard(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: <Widget>[
                    const FushiSkeleton(width: 40, height: 40),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          FushiSkeleton.line(widthFactor: 0.7, height: 14),
                          const SizedBox(height: 8),
                          FushiSkeleton.line(widthFactor: 0.4),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    final bool none = widget.tasks.isEmpty;
    return Center(
      child: FushiPlaceholderMessage(
        icon: none ? FushiIcons.downloading : FushiIcons.searchOff,
        message: none ? t.anime_download_no_tasks : t.download_task_no_match,
        action: none && widget.onAddTask != null
            ? FushiFilledButton.tonalIcon(
                key: const ValueKey<String>('download-task-empty-add'),
                onPressed: widget.onAddTask,
                icon: const FushiIcon(FushiIcons.add),
                label: Text(t.download_task_add),
              )
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<DownloadTaskEntry> visible = selectDownloadTasks(
      widget.tasks,
      query: _search.text,
      kind: _kind,
      sort: _sort,
      reverse: _reverse,
    ).where(
      (DownloadTaskEntry task) =>
          downloadTaskMatchesStatusFilter(task, _statusFilter),
    ).toList();
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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double page = tokens.spacing.page;
    final bool showFab = widget.onAddTask != null && !_selectionMode;

    Widget rowAt(BuildContext context, int index) {
      final Object row = rows[index];
      if (row is DownloadTaskEntry) {
        return FushiStaggeredEntrance(
          key: ValueKey<String>('download-entry-${row.id}'),
          index: index,
          child: Padding(
            padding: EdgeInsets.only(bottom: tokens.spacing.gap),
            child: _selectionMode ? _selectableRow(row) : row.builder(context),
          ),
        );
      }
      return FushiStaggeredEntrance(
        index: index,
        child: _buildGroupHeader(
          row as MapEntry<String, List<DownloadTaskEntry>>,
        ),
      );
    }

    final Widget body = widget.loading
        ? SliverToBoxAdapter(child: _buildSkeleton())
        : rows.isEmpty
        ? SliverFillRemaining(hasScrollBody: false, child: _buildEmpty())
        : SliverList.builder(
            findChildIndexCallback: (Key key) {
              final int index = rows.indexWhere(
                (Object row) =>
                    row is DownloadTaskEntry &&
                    key == ValueKey<String>('download-entry-${row.id}'),
              );
              return index < 0 ? null : index;
            },
            itemCount: rows.length,
            itemBuilder: rowAt,
          );

    // 叠放的浮动头部（浏览页一二级页签行）让出的高度：主滚动视图自己在顶部
    // 占位，内容滚到头部之下（BUG-2975）；不在浮动头部下时为 0。
    final double chromeInset = FushiFloatingChromeInset.of(context);

    Widget scroller({required bool withControls}) => FushiEntranceScope(
      replayKey: _statusFilter,
      child: CustomScrollView(
        key: const PageStorageKey<String>('download-task-list'),
        slivers: <Widget>[
          SliverToBoxAdapter(child: SizedBox(height: chromeInset)),
          if (widget.header != null)
            SliverPadding(
              // 横幅自带上边距、无内容时零高度：这里只给页边。
              padding: EdgeInsets.symmetric(horizontal: page),
              sliver: SliverToBoxAdapter(child: widget.header),
            ),
          if (withControls)
            SliverPadding(
              padding: EdgeInsets.fromLTRB(page, tokens.spacing.gap, page, 4),
              sliver: SliverToBoxAdapter(child: _buildControls(visible)),
            ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              page,
              withControls ? 4 : tokens.spacing.gap,
              page,
              showFab ? 96 : 24,
            ),
            sliver: body,
          ),
        ],
      ),
    );

    Widget withFab(Widget child) => Stack(
      children: <Widget>[
        Positioned.fill(child: child),
        if (showFab)
          PositionedDirectional(
            end: page,
            bottom: page,
            child: FushiFab(
              key: const ValueKey<String>('download-task-add-fab'),
              heroTag: null,
              tooltip: t.download_task_add,
              icon: const FushiIcon(FushiIcons.add),
              label: Text(t.download_task_add),
              onPressed: widget.onAddTask,
            ),
          ),
      ],
    );

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide =
            constraints.maxWidth >= kDownloadBrowserWideBreakpoint;
        final Widget main = wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(child: withFab(scroller(withControls: false))),
                  // 右侧窗格：汇总 hero + 状态分段 + 搜索 + 工具，独立滚动。
                  SizedBox(
                    width: 360,
                    child: SingleChildScrollView(
                      key: const ValueKey<String>('download-task-side-pane'),
                      padding: EdgeInsets.fromLTRB(
                        0,
                        chromeInset + tokens.spacing.gap,
                        page,
                        page,
                      ),
                      child: _buildControls(visible),
                    ),
                  ),
                ],
              )
            : withFab(scroller(withControls: true));
        return Column(
          children: <Widget>[
            Expanded(child: main),
            if (_selectionMode)
              _buildBatchBar(rows.whereType<DownloadTaskEntry>().toList()),
          ],
        );
      },
    );
  }
}

/// 工具胶囊外观（菜单触发器的可视面）。
class _ToolPill extends StatelessWidget {
  const _ToolPill({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isGlassDesign(context)
            ? appleColorsOf(context).fill
            : cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(999),
      ),
      child: child,
    );
  }
}

/// 下载页顶部汇总 hero：总速度（↓ Display 大号等宽数字 / ↑ 次级）、活动 /
/// 排队 / 完成计数 chip、执行设备 chip（本机 / 互联主机，点按去下载设置）、
/// 全部暂停 / 全部继续按钮组。M3E 是 primaryContainer 饱和色块，Apple 是强调色
/// 淡染卡。速度只计报得出实时指标的来源（torrent），其余来源不计入。
class DownloadSummaryHero extends StatelessWidget {
  const DownloadSummaryHero({
    required this.tasks,
    super.key,
    this.executionDeviceLabel,
    this.onOpenExecutionSettings,
    this.onPauseAll,
    this.onResumeAll,
  });

  final List<DownloadTaskEntry> tasks;
  final String? executionDeviceLabel;
  final VoidCallback? onOpenExecutionSettings;
  final VoidCallback? onPauseAll;
  final VoidCallback? onResumeAll;

  @override
  Widget build(BuildContext context) {
    int down = 0;
    int up = 0;
    int active = 0;
    int queued = 0;
    int completed = 0;
    for (final DownloadTaskEntry task in tasks) {
      down += task.downRateBps ?? 0;
      up += task.upRateBps ?? 0;
      switch (task.status) {
        case DownloadTaskStatus.active:
          active++;
        case DownloadTaskStatus.queued:
          queued++;
        case DownloadTaskStatus.completed:
          completed++;
        case DownloadTaskStatus.attention:
        case DownloadTaskStatus.paused:
        case DownloadTaskStatus.cancelled:
          break;
      }
    }
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color onContainer =
        fushiCardToneColors(context, FushiCardTone.primary)?.onContainer ??
        cs.onSurface;
    final FushiTypography type = context.fushiType;
    final String? device = executionDeviceLabel;
    return FushiCard(
      key: const ValueKey<String>('download-summary-hero'),
      tone: FushiCardTone.primary,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            t.download_summary_speed_title,
            style: type.labelLarge.copyWith(color: onContainer),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 20,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: <Widget>[
              _SpeedFigure(
                key: const ValueKey<String>('download-summary-down'),
                icon: FushiIcons.download,
                value: FushiByteFormat.speed(down.toDouble()),
                style: type.displaySmallEmphasized.tabular.copyWith(
                  color: onContainer,
                ),
              ),
              _SpeedFigure(
                key: const ValueKey<String>('download-summary-up'),
                icon: FushiIcons.upload,
                value: FushiByteFormat.speed(up.toDouble()),
                style: type.titleLargeEmphasized.tabular.copyWith(
                  color: onContainer,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              _HeroChip(
                icon: FushiIcons.downloading,
                label: t.download_summary_active(n: active),
              ),
              _HeroChip(
                icon: FushiIcons.pending,
                label: t.download_summary_queued(n: queued),
              ),
              _HeroChip(
                icon: FushiIcons.downloadDone,
                label: t.download_summary_completed(n: completed),
              ),
              _HeroChip(
                key: const ValueKey<String>('download-summary-execution'),
                icon: device != null ? FushiIcons.hub : FushiIcons.devices,
                label: device != null
                    ? t.download_target_remote(device: device)
                    : t.download_target_local,
                tooltip: t.download_target_label,
                onTap: onOpenExecutionSettings,
              ),
            ],
          ),
          if (onPauseAll != null || onResumeAll != null) ...<Widget>[
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final List<Widget> buttons = <Widget>[
                  FushiFilledButton.icon(
                    key: const ValueKey<String>('download-summary-pause-all'),
                    onPressed: onPauseAll,
                    icon: const FushiIcon(FushiIcons.pause),
                    label: Text(t.download_pause_all),
                  ),
                  FushiFilledButton.tonalIcon(
                    key: const ValueKey<String>('download-summary-resume-all'),
                    onPressed: onResumeAll,
                    icon: const FushiIcon(FushiIcons.play),
                    label: Text(t.download_resume_all),
                  ),
                ];
                // 够宽时是 M3E 按钮组（按下变宽挤压邻居）；窄屏 / 大字号换行。
                final bool roomy =
                    constraints.maxWidth >= 360 &&
                    MediaQuery.textScalerOf(context).scale(1) <= 1.3;
                return roomy
                    ? FushiButtonGroup(children: buttons)
                    : Wrap(spacing: 8, runSpacing: 8, children: buttons);
              },
            ),
          ],
        ],
      ),
    );
  }
}

class _SpeedFigure extends StatelessWidget {
  const _SpeedFigure({
    required this.icon,
    required this.value,
    required this.style,
    super.key,
  });

  final IconData icon;
  final String value;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final double iconSize = (style.fontSize ?? 24) * 0.7;
    // 大字号窄屏下整枚等比缩小，不撑破卡片。
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: AlignmentDirectional.centerStart,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiIcon(icon, size: iconSize, color: style.color),
          const SizedBox(width: 4),
          Text(value, maxLines: 1, style: style),
        ],
      ),
    );
  }
}

class _HeroChip extends StatelessWidget {
  const _HeroChip({
    required this.icon,
    required this.label,
    super.key,
    this.tooltip,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String? tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool glass = isGlassDesign(context);
    final Color background = glass ? appleColorsOf(context).fill : cs.surface;
    final Color foreground = glass
        ? appleColorsOf(context).label
        : cs.onSurface;
    const BorderRadius radius = FushiM3eShape.smallRadius;
    Widget chip = Material(
      color: background,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FushiIcon(icon, size: 16, color: foreground),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.fushiType.labelLarge.tabular.copyWith(
                    color: foreground,
                  ),
                ),
              ),
              if (onTap != null) ...<Widget>[
                const SizedBox(width: 2),
                FushiIcon(FushiIcons.chevronRight, size: 16, color: foreground),
              ],
            ],
          ),
        ),
      ),
    );
    if (onTap != null) chip = FushiPressScale(child: chip);
    if (tooltip != null) chip = FushiTooltip(message: tooltip, child: chip);
    return chip;
  }
}
