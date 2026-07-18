#include <windows.h>

#include <shellapi.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "voice_hook_ipc.h"

// galgame 一键制卡 C 阶段注入器（C.1）。把 hook DLL 注入目标游戏进程，建立共享内存 + 就绪
// 事件，确认注入成功后读回语音格式。Hibiki 主进程把它当子进程拉起（部署红线：注入代码只在
// 这个隔离组件里，不进 hibiki.exe）。
//
// 两种进入方式（二选一）：
//   attach（--pid）：注入已运行进程。适合引擎在游戏运行中才建声音设备的情形。
//   launch（--launch）：CREATE_SUSPENDED 拉起游戏，在其 WinMain 之前注入 hook 再 ResumeThread。
//     适合 KiriKiriZ 这类启动时创建一次 DirectSound 设备的旧引擎——attach 永远晚于设备创建会
//     漏掉，必须在游戏跑起来之前把 DirectSoundCreate 导出 hook 装好（MTool 对同款游戏正是
//     CREATE_SUSPENDED 早注入，证明这条路安全）。
//
// 用法：
//   hibiki_voice_injector.exe --pid <PID> [--dll <hook.dll>] [--wait-ms N] [--hold]
//   hibiki_voice_injector.exe --launch <exe> [--workdir <dir>] [--arg <a>]...
//                             [--dll <hook.dll>] [--wait-ms N] [--hold]
//     --pid     目标进程 ID（attach 模式；与 --launch 二选一）
//     --launch  目标游戏 exe 路径（launch 模式；与 --pid 二选一）
//     --workdir 子进程工作目录（launch 缺省=exe 所在目录）
//     --arg     追加一个传给子进程的命令行参数（可重复；launch 专用）
//     --dll     hook DLL 路径（默认取同目录 arch 匹配的 hibiki_voice_hook.dll）
//     --wait-ms 等待就绪事件的超时毫秒（默认 5000）
//     --hold    注入并确认后保持运行（host 模式，维持共享内存存活）；缺省=probe 模式，
//               确认后退出。launch 模式下 --hold 会一直挂到游戏进程退出。
namespace {

using hibiki_voice_hook::kClipCount;
using hibiki_voice_hook::kMaxRingBytes;
using hibiki_voice_hook::kRingSeconds;
using hibiki_voice_hook::kSharedMagic;
using hibiki_voice_hook::kSharedVersion;
using hibiki_voice_hook::kTextSlotBytes;
using hibiki_voice_hook::kTextSlotCount;
using hibiki_voice_hook::ReadyEventName;
using hibiki_voice_hook::SharedHeader;
using hibiki_voice_hook::SharedMemoryName;
using hibiki_voice_hook::VoiceClip;

// 目标与自身位数（WOW64）必须一致才能注入：x86 DLL 只能进 32 位进程，x64 只能进 64 位。
// 返回 true 表示匹配。CREATE_SUSPENDED 的新进程也能查（此刻映像已就绪，IsWow64Process 有效）。
bool BitnessMatches(HANDLE target, bool* target_is_wow64) {
  BOOL self_wow = FALSE;
  BOOL tgt_wow = FALSE;
  IsWow64Process(GetCurrentProcess(), &self_wow);
  IsWow64Process(target, &tgt_wow);
  *target_is_wow64 = (tgt_wow != FALSE);
  return (self_wow != FALSE) == (tgt_wow != FALSE);
}

// 默认 DLL 路径：同注入器目录下 hibiki_voice_hook.dll。
std::wstring DefaultDllPath() {
  wchar_t exe[MAX_PATH] = {0};
  const DWORD n = GetModuleFileNameW(nullptr, exe, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) {
    return L"hibiki_voice_hook.dll";
  }
  std::wstring path(exe, n);
  const size_t slash = path.find_last_of(L"\\/");
  if (slash != std::wstring::npos) {
    path.resize(slash + 1);
  } else {
    path.clear();
  }
  return path + L"hibiki_voice_hook.dll";
}

// 经 CreateRemoteThread(LoadLibraryW) 把 [dll_path] 注入 [target]。成功返回 true。
// CREATE_SUSPENDED 的进程主线程虽挂起，但此处 CreateRemoteThread 建的新线程照跑（kernel32/
// ntdll 已映射，LoadLibraryW 可用）——标准早注入手法。
bool InjectDll(HANDLE target, const std::wstring& dll_path) {
  const SIZE_T bytes = (dll_path.size() + 1) * sizeof(wchar_t);
  LPVOID remote = VirtualAllocEx(target, nullptr, bytes, MEM_COMMIT | MEM_RESERVE,
                                 PAGE_READWRITE);
  if (remote == nullptr) {
    fprintf(stderr, "VirtualAllocEx failed: %lu\n", GetLastError());
    return false;
  }
  bool ok = false;
  if (WriteProcessMemory(target, remote, dll_path.c_str(), bytes, nullptr)) {
    // LoadLibraryW 在 kernel32 里，同 arch/同会话跨进程地址一致（ASLR 每次开机固定）。
    const auto load =
        reinterpret_cast<LPTHREAD_START_ROUTINE>(reinterpret_cast<void*>(
            GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "LoadLibraryW")));
    if (load != nullptr) {
      HANDLE thread = CreateRemoteThread(target, nullptr, 0, load, remote, 0,
                                         nullptr);
      if (thread != nullptr) {
        WaitForSingleObject(thread, 10000);
        DWORD exit_code = 0;
        GetExitCodeThread(thread, &exit_code);
        CloseHandle(thread);
        // 64 位下 exit_code 截断 HMODULE，不足以判成败——真正的成功信号是 hook DLL
        // SetEvent 的就绪事件（见 RunInjection）。这里只要远程线程跑起来即算注入动作完成。
        ok = true;
      } else {
        fprintf(stderr, "CreateRemoteThread failed: %lu\n", GetLastError());
      }
    } else {
      fprintf(stderr, "resolve LoadLibraryW failed\n");
    }
  } else {
    fprintf(stderr, "WriteProcessMemory failed: %lu\n", GetLastError());
  }
  VirtualFreeEx(target, remote, 0, MEM_RELEASE);
  return ok;
}

