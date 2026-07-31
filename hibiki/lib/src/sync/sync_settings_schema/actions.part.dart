// GENERATED-NOTE: extracted from sync_settings_schema.dart (TODO-585).
part of '../sync_settings_schema.dart';

// Manual sync action row (sync-now).
// Shares the parent library's imports + private scope (_syncSettings / _showSnackBar / _SyncSettingsState); moved verbatim.
//
// 「跑同步 + 统一反馈」的实现搬去了 lib/src/sync/manual_sync_ui.dart
// （[runManualSyncWithFeedback] / [summarizeSyncReport]），因为媒体页的下拉同步要走
// 同一条路径 —— 冲突必须按各自通道后端呈现、鉴权失效必须登出，这些不能被复制成
// 多份各自演化。本行现在只是那个入口的一层壳。

// ── Backup export widget ─────────────────────────────────────────────

class _SyncNowWidget extends StatefulWidget {
  const _SyncNowWidget({required this.settingsContext});
  final SettingsContext settingsContext;

  @override
  State<_SyncNowWidget> createState() => _SyncNowWidgetState();
}

class _SyncNowWidgetState extends State<_SyncNowWidget> {
  /// 设置页「立即同步」——只是 [runManualSyncWithFeedback] 的壳。重入 guard、三种
  /// outcome 的提示、逐通道冲突呈现、鉴权失效登出全在那个共享入口里，与媒体页下拉
  /// 同步同一份实现。设置页是显式动作，三种结果都要给用户回音（全 announce 默认 true）。
  Future<void> _syncNow() async {
    await runManualSyncWithFeedback(
      context: context,
      appModel: widget.settingsContext.appModel,
      // 已在同步中时这一行本就在显示进度条，再弹一句 toast 是噪音（BUG-101）。
      announceBusy: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Driven by the app-wide notifiers, NOT a local flag: the bar must show for
    // ANY in-flight sweep — including a background/app-open auto-sync the user
    // never triggered from this row — instead of only the run this row started
    // (which used to fall through to a bare "同步进行中" toast, BUG-101).
    return ValueListenableBuilder<bool>(
      valueListenable: syncInProgress,
      builder: (BuildContext context, bool syncing, _) {
        return ValueListenableBuilder<SyncProgress?>(
          valueListenable: syncProgress,
          builder: (BuildContext context, SyncProgress? p, __) {
            return _buildRow(syncing, p);
          },
        );
      },
    );
  }

  /// 副标题分三段取值，都是「说清现在到底怎么了」：
  /// 1. 同步中且有阶段 tick → 阶段行；
  /// 2. 同步中但还没有 tick（准备段 / 轻量路径）→ 这轮同步的身份；
  /// 3. 空闲 → 上一轮的**结局**（尤其「没有可用的同步通道」＝上轮其实什么都没同步；
  ///    以前它与正常跑完同形，用户只看得到进度条闪一下）。没跑过才回落到静态提示。
  Widget _buildRow(bool syncing, SyncProgress? p) {
    return ValueListenableBuilder<SyncActivity?>(
      valueListenable: syncActivity,
      builder: (BuildContext context, SyncActivity? activity, _) {
        return ValueListenableBuilder<SyncRunOutcome?>(
          valueListenable: lastSyncOutcome,
          builder: (BuildContext context, SyncRunOutcome? outcome, __) {
            final String subtitle;
            if (syncing && p != null) {
              subtitle = syncProgressLine(p);
            } else if (syncing && activity != null) {
              subtitle = syncActivityLine(activity);
            } else if (!syncing && outcome != null) {
              subtitle = syncOutcomeLine(outcome);
            } else {
              subtitle = t.sync_now_hint;
            }
            final AdaptiveSettingsRow row = AdaptiveSettingsRow(
              title: t.sync_now,
              subtitle: subtitle,
              icon: Icons.sync,
              controlBelow: true,
              // The action lives on the trailing button; giving the ROW an onTap
              // is what registers it as a HibikiFocusTarget so gamepad/keyboard
              // directional nav can reach it and Activate runs the sync
              // (BUG-016). Without it the row was unreachable and Down from the
              // neighbouring "Compare Data" row jumped cross-pane to the rail.
              onTap: _syncNow,
              trailing: syncing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : FilledButton(
                      onPressed: _syncNow,
                      child: Text(t.sync_now),
                    ),
            );
            if (!syncing) return row;
            // Inline determinate bar below the row (indeterminate when a phase
            // has no measurable total), matching the compare dialog's Apply
            // progress.
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                row,
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: LinearProgressIndicator(value: p?.fraction),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
