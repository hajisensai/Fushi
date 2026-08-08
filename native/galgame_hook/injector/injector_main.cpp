#include <windows.h>

#include <bcrypt.h>
#include <mmreg.h>
#include <shellapi.h>
#include <tlhelp32.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <limits>
#include <map>
#include <sstream>
#include <string>
#include <cwchar>
#include <vector>

#include "voice_hook_ipc.h"
#include "voice_hook_session.h"
#include "child_process_policy.h"
#include "ffmpeg_runtime.h"
#include "launch_command_line.h"
#include "launch_failure_policy.h"
#include "locale_emulator_launch.h"
#include "kirikiri_launch_profile.h"
#include "siglus_launch.h"
#include "steam_launch.h"
#include "luna_bridge.h"
#include "luna_hook_config.h"
#include "luna_text_selector.h"
#include "text_thread_identity.h"

// galgame 一键制卡 C 阶段注入器（C.1）。把 hook DLL 注入目标游戏进程，建立共享内存 + 就绪
// 事件，确认注入成功后读回语音格式。Hibiki 主进程把它当子进程拉起（部署红线：注入代码只在
// 这个隔离组件里，不进 hibiki.exe）。
//
// 两种进入方式（二选一）：
//   attach（--pid）：注入已运行进程。适合引擎在游戏运行中才建声音设备的情形。
//   launch（--launch）：通常 CREATE_SUSPENDED 拉起游戏，在其 WinMain 之前注入 hook 再
//     ResumeThread。Steam 游戏必须由客户端启动，因此改走 steam://run 并以 15ms 间隔按完整路径
//     自动发现真实游戏进程后注入；SiglusEngine.exe 的 Enigma 保护壳会拒绝早注入，因此该 exe
//     正常启动，等保护壳退出且游戏主窗口出现后再附着。
//
// 用法：
//   hibiki_voice_injector.exe --pid <PID> [--dll <hook.dll>] [--wait-ms N] [--hold]
//   hibiki_voice_injector.exe --launch <exe> [--workdir <dir>] [--arg <a>]...
//                             [--japanese-locale]
//                             [--dll <hook.dll>] [--wait-ms N] [--hold]
//     --pid     目标进程 ID（attach 模式；与 --launch 二选一）
//     --launch  目标游戏 exe 路径（launch 模式；与 --pid 二选一）
//     --workdir 子进程工作目录（launch 缺省=exe 所在目录）
//     --arg     追加一个传给子进程的命令行参数（可重复；launch 专用）
//     --japanese-locale  用 injector 同目录的 Locale Emulator 运行库建立日语 CP932
//               环境，再在同一个挂起进程里完成 Hibiki 早注入。运行库不可用时告警并安全
//               回退普通启动（launch 专用；Steam 协议启动会明确告警且不伪装已转区）。
//     --dll     hook DLL 路径（默认取同目录 arch 匹配的 hibiki_voice_hook.dll）
//     --wait-ms 等待就绪事件的超时毫秒（默认 5000）
//     --hold    注入并确认后保持运行（host 模式，维持共享内存存活）；缺省=probe 模式，
//               确认后退出。launch 模式下 --hold 会一直挂到游戏进程退出。
//     --follow-child-processes  等启动器产生真实游戏子进程后再注入；Ren'Py 目录签名会自动启用。
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
using hibiki_voice_hook::kStableIpcVersion;
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
using hibiki_voice_hook::LunaBridgeExports;
using hibiki_voice_hook::LunaThreadParam;
using hibiki_voice_hook::PFN_Luna_DetachProcess;
using hibiki_voice_hook::PFN_Luna_InsertHookCode;
using hibiki_voice_hook::PFN_Luna_InsertPCHooks;
using hibiki_voice_hook::PFN_Luna_RemoveHook;

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

