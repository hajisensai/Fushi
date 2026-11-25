import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/sync/background_task.dart';
import 'package:fushi/src/sync/auto_backup/auto_backup_progress.dart';
import 'package:fushi/src/srs/srs_sync_progress.dart';
import 'package:fushi/src/srs/srs_sync_progress_ui.dart';
import 'package:fushi/src/sync/manual_sync_ui.dart';
import 'package:fushi/src/sync/sync_activity.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_progress.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi_engine/sync/sync_backend_type.dart';
import 'package:fushi_engine/sync/sync_channel_scope.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';

export 'package:fushi/src/sync/background_task.dart';
export 'package:fushi/src/sync/sync_background_activity.dart'
    show
        hasActiveSyncTasks,
        hasUnseenSyncFailures,
        syncBackgroundTasksListenable;
export 'package:fushi/src/sync/sync_task_board.dart'
    show acknowledgeFinishedSyncTasks;

/// 首页外壳的「后台任务」入口（2026-11-03 顶栏让位）：常规同步、复习同步 / 旧文件
/// 迁移、视频源补刮共用右下（MD3 手机叠在悬浮底栏 FAB 上方、Apple 进大标题行）的
/// 一颗按钮，按钮外圈是 [FushiSegmentedProgressRing]——一项任务一段弧，看一眼
/// 就知道跑了几项、各到哪；悬停 / 长按出每项一行的文字，点开是明细弹层。
///
/// 此前同步进度是每个库页列表上方的两行横幅（文字 + 4dp 波浪条，两项并存时
/// 约 56dp），后台同步跑十几分钟就一直挤掉近一行封面；补刮入口则只有一枚图标、
/// 看不到进度。两者在这里合并。

/// 条目种类的图标（书 / 视频 / 有声书 / 词典 / 本地音频 / 字体）；不知道是哪种时用
/// 同步图标。
IconData syncItemKindIcon(SyncItemKind? kind) => switch (kind) {
  SyncItemKind.book => FushiIcons.books,
  SyncItemKind.video => FushiIcons.video,
  SyncItemKind.audiobook => FushiIcons.audiobook,
  SyncItemKind.dictionary => FushiIcons.dictionary,
  SyncItemKind.localAudio => FushiIcons.music,
  SyncItemKind.font => FushiIcons.font,
  null => FushiIcons.sync,
};

/// 一轮同步的种类名（「等待全量同步」里的那个词）。
String syncActivityKindLabel(SyncActivityKind kind) => switch (kind) {
  SyncActivityKind.fullSweep => t.sync_task_kind_full_sweep,
  SyncActivityKind.collections => t.sync_task_kind_collections,
  SyncActivityKind.singleBook => t.sync_task_kind_single_book,
  SyncActivityKind.assetTransfer => t.sync_task_kind_asset_transfer,
};

