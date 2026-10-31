/// 来源库（扫描根）的「隐私」开关（schema v140 `media_sources.is_private`，反馈
/// kEAgATi1LF：「某个文件夹想放点 nsfw 的，但不想让它上排行榜」）。
///
/// 开关只写 `media_sources.is_private` 一列；「私密」的效果由
/// `fushi_engine/privacy/media_privacy.dart` 的 [MediaPrivacySnapshot] 统一实现——
/// 隐私来源产出的书 / 漫画 / 视频与作品级私密标记同一口径：排行榜书架构建
/// （`buildLocalShelf`，书架条目 + 封面投票的唯一来源）跳过它们，Bangumi 追踪也跳过。
///
/// **作用范围**：开关本身是设备本地配置（来源 = 本机的扫描根，不进互联同步），
/// 管的是「本机书架构建时这些条目算私密」。移除隐私来源时，条目会被逐一补上
/// **作品级**私密标记（`FushiDatabase.deleteMediaSource`）——那份标记按设计搭
/// 标签清单同步到已配对设备（排行榜只有一台上传设备，私密必须到得了它），所以
/// 「移除来源后仍私密」在所有设备上都成立。这是有意为之，见 `deleteMediaSource`。
///
/// 打开开关时，落库成功即生效（对话框立即可关）；随后在**后台**跑一次排行榜同步，
/// 把已经上报过的条目从服务端撤下（书架同步对「本地已消失」的作品发 remove），
/// 结果用 toast 报告，不等下一轮 30 分钟的后台同步，也不把对话框卡在一次网络同步上。
library;

import 'dart:async';

import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:material_ui/material_ui.dart';

/// 打开隐私开关后那次「从排行榜撤下」的结果。
enum SourceLibraryWithdrawOutcome {
  /// 已立即同步、从排行榜撤下已上报的条目。
  withdrawn,

  /// 排行榜不需要撤（没开排行榜 / 上传关着 / 本机不是上传设备）。
  notUploading,

  /// 立即撤下的那次同步失败（[SourceLibraryWithdrawResult.error]）；私密已经
  /// 生效（条目已不在书架里），下一轮后台同步会再撤。
  failed,
}

class SourceLibraryWithdrawResult {
  const SourceLibraryWithdrawResult(this.outcome, [this.error]);

  final SourceLibraryWithdrawOutcome outcome;

  /// [SourceLibraryWithdrawOutcome.failed] 时的同步错误。
  final Object? error;
}

/// 设置来源 [sourceId] 的隐私开关：只落库。落库失败直接抛（开关没变，调用方
/// 必须明说）。打开之后要不要从排行榜撤下由调用方另起
/// [withdrawSourceLibraryFromLeaderboard]——那是一次网络同步，不该挡住开关本身。
Future<void> setSourceLibraryPrivate({
  required FushiDatabase db,
  required int sourceId,
  required bool isPrivate,
}) => db.updateMediaSourcePrivate(sourceId, isPrivate);

/// 隐私开关打开后立即撤下已上报的条目：调 [withdrawFromLeaderboard]（生产里是
/// `leaderboardPrivacyWithdrawProvider`，即 `LeaderboardService.syncAfterPrivacyChange`：
/// 返回是否真的同步了）。同步失败不回滚开关——私密已经生效，只是服务端那份
/// 要等下一轮同步；失败作为 [SourceLibraryWithdrawOutcome.failed] 返回，由调用方
/// 明说。
Future<SourceLibraryWithdrawResult> withdrawSourceLibraryFromLeaderboard(
  Future<bool> Function() withdrawFromLeaderboard,
) async {
  try {
    final bool synced = await withdrawFromLeaderboard();
    return SourceLibraryWithdrawResult(
      synced
          ? SourceLibraryWithdrawOutcome.withdrawn
          : SourceLibraryWithdrawOutcome.notUploading,
    );
  } on Object catch (error) {
    return SourceLibraryWithdrawResult(
      SourceLibraryWithdrawOutcome.failed,
      error,
    );
  }
}

