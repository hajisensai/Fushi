/// dictionaryPopup scope 的手柄执行钩子与进程级登记处（手柄重设计 P2）。
///
/// 为什么在 shortcuts 层放一个纯回调对象、而不是直接引用
/// `DictionaryPopupController` / `DictionaryPopupWebViewState`：
/// GamepadService（shortcuts 层）是消费方，弹窗栈与 WebView 状态在 pages 层——
/// 依赖必须单向（pages → shortcuts）。controller 在自己那侧构造好钩子注册进来，
/// 服务侧只见函数，不见弹窗类型。
///
/// 分发次序（`GamepadService._dispatchButton` / `wrapWithGlobalNavigation`）：
/// **页面 Actions 永远优先**，弹窗解析只吃页面没消费的按钮——与 universal
/// 「返回上一级」同一哲学（页面专属键优先，兜底才轮到跨页面能力）。因此
/// dictionaryPopup 的手柄默认键必须挑各媒体页没占用的位（dpad上下/X/Y 会被
/// video 的音量与字幕句跳转先吃掉，那是**有意**的让位，不是 bug——视频页
/// 弹窗内导航走字幕选字光标）。
library;

import 'package:flutter/foundation.dart' show visibleForTesting;

/// 一组由弹窗宿主（`DictionaryPopupController`）提供的执行回调。全部指向
/// **栈顶可见**弹窗；无可见弹窗时 [hasVisiblePopup] 为 false，登记处直接跳过。
class DictionaryPopupGamepadHooks {
  const DictionaryPopupGamepadHooks({
    required this.hasVisiblePopup,
    required this.entryMove,
    required this.mineFirstEntry,
    required this.playFirstAudio,
    required this.scrollBy,
  });

  /// 当前栈里是否有可见弹窗（常驻隐藏热槽不算）。
  final bool Function() hasVisiblePopup;

  /// 词条焦点移到下/上一个词条并滚进视口（popup.js
  /// `fushiFocusDictionaryEntryMove`，与 Alt+滚轮同一执行体）。
  final Future<void> Function(bool forward) entryMove;

  /// 制卡：点第一个可见词条的加号（`fushiPopupMineFirstEntry`，单一制卡桥）。
  final Future<void> Function() mineFirstEntry;

  /// 发音：点第一个可见词条的发音按钮（`fushiPopupPlayFirstAudio`）。
  final Future<void> Function() playFirstAudio;

  /// 右摇杆连续滚动弹窗内容 [dy] CSS 像素（正=内容向下滚）。
  final Future<void> Function(double dy) scrollBy;
}

/// 进程级登记栈（与 `PageScrollRegistry` 同构）：每个弹窗 controller 构造时
/// push、dispose 时 pop。[current] 取**最近注册且当前有可见弹窗**的一组钩子——
/// 同一时刻现实中只有活跃路由的弹窗可见，可见性过滤天然消掉「首页 controller
/// 常驻但视频页在顶」的歧义。
class DictionaryPopupGamepadRegistry {
  DictionaryPopupGamepadRegistry._();

  static final List<DictionaryPopupGamepadHooks> _stack =
      <DictionaryPopupGamepadHooks>[];

  static void push(DictionaryPopupGamepadHooks hooks) => _stack.add(hooks);

  static void pop(DictionaryPopupGamepadHooks hooks) => _stack.remove(hooks);

  static DictionaryPopupGamepadHooks? get current {
    for (int i = _stack.length - 1; i >= 0; i--) {
      if (_stack[i].hasVisiblePopup()) return _stack[i];
    }
    return null;
  }

  @visibleForTesting
  static void debugClear() => _stack.clear();

  @visibleForTesting
  static int get debugDepth => _stack.length;
}

/// 手柄重设计 P5：游戏内查词卡片的**独占**手柄路由（仅 Windows galgame 链路）。
///
/// 与 [DictionaryPopupGamepadRegistry]（app 内弹窗的兜底路由）语义相反：游戏在
/// 前台、卡片可见时，手柄绝不能驱动后台 app 的页面 Actions / 焦点移动 / 返回
/// ——按到 B 把后台 app 退了一页是灾难。所以 GamepadService 在分发**最前端**
/// 检查本路由：命中弹窗动作（词条导航/制卡/发音）就经钩子转发进卡片 WebView2，
/// 未命中的按钮也一律吞掉（卡片可见期间手柄专属卡片；游戏自己经原生输入照常
/// 收到手柄，本路由只管 app 进程这一份轮询）。
///
/// 由 gal 游戏内查词 controller 在卡片显示时设置、隐藏/会话结束时清除。
class GalIngameLookupGamepadRoute {
  GalIngameLookupGamepadRoute._();

  static DictionaryPopupGamepadHooks? _current;

  /// 当前独占钩子；卡片不可见（或未设置）返回 null，分发照常走 app 路径。
  static DictionaryPopupGamepadHooks? get current {
    final DictionaryPopupGamepadHooks? hooks = _current;
    if (hooks == null || !hooks.hasVisiblePopup()) return null;
    return hooks;
  }

  static void set(DictionaryPopupGamepadHooks? hooks) => _current = hooks;

  @visibleForTesting
  static void debugClear() => _current = null;
}
