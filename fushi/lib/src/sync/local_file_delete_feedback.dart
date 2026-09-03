/// 把「同时删除本地文件」的失败告诉用户 + 记进错误日志。
///
/// 删除失败在这条路径上是**常态**而不是异常：最常见的一种是「这本/这条正在播放」，
/// Windows 上句柄被占用直接 errno 32。以前这些失败只走 `debugPrint`（release 里被
/// 剥掉）、返回值在三个调用点全被丢弃，用户看到「删除成功」，回头发现盘上一个文件
/// 没少——那是这个功能最坏的失败形态：静默的谎报。
library;

import 'package:fushi_core/fushi_core.dart'
    show LocalFileDeleteFailure, LocalFileDeleteReport;
import 'package:fushi/utils.dart';

/// 逐条记日志，并在有失败时弹一条 warning toast。没有失败就什么都不做（成功是
/// 默认预期，不额外打扰）。[source] 是 ErrorLog 里的来源标签。
void reportLocalFileDeleteFailures(
  LocalFileDeleteReport report, {
  required String source,
}) {
  if (report.failures.isEmpty) return;
  for (final LocalFileDeleteFailure failure in report.failures) {
    ErrorLogService.instance.log(source, failure);
  }
  FushiToast.show(
    msg: t.delete_local_files_failed(n: report.failures.length),
    severity: ToastSeverity.warning,
  );
}
