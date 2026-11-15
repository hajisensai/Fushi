import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/shortcuts/global_hotkey_backend.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_labels.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_inline_notice.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// Keyboard view of the app-outside (`globalExternal`) shortcuts on a Linux
/// Wayland desktop, replacing the in-app key recorder there.
///
/// On Wayland the desktop owns these bindings (GlobalShortcuts portal): what
/// the user recorded in Fushi was only ever a hint for the first bind, and
/// later changes happen in the desktop's settings. So this panel shows the
/// trigger the **desktop** reports for each action, says why hotkeys are not
/// working when they are not (no portal, dialog dismissed, …), and offers
/// "change in system settings" / "bind again" instead of a recorder that would
/// write a key nobody listens to.
class GlobalHotKeyPortalPanel extends StatelessWidget {
  const GlobalHotKeyPortalPanel({
    super.key,
    required this.status,
    required this.actions,
    required this.availableHere,
    required this.onRebind,
    required this.onConfigure,
  });

  /// The controller's hotkey status (`GlobalLookupController.hotKeyStatus`).
  final ValueListenable<GlobalHotKeyStatus?> status;

  /// The `globalExternal` actions, in settings order.
  final List<ShortcutAction> actions;

  /// Whether the action is declared to the portal in this session (screen OCR
  /// needs the lookup card overlay, which a Wayland session may lack).
  final bool Function(ShortcutAction action) availableHere;

  final Future<void> Function() onRebind;

  /// Returns false when the desktop cannot open its shortcut editor.
  final Future<bool> Function() onConfigure;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<GlobalHotKeyStatus?>(
      valueListenable: status,
      builder: (BuildContext context, GlobalHotKeyStatus? value, Widget? _) {
        final FushiDesignTokens tokens = FushiDesignTokens.of(context);
        final GlobalHotKeyStatus current =
            value ??
            const GlobalHotKeyStatus.idle(GlobalHotKeyBackendKind.portal);
        final Widget? problem = _problemNotice(context, current);
        int index = 0;
        return Column(
          key: const ValueKey<String>('global-hotkey-portal-panel'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            AdaptiveSettingsRow(
              title: t.shortcut_portal_note,
              icon: FushiIcons.info,
              showIcon: true,
              titleMaxLines: 4,
            ),
            if (problem != null)
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: tokens.spacing.rowHorizontal,
                  vertical: tokens.spacing.gap / 2,
                ),
                child: problem,
              ),
            if (current.problem != GlobalHotKeyProblem.portalMissing)
              for (final ShortcutAction action in actions)
                FushiStaggeredEntrance(
                  key: ValueKey<String>('global-hotkey-portal-${action.name}'),
                  index: index++,
                  child: AdaptiveSettingsRow(
                    title: action.label,
                    subtitle: _triggerText(action, current),
                    icon: FushiIcons.keyboard,
                    showIcon: true,
                  ),
                ),
            if (current.problem != GlobalHotKeyProblem.portalMissing &&
                current.problem != GlobalHotKeyProblem.portalNeedsAppId)
              _configureRow(context, current),
          ],
        );
      },
    );
  }

  String _triggerText(ShortcutAction action, GlobalHotKeyStatus status) {
    if (!availableHere(action)) return t.shortcut_portal_trigger_unavailable;
    final String? trigger = status.triggers[action.key];
    if (trigger != null) {
      return trigger.isEmpty ? t.shortcut_portal_trigger_unassigned : trigger;
    }
    if (!status.bound && status.problem == null) {
      return t.shortcut_portal_trigger_pending;
    }
    return t.shortcut_portal_trigger_unbound;
  }

  Widget? _problemNotice(BuildContext context, GlobalHotKeyStatus status) {
    final GlobalHotKeyProblem? problem = status.problem;
    if (problem == null) return null;
    final String message = switch (problem) {
      GlobalHotKeyProblem.portalMissing => t.shortcut_portal_missing,
      GlobalHotKeyProblem.portalNeedsAppId => t.shortcut_portal_needs_app_id,
      GlobalHotKeyProblem.dialogCancelled => t.shortcut_portal_cancelled,
      GlobalHotKeyProblem.portalFailed => t.shortcut_portal_failed,
      GlobalHotKeyProblem.sessionClosed => t.shortcut_portal_session_closed,
    };
    final bool canRebind =
        problem == GlobalHotKeyProblem.dialogCancelled ||
        problem == GlobalHotKeyProblem.portalFailed ||
        problem == GlobalHotKeyProblem.sessionClosed;
    return FushiInlineNotice(
      key: ValueKey<String>('global-hotkey-portal-problem-${problem.name}'),
      severity: problem == GlobalHotKeyProblem.dialogCancelled
          ? FushiNoticeSeverity.info
          : FushiNoticeSeverity.warning,
      message: message,
      actions: <Widget>[
        if (canRebind)
          FushiTextButton(
            key: const ValueKey<String>('global-hotkey-portal-rebind'),
            onPressed: () => unawaited(onRebind()),
            child: Text(t.shortcut_portal_rebind),
          ),
      ],
    );
  }

  Widget _configureRow(BuildContext context, GlobalHotKeyStatus status) {
    if (!status.canConfigure) {
      return AdaptiveSettingsRow(
        key: const ValueKey<String>('global-hotkey-portal-configure-hint'),
        title: t.shortcut_portal_configure_hint,
        icon: FushiIcons.settings,
        showIcon: true,
        titleMaxLines: 4,
      );
    }
    return AdaptiveSettingsRow(
      key: const ValueKey<String>('global-hotkey-portal-configure'),
      title: t.shortcut_portal_configure,
      icon: FushiIcons.settings,
      showIcon: true,
      onTap: () => unawaited(_configure(context)),
    );
  }

  Future<void> _configure(BuildContext context) async {
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    final bool opened = await onConfigure();
    if (!opened) {
      messenger?.showSnackBar(
        FushiSnackBar(content: Text(t.shortcut_portal_configure_failed)),
      );
    }
  }
}
