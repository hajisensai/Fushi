#ifndef RUNNER_STARTUP_TRACE_H_
#define RUNNER_STARTUP_TRACE_H_

#include <flutter/binary_messenger.h>

namespace fushi {

// 冷启动原生阶段计时：进程创建 → Dart main() 之前 runner 各段花了多久。
// Dart 侧（lib/src/startup/startup_timeline.dart）在主窗显示后经
// `app.fushi.reader/startup_trace` 取回，和 Dart 段拼成一行写进诊断日志。
//
// 记「[phase] 这一段刚结束」。只在平台线程调用。
void StartupTraceMark(const char* phase);

// 注册 `app.fushi.reader/startup_trace`：`get` 返回
// {processStartMicros: int64, marks: [[name, epochMicros], ...]}。
void RegisterStartupTraceChannel(flutter::BinaryMessenger* messenger);

}  // namespace fushi

#endif  // RUNNER_STARTUP_TRACE_H_
