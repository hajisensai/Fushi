import 'dart:async' show FutureOr;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_download_progress.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/misc/engine_listenable.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';

// 视频库页头的两颗专用动作（设计稿 #video V2，2026-11-15 所有者确认）：
//
// * 「后台任务」只在真有任务时出现，按钮外圈一枚进度环、角上写进行中的数量，
//   tooltip / Semantics 是「后台任务 · N 个进行中」——此前常驻一颗放大镜图标，
//   用户看不出它是后台任务（「完全看不出来这是后台任务」）。
// * 「⋯」把低频的库管理动作（管理标签 / 管理合集 / 刷新 / 布局切换 / 遥控 /
//   选择…）收在一处（共用组件 `FushiHeaderMoreButton`，曲库同用），页头只留搜索、
//   筛选与排序、后台任务、添加。

/// 页头「后台任务」按钮的展示状态（纯数据，便于单测）。
@immutable
class VideoBackgroundTasksSummary {
  const VideoBackgroundTasksSummary({
    required this.running,
    required this.needsConfirmation,
    required this.progress,
  });

  /// 进行中的任务数：正在跑的刮削 / 扫描（至多一条）+ 排队的手动刮削。
  final int running;

  /// 有一条刮削结果在等用户确认。
  final bool needsConfirmation;

  /// 当前任务的确定进度 0..1；null = 不定态（还没有总数）。
  final double? progress;

  /// 有任何需要露出按钮的事：没有任务时按钮整颗不出现。
  bool get visible => running > 0 || needsConfirmation;

  @override
  bool operator ==(Object other) =>
      other is VideoBackgroundTasksSummary &&
      other.running == running &&
      other.needsConfirmation == needsConfirmation &&
      other.progress == progress;

  @override
  int get hashCode => Object.hash(running, needsConfirmation, progress);
}

/// 由刮削任务控制器的原始状态得出按钮状态。
VideoBackgroundTasksSummary videoBackgroundTasksSummary({
  required bool busy,
  required int queuedManualRequests,
  required bool needsConfirmation,
  required int current,
  required int total,
}) {
  final int running = (busy ? 1 : 0) + queuedManualRequests;
  final double? progress = busy && total > 0
      ? (current / total).clamp(0.0, 1.0)
      : null;
  return VideoBackgroundTasksSummary(
    running: running,
    needsConfirmation: needsConfirmation,
    progress: progress,
  );
}

/// [videoBackgroundTasksSummary] 的控制器入口。
VideoBackgroundTasksSummary videoBackgroundTasksSummaryOf(
  VideoSourceScrapeTaskController controller,
) {
  final VideoSourceScrapeProgress progress = controller.progress;
  return videoBackgroundTasksSummary(
    busy: controller.isBusy,
    queuedManualRequests: controller.queuedManualRequestCount,
    needsConfirmation: controller.pendingConfirmation != null,
    current: progress.current,
    total: progress.total,
  );
}

/// 按钮 tooltip / 读屏名：有进行中的任务写数量，只剩待确认时写原「后台任务」。
String videoBackgroundTasksTooltip(VideoBackgroundTasksSummary summary) =>
    summary.running > 0
    ? t.video_background_tasks_running(n: summary.running)
    : t.video_source_scrape_tasks_open;

/// 页头「后台任务」按钮：[FushiIconButton]（焦点 / 手柄 / tooltip / 语义全走
/// 它）外圈叠一枚进度环、角上叠数量。控制器每次通知都就地重画进度与数量；
/// 出现 / 消失由页面按 [VideoBackgroundTasksSummary.visible] 决定（动作组按
/// 成员身份做形变切换）。
class VideoBackgroundTasksButton extends StatelessWidget {
  const VideoBackgroundTasksButton({
    required this.controller,
    required this.onTap,
    super.key,
  });

  final VideoSourceScrapeTaskController controller;
  final FutureOr<void> Function() onTap;

  static const double _ringSize = 40;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: EngineListenable(controller),
      builder: (BuildContext context, Widget? _) {
        final VideoBackgroundTasksSummary summary =
            videoBackgroundTasksSummaryOf(controller);
        final ColorScheme colors = Theme.of(context).colorScheme;
        final bool eink = isEinkTheme(context);
        final Color accent = eink ? colors.onSurface : colors.primary;
        final String tooltip = videoBackgroundTasksTooltip(summary);
        return Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: <Widget>[
            if (summary.running > 0)
              IgnorePointer(
                child: FushiDownloadProgressRing(
                  key: const ValueKey<String>('video-background-tasks-ring'),
                  value: summary.progress,
                  color: accent,
                  trackColor: accent.withValues(alpha: eink ? 0.3 : 0.18),
                  labelColor: accent,
                  size: _ringSize,
                  showLabel: false,
                ),
              ),
            FushiIconButton(
              key: const ValueKey<String>('video-background-tasks-button'),
              tooltip: tooltip,
              icon: summary.needsConfirmation
                  ? FushiIcons.checklist
                  : FushiIcons.manageSearch,
              size: 20,
              badge: summary.needsConfirmation && summary.running == 0,
              alwaysVisible: true,
              onTap: onTap,
            ),
            if (summary.running > 0)
              PositionedDirectional(
                top: -2,
                end: -2,
                child: IgnorePointer(
                  child: ExcludeSemantics(
                    child: AnimatedSwitcher(
                      duration: fushiMotionDuration(context, FushiMotion.short),
                      switchInCurve: FushiMotion.enter,
                      switchOutCurve: FushiMotion.exit,
                      transitionBuilder:
                          (Widget child, Animation<double> animation) =>
                              ScaleTransition(scale: animation, child: child),
                      child: _CountBadge(
                        key: ValueKey<int>(summary.running),
                        count: summary.running,
                        fill: accent,
                        ink: eink ? colors.surface : colors.onPrimary,
                        outline: colors.surface,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({
    required this.count,
    required this.fill,
    required this.ink,
    required this.outline,
    super.key,
  });

  final int count;
  final Color fill;
  final Color ink;
  final Color outline;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      key: const ValueKey<String>('video-background-tasks-count'),
      decoration: ShapeDecoration(
        color: fill,
        shape: StadiumBorder(side: BorderSide(color: outline, width: 1.5)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Center(
            widthFactor: 1,
            child: Text(
              count > 99 ? '99+' : '$count',
              style: context.fushiType.labelSmall.copyWith(
                color: ink,
                fontWeight: FontWeight.w700,
                height: 1,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
