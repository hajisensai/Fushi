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

/// 一条资产的一个方向 —— 设置页「上传词典 / 下载词典 / 上传本地音频数据库 /
/// 下载本地音频数据库」四行共用这一个 widget。
///
/// **一行一个动作**，而不是一行两个按钮：方向导航（手柄 / 键盘）在这个代码库里是
/// 按「行 = 一个 [FushiFocusTarget]」注册的（见 [_SyncNowWidget] 里 BUG-016 的注释），
/// 一行塞两个动作就得给焦点系统开左右键绑定的特例，而用户还猜不到那个绑定存在。
/// 拆成两行零特例，标题本身就说清了这一下会往哪边搬。
///
/// 跑与反馈全在 [runAssetTransferWithFeedback]（与「立即同步」共用同一个外壳）；
/// 这里只负责渲染行、显示在飞进度、并挡住重复触发。
class _AssetTransferWidget extends StatefulWidget {
  const _AssetTransferWidget({
    required this.settingsContext,
    required this.kind,
    required this.direction,
    required this.title,
    required this.icon,
  });

  final SettingsContext settingsContext;
  final SyncAssetKind kind;
  final SyncAssetDirection direction;
  final String title;
  final IconData icon;

  @override
  State<_AssetTransferWidget> createState() => _AssetTransferWidgetState();
}

class _AssetTransferWidgetState extends State<_AssetTransferWidget> {
  Future<void> _run() async {
    await runAssetTransferWithFeedback(
      context: context,
      appModel: widget.settingsContext.appModel,
      kind: widget.kind,
      direction: widget.direction,
    );
  }

  /// 说明文字讲的是**方向的语义**（并集的哪一半），与资产类别无关 —— 两类资产的
  /// 传输规则逐字相同，各写一份只会让它们日后漂移。
  String get _subtitle => switch (widget.direction) {
        SyncAssetDirection.upload => t.sync_asset_upload_hint,
        SyncAssetDirection.download => t.sync_asset_download_hint,
        // 这一行只由 upload / download 两个方向构造；[SyncAssetDirection.both] 是
        // 自动同步路径的方向，不会出现在设置页上。
        SyncAssetDirection.both => t.sync_asset_upload_hint,
      };

  @override
  Widget build(BuildContext context) {
    // 与「立即同步」同源：进度来自全局 notifier，任何在飞的同步（包括后台自动
    // sweep）都会让本行显示进度并挡住重复触发 —— 后端是单例，两轮并行会互相踩。
    return ValueListenableBuilder<bool>(
      valueListenable: syncInProgress,
      builder: (BuildContext context, bool syncing, _) {
        return ValueListenableBuilder<SyncProgress?>(
          valueListenable: syncProgress,
          builder: (BuildContext context, SyncProgress? p, __) {
            final AdaptiveSettingsRow row = AdaptiveSettingsRow(
              title: widget.title,
              subtitle: syncing && p != null ? syncProgressLine(p) : _subtitle,
              icon: widget.icon,
              controlBelow: true,
              // 行级 onTap 才让本行注册成 [FushiFocusTarget]，方向导航与手柄 A 因此
              // 能到达并触发它（BUG-016，与「立即同步」同因）。
              onTap: _run,
              trailing: syncing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : FilledButton.tonal(
                      onPressed: _run,
                      child: Text(
                        widget.direction == SyncAssetDirection.download
                            ? t.sync_asset_download_action
                            : t.sync_asset_upload_action,
                      ),
                    ),
            );
            if (!syncing) return row;
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
  /// 3. 空闲 → 上一轮**全量**同步的结局（尤其「没有可用的同步通道」＝上轮其实什么
  ///    都没同步；以前它与正常跑完同形，用户只看得到进度条闪一下）。没跑过才回落到
  ///    静态提示。
  ///
  /// 第 3 段只认 [SyncActivityKind.fullSweep]：本行讲的是「立即同步」这件事，拿后台
  /// 单本 / 合集轻量同步的结局来填会答非所问（用户点的是全量，看到的却是某本书的
  /// 结果）。进行中的第 1、2 段不做这个过滤 —— 那两段回答的是「现在有没有东西在跑」，
  /// 任何同步都算数（BUG-101 的教训）。
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
            } else if (!syncing &&
                outcome != null &&
                outcome.kind == SyncActivityKind.fullSweep) {
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
              // is what registers it as a FushiFocusTarget so gamepad/keyboard
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
