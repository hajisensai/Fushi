/// 鼠标绑定通道的两件共享设施：**解析阶梯**（[resolveMouseBindingAction]）与
/// **一次按下只派发一次**（[MouseBindingDispatch]）。
///
/// 为什么鼠标需要后者、键盘不需要：
///
/// 键盘天生有阻断——`KeyEventResult.handled` 一返回，事件就不再冒泡到外层 `Focus`。
/// 页面的 `Focus` 与 app 根 [wrapWithGlobalNavigation] 的 `Focus` 串在同一条冒泡链
/// 上，于是「页面专属键优先、页面没接才轮到全局」是免费的，而且**全局那一段的执行体
/// 只需要写在最外层一处**。
///
/// **指针没有这条链**：[Listener] 既不参与手势竞技场、也无法消费事件，Flutter 会把
/// 同一个 [PointerDownEvent] 沿命中路径**由内向外**交给每一个 [Listener]。若页面根与
/// app 根各挂一个而不做仲裁，同一次按下会被派发两次——绑「返回上一级」的侧键在视频页
/// 会一次退两级。
///
/// 本文件把那条缺失的阻断按**同一套语义**补上，而不是引入第二套优先级规则：
/// 分层不变（页面只解析自己的 scope，`universal` / `global` 一律由 app 根兜底，
/// 执行体也只有那一份），仲裁只回答「更内层已经派发过了吗」。
library;

import 'dart:async' show Timer;
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/gestures.dart'
    show
        GestureBinding,
        PointerCancelEvent,
        PointerDownEvent,
        PointerEvent,
        PointerRemovedEvent,
        PointerUpEvent;
import 'package:flutter/scheduler.dart' show SchedulerBinding;

import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/reader_space_override.dart'
    show isRepeatableReaderKeyboardShortcut;
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

/// 按 [ladder] 顺序把一次鼠标按下解析成动作，第一个命中的 scope 赢。
///
/// 按钮号折叠恒用 [domMouseButtonFromPointerButtons]：设置页的按键录制
/// （`binding_edit_dialog.part.dart`）用的是同一个函数，两侧不共用就会出现「设置里
/// 录到侧键、运行时按另一个号去解析」的错位。左键在那里返回 null，故**永远不可绑**，
/// 正常点击 / 划词 / 拖拽零影响；触摸合成事件的 `buttons` 同样折不出按钮号。
ShortcutAction? resolveMouseBindingAction({
  required FushiShortcutRegistry registry,
  required int buttons,
  required List<ShortcutScope> ladder,
}) {
  final int? button = domMouseButtonFromPointerButtons(buttons);
  if (button == null) return null;
  return resolveMouseBindingActionForButton(
    registry: registry,
    button: button,
    ladder: ladder,
  );
}

/// 与 [resolveMouseBindingAction] 同义，但入参是**已经折好的** DOM
/// `MouseEvent.button`（1=中键 / 2=右键 / 3=后退 / 4=前进）。
///
/// 供 WebView 宿主使用：阅读器 / 漫画那条路的按钮号是页内 JS 直接给的 `e.button`，
/// 本来就不是 Flutter 的 `buttons` 位掩码，再折一次会把 1 当成 `kPrimaryMouseButton`
/// 折错。
ShortcutAction? resolveMouseBindingActionForButton({
  required FushiShortcutRegistry registry,
  required int button,
  required List<ShortcutScope> ladder,
}) {
  if (button <= 0) return null;
  for (final ShortcutScope scope in ladder) {
    final ShortcutAction? action = registry.resolveMouse(button, scope: scope);
    if (action != null) return action;
  }
  return null;
}

