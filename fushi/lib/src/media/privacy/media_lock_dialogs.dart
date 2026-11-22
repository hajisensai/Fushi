/// 上锁作品的解锁 / 口令对话框（拍板台 qiqSbvdxrk）。
///
/// - [unlockMediaLockSession]：验证机主（口令或系统验证）后让本次会话显示上锁的作品；
/// - [verifyMediaLockOwner]：只验证、不改会话状态（改 / 删口令前用）；
/// - [ensureMediaLockMethod]：上锁之前确保至少有一种解锁方式——系统验证不可用又
///   没设口令时，先让用户设口令，否则锁上就打不开；
/// - [changeMediaLockPasscode] / [removeMediaLockPasscode]：设置页的设 / 改 / 删口令。
///
/// 走哪条路都按 [MediaLockAuth] 的规则（见 `media_lock_auth.dart` 文件头）：没口令、
/// 没系统验证、却有上锁作品的设备上，不会出现「新设一个口令就能解锁」的后门。
library;

import 'dart:async';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/privacy/media_lock_auth.dart';
import 'package:fushi/src/media/privacy/media_visibility.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

/// 验证机主后解锁本次会话。已解锁时直接返回 true。
Future<bool> unlockMediaLockSession(
  BuildContext context,
  FushiDatabase db,
) async {
  if (MediaLockSession.instance.isUnlocked) return true;
  final bool ok = await verifyMediaLockOwner(
    context,
    db,
    title: t.media_lock_unlock_title,
  );
  if (ok) MediaLockSession.instance.unlock();
  return ok;
}

/// 验证机主（[MediaLockAuth.verifyOwnerPlan]）：设了口令就弹口令框（可改用系统
/// 验证）；没设口令时走系统验证；两样都没有时——本机没有上锁作品就直接放行（没有
/// 要保护的东西），有就拒绝并说明去哪里设口令。
Future<bool> verifyMediaLockOwner(
  BuildContext context,
  FushiDatabase db, {
  required String title,
}) async {
  final MediaLockAuth auth = MediaLockAuth.forDatabase(db);
  final MediaLockVerifyPlan plan;
  final bool deviceAvailable;
  try {
    plan = await auth.verifyOwnerPlan();
    deviceAvailable = await auth.device.isAvailable();
  } on Object catch (error) {
    _toastVerifyError(error);
    return false;
  }
  if (!context.mounted) return false;
  switch (plan) {
    case MediaLockVerifyPlan.nothingToProtect:
      return true;
    case MediaLockVerifyPlan.blocked:
      await _showBlockedDialog(
        context,
        title: t.media_lock_verify_blocked_title,
        body: t.media_lock_verify_blocked_body,
      );
      return false;
    case MediaLockVerifyPlan.device:
      return _runDeviceAuth(auth, title);
    case MediaLockVerifyPlan.passcode:
      final bool? ok = await showAppDialog<bool>(
        context: context,
        builder: (BuildContext _) => _MediaLockVerifyDialog(
          title: title,
          auth: auth,
          deviceAvailable: deviceAvailable,
        ),
      );
      return ok ?? false;
  }
}

void _toastVerifyError(Object error) => FushiToast.show(
  msg: t.media_lock_verify_failed(reason: error.toString()),
  severity: ToastSeverity.error,
);

Future<bool> _runDeviceAuth(MediaLockAuth auth, String reason) async {
  final DeviceOwnerAuthResult result;
  try {
    result = await auth.device.authenticate(reason);
  } on Object catch (error) {
    FushiToast.show(
      msg: t.media_lock_device_auth_failed(reason: error.toString()),
      severity: ToastSeverity.error,
    );
    return false;
  }
  if (result == DeviceOwnerAuthResult.unavailable) {
    FushiToast.show(
      msg: t.media_lock_device_auth_unavailable,
      severity: ToastSeverity.warning,
    );
  }
  if (result != DeviceOwnerAuthResult.success) return false;
  try {
    await auth.throttle.recordSuccess();
  } on Object catch (error) {
    // 清不掉冷却记录不影响这次验证结果，但要让用户知道下次可能还在冷却。
    _toastVerifyError(error);
  }
  return true;
}

