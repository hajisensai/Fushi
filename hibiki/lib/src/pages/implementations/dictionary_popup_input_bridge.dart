import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;

import 'package:hibiki/src/focus/webview_key_bridge.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';
import 'package:hibiki/src/utils/misc/platform_utils.dart';

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
///
/// 宿主 [scope] 未命中时**回落 [ShortcutScope.universal]**，与页面派发路径的兜底
/// 顺序完全一致（页面专属键优先，其后才是「返回上一级」）。少了这一跳，默认的
/// Esc 关词典会在**弹窗持焦时**整条失效：Esc 现在绑在 universal 的 globalBack 上，
/// 而宿主 scope 里根本没有它——BUG-1071 修好的正是这条弹窗持焦路径，不能重开。
ShortcutAction? resolveDictionaryPopupInputToken({
  required HibikiShortcutRegistry registry,
  required String token,
  required ShortcutScope scope,
}) {
  final MouseBinding? mouse = MouseBinding.deserialize(token);
  if (mouse != null) {
    return registry.resolveMouse(mouse.button, scope: scope) ??
        registry.resolveMouse(mouse.button, scope: ShortcutScope.universal);
  }
  final InputBinding? keyboard = InputBinding.deserialize(token);
  if (keyboard != null) {
    return registry.resolveKeyboard(
          keyboard.key,
          modifiers: keyboard.modifiers,
          scope: scope,
        ) ??
        registry.resolveKeyboard(
          keyboard.key,
          modifiers: keyboard.modifiers,
          scope: ShortcutScope.universal,
        );
  }
  return null;
}

/// 弹窗侧桥的 `callHandler` 名。宿主 [DictionaryPopupWebView] 注册同名 handler。
const String kDictionaryPopupInputHandler = 'hostInputToken';

/// 弹窗表面的**指针**由谁第一手拥有：Flutter 宿主，还是原生 WebView。
///
/// BUG-1269 复诉的根因就在这条分界上，两侧的输入模型是真实不同的：
/// * **Windows**：fork 的 `flutter_inappwebview_windows` 用 WebView2 的
///   composition controller（无窗口 visual hosting），WebView **没有自己的输入
///   窗口**——指针先到 Flutter 的 [Listener]，再由 fork 逐个转发给 WebView2。而它
///   的 `PointerButton` 枚举只有 `{none, primary, secondary, tertiary}`：鼠标**侧键**
///   （后退/前进）在 `_getButton` 里折成 `none`，native 侧落到 default，于是侧键在
///   到达 WebView2 之前就被整条丢弃。JS 桥再正确也收不到一个 `Mouse3`/`Mouse4`
///   ——绑到侧键的「关闭词典」在弹窗表面**永远**无反应。既然指针本来就先经过
///   Flutter，正确的做法不是让 native 把它送进 WebView 再绕回来（那还会顺带打开
///   Chromium 的「侧键=历史后退」默认行为，阅读器正文换章有历史，会乱跳），而是
///   让宿主在 Flutter 侧就地消费。
/// * **Android / iOS / macOS / Linux**：WebView 是真正的原生视图，指针被它直接吃掉，
///   Flutter 的 [Listener] 根本收不到 —— 只能靠弹窗内的 JS 桥回传。
///
/// 所以这不是「平台特例分支」，而是指针所有权的事实：谁先拿到事件，谁负责分发。
/// 两条路**互斥**，故 [dictionaryPopupInputBridgeScript] 在宿主拥有指针时不装鼠标
/// 监听——否则中键/右键会被两条路各触发一次（关词典幂等看不出来，漫画翻页会翻两页）。
bool get hostOwnsDictionaryPopupPointerInput => isWindowsPlatform;

