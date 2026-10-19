/// 牌组列表顶上（列表第一项）的后台导入任务条（BUG-3549）：每个排队 / 运行中 / 刚结束的导入一行。
///
/// - 排队中：名字 + 不定态进度条，右侧「取消」（还没开始写库，取消后不会再跑）；
/// - 运行中：名字 + 进度条（还没进度时为不定态）；没有取消（引擎侧还没有批间停止信号）；
/// - 已取消：单独的终态，右侧「关闭」；
/// - 完成：点一下看导入报告，右侧「关闭」；
/// - 失败：点一下看失败原因，右侧「关闭」。
///
/// 卡片走 [FushiCard]（MD3 / Apple 两套设计系统各自分派）；行的出现 / 消失与状态切换都是
/// 尺寸 + 透明度动画，时长取 [fushiMotionDuration]（墨水屏与「减弱动态效果」归零）。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/srs/srs_import_entry.dart';
import 'package:fushi/src/srs/srs_import_task.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

class SrsImportTasksBar extends ConsumerWidget {
  const SrsImportTasksBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SrsImportController controller = ref.watch(
      srsImportControllerProvider,
    );
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        final List<SrsImportTask> tasks = controller.tasks;
        final Duration duration = fushiMotionDuration(
          context,
          FushiMotion.medium,
        );
        return FushiAnimatedSize(
          duration: duration,
          curve: FushiMotion.standard,
          alignment: Alignment.topCenter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final (int i, SrsImportTask task) in tasks.indexed)
                _TaskRow(
                  key: ValueKey<int>(task.id),
                  task: task,
                  first: i == 0,
                  onDismiss: () => controller.dismiss(task),
                  onCancel: () => unawaited(controller.cancel(task)),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _TaskRow extends StatefulWidget {
  const _TaskRow({
    required this.task,
    required this.onDismiss,
    required this.onCancel,
    required this.first,
    super.key,
  });

  final SrsImportTask task;
  final bool first;
  final VoidCallback onDismiss;

  /// 取消排队中 / 运行中的任务（只在 [SrsImportTask.canCancel] 时显示按钮）。
  final VoidCallback onCancel;

  @override
  State<_TaskRow> createState() => _TaskRowState();
}

class _TaskRowState extends State<_TaskRow>
    with SingleTickerProviderStateMixin {
  /// 进场：尺寸 + 透明度从 0 展开（与牌组列表行进场同一套时长）。
  late final AnimationController _enter = AnimationController(vsync: this);

  /// 进场曲线：只建一次（建在 build 里会每帧往 [_enter] 上多挂一个监听且永不释放）。
  late final CurvedAnimation _curved = CurvedAnimation(
    parent: _enter,
    curve: FushiMotion.enter,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _enter.duration = fushiMotionDuration(context, FushiMotion.medium);
    if (_enter.status == AnimationStatus.dismissed) _enter.forward();
  }

  @override
  void dispose() {
    _curved.dispose();
    _enter.dispose();
    super.dispose();
  }

  void _open() {
    final SrsImportTask task = widget.task;
    switch (task.status) {
      case SrsImportTaskStatus.done:
        if (task.report != null) {
          showSrsImportReportDialog(context, task.report!);
        }
      case SrsImportTaskStatus.failed:
        if (task.error != null) {
          showSrsImportFailureDialog(context, task.error!);
        }
      case SrsImportTaskStatus.queued:
      case SrsImportTaskStatus.running:
      case SrsImportTaskStatus.cancelled:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsImportTask task = widget.task;
    final Animation<double> curved = _curved;
    final Duration switchDuration = fushiMotionDuration(
      context,
      FushiMotion.short,
    );
    final String title = switch (task.status) {
      SrsImportTaskStatus.queued => t.srs_import_task_queued(
        name: task.displayName,
      ),
      SrsImportTaskStatus.running when task.stopping =>
        t.srs_import_task_stopping(name: task.displayName),
      SrsImportTaskStatus.running => t.srs_import_task_running(
        name: task.displayName,
      ),
      SrsImportTaskStatus.done => t.srs_import_task_done(
        name: task.displayName,
        n: task.report?.notesAdded ?? 0,
      ),
      SrsImportTaskStatus.failed => t.srs_import_task_failed(
        name: task.displayName,
      ),
      SrsImportTaskStatus.cancelled => t.srs_import_task_cancelled(
        name: task.displayName,
      ),
    };
    final IconData icon = switch (task.status) {
      SrsImportTaskStatus.queued ||
      SrsImportTaskStatus.running => FushiIcons.importFile,
      SrsImportTaskStatus.done => FushiIcons.success,
      SrsImportTaskStatus.failed => FushiIcons.error,
      SrsImportTaskStatus.cancelled => FushiIcons.block,
    };
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color? iconColor = switch (task.status) {
      SrsImportTaskStatus.failed => scheme.error,
      SrsImportTaskStatus.done => scheme.primary,
      _ => null,
    };
    return SizeTransition(
      sizeFactor: curved,
      axisAlignment: -1,
      child: FadeTransition(
        opacity: curved,
        child: Padding(
          // 行与行之间的间距（列表本身给左右边距与和牌组行的间隔）。
          padding: EdgeInsets.only(top: widget.first ? 0 : tokens.spacing.gap),
          child: FushiCard(
            key: ValueKey<String>('srs-import-task-${task.id}'),
            onTap:
                task.status == SrsImportTaskStatus.done ||
                    task.status == SrsImportTaskStatus.failed
                ? _open
                : null,
            padding: EdgeInsets.symmetric(
              horizontal: tokens.spacing.gap * 1.5,
              vertical: tokens.spacing.gap,
            ),
            child: Row(
              children: <Widget>[
                AnimatedSwitcher(
                  duration: switchDuration,
                  switchInCurve: FushiMotion.enter,
                  switchOutCurve: FushiMotion.exit,
                  child: FushiIcon(
                    icon,
                    key: ValueKey<SrsImportTaskStatus>(task.status),
                    color: iconColor,
                  ),
                ),
                SizedBox(width: tokens.spacing.gap * 1.5),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      AnimatedSwitcher(
                        duration: switchDuration,
                        switchInCurve: FushiMotion.enter,
                        switchOutCurve: FushiMotion.exit,
                        layoutBuilder:
                            (Widget? current, List<Widget> previous) => Stack(
                              alignment: Alignment.centerLeft,
                              children: <Widget>[
                                ...previous,
                                if (current != null) current,
                              ],
                            ),
                        child: Text(
                          title,
                          key: ValueKey<String>(title),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      FushiAnimatedSize(
                        duration: switchDuration,
                        curve: FushiMotion.standard,
                        child: task.isFinished
                            ? const SizedBox(width: double.infinity)
                            : Padding(
                                padding: EdgeInsets.only(
                                  top: tokens.spacing.gap / 2,
                                ),
                                child: ValueListenableBuilder<double>(
                                  valueListenable: task.progress,
                                  builder:
                                      (
                                        BuildContext context,
                                        double value,
                                        Widget? _,
                                      ) => FushiLinearProgressIndicator(
                                        value: value <= 0 ? null : value,
                                      ),
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
                // 排队中 / 运行中 → 取消；结束 → 关闭。两者互斥，切换时淡入淡出。
                AnimatedSwitcher(
                  duration: switchDuration,
                  switchInCurve: FushiMotion.enter,
                  switchOutCurve: FushiMotion.exit,
                  child: task.canCancel
                      ? FushiIconButton(
                          key: ValueKey<String>(
                            'srs-import-task-cancel-${task.id}',
                          ),
                          icon: FushiIcons.cancel,
                          tooltip: t.srs_import_task_cancel,
                          onTap: widget.onCancel,
                        )
                      : task.isFinished
                      ? FushiIconButton(
                          key: ValueKey<String>(
                            'srs-import-task-dismiss-${task.id}',
                          ),
                          icon: FushiIcons.close,
                          tooltip: t.srs_import_task_dismiss,
                          onTap: widget.onDismiss,
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
