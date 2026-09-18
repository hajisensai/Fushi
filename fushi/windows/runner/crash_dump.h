#ifndef RUNNER_CRASH_DUMP_H_
#define RUNNER_CRASH_DUMP_H_

// BUG-209 / TODO-398：进程级 minidump 安装。
//
// 为什么需要：BUG-209（GraphicsCapture.dll 0xc0000005 延迟 UAF）的崩溃帧无任何
// hibiki teardown 帧，唯一可靠取证手段是 minidump + cdb 反汇编。前十修全靠用户
// 系统 WER 偶然在 %LOCALAPPDATA%\CrashDumps 留下的 dump——但 WER 默认不一定开、
// 也不一定保留，多次复发都因「这次没留 dump」而无法对照。本模块主动安装
// SetUnhandledExceptionFilter，把崩溃 minidump 写进应用自有目录
// （%LOCALAPPDATA%\Fushi\crashdumps\），让每次崩溃必留 dump，不再赌 WER。
//
// 兼容性：Flutter engine 自身可能已设过 unhandled exception filter（崩溃上报）。
// 安装时保存前一个 filter 并在写完自家 dump 后链回它（返回其结果），不抢占、
// 不破坏引擎既有 crash handler。

#include <windows.h>

namespace fushi
{
  // 安装进程级 unhandled exception filter（写 minidump 到 %LOCALAPPDATA%\Fushi\
  // crashdumps\hibiki-<pid>-<时间戳>.dmp，并链回前一个 filter）。应在 CoInitializeEx
  // / Flutter engine 创建之前调用一次。失败（如 dbghelp 不可用）静默降级，不影响启动。
  void InstallCrashDumpHandler();

  // 把当前进程的 minidump 写到 crashdumps 目录：`<prefix>-<pid>-<tick>.dmp`。
  // [thread_id] 是 dump 里标为「出事线程」的线程；[exception_pointers] 可为 nullptr
  // （主线程停泵看门狗从旁路线程抓 hang dump 时没有异常上下文）。成功返回 true，
  // [out_path]（可为 nullptr）收到写出的完整路径（MAX_PATH）。零堆分配，崩溃 filter
  // 与看门狗线程共用同一条写出路径。
  bool WriteProcessMinidump(const wchar_t* prefix, DWORD thread_id,
    EXCEPTION_POINTERS* exception_pointers, wchar_t* out_path);

  // 启动期预载 dbghelp 并缓存 MiniDumpWriteDump 指针。抓 hang dump 时主线程可能
  // 正卡在 loader lock（WebView2 teardown 等），届时再 LoadLibraryW 会跟着死锁；
  // 崩溃 filter 同样受益。失败静默（写 dump 时退回按需加载）。
  void PreloadMinidumpWriter();

  // 解析并确保 crashdumps 目录存在（`%LOCALAPPDATA%\Fushi\crashdumps`；集成测试
  // 设了 FUSHI_TEST_ROOT 时为 `<root>\logs\native\crashdumps`）。[dir] 至少 MAX_PATH。
  bool ResolveCrashDumpDirectory(wchar_t* dir);
}

#endif  // RUNNER_CRASH_DUMP_H_
