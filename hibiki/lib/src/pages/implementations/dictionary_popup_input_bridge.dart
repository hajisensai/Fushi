import 'package:flutter/foundation.dart';

import 'package:hibiki/src/focus/webview_key_bridge.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';

/// 查词弹窗（纯原生 WebView）要交回宿主页面的输入集合。
///
/// 为什么需要它（BUG-1071 复诉的根因）：弹窗是原生平台视图，指针一旦落在它上面
/// （点词后弹窗就贴在光标旁，这是**常态**而非例外），键盘与鼠标事件全部只存在于
/// 弹窗的 DOM 里——宿主页面的 Flutter `Focus` / `Listener` 都收不到。于是：
/// * 「关闭词典」的**鼠标键**：宿主唯一的鼠标消费者是正文 WebView 的
///   `onPointerSeek`，只覆盖「点在弹窗矩形**之外**的正文区」。指针在弹窗上按侧键
///   ⇒ 事件被弹窗吃掉 ⇒ 完全无反应。
/// * 「关闭词典」的**键盘键**：BUG-1071 只在弹窗渲染那一刻把 Flutter 焦点抢回正文。
///   用户与弹窗交互一次（滚动看释义 / 点释义 / 点发音）OS 焦点就回到弹窗 ⇒ 之后
///   按键必然失效，表现为「时灵时不灵」。
///
/// 原有的转发桥（`onHostNavigationKey`）被 `capturesDictionaryPopupNavigationKeys`
/// 门控成**漫画页专属**，且键表硬编码 `ArrowLeft/ArrowRight/Escape` 三个值、不跟随
/// 用户改键。本 spec 把它一般化：宿主声明「哪些动作要在弹窗内也生效」，token 表由
/// 注册表**当前**绑定实时导出，键盘与鼠标同一条通道。
@immutable
class DictionaryPopupInputSpec {
  const DictionaryPopupInputSpec({
    this.keyTokens = const <String>[],
    this.mouseButtons = const <int>[],
  });

  /// 键盘 token（[InputBinding.serialize] 原样），如 `Escape` / `Ctrl+KeyD`。
  final List<String> keyTokens;

  /// `MouseEvent.button`（1=中键 / 2=右键 / 3=后退 / 4=前进）。
  final List<int> mouseButtons;

  /// 空 spec = 宿主不要求弹窗交回任何输入（基类默认）。仍会注入脚本以**清空**
  /// 热槽 WebView 上残留的旧 token 表，故不能拿它当「跳过注入」的信号。
  bool get isEmpty => keyTokens.isEmpty && mouseButtons.isEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DictionaryPopupInputSpec &&
          listEquals(keyTokens, other.keyTokens) &&
          listEquals(mouseButtons, other.mouseButtons);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(keyTokens), Object.hashAll(mouseButtons));

  @override
  String toString() =>
      'DictionaryPopupInputSpec(keys: $keyTokens, mouse: $mouseButtons)';
}