Future<void> _showBlockedDialog(
  BuildContext context, {
  required String title,
  required String body,
}) => showAppDialog<void>(
  context: context,
  builder: (BuildContext dialogContext) => FushiAlertDialog(
    key: const ValueKey<String>('media-lock-blocked-dialog'),
    title: Text(title),
    content: SizedBox(width: 420, child: Text(body)),
    actions: <Widget>[
      adaptiveDialogAction(
        context: dialogContext,
        isDefaultAction: true,
        onPressed: () => Navigator.of(dialogContext).pop(),
        child: Text(t.dialog_ok),
      ),
    ],
  ),
);

/// 上锁之前调用：本机已有解锁方式 = true；否则按设口令的规则请用户设一个，设好 = true。
Future<bool> ensureMediaLockMethod(
  BuildContext context,
  FushiDatabase db,
) async {
  if (await MediaLockAuth.forDatabase(db).hasAnyMethod()) return true;
  if (!context.mounted) return false;
  return changeMediaLockPasscode(context, db);
}

/// 设 / 改口令（[MediaLockAuth.passcodeChangePlan]）：已有口令先验证机主；没口令但
/// 有上锁作品先过系统验证，系统验证不可用就拒绝；都没有直接设。设好返回 true。
Future<bool> changeMediaLockPasscode(
  BuildContext context,
  FushiDatabase db,
) async {
  final MediaLockAuth auth = MediaLockAuth.forDatabase(db);
  final MediaLockPasscodeChangePlan plan;
  try {
    plan = await auth.passcodeChangePlan();
  } on Object catch (error) {
    _toastVerifyError(error);
    return false;
  }
  if (!context.mounted) return false;
  switch (plan) {
    case MediaLockPasscodeChangePlan.blocked:
      await _showBlockedDialog(
        context,
        title: t.media_lock_verify_blocked_title,
        body: t.media_lock_verify_blocked_body,
      );
      return false;
    case MediaLockPasscodeChangePlan.verifyOwner:
      if (!await verifyMediaLockOwner(
        context,
        db,
        title: t.settings_media_lock_passcode,
      )) {
        return false;
      }
    case MediaLockPasscodeChangePlan.verifyDevice:
      if (!await _runDeviceAuth(auth, t.settings_media_lock_passcode)) {
        return false;
      }
    case MediaLockPasscodeChangePlan.free:
      break;
  }
  if (!context.mounted) return false;
  final bool? ok = await showAppDialog<bool>(
    context: context,
    builder: (BuildContext _) => _MediaLockPasscodeSetupDialog(auth: auth),
  );
  return ok ?? false;
}

/// 删口令（[MediaLockAuth.passcodeRemovalPlan]）：先验证机主、再确认；还有上锁作品
/// 而本机系统验证不可用时拒绝。删掉返回 true。
Future<bool> removeMediaLockPasscode(
  BuildContext context,
  FushiDatabase db,
) async {
  final MediaLockAuth auth = MediaLockAuth.forDatabase(db);
  final MediaLockPasscodeRemovalPlan plan;
  final bool hasLockedWorks;
  try {
    plan = await auth.passcodeRemovalPlan();
    hasLockedWorks = await auth.hasLockedWorks();
  } on Object catch (error) {
    _toastVerifyError(error);
    return false;
  }
  if (!context.mounted) return false;
  switch (plan) {
    case MediaLockPasscodeRemovalPlan.notSet:
      FushiToast.show(
        msg: t.media_lock_passcode_not_set,
        severity: ToastSeverity.info,
      );
      return false;
    case MediaLockPasscodeRemovalPlan.blockedByLockedWorks:
      await _showBlockedDialog(
        context,
        title: t.media_lock_passcode_remove_confirm_title,
        body: t.media_lock_passcode_remove_blocked,
      );
      return false;
    case MediaLockPasscodeRemovalPlan.allowed:
      break;
  }
  if (!context.mounted) return false;
  if (!await verifyMediaLockOwner(
    context,
    db,
    title: t.settings_media_lock_passcode_remove,
  )) {
    return false;
  }
  if (!context.mounted) return false;
  final bool confirmed = await showFushiConfirmDialog(
    context: context,
    title: t.media_lock_passcode_remove_confirm_title,
    message: hasLockedWorks
        ? t.media_lock_passcode_remove_confirm_locked_body
        : t.media_lock_passcode_remove_confirm_body,
    confirmLabel: t.media_lock_passcode_remove_action,
    icon: FushiIcons.key,
    destructive: true,
  );
  if (!confirmed) return false;
  try {
    await auth.passcode.clear();
  } on Object catch (error) {
    FushiToast.show(
      msg: t.media_lock_passcode_save_failed(reason: error.toString()),
      severity: ToastSeverity.error,
    );
    return false;
  }
  FushiToast.show(
    msg: t.media_lock_passcode_removed_toast,
    severity: ToastSeverity.success,
  );
  return true;
}

