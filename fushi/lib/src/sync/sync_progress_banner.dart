import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/srs/srs_sync_progress.dart';
import 'package:fushi/src/srs/srs_sync_progress_ui.dart';
import 'package:fushi/src/sync/manual_sync_ui.dart';
import 'package:fushi/src/sync/sync_activity.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_progress.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 同步进行中的细进度条 —— 挂在媒体页列表上方。
///
/// 下拉同步一次全量可能要几十秒，光靠 RefreshIndicator 那个圈用户看不出在干什么、
/// 卡在哪一步。这条 banner 直接消费全局 [syncInProgress] / [syncProgress]，因此它
/// 对**任何**在飞的同步都亮（含后台/开机自动同步），不只是本页下拉触发的那次 ——
/// 页面本地 flag 做不到这点（BUG-101 同款教训）。
///
/// 文字行来自两级数据：有阶段 tick 用 [syncProgress]（"同步阅读数据 (3/12) 书名"），
/// 没有则退化到 [syncActivity]（"正在准备同步" / "同步合集" / "同步「书名」"）。二者
/// 同时为空是不可能的 —— 每条同步路径都先登记身份再干活 —— 所以这条 banner 不再会
/// 出现「一条线 + 零文字」那种无法解读的状态（用户据此分不清在同步还是在空转）。
///
/// 复习（SRS）同步一轮可能下载几千段、跑十几分钟，它不经 [syncInProgress]，所以这条 banner
/// 另听 [srsSyncProgress]，单独占一行（「同步复习数据 (123/2048)」+ 确定进度条）；没有一轮在跑而旧版本同步文件
/// 正在后台迁移时，这一行显示迁移进度（[srsMigrationProgress]）。
///
/// 没有同步在跑时收成零高度（[SizedBox.shrink]），不占布局、不改现有几何。
class SyncProgressBanner extends StatelessWidget {
  const SyncProgressBanner({
    this.compact = false,
    this.margin = EdgeInsets.zero,
    super.key,
  });

  /// Use the compact status strip in mobile book libraries.
  final bool compact;

  /// 只在有同步在跑（banner 可见）时才加的外边距：放进带间距的列表时用它留出与下一项的
  /// 间隔，空闲时仍是零高度、不留空白。
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        syncInProgress,
        syncProgress,
        syncActivity,
        srsSyncProgress,
        srsMigrationProgress,
      ]),
      builder: (BuildContext context, _) {
        final bool syncing = syncInProgress.value;
        final SrsSyncProgress? srs =
            srsSyncProgress.value ?? srsMigrationProgress.value;
        if (!syncing && srs == null) return const SizedBox.shrink();
        final FushiMotionScheme motion = context.fushiMotion;
        final SyncProgress? p = syncProgress.value;
        final SyncActivity? activity = syncActivity.value;
        // 常规同步与复习同步各一行（两者可能同时在跑：复习同步是常规同步的通道后置步骤，
        // 也会被「立即同步」/ 进复习 tab 单独触发）。各自的文字配各自的进度条，并存时
        // 两行都读得懂，不互相覆盖。
        return AnimatedSize(
          duration: motion.spatialDefault.duration,
          curve: motion.spatialDefault.curve,
          alignment: Alignment.topCenter,
          child: Padding(
            padding: margin,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (syncing)
                  _buildRow(
                    context,
                    key: const ValueKey<String>('sync-progress-banner-general'),
                    line: p != null
                        ? syncProgressLine(p)
                        : (activity != null
                              ? syncActivityLine(activity)
                              : null),
                    fraction: p?.fraction,
                  ),
                if (syncing && srs != null) SizedBox(height: compact ? 2 : 6),
                if (srs != null)
                  _buildRow(
                    context,
                    key: const ValueKey<String>('sync-progress-banner-srs'),
                    line: srsSyncProgressLine(srs),
                    fraction: srsSyncProgressFraction(srs),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 一行「图标 + 阶段文字」+ 一条进度条；[fraction] 为 null 时是不确定进度条。
  Widget _buildRow(
    BuildContext context, {
    required Key key,
    required String? line,
    required double? fraction,
  }) {
    final ThemeData theme = Theme.of(context);
    final FushiTypography type = context.fushiType;
    final FushiMotionScheme motion = context.fushiMotion;
    final bool eink = isEinkTheme(context);
    return Column(
      key: key,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (line != null)
          Padding(
            padding: compact
                ? const EdgeInsets.fromLTRB(12, 0, 12, 2)
                : const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Row(
              children: <Widget>[
                // M3E：行首一枚小号同步图标（tonal 圆底），让这条
                // 文字一眼读成「同步状态」而不是普通说明文字。
                if (!compact) ...<Widget>[
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: eink
                          ? theme.colorScheme.surface
                          : theme.colorScheme.secondaryContainer,
                      shape: BoxShape.circle,
                      border: eink
                          ? Border.all(color: theme.colorScheme.outline)
                          : null,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: FushiIcon(
                        FushiIcons.sync,
                        size: 14,
                        color: eink
                            ? theme.colorScheme.onSurface
                            : theme.colorScheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  // 阶段文字切换走 effects 弹簧淡入淡出，不跳字。
                  child: AnimatedSwitcher(
                    duration: motion.effectsFast.duration,
                    switchInCurve: motion.effectsFast.curve,
                    switchOutCurve: motion.effectsFast.curve,
                    layoutBuilder: (Widget? current, List<Widget> previous) =>
                        Stack(
                          alignment: AlignmentDirectional.centerStart,
                          children: <Widget>[
                            ...previous,
                            if (current != null) current,
                          ],
                        ),
                    child: Text(
                      line,
                      key: ValueKey<String>(line),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: (compact ? type.labelSmall : type.bodySmall)
                          .tabular
                          .copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ),
              ],
            ),
          ),
        // 阶段没有可测总数时退化成不确定进度条（value 为 null；eink
        // 下钉成 0——不定态动画在墨水屏上是整条带子持续刷新，且默认
        // 轨道色塌成底色，给实色轨道才看得见）。M3E 下是波浪进度。
        Padding(
          padding: compact
              ? EdgeInsets.zero
              : const EdgeInsets.symmetric(horizontal: 16),
          child: FushiLinearProgressIndicator(
            value: einkSafeProgressValue(context, fraction),
            minHeight: compact ? 2 : 4,
            backgroundColor: eink ? theme.colorScheme.surface : null,
          ),
        ),
      ],
    );
  }
}
