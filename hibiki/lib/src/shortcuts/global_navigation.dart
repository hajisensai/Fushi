import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart'
    show
        arrowFocusMoveDirection,
        dispatchNativeGamepadButtonIntent,
        focusedEditableText,
        gamepadMoveFocusInDirection;

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

/// App-wide arrow-key focus handling, in two parts (both reached BEFORE
/// WidgetsApp's [DefaultTextEditingShortcuts]/[DirectionalFocusAction] because
/// key events bubble up from the focused node and this wrapper is nearer the
/// focus than WidgetsApp's shortcuts):
///
/// 1. ESCAPE a focused single-line text field — the one directional-navigation
///    case the framework traps (bug "管理音频来源里按方向键上下动不了"): with the
///    URL field focused, up/down do nothing because the framework maps every
///    arrow to a caret intent and the [EditableText] consumes it even up/down on
///    a single-line field where the caret cannot move. This fires ONLY on the
///    press edge ([KeyDownEvent]) and ONLY when a single-line field is focused —
///    one Up/Down leaves the field; repeats would be meaningless since focus is
///    no longer on the field. left/right and multi-line up/down stay with the
///    caret.
///
/// 2. CONTINUE directional focus movement on OS auto-repeat ([KeyRepeatEvent])
///    when NO text field is focused. Holding an arrow advances focus
///    continuously instead of one step per press. The press edge is deliberately
///    NOT claimed here (it is left to the page/home/framework owners, so this is
///    a zero-regression addition); only the repeat is taken so it runs the SAME
///    [gamepadMoveFocusInDirection] (panel-aware geometry + reading-order
///    fallback) as the press edge would on home/gamepad — the framework's bare
///    [DirectionalFocusAction] that would otherwise handle the repeat does not
///    carry that fallback and dead-ends at row/panel edges. The home page
///    handles its own repeats and consumes them before they reach here; this
///    catches every other page (settings, dialogs, reader chrome) uniformly.
KeyEventResult _handleGlobalArrowFocus(
  GlobalKey<NavigatorState> navigatorKey,
  KeyEvent event,
) {
  final TraversalDirection? dir = arrowFocusMoveDirection(event);
  if (dir == null) return KeyEventResult.ignored;
  final EditableText? editable = focusedEditableText();

  if (editable == null) {
    // Part 2: no field focused — continue movement on OS auto-repeat ONLY, and
    // ONLY while focus rests on a real Hibiki-managed control. The managed-target
    // gate is what keeps this from hijacking a held arrow on a surface that owns
    // the arrow for itself — the reader's reading content / page-turn and char
    // cursor (its FocusNode is not a managed target; the reader consumes its own
    // caret repeats before they reach here). The press edge is left to the
    // page/framework owners, so this only ADDS repeat continuation, never changes
    // a single press.
    if (event is! KeyRepeatEvent) return KeyEventResult.ignored;
    // Resolve the controller from the FOCUSED context (the HibikiFocusRoot sits
    // below the Navigator, so navigatorKey.currentContext is ABOVE the scope and
    // cannot see it; the primary focus is inside the root). No focus / no root →
    // leave the repeat to the framework (unchanged behaviour).
    final BuildContext? focusContext =
        FocusManager.instance.primaryFocus?.context;
    final HibikiFocusController? controller = focusContext == null
        ? null
        : HibikiFocusRoot.maybeControllerOf(focusContext, listen: false);
    if (controller == null || !controller.primaryFocusIsManagedTarget) {
      return KeyEventResult.ignored;
    }
    return _moveFocusForArrow(navigatorKey, dir);
  }

  // Part 1: single-line field escape, press edge only.
  if (event is! KeyDownEvent || _caretKeepsArrow(editable, dir)) {
    return KeyEventResult.ignored;
  }
  return _moveFocusForArrow(navigatorKey, dir);
}