String _cooldownMessage(DateTime until) {
  final Duration left = until.difference(DateTime.now());
  final int seconds = left.inSeconds + 1;
  return seconds > 90
      ? t.media_lock_passcode_cooldown_minutes(minutes: (seconds / 60).ceil())
      : t.media_lock_passcode_cooldown(seconds: seconds);
}

class _MediaLockVerifyDialog extends StatefulWidget {
  const _MediaLockVerifyDialog({
    required this.title,
    required this.auth,
    required this.deviceAvailable,
  });

  final String title;
  final MediaLockAuth auth;
  final bool deviceAvailable;

  @override
  State<_MediaLockVerifyDialog> createState() => _MediaLockVerifyDialogState();
}

class _MediaLockVerifyDialogState extends State<_MediaLockVerifyDialog> {
  final TextEditingController _passcode = TextEditingController();
  String? _error;

  /// 读冷却状态之前也算忙（不让人在状态未知时提交）。
  bool _busy = true;
  DateTime? _coolingUntil;
  Timer? _cooldownTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_loadCooldown());
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _passcode.dispose();
    super.dispose();
  }

  Future<void> _loadCooldown() async {
    DateTime? until;
    String? error;
    try {
      until = await widget.auth.throttle.coolingUntil();
    } on Object catch (e) {
      error = t.media_lock_verify_failed(reason: e.toString());
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error ?? (until == null ? null : _cooldownMessage(until));
    });
    _armCooldown(until);
  }

  bool get _coolingDown {
    final DateTime? until = _coolingUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  void _armCooldown(DateTime? until) {
    _cooldownTimer?.cancel();
    _coolingUntil = until;
    if (until == null) return;
    final Duration left = until.difference(DateTime.now());
    if (left.isNegative) return;
    _cooldownTimer = Timer(left, () {
      if (mounted) setState(() => _error = null);
    });
  }

  Future<void> _submit() async {
    if (_busy || _coolingDown) return;
    setState(() => _busy = true);
    final bool ok;
    DateTime? cooldownUntil;
    try {
      ok = await widget.auth.passcode.verify(_passcode.text);
      if (ok) {
        await widget.auth.throttle.recordSuccess();
      } else {
        final Duration? cooldown = await widget.auth.throttle.recordFailure();
        if (cooldown != null) cooldownUntil = DateTime.now().add(cooldown);
      }
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = t.media_lock_verify_failed(reason: e.toString());
      });
      return;
    }
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }
    _armCooldown(cooldownUntil);
    setState(() {
      _busy = false;
      _error = cooldownUntil == null
          ? t.media_lock_passcode_wrong
          : _cooldownMessage(cooldownUntil);
      _passcode.clear();
    });
  }

  Future<void> _useDevice() async {
    setState(() => _busy = true);
    final bool ok = await _runDeviceAuth(widget.auth, widget.title);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final bool cooling = _coolingDown;
    return FushiAlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(t.media_lock_unlock_hint, style: text.bodyMedium),
            const SizedBox(height: 12),
            FushiTextField(
              key: const ValueKey<String>('media-lock-passcode-field'),
              controller: _passcode,
              autofocus: true,
              obscureText: true,
              enabled: !_busy && !cooling,
              labelText: t.media_lock_passcode_label,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => unawaited(_submit()),
            ),
            FushiAnimatedSize(
              duration: fushiMotionDuration(context, FushiMotion.short),
              curve: FushiMotion.standard,
              alignment: Alignment.topCenter,
              child: _error == null
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      key: const ValueKey<String>('media-lock-passcode-error'),
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        _error!,
                        style: text.bodyMedium?.copyWith(color: cs.error),
                      ),
                    ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        adaptiveDialogAction(
          context: context,
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(t.dialog_cancel),
        ),
        if (widget.deviceAvailable)
          adaptiveDialogAction(
            context: context,
            onPressed: _busy ? null : () => unawaited(_useDevice()),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const FushiIcon(FushiIcons.fingerprint, size: 18),
                const SizedBox(width: 6),
                Text(t.media_lock_use_device_auth),
              ],
            ),
          ),
        adaptiveDialogAction(
          context: context,
          isDefaultAction: true,
          onPressed: _busy || cooling ? null : () => unawaited(_submit()),
          child: Text(t.media_lock_unlock_action),
        ),
      ],
    );
  }
}