// 默认 DLL 路径：跟随注入器 basename。旧 Hibiki host 启动
// hibiki_voice_injector.exe 时必须继续加载 hibiki_voice_hook.dll，使两侧共同选择旧 IPC 名；
// 正常 Fushi 分发保持 fushi_voice_hook.dll。
std::wstring DefaultDllPath() {
  wchar_t exe[MAX_PATH] = {0};
  const DWORD n = GetModuleFileNameW(nullptr, exe, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) {
    return L"fushi_voice_hook.dll";
  }
  const std::wstring executable_path(exe, n);
  const bool legacy_hibiki =
      hibiki_voice_hook::ComponentUsesLegacyHibikiIpc(executable_path);
  std::wstring path = executable_path;
  const size_t slash = path.find_last_of(L"\\/");
  if (slash != std::wstring::npos) {
    path.resize(slash + 1);
  } else {
    path.clear();
  }
  return path +
         (legacy_hibiki ? L"hibiki_voice_hook.dll" : L"fushi_voice_hook.dll");
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

// 把结构化失败原因打成 host 可解析的一行。人类可读诊断保持原样（诊断包/日志仍要它），
// 这一行只是让 Hibiki 不必去猜中文串，从而能对「需要管理员 / 位数不符 / 被杀软拦下 /
// DLL 加载慢」给出各自不同的处置与重试策略。
void ReportFailureReason(hibiki_voice_hook::LaunchFailureReason reason,
                         int exit_code) {
  if (reason == hibiki_voice_hook::LaunchFailureReason::kNone) return;
  fprintf(stderr, "ERR reason=%s exit=%d\n",
          hibiki_voice_hook::LaunchFailureToken(reason), exit_code);
}

// 记录失败原因并返回退出码：每个失败出口都必须同时给出这两样，否则 host 只会看到
// 一个没有原因的非零退出。
int FailWith(hibiki_voice_hook::LaunchFailureReason* reason_out,
             hibiki_voice_hook::LaunchFailureReason reason, int exit_code) {
  if (reason_out != nullptr) *reason_out = reason;
  return exit_code;
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

// host 侧 LunaHook 运行时上下文（单目标进程，injector 一对一）。
struct LunaCtx {
  HMODULE host_dll = nullptr;      // 加载进 injector 的 LunaHost<arch>.dll
  SharedHeader* header = nullptr;  // injector map 的共享内存头（写文本环用）
  DWORD pid = 0;                   // 目标游戏 pid（Detach 用）
  PFN_Luna_DetachProcess detach = nullptr;
  PFN_Luna_InsertPCHooks insert_pc = nullptr;
  PFN_Luna_InsertHookCode insert_hook = nullptr;
  PFN_Luna_RemoveHook remove_hook = nullptr;
  bool use_pc_hooks = false;       // 连接后是否补装通用 PC hooks（默认否，避免与 GDI 重复）
  std::vector<std::wstring> hook_codes;
  std::vector<std::wstring> blocked_hook_codes;
  std::vector<std::wstring> blocked_hook_names;
  std::vector<std::wstring> confirmed_blocked_hook_names;
  std::vector<std::wstring> preferred_hook_codes;
  volatile LONG blocked_hook_remove_requests = 0;
  volatile LONG blocked_hook_remove_confirmations = 0;
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
  runtime.executable = base + L"fushi_unity_audio_extract.exe";
  runtime.classdata = base + L"classdata.tpk";
  runtime.decoder = base + L"vgmstream-cli.exe";
  runtime.ready = RegularFileExists(runtime.executable) &&
                  RegularFileExists(runtime.classdata) &&
                  RegularFileExists(runtime.decoder);
  return runtime;
}

std::wstring FindUnityDataDirectory(HANDLE process) {
  std::vector<wchar_t> image(32768, L'\0');
  DWORD length = static_cast<DWORD>(image.size());
  if (!QueryFullProcessImageNameW(process, 0, image.data(), &length) ||
      length == 0) {
    return L"";
  }
  std::wstring executable(image.data(), length);
  const size_t slash = executable.find_last_of(L"\\/");
  const size_t dot = executable.find_last_of(L'.');
  if (slash == std::wstring::npos) return L"";
  const std::wstring directory = executable.substr(0, slash + 1);
  const std::wstring stem = executable.substr(
      slash + 1,
      dot == std::wstring::npos || dot < slash ? std::wstring::npos
                                               : dot - slash - 1);
  const std::wstring candidates[] = {
      directory + stem + L"_Data",
      directory + L"Data",
  };
  for (const std::wstring& candidate : candidates) {
    if (RegularFileExists(candidate + L"\\resources.assets")) {
      return candidate;
    }
  }
  return L"";
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

struct WavePcm {
  std::vector<uint8_t> bytes;
  uint32_t sample_rate = 0;
  uint32_t channels = 0;
  uint32_t bits_per_sample = 0;
  uint32_t block_align = 0;
  uint32_t is_float = 0;
};

uint16_t ReadLe16(const uint8_t* data) {
  return static_cast<uint16_t>(data[0]) |
         (static_cast<uint16_t>(data[1]) << 8);
}

uint32_t ReadLe32(const uint8_t* data) {
  return static_cast<uint32_t>(data[0]) |
         (static_cast<uint32_t>(data[1]) << 8) |
         (static_cast<uint32_t>(data[2]) << 16) |
         (static_cast<uint32_t>(data[3]) << 24);
}

bool ReadUnityWavePcm(const std::wstring& path, uint32_t max_bytes,
                      WavePcm* result) {
  if (result == nullptr || max_bytes == 0) return false;
  std::ifstream input(path, std::ios::binary);
  uint8_t riff[12] = {0};
  if (!input.read(reinterpret_cast<char*>(riff), sizeof(riff)) ||
      memcmp(riff, "RIFF", 4) != 0 || memcmp(riff + 8, "WAVE", 4) != 0) {
    return false;
  }

  bool found_format = false;
  std::streamoff data_offset = 0;
  uint32_t data_size = 0;
  while (input) {
    uint8_t chunk_header[8] = {0};
    if (!input.read(reinterpret_cast<char*>(chunk_header),
                    sizeof(chunk_header))) {
      break;
    }
    const uint32_t chunk_size = ReadLe32(chunk_header + 4);
    const std::streamoff payload = input.tellg();
    if (memcmp(chunk_header, "fmt ", 4) == 0) {
      if (chunk_size < 16 || chunk_size > 64) return false;
      std::vector<uint8_t> format(chunk_size);
      if (!input.read(reinterpret_cast<char*>(format.data()), chunk_size)) {
        return false;
      }
      uint16_t format_tag = ReadLe16(format.data());
      if (format_tag == WAVE_FORMAT_EXTENSIBLE && chunk_size >= 40) {
        format_tag = static_cast<uint16_t>(ReadLe32(format.data() + 24));
      }
      if (format_tag != WAVE_FORMAT_PCM &&
          format_tag != WAVE_FORMAT_IEEE_FLOAT) {
        return false;
      }
      result->channels = ReadLe16(format.data() + 2);
      result->sample_rate = ReadLe32(format.data() + 4);
      result->block_align = ReadLe16(format.data() + 12);
      result->bits_per_sample = ReadLe16(format.data() + 14);
      result->is_float = format_tag == WAVE_FORMAT_IEEE_FLOAT ? 1u : 0u;
      const uint32_t expected_align =
          result->channels * ((result->bits_per_sample + 7) / 8);
      if (result->channels == 0 || result->sample_rate == 0 ||
          result->bits_per_sample == 0 || result->block_align == 0 ||
          result->block_align != expected_align) {
        return false;
      }
      found_format = true;
    } else if (memcmp(chunk_header, "data", 4) == 0) {
      data_offset = payload;
      data_size = chunk_size;
    }
    const uint64_t next =
        static_cast<uint64_t>(payload) + chunk_size + (chunk_size & 1u);
    const uint64_t max_stream_offset = static_cast<uint64_t>(
        (std::numeric_limits<std::streamoff>::max)());
    if (next > max_stream_offset) {
      return false;
    }
    input.clear();
    input.seekg(static_cast<std::streamoff>(next), std::ios::beg);
    if (found_format && data_size != 0) break;
  }
  if (!found_format || data_size == 0 || data_offset <= 0) return false;

  uint32_t retained = (std::min)(data_size, max_bytes);
  retained -= retained % result->block_align;
  if (retained == 0) return false;
  result->bytes.resize(retained);
  input.clear();
  input.seekg(data_offset, std::ios::beg);
  return input.read(reinterpret_cast<char*>(result->bytes.data()), retained)
      .good();
}

uint64_t UnityClipSourceId(const wchar_t* clip_name) {
  uint64_t hash = 1469598103934665603ull;
  if (clip_name != nullptr) {
    for (const wchar_t* cursor = clip_name; *cursor != 0; ++cursor) {
      const uint32_t value = static_cast<uint32_t>(*cursor);
      for (int shift = 0; shift < 32; shift += 8) {
        hash ^= (value >> shift) & 0xffu;
        hash *= 1099511628211ull;
      }
    }
  }
  return 0x554e000000000000ull | (hash & 0x0000ffffffffffffull);
}

bool CommitUnityWavePcm(SharedHeader* header, const UnityVoiceEvent& event,
                        const std::wstring& output) {
  if (header == nullptr || header->ring_capacity == 0 ||
      header->clip_region_offset == 0) {
    return false;
  }
  WavePcm wave;
  if (!ReadUnityWavePcm(output, header->ring_capacity, &wave)) {
    fprintf(stderr, "[unity-audio] invalid wav clip=%ls output=%ls\n",
            event.clip_name, output.c_str());
    return false;
  }

  const uint32_t byte_len = static_cast<uint32_t>(wave.bytes.size());
  const uint32_t capacity = header->ring_capacity;
  const uint64_t start = static_cast<uint64_t>(InterlockedExchangeAdd64(
      reinterpret_cast<volatile LONGLONG*>(&header->total_written),
      static_cast<LONGLONG>(byte_len)));
  const uint32_t ring_offset = static_cast<uint32_t>(start % capacity);
  uint8_t* const ring =
      reinterpret_cast<uint8_t*>(header) + sizeof(SharedHeader);
  const uint32_t first =
      (std::min)(byte_len, capacity - ring_offset);
  memcpy(ring + ring_offset, wave.bytes.data(), first);
  if (byte_len > first) {
    memcpy(ring, wave.bytes.data() + first, byte_len - first);
  }
  header->write_pos =
      static_cast<uint32_t>((start + byte_len) % capacity);

  if (header->sample_rate == 0) {
    header->channels = wave.channels;
    header->bits_per_sample = wave.bits_per_sample;
    header->is_float = wave.is_float;
    header->block_align = wave.block_align;
    MemoryBarrier();
    InterlockedCompareExchange(
        reinterpret_cast<volatile LONG*>(&header->sample_rate),
        static_cast<LONG>(wave.sample_rate), 0);
  }

  const uint64_t index = static_cast<uint64_t>(InterlockedExchangeAdd64(
      reinterpret_cast<volatile LONGLONG*>(&header->clip_write_count), 1));
  uint8_t* const clip_base =
      reinterpret_cast<uint8_t*>(header) + header->clip_region_offset;
  auto* clip = reinterpret_cast<VoiceClip*>(
      clip_base + (index % kClipCount) * sizeof(VoiceClip));
  clip->timestamp_ms = event.timestamp_ms;
  clip->total_at_write = start + byte_len;
  clip->ring_offset = ring_offset;
  clip->byte_len = byte_len;
  clip->sample_rate = wave.sample_rate;
  clip->channels = wave.channels;
  clip->bits_per_sample = wave.bits_per_sample;
  clip->is_float = wave.is_float;
  clip->pad = 0;
  clip->source_ptr = UnityClipSourceId(event.clip_name);
  MemoryBarrier();
  clip->seq = index + 1;
  fprintf(stderr,
          "[unity-audio] committed clip=%ls bytes=%u format=%u/%u/%u "
          "source=0x%016llx\n",
          event.clip_name, byte_len, wave.sample_rate, wave.channels,
          wave.bits_per_sample,
          static_cast<unsigned long long>(clip->source_ptr));
  return true;
}

bool ExtractUnityVoice(const UnityExtractorRuntime& runtime,
                       const std::wstring& data_directory,
                       const UnityVoiceEvent& event, SharedHeader* header) {
  if (!runtime.ready || event.clip_name[0] == 0 ||
      (event.bundle_path[0] == 0 && data_directory.empty())) {
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
      (event.bundle_path[0] == 0
           ? L" --data-dir " + QuoteWindowsArgument(data_directory)
           : L" --bundle " + QuoteWindowsArgument(event.bundle_path)) +
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
  const bool extracted = wait == WAIT_OBJECT_0 && exit_code == 0 &&
                         RegularFileExists(output);
  const bool ok = extracted && CommitUnityWavePcm(header, event, output);
  fprintf(stderr, "[unity-audio] %s clip=%ls input=%ls output=%ls\n",
          ok ? "extracted-and-committed" : "failed", event.clip_name,
          event.bundle_path[0] == 0 ? data_directory.c_str()
                                    : event.bundle_path,
          output.c_str());
  return ok;
}

void ProcessUnityVoiceEvents(SharedHeader* header,
                             const UnityExtractorRuntime& runtime,
                             const std::wstring& data_directory,
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
    if (ExtractUnityVoice(runtime, data_directory, event, header)) {
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
uint64_t LunaTextThreadId(const wchar_t* hookcode, const char* hookname,
                          const LunaThreadParam& tp) {
  return hibiki_voice_hook::NormalizeLunaTextThreadId(
      hibiki_voice_hook::LunaTextThreadIdFrom(
          tp.processId, tp.addr, tp.ctx, tp.ctx2, hookcode, hookname));
}

// hook「面」id：与 LunaTextThreadId 同源，但**刻意不含 ctx**（BUG-1159）。
// ctx 是调用点（返回地址），同一 hook 面换剧情分支就变；ctx2 是 split H 码声明的
// 语义分类（角色名/正文），必须保留。判据实现在 luna_text_selector.h，与单测共用。
uint64_t LunaTextFaceId(const wchar_t* hookcode, const char* hookname,
                        const LunaThreadParam& tp) {
  return hibiki_voice_hook::LunaTextFaceIdFrom(tp.processId, tp.addr, tp.ctx2,
                                               hookcode, hookname);
}

// Luna 侧写者状态。**必须定义在所有写路径之前**：v13 起写文本道也要在这把锁下认领，
// 与预览槽认领共用同一把锁、同一套下标分区。
hibiki_voice_hook::LunaTextSelector g_lunaTextSelector;
CRITICAL_SECTION g_lunaSelectCs;
bool g_lunaSelectCsInit = false;
alignas(8) volatile uint64_t g_lunaPreviewGeneration = 0;

void WriteLunaTextEvent(SharedHeader* header, const wchar_t* hookcode,
                        const char* hookname, const LunaThreadParam& tp,
                        uint64_t thread_id, uint64_t face_id,
                        uint32_t event_kind, uint32_t event_flags,
                        const wchar_t* text, int wlen) {
  if (header == nullptr ||
      (event_kind == hibiki_voice_hook::kTextEventLine &&
       (text == nullptr || wlen <= 0))) {
    return;
  }
  // v13：写进本线程自己那条道（Luna 在 injector 进程，用低段下标）。认领要与 ShouldWrite
  // 共用同一把进程内锁；跨进程隔离由区段划分保证，见 voice_hook_ipc.h 的分道注释。
  hibiki_voice_hook::TextLaneWrite write;
  write.thread_id = thread_id;
  write.face_id = face_id;
  write.thread_address = tp.addr;
  write.thread_context = tp.ctx;
  write.thread_context2 = tp.ctx2;
  write.process_id = tp.processId;
  write.source_kind = hibiki_voice_hook::kTextSourceLuna;
  write.event_kind = event_kind;
  write.event_flags = event_flags;
  write.is_utf8 = 0;  // UTF-16LE
  write.text = (text == nullptr || wlen <= 0) ? nullptr : text;
  write.byte_len = (text == nullptr || wlen <= 0)
                       ? 0
                       : static_cast<uint32_t>(wlen) *
                             static_cast<uint32_t>(sizeof(wchar_t));
  write.hook_name = hookname;
  write.hook_code = hookcode;
  const bool locked = g_lunaSelectCsInit;
  if (locked) EnterCriticalSection(&g_lunaSelectCs);
  hibiki_voice_hook::WriteTextLaneEvent(
      header, 0, hibiki_voice_hook::kLunaThreadPreviewCount, write);
  if (locked) LeaveCriticalSection(&g_lunaSelectCs);
}

void WriteLunaTextLine(SharedHeader* header, const wchar_t* hookcode,
                       const char* hookname, const LunaThreadParam& tp,
                       uint64_t thread_id, uint64_t face_id,
                       const wchar_t* text, int wlen) {
  WriteLunaTextEvent(header, hookcode, hookname, tp, thread_id, face_id,
                     hibiki_voice_hook::kTextEventLine, 0, text, wlen);
}

// ── 文本线程准入（LunaHook 伪影过滤 + 显式线程选择）────
// LunaHook 对同一个游戏常同时装多条 hook，同一句对白会被多条各回传一次：只有一条
// 干净，其余是坏 hook 产生的伪影（整串重复 / 每字重复 N 次）。
//
// v12 起不再自动挑赢家；v13 起连"只发布选定线程"也一并取消：每条线程写自己那条道，
// 挤压结构上不可能，采集期没有任何理由再丢行。选定线程只在消费侧使用。伪影仍在写入前
// 剔除（它们会挤掉本线程自己的真台词）。理由见 voice_hook_ipc.h 的 v13 分道注释。
//
// EmbedKrkrZ 的精确完整行双写先折叠成第一份；其他引擎保持原过滤语义。
// 伪影判别（纯函数）：给定规范化后的 [text,len]，判断是否为坏 hook 的重复伪影。
//   ① 等长游程：对字符串做游程编码（连续相同字符归为一段），若段数 >=3 且所有段
//     长度相等且 >=2 → 伪影（捕获每字×2/×3/×10 等）。
// 其余为“干净”。
// 线程准入的纯逻辑位于 luna_text_selector.h；运行时只负责跨回调加锁和读取手动选择值。
// v12：把本行记进该线程的预览槽。**必须在任何过滤/门控之前调用**——预览区存在的意义
// 就是让用户看见那些没被发布的线程；只记已发布行等于什么都没做。
//
// 寻址按 thread_id 线性查找/认领，不取模全局序号：这正是预览区不会被逐字重绘型 hook
// 挤爆的原因（它只覆盖自己的槽）。ThreadRemove 会回收槽并留下空洞，所以查找必须扫完整张
// 表：先找已有 id，再回退到遇到的第一个空槽。
//
// 与 ShouldWrite 复用同一把锁。锁串行化多个 Luna 回调 writer；槽内 odd/even seq 则保护
// 跨进程 reader，二者缺一不可。
void WriteThreadPreview(SharedHeader* header, uint64_t thread_id,
                        bool is_artifact, const wchar_t* text, int wlen) {
  if (header == nullptr || thread_id == 0 ||
      header->thread_preview_offset == 0 || !g_lunaSelectCsInit) {
    return;
  }
  EnterCriticalSection(&g_lunaSelectCs);
  auto* slots = reinterpret_cast<hibiki_voice_hook::ThreadPreviewSlot*>(
      reinterpret_cast<uint8_t*>(header) + header->thread_preview_offset);
  const uint32_t count = (std::min)(header->thread_preview_slot_count,
                                    hibiki_voice_hook::kLunaThreadPreviewCount);
  hibiki_voice_hook::ThreadPreviewSlot* slot =
      hibiki_voice_hook::FindThreadPreviewSlot(slots, count, thread_id);
  if (slot == nullptr) {
    LeaveCriticalSection(&g_lunaSelectCs);
    return;  // 只有 64 条同时存活线程时才会满；ThreadRemove 后的槽会立即可复用。
  }
  const uint64_t generation = hibiki_voice_hook::NextThreadPreviewGeneration(
      &g_lunaPreviewGeneration);
  hibiki_voice_hook::BeginThreadPreviewWrite(slot, generation);
  if (slot->thread_id == 0) {
    slot->line_count = 0;
    slot->artifact_count = 0;
    ZeroMemory(slot->text, sizeof(slot->text));
  }
  slot->thread_id = thread_id;
  slot->line_count++;
  if (is_artifact) slot->artifact_count++;
  uint32_t byte_len = (text == nullptr || wlen <= 0)
                          ? 0
                          : static_cast<uint32_t>(wlen) * sizeof(wchar_t);
  const uint32_t max_bytes =
      hibiki_voice_hook::kThreadPreviewTextChars * sizeof(wchar_t);
  if (byte_len > max_bytes) byte_len = max_bytes;  // 截断到槽容量（wchar 边界）
  if (byte_len != 0) memcpy(slot->text, text, byte_len);
  slot->byte_len = byte_len;
  slot->event_flags =
      is_artifact ? hibiki_voice_hook::kThreadPreviewFlagArtifact : 0u;
  slot->timestamp_ms = GetTickCount64();
  hibiki_voice_hook::PublishThreadPreviewWrite(slot, generation);
  // 全局计数最后发布：把它当变化信号的 reader 看到新 generation 时，槽必已是稳定偶数态。
  hibiki_voice_hook::PublishThreadPreviewChange(
      &header->thread_preview_write_count);
  LeaveCriticalSection(&g_lunaSelectCs);
}

// v12 文本环只接受用户显式选择的线程。hookcode/profile prefer 不参与准入判定：否则
// selected_text_thread_id 仍为 0、UI 显示未选择时，profile 快路却会在后台悄悄发布文本。
bool LunaShouldWriteLine(uint64_t thread_id, bool is_artifact,
                         uint64_t face_id) {
  // v13：采集期**不再有选定线程过滤**。每条线程写自己那条道，挤压在结构上已不可能，
  // 于是"只发布选定线程"这条丢数据的规则失去了存在理由——它当初存在只是为了保护那块
  // 256 槽全局 FIFO 里的配对候选。选定线程改由消费方使用（host 的文本消费点、游戏内
  // kirikiri 配对候选扫描），native 侧一行都不丢。
  //
  // 唯一仍然拦下的是伪影行（逐字重绘产生的半截串）：它们不是台词，进道只会挤掉本线程
  // 自己的真台词。伪影线程本身在预览区照样看得见（那里另有 artifact 标记位）。
  if (is_artifact) return false;
  // face 登记仍然要做：跨会话记忆恢复与同 hook 面兄弟线程的判定都依赖它（BUG-1159）。
  if (g_lunaSelectCsInit) {
    EnterCriticalSection(&g_lunaSelectCs);
    g_lunaTextSelector.NoteFace(thread_id, face_id);
    LeaveCriticalSection(&g_lunaSelectCs);
  }
  return true;
}

// ── Luna_Start 的回调实现（__cdecl 默认约定）─────────────────────────────────
// Output：全引擎精确台词入口。过滤 + 写文本环。v10.16.1.2 ABI 返回 void。
// LunaHook 逐行诊断（env `FUSHI_LUNA_DIAG=1` 打开）：把**每一行**（含随后被 filter/伪影/线程
// 选择丢弃的）连同其 hook 上下文（hookname / hookcode 签名 / addr / ctx / ctx2）打到 stderr。用于
// 实证「系统菜单标题（读/存档确认）是否与对话走不同 hook」——若不同则可在 hook 层白名单精确排除，
// 若同 hook 则只能回落文本层启发式。默认关（零开销）；不改任何写入路径，纯观测。
bool LunaDiagEnabled() {
  static const bool enabled = []() {
    char buf[8] = {0};
    const DWORD n = GetEnvironmentVariableA("FUSHI_LUNA_DIAG", buf, sizeof(buf));
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
    const int raw_len = static_cast<int>(wcslen(text));
    const int normalized_len =
        hibiki_voice_hook::LunaNormalizedTextLengthForHook(hookname, text,
                                                           raw_len);
    if (LunaDiagEnabled()) {
      char u8[1024];
      LunaWideToUtf8(text, raw_len, u8, sizeof(u8));
      char hc[512];
      LunaWideToUtf8(hookcode != nullptr ? hookcode : L"",
                     hookcode != nullptr ? static_cast<int>(wcslen(hookcode)) : 0,
                     hc, sizeof(hc));
      fprintf(stderr,
              "[lunadiag] name=%s code=%s addr=0x%llx ctx=0x%llx ctx2=0x%llx "
              "raw_len=%d normalized_len=%d text=%s\n",
              (hookname != nullptr) ? hookname : "(null)", hc,
              static_cast<unsigned long long>(tp.addr),
              static_cast<unsigned long long>(tp.ctx),
              static_cast<unsigned long long>(tp.ctx2), raw_len,
              normalized_len, u8);
      fflush(stderr);
    }
    if (LunaPassesFilter(text, normalized_len)) {
      // 先判伪影，再决定本行是否写入文本环。
      const bool artifact =
          hibiki_voice_hook::LunaTextIsArtifact(text, normalized_len);
      const uint64_t thread_id = LunaTextThreadId(hookcode, hookname, tp);
      const uint64_t face_id = LunaTextFaceId(hookcode, hookname, tp);
      // v12：预览必须写在门控**之前**且无条件（含伪影行）。预览区的全部意义就是让用户
      // 看见未被发布的线程；放到门控之后就只剩已选中的那条，等于没做。
      WriteThreadPreview(g_luna.header, thread_id, artifact, text,
                         normalized_len);
      // LunaHook 权威标记：游戏内 GDI 文本 hook 据此让位，避免双写者污染（见
      // voice_hook_ipc.h SharedHeader::luna_active 注释）。幂等，写 1 即可。
      //
      // v12：判据从「已**发布**干净行」改成「已**观测到**干净行」。取消自动选线程后
      // 用户选定之前一行都不发布，若仍绑在发布上，luna_active 永远是 0，GDI 会在整个
      // 选线程期间把逐字重绘垃圾灌进文本环——旧行为下自动赢家几行内就置位，这个窗口
      // 根本不存在。绑在观测上既保住原意（LunaHook 确实覆盖了这个引擎 → GDI 让位），
      // 又不依赖发布门控；LunaHook 对该引擎无输出时 luna_active 仍为 0，GDI 兜底照旧。
      if (!artifact) {
        g_luna.header->luna_active = 1;
      }
      if (LunaShouldWriteLine(thread_id, artifact, face_id)) {
        WriteLunaTextLine(g_luna.header, hookcode, hookname, tp, thread_id,
                          face_id, text, normalized_len);
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
      LunaTextFaceId(hookcode, hookname, tp),
      hibiki_voice_hook::kTextEventThreadDiscovered, embedable ? 1u : 0u,
      nullptr, 0);
}
// 移除事件不透传到线程目录，且不清 selected_text_thread_id / face map：同 ThreadParam 短暂
// 重建仍沿用用户选择。这里只回收预览槽，避免累计超过 64 个历史线程后新线程永久没有预览。
void LunaThreadRemove(const wchar_t* hookcode, const char* hookname,
                      LunaThreadParam tp) {
  if (g_luna.header == nullptr || !g_lunaSelectCsInit ||
      g_luna.header->thread_preview_offset == 0) {
    return;
  }
  const uint64_t thread_id = LunaTextThreadId(hookcode, hookname, tp);
  EnterCriticalSection(&g_lunaSelectCs);
  auto* slots = reinterpret_cast<hibiki_voice_hook::ThreadPreviewSlot*>(
      reinterpret_cast<uint8_t*>(g_luna.header) +
      g_luna.header->thread_preview_offset);
  const uint32_t count =
      (std::min)(g_luna.header->thread_preview_slot_count,
                 hibiki_voice_hook::kLunaThreadPreviewCount);
  for (uint32_t i = 0; i < count; ++i) {
    auto* slot = &slots[i];
    if (slot->thread_id != thread_id) continue;
    const uint64_t generation =
        hibiki_voice_hook::NextThreadPreviewGeneration(
            &g_lunaPreviewGeneration);
    hibiki_voice_hook::BeginThreadPreviewWrite(slot, generation);
    hibiki_voice_hook::ClearThreadPreviewPayload(slot);
    hibiki_voice_hook::PublishThreadPreviewWrite(slot, generation);
    hibiki_voice_hook::PublishThreadPreviewChange(
        &g_luna.header->thread_preview_write_count);
    break;
  }
  LeaveCriticalSection(&g_lunaSelectCs);
}
void LunaHostInfo(int type, const wchar_t* log) {
  if (LunaDiagEnabled() && log != nullptr) {
    fwprintf(stderr, L"[lunahost] type=%d log=%ls\n", type, log);
    fflush(stderr);
  }
  if (log == nullptr) return;
  const LONG requests =
      InterlockedCompareExchange(&g_luna.blocked_hook_remove_requests, 0, 0);
  LONG confirmations = InterlockedCompareExchange(
      &g_luna.blocked_hook_remove_confirmations, 0, 0);
  if (confirmations >= requests) return;
  for (const std::wstring& name : g_luna.blocked_hook_names) {
    if (hibiki_voice_hook::LunaHostLogConfirmsHookRemoval(log, name) &&
        std::find(g_luna.confirmed_blocked_hook_names.begin(),
                  g_luna.confirmed_blocked_hook_names.end(),
                  name) == g_luna.confirmed_blocked_hook_names.end()) {
      g_luna.confirmed_blocked_hook_names.push_back(name);
      confirmations =
          InterlockedIncrement(&g_luna.blocked_hook_remove_confirmations);
      fprintf(stderr,
              "[luna] confirmed unsafe auto hook removal "
              "(confirmed=%ld requested=%ld)\n",
              confirmations, requests);
      return;
    }
  }
}
void LunaHookInsert(DWORD pid, uint64_t addr, const wchar_t* hookcode) {
  if (pid != g_luna.pid || hookcode == nullptr) return;
  if (LunaDiagEnabled()) {
    fwprintf(stderr, L"[lunahookinsert] pid=%lu addr=0x%llx code=%ls\n", pid,
             static_cast<unsigned long long>(addr), hookcode);
    fflush(stderr);
  }
  for (const std::wstring& blocked : g_luna.blocked_hook_codes) {
    if (!hibiki_voice_hook::LunaHookCodeMatchesBlock(blocked, hookcode)) {
      continue;
    }
    if (g_luna.remove_hook == nullptr) {
      fprintf(stderr,
              "[luna] unsafe auto hook matched but Luna_RemoveHook is missing: "
              "%ls pid=%lu\n",
              hookcode, pid);
      return;
    }
    g_luna.remove_hook(pid, addr);
    InterlockedIncrement(&g_luna.blocked_hook_remove_requests);
    fprintf(stderr,
            "[luna] requested unsafe auto hook removal %ls pid=%lu "
            "addr=0x%llx\n",
            hookcode, pid, static_cast<unsigned long long>(addr));
    return;
  }
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
                  const std::vector<std::wstring>& hook_codes,
                  const std::vector<std::wstring>& blocked_hook_codes,
                  const std::vector<std::wstring>& blocked_hook_names,
                  const std::vector<std::wstring>& preferred_hook_codes) {
  const std::wstring host_path =
      InjectorDir() + L"LunaHost" + kLunaArch + L".dll";
  HMODULE host = LoadLibraryW(host_path.c_str());
  if (host == nullptr) {
    fprintf(stderr,
            "[luna] LunaHost%ls.dll 未加载(%lu)；跳过全引擎文本 hook，仅 GDI hook\n",
            kLunaArch, GetLastError());
    return false;
  }
  LunaBridgeExports bridge;
  if (!bridge.Resolve(host)) {
    fprintf(stderr,
            "[luna] LunaHost 缺关键导出(Start/ConnectProcess/"
            "CheckIfNeedInject/DetachProcess)；跳过\n");
    FreeLibrary(host);
    return false;
  }
  g_luna.host_dll = host;
  g_luna.header = header;
  g_luna.pid = pid;
  g_luna.detach = bridge.detach;
  g_luna.insert_pc = bridge.insert_pc;
  g_luna.insert_hook = bridge.insert_hook;
  g_luna.remove_hook = bridge.remove_hook;
  g_luna.use_pc_hooks = use_pc_hooks && (bridge.insert_pc != nullptr);
  g_luna.hook_codes = hook_codes;
  g_luna.blocked_hook_codes = blocked_hook_codes;
  g_luna.blocked_hook_names = blocked_hook_names;
  g_luna.confirmed_blocked_hook_names.clear();
  g_luna.preferred_hook_codes = preferred_hook_codes;
  InterlockedExchange(&g_luna.blocked_hook_remove_requests, 0);
  InterlockedExchange(&g_luna.blocked_hook_remove_confirmations, 0);
  header->hook_diagnostics |= kDiagLunaHostReady;

  // flushDelay=200ms（一句停顿 flush 一行）、filterRepetition=true（LunaHook 侧先去重）、
  // codepage（日文 galgame 默认 932/SHIFT_JIS）、maxBufferSize/maxHistorySize 保守非零值。
  if (bridge.settings != nullptr) {
    bridge.settings(200, true, codepage, 8192, 1000, false);
  }

  // 文本线程 face 表、显式选择判定与预览 writer 的共享锁：Output/ThreadRemove 回调可在
  // LunaHook 工作线程并发，于 start() 注册回调前初始化（进程生命期内一次）。
  if (!g_lunaSelectCsInit) {
    InitializeCriticalSection(&g_lunaSelectCs);
    g_lunaSelectCsInit = true;
  }
  g_lunaTextSelector.Reset();

  // 注册回调，顺序严格对齐 texthook.py：Connect, Disconnect, ThreadCreate, ThreadRemove,
  // Output, HostInfo, HookInsert, Embed, I18NQuery, EmuGameInfo。后两项本组件不用，传空让
  // LunaHost 采用默认行为。
  bridge.start(&LunaConnect, &LunaDisconnect, &LunaThreadCreate,
               &LunaThreadRemove, &LunaOutput, &LunaHostInfo, &LunaHookInsert,
               &LunaEmbed, nullptr, nullptr);

  // 触发 attach：先建 host<->hook 管道，再判断目标是否需要注入。需要则把
  // LunaHook<arch>.dll 注入游戏（复用 CreateRemoteThread(LoadLibraryW) 纯 DLL 注入，等价
  // LunaTranslator 的 shareddllproxy dllinject；LunaHook.dll 自初始化、连回管道、自动识别引擎
  // 装台词 hook → Output 回调回传）。
  bridge.connect(pid);
  if (bridge.need_inject(pid)) {
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
    g_luna.insert_hook = nullptr;
    g_luna.remove_hook = nullptr;
    g_luna.hook_codes.clear();
    g_luna.blocked_hook_codes.clear();
    g_luna.blocked_hook_names.clear();
    g_luna.confirmed_blocked_hook_names.clear();
    g_luna.preferred_hook_codes.clear();
    InterlockedExchange(&g_luna.blocked_hook_remove_requests, 0);
    InterlockedExchange(&g_luna.blocked_hook_remove_confirmations, 0);
    g_luna.pid = 0;
  }
}

// LunaHook 运行选项（命令行传入）。
struct LunaOptions {
  bool enabled = true;    // --no-luna 关闭
  int codepage = 932;     // --luna-codepage（日文默认 SHIFT_JIS）
  bool pc_hooks = false;  // --luna-pchooks 补装通用 PC hooks
  uint32_t defer_until_running_ms = 0;
  std::vector<std::wstring> hook_codes;  // 版本专用、已验证的 H-code
  std::vector<std::wstring> blocked_hook_codes;  // SHA-256 精确匹配的危险自动 hook
  std::vector<std::wstring> blocked_hook_names;  // 异步移除完成确认用 Luna 名称
  std::vector<std::wstring> preferred_hook_codes;  // 自动制卡优先采用的干净线程
  std::wstring profile_path;  // 用户导入的 UTF-8 TSV（按 exe/module SHA-256）
};

std::string ReadUtf8File(const std::wstring& path);
hibiki_voice_hook::LunaTargetIdentity BuildTargetIdentity(
    const std::wstring& executable, DWORD pid);

void ApplyLunaProfiles(const std::wstring& executable, DWORD pid,
                       const std::wstring& user_profile,
                       LunaOptions* options) {
  if (options == nullptr || executable.empty()) return;
  const auto identity = BuildTargetIdentity(executable, pid);
  auto apply = [&](const std::string& tsv, const char* source) {
    const auto match = hibiki_voice_hook::MatchLunaHookProfiles(tsv, identity);
    if (match.codepage > 0) options->codepage = match.codepage;
    if (match.enable_pc_hooks) options->pc_hooks = true;
    if (match.defer_until_running_ms > options->defer_until_running_ms) {
      options->defer_until_running_ms = match.defer_until_running_ms;
      fprintf(stderr, "[luna] matched %s deferred guard: %u ms\n", source,
              match.defer_until_running_ms);
    }
    for (const std::wstring& code : match.hook_codes) {
      if (std::find(options->hook_codes.begin(), options->hook_codes.end(),
                    code) == options->hook_codes.end()) {
        options->hook_codes.push_back(code);
        fprintf(stderr, "[luna] matched %s SHA-256 profile: %ls\n", source,
                code.c_str());
      }
    }
    for (const std::wstring& code : match.blocked_hook_codes) {
      if (std::find(options->blocked_hook_codes.begin(),
                    options->blocked_hook_codes.end(),
                    code) == options->blocked_hook_codes.end()) {
        options->blocked_hook_codes.push_back(code);
        fprintf(stderr, "[luna] matched %s blocked hook profile: %ls\n", source,
                code.c_str());
      }
    }
    for (const std::wstring& name : match.blocked_hook_names) {
      if (std::find(options->blocked_hook_names.begin(),
                    options->blocked_hook_names.end(),
                    name) == options->blocked_hook_names.end()) {
        options->blocked_hook_names.push_back(name);
        fprintf(stderr, "[luna] matched %s blocked hook name: %ls\n", source,
                name.c_str());
      }
    }
    for (const std::wstring& code : match.preferred_hook_codes) {
      if (std::find(options->preferred_hook_codes.begin(),
                    options->preferred_hook_codes.end(),
                    code) == options->preferred_hook_codes.end()) {
        options->preferred_hook_codes.push_back(code);
        fprintf(stderr, "[luna] matched %s preferred hook profile: %ls\n",
                source, code.c_str());
      }
    }
  };
  apply(hibiki_voice_hook::BuiltInLunaHookProfiles(), "built-in");
  if (!user_profile.empty()) {
    const std::string imported = ReadUtf8File(user_profile);
    if (imported.empty()) {
      fprintf(stderr, "[luna] profile unreadable or empty: %ls\n",
              user_profile.c_str());
    } else {
      apply(imported, "user");
    }
  }
}

using PFN_NtSuspendProcess = LONG(NTAPI*)(HANDLE);
using PFN_NtResumeProcess = LONG(NTAPI*)(HANDLE);

// Fragile engine profiles need Luna installed only after their startup scripts
// settle, while no game thread can execute a hook that is about to be removed.
// Resolve the Windows process-wide suspend/resume pair dynamically so the
// guarded behavior remains opt-in and fails closed when unavailable.
bool SetTargetProcessSuspended(HANDLE target, bool suspended) {
  HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
  if (ntdll == nullptr) return false;
  if (suspended) {
    const auto fn = reinterpret_cast<PFN_NtSuspendProcess>(
        GetProcAddress(ntdll, "NtSuspendProcess"));
    return fn != nullptr && fn(target) >= 0;
  }
  const auto fn = reinterpret_cast<PFN_NtResumeProcess>(
      GetProcAddress(ntdll, "NtResumeProcess"));
  return fn != nullptr && fn(target) >= 0;
}

// 恢复一个以 CREATE_SUSPENDED 创建出来的游戏，[stage] 只用于诊断。
//
// **为什么不能只信线程句柄**：Locale Emulator 路径下进程不是 injector 自己创建的，而是
// LoaderDll 的 `LeCreateProcess` 代创建，主线程句柄来自它回填的
// `LeProcessInformation::hThread`（见 CreateJapaneseLocaleProcess），该句柄不保证可用。
// 实测样本「屋上の百合霊さん」（x86 Unity，日语 locale 路径）：injector 打印了
// `LAUNCH pid=` 与 `OK hooked`、rc==0，但游戏主线程数小时后仍是 Suspended、窗口从未
// 出现；外部对该主线程调**一次** ResumeThread 返回 1（返回值即调用前的挂起计数）→
// 计数从未被减过，窗口随即出现。也就是说那唯一一次 ResumeThread 落空了。
// 因此这里以进程级 NtResumeProcess 作**确定性回退**，不把第三方回填的句柄当作前提。
//
// **恢复必须循环到挂起计数归零**，这正是本 bug 的根因所在：ResumeThread 的返回值是调用
// 前的挂起计数，它只把计数 -1。Locale Emulator 路径下计数**不是 1 而是 2**——除了
// CREATE_SUSPENDED 本身，LoaderDll 为了在 kernel32 初始化前装入 LocaleEmulator.dll 还会
// 自己挂一次。旧实现只调一次 ResumeThread：计数 2→1，线程**仍然挂起**，而返回值不是 -1
// 所以旧代码判为成功、rc=0、照常打印 OK hooked。用户看到的就是「点了启动没反应、游戏
// 没打开」（实测样本：屋上の百合霊さん，x86 Unity + 日语 locale，两次独立复现）。
// 上界防止句柄异常时无限循环；仍未归零则退到进程级 NtResumeProcess。
bool ResumeLaunchedGame(HANDLE process, HANDLE thread, const char* stage) {
  if (thread != nullptr) {
    DWORD initial_count = 0;
    for (int attempt = 0; attempt < 8; ++attempt) {
      const DWORD previous = ResumeThread(thread);
      if (previous == static_cast<DWORD>(-1)) {
        fprintf(stderr,
                "[resume] %s ResumeThread failed: %lu; falling back to "
                "NtResumeProcess\n",
                stage, GetLastError());
        break;
      }
      if (attempt == 0) initial_count = previous;
      if (previous <= 1) {
        // 把首次计数和总次数都记下来：只报最后一次的 1 会把「原本挂了几层」这个关键
        // 事实藏掉，而它正是判断本回归是否复发的唯一依据。
        fprintf(stderr,
                "[resume] %s primary thread resumed (initial suspend count=%lu, "
                "resume calls=%d)\n",
                stage, initial_count, attempt + 1);
        return true;
      }
    }
  } else {
    // 这条分支就是本 bug 的现场：旧代码在此**静默跳过整个 resume**，随后照常打印
    // OK hooked，injector 报成功而游戏永久挂起。现在它是一条显式诊断 + 确定性回退。
    fprintf(stderr,
            "[resume] %s no primary thread handle (Locale Emulator returned "
            "none); using process-wide NtResumeProcess\n",
            stage);
  }
  if (SetTargetProcessSuspended(process, false)) {
    fprintf(stderr, "[resume] %s resumed process-wide via NtResumeProcess\n",
            stage);
    return true;
  }
  fprintf(stderr, "[resume] %s NtResumeProcess failed\n", stage);
  return false;
}

// attach 与 launch 共用的注入编排。target=目标进程句柄，pid=目标 pid（命名共享内存/事件）。
// resume_thread!=nullptr（launch 模式）时：注入完成后 ResumeThread 让挂起的游戏跑起来，再等就绪
// 事件——保证 hook 在游戏调 DirectSoundCreate/WinMain 之前就装好。hold_process 在 --hold 时决定
// 挂起终点（launch 给游戏进程句柄，挂到游戏退出；attach 给 nullptr，无限 Sleep）。
// 契约与 --pid 老路径完全一致：建共享内存(pid) + 就绪事件(pid)，注入，[Resume]，等事件，
// 打印 OK hooked ...，[hold]。全部句柄本函数负责关闭。返回进程退出码。
// [reason_out] 回报结构化失败原因；[resumed_out] 回报「挂起的游戏主线程是否已经被本函数
// 恢复」——这是**事实**，不能再像旧实现那样从返回码推断（rc==2 的两个来源都发生在
// ResumeThread 之前，却被注释当成已恢复，于是游戏被永久留在挂起态）。
//
// [created_suspended] 才是「本函数是否必须恢复游戏」的真值，[resume_thread] 只是恢复的
// **首选手段**。旧实现用 `resume_thread != nullptr` 同时表达这两件事，于是一个 nullptr
// 承载了两种互斥含义：「本策略不需要 resume」（Siglus/follow-child：进程没被挂起创建）
// 与「本该 resume 但句柄没拿到」（Locale Emulator 未回填 hThread）。后者被静默当成前者
// 跳过，游戏永久挂起而 injector 照报 OK hooked。拆成两个参数就消掉了这个二义性。
int RunInjection(HANDLE target, DWORD pid, const std::wstring& dll_path,
                 DWORD wait_ms, bool hold, HANDLE resume_thread,
                 HANDLE hold_process, const LunaOptions& luna,
                 hibiki_voice_hook::LaunchFailureReason* reason_out = nullptr,
                 bool* resumed_out = nullptr,
                 bool created_suspended = false) {
  using hibiki_voice_hook::LaunchFailureReason;
  if (reason_out != nullptr) *reason_out = LaunchFailureReason::kNone;
  if (resumed_out != nullptr) *resumed_out = false;
  bool target_wow64 = false;
  if (!BitnessMatches(target, &target_wow64)) {
    fprintf(stderr,
            "位数不匹配：目标是 %s 进程，请改用对应 arch 的注入器 "
            "(32 位游戏用 x86 injector+DLL，64 位用 x64)。\n",
            target_wow64 ? "32 位" : "64 位");
    return FailWith(reason_out, LaunchFailureReason::kBitnessMismatch, 1);
  }

  // 建共享内存（header + 环形缓冲）并清零、写契约头。injector 持有映射句柄=内存所有者；
  // hold 模式下常驻维持它存活，供 host 消费。
  const uint32_t ring_capacity = ComputeRingCapacity();
  const uint32_t loopback_capacity = ComputeLoopbackCapacity();
  // v12 布局：[SharedHeader][音频环形 ring_capacity][文本环 kTextSlotCount*kTextSlotBytes]
  //          [clip 索引 kClipCount*sizeof(VoiceClip)][loopback 环 loopback_capacity]
  //          [loopback 标记表 kLoopbackMarkerCount*sizeof(LoopbackMarker)]
  //          [线程预览区 kThreadPreviewCount*sizeof(ThreadPreviewSlot)]。各区偏移下面填进 header。
  // v13：文本区 = 道表 + 按道分块的槽区（尺寸算法与寻址同在契约头，写读两侧共用一份）。
  const uint64_t text_region_bytes = hibiki_voice_hook::TextRegionBytes(
      hibiki_voice_hook::kTextLaneCount,
      hibiki_voice_hook::kTextLaneSlotCount);
  const uint64_t clip_region_bytes =
      static_cast<uint64_t>(kClipCount) * sizeof(VoiceClip);
  const uint64_t loopback_marker_bytes =
      static_cast<uint64_t>(kLoopbackMarkerCount) * sizeof(LoopbackMarker);
  const uint64_t thread_preview_bytes =
      static_cast<uint64_t>(hibiki_voice_hook::kThreadPreviewCount) *
      sizeof(hibiki_voice_hook::ThreadPreviewSlot);
  const uint64_t total_size = sizeof(SharedHeader) + ring_capacity +
                              text_region_bytes + clip_region_bytes +
                              loopback_capacity + loopback_marker_bytes +
                              thread_preview_bytes;
  const bool legacy_hibiki_ipc =
      hibiki_voice_hook::ComponentUsesLegacyHibikiIpc(dll_path);
  const std::wstring shm = SharedMemoryName(pid, legacy_hibiki_ipc);
  SetLastError(ERROR_SUCCESS);
  HANDLE mapping = CreateFileMappingW(
      INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE,
      static_cast<DWORD>(total_size >> 32),
      static_cast<DWORD>(total_size & 0xFFFFFFFF), shm.c_str());
  const bool mapping_already_exists = GetLastError() == ERROR_ALREADY_EXISTS;
  if (mapping == nullptr) {
    Fail("CreateFileMapping failed");
    return FailWith(reason_out,
                    LaunchFailureReason::kSharedMemoryUnavailable, 1);
  }
  auto* header = static_cast<SharedHeader*>(
      MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, 0));
  if (header == nullptr) {
    CloseHandle(mapping);
    Fail("MapViewOfFile failed");
    return FailWith(reason_out,
                    LaunchFailureReason::kSharedMemoryUnavailable, 1);
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
    return FailWith(reason_out, LaunchFailureReason::kStaleSession, 2);
  }
  const bool reuse_ready = mapping_action == MappingSessionAction::kReuseReady;
  if (!reuse_ready) {
    // 仅新映射允许清零。旧映射由游戏内 DLL 持有；重连时清零会让 hooked 永久丢失。
    memset(header, 0, static_cast<size_t>(total_size));
    header->magic = kSharedMagic;
    header->version = kSharedVersion;
    header->ipc_protocol_version = kStableIpcVersion;
    header->luna_bridge_abi_version =
        hibiki_voice_hook::kLunaBridgeAbiVersion;
    header->luna_vendored_version = hibiki_voice_hook::kLunaVendoredVersion;
    header->ring_capacity = ring_capacity;
    // 文本环紧随音频环形；clip 索引紧随文本环。hook DLL 据此偏移定位两区。
    header->text_region_offset = expected_text_offset;
    header->clip_region_offset = expected_clip_offset;
    // v13 分道参数：写侧认领道、读侧定位槽都只认 header 里这两个值（冗余但让 reader 自洽）。
    header->text_lane_count = hibiki_voice_hook::kTextLaneCount;
    header->text_lane_slot_count = hibiki_voice_hook::kTextLaneSlotCount;
    // v9：loopback 环紧随 clip 索引；标记表紧随 loopback 环。
    header->loopback_ring_offset =
        static_cast<uint32_t>(header->clip_region_offset + clip_region_bytes);
    header->loopback_ring_capacity = loopback_capacity;
    header->loopback_marker_offset = static_cast<uint32_t>(
        header->loopback_ring_offset + loopback_capacity);
    header->loopback_marker_slot_count = kLoopbackMarkerCount;
    // v12：线程预览区紧随标记表。放在**布局最尾**是有意的——前面各区的偏移一个都不动，
    // 旧 host 即使只认到 v11 的字段也不会读错位（版本号仍会先把它挡掉，这只是纵深防御）。
    header->thread_preview_offset = static_cast<uint32_t>(
        header->loopback_marker_offset + loopback_marker_bytes);
    header->thread_preview_slot_count = hibiki_voice_hook::kThreadPreviewCount;
  } else {
    fprintf(stderr,
            "[session] reusing live hook mapping pid=%lu text=%u audioBytes=%llu\n",
            pid, header->text_hooked,
            static_cast<unsigned long long>(header->total_written));
  }
  const UnityExtractorRuntime unity_extractor = FindUnityExtractorRuntime();
  const std::wstring unity_data_directory = FindUnityDataDirectory(target);
  if (unity_extractor.ready) {
    header->hook_diagnostics |= kDiagUnityResourceExtractorReady;
  } else {
    fprintf(stderr,
            "[unity-audio] resource extractor runtime missing; Unity audio will use normal fallback\n");
  }
  // 就绪事件（auto-reset，初始未触发）；hook DLL 装好后 SetEvent。
  const std::wstring evt = ReadyEventName(pid, legacy_hibiki_ipc);
  HANDLE ready = CreateEventW(nullptr, FALSE, FALSE, evt.c_str());
  if (ready == nullptr) {
    UnmapViewOfFile(header);
    CloseHandle(mapping);
    Fail("CreateEvent failed");
    return FailWith(reason_out,
                    LaunchFailureReason::kSharedMemoryUnavailable, 1);
  }

  if (!reuse_ready && !InjectDll(target, dll_path)) {
    CloseHandle(ready);
    UnmapViewOfFile(header);
    CloseHandle(mapping);
    Fail("injection failed");
    return FailWith(reason_out, LaunchFailureReason::kInjectionFailed, 1);
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
      return FailWith(reason_out, LaunchFailureReason::kReadyTimeout, 2);
    }
  }

  // CREATE_SUSPENDED launch 必须等游戏内 DLL 完成首次 XAudio2/DirectSound 导出 hook，
  // 再恢复主线程。否则 Unity 可能先创建全部 source voice，之后晚 attach 只能拿到混音。
  bool luna_initialized = false;
  auto init_guarded_luna = [&]() -> bool {
    if (luna.blocked_hook_names.size() != luna.blocked_hook_codes.size()) {
      fprintf(stderr,
              "[luna] blocked-hook profile is missing removal confirmation "
              "names\n");
      return false;
    }
    luna_initialized =
        InitLunaHook(header, target, pid, luna.codepage, luna.pc_hooks,
                     luna.hook_codes, luna.blocked_hook_codes,
                     luna.blocked_hook_names, luna.preferred_hook_codes);
    if (!luna_initialized) return false;
    const LONG expected_removed =
        static_cast<LONG>(luna.blocked_hook_codes.size());
    const ULONGLONG luna_deadline = GetTickCount64() + wait_ms;
    while (InterlockedCompareExchange(
               &g_luna.blocked_hook_remove_confirmations, 0, 0) <
               expected_removed &&
           GetTickCount64() < luna_deadline) {
      Sleep(1);
    }
    const LONG removed = InterlockedCompareExchange(
        &g_luna.blocked_hook_remove_confirmations, 0, 0);
    if (removed < expected_removed) {
      fprintf(stderr,
              "[luna] blocked-hook guard timed out "
              "(removed=%ld expected=%ld)\n",
              removed, expected_removed);
      return false;
    }
    fprintf(stderr,
            "[luna] blocked-hook guard ready "
            "(removed=%ld expected=%ld)\n",
            removed, expected_removed);
    return true;
  };
  if (created_suspended) {
    // 挂起窗口只用总预算的一部分：与宿主超时同时到期会让 injector 在被 kill 时恰好还没
    // resume，游戏永久挂起（见 SuspendedStartupWaitBudgetMs 的说明）。
    const unsigned long startup_budget_ms =
        hibiki_voice_hook::SuspendedStartupWaitBudgetMs(wait_ms);
    const ULONGLONG deadline = GetTickCount64() + startup_budget_ms;
    while ((header->hook_diagnostics & kDiagStartupAudioHooksReady) == 0 &&
           GetTickCount64() < deadline) {
      Sleep(1);
    }
    if ((header->hook_diagnostics & kDiagStartupAudioHooksReady) == 0) {
      fprintf(stderr,
              "startup audio hook readiness timed out after %lu ms (total "
              "wait budget %lu ms); resuming game with text/late-hook "
              "fallback\n",
              startup_budget_ms, wait_ms);
    }

    // 精确 profile 标记了危险自动 hook 时，必须在游戏线程挂起期间启动 Luna，
    // 并确认这些 hook 已移除后才允许游戏继续执行。defer profile 会先让脆弱的
    // 启动脚本稳定，再短暂挂起整个目标进程完成相同的安全安装。
    const bool guarded_luna =
        hold && luna.enabled && !luna.blocked_hook_codes.empty();
    const bool defer_guard =
        guarded_luna && luna.defer_until_running_ms > 0;
    if (guarded_luna && !defer_guard) {
      if (!init_guarded_luna()) {
        fprintf(stderr,
                "[luna] failed to initialize early blocked-hook guard; "
                "refusing to resume suspended game\n");
        ShutdownLunaHook();
        CloseHandle(ready);
        UnmapViewOfFile(header);
        CloseHandle(mapping);
        return FailWith(reason_out, LaunchFailureReason::kGuardedHookFailed, 1);
      }
    }

    // 只有游戏内 DLL 完成首轮音频导出 hook 后才允许游戏主线程继续。
    // Unity 会在启动早期创建 XAudio2 engine/source voice，提前恢复会永久错过这些对象。
    if (!ResumeLaunchedGame(target, resume_thread, "post-injection")) {
      CloseHandle(ready);
      UnmapViewOfFile(header);
      CloseHandle(mapping);
      return FailWith(reason_out, LaunchFailureReason::kResumeFailed, 1);
    }
    // 恢复成功是**事实**，立即回报：此后任何失败都不得再把游戏当成挂起态处置。
    if (resumed_out != nullptr) *resumed_out = true;

    if (defer_guard) {
      fprintf(stderr,
              "[luna] deferring guarded hook installation for %u ms\n",
              luna.defer_until_running_ms);
      const ULONGLONG defer_deadline =
          GetTickCount64() + luna.defer_until_running_ms;
      while (GetTickCount64() < defer_deadline) {
        if (hold_process != nullptr &&
            WaitForSingleObject(hold_process, 0) == WAIT_OBJECT_0) {
          luna_initialized = true;
          break;
        }
        Sleep(50);
      }
      if (!luna_initialized) {
        if (!SetTargetProcessSuspended(target, true)) {
          fprintf(stderr,
                  "[luna] failed to suspend running target for guarded "
                  "installation\n");
          CloseHandle(ready);
          UnmapViewOfFile(header);
          CloseHandle(mapping);
          return FailWith(reason_out,
                          LaunchFailureReason::kGuardedHookFailed, 1);
        }
        fprintf(stderr,
                "[luna] target suspended for guarded hook installation\n");
        const bool guarded_ready = init_guarded_luna();
        const bool resumed = SetTargetProcessSuspended(target, false);
        if (!resumed) {
          fprintf(stderr,
                  "[luna] failed to resume target after guarded installation\n");
        }
        if (!guarded_ready || !resumed) {
          ShutdownLunaHook();
          CloseHandle(ready);
          UnmapViewOfFile(header);
          CloseHandle(mapping);
          // 主线程此前已恢复（resumed_out=true），处置策略据此不会把一个正在运行的
          // 游戏误当成挂起僵尸去「恢复」或结束。
          return FailWith(reason_out,
                          LaunchFailureReason::kGuardedHookFailed, 1);
        }
        fprintf(stderr,
                "[luna] target resumed after guarded hook installation\n");
      }
    }
  }

  printf("OK hooked pid=%lu hooked=%u ring=%u sr=%u ch=%u bits=%u float=%u\n",
         pid, header->hooked, header->ring_capacity, header->sample_rate,
         header->channels, header->bits_per_sample, header->is_float);
  fflush(stdout);

  // host 模式（--hold）才接入 LunaHook 全引擎文本 hook：写同一文本环，与游戏内 GDI hook
  // 并存（原子占号防撞槽）。probe 模式确认即退，LunaHook 没有捕获窗口，故不接。
  if (hold && luna.enabled && !luna_initialized) {
    InitLunaHook(header, target, pid, luna.codepage, luna.pc_hooks,
                 luna.hook_codes, luna.blocked_hook_codes,
                 luna.blocked_hook_names,
                 luna.preferred_hook_codes);
  }

  if (hold) {
    // host 模式：常驻维持共享内存存活，供 Hibiki 消费（C.2 起真正读 PCM）。
    // 同时消费 Unity Streaming AudioClip 资源事件；重解析/解码在 injector 子进程完成，
    // 游戏内 hook 回调始终只写固定大小共享内存事件。
    uint64_t next_unity_event = 0;
    if (hold_process != nullptr) {
      while (WaitForSingleObject(hold_process, 50) == WAIT_TIMEOUT) {
        ProcessUnityVoiceEvents(header, unity_extractor,
                                unity_data_directory, &next_unity_event);
      }
      ProcessUnityVoiceEvents(header, unity_extractor,
                              unity_data_directory, &next_unity_event);
    } else {
      for (;;) {
        ProcessUnityVoiceEvents(header, unity_extractor,
                                unity_data_directory, &next_unity_event);
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

struct LeProcessInformation : PROCESS_INFORMATION {
  PVOID first_call_ldr_load_dll = nullptr;
};

using LeCreateProcessFunction = LONG(WINAPI*)(
    hibiki_voice_hook::LeEnvironmentBlock*, PCWSTR, PWSTR, PCWSTR, ULONG,
    LPSTARTUPINFOW, LeProcessInformation*, LPSECURITY_ATTRIBUTES,
    LPSECURITY_ATTRIBUTES, PVOID, HANDLE);

// Locale Emulator 的 LoaderDll 负责在 kernel32 初始化前装入 LocaleEmulator.dll。这里始终
// 把调用结果保持在 CREATE_SUSPENDED；普通引擎交回 RunInjection 完成 Hibiki 早注入后恢复，
// 需要发现窗口/子进程的策略则由 RunLaunch 先恢复再等待，避免挂起启动器与发现逻辑死锁。
bool CreateJapaneseLocaleProcess(
    const std::wstring& executable,
    std::vector<wchar_t>* command_line, const std::wstring& current_directory,
    DWORD creation_flags, STARTUPINFOW* startup_info,
    PROCESS_INFORMATION* process_information) {
  if (command_line == nullptr || startup_info == nullptr ||
      process_information == nullptr) {
    return false;
  }
  const std::wstring runtime_dir = InjectorDir();
  const std::wstring loader_path = JoinPath(runtime_dir, L"LoaderDll.dll");
  const std::wstring emulator_path =
      JoinPath(runtime_dir, L"LocaleEmulator.dll");
  if (!RegularFileExists(loader_path) || !RegularFileExists(emulator_path)) {
    fprintf(stderr,
            "[locale] runtime incomplete; expected LoaderDll.dll and "
            "LocaleEmulator.dll in %ls\n",
            runtime_dir.c_str());
    return false;
  }

  HMODULE loader = LoadLibraryExW(
      loader_path.c_str(), nullptr,
      LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
  if (loader == nullptr) {
    fprintf(stderr, "[locale] LoadLibraryExW(%ls) failed: %lu\n",
            loader_path.c_str(), GetLastError());
    return false;
  }
  const auto create_process = reinterpret_cast<LeCreateProcessFunction>(
      GetProcAddress(loader, "LeCreateProcess"));
  if (create_process == nullptr) {
    fprintf(stderr, "[locale] LoaderDll!LeCreateProcess missing: %lu\n",
            GetLastError());
    FreeLibrary(loader);
    return false;
  }

  auto environment = hibiki_voice_hook::BuildJapaneseLocaleEnvironment();
  LeProcessInformation le_process = {};
  const LONG status = create_process(
      &environment, executable.c_str(), command_line->data(),
      current_directory.empty() ? nullptr : current_directory.c_str(),
      creation_flags | CREATE_SUSPENDED, startup_info, &le_process, nullptr,
      nullptr, nullptr, nullptr);
  if (status == 0) {
    process_information->hProcess = le_process.hProcess;
    process_information->hThread = le_process.hThread;
    process_information->dwProcessId = le_process.dwProcessId;
    process_information->dwThreadId = le_process.dwThreadId;
    fprintf(stderr,
            "[locale] launched with Japanese CP932 via Locale Emulator "
            "pid=%lu\n",
            le_process.dwProcessId);
  } else {
    fprintf(stderr,
            "[locale] LeCreateProcess failed: NTSTATUS=0x%08lx; falling back "
            "to normal launch\n",
            static_cast<unsigned long>(status));
  }
  FreeLibrary(loader);
  return status == 0;
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

bool LooksLikeRenpyRuntime(const std::wstring& exe) {
  const std::wstring dir = ExecutableDirectory(exe);
  if (dir.empty()) return false;
  return DirectoryExists(JoinPath(dir, L"renpy")) ||
         DirectoryExists(JoinPath(JoinPath(dir, L"lib"), L"windows-i686")) ||
         DirectoryExists(
             JoinPath(JoinPath(dir, L"lib"), L"windows-x86_64")) ||
         DirectoryExists(JoinPath(JoinPath(dir, L"lib"), L"py3-windows-x86_64")) ||
         FileExists(JoinPath(dir, L"python.exe")) ||
         FileExists(JoinPath(dir, L"pythonw.exe"));
}

void InspectFfmpegModules(DWORD pid,
                          hibiki_voice_hook::ChildProcessCandidate* candidate) {
  HANDLE snapshot = CreateToolhelp32Snapshot(
      TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid);
  if (snapshot == INVALID_HANDLE_VALUE) return;
  MODULEENTRY32W module = {0};
  module.dwSize = sizeof(module);
  if (Module32FirstW(snapshot, &module)) {
    do {
      const auto parsed =
          hibiki_voice_hook::ParseFfmpegModuleName(module.szModule);
      candidate->has_avcodec =
          candidate->has_avcodec ||
          parsed.kind == hibiki_voice_hook::FfmpegModuleKind::kAvcodec;
      candidate->has_avformat =
          candidate->has_avformat ||
          parsed.kind == hibiki_voice_hook::FfmpegModuleKind::kAvformat;
      if (hibiki_voice_hook::IsMonolithicFfmpegModuleName(module.szModule)) {
        candidate->has_avcodec = true;
        candidate->has_avformat = true;
      }
    } while (Module32NextW(snapshot, &module));
  }
  CloseHandle(snapshot);
}

DWORD FindGameChildProcess(DWORD root_pid) {
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return 0;
  struct OwnedCandidate {
    hibiki_voice_hook::ChildProcessCandidate value;
    std::wstring name;
  };
  std::vector<OwnedCandidate> owned;
  PROCESSENTRY32W process = {0};
  process.dwSize = sizeof(process);
  if (Process32FirstW(snapshot, &process)) {
    do {
      if (process.th32ProcessID != root_pid && process.th32ProcessID != 0) {
        OwnedCandidate candidate;
        candidate.value.pid = process.th32ProcessID;
        candidate.value.parent_pid = process.th32ParentProcessID;
        candidate.name = process.szExeFile;
        owned.push_back(std::move(candidate));
      }
    } while (Process32NextW(snapshot, &process));
  }
  CloseHandle(snapshot);
  std::vector<hibiki_voice_hook::ChildProcessCandidate> candidates;
  candidates.reserve(owned.size());
  for (OwnedCandidate& item : owned) {
    item.value.executable_name = item.name.c_str();
    candidates.push_back(item.value);
  }
  // First select descendants without module inspection, then enrich every descendant. This keeps
  // Toolhelp module snapshots scoped to the launcher's process tree.
  for (size_t i = 0; i < candidates.size(); ++i) {
    if (hibiki_voice_hook::DescendantDepth(root_pid, i, candidates) > 0) {
      InspectFfmpegModules(candidates[i].pid, &candidates[i]);
    }
  }
  return hibiki_voice_hook::SelectGameChildProcess(root_pid, candidates);
}

DWORD WaitForGameChildProcess(DWORD root_pid, DWORD wait_ms) {
  const uint64_t started = GetTickCount64();
  const uint64_t deadline = GetTickCount64() + wait_ms;
  DWORD last_candidate = 0;
  int stable_observations = 0;
  while (GetTickCount64() < deadline) {
    const DWORD candidate = FindGameChildProcess(root_pid);
    if (candidate != 0 && candidate == last_candidate) {
      ++stable_observations;
      if (stable_observations >= 2) return candidate;
    } else {
      last_candidate = candidate;
      stable_observations = candidate == 0 ? 0 : 1;
    }
    if (candidate == 0 && GetTickCount64() - started >= 1000) {
      hibiki_voice_hook::ChildProcessCandidate launcher;
      launcher.pid = root_pid;
      InspectFfmpegModules(root_pid, &launcher);
      if (launcher.has_avcodec && launcher.has_avformat) return 0;
    }
    Sleep(100);
  }
  return last_candidate;
}

std::string Sha256File(const std::wstring& path) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ,
                            FILE_SHARE_READ | FILE_SHARE_WRITE |
                                FILE_SHARE_DELETE,
                            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                            nullptr);
  if (file == INVALID_HANDLE_VALUE) return {};
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  DWORD object_size = 0;
  DWORD result_size = 0;
  std::vector<uint8_t> object;
  std::array<uint8_t, 32> digest{};
  bool ok = BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM,
                                         nullptr, 0) == 0 &&
            BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH,
                              reinterpret_cast<PUCHAR>(&object_size),
                              sizeof(object_size), &result_size, 0) == 0;
  if (ok) {
    object.resize(object_size);
    ok = BCryptCreateHash(algorithm, &hash, object.data(), object_size, nullptr,
                          0, 0) == 0;
  }
  std::array<uint8_t, 64 * 1024> buffer{};
  while (ok) {
    DWORD read = 0;
    if (!ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()),
                  &read, nullptr)) {
      ok = false;
      break;
    }
    if (read == 0) break;
    ok = BCryptHashData(hash, buffer.data(), read, 0) == 0;
  }
  if (ok) {
    ok = BCryptFinishHash(hash, digest.data(),
                          static_cast<ULONG>(digest.size()), 0) == 0;
  }
  if (hash != nullptr) BCryptDestroyHash(hash);
  if (algorithm != nullptr) BCryptCloseAlgorithmProvider(algorithm, 0);
  CloseHandle(file);
  if (!ok) return {};
  std::ostringstream out;
  out << std::hex << std::setfill('0');
  for (uint8_t byte : digest) out << std::setw(2) << static_cast<int>(byte);
  return out.str();
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int size = WideCharToMultiByte(CP_UTF8, 0, value.c_str(),
                                       static_cast<int>(value.size()), nullptr,
                                       0, nullptr, nullptr);
  std::string result(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.c_str(),
                      static_cast<int>(value.size()), result.data(), size,
                      nullptr, nullptr);
  return result;
}

std::string ReadUtf8File(const std::wstring& path) {
  std::ifstream input(path, std::ios::binary);
  return input ? std::string(std::istreambuf_iterator<char>(input),
                             std::istreambuf_iterator<char>())
               : std::string();
}

hibiki_voice_hook::LunaTargetIdentity BuildTargetIdentity(
    const std::wstring& executable, DWORD pid) {
  hibiki_voice_hook::LunaTargetIdentity identity;
  identity.executable_sha256 = Sha256File(executable);
  HANDLE snapshot = CreateToolhelp32Snapshot(
      TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid);
  if (snapshot == INVALID_HANDLE_VALUE) return identity;
  MODULEENTRY32W module = {0};
  module.dwSize = sizeof(module);
  if (Module32FirstW(snapshot, &module)) {
    do {
      std::string name = hibiki_voice_hook::LowerAscii(WideToUtf8(module.szModule));
      if (!name.empty() && identity.module_sha256.find(name) ==
                               identity.module_sha256.end()) {
        identity.module_sha256.emplace(name, Sha256File(module.szExePath));
      }
    } while (Module32NextW(snapshot, &module));
  }
  CloseHandle(snapshot);
  return identity;
}

void ApplyLunaProfiles(const std::wstring& executable, DWORD pid,
                       const std::wstring& user_profile,
                       struct LunaOptions* options);

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

// 延迟附着必须等目标进入游戏消息循环；需要时还要等 profile 指定的运行库已加载，确保
// 注入不会再次进入已证实会崩溃的插件启动边界。只看本次子进程，不靠固定长 Sleep 猜机器速度。
bool ProcessHasModule(DWORD pid, const wchar_t* expected_module) {
  if (expected_module == nullptr || expected_module[0] == L'\0') return true;
  HANDLE snapshot = CreateToolhelp32Snapshot(
      TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid);
  if (snapshot == INVALID_HANDLE_VALUE) return false;
  bool found = false;
  MODULEENTRY32W module = {0};
  module.dwSize = sizeof(module);
  if (Module32FirstW(snapshot, &module)) {
    do {
      if (_wcsicmp(module.szModule, expected_module) == 0) {
        found = true;
        break;
      }
    } while (Module32NextW(snapshot, &module));
  }
  CloseHandle(snapshot);
  return found;
}

bool WaitForReadyGameWindow(HANDLE process, DWORD pid, DWORD timeout_ms,
                            const wchar_t* readiness_module = nullptr) {
  const uint64_t deadline = GetTickCount64() + timeout_ms;
  while (GetTickCount64() < deadline) {
    if (WaitForSingleObject(process, 0) == WAIT_OBJECT_0) return false;
    ReadyWindowSearch search;
    search.pid = pid;
    EnumWindows(&FindReadyGameWindow, reinterpret_cast<LPARAM>(&search));
    if (search.found && ProcessHasModule(pid, readiness_module)) {
      Sleep(200);  // 让窗口/模块初始化尾部退出启动调用栈，再装 inline hooks。
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
  if (!GetFileSizeEx(file, &size)) {
    CloseHandle(file);
    return false;
  }
  LONGLONG file_size = 0;
  static_assert(sizeof(file_size) == sizeof(size));
  std::memcpy(&file_size, &size, sizeof(file_size));
  if (file_size <= 0 || file_size > 2 * 1024 * 1024) {
    CloseHandle(file);
    return false;
  }
  std::vector<char> bytes(static_cast<size_t>(file_size));
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

constexpr DWORD kInjectionProcessRights =
    PROCESS_CREATE_THREAD | PROCESS_VM_OPERATION | PROCESS_VM_WRITE |
    PROCESS_VM_READ | PROCESS_QUERY_INFORMATION | SYNCHRONIZE;

// Steam 客户端可能已经启动了目标，也可能在处理 steam://run 后异步创建目标。
// 只按完整镜像路径匹配，避免同名启动器/其他游戏被误注入。返回的句柄由调用方关闭。
HANDLE FindProcessByImagePath(const std::wstring& expected_exe,
                              DWORD* found_pid) {
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return nullptr;
  PROCESSENTRY32W entry = {0};
  entry.dwSize = sizeof(entry);
  HANDLE found = nullptr;
  if (Process32FirstW(snapshot, &entry)) {
    do {
      HANDLE process = OpenProcess(kInjectionProcessRights, FALSE,
                                   entry.th32ProcessID);
      if (process == nullptr) continue;
      const std::wstring image = ProcessImagePath(process);
      if (!image.empty() && _wcsicmp(image.c_str(), expected_exe.c_str()) == 0) {
        found = process;
        if (found_pid != nullptr) *found_pid = entry.th32ProcessID;
        break;
      }
      CloseHandle(process);
    } while (Process32NextW(snapshot, &entry));
  }
  CloseHandle(snapshot);
  return found;
}

HANDLE WaitForSteamGameProcess(const std::wstring& expected_exe,
                               DWORD timeout_ms, DWORD* found_pid) {
  const uint64_t deadline = GetTickCount64() + timeout_ms;
  do {
    HANDLE process = FindProcessByImagePath(expected_exe, found_pid);
    if (process != nullptr) return process;
    Sleep(15);
  } while (GetTickCount64() < deadline);
  return nullptr;
}

int RunSteamLaunch(const std::wstring& exe, const std::wstring& app_id,
                   const std::wstring& dll_path, DWORD wait_ms, bool hold,
                   LunaOptions luna) {
  std::vector<wchar_t> absolute_buffer(32768, L'\0');
  const DWORD absolute_size = GetFullPathNameW(
      exe.c_str(), static_cast<DWORD>(absolute_buffer.size()),
      absolute_buffer.data(), nullptr);
  const std::wstring expected_exe =
      absolute_size > 0 && absolute_size < absolute_buffer.size()
          ? std::wstring(absolute_buffer.data(), absolute_size)
          : exe;
  DWORD pid = 0;
  HANDLE target = FindProcessByImagePath(expected_exe, &pid);
  if (target != nullptr) {
    fprintf(stderr,
            "[steam] target already running; attaching without relaunch "
            "pid=%lu image=%ls\n",
            pid, expected_exe.c_str());
  } else {
    const std::wstring uri = hibiki_voice_hook::BuildSteamRunUri(app_id);
    const HINSTANCE launched = ShellExecuteW(
        nullptr, L"open", uri.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
    if (reinterpret_cast<INT_PTR>(launched) <= 32) {
      fprintf(stderr, "ShellExecuteW(%ls) failed: %lld\n", uri.c_str(),
              static_cast<long long>(reinterpret_cast<INT_PTR>(launched)));
      return 1;
    }
    fprintf(stderr, "[steam] requested AppID=%ls via %ls\n", app_id.c_str(),
            uri.c_str());
    target = WaitForSteamGameProcess(expected_exe, 45000, &pid);
    if (target == nullptr) {
      fprintf(stderr,
              "Steam 已接受启动请求，但 45 秒内未发现目标进程：%ls\n",
              expected_exe.c_str());
      ReportFailureReason(hibiki_voice_hook::LaunchFailureReason::kSteamTimeout,
                          1);
      return 1;
    }
    fprintf(stderr, "[steam] discovered launched game pid=%lu image=%ls\n", pid,
            expected_exe.c_str());
  }

  ApplyLunaProfiles(expected_exe, pid, luna.profile_path, &luna);
  // Steam 路径的游戏由客户端启动、始终处于运行态，没有可恢复的挂起主线程；但失败原因
  // 同样必须回报，否则 host 只能看到一个没有原因的非零退出。
  hibiki_voice_hook::LaunchFailureReason reason =
      hibiki_voice_hook::LaunchFailureReason::kNone;
  const int rc = RunInjection(target, pid, dll_path, wait_ms, hold, nullptr,
                              target, luna, &reason);
  CloseHandle(target);
  if (rc != 0) ReportFailureReason(reason, rc);
  return rc;
}

// launch 模式：一般 CREATE_SUSPENDED 早注入；已验证不兼容早注入的 profile 改为正常启动后附着。
// 命令行含 exe 本身（CreateProcessW 约定）；workdir 缺省=exe 所在目录。
int RunLaunch(const std::wstring& exe, const std::wstring& workdir_in,
              const std::vector<std::wstring>& extra_args,
              const std::wstring& dll_path, DWORD wait_ms, bool hold,
              bool follow_child_processes, bool japanese_locale,
              bool force_direct_launch, const LunaOptions& luna) {
  if (GetFileAttributesW(exe.c_str()) == INVALID_FILE_ATTRIBUTES) {
    Fail("目标 exe 不存在（--launch <exe路径>）");
    ReportFailureReason(hibiki_voice_hook::LaunchFailureReason::kGameExeMissing,
                        1);
    return 1;
  }
  LunaOptions effective_luna = luna;
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

  // 构造命令行：首 token 必须是 exe 自身（CreateProcessW 约定），用户参数按 Windows
  // 反解规则逐个转义 —— 直接空格拼接会让含空格/引号的参数在游戏侧被拆成多个 argv。
  // CreateProcessW 要求缓冲可写。
  const std::wstring cmdline =
      hibiki_voice_hook::BuildLaunchCommandLine(exe, extra_args);
  const auto make_command_buffer = [&cmdline]() {
    std::vector<wchar_t> buffer(cmdline.begin(), cmdline.end());
    buffer.push_back(L'\0');
    return buffer;
  };
  std::vector<wchar_t> cmd_buf = make_command_buffer();

  STARTUPINFOW si = {0};
  si.cb = sizeof(si);
  PROCESS_INFORMATION pi = {0};
  const bool delayed_siglus = IsSiglusGame(exe);
  const auto* delayed_kirikiri =
      hibiki_voice_hook::FindKirikiriDelayedAttachProfile(Sha256File(exe));
  const bool delayed_attach = delayed_siglus || delayed_kirikiri != nullptr;
  if (delayed_kirikiri != nullptr) {
    fprintf(stderr, "[launch] delayed-attach profile=%s\n",
            delayed_kirikiri->id);
  }
  const bool follow_children =
      follow_child_processes || LooksLikeRenpyRuntime(exe);
  // SteamAPI_RestartAppIfNecessary 要求游戏由 Steam 客户端启动。直接 CreateProcess
  // 即使临时设置 AppID 环境变量也可能触发客户端二次拉起，最终出现重复实例且 hook 留在
  // 已退出的首进程。Steam 游戏改走客户端协议，并自动按完整 exe 路径发现/注入真实进程。
  const std::wstring steam_app_id = DiscoverSteamAppId(exe);
  if (!force_direct_launch &&
      hibiki_voice_hook::ChooseSteamLaunchStrategy(steam_app_id) ==
      hibiki_voice_hook::SteamLaunchStrategy::kSteamClient) {
    if (!extra_args.empty()) {
      fprintf(stderr,
              "[steam] warning: custom --arg values are not forwarded by the "
              "steam:// launch path\n");
    }
    if (japanese_locale) {
      fprintf(stderr,
              "[locale] Steam protocol launch cannot preserve the Locale "
              "Emulator create-suspended boundary; continuing without locale "
              "override\n");
    }
    return RunSteamLaunch(exe, steam_app_id, dll_path, wait_ms, hold,
                          effective_luna);
  }
  const DWORD creation_flags =
      (delayed_attach || follow_children) ? 0 : CREATE_SUSPENDED;
  wchar_t previous_steam_app_id[64] = {0};
  wchar_t previous_steam_game_id[64] = {0};
  const DWORD previous_app_id_chars = GetEnvironmentVariableW(
      L"SteamAppId", previous_steam_app_id,
      static_cast<DWORD>(std::size(previous_steam_app_id)));
  const DWORD previous_game_id_chars = GetEnvironmentVariableW(
      L"SteamGameId", previous_steam_game_id,
      static_cast<DWORD>(std::size(previous_steam_game_id)));
  if (force_direct_launch && !steam_app_id.empty()) {
    SetEnvironmentVariableW(L"SteamAppId", steam_app_id.c_str());
    SetEnvironmentVariableW(L"SteamGameId", steam_app_id.c_str());
    fprintf(stderr,
            "[steam] forcing CREATE_SUSPENDED with inherited AppID=%ls\n",
            steam_app_id.c_str());
  }
  BOOL created = FALSE;
  bool locale_launched = false;
  if (japanese_locale) {
    created = CreateJapaneseLocaleProcess(
                  exe, &cmd_buf, workdir, creation_flags, &si, &pi)
                  ? TRUE
                  : FALSE;
    locale_launched = created == TRUE;
  }
  if (!created) {
    // LoaderDll may rewrite its mutable command line. Rebuild before the
    // Never-break fallback to CreateProcessW.
    cmd_buf = make_command_buffer();
    created = CreateProcessW(
        exe.c_str(), cmd_buf.data(), nullptr, nullptr, FALSE, creation_flags,
        nullptr, workdir.empty() ? nullptr : workdir.c_str(), &si, &pi);
  }
  if (force_direct_launch && !steam_app_id.empty()) {
    SetEnvironmentVariableW(
        L"SteamAppId",
        previous_app_id_chars > 0 ? previous_steam_app_id : nullptr);
    SetEnvironmentVariableW(
        L"SteamGameId",
        previous_game_id_chars > 0 ? previous_steam_game_id : nullptr);
  }
  if (!created) {
    const DWORD create_error = GetLastError();
    fprintf(stderr, "CreateProcessW failed: %lu\n", create_error);
    // 740 = ERROR_ELEVATION_REQUIRED：游戏 manifest 要求管理员，非提权 injector 拉不起来。
    // host 据此提示「以管理员身份启动 Hibiki」，而不是笼统的启动失败。
    if (create_error == ERROR_ELEVATION_REQUIRED) {
      fprintf(stderr, "ERR reason=elevationRequired exit=1\n");
    } else {
      ReportFailureReason(
          hibiki_voice_hook::LaunchFailureReason::kCreateProcessFailed, 1);
    }
    return 1;
  }

  // 游戏进程**已经存在**这件事必须先于注入结果回报：注入之后再失败时，host 才知道
  // 「游戏其实在跑」，可以改走附着重试，而不是把一个有窗口的游戏报成「启动失败」。
  printf("LAUNCH pid=%lu arch=%s\n", pi.dwProcessId,
         sizeof(void*) == 8 ? "x64" : "x86");
  fflush(stdout);

  // 进程当前是否处于挂起态，是一个**事实**，只有一个来源：普通路径看 creation_flags；
  // 而 locale 路径下 LoaderDll 无论调用方传什么都会叠加 CREATE_SUSPENDED
  // （CreateJapaneseLocaleProcess 里的 `creation_flags | CREATE_SUSPENDED`），所以只要
  // 走了 locale 就一定是挂起态——旧代码算 created_suspended 时漏了这一半。
  const bool launched_suspended = hibiki_voice_hook::LaunchedProcessIsSuspended(
      (creation_flags & CREATE_SUSPENDED) != 0, locale_launched);
  bool resumed_before_discovery = false;

  const auto locale_resume_policy =
      hibiki_voice_hook::SelectLocaleThreadResumePolicy(
          locale_launched, delayed_attach, follow_children);
  if (locale_resume_policy ==
      hibiki_voice_hook::LocaleThreadResumePolicy::kBeforeProcessDiscovery) {
    if (!ResumeLaunchedGame(pi.hProcess, pi.hThread, "pre-discovery")) {
      fprintf(stderr,
              "[locale] failed to resume the game before process discovery\n");
      ReportFailureReason(hibiki_voice_hook::LaunchFailureReason::kResumeFailed,
                          1);
      TerminateProcess(pi.hProcess, 1);
      CloseHandle(pi.hThread);
      CloseHandle(pi.hProcess);
      return 1;
    }
    resumed_before_discovery = true;
  }

  const wchar_t* readiness_module =
      delayed_kirikiri == nullptr ? nullptr : delayed_kirikiri->readiness_module;
  if (delayed_attach &&
      !WaitForReadyGameWindow(pi.hProcess, pi.dwProcessId, 20000,
                              readiness_module)) {
    fprintf(stderr, "延迟附着等待游戏窗口/运行库就绪超时\n");
    TerminateProcess(pi.hProcess, 1);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return 1;
  }

  HANDLE target_process = pi.hProcess;
  DWORD target_pid = pi.dwProcessId;
  HANDLE child_process = nullptr;
  std::wstring target_exe = exe;
  if (follow_children) {
    const DWORD child_wait_ms =
        wait_ms > static_cast<DWORD>(15000) ? wait_ms : static_cast<DWORD>(15000);
    const DWORD child_pid =
        WaitForGameChildProcess(pi.dwProcessId, child_wait_ms);
    if (child_pid != 0) {
      child_process = OpenProcess(
          PROCESS_CREATE_THREAD | PROCESS_VM_OPERATION | PROCESS_VM_WRITE |
              PROCESS_VM_READ | PROCESS_QUERY_INFORMATION | SYNCHRONIZE,
          FALSE, child_pid);
      if (child_process != nullptr) {
        target_process = child_process;
        target_pid = child_pid;
        target_exe = ProcessImagePath(child_process);
        fprintf(stderr, "[process] following child pid=%lu image=%ls\n",
                child_pid, target_exe.c_str());
        // 真正承载游戏的是子进程：更新回报，host 的附着重试必须瞄准它而不是启动器。
        printf("LAUNCH pid=%lu arch=%s\n", child_pid,
               sizeof(void*) == 8 ? "x64" : "x86");
        fflush(stdout);
      }
    }
    if (target_process == pi.hProcess) {
      fprintf(stderr,
              "[process] no stable game child found; attaching launcher pid=%lu\n",
              pi.dwProcessId);
    }
  }

  ApplyLunaProfiles(target_exe, target_pid, effective_luna.profile_path,
                    &effective_luna);

  // 复用 attach 同一套编排。resume 的**意图**由 must_resume_after_injection 表达（进程被
  // 挂起创建且还没被 pre-discovery 恢复），句柄只是首选手段——句柄拿不到时
  // ResumeLaunchedGame 会退到进程级 NtResumeProcess，绝不再静默跳过。
  // hold_process 让 --hold 挂到游戏退出。
  const bool must_resume_after_injection =
      hibiki_voice_hook::MustResumeAfterInjection(launched_suspended,
                                                 resumed_before_discovery);
  hibiki_voice_hook::LaunchFailureReason reason =
      hibiki_voice_hook::LaunchFailureReason::kNone;
  bool resumed = false;
  const int rc = RunInjection(target_process, target_pid, dll_path, wait_ms,
                              hold, pi.hThread, target_process, effective_luna,
                              &reason, &resumed, must_resume_after_injection);

  // 失败后的进程处置以**事实**为准（是否 CREATE_SUSPENDED、是否已恢复），不再按返回码
  // 猜测。旧实现：rc==1 一律 TerminateProcess（杀掉用户明明要玩的游戏）；rc==2 依据
  // 「超时但已 Resume」的注释放着不管——而 rc==2 的两个来源（就绪事件超时、旧映射不可
  // 复用）都发生在 ResumeThread 之前，游戏于是被永久留在挂起态：进程在、窗口永不出现，
  // 用户看到的就是「启动失败」。现在任何失败都至少让游戏以无 hook 方式跑起来。
  // created_suspended 与上面 must_resume_after_injection 同源（launched_suspended），
  // 不再自己重算一套口径——旧实现这里漏了 locale 路径，且 pre-discovery 已恢复的情形
  // 也要算作「已恢复」。
  const bool created_suspended = launched_suspended;
  const bool already_resumed = resumed || resumed_before_discovery;
  if (rc != 0) {
    hibiki_voice_hook::LaunchedProcessDisposition disposition =
        hibiki_voice_hook::DecideLaunchedProcessDisposition(created_suspended,
                                                            already_resumed,
                                                            reason);
    if (disposition ==
        hibiki_voice_hook::LaunchedProcessDisposition::kResumeDegraded) {
      if (!ResumeLaunchedGame(pi.hProcess, pi.hThread, "degraded")) {
        fprintf(stderr, "[launch] hook failed and resuming the game failed\n");
        reason = hibiki_voice_hook::LaunchFailureReason::kResumeFailed;
        disposition =
            hibiki_voice_hook::LaunchedProcessDisposition::kTerminate;
      } else {
        fprintf(stderr,
                "[launch] hook failed; game resumed without hooks so it still "
                "starts\n");
      }
    }
    if (disposition ==
        hibiki_voice_hook::LaunchedProcessDisposition::kTerminate) {
      TerminateProcess(pi.hProcess, 1);
    }
    ReportFailureReason(reason, rc);
  }
  if (child_process != nullptr) CloseHandle(child_process);
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
  bool japanese_locale = false;
  std::vector<std::wstring> launch_args;
  std::wstring dll_path;
  DWORD wait_ms = 5000;
  bool hold = false;
  bool follow_child_processes = false;
  bool force_direct_launch = false;
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
      } else if (a == L"--japanese-locale") {
        japanese_locale = true;
      } else if (a == L"--arg" && i + 1 < argc) {
        launch_args.emplace_back(argv[++i]);
      } else if (a == L"--dll" && i + 1 < argc) {
        dll_path = argv[++i];
      } else if (a == L"--wait-ms" && i + 1 < argc) {
        wait_ms = static_cast<DWORD>(_wtoi(argv[++i]));
      } else if (a == L"--hold") {
        hold = true;
      } else if (a == L"--follow-child-processes") {
        follow_child_processes = true;
      } else if (a == L"--force-direct-launch") {
        force_direct_launch = true;
      } else if (a == L"--no-luna") {
        luna.enabled = false;
      } else if (a == L"--luna-pchooks") {
        luna.pc_hooks = true;
      } else if (a == L"--luna-codepage" && i + 1 < argc) {
        luna.codepage = _wtoi(argv[++i]);
      } else if (a == L"--luna-hook-code" && i + 1 < argc) {
        luna.hook_codes.emplace_back(argv[++i]);
      } else if (a == L"--luna-hook-profile" && i + 1 < argc) {
        luna.profile_path = argv[++i];
      }
    }
    LocalFree(argv);
  }

  if ((pid == 0) == launch_exe.empty()) {
    // 两个都没给 或 两个都给了。
    return Fail(
        "usage: fushi_voice_injector --pid <PID> [--dll <hook.dll>] "
        "[--wait-ms N] [--hold]\n"
        "   or: fushi_voice_injector --launch <exe> [--workdir <dir>] "
        "[--japanese-locale] "
        "[--arg <a>]... [--dll <hook.dll>] [--wait-ms N] [--hold] "
        "[--follow-child-processes] [--force-direct-launch]\n"
        "LunaHook(host 侧全引擎文本 hook，仅 --hold 生效): [--no-luna] "
        "[--luna-pchooks] [--luna-codepage <cp=932>] "
        "[--luna-hook-code <H-code>]... [--luna-hook-profile <profiles.tsv>]");
  }

  if (dll_path.empty()) {
    dll_path = DefaultDllPath();
  }
  if (GetFileAttributesW(dll_path.c_str()) == INVALID_FILE_ATTRIBUTES) {
    Fail("hook DLL not found (pass --dll <path>)");
    ReportFailureReason(hibiki_voice_hook::LaunchFailureReason::kHookDllMissing,
                        1);
    return 1;
  }

  // launch 模式：CREATE_SUSPENDED 早注入。
  if (!launch_exe.empty()) {
    return RunLaunch(launch_exe, workdir, launch_args, dll_path, wait_ms, hold,
                     follow_child_processes, japanese_locale,
                     force_direct_launch, luna);
  }

  // attach 模式：注入已运行进程（老路径行为不变）。
  HANDLE target = OpenProcess(
      PROCESS_CREATE_THREAD | PROCESS_VM_OPERATION | PROCESS_VM_WRITE |
          PROCESS_VM_READ | PROCESS_QUERY_INFORMATION,
      FALSE, pid);
  if (target == nullptr) {
    fprintf(stderr, "OpenProcess(%lu) failed: %lu (需管理员/相同完整性级别?)\n",
            pid, GetLastError());
    // 附着失败最常见的真实原因：游戏以更高完整性级别（管理员）运行。host 据此提示
    // 「以管理员身份启动 Hibiki」，并且不做无意义的重试。
    fprintf(stderr, "ERR reason=accessDenied exit=1\n");
    return 1;
  }

  LunaOptions effective_luna = luna;
  const std::wstring target_exe = ProcessImagePath(target);
  ApplyLunaProfiles(target_exe, pid, effective_luna.profile_path,
                    &effective_luna);
  if (!effective_luna.pc_hooks && !target_exe.empty() &&
      ShouldAutoUseLunaPcHooks(target_exe)) {
    effective_luna.pc_hooks = true;
    fprintf(stderr,
            "[luna] auto-enabled PC hooks for attached Unity/Mono-style "
            "target: %ls\n",
            ExecutableBaseName(target_exe).c_str());
  }

  hibiki_voice_hook::LaunchFailureReason reason =
      hibiki_voice_hook::LaunchFailureReason::kNone;
  const int rc = RunInjection(target, pid, dll_path, wait_ms, hold, nullptr,
                              nullptr, effective_luna, &reason);
  CloseHandle(target);
  if (rc != 0) ReportFailureReason(reason, rc);
  return rc;
}
