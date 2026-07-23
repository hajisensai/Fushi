import 'package:flutter/material.dart';
import 'package:hibiki/src/sync/manual_sync_ui.dart';
import 'package:hibiki/src/sync/sync_auto_trigger.dart';
import 'package:hibiki/src/sync/sync_progress.dart';

/// 同步进行中的细进度条 —— 挂在媒体页列表上方。
///
/// 下拉同步一次全量可能要几十秒，光靠 RefreshIndicator 那个圈用户看不出在干什么、
/// 卡在哪一步。这条 banner 直接消费全局 [syncInProgress] / [syncProgress]，因此它
/// 对**任何**在飞的同步都亮（含后台/开机自动同步），不只是本页下拉触发的那次 ——
/// 页面本地 flag 做不到这点（BUG-101 同款教训）。
///
/// 没有同步在跑时收成零高度（[SizedBox.shrink]），不占布局、不改现有几何。
class SyncProgressBanner extends StatelessWidget {
  const SyncProgressBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: syncInProgress,
      builder: (BuildContext context, bool syncing, _) {
        if (!syncing) return const SizedBox.shrink();
        return ValueListenableBuilder<SyncProgress?>(
          valueListenable: syncProgress,
          builder: (BuildContext context, SyncProgress? p, __) {
            final ThemeData theme = Theme.of(context);
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (p != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: Text(
                      syncProgressLine(p),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                // 阶段没有可测总数时退化成不确定进度条（value 为 null）。
                LinearProgressIndicator(value: p?.fraction, minHeight: 2),
              ],
            );
          },
        );
      },
    );
  }
}
