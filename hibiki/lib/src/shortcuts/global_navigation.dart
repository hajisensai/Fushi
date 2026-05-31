import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';

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

/// Escape -> pop the current FULL-PAGE route ("退出层级").
///
/// The framework only wires Escape to a dismiss action for `barrierDismissible`
/// modal routes (dialogs, dropdowns, popups, bottom sheets). Full-page routes
/// (`PageRoute`, e.g. pushed settings pages) have `barrierDismissible == false`,
/// so Escape is a no-op there and the user cannot back out a level with the
/// keyboard.
///
/// This handler sits above the [Navigator], so it sees an Escape only after
/// every deeper handler declined it — a page that consumes Escape itself (e.g.
/// the reader toggling its chrome) keeps winning. It pops ONLY page routes;
/// popups are left to the framework so the `barrierDismissible` contract (incl.
/// intentionally non-dismissible dialogs) and any [PopScope] stay authoritative.
/// [Navigator.maybePop] is used so a page's own [PopScope] guard still runs.
KeyEventResult _handleGlobalEscape(
  GlobalKey<NavigatorState> navigatorKey,
  KeyEvent event,
) {
  if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.escape) {
    return KeyEventResult.ignored;
  }
  final NavigatorState? nav = navigatorKey.currentState;
  if (nav == null || !nav.canPop()) return KeyEventResult.ignored;

  // The focused widget lives in the top-most route; resolve its route so we can
  // tell a full page apart from a popup. The focus root is the authoritative
  // source once installed; raw primary focus is kept as an unrooted fallback.
  final BuildContext? navigationContext = navigatorKey.currentContext;
  final HibikiFocusController? controller = navigationContext == null
      ? null
      : HibikiFocusRoot.maybeControllerOf(navigationContext, listen: false);
  final BuildContext? focused =
      controller?.activeContext ?? FocusManager.instance.primaryFocus?.context;
  if (focused == null) return KeyEventResult.ignored;
  final ModalRoute<dynamic>? route = ModalRoute.of(focused);
  if (route == null || route is PopupRoute) return KeyEventResult.ignored;

  nav.maybePop();
  return KeyEventResult.handled;
}

/// Wrap [child] (typically MaterialApp's builder child) with app-wide keyboard /
/// gamepad navigation:
///
/// * Escape pops the current full-page route ("退出层级") — desktop is where
///   hardware Escape matters, and it is harmless elsewhere. Popups keep the
///   framework's own Escape handling.
/// * The gamepad B button triggers a global back/dismiss.
Widget wrapWithGlobalNavigation({
  required GlobalKey<NavigatorState> navigatorKey,
  required Widget child,
}) {
  // Outermost: observes Escape that bubbled past every deeper handler. It never
  // takes focus or a tab stop — it only listens.
  return Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: (FocusNode node, KeyEvent event) =>
        _handleGlobalEscape(navigatorKey, event),
    child: Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.gameButtonB): HibikiPopIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          HibikiPopIntent: HibikiPopAction(navigatorKey),
        },
        child: child,
      ),
    ),
  );
}
