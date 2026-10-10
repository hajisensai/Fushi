// 账户页：昵称、头像、可见性、上传开关、已登录设备（解绑）、导出 / 导入恢复码、仅本机
// 退出、删除账户。

import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_engine/leaderboard/leaderboard_client.dart';
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

  /// 输入框最近一次从服务端同步进来的昵称；输入框内容仍等于它 = 用户没编辑过，服务端
  /// 昵称变了（`self` 晚到 / 保存后）就跟着更新。
  String _syncedNickname = '';
  late final LeaderboardService _service;

  List<LeaderboardDevice>? _devices;
  Object? _devicesError;
  bool _devicesLoading = false;

  @override
  void initState() {
    super.initState();
    _service = ref.read(leaderboardServiceProvider);
    _syncNicknameFromSelf();
    _service.addListener(_syncNicknameFromSelf);
    unawaited(_loadDevices());
  }

  @override
  void dispose() {
    _service.removeListener(_syncNicknameFromSelf);
    _nickname.dispose();
    super.dispose();
  }

  void _syncNicknameFromSelf() {
    final String server = _service.self?.account.nickname ?? '';
    if (server == _syncedNickname) return;
    if (_nickname.text == _syncedNickname) _nickname.text = server;
    _syncedNickname = server;
  }

  Future<void> _loadDevices() async {
    final LeaderboardClient? client = _service.client;
    if (client == null) return;
    setState(() {
      _devicesLoading = true;
      _devicesError = null;
    });
    try {
      final List<LeaderboardDevice> devices = await client.devices();
      if (mounted) setState(() => _devices = devices);
    } catch (e, st) {
      ErrorLogService.instance.log('Leaderboard.devices', e, st);
      if (mounted) setState(() => _devicesError = e);
    } finally {
      if (mounted) setState(() => _devicesLoading = false);
    }
  }

  Future<void> _removeDevice(LeaderboardDevice device) async {
    final FushiDestructiveConfirmResult? ok =
        await showAppDialog<FushiDestructiveConfirmResult>(
          context: context,
          builder: (BuildContext _) => FushiDestructiveConfirmDialog(
            title: t.leaderboard_account_device_remove,
            message: t.leaderboard_account_device_remove_message(
              id: device.keyId,
            ),
            confirmLabel: t.leaderboard_account_device_remove,
            leadingIcon: FushiIcons.deviceRemove,
          ),
        );
    if (ok == null || !mounted) return;
    final LeaderboardClient? client = _service.client;
    if (client == null) return;
    final bool done = await _run(
      'removeDevice',
      () => client.removeDevice(device.keyId),
    );
    if (!done) return;
    FushiToast.show(msg: t.leaderboard_account_device_removed);
    await _loadDevices();
    // 解绑的可能是上传设备（服务端随之清空）：刷新「本机是否上传设备」。
    try {
      await _service.refreshSelf();
    } catch (e, st) {
      ErrorLogService.instance.log('Leaderboard.refreshSelf', e, st);
    }
  }

  Future<void> _setUpload(bool enabled) async {
    await _run('setUploadEnabled', () async {
      if (!enabled) return _service.setUploadEnabled(false);
      await runWithLeaderboardUploadConsent(
        context,
        _service,
        (bool consent) => _service.setUploadEnabled(true, consent: consent),
      );
    });
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
            leadingIcon: FushiIcons.key,
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
                FushiInlineNotice(
                  severity: FushiNoticeSeverity.warning,
                  message: t.leaderboard_recovery_export_warning,
                ),
                SizedBox(height: tokens.spacing.gap),
                SelectableText(code, style: tokens.type.metadata),
              ],
            ),
            footer: Wrap(
              alignment: WrapAlignment.end,
              spacing: tokens.spacing.gap,
              children: <Widget>[
                FushiDialogAction(
                  label: t.dialog_close,
                  onPressed: () => Navigator.pop(dialogContext),
                ),
                FushiDialogAction(
                  label: t.leaderboard_copy,
                  kind: FushiDialogActionKind.primary,
                  onPressed: () => unawaited(leaderboardCopy(code)),
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
            leadingIcon: FushiIcons.logout,
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

  List<Widget> _deviceRows() {
    final List<LeaderboardDevice>? devices = _devices;
    if (devices == null) {
      if (_devicesError != null) {
        return <Widget>[
          FushiListItem(
            leading: const FushiIcon(FushiIcons.cloudOff),
            title: Text(leaderboardErrorText(_devicesError!)),
            subtitleMaxLines: 3,
            onTap: () => unawaited(_loadDevices()),
          ),
        ];
      }
      return <Widget>[
        if (_devicesLoading) const FushiLinearProgressIndicator(),
      ];
    }
    return <Widget>[
      for (final LeaderboardDevice d in devices)
        FushiListItem(
          key: ValueKey<String>('leaderboard-device-${d.keyId}'),
          leading: FushiIcon(d.current ? FushiIcons.phone : FushiIcons.devices),
          title: Text(
            d.current
                ? '${d.keyId} · ${t.leaderboard_account_device_current}'
                : d.keyId,
          ),
          subtitle: Text(
            t.leaderboard_account_device_subtitle(
              created: leaderboardDate(d.createdAt),
              used: d.lastUsedAt == null
                  ? t.leaderboard_account_device_never_used
                  : leaderboardDateTime(d.lastUsedAt!),
            ),
          ),
          trailing: d.current
              ? null
              : ExcludeFocus(
                  child: FushiTextButton(
                    onPressed: _busy ? null : () => unawaited(_removeDevice(d)),
                    child: Text(t.leaderboard_account_device_remove),
                  ),
                ),
          onTap: d.current || _busy ? null : () => unawaited(_removeDevice(d)),
        ),
    ];
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
      body: Builder(
        builder: (BuildContext context) => ListView(
          // 正文铺到悬浮页头底下：顶部让出「状态栏 + 页头」（Builder 的
          // context 在页头脚手架之内才读得到这段 padding）。
          padding: withBottomSafeInset(
            context,
            EdgeInsets.fromLTRB(
              tokens.spacing.card,
              tokens.spacing.card + MediaQuery.paddingOf(context).top,
              tokens.spacing.card,
              tokens.spacing.card,
            ),
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
            if (_busy) const FushiLinearProgressIndicator(),
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
                      FushiOutlinedButton.icon(
                        onPressed: _busy
                            ? null
                            : () => unawaited(_pickAvatar()),
                        icon: const FushiIcon(FushiIcons.image),
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
                    child: FushiFilledButton.tonal(
                      onPressed: _busy
                          ? null
                          : () => unawaited(_saveNickname()),
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
              trailing: ExcludeFocus(
                child: FushiSwitch(
                  value: account?.uploadEnabled ?? false,
                  onChanged: _busy || account == null
                      ? null
                      : (bool v) => unawaited(_setUpload(v)),
                ),
              ),
              onTap: _busy || account == null
                  ? null
                  : () => unawaited(_setUpload(!account.uploadEnabled)),
            ),
            LeaderboardSectionTitle(t.leaderboard_account_devices),
            ..._deviceRows(),
            LeaderboardSectionTitle(t.leaderboard_account_recovery),
            FushiListItem(
              leading: const FushiIcon(FushiIcons.key),
              title: Text(t.leaderboard_recovery_export_title),
              subtitle: Text(t.leaderboard_recovery_export_hint),
              onTap: () => unawaited(_exportRecovery()),
            ),
            FushiListItem(
              leading: const FushiIcon(FushiIcons.download),
              title: Text(t.leaderboard_recovery_import_title),
              subtitle: Text(t.leaderboard_recovery_import_message),
              onTap: () =>
                  unawaited(showLeaderboardRecoveryImportDialog(context)),
            ),
            LeaderboardSectionTitle(t.leaderboard_account_danger),
            FushiListItem(
              leading: const FushiIcon(FushiIcons.logout),
              title: Text(t.leaderboard_account_sign_out),
              subtitle: Text(t.leaderboard_account_sign_out_message),
              onTap: _busy ? null : () => unawaited(_signOut()),
            ),
            FushiListItem(
              key: const ValueKey<String>('leaderboard-account-delete'),
              leading: FushiIcon(FushiIcons.delete, color: colors.error),
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
      ),
    );
  }
}
