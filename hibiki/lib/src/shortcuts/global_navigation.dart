import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart'
    show
        arrowTraversalDirection,
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

/// Lets keyboard up/down ESCAPE a focused single-line text field — the one
/// directional-navigation case the framework traps.
///
/// The reported bug ("管理音频来源里按方向键上下动不了"): with the URL text field
/// focused, up/down do nothing. The framework's [DefaultTextEditingShortcuts]
/// maps every arrow to a caret intent and the [EditableText] consumes it — even
/// up/down on a single-line field, where the caret cannot move — so focus is
/// trapped on the field and never reaches the rows above or the buttons below.
///
/// This is deliberately the MINIMAL intervention. It only ever fires while a
/// text field is focused; every other arrow is left untouched, so the existing
/// owners keep working exactly as before — the home page's directional nav, the
/// reader's page-turn, sliders/dropdowns, and Flutter's default directional
/// traversal inside dialogs (which already walks non-field controls fine). The
/// wrapper sits ABOVE the Navigator yet is reached BEFORE
/// [DefaultTextEditingShortcuts] (key events bubble up from the focused node, and
/// this wrapper is nearer the focus than WidgetsApp's shortcuts), so it can claim
/// the up/down a single-line caret does not need:
///   * left/right -> always left to the caret;
///   * up/down in a MULTI-line field -> left to the caret (line navigation);
///   * up/down in a single-line field -> move focus out of the field, via
///     [gamepadMoveFocusInDirection] (same bootstrap + reading-order fallback as
///     the gamepad D-pad, so it never dead-ends mid-list).
KeyEventResult _handleGlobalArrowFocus(
  GlobalKey<NavigatorState> navigatorKey,
  KeyEvent event,
) {
  if (event is! KeyDownEvent) return KeyEventResult.ignored;
  final TraversalDirection? dir = arrowTraversalDirection(event.logicalKey);
  if (dir == null) return KeyEventResult.ignored;
  final EditableText? editable = focusedEditableText();
  // Surgical: only intervene to free a trapped single-line field. With no field
  // focused, or for an arrow the caret legitimately uses, stay out of the way.
  if (editable == null || _caretKeepsArrow(editable, dir)) {
    return KeyEventResult.ignored;
  }
  // Mirror the gamepad service's dispatch context: the focused widget's context
  // when one exists, else the navigator, so directional resolution starts from
  // the right scope inside whichever route is on top.
  final BuildContext? context = FocusManager.instance.primaryFocus?.context ??
      navigatorKey.currentContext;
  if (context == null) return KeyEventResult.ignored;
  gamepadMoveFocusInDirection(context, dir);
  // Always consume: at a scroll/list edge the move is a no-op, but the arrow has
  // still been "spent" leaving the field — never falls back to the caret.
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
