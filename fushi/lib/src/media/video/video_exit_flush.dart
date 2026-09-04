import 'dart:async';

import 'package:flutter/foundation.dart' show VoidCallback;

/// 「发起落库、不等它」的唯一原语（BUG-2119）。
///
/// [persist] **同步启动**（drift 请求在本调用返回前已排进执行队列，后续对同一行
/// 的读取排在它之后，进度不会被读到旧值）；失败只走 [onPersistError] 记账，永远
/// 不向调用方抛出、也不让调用方等待。调用方随即做自己的事（pop 路由、换集……）。
///
/// 为什么不能 `await`：Dart future 不随 widget 销毁而消失，drift 的写请求一旦发出
/// 就会在后台完成——那层 await 不保护任何东西。它保护不了的东西却真实存在：一条
/// `SQLITE_BUSY` 后未 reset 的写语句能让整条连接上每一次 COMMIT 都抛错（2026-09-04
/// 真机），await 落库的路径就全部卡死。
void persistInBackground({
  required Future<void> Function() persist,
  required void Function(Object error, StackTrace stack) onPersistError,
}) {
  Future<void> pending;
  try {
    pending = persist();
  } catch (error, stack) {
    onPersistError(error, stack);
    return;
  }
  unawaited(
    pending.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) => onPersistError(error, stack),
    ),
  );
}

/// 「先发起落库、立刻退出」：[persistInBackground] 之后**无条件、同步**执行 [exit]。
///
/// 视频页退出汇聚点此前是 `await flushPosition(); nav.pop();`——把**离开页面**
/// 绑在**一次数据库写入成功**上。写入一旦抛错或永不完成，`pop` 永远到不了：
/// Esc / 返回箭头 / 手柄 B / 系统返回四条通道同时失灵，用户被锁在视频页里。
void exitAfterPersist({
  required Future<void> Function() persist,
  required VoidCallback exit,
  required void Function(Object error, StackTrace stack) onPersistError,
}) {
  persistInBackground(persist: persist, onPersistError: onPersistError);
  exit();
}
