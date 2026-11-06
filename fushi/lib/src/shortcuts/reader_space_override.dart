import 'package:flutter/services.dart' show LogicalKeyboardKey;

import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';

/// 有声书激活时，无修饰 Space 改作播放/暂停（媒体播放器惯例）。
///
/// 设计：阅读器键盘解析里 reader scope 先于 audiobook scope，默认绑定中
/// Space=翻页、Ctrl+Space=播放/暂停，导致有声书场景按 Space 永远翻页。
/// 本函数仅在「有声书已激活 + 无任何修饰键 + 是 Space」时返回
/// [ShortcutAction.audiobookPlayPause] 覆写翻页；其余一律返回 null 表示
/// 不覆写，交回默认解析（翻页仍可用方向键/PageDown；Shift+Space 仍后退翻页；
/// Ctrl+Space 保留原义）。
///
/// Windows 输入法激活时按键会被输入法吞掉（BUG-430/1450），那是平台边界上的事：
/// 无文本焦点时 `WindowsImeGuard` 解除窗口 IME 关联，按键以正常逻辑键到达这里，
/// 本函数不需要任何 IME 特例。
ShortcutAction? resolveReaderSpaceOverride({
  required LogicalKeyboardKey key,
  required Set<ModifierKey> modifiers,
  required bool hasActiveAudiobook,
}) {
  if (modifiers.isNotEmpty) return null;
  if (!hasActiveAudiobook) return null;
  if (key != LogicalKeyboardKey.space) return null;
  return ShortcutAction.audiobookPlayPause;
}

/// 键盘裸左右键翻页必须跟随阅读方向（BUG-098）：
/// - 竖排 RTL（`vertical-rl`，日文默认）：从右往左读，「下一页」在左 → 左箭头前进、
///   右箭头后退。
/// - 横排 LTR（`horizontal-tb`）：从左往右读，「下一页」在右 → 右箭头前进、
///   左箭头后退。
///
/// 默认键盘绑定把「右箭头=前进」写死，对 RTL 书方向恰好相反。本函数在注册表解析前
/// 介入，仅处理**键盘**「无修饰的裸左/右箭头」；其它键（上/下箭头、PageUp/PageDown、
/// Space、字母键，以及 Ctrl+方向键的有声书句子导航）一律返回 null，交回默认解析不受影响。
/// D-pad / gamepad / joystick 事件必须先走 gamepad registry，不进入这个 helper。
///
/// [reverse]（TODO-120 用户开关 `reverse_arrow_page_turn`，默认 false）只对**最终
/// 方向**整体取反：先按阅读方向（[rtl]）算出前进/后退，再在开关打开时把前进/后退对调。
/// 这样无论 LTR 还是 RTL，开关都只把键盘左右键当前行为整体反过来（左↔右互换），
/// 与 RTL 自动判定正交叠加，不影响手柄映射、字母快捷键或滑动手势。
///
/// TODO-992：本覆写只为「翻页绑定」做阅读方向校正，**必须尊重用户改键**。调用方传入
/// 该裸键当前在阅读器 co-active 组（reader + audiobook scope）解析出的 [boundAction]：
/// - 仍是翻页动作（[ShortcutAction.readerPageForward]/[ShortcutAction.readerPageBackward]）
///   → 按阅读方向重定向，保持 BUG-098/099/TODO-120 既有行为。
/// - 被用户改绑成别的动作（如有声书上/下句）或显式解绑（null）→ 返回 null 让出，
///   交回注册表解析用户的真实绑定（修复「连续滚动模式下左右键仍只翻页不动有声书」，
///   分页与连续两模式都走这条统一解析，故两模式一并修复）。
/// 默认绑定下裸 Left/Right 仍解析为翻页，故默认用户行为不变（Never break userspace）。
ShortcutAction? resolveReaderArrowPageTurn({
  required LogicalKeyboardKey key,
  required Set<ModifierKey> modifiers,
  required bool rtl,
  required ShortcutAction? boundAction,
  bool reverse = false,
}) {
  if (modifiers.isNotEmpty) return null;
  final bool leftIsForward = rtl ^ reverse;
  final bool isLeft = key == LogicalKeyboardKey.arrowLeft;
  final bool isRight = key == LogicalKeyboardKey.arrowRight;
  // 阅读方向校正只接管「出厂的物理方向绑定」：左 = 后退、右 = 前进（见
  // shortcut_defaults.dart）。用户把该键改绑成别的动作、解绑，或改成**相反**的
  // 翻页方向，都是明确意图 → 不覆写，交回注册表解析真实绑定。此前只判「是不是
  // 翻页动作」，把右键绑成「上一页」照样被按阅读方向改回「下一页」（反馈 aiRZmYl5zS）。
  final ShortcutAction factoryBinding = isLeft
      ? ShortcutAction.readerPageBackward
      : ShortcutAction.readerPageForward;
  if ((!isLeft && !isRight) || boundAction != factoryBinding) return null;
  if (isLeft) {
    return leftIsForward
        ? ShortcutAction.readerPageForward
        : ShortcutAction.readerPageBackward;
  }
  if (isRight) {
    return leftIsForward
        ? ShortcutAction.readerPageBackward
        : ShortcutAction.readerPageForward;
  }
  return null;
}

