import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:macos_ui/macos_ui.dart' show WindowManipulator;
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

/// 顶层路由是不是一个**弹层**（对话框 / 下拉 / bottom sheet）。
///
/// The focused widget lives in the top-most route; resolve its route so we can
/// tell a full page apart from a popup. The focus root's active target and the
/// raw primary focus are BOTH candidates: the controller's [activeContext] is
/// only authoritative while a managed target is live — on a page with zero
/// managed targets it falls back to the HibikiFocusRoot's own fallback node,
/// which sits ABOVE the [Navigator] and therefore resolves NO route at all
/// (BUG-1349: Escape went dead on the collection detail page whenever focus
/// navigation was enabled). Take the first candidate that resolves to a real
/// route instead of letting an unrooted fallback shadow a perfectly good
/// primary focus.
///
/// Unresolvable (focus parked above the Navigator on the focus root's fallback
/// node) is NOT a popup: when a dialog owns focus the framework consumes Escape
/// before it ever bubbles here, so the top route in the unresolvable case is a
/// full page.
bool _topRouteIsPopup(GlobalKey<NavigatorState> navigatorKey) {
  final BuildContext? navigationContext = navigatorKey.currentContext;
  final HibikiFocusController? controller = navigationContext == null
      ? null
      : HibikiFocusRoot.maybeControllerOf(navigationContext, listen: false);
  ModalRoute<dynamic>? route;
  for (final BuildContext? candidate in <BuildContext?>[
    controller?.activeContext,
    FocusManager.instance.primaryFocus?.context,
  ]) {
    if (candidate == null || !candidate.mounted) continue;
    route = ModalRoute.of(candidate);
    if (route != null) break;
  }
  return route is PopupRoute;
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
///    [focusNavigationEnabled] is off, so the default build is unchanged.
///    BUG-1266：门控范围已收窄到**只剩方向键移焦这一件事**——同一个 `if` 里原本还
///    压着手柄按钮分发与注册表 globalBack，它们与「实验性焦点导航」无关，现已移到
///    门控之外常驻生效。
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
/// (TODO-700 T1). A page that owns its own global resolution (home / reader /
/// manga / video) consumes the key in a nearer handler first; this only fires
/// for pages that do NOT self-resolve globalBack (settings pages, dialogs),
/// preserving "B / the bound back key pops a level" on every surface on both
/// Android (native gameButton key events) and desktop (the polled gamepad
/// reaches here as a synthesized key event), while letting the user rebind
/// which key is "back". Returns handled only when the event is actually bound
/// to globalBack.
///
/// 「返回上一级」统一之后，本处理器同时接管了从前那条**硬编码 Escape** 兜底
/// （旧 `_handleGlobalEscape`：Esc → pop 当前整页路由）。它们本来就是同一件事，
/// 只是一条可改键、一条改不动——两套并存的结果就是设置页写着「退出书籍 = Ctrl+W」
/// 而实际退书靠硬编码 Esc。现在 Esc 只是 [ShortcutAction.globalBack] 的默认键之一，
/// 改键真的能改。The framework only wires Escape to a dismiss action for
/// `barrierDismissible` modal routes; full-page routes (`PageRoute`, e.g. pushed
/// settings pages) have `barrierDismissible == false`, so without this the user
/// could not back out a level with the keyboard at all.
///
/// **两条既有语义原样保留、不合并**（合并任何一边都是回归）：
///   · 触发键是 Escape 且顶层是弹层 ⇒ 不介入，让框架自己的 `barrierDismissible`
///     契约（含**故意**不可关闭的对话框）说了算 —— 旧 `_handleGlobalEscape` 行为；
///   · 其余触发键（Alt+← / 手柄 B / 用户自绑键）⇒ 一律 [Navigator.maybePop]，弹层
///     上也照 pop —— 旧 `_handleGlobalBack` 行为（手柄用户靠它关对话框）。
/// [Navigator.maybePop] 保证页面自己的 [PopScope] 闸门仍然先跑。
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
    scope: ShortcutScope.universal,
    physicalKey: imeFallbackPhysicalKey,
  );
  if (action == null) {
    final GamepadButton? gamepad = GamepadButton.fromKeyEvent(event);
    if (gamepad != null) {
      action = registry.resolveGamepad(gamepad, scope: ShortcutScope.universal);
    }
  }
  if (action != ShortcutAction.globalBack) return KeyEventResult.ignored;
  final NavigatorState? nav = navigatorKey.currentState;
  if (nav == null || !nav.canPop()) return KeyEventResult.ignored;
  // Escape 落在弹层上：让给框架（见上方文档的两条既有语义）。
  if (event.logicalKey == LogicalKeyboardKey.escape &&
      _topRouteIsPopup(navigatorKey)) {
    return KeyEventResult.ignored;
  }
  nav.maybePop();
  return KeyEventResult.handled;
}