/// Flutter 焦点落在弹窗子树里时，把命中 [spec] 的按键折成与 JS 桥**完全同形**的
/// token（`Escape` / `Ctrl+KeyD`），未命中返回 null。
///
/// BUG-1347 键盘那一半：JS 桥只在「弹窗 DOM 真能收到 keydown」的平台生效，Windows 的
/// 无窗口 WebView2 收不到（fork 不转发键盘）。但那里的按键**一定**会到 Flutter，问题
/// 只是**到不了宿主页面的 `Focus`**：视频/首页查词把整棵浮层挂在**根 Overlay**
/// （为了盖过 media_kit 全屏路由），焦点一旦进入浮层子树，`KeyEvent` 的冒泡链是
/// 根 Overlay → Navigator → App，**永远不经过宿主页面那个 `Focus(onKeyEvent:)`**。
/// 用户点了弹窗里的词（唤出嵌套层）之后焦点正好就在那里——这就是「第一层有效、
/// 嵌套无效」：第一层是从页面里点出来的、焦点还在页面上。
///
/// 所以在弹窗层自己挂一个 `Focus` 接住它，折成同一个 token 交回宿主。与 JS 桥天然
/// **互斥**：按键只会到达其中一个（DOM 收得到键的平台，Flutter 焦点就不在浏览器外面），
/// 故不需要平台判据——谁收到谁转发。
///
/// 用的是与 [dictionaryPopupInputSpecFor] 生成键表**同一个** [InputBinding.serialize]，
/// 所以两边的字符串必然对齐，不存在「表里写 A、运行时折出 B」的漂移。
String? dictionaryPopupKeyToken({
  required LogicalKeyboardKey key,
  required Set<ModifierKey> modifiers,
  required DictionaryPopupInputSpec spec,
}) {
  if (spec.keyTokens.isEmpty) return null;
  final String token = InputBinding(key: key, modifiers: modifiers).serialize();
  return spec.keyTokens.contains(token) ? token : null;
}

/// 指针落在弹窗表面时，把命中 [spec] 的鼠标按下折成与 JS 桥**完全同形**的 token
/// （`Mouse1`/`Mouse2`/`Mouse3`/`Mouse4`），未命中返回 null。
///
/// 复用同一套 token 而不是另开一条「宿主鼠标」通道，是为了让两条路径最终汇进同一个
/// [resolveDictionaryPopupInputToken] → 同一个宿主落地入口：改键、scope 减法、动作
/// 分发全都只有一份实现。纯函数，供守卫直接断言。
String? dictionaryPopupPointerToken({
  required int buttons,
  required DictionaryPopupInputSpec spec,
}) {
  final int? domButton = domMouseButtonFromPointerButtons(buttons);
  if (domButton == null) return null;
  if (!spec.mouseButtons.contains(domButton)) return null;
  return 'Mouse$domButton';
}

/// 生成注入弹窗 WebView 的桥脚本。
///
/// 长按不转发（`forwardRepeats: false`）：关词典是一次性动作，按住 Esc 不该关掉
/// 整条弹窗栈里的每一层。`stopPropagation` 打开：这些键既然已经交给宿主，就不能
/// 再让 popup.js 自己的监听（词条导航 / 制卡）二次响应同一次按下。
///
/// [hostOwnsPointer] 为 true（Windows，见 [hostOwnsDictionaryPopupPointerInput]）时
/// **不装**鼠标监听：那里的指针由宿主的 [Listener] 第一手拥有并分发，弹窗内再装一份
/// 就是同一次按下走两条路。默认按运行平台取值，测试可显式传入。
String dictionaryPopupInputBridgeScript(
  DictionaryPopupInputSpec spec, {
  bool? hostOwnsPointer,
}) {
  final bool byHost = hostOwnsPointer ?? hostOwnsDictionaryPopupPointerInput;
  return webViewKeyBridgeScript(
    handlerName: kDictionaryPopupInputHandler,
    keys: spec.keyTokens,
    // 宿主拥有指针时连**表**也下发空的，不只是不装 listener：热槽 WebView 跨查词
    // 长期存活，万一某次注入曾装过鼠标监听，空表让它永远不命中（表每次注入都覆盖）。
    mouseButtons: byHost ? const <int>[] : spec.mouseButtons,
    installMouseListeners: !byHost,
    deferToPopupModal: true,
    forwardRepeats: false,
    stopPropagation: true,
  );
}
