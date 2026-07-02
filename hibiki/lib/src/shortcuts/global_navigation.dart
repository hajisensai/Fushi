import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:window_manager/window_manager.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';

import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart'
    show
        arrowFocusMoveDirection,
        dispatchNativeGamepadButtonIntent,
        focusedEditableText,
        gamepadMoveFocusInDirection;

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
/// 2. OWN directional focus movement for BOTH the press edge ([KeyDownEvent])
///    AND OS auto-repeat ([KeyRepeatEvent]) when NO text field is focused and
///    focus rests on a real Hibiki-managed control (BUG-263). This is the single
///    arbiter for "arrow = focus traversal": press and repeat now go through the
///    SAME [gamepadMoveFocusInDirection] (panel-aware geometry + reading-order +
///    scroll-edge fallback) — the gamepad D-pad and the keyboard arrow reach the
///    exact same focus engine. Previously the press edge was deliberately left to
///    WidgetsApp's framework [DirectionalFocusAction] (a plain focusInDirection
///    with none of Hibiki's fallbacks) while only the repeat was taken here, so
///    holding an arrow switched focus engines mid-hold: the press could dead-end
///    at a row/panel/scroll edge that the very next repeat then escaped, and at a
///    managed control the framework press and the Hibiki repeat resolved to
///    DIFFERENT targets. That split is the "focus steals shortcut / left-right
///    always conflicts" the user hit. Claiming the press here consumes the arrow
///    before it can reach the framework's [DirectionalFocusAction], so exactly
///    one focus engine runs.
///
///    The managed-target gate is what keeps this from hijacking an arrow on a
///    surface that owns it for itself — the reader's reading content / page-turn
///    and char cursor (its FocusNode is not a managed target), the video player,
///    the WebView. Those surfaces also consume the arrow in their OWN nearer
///    [Focus.onKeyEvent] before it ever bubbles here, so this never competes with
///    a bound page-turn / seek shortcut. The home page handles its own arrows and
///    consumes them before they reach here; this catches every other managed
///    page (settings, dialogs, reader chrome) uniformly. Disabled entirely when
///    [focusNavigationEnabled] is off (the whole arrow/gamepad block is gated by
///    the caller), so the default build is unchanged.
KeyEventResult _handleGlobalArrowFocus(
  GlobalKey<NavigatorState> navigatorKey,
  KeyEvent event,
) {
  final TraversalDirection? dir = arrowFocusMoveDirection(event);
  if (dir == null) return KeyEventResult.ignored;
  final EditableText? editable = focusedEditableText();

  if (editable == null) {
    // Part 2: no field focused — move focus on the press edge AND every repeat,
    // but ONLY while focus rests on a real Hibiki-managed control. The
    // managed-target gate keeps this from hijacking an arrow on a surface that
    // owns it (reader page-turn / char cursor, video seek, raw page sink); those
    // surfaces are not managed targets and consume the arrow in their own nearer
    // handler first. [arrowFocusMoveDirection] already returns non-null only for
    // a KeyDown or KeyRepeat (never a KeyUp), so both edges flow through the
    // single shared move below — press and repeat can never diverge.
    //
    // Resolve the controller from the FOCUSED context (the HibikiFocusRoot sits
    // below the Navigator, so navigatorKey.currentContext is ABOVE the scope and
    // cannot see it; the primary focus is inside the root). No focus / no root →
    // leave the arrow to the framework (unchanged behaviour).
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

/// Outermost fallback for the remappable [ShortcutAction.globalBack] key
/// (TODO-700 T1). A page that owns its own global resolution (home / reader)
/// consumes the key in a nearer handler first; this only fires for pages that do
/// NOT self-resolve globalBack (settings pages, dialogs), preserving "B / the
/// bound back key pops a level" on every surface on both Android (native
/// gameButton key events) and desktop (the polled gamepad reaches here as a
/// synthesized key event), while letting the user rebind which key is "back".
/// Returns handled only when the event is actually bound to globalBack.
KeyEventResult _handleGlobalBack(
  GlobalKey<NavigatorState> navigatorKey,
  HibikiShortcutRegistry registry,
  KeyEvent event,
) {
  if (event is! KeyDownEvent) return KeyEventResult.ignored;
  final Set<ModifierKey> modifiers = <ModifierKey>{};
  final HardwareKeyboard hw = HardwareKeyboard.instance;
  if (hw.isControlPressed) modifiers.add(ModifierKey.ctrl);
  if (hw.isShiftPressed) modifiers.add(ModifierKey.shift);
  if (hw.isAltPressed) modifiers.add(ModifierKey.alt);
  if (hw.isMetaPressed) modifiers.add(ModifierKey.meta);
  // TODO-847: IME 激活时 logicalKey 被改写成 process，传 physicalKey 让 registry
  // 走物理键回退还原 globalBack（默认 Esc）；文本框 composing 时传 null 关闭回退。
  final PhysicalKeyboardKey? imeFallbackPhysicalKey =
      focusedEditableText() == null ? event.physicalKey : null;
  ShortcutAction? action = registry.resolveKeyboard(
    event.logicalKey,
    modifiers: modifiers,
    scope: ShortcutScope.global,
    physicalKey: imeFallbackPhysicalKey,
  );
  if (action == null) {
    final GamepadButton? gamepad = GamepadButton.fromKeyEvent(event);
    if (gamepad != null) {
      action = registry.resolveGamepad(gamepad, scope: ShortcutScope.global);
    }
  }
  if (action != ShortcutAction.globalBack) return KeyEventResult.ignored;
  final NavigatorState? nav = navigatorKey.currentState;
  if (nav == null || !nav.canPop()) return KeyEventResult.ignored;
  nav.maybePop();
  return KeyEventResult.handled;
}

/// Desktop window-level fullscreen toggle for the remappable
/// [ShortcutAction.globalToggleFullscreen] key (TODO-1093). Distinct from the
/// video player's own [ShortcutAction.videoToggleFullscreen] (which only toggles
/// the video surface): this flips the whole app window between fullscreen and
/// windowed via [WindowManager.setFullScreen], reading the current state the same
/// way [DesktopWindowPlacement.saveCurrentBoundsNow] does
/// ([WindowManager.isFullScreen]). Only meaningful on desktop (Windows / macOS /
/// Linux) where a native window exists; on mobile there is no such window, so the
/// binding resolves but the toggle is a no-op (guarded by [_isDesktopWindow]).
///
/// Resolution is synchronous so [Focus.onKeyEvent] can return a [KeyEventResult]
/// immediately; the actual (async) [WindowManager] round-trip is fired
/// unawaited only after the key is confirmed bound to globalToggleFullscreen.
KeyEventResult _handleGlobalToggleFullscreen(
  HibikiShortcutRegistry registry,
  KeyEvent event,
) {
  if (event is! KeyDownEvent) return KeyEventResult.ignored;
  final Set<ModifierKey> modifiers = <ModifierKey>{};
  final HardwareKeyboard hw = HardwareKeyboard.instance;
  if (hw.isControlPressed) modifiers.add(ModifierKey.ctrl);
  if (hw.isShiftPressed) modifiers.add(ModifierKey.shift);
  if (hw.isAltPressed) modifiers.add(ModifierKey.alt);
  if (hw.isMetaPressed) modifiers.add(ModifierKey.meta);
  final PhysicalKeyboardKey? imeFallbackPhysicalKey =
      focusedEditableText() == null ? event.physicalKey : null;
  ShortcutAction? action = registry.resolveKeyboard(
    event.logicalKey,
    modifiers: modifiers,
    scope: ShortcutScope.global,
    physicalKey: imeFallbackPhysicalKey,
  );
  if (action == null) {
    final GamepadButton? gamepad = GamepadButton.fromKeyEvent(event);
    if (gamepad != null) {
      action = registry.resolveGamepad(gamepad, scope: ShortcutScope.global);
    }
  }
  if (action != ShortcutAction.globalToggleFullscreen) {
    return KeyEventResult.ignored;
  }
  // Bound but no desktop window (mobile): consume the key (it is intentionally
  // assigned) but do nothing — there is no window to toggle.
  if (_isDesktopWindow) {
    unawaited(_toggleWindowFullscreen());
  }
  return KeyEventResult.handled;
}

/// Whether the running platform has a desktop window whose fullscreen state can
/// be toggled via [WindowManager] (mirrors [DesktopWindowPlacement] desktop gate).
bool get _isDesktopWindow =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// Flips the main window between fullscreen and windowed. Reads the current
/// state with [WindowManager.isFullScreen] (same call
/// [DesktopWindowPlacement.saveCurrentBoundsNow] uses) and inverts it. Any
/// platform-channel failure is swallowed with a debug log so a stray key press
/// can never crash the app.
Future<void> _toggleWindowFullscreen() async {
  try {
    final bool current = await windowManager.isFullScreen();
    await windowManager.setFullScreen(!current);
  } catch (e) {
    debugPrint('[Hibiki] window fullscreen toggle skipped: $e');
  }
}

/// Wrap [child] (typically MaterialApp's builder child) with app-wide keyboard /
/// gamepad navigation:

///
/// * Escape pops the current full-page route ("退出层级") — desktop is where
///   hardware Escape matters, and it is harmless elsewhere. Popups keep the
///   framework's own Escape handling.
/// * The gamepad B button triggers a global back/dismiss.
/// * [focusNavigationEnabled] 为实验性「键盘/手柄焦点导航」总开关（默认关闭，见
///   AppModel.experimentalFocusNavigationEnabled）。它控制手柄按钮分发、方向键
///   移焦、手柄 B 返回；关闭时这些一律不挂。**关闭时还把 Tab / Shift+Tab 中和成
///   [DoNothingIntent]**，停掉 Flutter [WidgetsApp] 内建的 Tab 焦点遍历——用户裁定
///   没开焦点导航时按 Tab 不该有动作（TODO-112）。开启时不中和，原生 Tab 遍历照常。
///   与焦点导航无关、始终生效的两件事不受其影响：
///     * Escape 退出整页层级（桌面键盘惯例）；
///     * 裸空格中和为 [DoNothingIntent]，使焦点确认永不走空格（确认键统一 Enter /
///       手柄 A，由框架默认提供）。空格被更近作用域消费（阅读器翻页 / 视频·有声书
///       播放暂停 / 文本框输入空格）时根本到不了这里，故不受影响。
Widget wrapWithGlobalNavigation({
  required GlobalKey<NavigatorState> navigatorKey,
  required Widget child,
  bool focusNavigationEnabled = true,
  HibikiShortcutRegistry? registry,
}) {
  final Map<ShortcutActivator, Intent> shortcuts = <ShortcutActivator, Intent>{
    const SingleActivator(LogicalKeyboardKey.space): const DoNothingIntent(),
    // 焦点导航总开关关闭时，把 Tab / Shift+Tab 中和成 DoNothingIntent，使 Flutter
    // [WidgetsApp] 内建的 NextFocusIntent/PreviousFocusIntent 遍历不再生效——本
    // Shortcuts 比 WidgetsApp 默认 shortcuts 更靠近焦点节点，故先匹配并阻断冒泡。
    // 用户裁定：没开「键盘/手柄焦点导航」时按 Tab 不该有动作（与裸空格中和同范式）。
    // 开启时不加这两条，Flutter 原生 Tab 遍历照常工作。文本框输入不受影响：Tab 在
    // 文本框内本就是焦点遍历键（不插入制表符），中和它只停遍历，不改文本编辑。
    if (!focusNavigationEnabled) ...<ShortcutActivator, Intent>{
      const SingleActivator(LogicalKeyboardKey.tab): const DoNothingIntent(),
      const SingleActivator(LogicalKeyboardKey.tab, shift: true):
          const DoNothingIntent(),
    },
    // TODO-700 T1：手柄 B 不再硬绑全局 Pop。B 现经 GamepadService /
    // dispatchNativeGamepadButtonIntent 进各页 Actions，按注册表 globalBack 解析，
    // 故「返回」可改键（约束3/5），且阅读器内 B 先被 audiobookPrevSentence 消费、
    // 不再被全局返回夺舍退书（约束2/4）。HibikiPopIntent/HibikiPopAction 仍保留，
    // 由 globalBack 的执行体复用（见下 Actions 注册）。
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
        // TODO-700 T1：注册表驱动的全局返回回退（B 或用户改键后的「返回」键）。仅
        // 对未自解析 globalBack 的页面（设置/对话框）生效；home/reader 已在更近的
        // 处理器消费。registry 为空（测试 / 未注入）时跳过，回退到 Escape。
        if (registry != null) {
          final KeyEventResult backResult =
              _handleGlobalBack(navigatorKey, registry, event);
          if (backResult == KeyEventResult.handled) return backResult;
          // TODO-1093：注册表驱动的窗口级全屏切换（默认 F11）。放在 globalBack 之后、
          // Escape 之前；仅桌面有窗口时真正 toggle，移动端 no-op（见下）。
          final KeyEventResult fullscreenResult =
              _handleGlobalToggleFullscreen(registry, event);
          if (fullscreenResult == KeyEventResult.handled) {
            return fullscreenResult;
          }
        }
      }
      return _handleGlobalEscape(navigatorKey, event);
    },
    child: Shortcuts(
      shortcuts: shortcuts,
      child: child,
    ),
  );
}