/// 明细第二行：通道 · 在等谁 / 结束了。都没有时为 null。
String? syncTaskDetailLine(SyncTask task) {
  final SyncChannelScope? channel = task.channel;
  final String? channelLabel = channel == null
      ? null
      : (channel == SyncChannelScope.forBackendType(SyncBackendType.fushiServer)
            ? t.sync_task_channel_interconnect
            : t.sync_task_channel_cloud);
  final String? state;
  if (!task.isActive) {
    state = t.sync_task_finished_with_errors(count: task.errors.length);
  } else if (task.isWaiting) {
    final SyncActivityKind? blocker = task.waitingOn.firstWhere(
      (SyncActivityKind? k) => k != null,
      orElse: () => null,
    );
    state = blocker == null
        ? t.sync_task_waiting_other
        : t.sync_task_waiting_for(what: syncActivityKindLabel(blocker));
  } else {
    state = null;
  }
  final List<String> parts = <String>[?channelLabel, ?state];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// 任务表里的一轮同步 → 入口 / 明细的一项。
BackgroundTask syncTaskToBackgroundTask(SyncTask task) {
  // BUG-5368：已结束的一轮不再沿用最后一个进度阶段——失败项写着「正在读取远端文件
  // 清单」是在撒谎。结束了就说这轮是谁（全量同步 / 合集 / 单本），结局在第二行
  // （「已结束，N 项失败」）与错误列表里。
  final SyncProgress? p = task.isActive ? task.progress : null;
  return BackgroundTask(
    id: 'sync-${task.id}',
    icon: syncItemKindIcon(p?.itemKind),
    // 两级取值（BUG-1260）：在跑且有阶段 tick 用它，否则说清这轮同步是谁。
    line: p != null
        ? syncProgressLine(p)
        : syncActivityLine(SyncActivity(task.kind, title: task.title)),
    fraction: p?.fraction,
    detail: syncTaskDetailLine(task),
    stageSince: task.isActive ? task.stageSince : null,
    errors: <String>[for (final SyncTaskError e in task.errors) e.message],
    finished: !task.isActive,
  );
}

/// 此刻的同步类任务：常规同步**每一轮一项**（按资源加锁后全量 sweep 与退出书的单本
/// 同步可能同时在跑，各自一段弧），复习同步一项。
/// 复习同步不经任务表（「立即同步」/ 进复习 tab 也会单独触发），所以单独成项。
/// 已结束但有失败的那几轮排在最后，只在明细里显示。
List<BackgroundTask> syncBackgroundTasks() {
  final SrsSyncProgress? srs = srsSyncProgress.value;
  final List<SyncTask> all = syncTasks.value;
  return <BackgroundTask>[
    for (final SyncTask task in all)
      if (task.isActive) syncTaskToBackgroundTask(task),
    if (srs != null)
      BackgroundTask(
        id: 'srs',
        icon: FushiIcons.cloudSync,
        line: srsSyncProgressLine(srs),
        fraction: srsSyncProgressFraction(srs),
      ),
    if (autoBackupProgress.value case final AutoBackupProgress backup)
      BackgroundTask(
        id: 'auto-backup',
        icon: FushiIcons.backup,
        line: t.auto_backup_task_running,
        fraction: backup.fraction,
      ),
    for (final SyncTask task in all)
      if (!task.isActive) syncTaskToBackgroundTask(task),
  ];
}

/// 入口（进度环 / 气泡）只看还在跑的任务。
List<BackgroundTask> activeBackgroundTasks(List<BackgroundTask> tasks) =>
    <BackgroundTask>[
      for (final BackgroundTask task in tasks)
        if (!task.finished) task,
    ];

/// 入口按钮中心的图标：只有一项时用它自己的，多项时统一用同步图标。
IconData backgroundTasksIcon(List<BackgroundTask> tasks) {
  final List<BackgroundTask> active = activeBackgroundTasks(tasks);
  return active.length == 1 ? active.single.icon : FushiIcons.sync;
}

/// 悬停 / 长按气泡：每项一行（已结束的不列）。
String backgroundTasksTooltip(List<BackgroundTask> tasks) =>
    activeBackgroundTasks(
      tasks,
    ).map((BackgroundTask task) => task.line).join('\n');

/// 分段进度环 + 中心图标；[tasks] 为空时画空盒（尺寸不变，宿主自己决定显隐）。
class BackgroundTasksGlyph extends StatelessWidget {
  const BackgroundTasksGlyph({
    required this.tasks,
    this.size = 40,
    this.iconSize = 20,
    this.strokeWidth = 3,
    this.color,
    this.showIcon = true,
    super.key,
  });

  final List<BackgroundTask> tasks;
  final double size;
  final double iconSize;
  final double strokeWidth;

  /// false = 只画环（宿主是自带图标的按钮，环叠在它外圈）。
  final bool showIcon;

  /// 图标与进度弧颜色；null = 宿主 [IconTheme] 的颜色。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool eink = isEinkTheme(context);
    final Color fg =
        color ?? IconTheme.of(context).color ?? theme.colorScheme.primary;
    final Color track = eink
        ? theme.colorScheme.outlineVariant
        : fg.withValues(alpha: fg.a * 0.24);
    return SizedBox.square(
      dimension: size,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          if (activeBackgroundTasks(tasks).isNotEmpty)
            FushiSegmentedProgressRing(
              key: const ValueKey<String>('background-tasks-ring'),
              size: size,
              strokeWidth: strokeWidth,
              // 墨水屏不跑不定态的往返动画：钉成 0，留一段静止的空轨道。
              values: <double?>[
                for (final BackgroundTask task in activeBackgroundTasks(tasks))
                  einkSafeProgressValue(context, task.fraction),
              ],
              colors: <Color>[
                for (final BackgroundTask _ in activeBackgroundTasks(tasks)) fg,
              ],
              trackColor: track,
            ),
          if (showIcon)
            FushiIcon(backgroundTasksIcon(tasks), size: iconSize, color: fg),
          // 有一轮记下了失败（在跑或已结束、用户还没打开明细看过）：右上角红点，
          // 一直提醒到用户打开明细（确认见 acknowledgeFinishedSyncTasks）。只画环
          // （[showIcon] = false，Apple 导航栏 bar button 外圈）时也画：入口在那里
          // 同样因「未看过的失败」常驻，没有红点就看不出它为什么还在。
          if (tasks.any((BackgroundTask t) => t.errors.isNotEmpty))
            PositionedDirectional(
              top: 0,
              end: 0,
              child: DecoratedBox(
                key: const ValueKey<String>('background-tasks-error-dot'),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.error,
                  border: Border.all(
                    color: theme.colorScheme.surface,
                    width: 2,
                  ),
                ),
                child: SizedBox.square(dimension: size * 0.24),
              ),
            ),
        ],
      ),
    );
  }
}

