// 排行榜同步状态卡：上次同步时间 + 立即同步、上传设备在别处时的「接管」、书架
// 超限提示与同步错误。2026-10-09 从排行榜主页挪进账户（排行榜设置）页，主页只留
// 榜单本身。

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';

import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/leaderboard/leaderboard_store.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_common.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

class LeaderboardSyncPanel extends ConsumerStatefulWidget {
  const LeaderboardSyncPanel({this.initialError, super.key});

  /// 进页前（排行榜页的后台同步）已经出的错，先显示出来。
  final Object? initialError;

  @override
  ConsumerState<LeaderboardSyncPanel> createState() =>
      _LeaderboardSyncPanelState();
}

class _LeaderboardSyncPanelState extends ConsumerState<LeaderboardSyncPanel> {
  bool _syncing = false;
  late Object? _syncError = widget.initialError;

  Future<void> _syncNow() async {
    setState(() {
      _syncing = true;
      _syncError = null;
    });
    try {
      await ref.read(leaderboardServiceProvider).syncNow();
    } catch (e, st) {
      ErrorLogService.instance.log('Leaderboard.syncNow', e, st);
      if (mounted) setState(() => _syncError = e);
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _claim() async {
    final FushiDestructiveConfirmResult? ok =
        await showAppDialog<FushiDestructiveConfirmResult>(
          context: context,
          builder: (BuildContext _) => FushiDestructiveConfirmDialog(
            title: t.leaderboard_sync_claim_title,
            message: t.leaderboard_sync_claim_message,
            confirmLabel: t.leaderboard_sync_claim_action,
            leadingIcon: FushiIcons.swap,
          ),
        );
    if (ok == null || !mounted) return;
    final LeaderboardService service = ref.read(leaderboardServiceProvider);
    // 登录 / 导入时没同意公开的本机账户：接管前先确认公开清单。
    final bool consent =
        !service.hasConsent &&
        await showLeaderboardUploadConsentDialog(context);
    if (!service.hasConsent && !consent) return;
    if (!mounted) return;
    setState(() {
      _syncing = true;
      _syncError = null;
    });
    try {
      await service.claimUploadDevice(consent: consent);
    } catch (e, st) {
      ErrorLogService.instance.log('Leaderboard.claimUploadDevice', e, st);
      if (mounted) setState(() => _syncError = e);
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final LeaderboardService service = ref.watch(leaderboardServiceProvider);
    final LeaderboardLocalAccount? account = service.account;
    final int? last = account?.lastSyncAt;
    final String status = account != null && !account.uploadEnabled
        ? t.leaderboard_sync_upload_off
        : (last == null
              ? t.leaderboard_sync_never
              : t.leaderboard_sync_last(time: leaderboardDateTime(last)));
    final bool blockedElsewhere = service.isUploadDevice == false;
    return FushiCard(
      key: const ValueKey<String>('leaderboard-sync-panel'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const FushiIcon(FushiIcons.cloudSync, size: 20),
              SizedBox(width: tokens.spacing.gap),
              Expanded(
                child: Text(
                  status,
                  key: const ValueKey<String>('leaderboard-sync-status'),
                  style: tokens.type.listSubtitle,
                ),
              ),
              FushiTextButton(
                key: const ValueKey<String>('leaderboard-sync-now'),
                onPressed:
                    _syncing ||
                        blockedElsewhere ||
                        account?.uploadEnabled != true
                    ? null
                    : () => unawaited(_syncNow()),
                child: _syncing
                    ? const SizedBox.square(
                        dimension: 16,
                        child: FushiCircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(t.leaderboard_sync_now),
              ),
            ],
          ),
          if (blockedElsewhere) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            Text(
              t.leaderboard_sync_owned_elsewhere,
              key: const ValueKey<String>('leaderboard-sync-elsewhere'),
              style: tokens.type.listSubtitle,
            ),
            SizedBox(height: tokens.spacing.gap),
            FushiFilledButton.tonalIcon(
              key: const ValueKey<String>('leaderboard-sync-claim'),
              onPressed: _syncing ? null : () => unawaited(_claim()),
              icon: const FushiIcon(FushiIcons.swap),
              label: Text(t.leaderboard_sync_claim_action),
            ),
          ],
          if ((service.droppedForShelfLimit ?? 0) > 0) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            Text(
              t.leaderboard_sync_shelf_limit(
                limit: kLeaderboardMaxShelfRows,
                count: service.droppedForShelfLimit!,
              ),
              key: const ValueKey<String>('leaderboard-sync-shelf-limit'),
              style: tokens.type.listSubtitle,
            ),
          ],
          if (_syncError != null) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            Text(
              leaderboardSyncErrorText(_syncError!),
              key: const ValueKey<String>('leaderboard-sync-error'),
              style: tokens.type.metadata.copyWith(color: colors.error),
            ),
          ],
        ],
      ),
    );
  }
}