class _MediaLockPasscodeSetupDialog extends StatefulWidget {
  const _MediaLockPasscodeSetupDialog({required this.auth});

  final MediaLockAuth auth;

  @override
  State<_MediaLockPasscodeSetupDialog> createState() =>
      _MediaLockPasscodeSetupDialogState();
}

class _MediaLockPasscodeSetupDialogState
    extends State<_MediaLockPasscodeSetupDialog> {
  final TextEditingController _first = TextEditingController();
  final TextEditingController _second = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _first.dispose();
    _second.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    final String a = _first.text;
    if (a.length < kMediaLockPasscodeMinLength) {
      setState(
        () => _error = t.media_lock_passcode_too_short(
          count: kMediaLockPasscodeMinLength,
        ),
      );
      return;
    }
    if (a != _second.text) {
      setState(() => _error = t.media_lock_passcode_mismatch);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.auth.passcode.set(a);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = t.media_lock_passcode_save_failed(reason: error.toString());
      });
      return;
    }
    if (!mounted) return;
    FushiToast.show(
      msg: t.media_lock_passcode_saved_toast,
      severity: ToastSeverity.success,
    );
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    return FushiAlertDialog(
      title: Text(t.media_lock_passcode_setup_title),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              t.media_lock_passcode_setup_synced_hint,
              style: text.bodyMedium,
            ),
            const SizedBox(height: 12),
            FushiTextField(
              key: const ValueKey<String>('media-lock-passcode-new'),
              controller: _first,
              autofocus: true,
              obscureText: true,
              enabled: !_busy,
              labelText: t.media_lock_passcode_new_label,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 8),
            FushiTextField(
              key: const ValueKey<String>('media-lock-passcode-confirm'),
              controller: _second,
              obscureText: true,
              enabled: !_busy,
              labelText: t.media_lock_passcode_confirm_label,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => unawaited(_save()),
            ),
            FushiAnimatedSize(
              duration: fushiMotionDuration(context, FushiMotion.short),
              curve: FushiMotion.standard,
              alignment: Alignment.topCenter,
              child: _error == null
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      key: const ValueKey<String>('media-lock-passcode-error'),
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        _error!,
                        style: text.bodyMedium?.copyWith(color: cs.error),
                      ),
                    ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        adaptiveDialogAction(
          context: context,
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(t.dialog_cancel),
        ),
        adaptiveDialogAction(
          context: context,
          isDefaultAction: true,
          onPressed: _busy ? null : () => unawaited(_save()),
          child: Text(t.media_lock_passcode_save_action),
        ),
      ],
    );
  }
}
