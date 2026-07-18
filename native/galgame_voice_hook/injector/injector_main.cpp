#include <windows.h>

#include <shellapi.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

#include "voice_hook_ipc.h"

// galgame 一键制卡 C 阶段注入器（C.1）。把 hook DLL 注入目标游戏进程，建立共享内存 + 就绪
// 事件，确认注入成功后读回语音格式。Hibiki 主进程把它当子进程拉起（部署红线：注入代码只在
// 这个隔离组件里，不进 hibiki.exe）。
//
// 用法：
//   hibiki_voice_injector.exe --pid <PID> [--dll <hook.dll>] [--wait-ms N] [--hold]
//     --pid     目标进程 ID（必填）
//     --dll     hook DLL 路径（默认取同目录 arch 匹配的 hibiki_voice_hook.dll）
//     --wait-ms 等待「就绪」事件的超时毫秒（默认 5000）
//     --hold    注入并确认后保持运行（host 模式，维持共享内存存活）；缺省=probe 模式，
//               确认后退出（仅用于验证注入管线，退出后映射释放）。
namespace {

using hibiki_voice_hook::kMaxRingBytes;
using hibiki_voice_hook::kRingSeconds;
using hibiki_voice_hook::kSharedMagic;
using hibiki_voice_hook::kSharedVersion;
using hibiki_voice_hook::ReadyEventName;
using hibiki_voice_hook::SharedHeader;
using hibiki_voice_hook::SharedMemoryName;

// 目标与自身位数（WOW64）必须一致才能注入：x86 DLL 只能进 32 位进程，x64 只能进 64 位。
// 返回 true 表示匹配。mismatch 时提示改用对应 arch 的注入器。
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
        // SetEvent 的就绪事件（见 main）。这里只要远程线程跑起来即算注入动作完成。
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

}  // namespace

int main() {
  int argc = 0;
  wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  DWORD pid = 0;
  std::wstring dll_path;
  DWORD wait_ms = 5000;
  bool hold = false;

  if (argv != nullptr) {
    for (int i = 1; i < argc; i++) {
      const std::wstring a = argv[i];
      if (a == L"--pid" && i + 1 < argc) {
        pid = static_cast<DWORD>(_wtoi(argv[++i]));
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
  if (pid == 0) {
    return Fail("usage: hibiki_voice_injector --pid <PID> [--dll <hook.dll>] "
                "[--wait-ms N] [--hold]");
  }
  if (dll_path.empty()) {
    dll_path = DefaultDllPath();
  }
  if (GetFileAttributesW(dll_path.c_str()) == INVALID_FILE_ATTRIBUTES) {
    return Fail("hook DLL not found (pass --dll <path>)");
  }

  HANDLE target = OpenProcess(
      PROCESS_CREATE_THREAD | PROCESS_VM_OPERATION | PROCESS_VM_WRITE |
          PROCESS_VM_READ | PROCESS_QUERY_INFORMATION,
      FALSE, pid);
  if (target == nullptr) {
    fprintf(stderr, "OpenProcess(%lu) failed: %lu (需管理员/相同完整性级别?)\n",
            pid, GetLastError());
    return 1;
  }

  bool target_wow64 = false;
  if (!BitnessMatches(target, &target_wow64)) {
    CloseHandle(target);
    fprintf(stderr,
            "位数不匹配：目标是 %s 进程，请改用对应 arch 的注入器 "
            "(32 位游戏用 x86 injector+DLL，64 位用 x64)。\n",
            target_wow64 ? "32 位" : "64 位");
    return 1;
  }

  // 建共享内存（header + 环形缓冲）并清零、写契约头。injector 持有映射句柄=内存所有者；
  // hold 模式下常驻维持它存活，供 host 消费。
  const uint32_t ring_capacity = ComputeRingCapacity();
  const uint64_t total_size = sizeof(SharedHeader) + ring_capacity;
  const std::wstring shm = SharedMemoryName(pid);
  HANDLE mapping = CreateFileMappingW(
      INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE,
      static_cast<DWORD>(total_size >> 32),
      static_cast<DWORD>(total_size & 0xFFFFFFFF), shm.c_str());
  if (mapping == nullptr) {
    CloseHandle(target);
    return Fail("CreateFileMapping failed");
  }
  auto* header = static_cast<SharedHeader*>(
      MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, 0));
  if (header == nullptr) {
    CloseHandle(mapping);
    CloseHandle(target);
    return Fail("MapViewOfFile failed");
  }
  memset(header, 0, sizeof(SharedHeader));
  header->magic = kSharedMagic;
  header->version = kSharedVersion;
  header->ring_capacity = ring_capacity;

  // 就绪事件（auto-reset，初始未触发）；hook DLL 装好后 SetEvent。
  const std::wstring evt = ReadyEventName(pid);
  HANDLE ready = CreateEventW(nullptr, FALSE, FALSE, evt.c_str());
  if (ready == nullptr) {
    UnmapViewOfFile(header);
    CloseHandle(mapping);
    CloseHandle(target);
    return Fail("CreateEvent failed");
  }

  if (!InjectDll(target, dll_path)) {
    CloseHandle(ready);
    UnmapViewOfFile(header);
    CloseHandle(mapping);
    CloseHandle(target);
    return Fail("injection failed");
  }

  // 等 hook DLL 的 proof-of-life。超时=注入了但 DLL 没跑到通知点（arch/契约/权限问题）。
  const DWORD w = WaitForSingleObject(ready, wait_ms);
  if (w != WAIT_OBJECT_0) {
    fprintf(stderr, "注入完成但未收到就绪信号（%lums 超时）；hooked=%u\n",
            wait_ms, header->hooked);
    CloseHandle(ready);
    UnmapViewOfFile(header);
    CloseHandle(mapping);
    CloseHandle(target);
    return 2;
  }

  printf("OK hooked pid=%lu hooked=%u ring=%u sr=%u ch=%u bits=%u float=%u\n",
         pid, header->hooked, header->ring_capacity, header->sample_rate,
         header->channels, header->bits_per_sample, header->is_float);
  fflush(stdout);

  if (hold) {
    // host 模式：常驻维持共享内存存活，供 Hibiki 消费（C.2 起真正读 PCM）。
    for (;;) {
      Sleep(1000);
    }
  }

  CloseHandle(ready);
  UnmapViewOfFile(header);
  CloseHandle(mapping);
  CloseHandle(target);
  return 0;
}
