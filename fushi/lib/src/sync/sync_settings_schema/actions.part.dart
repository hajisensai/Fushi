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

/// 一次性告知：升级前开着词典 / 本地音频自动同步的存量用户，升级后同步会**静默**
/// 停下——「立即同步」照常报「完成 N 项」，而新导入的词典再也不上云，用户没有任何
/// 信号知道备份里已经没有词典了。这不是数据丢失，是「我以为还在备份」的静默失效。
///
/// 只在 [SyncRepository.hadLegacyAssetAutoSync] 为真时占位，用户点「知道了」后写
/// false，此后彻底消失；从没开过那两个开关的用户一次都看不到。
class _LegacyAssetSyncNotice extends StatefulWidget {
  const _LegacyAssetSyncNotice({required this.settingsContext});

  final SettingsContext settingsContext;

  @override
  State<_LegacyAssetSyncNotice> createState() => _LegacyAssetSyncNoticeState();
}

class _LegacyAssetSyncNoticeState extends State<_LegacyAssetSyncNotice> {
  /// null = 还没读出来（不占位，避免闪一下再消失）。
  bool? _show;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final bool had =
        await SyncRepository(widget.settingsContext.appModel.database)
            .hadLegacyAssetAutoSync();
    if (!mounted) return;
    setState(() => _show = had);
  }

  Future<void> _dismiss() async {
    await SyncRepository(widget.settingsContext.appModel.database)
        .acknowledgeLegacyAssetAutoSync();
    if (!mounted) return;
    setState(() => _show = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_show != true) return const SizedBox.shrink();
    return AdaptiveSettingsRow(
      title: t.sync_asset_legacy_notice_title,
      subtitle: t.sync_asset_legacy_notice_body,
      icon: Icons.info_outline,
      controlBelow: true,
      // 行级 onTap 让本行注册成 FushiFocusTarget，方向导航 / 手柄 A 能到达（BUG-016）。
      onTap: _dismiss,
      trailing: FilledButton.tonal(
        onPressed: _dismiss,
        child: Text(t.sync_asset_legacy_notice_dismiss),
      ),
    );
  }
}

/// 一类资产一行 —— 设置页「词典 / 本地音频数据库」两行共用这一个 widget，方向
/// （上传把本机独有的推上去 / 下载把远端独有的拉下来）在行尾的「传输 ▾」菜单里选。
///
/// **一行一个焦点目标**：方向导航（手柄 / 键盘）在这个代码库里是按「行 = 一个
/// [FushiFocusTarget]」注册的（见 [_SyncNowWidget] 里 BUG-016 的注释）。这里那个
/// 目标就是菜单本身——[FushiOverflowMenu] 在焦点树里自注册，Activate 即弹菜单，
/// 鼠标点也是同一条路径；行**不**再另挂 onTap，否则一行两个目标。此前是「一行一个
/// 方向」四行，用户拍板合并（2026-09-06）；「一行两个按钮」被否——那要给焦点系统开
/// 左右键特例，用户还猜不到那个绑定存在。
///
/// 跑与反馈全在 [runAssetTransferWithFeedback]（与「立即同步」共用同一个外壳）；
/// 这里只负责渲染行、显示在飞进度、并挡住重复触发。
class _AssetTransferMenuRow extends StatelessWidget {
  const _AssetTransferMenuRow({
    required this.settingsContext,
    required this.kind,
    required this.title,
    required this.icon,
  });

  final SettingsContext settingsContext;
  final SyncAssetKind kind;
  final String title;
  final IconData icon;

  Future<void> _run(BuildContext context, SyncAssetDirection direction) {
    return runAssetTransferWithFeedback(
      context: context,
      appModel: settingsContext.appModel,
      kind: kind,
      direction: direction,
    );
  }

  Widget _menu(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return FushiOverflowMenu<SyncAssetDirection>(
      tooltip: t.sync_asset_transfer_menu,
      items: <PopupMenuEntry<SyncAssetDirection>>[
        FushiPopupMenuItem<SyncAssetDirection>(
          label: t.sync_asset_upload_action,
          value: SyncAssetDirection.upload,
          icon: Icons.upload_outlined,
        ),
        FushiPopupMenuItem<SyncAssetDirection>(
          label: t.sync_asset_download_action,
          value: SyncAssetDirection.download,
          icon: Icons.download_outlined,
        ),
      ],
      onSelected: (SyncAssetDirection direction) => _run(context, direction),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              t.sync_asset_transfer_menu,
              style: TextStyle(
                color: scheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            Icon(Icons.arrow_drop_down, color: scheme.primary),
          ],
        ),
      ),
    );
  }

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
              title: title,
              subtitle: syncing && p != null
                  ? syncProgressLine(p)
                  : t.sync_asset_transfer_hint,
              icon: icon,
              controlBelow: true,
              trailing: syncing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : _menu(context),
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
          // 读 [lastFullSweepOutcome] 而不是「读 lastSyncOutcome 再过滤 kind」：
          // 后者会被任何一轮别的同步挤掉（合集轻量、单本，以及本页那四个资产传输
          // 按钮），于是刚显示的「上次同步」结局凭空退回静态提示。值本身就该是
          // 精确的那一个。
          valueListenable: lastFullSweepOutcome,
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