/// 「这次按下已经被更内层派发掉了」的唯一真相。
///
/// 仲裁规则与键盘完全同构：**最内层真正派发出去的那一层拿走这次按下**，外层看到已被
/// 认领就什么都不做。Flutter 的指针派发次序是 innermost → outermost（命中路径逆序），
/// 所以这不是「先到先得的运气」，而恰好复刻了键盘那条「页面专属优先，页面没接才轮到
/// 全局」的既有语义。
///
/// 为什么单槽够用：[PointerDownEvent.pointer] 由引擎在每次新按下时分配，进程内单调
/// 递增、永不复用；同一次按下沿命中路径传递时携带的是**同一个** id，这正是判据。
///
/// **认领状态只能经 [dispatchClaimedMouseAction] 读写**：探测、执行、认领三步被封在
/// 那一个函数里，[_isClaimed] / [_claim] 是库私有的，调用点**没有**手搓这套协议的
/// 途径。
///
/// BUG-2031 之前它们是公开的、由每个入口各写一遍三步。七个入口里有一个（查词浮层的
/// dismiss barrier）写成了「调完回调就往下走」——一个 claim 都没有。后果是浮层可见时
/// 一次侧键被 barrier 与 app 根各派发一次：关词典 **+** 退书，而键盘 Esc 只关词典。
/// 那次教训的结论不是「再加一条守卫检查有没有写对」，而是**把写错的可能性删掉**。
class MouseBindingDispatch {
  MouseBindingDispatch._();

  static int? _claimedPointer;

  static bool _isClaimed(PointerDownEvent event) =>
      _claimedPointer == event.pointer;

  static void _claim(PointerDownEvent event) => _claimedPointer = event.pointer;

  /// 仅测试：清掉认领槽。静态态跨用例残留会让「第二个用例复用同一个 pointer id」
  /// 静默变成 no-op（测试假绿）。
  @visibleForTesting
  static void resetForTest() {
    _claimedPointer = null;
    MouseHoldRepeater._stop();
  }
}

/// 鼠标绑定派发的**唯一**入口：更内层已派发就让路，否则跑 [execute]，只有它确实
/// 执行了（返回 true）才认领这次按下。
///
/// 「探测」与「认领」之所以不能合成一步：解析到了但执行体没接的一层若也认领，就会把
/// 同一按钮上外层的合法绑定白白挡掉——等价于键盘侧「明明 ignored 却返回 handled」，
/// 症状是绑在 universal / global 上的键在某些页面莫名失灵。所以 [execute] 的返回值
/// 必须是「**真的执行了吗**」，不是「解析到了吗」。
///
/// [onHeldRepeat]：按住这颗键时的**连发**执行体，等价于键盘的 OS 自动重复
/// （`KeyRepeatEvent`）。传了且本次确实认领，就在 [kMouseHoldRepeatDelay] 后按
/// [kMouseHoldRepeatInterval] 反复调它，直到这颗键松开（同一 pointer 的 up / cancel，
/// 或 `buttons` 里这一位清零）、窗口失去前台、或它返回 false（「这次不该连发」——
/// 例如页面已卸载）。不传 = 一次一按，与改造前相同。
///
/// 为什么连发必须由这里出、不能靠外部改键软件：Logi Options+ 之类把侧键映射成键盘
/// 快捷键时，按下瞬间就发完整的「按下 + 松开」，Fushi 永远看不到一个被按住的键，
/// OS 自动重复无从产生。直接绑鼠标键时 Flutter 拿得到松开沿，按住语义只能在这一层
/// 补上。
///
/// 返回值与 [execute] 一致，供调用方需要时继续分流（多数入口忽略）。
bool dispatchClaimedMouseAction(
  PointerDownEvent event,
  bool Function() execute, {
  bool Function()? onHeldRepeat,
}) {
  if (MouseBindingDispatch._isClaimed(event)) return false;
  if (!execute()) return false;
  MouseBindingDispatch._claim(event);
  if (onHeldRepeat != null) MouseHoldRepeater._start(event, onHeldRepeat);
  return true;
}

/// 鼠标按住连发的起步延迟。取 Windows 键盘自动重复的出厂默认（延迟档位 1 ≈ 500 ms），
/// 让「按住侧键」与「按住它曾经映射的那个键盘键」手感一致。WebView 页内的鼠标桥
/// （`webViewMouseHoldRepeatScript`）用同一对常量。
const Duration kMouseHoldRepeatDelay = Duration(milliseconds: 500);

/// 鼠标按住连发的间隔：Windows 键盘重复速率出厂默认（≈30 次 / 秒）。
const Duration kMouseHoldRepeatInterval = Duration(milliseconds: 33);