uint32_t ComputeRingCapacity() {
  // 默认按 48k 立体声 float32 * 60s 预留；hook 拿到真实格式后按此容量写。上界 kMaxRingBytes。
  uint64_t cap = 48000ull * 2ull * 4ull * kRingSeconds;
  if (cap > kMaxRingBytes) {
    cap = kMaxRingBytes;
  }
  cap -= (cap % 8);
  return static_cast<uint32_t>(cap);
}

int Fail(const char* msg) {
  fprintf(stderr, "%s\n", msg);
  return 1;
}

// attach 与 launch 共用的注入编排。target=目标进程句柄，pid=目标 pid（命名共享内存/事件）。
// resume_thread!=nullptr（launch 模式）时：注入完成后 ResumeThread 让挂起的游戏跑起来，再等就绪
// 事件——保证 hook 在游戏调 DirectSoundCreate/WinMain 之前就装好。hold_process 在 --hold 时决定
// 挂起终点（launch 给游戏进程句柄，挂到游戏退出；attach 给 nullptr，无限 Sleep）。
// 契约与 --pid 老路径完全一致：建共享内存(pid) + 就绪事件(pid)，注入，[Resume]，等事件，
// 打印 OK hooked ...，[hold]。全部句柄本函数负责关闭。返回进程退出码。
int RunInjection(HANDLE target, DWORD pid, const std::wstring& dll_path,
                 DWORD wait_ms, bool hold, HANDLE resume_thread,
                 HANDLE hold_process) {
  bool target_wow64 = false;
  if (!BitnessMatches(target, &target_wow64)) {
    fprintf(stderr,
            "位数不匹配：目标是 %s 进程，请改用对应 arch 的注入器 "
            "(32 位游戏用 x86 injector+DLL，64 位用 x64)。\n",
            target_wow64 ? "32 位" : "64 位");
    return 1;
  }

  // 建共享内存（header + 环形缓冲）并清零、写契约头。injector 持有映射句柄=内存所有者；
  // hold 模式下常驻维持它存活，供 host 消费。
  const uint32_t ring_capacity = ComputeRingCapacity();
  // v2 布局：[SharedHeader][音频环形 ring_capacity][文本环 kTextSlotCount*kTextSlotBytes]
  //          [clip 索引 kClipCount*sizeof(VoiceClip)]。各区偏移下面填进 header。
  const uint64_t text_region_bytes =
      static_cast<uint64_t>(kTextSlotCount) * kTextSlotBytes;
  const uint64_t clip_region_bytes =
      static_cast<uint64_t>(kClipCount) * sizeof(VoiceClip);
  const uint64_t total_size = sizeof(SharedHeader) + ring_capacity +
                              text_region_bytes + clip_region_bytes;
  const std::wstring shm = SharedMemoryName(pid);
  HANDLE mapping = CreateFileMappingW(
      INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE,
      static_cast<DWORD>(total_size >> 32),
      static_cast<DWORD>(total_size & 0xFFFFFFFF), shm.c_str());
  if (mapping == nullptr) {
    return Fail("CreateFileMapping failed");
  }
  auto* header = static_cast<SharedHeader*>(
      MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, 0));
  if (header == nullptr) {
    CloseHandle(mapping);
    return Fail("MapViewOfFile failed");
  }
  // 清零整块映射（页文件后备本就零，显式清零防旧内容并保 v2 各计数/偏移干净起步）。
  memset(header, 0, static_cast<size_t>(total_size));
  header->magic = kSharedMagic;
  header->version = kSharedVersion;
  header->ring_capacity = ring_capacity;
  // 文本环紧随音频环形；clip 索引紧随文本环。hook DLL 据此偏移定位两区。
  header->text_region_offset =
      static_cast<uint32_t>(sizeof(SharedHeader) + ring_capacity);
  header->clip_region_offset =
      static_cast<uint32_t>(header->text_region_offset + text_region_bytes);

  // 就绪事件（auto-reset，初始未触发）；hook DLL 装好后 SetEvent。
  const std::wstring evt = ReadyEventName(pid);
  HANDLE ready = CreateEventW(nullptr, FALSE, FALSE, evt.c_str());
  if (ready == nullptr) {
    UnmapViewOfFile(header);
    CloseHandle(mapping);
    return Fail("CreateEvent failed");
  }

  if (!InjectDll(target, dll_path)) {
    CloseHandle(ready);
    UnmapViewOfFile(header);
    CloseHandle(mapping);
    return Fail("injection failed");
  }

  // launch 模式：hook 已装好，此刻才放游戏跑（它随后调 DirectSoundCreate 命中我们的 hook）。
  if (resume_thread != nullptr) {
    if (ResumeThread(resume_thread) == static_cast<DWORD>(-1)) {
      fprintf(stderr, "ResumeThread failed: %lu\n", GetLastError());
      CloseHandle(ready);
      UnmapViewOfFile(header);
      CloseHandle(mapping);
      return 1;
    }
  }

  // 等 hook DLL 的 proof-of-life。超时=注入了但 DLL 没跑到通知点（arch/契约/权限问题）。
  const DWORD w = WaitForSingleObject(ready, wait_ms);
  if (w != WAIT_OBJECT_0) {
    fprintf(stderr, "注入完成但未收到就绪信号（%lums 超时）；hooked=%u\n",
            wait_ms, header->hooked);
    CloseHandle(ready);
    UnmapViewOfFile(header);
    CloseHandle(mapping);
    return 2;
  }

  printf("OK hooked pid=%lu hooked=%u ring=%u sr=%u ch=%u bits=%u float=%u\n",
         pid, header->hooked, header->ring_capacity, header->sample_rate,
         header->channels, header->bits_per_sample, header->is_float);
  fflush(stdout);

  if (hold) {
    // host 模式：常驻维持共享内存存活，供 Hibiki 消费（C.2 起真正读 PCM）。
    // launch 时挂到游戏进程退出；attach 时无限 Sleep（Ctrl-C 结束）。
    if (hold_process != nullptr) {
      WaitForSingleObject(hold_process, INFINITE);
    } else {
      for (;;) {
        Sleep(1000);
      }
    }
  }

  CloseHandle(ready);
  UnmapViewOfFile(header);
  CloseHandle(mapping);
  return 0;
}

