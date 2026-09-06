/// TODO-1066 — app 外全局查词（`ShortcutScope.globalExternal`）的**非键盘触发源**
/// 登记处。
///
/// 为什么需要它：执行体 `GlobalLookupController.triggerSelectionLookup` 住在
/// lookup 层，消费方 `GamepadService` 住在 shortcuts 层，依赖必须单向
/// （lookup → shortcuts）。controller 在自己那侧把入口注册进来，服务侧只见一个
/// 函数，不见 controller 类型——与 [DictionaryPopupGamepadRegistry] /
/// [GalIngameLookupGamepadRoute] 同一范式。
///
/// 为什么是**单槽**而不是栈：app 外全局查词全进程只有一个 controller
/// （`GlobalLookupController` 由 `AppModel` 持有，`main.dart` 启动一次），不存在
/// 「多个宿主争同一触发」的情形。栈只会给它编造一个不存在的歧义。
///
/// 为什么手柄这条要单独开一条不经 Flutter 焦点树的路：Windows 上主窗一失焦，
/// `MainWindowFocusGate` 就把整棵子树设成 `descendantsAreFocusable: false`，
/// `Actions.maybeInvoke<GamepadButtonIntent>` 那条主派发路径必然落空——而"用户
/// 正在别的程序里看文本"恰恰是本功能**唯一**的使用场景。底层的 GameInput 轮询
/// 与前台焦点无关（每手柄一条 native 线程 8ms 轮询），所以按钮读得到，只是派发
/// 链断了；这里补的就是那一段。
library;

import 'package:flutter/foundation.dart' show visibleForTesting;

class GlobalExternalLookupRoute {
  GlobalExternalLookupRoute._();

  static Future<void> Function()? _trigger;

  /// 当前触发入口；未注册（非桌面平台 / controller 未 start）时为 null，此时
  /// 分发照常沿原路径继续——**不吞按钮**。功能不可用时把键"吃掉"会让用户以为
  /// 手柄坏了，比没有这个功能更糟。
  static Future<void> Function()? get current => _trigger;

  /// 由 `GlobalLookupController.start` 注册、`dispose` 时传 null 注销。
  static void set(Future<void> Function()? trigger) => _trigger = trigger;

  @visibleForTesting
  static void debugClear() => _trigger = null;
}