/// 在**页面执行体**之外，哪些动作按住鼠标键时连发——只放行「步进」类：翻页、滚动、
/// seek、逐帧、倍速、音量、上一句 / 下一句、字幕延迟。翻转 / 打开 / 退出 / 制卡这类
/// 离散动作一次一按（按住侧键不能来回开关全屏、连退几级页面、连发制卡）。新增动作
/// 默认不连发，要连发须显式加进来。
///
/// 阅读器 / 有声书段直接复用键盘的 [isRepeatableReaderKeyboardShortcut]，两条通道
/// 同一份白名单。漫画不经本函数：它的键盘长按有自己的判决（翻页要等上一页动画落定），
/// 鼠标连发直接复用那份判决。
bool mouseBindingRepeatsWhileHeld(ShortcutAction action) {
  if (isRepeatableReaderKeyboardShortcut(action)) return true;
  switch (action) {
    case ShortcutAction.globalScrollLineDown:
    case ShortcutAction.globalScrollLineUp:
    case ShortcutAction.globalScrollPageDown:
    case ShortcutAction.globalScrollPageUp:
    case ShortcutAction.videoSeekBackward:
    case ShortcutAction.videoSeekForward:
    case ShortcutAction.videoPreviousFrame:
    case ShortcutAction.videoNextFrame:
    case ShortcutAction.videoSpeedUp:
    case ShortcutAction.videoSpeedDown:
    case ShortcutAction.videoPreviousSubtitle:
    case ShortcutAction.videoNextSubtitle:
    case ShortcutAction.videoPreviousChapter:
    case ShortcutAction.videoNextChapter:
    case ShortcutAction.videoSubtitleDelayIncrease:
    case ShortcutAction.videoSubtitleDelayDecrease:
    case ShortcutAction.videoVolumeUp:
    case ShortcutAction.videoVolumeDown:
      return true;
    default:
      return false;
  }
}

/// 鼠标按住连发的计时器（[dispatchClaimedMouseAction] 的 `onHeldRepeat`）。
///
/// 全进程同一时刻只有一颗键在连发：新的一次认领直接接替旧的（与键盘「最后按下的键
/// 才自动重复」一致）。松开检测挂在 [GestureBinding.pointerRouter] 的全局路由上——
/// 不依赖任何一层 [Listener] 还在树里，页面在连发中途卸载也收得到松开沿。
class MouseHoldRepeater {
  MouseHoldRepeater._();

  static int? _pointer;
  static int _buttonBit = 0;
  static bool Function()? _repeat;
  static Timer? _timer;
  static bool _routed = false;

  /// 仅测试：此刻是否有键在连发。
  @visibleForTesting
  static bool get isActive => _timer != null;

  static void _start(PointerDownEvent event, bool Function() repeat) {
    _stop();
    final int? button = domMouseButtonFromPointerButtons(event.buttons);
    final int? bit = button == null
        ? null
        : pointerButtonBitForDomMouseButton(button);
    if (bit == null) return;
    _pointer = event.pointer;
    _buttonBit = bit;
    _repeat = repeat;
    if (!_routed) {
      GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointerEvent);
      _routed = true;
    }
    _timer = Timer(kMouseHoldRepeatDelay, () {
      if (!_tick()) return;
      _timer = Timer.periodic(kMouseHoldRepeatInterval, (_) => _tick());
    });
  }

  /// 跑一次连发；该停就停并返回 false。
  static bool _tick() {
    final bool Function()? repeat = _repeat;
    final AppLifecycleState? lifecycle =
        SchedulerBinding.instance.lifecycleState;
    // 窗口转后台时松开沿可能落在别的窗口上、再也回不来：宁可停掉，不留一颗「卡住」
    // 的键。lifecycle 为 null（测试 / 引擎未上报）时不据此判断。
    if (repeat == null ||
        (lifecycle != null && lifecycle != AppLifecycleState.resumed) ||
        !repeat()) {
      _stop();
      return false;
    }
    return true;
  }

  static void _onPointerEvent(PointerEvent event) {
    if (event.pointer != _pointer) return;
    if (event is PointerUpEvent ||
        event is PointerCancelEvent ||
        event is PointerRemovedEvent ||
        event.buttons & _buttonBit == 0) {
      _stop();
    }
  }

  static void _stop() {
    _timer?.cancel();
    _timer = null;
    _repeat = null;
    _pointer = null;
    _buttonBit = 0;
    if (_routed) {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointerEvent);
      _routed = false;
    }
  }

  /// 仅测试：停掉连发、摘掉全局路由。
  @visibleForTesting
  static void resetForTest() => _stop();
}
