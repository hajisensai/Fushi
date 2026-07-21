#include <windows.h>

#include <shellapi.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <cwchar>
#include <vector>

#include "voice_hook_ipc.h"
#include "voice_hook_session.h"
#include "siglus_launch.h"
#include "steam_launch.h"
#include "luna_hook_config.h"

// galgame 一键制卡 C 阶段注入器（C.1）。把 hook DLL 注入目标游戏进程，建立共享内存 + 就绪
// 事件，确认注入成功后读回语音格式。Hibiki 主进程把它当子进程拉起（部署红线：注入代码只在
// 这个隔离组件里，不进 hibiki.exe）。
//
// 两种进入方式（二选一）：
//   attach（--pid）：注入已运行进程。适合引擎在游戏运行中才建声音设备的情形。
//   launch（--launch）：通常 CREATE_SUSPENDED 拉起游戏，在其 WinMain 之前注入 hook 再
//     ResumeThread。SiglusEngine.exe 的 Enigma 保护壳会拒绝这种早注入，因此该 exe 自动改为
//     正常启动，等保护壳退出且游戏主窗口出现后再附着；Siglus 的干净语音来自后续 OVK 文件读，
//     不要求抢在音频设备创建之前。
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
using hibiki_voice_hook::kDiagLunaConnected;
using hibiki_voice_hook::kDiagLunaHostReady;
using hibiki_voice_hook::kDiagLunaInjectFailed;
using hibiki_voice_hook::kDiagLunaOutputObserved;
using hibiki_voice_hook::kDiagStartupAudioHooksReady;
using hibiki_voice_hook::kDiagUnityResourceExtracted;
using hibiki_voice_hook::kDiagUnityResourceExtractFailed;
using hibiki_voice_hook::kDiagUnityResourceExtractorReady;
using hibiki_voice_hook::kLoopbackMarkerCount;
using hibiki_voice_hook::kLoopbackSeconds;
using hibiki_voice_hook::kMaxLoopbackBytes;
using hibiki_voice_hook::kMaxRingBytes;
using hibiki_voice_hook::kRingSeconds;
using hibiki_voice_hook::kSharedMagic;
using hibiki_voice_hook::kSharedVersion;
using hibiki_voice_hook::kTextSlotBytes;
using hibiki_voice_hook::kTextSlotCount;
using hibiki_voice_hook::kUnityVoiceEventCount;
using hibiki_voice_hook::LoopbackMarker;
using hibiki_voice_hook::ReadyEventName;
using hibiki_voice_hook::SharedHeader;
using hibiki_voice_hook::SharedMemoryName;
using hibiki_voice_hook::TextSlot;
using hibiki_voice_hook::VoiceClip;
using hibiki_voice_hook::UnityVoiceEvent;
using hibiki_voice_hook::InspectMappingSession;
using hibiki_voice_hook::AdvanceUnityEventCursorIfCommitted;
using hibiki_voice_hook::MappingSessionAction;

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

// loopback 环固定容量（注入前分配，尚不知真实混音格式）：按名义 48k 立体声 16-bit 存储 * 60s。
// 混音若多声道则同容量下历史时长变短，仍够抽窗；上界 kMaxLoopbackBytes 护住 32 位地址空间。
uint32_t ComputeLoopbackCapacity() {
  uint64_t cap = 48000ull * 2ull * 2ull * kLoopbackSeconds;  // sr*ch*16bit*秒
  if (cap > kMaxLoopbackBytes) {
    cap = kMaxLoopbackBytes;
  }
  cap -= (cap % 8);
  return static_cast<uint32_t>(cap);
}

int Fail(const char* msg) {
  fprintf(stderr, "%s\n", msg);
  return 1;
}

// LunaHook 集成（host 侧全引擎文本 hook）。
//
// 游戏内的 hibiki_voice_hook.dll 只覆盖 GDI 文本（TextOut/GetGlyphOutline 等），抓不到
// KiriKiriZ/RenPy/Unity 这类把文本走自绘/脚本 VM 的引擎。LunaHook（Textractor 的后继、
// GPLv3）是成熟的引擎级文本 hook 引擎，内置各引擎的精确台词 hook。这里在 **host 侧（injector
// 进程内）** 用 vendored 的 LunaHost<arch>.dll 驱动 LunaHook：LunaHost.dll 加载进本进程，
// 注入 LunaHook<arch>.dll 进游戏，游戏侧抓到的台词经进程内回调回传给我们，写进**同一块文本
// 环**（injector 本就 map 着共享内存）。与游戏内 GDI hook 双写同一环，靠 InterlockedIncrement64
// 原子占号防撞槽。
//
// ABI 定死来源（务必与 vendored 二进制版本一致）：LunaTranslator v10.16.1.2 发布包自带的
// LunaTranslator/textio/textsource/texthook.py，以及同 tag 的 LunaHostDll.cpp。Luna_Start 收
// 10 个 __cdecl 回调指针；attach 先建 host 管道（Luna_ConnectProcess），再由
// Luna_CheckIfNeedInject 判断是否需要注入；Luna_DetachProcess 收尾。换 DLL 版本时必须重新核对
// 发布包内 texthook.py、上游导出实现和本文件，不能只覆盖二进制。

// LunaHook ThreadParam：按 texthook.py 的 ctypes 结构 1:1 定死（processId=c_uint 后跟三个
// c_uint64，8 对齐 → 4+4pad+8+8+8 = 32 字节）。回调里**按值**传入，布局必须精确匹配。
#pragma pack(push, 8)
struct LunaThreadParam {
  uint32_t processId;
  uint64_t addr;
  uint64_t ctx;
  uint64_t ctx2;
};
#pragma pack(pop)
static_assert(sizeof(LunaThreadParam) == 32,
              "LunaThreadParam 必须 32 字节，匹配 LunaHost ABI");

// Luna_Start 的 10 个回调槽（默认 __cdecl，匹配 LunaHost 内部自由函数指针约定 / texthook.py 的
// CFUNCTYPE）。只真正用第 5 个 Output；1-4、6-8 是最小 stub，9-10（i18n/emulator info）传空。
// 参数逐个对齐 texthook.py：
//   ProcessEvent            = void(DWORD)
//   ThreadEvent_maybe_embed = void(const wchar_t* hookcode, const char* hookname, TP, bool)
//   ThreadEvent             = void(const wchar_t* hookcode, const char* hookname, TP)
//   OutputCallback          = void(const wchar_t* hookcode, const char* hookname, TP, const wchar_t* text)
//   HostInfoHandler         = void(int type, const wchar_t* log)
//   HookInsertHandler       = void(DWORD pid, uint64_t addr, const wchar_t* hookcode)
//   EmbedCallback           = void(const wchar_t* text, TP)
using LunaProcessEvent = void (*)(DWORD);
using LunaThreadEventMaybeEmbed = void (*)(const wchar_t*, const char*,
                                            LunaThreadParam, bool);
using LunaThreadEvent = void (*)(const wchar_t*, const char*, LunaThreadParam);
using LunaOutputCallback = void (*)(const wchar_t*, const char*,
                                    LunaThreadParam, const wchar_t*);
using LunaHostInfoHandler = void (*)(int, const wchar_t*);
using LunaHookInsertHandler = void (*)(DWORD, uint64_t, const wchar_t*);
using LunaEmbedCallback = void (*)(const wchar_t*, LunaThreadParam);
using LunaI18nQueryCallback = wchar_t* (*)(const wchar_t*);
using LunaEmuGameInfoCallback = void (*)(const wchar_t*, const wchar_t*,
                                         const wchar_t*);
using PFN_Luna_Start = void (*)(
    LunaProcessEvent, LunaProcessEvent, LunaThreadEventMaybeEmbed,
    LunaThreadEvent, LunaOutputCallback, LunaHostInfoHandler,
    LunaHookInsertHandler, LunaEmbedCallback, LunaI18nQueryCallback,
    LunaEmuGameInfoCallback);
using PFN_Luna_ConnectProcess = void (*)(DWORD);
using PFN_Luna_CheckIfNeedInject = bool (*)(DWORD);
using PFN_Luna_DetachProcess = void (*)(DWORD);
// Luna_Settings(flushDelay, filterRepetition, defaultCodepage, maxBufferSize,
//               maxHistorySize, enablePCHooks)。PC hooks 仍由连接回调按目标决定，末参传 false。
using PFN_Luna_Settings = void (*)(int, bool, int, int, int, bool);
using PFN_Luna_InsertPCHooks = void (*)(DWORD, int);
using PFN_Luna_InsertHookCode = bool (*)(DWORD, const wchar_t*);

