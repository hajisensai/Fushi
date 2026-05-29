import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Intent for "go back / dismiss" driven by the gamepad B button.
/// Reuses [Navigator.maybePop] so it uniformly closes dialogs, bottom sheets
/// and page routes while respecting any [PopScope].
class HibikiPopIntent extends Intent {
  const HibikiPopIntent();
}

class HibikiPopAction extends Action<HibikiPopIntent> {
  HibikiPopAction(this.navigatorKey);

  final GlobalKey<NavigatorState> navigatorKey;

  @override
  void invoke(HibikiPopIntent intent) {
    navigatorKey.currentState?.maybePop();
  }
}

/// Wrap [child] (typically MaterialApp's builder child) so the gamepad B
/// button triggers a global back/dismiss. Escape is intentionally NOT bound
/// here so the framework's default Escape -> DismissIntent keeps closing
/// dialogs and dropdowns.
///
/// [enableGamepad] gates the gamepad-B mapping: it is mobile-only (Android/iOS),
/// since desktop embedders never deliver gameButton* logical keys. When false
/// the wrapper is a no-op and [child] is returned unwrapped.
Widget wrapWithGlobalNavigation({
  required GlobalKey<NavigatorState> navigatorKey,
  required Widget child,
  bool enableGamepad = true,
}) {
  if (!enableGamepad) return child;
  return Shortcuts(
    shortcuts: const <ShortcutActivator, Intent>{
      SingleActivator(LogicalKeyboardKey.gameButtonB): HibikiPopIntent(),
    },
    child: Actions(
      actions: <Type, Action<Intent>>{
        HibikiPopIntent: HibikiPopAction(navigatorKey),
      },
      child: child,
    ),
  );
}
