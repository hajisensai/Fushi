/// 按钮回调里「交给后台跑并记录失败」的小工具，从 `srs_providers.dart` 下沉出来的叶子：只依赖错误日志，
/// 让不该连到 AppModel 的 SRS UI 件（如字段 AI 入口）也能用，不经 Riverpod 装配进大 import 环。
/// `srs_providers.dart` 原样再导出，老调用方不用改。
library;

import 'dart:async';

import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 把一个 Future 交给后台跑并记录失败（按钮回调里用）。
///
/// 用 `then(onError:)` 而不是 `catchError`：[body] 实际返回的可能是 `Future<bool>` 之类（`Future<void>`
/// 收得下任何 Future），`catchError` 的处理函数返回 null 时 Dart 会再抛一个「error handler must return a
/// value of the future's type」的未处理错误。
void srsRunLogged(String where, Future<void> Function() body) {
  unawaited(
    body().then<void>(
      (_) {},
      onError: (Object e, StackTrace stack) {
        ErrorLogService.instance.log(where, e, stack);
      },
    ),
  );
}