// host 侧 LunaHook 运行时上下文（单目标进程，injector 一对一）。
struct LunaCtx {
  HMODULE host_dll = nullptr;      // 加载进 injector 的 LunaHost<arch>.dll
  SharedHeader* header = nullptr;  // injector map 的共享内存头（写文本环用）
  DWORD pid = 0;                   // 目标游戏 pid（Detach 用）
  PFN_Luna_DetachProcess detach = nullptr;
  PFN_Luna_InsertPCHooks insert_pc = nullptr;
  PFN_Luna_InsertHookCode insert_hook = nullptr;
  bool use_pc_hooks = false;       // 连接后是否补装通用 PC hooks（默认否，避免与 GDI 重复）
  std::vector<std::wstring> hook_codes;
};
LunaCtx g_luna;

// injector 自身所在目录（末尾带反斜杠）。DLL 部署在 injector 同目录（CMake post-build 拷入）。
std::wstring InjectorDir() {
  wchar_t exe[MAX_PATH] = {0};
  const DWORD n = GetModuleFileNameW(nullptr, exe, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) {
    return L"";
  }
  std::wstring path(exe, n);
  const size_t slash = path.find_last_of(L"\\/");
  if (slash != std::wstring::npos) {
    path.resize(slash + 1);
  } else {
    path.clear();
  }
  return path;
}

struct UnityExtractorRuntime {
  std::wstring executable;
  std::wstring classdata;
  std::wstring decoder;
  bool ready = false;
};

