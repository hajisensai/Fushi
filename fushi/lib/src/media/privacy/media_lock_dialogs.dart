/// 上锁作品的解锁 / 口令对话框（拍板台 qiqSbvdxrk）。
///
/// - [unlockMediaLockSession]：验证机主（口令或系统验证）后让本次会话显示上锁的作品；
/// - [verifyMediaLockOwner]：只验证、不改会话状态（改 / 清口令前用）；
/// - [ensureMediaLockMethod]：上锁之前确保本机至少有一种解锁方式——系统验证不可用
///   又没设口令时，先让用户设口令，否则锁上就打不开。
library;

import 'dart:async';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/privacy/media_lock_auth.dart';
import 'package:fushi/src/media/privacy/media_visibility.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:material_ui/material_ui.dart';

/// 连续输错这么多次后冷却 [_cooldown]（系统验证不受限）。
const int _maxFailuresBeforeCooldown = 5;
const Duration _cooldown = Duration(seconds: 30);

int _failures = 0;
DateTime? _cooldownUntil;

/// 测试复位用。
@visibleForTesting
void resetMediaLockThrottleForTest() {
  _failures = 0;
  _cooldownUntil = null;
}

/// 验证机主后解锁本次会话。已解锁时直接返回 true。
Future<bool> unlockMediaLockSession(BuildContext context) async {
  if (MediaLockSession.instance.isUnlocked) return true;
  final bool ok = await verifyMediaLockOwner(
    context,
    title: t.media_lock_unlock_title,
  );
  if (ok) MediaLockSession.instance.unlock();
  return ok;
}

/// 验证机主：设了口令就弹口令框（可改用系统验证）；没设口令时直接走系统验证；
/// 两样都没有（上锁标记从别的设备同步过来、本机从没设过口令）时请用户先设一个口令。
Future<bool> verifyMediaLockOwner(
  BuildContext context, {
  required String title,
}) async {
  final MediaLockAuth auth = MediaLockAuth.instance;
  final bool hasPasscode = await auth.passcode.isSet();
  final bool deviceAvailable = await auth.device.isAvailable();
  if (!context.mounted) return false;
  if (!hasPasscode && deviceAvailable) {
    return _runDeviceAuth(auth, title);
  }
  if (!hasPasscode) {
    return showMediaLockPasscodeSetupDialog(context);
  }
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
  return result == DeviceOwnerAuthResult.success;
}

/// 上锁之前调用：本机已有解锁方式 = true；否则请用户设口令，设好 = true。
Future<bool> ensureMediaLockMethod(BuildContext context) async {
  if (await MediaLockAuth.instance.hasAnyMethod()) return true;
  if (!context.mounted) return false;
  return showMediaLockPasscodeSetupDialog(context);
}

/// 设 / 改口令（调用方负责先 [verifyMediaLockOwner]）。设好返回 true。
Future<bool> showMediaLockPasscodeSetupDialog(BuildContext context) async {
  final bool? ok = await showAppDialog<bool>(
    context: context,
    builder: (BuildContext _) =>
        _MediaLockPasscodeSetupDialog(auth: MediaLockAuth.instance),
  );
  return ok ?? false;
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
  bool _busy = false;
  Timer? _cooldownTimer;

  @override
  void initState() {
    super.initState();
    _scheduleCooldownTick();
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _passcode.dispose();
    super.dispose();
  }

  bool get _coolingDown {
    final DateTime? until = _cooldownUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  void _scheduleCooldownTick() {
    _cooldownTimer?.cancel();
    final DateTime? until = _cooldownUntil;
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
    final bool ok = await widget.auth.passcode.verify(_passcode.text);
    if (!mounted) return;
    if (ok) {
      _failures = 0;
      Navigator.of(context).pop(true);
      return;
    }
    _failures++;
    String error = t.media_lock_passcode_wrong;
    if (_failures >= _maxFailuresBeforeCooldown) {
      _failures = 0;
      _cooldownUntil = DateTime.now().add(_cooldown);
      error = t.media_lock_passcode_cooldown(seconds: _cooldown.inSeconds);
      _scheduleCooldownTick();
    }
    setState(() {
      _busy = false;
      _error = error;
      _passcode.clear();
    });
  }

  Future<void> _useDevice() async {
    setState(() => _busy = true);
    final bool ok = await _runDeviceAuth(widget.auth, widget.title);
    if (!mounted) return;
    if (ok) {
      _failures = 0;
      _cooldownUntil = null;
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
            Text(t.media_lock_passcode_setup_hint, style: text.bodyMedium),
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
