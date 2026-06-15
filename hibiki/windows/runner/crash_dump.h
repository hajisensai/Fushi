#ifndef RUNNER_CRASH_DUMP_H_
#define RUNNER_CRASH_DUMP_H_

// BUG-209 / TODO-398：进程级 minidump 安装。
//
// 为什么需要：BUG-209（GraphicsCapture.dll 0xc0000005 延迟 UAF）的崩溃帧无任何
// hibiki teardown 帧，唯一可靠取证手段是 minidump + cdb 反汇编。前十修全靠用户
// 系统 WER 偶然在 %LOCALAPPDATA%\CrashDumps 留下的 dump——但 WER 默认不一定开、
// 也不一定保留，多次复发都因「这次没留 dump」而无法对照。本模块主动安装
// SetUnhandledExceptionFilter，把崩溃 minidump 写进应用自有目录
// （%LOCALAPPDATA%\Hibiki\crashdumps\），让每次崩溃必留 dump，不再赌 WER。
//
// 兼容性：Flutter engine 自身可能已设过 unhandled exception filter（崩溃上报）。
// 安装时保存前一个 filter 并在写完自家 dump 后链回它（返回其结果），不抢占、
// 不破坏引擎既有 crash handler。

namespace hibiki
{
  // 安装进程级 unhandled exception filter（写 minidump 到 %LOCALAPPDATA%\Hibiki\
  // crashdumps\hibiki-<pid>-<时间戳>.dmp，并链回前一个 filter）。应在 CoInitializeEx
  // / Flutter engine 创建之前调用一次。失败（如 dbghelp 不可用）静默降级，不影响启动。
  void InstallCrashDumpHandler();
}

#endif  // RUNNER_CRASH_DUMP_H_
