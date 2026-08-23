// BUG-1619 根治层：把「Flutter 焦点树能持有焦点 ⟺ 主窗拥有 OS 焦点」变成一条
// 结构性不变量，而不是在每个 requestFocus 调用点各写一次判据。
//
// 为什么必须在根部立这条不变量（而不是逐点加 if）：
//
//   ① Win32 硬语义：SetFocus(子窗) 在其顶层窗口非活动时**连带激活该顶层窗口**。
//   ② Flutter 引擎：Dart 侧 requestFocus 后，引擎为让键盘 / IME 工作，无条件对
//      FlutterView 调 SetFocus。
//   ③ 于是「主窗不在前台时的任意一次 requestFocus」＝把主界面抢到用户正在用的
//      游戏 / 浏览器前面。
//
// ①② 都不在我们手里，能控制的只有 ③。而 ③ 的入口穷举不完——真机上「拖面板顶栏」
// 走的是 FushiFocusController.ensureFocus，「复制文本」那条至今没能在全仓 16 处
// requestFocus 里定位到。逐点加判据 = 每发现一个入口补一刀；在根部立不变量 =
// 这个特殊情况根本不存在。
//
// 关门会让出焦点，所以必须配套开门补焦点（[FushiFocusController] 订阅
// [mainWindowForegroundNotifier]），否则用户切回主窗会发现整页没有焦点、键盘 /
// 手柄快捷键全不响应（TODO-900 的老症状）。
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:fushi/src/sync/desktop_foreground_guard.dart';
import 'package:window_manager/window_manager.dart';

/// 主窗此刻是否拥有 OS 焦点。**窗口级**真值，不是进程级。
///
/// 非桌面 / 非 Windows 恒 true：那些平台没有多顶层窗口结构，不该改变既有语义。
final ValueNotifier<bool> mainWindowForegroundNotifier =
    ValueNotifier<bool>(true);

/// 本平台是否需要这条不变量。
bool get mainWindowFocusGateApplies => Platform.isWindows;

/// 监听主窗自己的 focus / blur（window_manager 底层是主窗 `WM_NCACTIVATE`，
/// 窗口级信号，不是 `AppLifecycleState.resumed` 那种进程级信号），刷新
/// [mainWindowForegroundNotifier]。
///
/// 与 widget 分开是为了两件事：widget 只读真值（好测），以及非 UI 代码
/// （焦点控制器）也能订阅同一个真值。
class MainWindowForegroundWatcher with WindowListener {
  MainWindowForegroundWatcher._();

  static final MainWindowForegroundWatcher instance =
      MainWindowForegroundWatcher._();

  bool _started = false;

  void start() {
    if (_started || !mainWindowFocusGateApplies) return;
    _started = true;
    windowManager.addListener(this);
    sync();
  }

  @override
  void onWindowFocus() => sync();

  @override
  void onWindowBlur() => sync();

  /// 事件只是「该重新看一眼」的触发器，真值一律现问系统：事件走 channel 有延迟，
  /// 到达时前台可能已经再次变化，照事件方向记账会把门开错。
  @visibleForTesting
  void sync() {
    final bool next = DesktopForegroundGuard.isMainWindowForeground();
    if (mainWindowForegroundNotifier.value != next) {
      mainWindowForegroundNotifier.value = next;
    }
  }
}

/// 焦点闸门本体：门关着时整棵子树不可聚焦，任何 requestFocus 都是 no-op。
///
/// 关门会让出焦点，所以闸门**自己**负责精确恢复：关门前记下当时的 primaryFocus，
/// 开门后还给它。不能把恢复外包给 [FushiFocusController]——那条只在「键盘/手柄
/// 焦点导航」实验开关打开时才有受管目标，而默认是关的（真机 A/B 实测：只靠它
/// 恢复时，焦点会从路由的 ModalScope 掉到最外层的 View Scope 回不来）。
class MainWindowFocusGate extends StatefulWidget {
  const MainWindowFocusGate({super.key, required this.child});

  final Widget child;

  @override
  State<MainWindowFocusGate> createState() => _MainWindowFocusGateState();
}

class _MainWindowFocusGateState extends State<MainWindowFocusGate> {
  bool _open = true;

  /// 闸门自己的节点：兜底恢复时先由它接住焦点，再 [FocusNode.nextFocus] 交给
  /// 子树里第一个可聚焦控件。
  final FocusNode _gateNode = FocusNode(
    debugLabel: 'fushi-main-window-focus-gate',
    skipTraversal: true,
  );

  /// 关门前持有焦点的节点，开门后还给它。只在关门那一刻取——关门之后
  /// primaryFocus 已经被让出，再取就只剩外层 scope 了。
  FocusNode? _restoreTarget;

  @override
  void initState() {
    super.initState();
    if (!mainWindowFocusGateApplies) return;
    _open = mainWindowForegroundNotifier.value;
    mainWindowForegroundNotifier.addListener(_onForegroundChanged);
  }

  @override
  void dispose() {
    if (mainWindowFocusGateApplies) {
      mainWindowForegroundNotifier.removeListener(_onForegroundChanged);
    }
    _gateNode.dispose();
    super.dispose();
  }

  void _onForegroundChanged() {
    final bool next = mainWindowForegroundNotifier.value;
    if (next == _open) return;
    if (!next) {
      _restoreTarget = FocusManager.instance.primaryFocus;
    }
    setState(() => _open = next);
    if (next) {
      final FocusNode? target = _restoreTarget;
      _restoreTarget = null;
      // 等这一帧的 descendantsAreFocusable 生效后再还，否则请求会被仍然关着的
      // 闸门吃掉。节点可能在后台期间被销毁 / 卸载，所以要重新确认它还在树上。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !mainWindowForegroundNotifier.value) return;
        if (target != null &&
            target.context != null &&
            target.canRequestFocus) {
          target.requestFocus();
          return;
        }
        _handOffFocusIntoSubtree();
      });
    }
  }

  /// 兜底：开门后子树里没人持焦时，把焦点交进去。
  ///
  /// 必需，而不是锦上添花：app 在**后台启动**（开机自启 / 被别的窗口压着拉起）
  /// 时，路由的 ModalScope 会在关门期间挂载并被挡下，而 Navigator 只在挂载那一
  /// 刻请求一次 scope 焦点、之后不会重试——不兜底的话整页焦点体系就永久失效，
  /// 连点击都救不回来（真机 A/B 实测：primaryFocus 卡在最外层 View Scope）。
  void _handOffFocusIntoSubtree() {
    final FocusNode? primary = FocusManager.instance.primaryFocus;
    if (primary != null && _gateNode.descendants.contains(primary)) return;
    if (!_gateNode.canRequestFocus) return;
    _gateNode.requestFocus();
    _gateNode.nextFocus();
  }

  @override
  Widget build(BuildContext context) {
    if (!mainWindowFocusGateApplies) return widget.child;
    // skipTraversal：这层只是闸门，不能成为方向导航的落点（否则焦点环会框住
    // 整个窗口，与首页那个整页 key-event sink 同款问题）。
    return Focus(
      focusNode: _gateNode,
      canRequestFocus: _open,
      descendantsAreFocusable: _open,
      skipTraversal: true,
      child: widget.child,
    );
  }
}