/// Moves directional focus one step in [dir] from whichever route is on top,
/// then ALWAYS consumes the arrow: at a scroll/list edge the move is a no-op but
/// the arrow has still been "spent" (so it never falls back to the caret or to
/// the framework's fallback that lacks Hibiki's reading-order step).
KeyEventResult _moveFocusForArrow(
  GlobalKey<NavigatorState> navigatorKey,
  TraversalDirection dir,
) {
  // Mirror the gamepad service's dispatch context: the focused widget's context
  // when one exists, else the navigator, so directional resolution starts from
  // the right scope inside whichever route is on top.
  final BuildContext? context = FocusManager.instance.primaryFocus?.context ??
      navigatorKey.currentContext;
  if (context == null) return KeyEventResult.ignored;
  gamepadMoveFocusInDirection(context, dir);
  return KeyEventResult.handled;
}

/// Whether [editable]'s caret should keep [dir] instead of yielding it to focus
/// navigation. Horizontal arrows always drive the caret; vertical arrows drive
/// the caret only in a multi-line field (a single-line field has no line to move
/// to, so up/down are free to move focus out).
bool _caretKeepsArrow(EditableText editable, TraversalDirection dir) {
  if (dir == TraversalDirection.left || dir == TraversalDirection.right) {
    return true;
  }
  final int? maxLines = editable.maxLines;
  return maxLines == null || maxLines > 1; // null = unbounded = multi-line
}

/// Wrap [child] (typically MaterialApp's builder child) with app-wide keyboard /
/// gamepad navigation:
///
/// * Escape pops the current full-page route ("退出层级") — desktop is where
///   hardware Escape matters, and it is harmless elsewhere. Popups keep the
///   framework's own Escape handling.
/// * The gamepad B button triggers a global back/dismiss.
/// * [focusNavigationEnabled] 为实验性「键盘/手柄焦点导航」总开关（默认关闭，见
///   AppModel.experimentalFocusNavigationEnabled）。仅它控制手柄按钮分发、方向键
///   移焦、以及手柄 B 返回；关闭时这些一律不挂，App 回退到 Flutter 原生焦点遍历。
///   与焦点导航无关、始终生效的两件事不受其影响：
///     * Escape 退出整页层级（桌面键盘惯例）；
///     * 裸空格中和为 [DoNothingIntent]，使焦点确认永不走空格（确认键统一 Enter /
///       手柄 A，由框架默认提供）。空格被更近作用域消费（阅读器翻页 / 视频·有声书
///       播放暂停 / 文本框输入空格）时根本到不了这里，故不受影响。
Widget wrapWithGlobalNavigation({
  required GlobalKey<NavigatorState> navigatorKey,
  required Widget child,
  bool focusNavigationEnabled = true,
}) {
  final Map<ShortcutActivator, Intent> shortcuts = <ShortcutActivator, Intent>{
    const SingleActivator(LogicalKeyboardKey.space): const DoNothingIntent(),
    if (focusNavigationEnabled)
      const SingleActivator(LogicalKeyboardKey.gameButtonB):
          const HibikiPopIntent(),
  };
  // Outermost: observes Escape that bubbled past every deeper handler. It never
  // takes focus or a tab stop — it only listens.
  return Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: (FocusNode node, KeyEvent event) {
      if (focusNavigationEnabled) {
        final KeyEventResult gamepadResult =
            dispatchNativeGamepadButtonIntent(event);
        if (gamepadResult == KeyEventResult.handled) return gamepadResult;
        final KeyEventResult arrowResult =
            _handleGlobalArrowFocus(navigatorKey, event);
        if (arrowResult == KeyEventResult.handled) return arrowResult;
      }
      return _handleGlobalEscape(navigatorKey, event);
    },
    child: Shortcuts(
      shortcuts: shortcuts,
      child: Actions(
        actions: <Type, Action<Intent>>{
          HibikiPopIntent: HibikiPopAction(navigatorKey),
        },
        child: child,
      ),
    ),
  );
}