// launch 模式：CREATE_SUSPENDED 拉起游戏，再 RunInjection（建共享内存/注入/Resume/等事件/hold）。
// 命令行含 exe 本身（CreateProcessW 约定）；workdir 缺省=exe 所在目录。
int RunLaunch(const std::wstring& exe, const std::wstring& workdir_in,
              const std::vector<std::wstring>& extra_args,
              const std::wstring& dll_path, DWORD wait_ms, bool hold) {
  if (GetFileAttributesW(exe.c_str()) == INVALID_FILE_ATTRIBUTES) {
    return Fail("目标 exe 不存在（--launch <exe路径>）");
  }

  // workdir 缺省=exe 所在目录。
  std::wstring workdir = workdir_in;
  if (workdir.empty()) {
    const size_t slash = exe.find_last_of(L"\\/");
    if (slash != std::wstring::npos) {
      workdir = exe.substr(0, slash);
    }
  }

  // 构造命令行：exe 加引号防路径含空格；CreateProcessW 要求缓冲可写。
  std::wstring cmdline = L"\"" + exe + L"\"";
  for (const std::wstring& a : extra_args) {
    cmdline += L" ";
    cmdline += a;
  }
  std::vector<wchar_t> cmd_buf(cmdline.begin(), cmdline.end());
  cmd_buf.push_back(L'\0');

  STARTUPINFOW si = {0};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi = {0};
  const BOOL created = CreateProcessW(
      exe.c_str(), cmd_buf.data(), nullptr, nullptr, FALSE, CREATE_SUSPENDED,
      nullptr, workdir.empty() ? nullptr : workdir.c_str(), &si, &pi);
  if (!created) {
    fprintf(stderr, "CreateProcessW failed: %lu\n", GetLastError());
    return 1;
  }

  // 复用 attach 同一套编排；resume_thread=pi.hThread（注入后再放行游戏），
  // hold_process=pi.hProcess（--hold 挂到游戏退出）。
  const int rc = RunInjection(pi.hProcess, pi.dwProcessId, dll_path, wait_ms,
                              hold, pi.hThread, pi.hProcess);

  // 注入前/Resume 前失败（rc==1）时游戏仍处挂起：强制结束，避免留下僵死挂起进程。
  // rc==2（超时但已 Resume）游戏已在跑，不 terminate 交给用户。rc==0 正常退出，游戏自然运行。
  if (rc == 1) {
    TerminateProcess(pi.hProcess, 1);
  }
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  return rc;
}

}  // namespace