/// 后台跑 [withdrawSourceLibraryFromLeaderboard] 并用 toast 报告结果。不依赖任何
/// widget 的生命周期：对话框早已关掉也照样报。
Future<void> runSourceLibraryWithdrawal(
  Future<bool> Function() withdrawFromLeaderboard,
) async {
  final SourceLibraryWithdrawResult result =
      await withdrawSourceLibraryFromLeaderboard(withdrawFromLeaderboard);
  switch (result.outcome) {
    case SourceLibraryWithdrawOutcome.withdrawn:
      FushiToast.show(
        msg: t.media_source_privacy_withdrawn_toast,
        severity: ToastSeverity.success,
      );
    case SourceLibraryWithdrawOutcome.notUploading:
      FushiToast.show(
        msg: t.media_source_privacy_marked_toast,
        severity: ToastSeverity.success,
      );
    case SourceLibraryWithdrawOutcome.failed:
      // 私密已生效，但服务端那份还在：必须明说，不能报成功。
      FushiToast.show(
        msg: t.media_source_privacy_withdraw_failed(
          reason: result.error.toString(),
        ),
        severity: ToastSeverity.error,
      );
  }
}

/// 打开来源 [source] 的隐私开关对话框；返回最终是否私密（null = 没改过）。
Future<bool?> showSourceLibraryPrivacyDialog(
  BuildContext context, {
  required FushiDatabase db,
  required SourceLibraryRow source,
  required Future<bool> Function() withdrawFromLeaderboard,
}) => showAppDialog<bool>(
  context: context,
  builder: (BuildContext dialogContext) => SourceLibraryPrivacyDialog(
    db: db,
    source: source,
    withdrawFromLeaderboard: withdrawFromLeaderboard,
  ),
);

class SourceLibraryPrivacyDialog extends StatefulWidget {
  const SourceLibraryPrivacyDialog({
    super.key,
    required this.db,
    required this.source,
    required this.withdrawFromLeaderboard,
  });

  final FushiDatabase db;
  final SourceLibraryRow source;
  final Future<bool> Function() withdrawFromLeaderboard;

  @override
  State<SourceLibraryPrivacyDialog> createState() =>
      _SourceLibraryPrivacyDialogState();
}

class _SourceLibraryPrivacyDialogState
    extends State<SourceLibraryPrivacyDialog> {
  late bool _private = widget.source.isPrivate;

  /// 本对话框里改过（关闭时回传给列表刷新）。
  bool _changed = false;
  bool _writing = false;

  /// 只等落库：成功即放开控件（对话框可以立刻关）。打开时的排行榜撤下在后台跑，
  /// 结果由 [runSourceLibraryWithdrawal] 用 toast 报告——它不挂在本对话框上，
  /// 关掉对话框不会打断它。
  Future<void> _set(bool value) async {
    setState(() => _writing = true);
    try {
      await setSourceLibraryPrivate(
        db: widget.db,
        sourceId: widget.source.id,
        isPrivate: value,
      );
    } on Object catch (error) {
      // 落库失败：开关保持原状态并明说——用户以为已经藏起来了、其实下一轮照常上传，
      // 正是这个开关要防的事。
      FushiToast.show(
        msg: t.media_privacy_save_failed(reason: error.toString()),
        severity: ToastSeverity.error,
      );
      if (mounted) setState(() => _writing = false);
      return;
    }
    if (mounted) {
      setState(() {
        _private = value;
        _changed = true;
        _writing = false;
      });
    }
    if (value) {
      unawaited(runSourceLibraryWithdrawal(widget.withdrawFromLeaderboard));
    } else {
      FushiToast.show(
        msg: t.media_source_privacy_cleared_toast,
        severity: ToastSeverity.success,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return FushiAlertDialog(
      title: Text('${t.media_source_privacy_action} · ${widget.source.label}'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              FushiSwitchListTile(
                key: const ValueKey<String>('media-source-privacy-switch'),
                value: _private,
                onChanged: _writing ? null : (bool v) => unawaited(_set(v)),
                contentPadding: EdgeInsets.zero,
                secondary: FushiIcon(
                  _private ? FushiIcons.lock : FushiIcons.lockOpen,
                ),
                title: Text(t.media_source_privacy_switch),
              ),
              FushiAnimatedSize(
                duration: fushiMotionDuration(context, FushiMotion.short),
                curve: FushiMotion.standard,
                alignment: Alignment.topCenter,
                child: _writing
                    ? const Padding(
                        key: ValueKey<String>('media-source-privacy-busy'),
                        padding: EdgeInsets.only(top: 4),
                        child: FushiLinearProgressIndicator(),
                      )
                    : const SizedBox(width: double.infinity),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  t.media_source_privacy_hint,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        adaptiveDialogAction(
          context: context,
          onPressed: _writing
              ? null
              : () => Navigator.of(context).pop(_changed ? _private : null),
          child: Text(t.dialog_close),
        ),
      ],
    );
  }
}