/// 触摸 / 鼠标滑动翻页方向必须跟随书写方向（横排 LTR 与竖排 vertical-rl 相反），
/// 与键盘方向键 [resolveReaderArrowPageTurn] 的 `leftIsForward = rtl ^ reverse` 同构。
///
/// 返回「向左滑（`onSwipe('left')`，手指 dx<0）是否 = 前进」。
/// - [invert] = 用户 `invertSwipeDirection` 开关（默认 true）。
/// - [rtl] = 竖排 vertical-rl（日文默认，`_isRtlReading`）。
///
/// `invert ^ rtl` 的四象限：
/// - 竖排默认(rtl=T, invert=T) → false：右滑前进（**与历史行为一致**，不破坏既有手感）。
/// - 横排默认(rtl=F, invert=T) → true：左滑前进（LTR 下一页在右，推内容向左露出=前进）。
///
/// 此前滑动路径只用 [invert] 不看书写方向，横排与竖排共用同一套映射（横排方向反了）；
/// 键盘路径早已翻转，滑动漏了，本谓词补齐。
bool swipeLeftIsForward({required bool invert, required bool rtl}) =>
    invert ^ rtl;

/// 分页模式一拍滚轮 / 触控板（`onWheelPaginate`）→ 是否前进（反馈 794gISjvgV）。
///
/// [deltaPositive] = JS 主轴 delta > 0（handler 收到的 `'forward'`）；[horizontal] =
/// 主轴是横向；[trackpad] = JS `_isTrackpadWheel` 判为触控板。
///
/// * **纵向鼠标**：delta > 0 = 前进，与连续模式滚轮同口径；鼠标滚轮的这条约定由
///   TODO-737 定死，不受任何反转开关影响。
/// * **纵向触控板**（BUG-3358 补漏）：两指上下滑与两指横滑同属「滑动翻页」，同一判据——
///   默认开关（invert = true）下按原生滚动语义（delta > 0，即内容跟手往上走 = 前进，
///   与修复前逐拍一致），关掉「反转滑动翻页方向」则整体反转。纵向与书写方向无关
///   （横排 / 竖排的分页都不沿纵轴排页），故不看 [rtl]。此前这一象限直接返回
///   delta 符号，翻页（paginated）与视觉小说（vn）模式下两指上下滑不认开关。
/// * **横向鼠标**（倾斜滚轮 / Shift+滚轮）：按原生滚动语义——视口往书页前进的方向滚
///   就是前进。横排书页往右排（delta > 0 前进），竖排 vertical-rl 往左排（delta < 0
///   前进）。此前不看书写方向，竖排里向「下一页那一侧」滚反而后退。
/// * **横向触控板**：两指横滑就是滑动翻页，与触摸滑动同一套语义——原生滚动内容跟手，
///   delta > 0 即手指向左划，按 [swipeLeftIsForward] 折成前进 / 后退，于是用户的
///   「反转滑动翻页方向」开关也管到触控板。此前这条走的是滚轮约定、不认任何开关
///   （反馈原话：「试过几个开关，都对触摸板的方向反转没用」）。默认开关（invert =
///   true）下与「视口往前进方向滚」逐象限一致。
bool readerWheelTickIsForward({
  required bool deltaPositive,
  required bool horizontal,
  required bool trackpad,
  required bool rtl,
  required bool invertSwipe,
}) {
  if (!trackpad) return horizontal ? deltaPositive != rtl : deltaPositive;
  if (!horizontal) return deltaPositive == invertSwipe;
  return deltaPositive == swipeLeftIsForward(invert: invertSwipe, rtl: rtl);
}

