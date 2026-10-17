// 由某个页面拥有、却挂在外层（根）ScaffoldMessenger 上的提示条。
//
// 页面不能给自己单独包一层 ScaffoldMessenger：Scaffold 只向最近的 messenger 登记，
// 包了之后根 messenger 的提示（同步报告等全局提示）就不再落在本页的 Scaffold 上，
// 而是画到下面被盖住的页面里。所以提示条只能挂在根上，由页面自己在离场时收掉。

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';

/// 一条页面拥有的 [SnackBar]：记住挂在哪个 messenger 上、是否已经结束，
/// 页面 dispose 时用 [closeAfterOwnerDisposed] 收掉。
class OwnedSnackBar {
  OwnedSnackBar._(this._messenger, this._controller) {
    unawaited(_controller.closed.whenComplete(() => _finished = true));
  }

  /// 在 [messenger] 上弹出 [snackBar]。
  factory OwnedSnackBar.show(
    ScaffoldMessengerState messenger,
    SnackBar snackBar,
  ) => OwnedSnackBar._(messenger, messenger.showSnackBar(snackBar));

  final ScaffoldMessengerState _messenger;
  final ScaffoldFeatureController<SnackBar, SnackBarClosedReason> _controller;
  bool _finished = false;

  /// 提示条关闭（任何原因）后完成。
  Future<SnackBarClosedReason> get closed => _controller.closed;

  /// 在事件回调等普通时机里关掉它（带退场动画；无障碍导航下立即移除）。
  void close() {
    if (_finished) return;
    _controller.close();
  }

  /// 在拥有者的 [State.dispose] 里调用：推到本帧之后再关。
  ///
  /// dispose 跑在 `BuildOwner.finalizeTree` 的锁树阶段。开着读屏
  /// （`MediaQuery.accessibleNavigation`）时 `hideCurrentSnackBar` 走同步
  /// `value = 0.0`，状态回调立刻对 ScaffoldMessenger `setState`，debug 抛
  /// 「setState() called when widget tree was locked」；`removeCurrentSnackBar`
  /// 同样是同步 `value = 0.0`。改在 deactivate 也不行：那是 build 阶段，messenger
  /// 是祖先而非正在 build 的节点的后代，抛「called during build」。帧后回调是
  /// 树解锁后的第一个安全点。
  ///
  /// 到回调时它若已自己结束（超时 / 被别处关掉）就不再关——此时
  /// `hideCurrentSnackBar` 收掉的会是别人的提示条；messenger 已卸载也跳过。
  void closeAfterOwnerDisposed() {
    if (_finished) return;
    SchedulerBinding.instance
      ..addPostFrameCallback((Duration _) {
        if (_finished || !_messenger.mounted) return;
        _controller.close();
      })
      ..ensureVisualUpdate();
  }
}
