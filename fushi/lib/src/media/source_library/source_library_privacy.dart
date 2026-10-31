/// 来源库（扫描根）的「隐私」开关（schema v140 `media_sources.is_private`，反馈
/// kEAgATi1LF：「某个文件夹想放点 nsfw 的，但不想让它上排行榜」）。
///
/// 开关只写 `media_sources.is_private` 一列；「私密」的效果由
/// `fushi_engine/privacy/media_privacy.dart` 的 [MediaPrivacySnapshot] 统一实现——
/// 隐私来源产出的书 / 漫画 / 视频与作品级私密标记同一口径：排行榜书架构建
/// （`buildLocalShelf`，书架条目 + 封面投票的唯一来源）跳过它们，Bangumi 追踪也跳过。
///
/// 打开开关时立即跑一次排行榜同步，把已经上报过的条目从服务端撤下（书架同步对
/// 「本地已消失」的作品发 remove）；不等下一轮 30 分钟的后台同步。
library;

import 'dart:async';

import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:material_ui/material_ui.dart';

/// 一次拨动隐私开关的结果。
enum SourceLibraryPrivacyOutcome {
  /// 打开了，并已立即同步、从排行榜撤下已上报的条目。
  privateWithdrawn,

  /// 打开了；排行榜不需要撤（没开排行榜 / 上传关着 / 本机不是上传设备）。
  privateLocalOnly,

  /// 打开了，但立即撤下的那次同步失败（[SourceLibraryPrivacyResult.error]）；
  /// 条目已不在书架里，下一轮后台同步会再撤。
  privateWithdrawFailed,

  /// 关掉了（条目在下一轮排行榜同步时照常上传）。
  cleared,
}

class SourceLibraryPrivacyResult {
  const SourceLibraryPrivacyResult(this.outcome, [this.error]);

  final SourceLibraryPrivacyOutcome outcome;

  /// [SourceLibraryPrivacyOutcome.privateWithdrawFailed] 时的同步错误。
  final Object? error;
}

/// 设置来源 [sourceId] 的隐私开关。打开时随后调 [withdrawFromLeaderboard]（生产里
/// 是 `LeaderboardService.syncAfterPrivacyChange`：返回是否真的同步了）把已上报的
/// 条目从服务端撤下。落库失败直接抛（开关没变，调用方必须明说）；撤下失败不回滚
/// 开关——私密已经生效（书架里不再有这些条目），只是服务端那份要等下一轮同步。
Future<SourceLibraryPrivacyResult> setSourceLibraryPrivate({
  required FushiDatabase db,
  required int sourceId,
  required bool isPrivate,
  required Future<bool> Function() withdrawFromLeaderboard,
}) async {
  await db.updateMediaSourcePrivate(sourceId, isPrivate);
  if (!isPrivate) {
    return const SourceLibraryPrivacyResult(
      SourceLibraryPrivacyOutcome.cleared,
    );
  }
  try {
    final bool synced = await withdrawFromLeaderboard();
    return SourceLibraryPrivacyResult(
      synced
          ? SourceLibraryPrivacyOutcome.privateWithdrawn
          : SourceLibraryPrivacyOutcome.privateLocalOnly,
    );
  } on Object catch (error) {
    return SourceLibraryPrivacyResult(
      SourceLibraryPrivacyOutcome.privateWithdrawFailed,
      error,
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

  Future<void> _set(bool value) async {
    setState(() => _writing = true);
    try {
      final SourceLibraryPrivacyResult result = await setSourceLibraryPrivate(
        db: widget.db,
        sourceId: widget.source.id,
        isPrivate: value,
        withdrawFromLeaderboard: widget.withdrawFromLeaderboard,
      );
      if (mounted) {
        setState(() {
          _private = value;
          _changed = true;
        });
      }
      switch (result.outcome) {
        case SourceLibraryPrivacyOutcome.privateWithdrawn:
          FushiToast.show(
            msg: t.media_source_privacy_withdrawn_toast,
            severity: ToastSeverity.success,
          );
        case SourceLibraryPrivacyOutcome.privateLocalOnly:
          FushiToast.show(
            msg: t.media_source_privacy_marked_toast,
            severity: ToastSeverity.success,
          );
        case SourceLibraryPrivacyOutcome.privateWithdrawFailed:
          // 私密已生效，但服务端那份还在：必须明说，不能报成功。
          FushiToast.show(
            msg: t.media_source_privacy_withdraw_failed(
              reason: result.error.toString(),
            ),
            severity: ToastSeverity.error,
          );
        case SourceLibraryPrivacyOutcome.cleared:
          FushiToast.show(
            msg: t.media_source_privacy_cleared_toast,
            severity: ToastSeverity.success,
          );
      }
    } on Object catch (error) {
      // 落库失败：开关保持原状态并明说——用户以为已经藏起来了、其实下一轮照常上传，
      // 正是这个开关要防的事。
      FushiToast.show(
        msg: t.media_privacy_save_failed(reason: error.toString()),
        severity: ToastSeverity.error,
      );
    } finally {
      if (mounted) setState(() => _writing = false);
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