/// 把 [actions] 在 [scope] 下的**当前**键盘/鼠标绑定导出成弹窗 token 表。
///
/// 顺序按 [actions] 的迭代序 + 各自绑定序，稳定可比较（widget 的 `didUpdateWidget`
/// 靠 spec 相等性决定要不要重新注入，顺序抖动会造成无谓的重复注入）。同一 token
/// 在多个 action 上重复绑定时只保留一次。
///
/// 注册表尚未装载（[HibikiShortcutRegistry.isLoaded] 为 false）时返回空 spec：那时
/// `bindingsFor` 对每个动作都返回空集，与「用户主动清空了绑定」在数据上不可区分，
/// 按空表下发即可（弹窗侧不拦任何键），等装载完成宿主会再注入一次真表。
///
/// **恒减去 [ShortcutScope.dictionaryPopup] 已占用的绑定**：切词条 / 制卡是**弹窗内**
/// 的动作，必须在弹窗里生效，宿主不能把它们抢走。这条是不变式而不是各宿主的选项——
/// 视频页尤其需要：它的 dismiss 语义是「浮层可见时**任一**已映射的视频快捷键先关浮层」
/// （BUG-924），整个 video scope 都要转发，与弹窗内动作撞键的概率最高。放在数据层做
/// 减法，JS 侧就不必再判一次 scope。
DictionaryPopupInputSpec dictionaryPopupInputSpecFor({
  required HibikiShortcutRegistry registry,
  required Iterable<ShortcutAction> actions,
}) {
  if (!registry.isLoaded) return const DictionaryPopupInputSpec();

  final Set<String> reservedKeys = <String>{};
  final Set<int> reservedButtons = <int>{};
  for (final ShortcutAction action
      in ShortcutAction.actionsForScope(ShortcutScope.dictionaryPopup)) {
    final ShortcutBindingSet bindings = registry.bindingsFor(action);
    reservedKeys.addAll(bindings.keyboardBindings.map((b) => b.serialize()));
    reservedButtons.addAll(bindings.mouseBindings.map((b) => b.button));
  }

  final List<String> keys = <String>[];
  final List<int> buttons = <int>[];
  for (final ShortcutAction action in actions) {
    final ShortcutBindingSet bindings = registry.bindingsFor(action);
    for (final InputBinding kb in bindings.keyboardBindings) {
      final String token = kb.serialize();
      if (reservedKeys.contains(token)) continue;
      if (!keys.contains(token)) keys.add(token);
    }
    for (final MouseBinding mb in bindings.mouseBindings) {
      if (reservedButtons.contains(mb.button)) continue;
      if (!buttons.contains(mb.button)) buttons.add(mb.button);
    }
  }
  return DictionaryPopupInputSpec(
    keyTokens: List<String>.unmodifiable(keys),
    mouseButtons: List<int>.unmodifiable(buttons),
  );
}

/// 弹窗回传的 token → 动作。键盘与鼠标 token 的取值域天然不相交
/// （`MouseBinding.deserialize('Escape')` 与 `InputBinding.deserialize('Mouse3')`
/// 都是 null），故先试哪个都一样，不需要额外的类型标记位。
///
/// 解析走的是与键盘路径**同一个** `resolve*`，所以改键对两条路径同时生效——旧桥
/// 把键名硬编码在 JS 里，改键后 WebView 持焦时仍按老键位响应。
ShortcutAction? resolveDictionaryPopupInputToken({
  required HibikiShortcutRegistry registry,
  required String token,
  required ShortcutScope scope,
}) {
  final MouseBinding? mouse = MouseBinding.deserialize(token);
  if (mouse != null) {
    return registry.resolveMouse(mouse.button, scope: scope);
  }
  final InputBinding? keyboard = InputBinding.deserialize(token);
  if (keyboard != null) {
    return registry.resolveKeyboard(
      keyboard.key,
      modifiers: keyboard.modifiers,
      scope: scope,
    );
  }
  return null;
}

/// 弹窗侧桥的 `callHandler` 名。宿主 [DictionaryPopupWebView] 注册同名 handler。
const String kDictionaryPopupInputHandler = 'hostInputToken';

/// 生成注入弹窗 WebView 的桥脚本。
///
/// 长按不转发（`forwardRepeats: false`）：关词典是一次性动作，按住 Esc 不该关掉
/// 整条弹窗栈里的每一层。`stopPropagation` 打开：这些键既然已经交给宿主，就不能
/// 再让 popup.js 自己的监听（词条导航 / 制卡）二次响应同一次按下。
String dictionaryPopupInputBridgeScript(DictionaryPopupInputSpec spec) =>
    webViewKeyBridgeScript(
      handlerName: kDictionaryPopupInputHandler,
      keys: spec.keyTokens,
      mouseButtons: spec.mouseButtons,
      installMouseListeners: true,
      deferToPopupModal: true,
      forwardRepeats: false,
      stopPropagation: true,
    );