/// 注册表缺席时的键盘退出降级：裸 Escape 退一层整页路由，弹层仍让给框架。
///
/// 只在 [wrapWithGlobalNavigation] 拿不到 [HibikiShortcutRegistry] 时使用（widget
/// 测试直接调 wrapper）。生产路径一律走可改键的 [_handleGlobalBack]，故这不是
/// 「第二条硬编码 Escape」——它与注册表路径互斥，永远不会两条同时活着。
KeyEventResult _handleEscapeWithoutRegistry(
  GlobalKey<NavigatorState> navigatorKey,
  KeyEvent event,
) {
  if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.escape) {
    return KeyEventResult.ignored;
  }
  final NavigatorState? nav = navigatorKey.currentState;
  if (nav == null || !nav.canPop()) return KeyEventResult.ignored;
  if (_topRouteIsPopup(navigatorKey)) return KeyEventResult.ignored;
  nav.maybePop();
  return KeyEventResult.handled;
}

/// BUG-1266：吞掉**没有任何处理器认领**的手柄 B，阻断 Android 的系统级按键兜底。
///
/// Android 的 `Generic.kcm` 为游戏手柄的 `BUTTON_B` 定义了 `fallback BACK`：当 app
/// 的 view 层不消费 `KEYCODE_BUTTON_B` 时，系统会**另外合成一个 `KEYCODE_BACK`** 派发
/// 下来。那条兜底路径完全绕过 Hibiki 的快捷键注册表，于是：
///   * 用户把「返回」改绑到 RB 后，B 仍然退出页面（改键在 B 上根本是假的）；
///   * 页面尚未拿到键盘焦点时（如视频页首帧未就绪），B 连页面自己的绑定都还没轮到，
///     就被系统直接判成返回——用户「进视频想回退两句，结果一路退回桌面」正是它。
/// 把 B 在最外层就地消费，等于把「B 是不是返回键」的决定权完整交回注册表：绑了
/// globalBack 就在上面的 [_handleGlobalBack] 里 pop（默认绑定，行为不变），改绑走了
/// 就静默无操作，绝不再有第二条隐形返回路径。
///
/// 只针对 B，不扩大到别的手柄键，因为只有它有 BACK 兜底：
///   * `BUTTON_A` 的兜底是 `DPAD_CENTER`（= 确认焦点控件），是有益能力，保留；
///   * D-pad 无按键兜底，且仍需放行给方向焦点移动，绝不能在此吞掉；
///   * X/Y/LB/RB/扳机/Start/Select 在 `Generic.kcm` 里没有 fallback，吞不吞等价。
///
/// DOWN / UP / REPEAT 三个边沿都要消费：Android 的返回动作实际发生在 **ACTION_UP**，
/// 只吞按下边沿会让抬起边沿照样合成出 BACK，等于没修。
///
/// 判据独立成可单测的纯函数，让「吞哪些键」这条边界有直接断言，而不是只能从
/// widget 行为反推。
@visibleForTesting
bool gamepadBackMustBeSwallowed(KeyEvent event) =>
    GamepadButton.fromKeyEvent(event) == GamepadButton.b;

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