int main() {
  int argc = 0;
  wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  DWORD pid = 0;
  std::wstring launch_exe;
  std::wstring workdir;
  std::vector<std::wstring> launch_args;
  std::wstring dll_path;
  DWORD wait_ms = 5000;
  bool hold = false;

  if (argv != nullptr) {
    for (int i = 1; i < argc; i++) {
      const std::wstring a = argv[i];
      if (a == L"--pid" && i + 1 < argc) {
        pid = static_cast<DWORD>(_wtoi(argv[++i]));
      } else if (a == L"--launch" && i + 1 < argc) {
        launch_exe = argv[++i];
      } else if (a == L"--workdir" && i + 1 < argc) {
        workdir = argv[++i];
      } else if (a == L"--arg" && i + 1 < argc) {
        launch_args.emplace_back(argv[++i]);
      } else if (a == L"--dll" && i + 1 < argc) {
        dll_path = argv[++i];
      } else if (a == L"--wait-ms" && i + 1 < argc) {
        wait_ms = static_cast<DWORD>(_wtoi(argv[++i]));
      } else if (a == L"--hold") {
        hold = true;
      }
    }
    LocalFree(argv);
  }

  if ((pid == 0) == launch_exe.empty()) {
    // 两个都没给 或 两个都给了。
    return Fail(
        "usage: hibiki_voice_injector --pid <PID> [--dll <hook.dll>] "
        "[--wait-ms N] [--hold]\n"
        "   or: hibiki_voice_injector --launch <exe> [--workdir <dir>] "
        "[--arg <a>]... [--dll <hook.dll>] [--wait-ms N] [--hold]");
  }

  if (dll_path.empty()) {
    dll_path = DefaultDllPath();
  }
  if (GetFileAttributesW(dll_path.c_str()) == INVALID_FILE_ATTRIBUTES) {
    return Fail("hook DLL not found (pass --dll <path>)");
  }

  // launch 模式：CREATE_SUSPENDED 早注入。
  if (!launch_exe.empty()) {
    return RunLaunch(launch_exe, workdir, launch_args, dll_path, wait_ms, hold);
  }

  // attach 模式：注入已运行进程（老路径行为不变）。
  HANDLE target = OpenProcess(
      PROCESS_CREATE_THREAD | PROCESS_VM_OPERATION | PROCESS_VM_WRITE |
          PROCESS_VM_READ | PROCESS_QUERY_INFORMATION,
      FALSE, pid);
  if (target == nullptr) {
    fprintf(stderr, "OpenProcess(%lu) failed: %lu (需管理员/相同完整性级别?)\n",
            pid, GetLastError());
    return 1;
  }

  const int rc = RunInjection(target, pid, dll_path, wait_ms, hold,
                              nullptr,
                              nullptr);
  CloseHandle(target);
  return rc;
}