/// 桌面阅读器 / 查词弹窗「复制选中文字」兼容层（BUG-402 Windows、BUG-4127 macOS）。
///
/// 两个桌面平台的浏览器原生 `copy` 都收不到这一按键，只是断法不同：
/// * Windows：WebView 走 WebView2 合成模式，fork 的 `flutter_inappwebview_windows`
///   只转发鼠标、不转发键盘给 WebView2，左键能建立原生选区，但 Ctrl+C / 右键复制
///   都到不了 WebView2（BUG-402）。
/// * macOS：点击阅读器正文后 first responder **通常仍是 `FlutterView`**——BUG-2948
///   真机取证；机制见 BUG-2508（desktop_drop 的 DropTarget 压在窗口最上层，点击由
///   引擎转发给平台视图）与 BUG-3131（fork 不调 `makeFirstResponder`）。此时 Flutter
///   不处理 ⌘C，Runner 菜单 Edit > Copy 的 `copy:` 发给 first responder =
///   FlutterView，它不实现 `copy:`，WebKit 收不到。例外：DOM 节点获焦时 WebKit 会把
///   WKWebView 交成 first responder（BUG-2447 / BUG-3828，见 caret.part.dart
///   `_handleKeyEvent` 注释），那时原生 copy 本身可用，⌘C 也到不了 Flutter，本谓词
///   不会被调到，不会重复处理——两种情形下接管都成立。
///   旧注释「macOS 的 WebView 自带原生 copy」是没在 Mac 上验证过的错误前提。
///
/// BUG-1451：查词弹窗（[DictionaryPopupWebView]）与阅读器正文**共用**本谓词——两者
/// 断在同一个平台事实上，判据必须同源，否则改一处另一处会漂开。
///
/// 本谓词只判定「这是不是本平台该接管的复制手势」：键必须是 C，修饰键必须**恰好**
/// 是本平台的主修饰键——Windows 只认 {Ctrl}、macOS 只认 {Meta}（⌘）；混入
/// Shift / Alt / 另一主修饰键的组合（Ctrl+Shift+C、⌘⇧C 等）一律不接管。命中后由
/// 调用方取 `window.getSelection()`（浏览器原生选区，**不是** `window.fushiSelection`
/// 查词选区）的文本写入系统剪贴板。Linux / 移动端与其余组合一律返回 false，交回
/// 默认处理，不吞键。
bool desktopShouldHandleCopyGesture({
  required LogicalKeyboardKey key,
  required Set<ModifierKey> modifiers,
  required bool isWindows,
  required bool isMacOS,
}) {
  if (key != LogicalKeyboardKey.keyC) return false;
  final ModifierKey primary;
  if (isWindows) {
    primary = ModifierKey.ctrl;
  } else if (isMacOS) {
    primary = ModifierKey.meta;
  } else {
    return false;
  }
  return modifiers.length == 1 && modifiers.contains(primary);
}

/// TODO-1370：长按方向键连续切句。判断一个已解析出的阅读器/有声书快捷动作是否应随
/// OS 键盘自动重复（[KeyRepeatEvent]）连续触发。
///
/// 根因：阅读器 `_handleKeyEvent` 在解析快捷键前有 `event is! KeyDownEvent` 闸门，
/// 把长按产生的 KeyRepeat 事件全部丢弃（字符光标除外），所以按住 Ctrl+←/→（或用户
/// 改绑成裸 ←/→）的「上一句/下一句」只在按下瞬间触发一次，无法连续切句——而视频
/// 播放器经 `SingleActivator(includeRepeats: true)`、手柄 D-pad 经 `GamepadFrameProcessor`
/// 自动重复，两者都连续。本谓词让阅读器键盘路径与它们对齐。
///
/// 只放行「移动 / 前进后退」类动作：翻页（[ShortcutAction.readerPageForward] /
/// [ShortcutAction.readerPageBackward]）与有声书上一句/下一句
/// （[ShortcutAction.audiobookPrevSentence] / [ShortcutAction.audiobookNextSentence]）。
/// 离散动作（查词 / 书签 / 关词典 / 打开菜单 / 播放暂停）必须一次一按，绝不随长按连发
/// （否则按住会连续查词 / 反复开关播放），故默认一律返回 false；新增 action 也默认不
/// 可重复，需显式加入白名单才连发。
bool isRepeatableReaderKeyboardShortcut(ShortcutAction action) {
  switch (action) {
    case ShortcutAction.readerPageForward:
    case ShortcutAction.readerPageBackward:
    case ShortcutAction.audiobookNextSentence:
    case ShortcutAction.audiobookPrevSentence:
      return true;
    default:
      return false;
  }
}