bool RegularFileExists(const std::wstring& path) {
  const DWORD attr = GetFileAttributesW(path.c_str());
  return attr != INVALID_FILE_ATTRIBUTES &&
         (attr & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

UnityExtractorRuntime FindUnityExtractorRuntime() {
  const std::wstring base = InjectorDir() + L"unity_audio_runtime\\";
  UnityExtractorRuntime runtime;
  runtime.executable = base + L"hibiki_unity_audio_extract.exe";
  runtime.classdata = base + L"classdata.tpk";
  runtime.decoder = base + L"vgmstream-cli.exe";
  runtime.ready = RegularFileExists(runtime.executable) &&
                  RegularFileExists(runtime.classdata) &&
                  RegularFileExists(runtime.decoder);
  return runtime;
}

std::wstring QuoteWindowsArgument(const std::wstring& value) {
  std::wstring quoted = L"\"";
  size_t slashes = 0;
  for (wchar_t c : value) {
    if (c == L'\\') {
      ++slashes;
      continue;
    }
    if (c == L'\"') {
      quoted.append(slashes * 2 + 1, L'\\');
      quoted.push_back(c);
      slashes = 0;
      continue;
    }
    quoted.append(slashes, L'\\');
    slashes = 0;
    quoted.push_back(c);
  }
  quoted.append(slashes * 2, L'\\');
  quoted.push_back(L'\"');
  return quoted;
}

std::wstring SafeVoiceFileName(const wchar_t* clip_name) {
  std::wstring result = clip_name == nullptr ? L"unity_voice" : clip_name;
  for (wchar_t& c : result) {
    if (c < 0x20 || c == L'\\' || c == L'/' || c == L':' || c == L'*' ||
        c == L'?' || c == L'\"' || c == L'<' || c == L'>' || c == L'|') {
      c = L'_';
    }
  }
  if (result.empty()) result = L"unity_voice";
  return result;
}

bool ExtractUnityVoice(const UnityExtractorRuntime& runtime,
                       const UnityVoiceEvent& event) {
  if (!runtime.ready || event.bundle_path[0] == 0 ||
      event.clip_name[0] == 0) {
    return false;
  }
  wchar_t temp[MAX_PATH] = {0};
  const DWORD temp_len = GetTempPathW(MAX_PATH, temp);
  if (temp_len == 0 || temp_len >= MAX_PATH) return false;
  const std::wstring dir = std::wstring(temp) + L"hibiki_gal_voice";
  CreateDirectoryW(dir.c_str(), nullptr);
  const std::wstring output =
      dir + L"\\" + std::to_wstring(event.timestamp_ms) + L"_" +
      SafeVoiceFileName(event.clip_name) + L".wav";

  std::wstring command = QuoteWindowsArgument(runtime.executable) +
      L" --bundle " + QuoteWindowsArgument(event.bundle_path) +
      L" --clip " + QuoteWindowsArgument(event.clip_name) +
      L" --output " + QuoteWindowsArgument(output) +
      L" --classdata " + QuoteWindowsArgument(runtime.classdata) +
      L" --decoder " + QuoteWindowsArgument(runtime.decoder);
  std::vector<wchar_t> command_buffer(command.begin(), command.end());
  command_buffer.push_back(0);
  STARTUPINFOW startup = {0};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process = {0};
  if (!CreateProcessW(runtime.executable.c_str(), command_buffer.data(),
                      nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr,
                      InjectorDir().c_str(), &startup, &process)) {
    fprintf(stderr, "[unity-audio] extractor launch failed=%lu clip=%ls\n",
            GetLastError(), event.clip_name);
    return false;
  }
  CloseHandle(process.hThread);
  const DWORD wait = WaitForSingleObject(process.hProcess, 30000);
  DWORD exit_code = 2;
  if (wait == WAIT_OBJECT_0) GetExitCodeProcess(process.hProcess, &exit_code);
  CloseHandle(process.hProcess);
  const bool ok = wait == WAIT_OBJECT_0 && exit_code == 0 &&
                  RegularFileExists(output);
  fprintf(stderr, "[unity-audio] %s clip=%ls bundle=%ls output=%ls\n",
          ok ? "extracted" : "failed", event.clip_name,
          event.bundle_path, output.c_str());
  return ok;
}

void ProcessUnityVoiceEvents(SharedHeader* header,
                             const UnityExtractorRuntime& runtime,
                             uint64_t* next_event) {
  if (header == nullptr || next_event == nullptr || !runtime.ready) return;
  const uint64_t count = header->unity_voice_write_count;
  if (*next_event + kUnityVoiceEventCount < count) {
    *next_event = count - kUnityVoiceEventCount;
  }
  while (*next_event < count) {
    const uint64_t expected_seq = *next_event + 1;
    const UnityVoiceEvent* source =
        &header->unity_voice_events[*next_event % kUnityVoiceEventCount];
    // write_count 在生产者填槽前预留；seq 尚未提交时不能跳过，留给下轮 50ms 重试。
    if (source->seq != expected_seq) break;
    MemoryBarrier();
    UnityVoiceEvent event = {};
    event.seq = source->seq;
    event.timestamp_ms = source->timestamp_ms;
    wcsncpy_s(event.clip_name, source->clip_name, _TRUNCATE);
    wcsncpy_s(event.bundle_path, source->bundle_path, _TRUNCATE);
    if (source->seq != expected_seq) break;
    if (ExtractUnityVoice(runtime, event)) {
      header->hook_diagnostics |= kDiagUnityResourceExtracted;
    } else {
      header->hook_diagnostics |= kDiagUnityResourceExtractFailed;
    }
    const bool advanced = AdvanceUnityEventCursorIfCommitted(
        expected_seq, event.seq, next_event);
    if (!advanced) break;
  }
}

// injector 与目标同位数（BitnessMatches 已强制），故 LunaHost/LunaHook 位数 = 本编译位数。
#ifdef _WIN64
constexpr const wchar_t* kLunaArch = L"64";
#else
constexpr const wchar_t* kLunaArch = L"32";
#endif

// 文本粗过滤：跳空串 / 纯空白 / 纯 ASCII 控制；保留含 >=1 个非 ASCII（>=0x3000，假名/汉字）
// 或非空白字符数 >=2 的串。与游戏内 DLL 的 FlushLine 过滤同口径，避免把 UI 数字/单字母当台词。
bool LunaPassesFilter(const wchar_t* text, int len) {
  if (text == nullptr || len <= 0) {
    return false;
  }
  int non_ws = 0;
  bool has_wide = false;
  for (int i = 0; i < len; i++) {
    const wchar_t c = text[i];
    if (c == L' ' || c == L'\t' || c == L'\r' || c == L'\n' || c == 0x3000) {
      continue;  // 空白（含全角空格）
    }
    non_ws++;
    if (static_cast<unsigned>(c) >= 0x3000) {
      has_wide = true;
    }
  }
  return has_wide || non_ws >= 2;
}

// 把台词或线程发现事件写进共享内存文本环（host 侧 LunaHook 写者）。与游戏内 DLL 的
// WriteTextRingLocked **完全同一套协议**：InterlockedIncrement64 原子占唯一槽号 → 填文本 + 字段
// → 最后写 seq 作完成标记。跨进程双写同环靠原子占号防撞槽、防丢更新。LunaHook 的回调可能在
// 其内部工作线程并发触发，原子占号同样保证 injector 侧多次调用互不撞槽。
uint64_t Fnv1a64(uint64_t hash, const void* data, size_t size) {
  const auto* bytes = static_cast<const uint8_t*>(data);
  for (size_t i = 0; i < size; i++) {
    hash ^= bytes[i];
    hash *= 1099511628211ull;
  }
  return hash;
}

uint64_t LunaTextThreadId(const wchar_t* hookcode, const char* hookname,
                          const LunaThreadParam& tp) {
  uint64_t hash = 1469598103934665603ull;
  hash = Fnv1a64(hash, &tp.processId, sizeof(tp.processId));
  hash = Fnv1a64(hash, &tp.addr, sizeof(tp.addr));
  hash = Fnv1a64(hash, &tp.ctx, sizeof(tp.ctx));
  hash = Fnv1a64(hash, &tp.ctx2, sizeof(tp.ctx2));
  if (hookcode != nullptr) {
    hash = Fnv1a64(hash, hookcode, wcslen(hookcode) * sizeof(wchar_t));
  }
  if (hookname != nullptr) {
    hash = Fnv1a64(hash, hookname, strlen(hookname));
  }
  return hash == 0 ? 1 : hash;
}

void WriteLunaTextEvent(SharedHeader* header, const wchar_t* hookcode,
                        const char* hookname, const LunaThreadParam& tp,
                        uint64_t thread_id, uint32_t event_kind,
                        uint32_t event_flags, const wchar_t* text, int wlen) {
  if (header == nullptr ||
      (event_kind == hibiki_voice_hook::kTextEventLine &&
       (text == nullptr || wlen <= 0))) {
    return;
  }
  uint8_t* text_base =
      reinterpret_cast<uint8_t*>(header) + header->text_region_offset;
  const LONGLONG reserved = InterlockedIncrement64(
      reinterpret_cast<volatile LONGLONG*>(&header->text_write_count));
  const uint64_t idx = static_cast<uint64_t>(reserved) - 1;
  uint8_t* slot =
      text_base + static_cast<size_t>(idx % kTextSlotCount) * kTextSlotBytes;
  auto* ts = reinterpret_cast<TextSlot*>(slot);
  memset(ts, 0, sizeof(TextSlot));
  uint32_t max_bytes = kTextSlotBytes - static_cast<uint32_t>(sizeof(TextSlot));
  max_bytes -= (max_bytes % static_cast<uint32_t>(sizeof(wchar_t)));  // wchar 边界
  uint32_t byte_len = text == nullptr || wlen <= 0
                          ? 0
                          : static_cast<uint32_t>(wlen) *
                                static_cast<uint32_t>(sizeof(wchar_t));
  if (byte_len > max_bytes) {
    byte_len = max_bytes;  // 截断到槽容量
  }
  if (byte_len != 0) {
    memcpy(slot + sizeof(TextSlot), text, byte_len);
  }
  ts->timestamp_ms = GetTickCount64();
  ts->byte_len = byte_len;
  ts->is_utf8 = 0;  // UTF-16LE
  ts->thread_id = thread_id;
  ts->thread_address = tp.addr;
  ts->thread_context = tp.ctx;
  ts->thread_context2 = tp.ctx2;
  ts->process_id = tp.processId;
  ts->source_kind = hibiki_voice_hook::kTextSourceLuna;
  ts->event_kind = event_kind;
  ts->event_flags = event_flags;
  if (hookname != nullptr) {
    const size_t n = (std::min)(strlen(hookname),
                                static_cast<size_t>(
                                    hibiki_voice_hook::kTextHookNameChars - 1));
    memcpy(ts->hook_name, hookname, n);
    ts->hook_name[n] = '\0';
    ts->hook_name_len = static_cast<uint32_t>(n);
  }
  if (hookcode != nullptr) {
    const size_t n = (std::min)(wcslen(hookcode),
                                static_cast<size_t>(
                                    hibiki_voice_hook::kTextHookCodeChars - 1));
    memcpy(ts->hook_code, hookcode, n * sizeof(wchar_t));
    ts->hook_code[n] = L'\0';
    ts->hook_code_len = static_cast<uint32_t>(n);
  }
  ts->seq = static_cast<uint64_t>(reserved);  // 完成标记，最后写
  if (header->text_hooked == 0) {
    header->text_hooked = 1;  // 首次 flush：文本 hook proof-of-life
  }
}

void WriteLunaTextLine(SharedHeader* header, const wchar_t* hookcode,
                       const char* hookname, const LunaThreadParam& tp,
                       uint64_t thread_id, const wchar_t* text, int wlen) {
  WriteLunaTextEvent(header, hookcode, hookname, tp, thread_id,
                     hibiki_voice_hook::kTextEventLine, 0, text, wlen);
}

// ── 多 hook 自动选干净线程（LunaHook 伪影过滤）────
// LunaHook 对同一个游戏常同时装多条 hook，同一句对白会被多条各回传一次：只有一条
// 干净，其余是坏 hook 产生的伪影（整串重复 / 每字重复 N 次）。这里按 hookcode 分组统计
// clean/dirty，自动锁定表现最干净的那条 hook；用户在 Hibiki 选择线程后则以共享 header 的
// selected_text_thread_id 覆盖自动赢家。重复伪影始终不写，手动选择也不能绕过过滤。

// 伪影判别（纯函数）：给定 [text,len]，判断是否为坏 hook 的重复伪影。
//   ① 整串重复：len 为偶数且前半 == 后半（例：AB…|AB…）。
//   ② 等长游程：对字符串做游程编码（连续相同字符归为一段），若段数 >=3 且所有段
//     长度相等且 >=2 → 伪影（捕获每字×2/×3/×10 等）。
// 其余为“干净”。
bool LunaTextIsArtifact(const wchar_t* text, int len) {
  if (text == nullptr || len <= 1) {
    return false;
  }
  // ① 整串重复：偶数长且前半 == 后半。
  if ((len % 2) == 0) {
    const int half = len / 2;
    if (wmemcmp(text, text + half, static_cast<size_t>(half)) == 0) {
      return true;
    }
  }
  // ② 等长游程：连续相同字符归一段，段数 >=3 且所有段等长且 >=2。
  int seg_count = 0;
  int first_run = 0;
  bool uniform = true;
  int i = 0;
  while (i < len) {
    int j = i + 1;
    while (j < len && text[j] == text[i]) {
      j++;
    }
    const int run = j - i;
    if (seg_count == 0) {
      first_run = run;
    } else if (run != first_run) {
      uniform = false;
    }
    seg_count++;
    i = j;
  }
  if (seg_count >= 3 && uniform && first_run >= 2) {
    return true;
  }
  // ③ 相邻同字比例：非等长的混合重画伪影（如 そそれれど…ころかか，部分字重复）游程不等长，
  //   ② 抓不到。但每字重画的相邻相同字符占比很高（~0.5），干净日文 ≈0（偶有っ/ー/々）。>=30% 判伪影。
  int adj_eq = 0;
  for (int k = 1; k < len; k++) {
    if (text[k] == text[k - 1]) {
      adj_eq++;
    }
  }
  return len > 4 && adj_eq * 100 >= (len - 1) * 30;
}

// 每条 hook 的干净/伪影计数。
struct LunaHookStats {
  uint64_t clean_count = 0;
  uint64_t dirty_count = 0;
  uint64_t last_tick = 0;
};

// hookcode -> 计数。Output 回调可能在 LunaHook 内部工作线程并发触发，用 CRITICAL_SECTION
// 串行化计数更新与赢家评估。g_lunaSelectedHook 空=冷启动未选出赢家。
std::map<std::wstring, LunaHookStats> g_lunaHookStats;
std::wstring g_lunaSelectedHook;
bool g_lunaSelectPrimed = false;
CRITICAL_SECTION g_lunaSelectCs;
bool g_lunaSelectCsInit = false;

// 冷启动阈值：总干净行 < 阈值前不锁定赢家，只要该行本身干净就照写（保证首句立刻可见）。
constexpr uint64_t kLunaSelectMinClean = 3;

// 多 hook 自动选干净线程：更新某 hookcode 的计数并重算当前赢家，返回本行是否应写入文本环。
// hookcode 可能为 nullptr（归到空串 key）。冷启动（总 clean < 阈值）时干净行照写；一旦某
// hook 累计干净行达阈值即锁定为赢家，之后只写赢家的行；赢家按 clean_count 最高 + 占比
// clean/(clean+dirty) >= 0.5 重选，可随游戏切换重新评估。
bool LunaShouldWriteLine(const wchar_t* hookcode, uint64_t thread_id,
                         bool is_artifact) {
  const uint64_t manually_selected = g_luna.header == nullptr
                                         ? 0
                                         : static_cast<uint64_t>(
                                               InterlockedCompareExchange64(
                                                   reinterpret_cast<
                                                       volatile LONGLONG*>(
                                                       &g_luna.header
                                                            ->selected_text_thread_id),
                                                   0, 0));
  if (!g_lunaSelectCsInit) {
    return !is_artifact &&
           (manually_selected == 0 || manually_selected == thread_id);
  }
  const std::wstring key =
      (hookcode != nullptr) ? std::wstring(hookcode) : std::wstring();
  bool should_write = false;
  EnterCriticalSection(&g_lunaSelectCs);
  LunaHookStats& st = g_lunaHookStats[key];
  if (is_artifact) {
    st.dirty_count++;
  } else {
    st.clean_count++;
  }
  st.last_tick = GetTickCount64();

  // 重算赢家。**优先「纯净」hook（dirty==0，从未产伪影）**，无纯净 hook 才回落
  // 「clean>=dirty 且 clean_count 最高」的旧规则。
  //
  // 根因（真机实证 lunadiag + 模拟）：per-char/整串重复的坏 hook（KiriKiri 的 KiriKiriZ）在读档
  // 菜单阶段先吐一堆**干净**的存档预览/槽号/时间戳、凭早期高 clean_count 霸占赢家；进对话后它只
  // 吐每字重复**伪影**（被伪影闸丢弃），而真正干净的对话 hook（textrender）虽已出干净行却因不是
  // 赢家被拒 → 正文一句不写、只剩菜单文字（用户症状「没正文文字，只有读存档文字」）。旧规则靠
  // 累计 clean_count 选赢家，坏 hook 的早期干净菜单数长期压过对话 hook。
  // 纯净优先：坏 hook 一进对话吐出第一条伪影 dirty>0 即失去纯净资格，对话 hook（始终 dirty==0）
  // 立即接管，正文流出。单 hook 偶发误判伪影的游戏无纯净 hook、回落旧规则，行为不变。
  const std::wstring* best = nullptr;
  uint64_t best_clean = 0;
  const std::wstring* best_pristine = nullptr;
  uint64_t best_pristine_clean = 0;
  uint64_t total_clean = 0;
  for (const auto& kv : g_lunaHookStats) {
    total_clean += kv.second.clean_count;
    const uint64_t c = kv.second.clean_count;
    const uint64_t d = kv.second.dirty_count;
    if (c == 0) {
      continue;
    }
    if (d == 0 && c > best_pristine_clean) {
      best_pristine_clean = c;  // 纯净候选（从未产伪影）
      best_pristine = &kv.first;
    }
    if (c >= d && c > best_clean) {
      best_clean = c;  // 回落候选（占比 c/(c+d)>=0.5 <=> c>=d）
      best = &kv.first;
    }
  }
  const std::wstring* winner =
      (best_pristine != nullptr) ? best_pristine : best;

  if (total_clean >= kLunaSelectMinClean && winner != nullptr) {
    g_lunaSelectPrimed = true;
    g_lunaSelectedHook = *winner;
  }

  // 伪影永不写——无论来自哪个 hook。赢家 hook 自己也会夹带 ×2/×3 伪影行（同一 hookcode 既出
  // 干净又出重复），旧逻辑「锁定态只按 key 放行」会把赢家的伪影也写进去。线程选择只作次级去重
  // （多条干净 hook 里锁定一条，避免重复），伪影过滤是无条件的第一道闸。
  if (is_artifact) {
    should_write = false;
  } else if (manually_selected != 0) {
    // Hibiki UI 手动选择优先于自动赢家；切回 0 即恢复自动选择。
    should_write = manually_selected == thread_id;
  } else if (!g_lunaSelectPrimed) {
    // 冷启动：未锁定赢家，干净行照写（保证首句立刻可见）。
    should_write = true;
  } else {
    // 锁定态：只写赢家 hook 的干净行。
    should_write = (key == g_lunaSelectedHook);
  }
  LeaveCriticalSection(&g_lunaSelectCs);
  return should_write;
}

// ── Luna_Start 的回调实现（__cdecl 默认约定）─────────────────────────────────
// Output：全引擎精确台词入口。过滤 + 写文本环。v10.16.1.2 ABI 返回 void。
// LunaHook 逐行诊断（env `HIBIKI_LUNA_DIAG=1` 打开）：把**每一行**（含随后被 filter/伪影/线程
// 选择丢弃的）连同其 hook 上下文（hookname / hookcode 签名 / addr / ctx / ctx2）打到 stderr。用于
// 实证「系统菜单标题（读/存档确认）是否与对话走不同 hook」——若不同则可在 hook 层白名单精确排除，
// 若同 hook 则只能回落文本层启发式。默认关（零开销）；不改任何写入路径，纯观测。
bool LunaDiagEnabled() {
  static const bool enabled = []() {
    char buf[8] = {0};
    const DWORD n = GetEnvironmentVariableA("HIBIKI_LUNA_DIAG", buf, sizeof(buf));
    return n > 0 && buf[0] != '0';
  }();
  return enabled;
}

// 把 UTF-16 文本转 UTF-8 写进定长栈缓冲（截断到 [out_cap-1]），供诊断打印。返回写入字节数。
int LunaWideToUtf8(const wchar_t* text, int wlen, char* out, int out_cap) {
  if (text == nullptr || wlen <= 0 || out_cap <= 1) {
    if (out_cap > 0) out[0] = '\0';
    return 0;
  }
  const int n = WideCharToMultiByte(CP_UTF8, 0, text, wlen, out, out_cap - 1,
                                    nullptr, nullptr);
  const int written = (n > 0) ? n : 0;
  out[written] = '\0';
  return written;
}

// ── Luna_Start 的 8 个回调实现（__cdecl 默认约定）─────────────────────────────
// Output：全引擎精确台词入口。过滤 + 写文本环。返回值在本 vendored 版恒 true（不作门控）。
void LunaOutput(const wchar_t* hookcode, const char* hookname,
                LunaThreadParam tp, const wchar_t* text) {
  if (g_luna.header != nullptr && text != nullptr) {
    g_luna.header->hook_diagnostics |= kDiagLunaOutputObserved;
    const int len = static_cast<int>(wcslen(text));
    if (LunaDiagEnabled()) {
      char u8[1024];
      LunaWideToUtf8(text, len, u8, sizeof(u8));
      char hc[512];
      LunaWideToUtf8(hookcode != nullptr ? hookcode : L"",
                     hookcode != nullptr ? static_cast<int>(wcslen(hookcode)) : 0,
                     hc, sizeof(hc));
      fprintf(stderr,
              "[lunadiag] name=%s code=%s addr=0x%llx ctx=0x%llx ctx2=0x%llx "
              "len=%d text=%s\n",
              (hookname != nullptr) ? hookname : "(null)", hc,
              static_cast<unsigned long long>(tp.addr),
              static_cast<unsigned long long>(tp.ctx),
              static_cast<unsigned long long>(tp.ctx2), len, u8);
      fflush(stderr);
    }
    if (LunaPassesFilter(text, len)) {
      // 多 hook 自动选干净线程：先判伪影并累计，再决定本行是否写入文本环。
      const bool artifact = LunaTextIsArtifact(text, len);
      const uint64_t thread_id = LunaTextThreadId(hookcode, hookname, tp);
      if (LunaShouldWriteLine(hookcode, thread_id, artifact)) {
        WriteLunaTextLine(g_luna.header, hookcode, hookname, tp, thread_id, text,
                          len);
        // 一旦 LunaHook 写出干净行，标记 LunaHook 权威：游戏内 GDI 文本 hook 让位不再写文本，
        // 避免双写者污染（见 voice_hook_ipc.h SharedHeader::luna_active 注释）。幂等，写 1 即可。
        if (!artifact) {
          g_luna.header->luna_active = 1;
        }
      }
    }
  }
}

// Connect：LunaHook DLL 注入并连回 host 时触发。可选补装通用 PC hooks（默认关，避免与游戏内
// GDI hook 产生重复行；LunaHook 内置的各引擎精确 hook 本就自动上线，无需在此手动插）。
void LunaConnect(DWORD pid) {
  fprintf(stderr, "[luna] connected pid=%lu\n", pid);
  // 连接成功即代表 LunaHook 的文本管线已经安装并可接收内容。不能等到第一句 Output
  // 才置 text_hooked：游戏停在标题/菜单超过 Dart 等待窗口时会把健康 helper 误判失败。
  if (g_luna.header != nullptr && pid == g_luna.pid) {
    g_luna.header->hook_diagnostics |= kDiagLunaConnected;
    g_luna.header->text_hooked = 1;
  }
  if (g_luna.insert_hook != nullptr) {
    for (const std::wstring& code : g_luna.hook_codes) {
      const bool inserted = g_luna.insert_hook(pid, code.c_str());
      fprintf(stderr, "[luna] known hook %ls pid=%lu result=%d\n",
              code.c_str(), pid, inserted ? 1 : 0);
    }
  }
  if (g_luna.use_pc_hooks && g_luna.insert_pc != nullptr) {
    g_luna.insert_pc(pid, 0);
    g_luna.insert_pc(pid, 1);
    fprintf(stderr, "[luna] inserted PC hooks pid=%lu\n", pid);
  }
}
void LunaDisconnect(DWORD pid) {
  fprintf(stderr, "[luna] disconnected pid=%lu\n", pid);
}
// ThreadCreate 是 LunaTranslator 线程列表的真相源。不能再只从已通过自动赢家过滤的 Output
// 反推线程，否则 TextRender 这类候选在线程被选中前没有已发布行，就永远无法出现在选择器里。
void LunaThreadCreate(const wchar_t* hookcode, const char* hookname,
                      LunaThreadParam tp, bool embedable) {
  if (g_luna.header == nullptr) {
    return;
  }
  const uint64_t thread_id = LunaTextThreadId(hookcode, hookname, tp);
  WriteLunaTextEvent(
      g_luna.header, hookcode, hookname, tp, thread_id,
      hibiki_voice_hook::kTextEventThreadDiscovered, embedable ? 1u : 0u,
      nullptr, 0);
}
// 线程目录按捕获会话整体清理；移除事件暂不透传，避免用户刚选中的短生命周期线程在 Luna
// 重建同一 ThreadParam 的间隙被 UI 擅自切回自动。
void LunaThreadRemove(const wchar_t* hookcode, const char* hookname,
                      LunaThreadParam tp) {
  (void)hookcode;
  (void)hookname;
  (void)tp;
}
void LunaHostInfo(int type, const wchar_t* log) {
  (void)type;
  (void)log;
}
void LunaHookInsert(DWORD pid, uint64_t addr, const wchar_t* hookcode) {
  (void)pid;
  (void)addr;
  (void)hookcode;
}
void LunaEmbed(const wchar_t* text, LunaThreadParam tp) {
  (void)text;
  (void)tp;
}

// LunaHook host 侧初始化：加载 LunaHost<arch>.dll、解析导出、注册回调、触发对目标注入。
// 缺 DLL / 缺关键导出 / 加载失败 → 打日志跳过，**不致命**（仍走游戏内 GDI hook）。
// target 是目标进程句柄（复用 InjectDll 把 LunaHook<arch>.dll 注入游戏）。成功接线返回 true。
bool InitLunaHook(SharedHeader* header, HANDLE target, DWORD pid, int codepage,
                  bool use_pc_hooks,
                  const std::vector<std::wstring>& hook_codes) {
  const std::wstring host_path =
      InjectorDir() + L"LunaHost" + kLunaArch + L".dll";
  HMODULE host = LoadLibraryW(host_path.c_str());
  if (host == nullptr) {
    fprintf(stderr,
            "[luna] LunaHost%ls.dll 未加载(%lu)；跳过全引擎文本 hook，仅 GDI hook\n",
            kLunaArch, GetLastError());
    return false;
  }
  auto start =
      reinterpret_cast<PFN_Luna_Start>(GetProcAddress(host, "Luna_Start"));
  auto connect = reinterpret_cast<PFN_Luna_ConnectProcess>(
      GetProcAddress(host, "Luna_ConnectProcess"));
  auto need_inject = reinterpret_cast<PFN_Luna_CheckIfNeedInject>(
      GetProcAddress(host, "Luna_CheckIfNeedInject"));
  auto detach =
      reinterpret_cast<PFN_Luna_DetachProcess>(
          GetProcAddress(host, "Luna_DetachProcess"));
  if (start == nullptr || connect == nullptr || need_inject == nullptr ||
      detach == nullptr) {
    fprintf(stderr,
            "[luna] LunaHost 缺关键导出(Start/ConnectProcess/"
            "CheckIfNeedInject/DetachProcess)；跳过\n");
    FreeLibrary(host);
    return false;
  }
  auto settings = reinterpret_cast<PFN_Luna_Settings>(
      GetProcAddress(host, "Luna_Settings"));  // 可选
  auto insert_pc = reinterpret_cast<PFN_Luna_InsertPCHooks>(
      GetProcAddress(host, "Luna_InsertPCHooks"));  // 可选
  auto insert_hook = reinterpret_cast<PFN_Luna_InsertHookCode>(
      GetProcAddress(host, "Luna_InsertHookCode"));  // 可选

  g_luna.host_dll = host;
  g_luna.header = header;
  g_luna.pid = pid;
  g_luna.detach = detach;
  g_luna.insert_pc = insert_pc;
  g_luna.insert_hook = insert_hook;
  g_luna.use_pc_hooks = use_pc_hooks && (insert_pc != nullptr);
  g_luna.hook_codes = hook_codes;
  header->hook_diagnostics |= kDiagLunaHostReady;

  // flushDelay=200ms（一句停顿 flush 一行）、filterRepetition=true（LunaHook 侧先去重）、
  // codepage（日文 galgame 默认 932/SHIFT_JIS）、maxBufferSize/maxHistorySize 保守非零值。
  if (settings != nullptr) {
    settings(200, true, codepage, 8192, 1000, false);
  }

  // 多 hook 自动选干净线程的计数锁：Output 回调可在 LunaHook 工作线程并发，
  // 于 start() 注册回调前初始化（进程生命期内一次，多次 Init 由 flag 守卫）。
  if (!g_lunaSelectCsInit) {
    InitializeCriticalSection(&g_lunaSelectCs);
    g_lunaSelectCsInit = true;
  }

  // 注册回调，顺序严格对齐 texthook.py：Connect, Disconnect, ThreadCreate, ThreadRemove,
  // Output, HostInfo, HookInsert, Embed, I18NQuery, EmuGameInfo。后两项本组件不用，传空让
  // LunaHost 采用默认行为。
  start(&LunaConnect, &LunaDisconnect, &LunaThreadCreate, &LunaThreadRemove,
        &LunaOutput, &LunaHostInfo, &LunaHookInsert, &LunaEmbed, nullptr,
        nullptr);

  // 触发 attach：先建 host<->hook 管道，再判断目标是否需要注入。需要则把
  // LunaHook<arch>.dll 注入游戏（复用 CreateRemoteThread(LoadLibraryW) 纯 DLL 注入，等价
  // LunaTranslator 的 shareddllproxy dllinject；LunaHook.dll 自初始化、连回管道、自动识别引擎
  // 装台词 hook → Output 回调回传）。
  connect(pid);
  if (need_inject(pid)) {
    const std::wstring hook_path =
        InjectorDir() + L"LunaHook" + kLunaArch + L".dll";
    if (GetFileAttributesW(hook_path.c_str()) == INVALID_FILE_ATTRIBUTES) {
      fprintf(stderr, "[luna] LunaHook%ls.dll 缺失，无法注入；仅 GDI hook\n",
              kLunaArch);
    } else if (!InjectDll(target, hook_path)) {
      header->hook_diagnostics |= kDiagLunaInjectFailed;
      fprintf(stderr, "[luna] LunaHook%ls.dll 注入失败；仅 GDI hook\n",
              kLunaArch);
    } else {
      fprintf(stderr, "[luna] LunaHook%ls.dll 已注入 pid=%lu，等待连接...\n",
              kLunaArch, pid);
    }
  } else {
    fprintf(stderr,
            "[luna] CheckIfNeedInject=false(已 hook 或无需注入) pid=%lu\n", pid);
  }
  return true;
}

// 收尾：DetachProcess 目标（停 LunaHook 侧 hook）。LunaHost 的管道工作线程是 detached thread，
// API 没有 join/等待导出；发送 detach 后立刻 FreeLibrary 会卸载仍在跑的 host 代码。injector 此后
// 立即退出，故成功启动过 Host 时故意保留模块到进程结束，由 OS 安全回收。幂等。
void ShutdownLunaHook() {
  if (g_luna.host_dll != nullptr) {
    if (g_luna.detach != nullptr && g_luna.pid != 0) {
      g_luna.detach(g_luna.pid);
    }
    g_luna.host_dll = nullptr;
    g_luna.header = nullptr;
    g_luna.detach = nullptr;
    g_luna.insert_pc = nullptr;
    g_luna.pid = 0;
  }
}

// LunaHook 运行选项（命令行传入）。
struct LunaOptions {
  bool enabled = true;    // --no-luna 关闭
  int codepage = 932;     // --luna-codepage（日文默认 SHIFT_JIS）
  bool pc_hooks = false;  // --luna-pchooks 补装通用 PC hooks
  std::vector<std::wstring> hook_codes;  // 版本专用、已验证的 H-code
};

// attach 与 launch 共用的注入编排。target=目标进程句柄，pid=目标 pid（命名共享内存/事件）。
// resume_thread!=nullptr（launch 模式）时：注入完成后 ResumeThread 让挂起的游戏跑起来，再等就绪
// 事件——保证 hook 在游戏调 DirectSoundCreate/WinMain 之前就装好。hold_process 在 --hold 时决定
// 挂起终点（launch 给游戏进程句柄，挂到游戏退出；attach 给 nullptr，无限 Sleep）。
// 契约与 --pid 老路径完全一致：建共享内存(pid) + 就绪事件(pid)，注入，[Resume]，等事件，
// 打印 OK hooked ...，[hold]。全部句柄本函数负责关闭。返回进程退出码。
int RunInjection(HANDLE target, DWORD pid, const std::wstring& dll_path,
                 DWORD wait_ms, bool hold, HANDLE resume_thread,
                 HANDLE hold_process, const LunaOptions& luna) {
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
  const uint32_t loopback_capacity = ComputeLoopbackCapacity();
  // v6 布局：[SharedHeader][音频环形 ring_capacity][文本环 kTextSlotCount*kTextSlotBytes]
  //          [clip 索引 kClipCount*sizeof(VoiceClip)][loopback 环 loopback_capacity]
  //          [loopback 标记表 kLoopbackMarkerCount*sizeof(LoopbackMarker)]。各区偏移下面填进 header。
  const uint64_t text_region_bytes =
      static_cast<uint64_t>(kTextSlotCount) * kTextSlotBytes;
  const uint64_t clip_region_bytes =
      static_cast<uint64_t>(kClipCount) * sizeof(VoiceClip);
  const uint64_t loopback_marker_bytes =
      static_cast<uint64_t>(kLoopbackMarkerCount) * sizeof(LoopbackMarker);
  const uint64_t total_size = sizeof(SharedHeader) + ring_capacity +
                              text_region_bytes + clip_region_bytes +
                              loopback_capacity + loopback_marker_bytes;
  const std::wstring shm = SharedMemoryName(pid);
  SetLastError(ERROR_SUCCESS);
  HANDLE mapping = CreateFileMappingW(
      INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE,
      static_cast<DWORD>(total_size >> 32),
      static_cast<DWORD>(total_size & 0xFFFFFFFF), shm.c_str());
  const bool mapping_already_exists = GetLastError() == ERROR_ALREADY_EXISTS;
  if (mapping == nullptr) {
    return Fail("CreateFileMapping failed");
  }
  auto* header = static_cast<SharedHeader*>(
      MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, 0));
  if (header == nullptr) {
    CloseHandle(mapping);
    return Fail("MapViewOfFile failed");
  }
  const uint32_t expected_text_offset =
      static_cast<uint32_t>(sizeof(SharedHeader) + ring_capacity);
  const uint32_t expected_clip_offset =
      static_cast<uint32_t>(expected_text_offset + text_region_bytes);
  const MappingSessionAction mapping_action = InspectMappingSession(
      mapping_already_exists, header, ring_capacity, expected_text_offset,
      expected_clip_offset);
  if (mapping_action == MappingSessionAction::kRejectStale) {
    fprintf(stderr,
            "已存在但不可复用的 hook 会话（契约不匹配或 hooked=0）；请重启一次游戏以清理旧 DLL。\n");
    UnmapViewOfFile(header);
    CloseHandle(mapping);
    return 2;
  }
  const bool reuse_ready = mapping_action == MappingSessionAction::kReuseReady;
  if (!reuse_ready) {
    // 仅新映射允许清零。旧映射由游戏内 DLL 持有；重连时清零会让 hooked 永久丢失。
    memset(header, 0, static_cast<size_t>(total_size));
    header->magic = kSharedMagic;
    header->version = kSharedVersion;
    header->ring_capacity = ring_capacity;
    // 文本环紧随音频环形；clip 索引紧随文本环。hook DLL 据此偏移定位两区。
    header->text_region_offset = expected_text_offset;
    header->clip_region_offset = expected_clip_offset;
    // v9：loopback 环紧随 clip 索引；标记表紧随 loopback 环。
    header->loopback_ring_offset =
        static_cast<uint32_t>(header->clip_region_offset + clip_region_bytes);
    header->loopback_ring_capacity = loopback_capacity;
    header->loopback_marker_offset = static_cast<uint32_t>(
        header->loopback_ring_offset + loopback_capacity);
    header->loopback_marker_slot_count = kLoopbackMarkerCount;
  } else {
    fprintf(stderr,
            "[session] reusing live hook mapping pid=%lu text=%u audioBytes=%llu\n",
            pid, header->text_hooked,
            static_cast<unsigned long long>(header->total_written));
  }
  const UnityExtractorRuntime unity_extractor = FindUnityExtractorRuntime();
  if (unity_extractor.ready) {
    header->hook_diagnostics |= kDiagUnityResourceExtractorReady;
  } else {
    fprintf(stderr,
            "[unity-audio] resource extractor runtime missing; Unity audio will use normal fallback\n");
  }
  // 就绪事件（auto-reset，初始未触发）；hook DLL 装好后 SetEvent。
  const std::wstring evt = ReadyEventName(pid);
  HANDLE ready = CreateEventW(nullptr, FALSE, FALSE, evt.c_str());
  if (ready == nullptr) {
    UnmapViewOfFile(header);
    CloseHandle(mapping);
    return Fail("CreateEvent failed");
  }

  if (!reuse_ready && !InjectDll(target, dll_path)) {
    CloseHandle(ready);
    UnmapViewOfFile(header);
    CloseHandle(mapping);
    return Fail("injection failed");
  }

  // 等 hook DLL 的 proof-of-life。超时=注入了但 DLL 没跑到通知点（arch/契约/权限问题）。
  if (!reuse_ready) {
    const DWORD w = WaitForSingleObject(ready, wait_ms);
    if (w != WAIT_OBJECT_0) {
      fprintf(stderr, "注入完成但未收到就绪信号（%lums 超时）；hooked=%u\n",
              wait_ms, header->hooked);
      CloseHandle(ready);
      UnmapViewOfFile(header);
      CloseHandle(mapping);
      return 2;
    }
  }

  // CREATE_SUSPENDED launch 必须等游戏内 DLL 完成首次 XAudio2/DirectSound 导出 hook，
  // 再恢复主线程。否则 Unity 可能先创建全部 source voice，之后晚 attach 只能拿到混音。
  if (resume_thread != nullptr) {
    const ULONGLONG deadline = GetTickCount64() + wait_ms;
    while ((header->hook_diagnostics & kDiagStartupAudioHooksReady) == 0 &&
           GetTickCount64() < deadline) {
      Sleep(1);
    }
    if ((header->hook_diagnostics & kDiagStartupAudioHooksReady) == 0) {
      fprintf(stderr,
              "startup audio hook readiness timed out; resuming game with text/late-hook fallback\n");
    }

    // 只有游戏内 DLL 完成首轮音频导出 hook 后才允许游戏主线程继续。
    // Unity 会在启动早期创建 XAudio2 engine/source voice，提前恢复会永久错过这些对象。
    if (ResumeThread(resume_thread) == static_cast<DWORD>(-1)) {
      fprintf(stderr, "ResumeThread failed: %lu\n", GetLastError());
      CloseHandle(ready);
      UnmapViewOfFile(header);
      CloseHandle(mapping);
      return 1;
    }
  }

  printf("OK hooked pid=%lu hooked=%u ring=%u sr=%u ch=%u bits=%u float=%u\n",
         pid, header->hooked, header->ring_capacity, header->sample_rate,
         header->channels, header->bits_per_sample, header->is_float);
  fflush(stdout);

  // host 模式（--hold）才接入 LunaHook 全引擎文本 hook：写同一文本环，与游戏内 GDI hook
  // 并存（原子占号防撞槽）。probe 模式确认即退，LunaHook 没有捕获窗口，故不接。
  if (hold && luna.enabled) {
    InitLunaHook(header, target, pid, luna.codepage, luna.pc_hooks,
                 luna.hook_codes);
  }

  if (hold) {
    // host 模式：常驻维持共享内存存活，供 Hibiki 消费（C.2 起真正读 PCM）。
    // 同时消费 Unity Streaming AudioClip 资源事件；重解析/解码在 injector 子进程完成，
    // 游戏内 hook 回调始终只写固定大小共享内存事件。
    uint64_t next_unity_event = 0;
    if (hold_process != nullptr) {
      while (WaitForSingleObject(hold_process, 50) == WAIT_TIMEOUT) {
        ProcessUnityVoiceEvents(header, unity_extractor, &next_unity_event);
      }
      ProcessUnityVoiceEvents(header, unity_extractor, &next_unity_event);
    } else {
      for (;;) {
        ProcessUnityVoiceEvents(header, unity_extractor, &next_unity_event);
        Sleep(50);
      }
    }
  }

  ShutdownLunaHook();  // Detach 目标；Host 模块由进程退出回收（未接入时 no-op）
  CloseHandle(ready);
  UnmapViewOfFile(header);
  CloseHandle(mapping);
  return 0;
}

bool IsSiglusExecutable(const std::wstring& exe) {
  const size_t slash = exe.find_last_of(L"\\/");
  const wchar_t* base =
      slash == std::wstring::npos ? exe.c_str() : exe.c_str() + slash + 1;
  return _wcsicmp(base, L"SiglusEngine.exe") == 0;
}

std::wstring ExecutableBaseName(const std::wstring& exe) {
  const size_t slash = exe.find_last_of(L"\\/");
  if (slash == std::wstring::npos) return exe;
  return exe.substr(slash + 1);
}

std::wstring ExecutableDirectory(const std::wstring& exe) {
  const size_t slash = exe.find_last_of(L"\\/");
  if (slash == std::wstring::npos) return L"";
  return exe.substr(0, slash);
}

std::wstring StripExeExtension(const std::wstring& basename) {
  if (basename.size() >= 4 &&
      _wcsicmp(basename.c_str() + basename.size() - 4, L".exe") == 0) {
    return basename.substr(0, basename.size() - 4);
  }
  return basename;
}

std::wstring JoinPath(const std::wstring& a, const std::wstring& b) {
  if (a.empty()) return b;
  if (a.back() == L'\\' || a.back() == L'/') return a + b;
  return a + L"\\" + b;
}

bool FileExists(const std::wstring& path) {
  const DWORD attr = GetFileAttributesW(path.c_str());
  return attr != INVALID_FILE_ATTRIBUTES &&
         (attr & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

bool DirectoryExists(const std::wstring& path) {
  const DWORD attr = GetFileAttributesW(path.c_str());
  return attr != INVALID_FILE_ATTRIBUTES &&
         (attr & FILE_ATTRIBUTE_DIRECTORY) != 0;
}

std::wstring ProcessImagePath(HANDLE process) {
  std::vector<wchar_t> buffer(32768, L'\0');
  DWORD size = static_cast<DWORD>(buffer.size());
  if (!QueryFullProcessImageNameW(process, 0, buffer.data(), &size) ||
      size == 0) {
    return L"";
  }
  return std::wstring(buffer.data(), size);
}

bool LooksLikeUnityRuntime(const std::wstring& exe) {
  const std::wstring dir = ExecutableDirectory(exe);
  if (dir.empty() || !FileExists(JoinPath(dir, L"UnityPlayer.dll"))) {
    return false;
  }
  const std::wstring stem = StripExeExtension(ExecutableBaseName(exe));
  const std::wstring data = JoinPath(dir, stem + L"_Data");
  const bool il2cpp =
      FileExists(JoinPath(dir, L"GameAssembly.dll")) ||
      FileExists(JoinPath(JoinPath(JoinPath(data, L"il2cpp_data"), L"Metadata"),
                          L"global-metadata.dat"));
  const bool mono = DirectoryExists(JoinPath(data, L"Managed")) ||
                    DirectoryExists(JoinPath(data, L"MonoBleedingEdge")) ||
                    FileExists(JoinPath(dir, L"mono-2.0-bdwgc.dll"));
  return il2cpp || mono;
}

// Siglus 游戏（含改名 exe）：exe 名严格匹配，或 exe 同目录具备 Siglus 文件夹签名。用于把 launch
// 的早注入改为延迟附着，绕过 Enigma 保护壳拒绝挂起态注入导致的 launch_or_inject_failed。
bool LooksLikeSiglusRuntime(const std::wstring& exe) {
  const std::wstring dir = ExecutableDirectory(exe);
  return hibiki_voice_hook::DirectoryLooksLikeSiglus(
      dir, [](const std::wstring& d, const wchar_t* name) {
        return FileExists(JoinPath(d, name));
      });
}

bool IsSiglusGame(const std::wstring& exe) {
  return IsSiglusExecutable(exe) || LooksLikeSiglusRuntime(exe);
}

bool ShouldAutoUseLunaPcHooks(const std::wstring& exe) {
  const std::wstring base = ExecutableBaseName(exe);
  if (_wcsicmp(base.c_str(), L"manosaba.exe") == 0 ||
      _wcsicmp(base.c_str(), L"SiglusEngine.exe") == 0) {
    return true;
  }
  return LooksLikeUnityRuntime(exe) || LooksLikeSiglusRuntime(exe);
}

struct ReadyWindowSearch {
  DWORD pid = 0;
  bool found = false;
};

BOOL CALLBACK FindReadyGameWindow(HWND window, LPARAM param) {
  auto* search = reinterpret_cast<ReadyWindowSearch*>(param);
  DWORD owner = 0;
  GetWindowThreadProcessId(window, &owner);
  if (owner != search->pid || !IsWindowVisible(window)) return TRUE;
  wchar_t title[256] = {0};
  if (GetWindowTextW(window, title, 256) <= 0 ||
      _wcsicmp(title, L"The Enigma Protector") == 0) {
    return TRUE;
  }
  search->found = true;
  return FALSE;
}

// Enigma 完成自校验并进入游戏消息循环后再注入。只看本次子进程的可见非保护器窗口，
// 不靠固定 Sleep 猜机器速度；进程提前退出或超时都明确失败。
bool WaitForSiglusGameWindow(HANDLE process, DWORD pid, DWORD timeout_ms) {
  const uint64_t deadline = GetTickCount64() + timeout_ms;
  while (GetTickCount64() < deadline) {
    if (WaitForSingleObject(process, 0) == WAIT_OBJECT_0) return false;
    ReadyWindowSearch search;
    search.pid = pid;
    EnumWindows(&FindReadyGameWindow, reinterpret_cast<LPARAM>(&search));
    if (search.found) {
      Sleep(200);  // 让窗口创建尾部退出保护器调用栈，再装 inline hooks。
      return true;
    }
    Sleep(50);
  }
  return false;
}

bool ReadSmallUtf8File(const std::wstring& path, std::wstring* out) {
  if (out == nullptr) return false;
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ,
                            FILE_SHARE_READ | FILE_SHARE_WRITE |
                                FILE_SHARE_DELETE,
                            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                            nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  LARGE_INTEGER size = {};
  if (!GetFileSizeEx(file, &size) || size.QuadPart <= 0 ||
      size.QuadPart > 2 * 1024 * 1024) {
    CloseHandle(file);
    return false;
  }
  std::vector<char> bytes(static_cast<size_t>(size.QuadPart));
  DWORD read = 0;
  const bool ok = ReadFile(file, bytes.data(), static_cast<DWORD>(bytes.size()),
                           &read, nullptr) != FALSE &&
                  read == bytes.size();
  CloseHandle(file);
  if (!ok) return false;
  int chars = MultiByteToWideChar(CP_UTF8, 0, bytes.data(), read, nullptr, 0);
  UINT codepage = CP_UTF8;
  if (chars <= 0) {
    codepage = CP_ACP;
    chars = MultiByteToWideChar(codepage, 0, bytes.data(), read, nullptr, 0);
  }
  if (chars <= 0) return false;
  out->assign(static_cast<size_t>(chars), L'\0');
  MultiByteToWideChar(codepage, 0, bytes.data(), read, &(*out)[0], chars);
  return true;
}

std::wstring DiscoverSteamAppId(const std::wstring& executable) {
  hibiki_voice_hook::SteamLibraryPath library;
  if (!hibiki_voice_hook::ParseSteamLibraryPath(executable, &library)) {
    return L"";
  }
  const std::wstring pattern = library.steamapps_dir + L"\\appmanifest_*.acf";
  WIN32_FIND_DATAW data = {};
  HANDLE search = FindFirstFileW(pattern.c_str(), &data);
  if (search == INVALID_HANDLE_VALUE) return L"";
  std::wstring found;
  do {
    if ((data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) continue;
    std::wstring manifest;
    if (!ReadSmallUtf8File(library.steamapps_dir + L"\\" + data.cFileName,
                           &manifest)) {
      continue;
    }
    const std::wstring install = hibiki_voice_hook::ParseAcfQuotedValue(
        manifest, L"installdir");
    if (_wcsicmp(install.c_str(), library.install_dir.c_str()) != 0) continue;
    const std::wstring app_id =
        hibiki_voice_hook::ParseAcfQuotedValue(manifest, L"appid");
    if (!app_id.empty() &&
        std::all_of(app_id.begin(), app_id.end(),
                    [](wchar_t c) { return c >= L'0' && c <= L'9'; })) {
      found = app_id;
      break;
    }
  } while (FindNextFileW(search, &data));
  FindClose(search);
  return found;
}

struct EnvironmentValue {
  bool existed = false;
  std::wstring value;
};

EnvironmentValue CaptureEnvironment(const wchar_t* name) {
  EnvironmentValue result;
  const DWORD need = GetEnvironmentVariableW(name, nullptr, 0);
  if (need == 0) return result;
  std::vector<wchar_t> value(need, 0);
  if (GetEnvironmentVariableW(name, value.data(), need) > 0) {
    result.existed = true;
    result.value = value.data();
  }
  return result;
}

void RestoreEnvironment(const wchar_t* name, const EnvironmentValue& value) {
  SetEnvironmentVariableW(name, value.existed ? value.value.c_str() : nullptr);
}

// launch 模式：一般 CREATE_SUSPENDED 早注入；Siglus 因 Enigma 保护壳改为正常启动后附着。
// 命令行含 exe 本身（CreateProcessW 约定）；workdir 缺省=exe 所在目录。
int RunLaunch(const std::wstring& exe, const std::wstring& workdir_in,
              const std::vector<std::wstring>& extra_args,
              const std::wstring& dll_path, DWORD wait_ms, bool hold,
              const LunaOptions& luna) {
  if (GetFileAttributesW(exe.c_str()) == INVALID_FILE_ATTRIBUTES) {
    return Fail("目标 exe 不存在（--launch <exe路径>）");
  }
  LunaOptions effective_luna = luna;
  effective_luna.hook_codes =
      hibiki_voice_hook::KnownLunaHookCodesForExecutable(exe);
  if (!effective_luna.pc_hooks && ShouldAutoUseLunaPcHooks(exe)) {
    effective_luna.pc_hooks = true;
    fprintf(stderr,
            "[luna] auto-enabled PC hooks for Unity/Mono-style target: %ls\n",
            ExecutableBaseName(exe).c_str());
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
  const bool delayed_siglus = IsSiglusGame(exe);
  // Steam 游戏被直接 CreateProcess 时常会立即退出，再由 Steam 拉起一个未注入子进程。
  // 从 exe 所在库的 appmanifest 自动发现 AppID，并只在本次 CreateProcess 的继承窗口内设置
  // 官方环境变量，避免 Steam 二次拉起导致“看似启动成功、实际 hook 的是已退出进程”。
  const std::wstring steam_app_id = DiscoverSteamAppId(exe);
  const EnvironmentValue old_steam_app = CaptureEnvironment(L"SteamAppId");
  const EnvironmentValue old_steam_game = CaptureEnvironment(L"SteamGameId");
  if (!steam_app_id.empty()) {
    SetEnvironmentVariableW(L"SteamAppId", steam_app_id.c_str());
    SetEnvironmentVariableW(L"SteamGameId", steam_app_id.c_str());
    fprintf(stderr, "[steam] inherited AppID=%ls for %ls\n",
            steam_app_id.c_str(), ExecutableBaseName(exe).c_str());
  }
  const BOOL created = CreateProcessW(
      exe.c_str(), cmd_buf.data(), nullptr, nullptr, FALSE,
      delayed_siglus ? 0 : CREATE_SUSPENDED,
      nullptr, workdir.empty() ? nullptr : workdir.c_str(), &si, &pi);
  if (!steam_app_id.empty()) {
    RestoreEnvironment(L"SteamAppId", old_steam_app);
    RestoreEnvironment(L"SteamGameId", old_steam_game);
  }
  if (!created) {
    fprintf(stderr, "CreateProcessW failed: %lu\n", GetLastError());
    return 1;
  }

  if (delayed_siglus &&
      !WaitForSiglusGameWindow(pi.hProcess, pi.dwProcessId, 20000)) {
    fprintf(stderr, "Siglus 保护壳初始化/游戏窗口等待超时\n");
    TerminateProcess(pi.hProcess, 1);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return 1;
  }

  // 复用 attach 同一套编排；普通 launch 的 resume_thread=pi.hThread（注入后放行），
  // Siglus 已正常运行故为 nullptr；hold_process 让 --hold 挂到游戏退出。
  const int rc = RunInjection(pi.hProcess, pi.dwProcessId, dll_path, wait_ms,
                              hold, delayed_siglus ? nullptr : pi.hThread,
                              pi.hProcess, effective_luna);

  // 普通早注入在注入前/Resume 前失败（rc==1）时游戏仍处挂起：强制结束，避免留下僵死
  // 挂起进程。Siglus 延迟附着时游戏已经正常运行，hook 失败也交给用户/上层回退处理。
  // rc==2（超时但已 Resume）游戏已在跑，不 terminate。rc==0 正常退出，游戏自然运行。
  if (rc == 1 && !delayed_siglus) {
    TerminateProcess(pi.hProcess, 1);
  }
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  return rc;
}

}  // namespace

int main() {
  // stderr 无缓冲：--hold 期间 [luna] 等诊断日志立即落盘/可读（否则块缓冲到进程退出才 flush，
  // host 模式常被外部按 PID 收尾杀掉 → 日志丢失，无法诊断 LunaHook 加载/注入）。
  setvbuf(stderr, nullptr, _IONBF, 0);
  int argc = 0;
  wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  DWORD pid = 0;
  std::wstring launch_exe;
  std::wstring workdir;
  std::vector<std::wstring> launch_args;
  std::wstring dll_path;
  DWORD wait_ms = 5000;
  bool hold = false;
  LunaOptions luna;

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
      } else if (a == L"--no-luna") {
        luna.enabled = false;
      } else if (a == L"--luna-pchooks") {
        luna.pc_hooks = true;
      } else if (a == L"--luna-codepage" && i + 1 < argc) {
        luna.codepage = _wtoi(argv[++i]);
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
        "[--arg <a>]... [--dll <hook.dll>] [--wait-ms N] [--hold]\n"
        "LunaHook(host 侧全引擎文本 hook，仅 --hold 生效): [--no-luna] "
        "[--luna-pchooks] [--luna-codepage <cp=932>]");
  }

  if (dll_path.empty()) {
    dll_path = DefaultDllPath();
  }
  if (GetFileAttributesW(dll_path.c_str()) == INVALID_FILE_ATTRIBUTES) {
    return Fail("hook DLL not found (pass --dll <path>)");
  }

  // launch 模式：CREATE_SUSPENDED 早注入。
  if (!launch_exe.empty()) {
    return RunLaunch(launch_exe, workdir, launch_args, dll_path, wait_ms, hold,
                     luna);
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

  LunaOptions effective_luna = luna;
  const std::wstring target_exe = ProcessImagePath(target);
  effective_luna.hook_codes =
      hibiki_voice_hook::KnownLunaHookCodesForExecutable(target_exe);
  if (!effective_luna.pc_hooks && !target_exe.empty() &&
      ShouldAutoUseLunaPcHooks(target_exe)) {
    effective_luna.pc_hooks = true;
    fprintf(stderr,
            "[luna] auto-enabled PC hooks for attached Unity/Mono-style "
            "target: %ls\n",
            ExecutableBaseName(target_exe).c_str());
  }

  const int rc = RunInjection(target, pid, dll_path, wait_ms, hold, nullptr,
                              nullptr, effective_luna);
  CloseHandle(target);
  return rc;
}