/// 裸空格中和：焦点确认永不走空格（确认键统一 Enter / 手柄 A，由框架默认提供），故在
/// 无文本输入时吞掉裸空格的按下沿，阻断 [WidgetsApp] 默认的 space→ActivateIntent。
///
/// **但仅在没有文本框聚焦时中和**。以前把 `space → DoNothingIntent` 挂进 [Shortcuts]，
/// 而 [DoNothingAction.consumesKey] 恒为 true——它无条件吞空格，包括文本框聚焦时
/// （BUG-962）。文本框里裸空格没有任何 text-editing 动作，不会在近处被消费，会一路冒泡
/// 到全局被吞掉；物理键盘走 KeyEvent 管线故被吞，屏幕键盘走 IME text-input 通道绕过快捷
/// 键层故能打——「重命名对话框只有屏幕键盘能打空格」正是这个漏判。现改为：仅按下沿且
/// [focusedEditableText] 为空时才消费——文本框聚焦时放行，空格落到 text-input 正常插入。
///
/// 只吞按下沿（[KeyDownEvent]），与原 [SingleActivator] 一致（激活是按下沿动作）；
/// repeat/up 放行无害。阅读器翻页 / 视频·有声书播放暂停在更近作用域先消费空格，根本到
/// 不了这里，故不受影响。始终生效，不受实验性焦点导航开关影响。
KeyEventResult _neutralizeBareSpace(KeyEvent event) {
  if (event is! KeyDownEvent ||
      event.logicalKey != LogicalKeyboardKey.space ||
      focusedEditableText() != null) {
    return KeyEventResult.ignored;
  }
  return KeyEventResult.handled;
}

