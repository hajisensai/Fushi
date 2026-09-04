import 'dart:async';

import 'package:flutter/foundation.dart' show VoidCallback;

/// 「先发起落库、立刻退出」的唯一退出原语（BUG-2119）。
///
/// 视频页退出汇聚点此前是 `await flushPosition(); nav.pop();`——把**离开页面**
/// 绑在**一次数据库写入成功**上。写入一旦抛错（`SqliteException`）或永不完成
/// （连接被一条挂起的写语句毒化、drift 事务锁被占死），`pop` 永远到不了：
/// Esc / 返回箭头 / 手柄 B / 系统返回四条通道同时失灵，用户被锁在视频页里。
/// 那是 2026-09-04 真机上发生的事：一条写语句 `SQLITE_BUSY` 后未 reset，
/// 之后整条连接上每一次 COMMIT 都抛「SQL statements in progress」。
///
/// 这里把两件事解耦：
/// * [persist] **同步启动**（drift 请求在本调用返回前已排进执行队列，后续页面
///   对同一行的读取排在它之后，进度不会被读到旧值）；
/// * [exit] **无条件、同步**执行——不等落库完成，也不看落库成败；
/// * 落库的失败只走 [onPersistError] 记账，永远不会阻断退出。
///
/// 「退出前先 await 落库」的原始动机是怕 `State` 销毁把写入竞争掉；但 Dart
/// future 不随 widget 销毁而消失，drift 的写请求一旦发出就会在后台完成——
/// 那层 await 不保护任何东西，只制造了本 bug。
void exitAfterPersist({
  required Future<void> Function() persist,
  required VoidCallback exit,
  required void Function(Object error, StackTrace stack) onPersistError,
}) {
  Future<void> pending;
  try {
    pending = persist();
  } catch (error, stack) {
    onPersistError(error, stack);
    exit();
    return;
  }
  unawaited(
    pending.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) => onPersistError(error, stack),
    ),
  );
  exit();
}