/// 后台任务明细弹层：每项一行（图标 + 文字 + 进度条 + 可选动作），随数据实时刷新；
/// 全部跑完时显示空态，不自动关（用户正在看）。
Future<void> showBackgroundTasksSheet({
  required BuildContext context,
  required Listenable listenable,
  required List<BackgroundTask> Function() tasks,
}) {
  return adaptiveModalSheet<void>(
    context: context,
    builder: (BuildContext sheetContext) => FushiModalSheetFrame(
      title: t.video_source_scrape_tasks_open,
      leadingIcon: FushiIcons.sync,
      scrollable: true,
      // 框架的 body 默认零内边距：不给的话任务行贴着弹层左右边缘、进度条画出圆角、
      // 末行压着底边（对话框与底部 sheet 都是）。左右与 MD3 标题同 24；行自带上下 8，底部再加 16。
      bodyPadding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      body: ListenableBuilder(
        listenable: listenable,
        builder: (BuildContext context, _) {
          final List<BackgroundTask> current = tasks();
          if (current.isEmpty) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                t.background_tasks_empty,
                key: const ValueKey<String>('background-tasks-empty'),
                style: context.fushiType.bodyMedium.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            );
          }
          // 任务行错峰进场；数据刷新时已挂载的行不重播（进场窗口只开一次）。
          return FushiEntranceScope(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final (int i, BackgroundTask task) in current.indexed)
                  FushiStaggeredEntrance(
                    key: ValueKey<String>('background-task-${task.id}'),
                    index: i,
                    child: _BackgroundTaskRow(
                      task: task,
                      onOpen: task.onOpen == null
                          ? null
                          : () {
                              Navigator.of(sheetContext).pop();
                              task.onOpen!();
                            },
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    ),
  );
}

/// 毫秒时长 → `m:ss`（满一小时 `h:mm:ss`）。
String formatSyncStageElapsed(int ms) {
  final int totalSeconds = (ms < 0 ? 0 : ms) ~/ 1000;
  final int h = totalSeconds ~/ 3600;
  final int m = (totalSeconds % 3600) ~/ 60;
  final String s = (totalSeconds % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

class _BackgroundTaskRow extends StatefulWidget {
  const _BackgroundTaskRow({required this.task, this.onOpen});

  final BackgroundTask task;
  final VoidCallback? onOpen;

  @override
  State<_BackgroundTaskRow> createState() => _BackgroundTaskRowState();
}

class _BackgroundTaskRowState extends State<_BackgroundTaskRow> {
  /// 「这一步已多久」每秒走一格；没有起点（复习同步、补刮、已结束）时不开计时器。
  Timer? _clock;
  bool _errorsExpanded = false;

  @override
  void initState() {
    super.initState();
    _syncClock();
  }

  @override
  void didUpdateWidget(covariant _BackgroundTaskRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncClock();
  }

  void _syncClock() {
    if (widget.task.stageSince == null) {
      _clock?.cancel();
      _clock = null;
    } else {
      _clock ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool eink = isEinkTheme(context);
    final BackgroundTask task = widget.task;
    final VoidCallback? onOpen = widget.onOpen;
    final String? openLabel = task.openLabel;
    final int? stageSince = task.stageSince;
    final String? detail = <String>[
      ?task.detail,
      if (stageSince != null)
        t.sync_task_stage_elapsed(
          elapsed: formatSyncStageElapsed(
            DateTime.now().millisecondsSinceEpoch - stageSince,
          ),
        ),
    ].join(' · ').nullIfEmpty;
    final TextStyle secondary = context.fushiType.bodySmall.tabular.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              FushiIcon(
                task.icon,
                size: 20,
                color: task.finished
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      task.line,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: context.fushiType.bodyMedium.tabular,
                    ),
                    if (detail != null) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(
                        detail,
                        key: ValueKey<String>(
                          'background-task-detail-${task.id}',
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: secondary,
                      ),
                    ],
                    if (!task.finished) ...<Widget>[
                      const SizedBox(height: 6),
                      FushiLinearProgressIndicator(
                        value: einkSafeProgressValue(context, task.fraction),
                        backgroundColor: eink
                            ? theme.colorScheme.surface
                            : null,
                      ),
                    ],
                  ],
                ),
              ),
              if (onOpen != null && openLabel != null) ...<Widget>[
                const SizedBox(width: 12),
                FushiFilledButton.tonal(
                  onPressed: onOpen,
                  child: Text(openLabel),
                ),
              ],
            ],
          ),
          if (task.errors.isNotEmpty) _buildErrors(context, task),
        ],
      ),
    );
  }

  /// 失败清单：一枚「N 项失败」开关（命中区 ≥48dp），展开后每项一行。
  Widget _buildErrors(BuildContext context, BackgroundTask task) {
    final ThemeData theme = Theme.of(context);
    final FushiMotionScheme motion = context.fushiMotion;
    final String label = t.sync_task_errors_count(count: task.errors.length);
    return FushiAnimatedSize(
      duration: fushiMotionDuration(context, FushiMotion.medium),
      curve: motion.spatialDefault.curve,
      alignment: Alignment.topCenter,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FushiPressScale(
              child: Semantics(
                button: true,
                expanded: _errorsExpanded,
                child: InkWell(
                  key: ValueKey<String>('background-task-errors-${task.id}'),
                  borderRadius: FushiM3eShape.smallRadius,
                  onTap: () =>
                      setState(() => _errorsExpanded = !_errorsExpanded),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(
                        start: 32,
                        end: 8,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          FushiIcon(
                            FushiIcons.warning,
                            size: 16,
                            color: theme.colorScheme.error,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            label,
                            style: context.fushiType.labelLarge.copyWith(
                              color: theme.colorScheme.error,
                            ),
                          ),
                          const SizedBox(width: 4),
                          FushiIcon(
                            _errorsExpanded
                                ? FushiIcons.expandLess
                                : FushiIcons.expandMore,
                            size: 18,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_errorsExpanded)
            FushiEntranceScope(
              child: Column(
                key: ValueKey<String>('background-task-error-list-${task.id}'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (final (int i, String error) in task.errors.indexed)
                    FushiStaggeredEntrance(
                      index: i,
                      child: Padding(
                        padding: const EdgeInsetsDirectional.only(
                          start: 32,
                          bottom: 4,
                        ),
                        child: SelectableText(
                          error,
                          style: context.fushiType.bodySmall.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}
