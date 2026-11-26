#ifndef RUNNER_CODE_INTEGRITY_PROBE_H_
#define RUNNER_CODE_INTEGRITY_PROBE_H_

namespace fushi {

// 在独立线程上读一次 CodeIntegrity/Operational 事件日志，把最近 14 天里**还没报告过**、
// 且指向 Fushi 文件的「已拦截」记录，连同智能应用控制的状态写进
// %LOCALAPPDATA%\Fushi\crashdumps\code_integrity.log；下次启动由 Dart 侧
// CodeIntegrityLog.foldIntoErrorLog 折进错误日志（BUG-5484）。
//
// [startup_stall] = 启动期限到点、主窗仍未显示时调用：零命中也写一行状态。
// 同一时刻只跑一个；查询不碰主线程，失败静默（取证不能挡启动）。
void StartCodeIntegrityProbe(bool startup_stall);

}  // namespace fushi

#endif  // RUNNER_CODE_INTEGRITY_PROBE_H_
