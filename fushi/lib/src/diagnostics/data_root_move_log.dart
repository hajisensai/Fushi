// 最近一次书库迁移的取证记录（BUG-5467）。
//
// 诊断日志只在内存里、随反馈 / 闪退报告上传，而迁移成功后进程马上重启：迁移进程里记的
// 那条摘要还没被任何报告带走就丢了。所以摘要连同时间写进设备本地的 SharedPreferences
// （不随备份 / 同步出境），之后每次启动都重新记一条，直到下一次迁移覆盖它。用户隔几天才报
// 「书库空了」时，报告里照样看得到上次是什么时候、怎么搬的、搬了多少。

import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences 键：最近一次书库迁移的摘要，首行是迁移完成的本地时间（ISO 8601）。
const String kDataRootLastMovePrefKey = 'data_root_last_move_summary';

/// 日志 source 标签（不是 i18n key）。
const String kDataRootLastMoveSource = 'DataRootMigration.last';

/// 迁移成功提交后调用：记进本进程的诊断日志，并落盘供重启后的进程再记。
Future<void> recordDataRootMove(String summary, {DateTime? finishedAt}) async {
  final String stamped =
      '${(finishedAt ?? DateTime.now()).toIso8601String()}\n$summary';
  ErrorLogService.instance.logDiagnostic(kDataRootLastMoveSource, stamped);
  try {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    await sp.setString(kDataRootLastMovePrefKey, stamped);
  } on Object catch (e, st) {
    // 迁移本身已提交成功，取证记录写不进去不能把它判成失败；记成错误随报告上传。
    ErrorLogService.instance.log(kDataRootLastMoveSource, e, st);
  }
}

/// 启动时调一次：有迁移记录就记一条诊断日志。
Future<void> logLastDataRootMove() async {
  try {
    final SharedPreferences sp = await SharedPreferences.getInstance();
    final String? stamped = sp.getString(kDataRootLastMovePrefKey);
    if (stamped == null) return;
    ErrorLogService.instance.logDiagnostic(kDataRootLastMoveSource, stamped);
  } on Object catch (e, st) {
    ErrorLogService.instance.log(kDataRootLastMoveSource, e, st);
  }
}
