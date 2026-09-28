// 账户页：昵称、头像、可见性、上传开关、导出 / 导入恢复码、仅本机退出、删除账户。

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/leaderboard/leaderboard_models.dart';

import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi/src/leaderboard/leaderboard_store.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_common.dart';
import 'package:fushi/utils.dart';

/// 可见性线上值。
const String kLeaderboardVisibilityPublic = 'public';
const String kLeaderboardVisibilityFriends = 'friends';

class LeaderboardAccountPage extends ConsumerStatefulWidget {
  const LeaderboardAccountPage({super.key});

  @override
  ConsumerState<LeaderboardAccountPage> createState() =>
      _LeaderboardAccountPageState();
}

class _LeaderboardAccountPageState
    extends ConsumerState<LeaderboardAccountPage> {
  final TextEditingController _nickname = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nickname.text =
        ref.read(leaderboardServiceProvider).self?.account.nickname ?? '';
  }

  @override
  void dispose() {
    _nickname.dispose();
    super.dispose();
  }

  /// 跑一个账户操作：忙碌态 + 错误就地显示。成功返回 true。
  Future<bool> _run(String what, Future<void> Function() op) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await op();
      return true;
    } catch (e, st) {
      ErrorLogService.instance.log('Leaderboard.$what', e, st);
      if (mounted) setState(() => _error = leaderboardErrorText(e));
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveNickname() async {
    final String nick = _nickname.text.trim();
    final int len = nick.runes.length;
    if (len < 1 || len > 24) {
      setState(() => _error = t.leaderboard_error_bad_nickname);
      return;
    }
    final bool ok = await _run(
      'updateNickname',
      () => ref.read(leaderboardServiceProvider).updateProfile(nickname: nick),
    );
    if (ok) FushiToast.show(msg: t.leaderboard_account_saved);
  }

  Future<void> _pickAvatar() async {
    final File? file = await pickGalleryImageFile();
    if (file == null) return;
    final bool ok = await _run(
      'setAvatar',
      () => ref.read(leaderboardServiceProvider).setAvatarFromFile(file.path),
    );
    if (ok) FushiToast.show(msg: t.leaderboard_account_saved);
  }

  Future<void> _exportRecovery() async {
    final String code;
    try {
      code = ref.read(leaderboardServiceProvider).exportRecoveryCode();
    } on StateError catch (e, st) {
      ErrorLogService.instance.log('Leaderboard.exportRecovery', e, st);
      return;
    }
    await showAppDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        final FushiDesignTokens tokens = FushiDesignTokens.of(dialogContext);
        return FushiDialogFrame(
          child: FushiModalSheetFrame(
            title: t.leaderboard_recovery_export_title,
            leadingIcon: Icons.key_outlined,
            bodyPadding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              0,
              tokens.spacing.card,
              tokens.spacing.gap,
            ),
            body: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  t.leaderboard_recovery_export_warning,
                  style: tokens.type.listSubtitle.copyWith(
                    color: Theme.of(dialogContext).colorScheme.error,
                  ),
                ),
                SizedBox(height: tokens.spacing.gap),
                SelectableText(code, style: tokens.type.metadata),
              ],
            ),
            footer: Wrap(
              alignment: WrapAlignment.end,
              spacing: tokens.spacing.gap,
              children: <Widget>[
                adaptiveDialogAction(
                  context: dialogContext,
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(t.dialog_close),
                ),
                adaptiveDialogAction(
                  context: dialogContext,
                  isDefaultAction: true,
                  onPressed: () => unawaited(leaderboardCopy(code)),
                  child: Text(t.leaderboard_copy),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _signOut() async {
    final FushiDestructiveConfirmResult? ok =
        await showAppDialog<FushiDestructiveConfirmResult>(
          context: context,
          builder: (BuildContext _) => FushiDestructiveConfirmDialog(
            title: t.leaderboard_account_sign_out,
            message: t.leaderboard_account_sign_out_message,
            confirmLabel: t.leaderboard_account_sign_out,
            leadingIcon: Icons.logout,
          ),
        );
    if (ok == null || !mounted) return;
    final bool done = await _run(
      'signOutLocally',
      () => ref.read(leaderboardServiceProvider).signOutLocally(),
    );
    if (done && mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final FushiDestructiveConfirmResult? ok =
        await showAppDialog<FushiDestructiveConfirmResult>(
          context: context,
          builder: (BuildContext _) => FushiDestructiveConfirmDialog(
            title: t.leaderboard_account_delete,
            message: t.leaderboard_account_delete_message,
            checkboxLabel: t.leaderboard_account_delete_confirm,
            requireCheckboxToConfirm: true,
            confirmLabel: t.leaderboard_account_delete,
          ),
        );
    if (ok == null || !mounted) return;
    final bool done = await _run(
      'deleteAccount',
      () => ref.read(leaderboardServiceProvider).deleteAccount(),
    );
    if (done && mounted) {
      FushiToast.show(msg: t.leaderboard_account_deleted);
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final LeaderboardService service = ref.watch(leaderboardServiceProvider);
    final LeaderboardSelf? self = service.self;
    final LeaderboardLocalAccount? account = service.account;
    final String visibility = self?.visibility ?? kLeaderboardVisibilityPublic;
    return FushiPageScaffold(
      title: t.leaderboard_account_title,
      body: ListView(
        padding: withBottomSafeInset(
          context,
          EdgeInsets.all(tokens.spacing.card),
        ),
        children: <Widget>[
          if (_error != null)
            Padding(
              padding: EdgeInsets.only(bottom: tokens.spacing.gap),
              child: Text(
                _error!,
                key: const ValueKey<String>('leaderboard-account-error'),
                style: tokens.type.listSubtitle.copyWith(color: colors.error),
              ),
            ),
          if (_busy) const LinearProgressIndicator(),
          FushiCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    if (self != null)
                      LeaderboardAvatar(account: self.account, size: 56),
                    SizedBox(width: tokens.spacing.card),
                    Expanded(
                      child: Text(
                        self?.account.tag ?? '',
                        style: tokens.type.listTitle,
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => unawaited(_pickAvatar()),
                      icon: const Icon(Icons.image_outlined),
                      label: Text(t.leaderboard_account_avatar),
                    ),
                  ],
                ),
                SizedBox(height: tokens.spacing.card),
                FushiTextField(
                  controller: _nickname,
                  labelText: t.leaderboard_signin_nickname,
                  onSubmitted: (String _) => unawaited(_saveNickname()),
                ),
                SizedBox(height: tokens.spacing.gap),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonal(
                    onPressed: _busy ? null : () => unawaited(_saveNickname()),
                    child: Text(t.leaderboard_account_save_nickname),
                  ),
                ),
              ],
            ),
          ),
          LeaderboardSectionTitle(t.leaderboard_account_visibility),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: tokens.spacing.card),
            child: LeaderboardChoiceRow<String>(
              values: const <String>[
                kLeaderboardVisibilityPublic,
                kLeaderboardVisibilityFriends,
              ],
              selected: visibility,
              labelOf: (String v) => v == kLeaderboardVisibilityPublic
                  ? t.leaderboard_account_visibility_public
                  : t.leaderboard_account_visibility_friends,
              onSelected: (String v) {
                if (_busy || v == visibility) return;
                unawaited(
                  _run(
                    'updateVisibility',
                    () => service.updateProfile(visibility: v),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              tokens.spacing.gap,
              tokens.spacing.card,
              0,
            ),
            child: Text(
              t.leaderboard_account_visibility_hint,
              style: tokens.type.metadata,
            ),
          ),
          SizedBox(height: tokens.spacing.card),
          FushiListItem(
            key: const ValueKey<String>('leaderboard-account-upload'),
            title: Text(t.leaderboard_account_upload),
            subtitle: Text(t.leaderboard_account_upload_hint),
            subtitleMaxLines: 3,
            trailing: Switch(
              value: account?.uploadEnabled ?? false,
              onChanged: _busy || account == null
                  ? null
                  : (bool v) => unawaited(
                      _run(
                        'setUploadEnabled',
                        () => service.setUploadEnabled(v),
                      ),
                    ),
            ),
            onTap: _busy || account == null
                ? null
                : () => unawaited(
                    _run(
                      'setUploadEnabled',
                      () => service.setUploadEnabled(!account.uploadEnabled),
                    ),
                  ),
          ),
          LeaderboardSectionTitle(t.leaderboard_account_recovery),
          FushiListItem(
            leading: const Icon(Icons.key_outlined),
            title: Text(t.leaderboard_recovery_export_title),
            subtitle: Text(t.leaderboard_recovery_export_hint),
            onTap: () => unawaited(_exportRecovery()),
          ),
          FushiListItem(
            leading: const Icon(Icons.download_outlined),
            title: Text(t.leaderboard_recovery_import_title),
            subtitle: Text(t.leaderboard_recovery_import_message),
            onTap: () =>
                unawaited(showLeaderboardRecoveryImportDialog(context)),
          ),
          LeaderboardSectionTitle(t.leaderboard_account_danger),
          FushiListItem(
            leading: const Icon(Icons.logout),
            title: Text(t.leaderboard_account_sign_out),
            subtitle: Text(t.leaderboard_account_sign_out_message),
            onTap: _busy ? null : () => unawaited(_signOut()),
          ),
          FushiListItem(
            key: const ValueKey<String>('leaderboard-account-delete'),
            leading: Icon(Icons.delete_forever_outlined, color: colors.error),
            title: Text(
              t.leaderboard_account_delete,
              style: TextStyle(color: colors.error),
            ),
            subtitle: Text(t.leaderboard_account_delete_message),
            subtitleMaxLines: 3,
            onTap: _busy ? null : () => unawaited(_delete()),
          ),
        ],
      ),
    );
  }
}
