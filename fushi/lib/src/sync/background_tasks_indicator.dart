import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/srs/srs_sync_progress.dart';
import 'package:fushi/src/srs/srs_sync_progress_ui.dart';
import 'package:fushi/src/sync/manual_sync_ui.dart';
import 'package:fushi/src/sync/sync_activity.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_progress.dart';
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';

/// 首页外壳的「后台任务」入口（2026-11-03 顶栏让位）：常规同步、复习同步 / 旧文件
/// 迁移、视频源补刮共用右下（MD3 手机叠在悬浮底栏 FAB 上方、Apple 进大标题行）的
/// 一颗按钮，按钮外圈是 [FushiSegmentedProgressRing]——一项任务一段弧，看一眼
/// 就知道跑了几项、各到哪；悬停 / 长按出每项一行的文字，点开是明细弹层。
///
/// 此前同步进度是每个库页列表上方的两行横幅（文字 + 4dp 波浪条，两项并存时
/// 约 56dp），后台同步跑十几分钟就一直挤掉近一行封面；补刮入口则只有一枚图标、
/// 看不到进度。两者在这里合并。

/// 一项正在后台跑的任务（给入口与明细弹层看的那一层）。
@immutable
class BackgroundTask {
  const BackgroundTask({
    required this.id,
    required this.icon,
    required this.line,
    this.fraction,
    this.onOpen,
    this.openLabel,
  });

  /// 稳定标识（明细行的 key）。
  final String id;
  final IconData icon;

  /// 一行描述，如「同步阅读数据 (27/36) 书名」。
  final String line;

  /// 0..1；null = 没有可测总数（不定态）。
  final double? fraction;

  /// 明细行尾的「去处理」动作（补刮任务面板）；null = 只展示。
  final VoidCallback? onOpen;
  final String? openLabel;

  @override
  bool operator ==(Object other) =>
      other is BackgroundTask &&
      other.id == id &&
      other.icon == icon &&
      other.line == line &&
      other.fraction == fraction &&
      other.openLabel == openLabel;

  @override
  int get hashCode => Object.hash(id, icon, line, fraction, openLabel);
}

/// 同步类任务的全部数据源；入口与明细都听它。
final Listenable syncBackgroundTasksListenable = Listenable.merge(<Listenable>[
  syncInProgress,
  syncProgress,
  syncActivity,
  srsSyncProgress,
  srsMigrationProgress,
]);

/// 有没有同步类任务在跑（外壳只在这一位翻转时重建）。
bool hasActiveSyncTasks() =>
    syncInProgress.value ||
    srsSyncProgress.value != null ||
    srsMigrationProgress.value != null;

/// 此刻在跑的同步类任务：常规同步一项、复习同步（没有一轮在跑时是旧文件迁移）
/// 一项。复习同步不经 [syncInProgress]（「立即同步」/ 进复习 tab 也会单独触发），
/// 所以两项分开、并存时各占一段弧。
List<BackgroundTask> syncBackgroundTasks() {
  final SyncProgress? p = syncProgress.value;
  final SyncActivity? activity = syncActivity.value;
  final SrsSyncProgress? srs = srsSyncProgress.value;
  final SrsSyncProgress? migration = srsMigrationProgress.value;
  final SrsSyncProgress? srsLike = srs ?? migration;
  return <BackgroundTask>[
    if (syncInProgress.value)
      BackgroundTask(
        id: 'sync',
        icon: FushiIcons.sync,
        // 两级取值（BUG-1260）：有阶段 tick 用它，否则说清这轮同步是谁。
        line: p != null
            ? syncProgressLine(p)
            : (activity != null
                  ? syncActivityLine(activity)
                  : t.sync_progress_preparing),
        fraction: p?.fraction,
      ),
    if (srsLike != null)
      BackgroundTask(
        id: srs != null ? 'srs' : 'srs-migration',
        icon: srs != null ? FushiIcons.cloudSync : FushiIcons.storage,
        line: srsSyncProgressLine(srsLike),
        fraction: srsSyncProgressFraction(srsLike),
      ),
  ];
}

/// 入口按钮中心的图标：只有一项时用它自己的，多项时统一用同步图标。
IconData backgroundTasksIcon(List<BackgroundTask> tasks) =>
    tasks.length == 1 ? tasks.single.icon : FushiIcons.sync;

/// 悬停 / 长按气泡：每项一行。
String backgroundTasksTooltip(List<BackgroundTask> tasks) =>
    tasks.map((BackgroundTask task) => task.line).join('\n');

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
          if (tasks.isNotEmpty)
            FushiSegmentedProgressRing(
              key: const ValueKey<String>('background-tasks-ring'),
              size: size,
              strokeWidth: strokeWidth,
              // 墨水屏不跑不定态的往返动画：钉成 0，留一段静止的空轨道。
              values: <double?>[
                for (final BackgroundTask task in tasks)
                  einkSafeProgressValue(context, task.fraction),
              ],
              colors: <Color>[for (final BackgroundTask _ in tasks) fg],
              trackColor: track,
            ),
          if (showIcon)
            FushiIcon(backgroundTasksIcon(tasks), size: iconSize, color: fg),
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
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final BackgroundTask task in current)
                _BackgroundTaskRow(
                  key: ValueKey<String>('background-task-${task.id}'),
                  task: task,
                  onOpen: task.onOpen == null
                      ? null
                      : () {
                          Navigator.of(sheetContext).pop();
                          task.onOpen!();
                        },
                ),
            ],
          );
        },
      ),
    ),
  );
}

class _BackgroundTaskRow extends StatelessWidget {
  const _BackgroundTaskRow({required this.task, this.onOpen, super.key});

  final BackgroundTask task;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool eink = isEinkTheme(context);
    final String? openLabel = task.openLabel;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: <Widget>[
          FushiIcon(task.icon, size: 20, color: theme.colorScheme.primary),
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
                const SizedBox(height: 6),
                FushiLinearProgressIndicator(
                  value: einkSafeProgressValue(context, task.fraction),
                  backgroundColor: eink ? theme.colorScheme.surface : null,
                ),
              ],
            ),
          ),
          if (onOpen != null && openLabel != null) ...<Widget>[
            const SizedBox(width: 12),
            FushiFilledButton.tonal(onPressed: onOpen, child: Text(openLabel)),
          ],
        ],
      ),
    );
  }
}