/// Flips the main window between fullscreen and windowed.
///
/// TODO-1375：全屏切换必须由 NSWindow 的**唯一所有者**执行。macOS 壳用
/// macos_window_utils（[WindowManipulator]）持有 NSWindow.delegate（透明标题栏 /
/// sidebar vibrancy / 全屏 presentation options 都挂它），而 window_manager 想把
/// 自己设成 delegate 却在初始化时被 macos_window_utils 覆盖——两者各持一份 NSWindow
/// 引用与各自的全屏认知。若 macOS 仍走 [WindowManager.setFullScreen]（内部
/// `toggleFullScreen(nil)`），进出全屏时 delegate 通知全被 macos_window_utils 截获、
/// window_manager 的 WindowListener 收不到，状态机在双栈间走岔（TODO-1375 症状①：
/// 全屏退出后 sidebar 卡死）。故 macOS 全屏统一改走 [WindowManipulator]
/// （enter/exit/isWindowFullscreened，底层同样是 `toggleFullScreen`，但由 delegate
/// 所有者自洽驱动）。Windows / Linux 无此双栈问题，保持 window_manager。
///
/// 任何 platform-channel 失败都以 debug 日志吞掉，杂散按键永不崩应用。
Future<void> _toggleWindowFullscreen() async {
  try {
    if (Platform.isMacOS) {
      final bool current = await WindowManipulator.isWindowFullscreened();
      if (current) {
        await WindowManipulator.exitFullscreen();
      } else {
        await WindowManipulator.enterFullscreen();
      }
      return;
    }
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
///   AppModel.experimentalFocusNavigationEnabled）。它只控制**方向键/摇杆移焦**这
///   套实验性焦点导航；**手柄按钮分发与注册表 globalBack 不再受它门控**（BUG-1266）：
///   手柄改键是正式功能（快捷键设置里有完整 UI 与默认绑定表），把它挂在一个默认关闭
///   的实验开关上，等于在默认安装上「配了手柄绑定却永不解析」。**关闭时还把
///   Tab / Shift+Tab 中和成
///   [DoNothingIntent]**，停掉 Flutter [WidgetsApp] 内建的 Tab 焦点遍历——用户裁定
///   没开焦点导航时按 Tab 不该有动作（TODO-112）。开启时不中和，原生 Tab 遍历照常。
///   与焦点导航无关、始终生效的两件事不受其影响：
///     * Escape 退出整页层级（桌面键盘惯例）；
///     * 裸空格中和（[_neutralizeBareSpace]），使焦点确认永不走空格（确认键统一
///       Enter / 手柄 A，由框架默认提供）。**仅在没有文本框聚焦时中和**——文本框输入
///       空格必须放行，否则重命名等输入框打不出空格（BUG-962）。空格被更近作用域消费
///       （阅读器翻页 / 视频·有声书播放暂停）时根本到不了这里，故不受影响。
Widget wrapWithGlobalNavigation({
  required GlobalKey<NavigatorState> navigatorKey,
  required Widget child,
  bool focusNavigationEnabled = true,
  HibikiShortcutRegistry? registry,
}) {
  final Map<ShortcutActivator, Intent> shortcuts = <ShortcutActivator, Intent>{
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
      // 裸空格中和（始终生效，不受焦点导航开关影响）；仅非文本输入时消费，见
      // [_neutralizeBareSpace]（BUG-962）。放在最前，先于框架 space→ActivateIntent。
      if (_neutralizeBareSpace(event) == KeyEventResult.handled) {
        return KeyEventResult.handled;
      }
      // BUG-1266：手柄按钮分发**不受** [focusNavigationEnabled] 门控。该开关默认
      // 关闭，此前把整块手柄逻辑一起关掉，导致默认安装上「注册表 globalBack」根本
      // 不参与解析——Android 上按 B 之所以还能返回，靠的是系统兜底（见下），于是
      // 用户把「返回」改绑到 RB 后 B 依旧退出页面。
      final KeyEventResult gamepadResult =
          dispatchNativeGamepadButtonIntent(event);
      if (gamepadResult == KeyEventResult.handled) return gamepadResult;
      if (focusNavigationEnabled) {
        final KeyEventResult arrowResult =
            _handleGlobalArrowFocus(navigatorKey, event);
        if (arrowResult == KeyEventResult.handled) return arrowResult;
      }
      // TODO-700 T1：注册表驱动的全局返回回退（Esc / Alt+← / B，或用户改键后的
      // 「返回」键）。仅对未自解析 globalBack 的页面（设置/对话框）生效；
      // home/reader/manga/video 已在更近的处理器消费。
      if (registry != null) {
        final KeyEventResult backResult =
            _handleGlobalBack(navigatorKey, registry, event);
        if (backResult == KeyEventResult.handled) return backResult;
        if (focusNavigationEnabled) {
          // TODO-1093：注册表驱动的窗口级全屏切换（默认 F11）。放在 globalBack 之后、
          // Escape 之前；仅桌面有窗口时真正 toggle，移动端 no-op（见下）。
          final KeyEventResult fullscreenResult =
              _handleGlobalToggleFullscreen(registry, event);
          if (fullscreenResult == KeyEventResult.handled) {
            return fullscreenResult;
          }
        }
      }
      // BUG-1266：走到这里说明**没有任何**处理器认领这次手柄按键。对手柄 B 必须
      // 就地消费，绝不能放行——见 [gamepadBackMustBeSwallowed] 的完整理由。
      if (gamepadBackMustBeSwallowed(event)) return KeyEventResult.handled;
      // 注册表未注入（widget 测试直接调本 wrapper，不带 registry）时的降级：按裸
      // Escape 退一层。生产路径永远带 registry，走上面那条可改键的 globalBack；
      // 这里只是让「不关心快捷键」的测试宿主仍有键盘退出能力，不是第二条产品路径。
      if (registry == null) {
        return _handleEscapeWithoutRegistry(navigatorKey, event);
      }
      return KeyEventResult.ignored;
    },
    child: Shortcuts(
      shortcuts: shortcuts,
      child: child,
    ),
  );
}
