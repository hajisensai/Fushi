#include <windows.h>

// 通用位图呈现器的窗口过程要用 GET_X_LPARAM / GET_Y_LPARAM 拆鼠标消息坐标。
// 必须用它们而不是自己 HIWORD/LOWORD：多显示器下坐标可为负，HIWORD 会把负数截成大正数。
#include <windowsx.h>

#include <mmreg.h>
#include <xaudio2.h>

// DirectSound（旧引擎 KiriKiri/吉里吉里等混音前干净语音）。只用头文件里的接口/结构定义，
// **不链接 dsound.lib**——不 CoCreateInstance、不用任何 CLSID/IID 常量，仅 GetProcAddress 拿
// 导出 + vtable hook，故纯头文件即可（避开 dsound.lib 依赖）。DIRECTSOUND_VERSION 必须在
// include 前定义为 0x0800，才能拿到 IDirectSound8 定义。
#define DIRECTSOUND_VERSION 0x0800
#include <dsound.h>

// 精确 WHITE ALBUM2 profile 的 D3D9 几何 trace（只用接口定义，不链 d3d9.lib）。
// 必须在这里而不是 adapter 里 include —— 理由见 leaf_aquaplus_adapter.inc 顶部。
#include <d3d9.h>

// C.2e Ren'Py/FFmpeg 捕获：按前缀（avcodec-54*/avformat-54*）枚举已加载模块用 Toolhelp 快照。
#include <tlhelp32.h>

// C.2f WASAPI loopback 兜底混音捕获（无引擎专属纯人声 hook 的游戏）。标准渲染端点 loopback，
// 非 vtable hook。GUID 用 __uuidof（SDK 头对这些 coclass/接口带 uuid 属性），免链额外 GUID 库；
// CoInitializeEx/CoCreateInstance/CoTaskMemFree 需 ole32.lib，用 #pragma 就地声明避免改 CMake。
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <bcrypt.h>
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "bcrypt.lib")

#include <MinHook.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <intrin.h>
#include <string>
#include <vector>

#include "il2cpp_thread_scope.h"
#include "adapter.h"
#include "module_settle.h"
#include "host_executable_digest.h"
#include "lookup_overlay_geometry.h"
#include "game_main_window.h"
// KiriKiri 第三条 exporter 路径的判据（BUG-2145）。必须在**顶层**引入：adapters/*.inc 是被
// 包进本文件匿名命名空间里的，从那里 include 会把 std:: 解析成匿名命名空间下的名字。
#include "adapters/kirikiri_exporter_scan.h"
#include "hunex_gge_trace.h"
#include "leaf_d3d_trace.h"
#include "artemis_pfs.h"
#include "asar_runtime.h"
#include "bgi_arc.h"
#include "directsound_format_registry.h"
#include "catsystem2_int.h"
#include "malie_lib.h"
#include "ffmpeg_runtime.h"
#include "lookup_v19_runtime.h"
#include "hook_original_registry.h"
#include "tracked_handle_table.h"
#include "hunex_hfa.h"
#include "siglus_ovk.h"
#include "siglus_launch.h"
#include "adapters/siglus_lookup.h"
#include "adapters/hunex_gge_lookup.h"
#include "adapters/hunex_gge_capture_bridge.h"
#include "adapters/hunex_gge_lookup_core.h"
#include "adapters/hunex_gge_selected_text.h"
#include "adapters/leaf_aquaplus_voice_archive.h"
#include "adapters/smash_fzmedia_shared.h"
#include "adapters/smash_fzmedia_lookup_core.h"
#include "adapters/smash_fzmedia_lookup.h"
#include "siglus_text.h"
#include "text_thread_identity.h"
#include "luna_text_selector.h"
#include "unity_text_mesh_reassembler.h"
#include "unity_text_profile.h"
#include "visual_arts_ovk.h"
#include "voice_hook_ipc.h"
#include "voice_resource_filename.h"
#include "voice_resource_pairing.h"
#include "kirikiri_voice_storage_name.h"
#include "lookup_line_text_match.h"
#include "xaudio_resource_dispatch.h"
#include "xaudio_source_format.h"
#include "xaudio_trace.h"
#include "xwma_resource.h"
#include "generated/profile_includes.inc"
// C.2d KiriKiriZ 原始语音 OGG 捕获需读主模块 VersionInfo 确认引擎版本（仅诊断，非门控）。
// GetFileVersionInfo* 在 version.dll，用 #pragma 就地声明依赖，避免改 CMake（改动集中在本文件）。
#pragma comment(lib, "version.lib")

// galgame 一键制卡 C 阶段 hook DLL（C.1 注入管线 + C.2 XAudio2/DirectSound 语音捕获）。
//
// C.1 建立注入管线与共享内存契约：注入进游戏后打开 injector 建好的共享内存、校验 magic/version、
// 标记 hooked=1、SetEvent 通知 injector。
// C.2 在 HookWorker 里经 MinHook 安装 XAudio2 语音捕获链：
//   XAudio2Create -> 每个 IXAudio2::CreateSourceVoice -> 每个 source voice 的 SubmitSourceBuffer，
//   在语音进混音**之前**把 PCM memcpy 进共享内存的环形缓冲。回调里只 memcpy + 推 write_pos/
//   total_written，无锁无分配无 IO（回调阻塞即爆音，spec 红线）。
// C.2b 同法覆盖 DirectSound（旧引擎 KiriKiri 等，多为 32 位）：DirectSoundCreate8/Create ->
//   每个 IDirectSound8::CreateSoundBuffer -> 每个 secondary buffer 的 Unlock；Unlock 参数即
//   游戏刚写完 PCM 的锁定区，直接 memcpy 进同一环形缓冲（跳主缓冲 + 格式一致性门控保证只装
//   一种格式的干净 secondary 语音流）。
//
// loader lock 纪律：DllMain 里**不**做 IPC/同步/加载库/MinHook，只 DisableThreadLibraryCalls +
// CreateThread 把活儿丢给工作线程（在 loader lock 之外跑），这是 hook DLL 的正确形态。
//
// 独立导出的固定 XAudio trace 不属于 SharedHeader ABI。ring_probe 从目标 DLL 的 PE export
// 解析本符号 RVA，再用 ReadProcessMemory 读取；因此无需升级 IPC 版本，也不要求 probe 与目标
// 同位数。初始化只含常量/零值，不在 loader lock 下做任何动作。
extern "C" __declspec(dllexport) alignas(8)
    fushi_voice_hook::XAudioTraceBuffer FushiXAudioTraceV1 = {};

// Numeric-only exact-profile renderer telemetry, outside SharedHeader ABI.
extern "C" __declspec(dllexport) alignas(8)
    fushi_voice_hook::LeafD3DTraceBuffer FushiLeafD3DTraceV1 = {};

// Numeric-only HUNEX/GGE renderer and sampled-input telemetry.  Like the Leaf
// trace this is resolved by the diagnostic probe from the live DLL export and
// is intentionally outside SharedHeader ABI.
extern "C" __declspec(dllexport) alignas(8)
    fushi_voice_hook::HunexGgeTraceBuffer FushiHunexGgeTraceV3 = {};

namespace {

using fushi_voice_hook::kClipCount;
using fushi_voice_hook::kDiagStartupAudioHooksReady;
using fushi_voice_hook::kDiagSiglusExactTextHookReady;
using fushi_voice_hook::kDiagSiglusExactTextObserved;
using fushi_voice_hook::kDiagSiglusOvkHooksReady;
using fushi_voice_hook::kDiagKirikiriVoiceStreamDumped;
using fushi_voice_hook::kDiagKirikiriVoiceStreamHookReady;
using fushi_voice_hook::kDiagUnityIl2CppClipCaptured;
using fushi_voice_hook::kDiagUnityIl2CppGetDataRejected;
using fushi_voice_hook::kDiagUnityIl2CppHooksReady;
using fushi_voice_hook::kDiagUnityIl2CppPlaybackObserved;
using fushi_voice_hook::kDiagUnityNaninovelTextHookReady;
using fushi_voice_hook::kDiagUnityTmpTextHooksReady;
using fushi_voice_hook::kUnityBundlePathChars;
using fushi_voice_hook::kUnityClipNameChars;
using fushi_voice_hook::kUnityVoiceEventCount;
using fushi_voice_hook::kLoopbackMarkerCount;
using fushi_voice_hook::kSharedMagic;
using fushi_voice_hook::kSharedVersion;
using fushi_voice_hook::kTextSlotBytes;
using fushi_voice_hook::kTextSlotCount;
using fushi_voice_hook::kTextHookCodeChars;
using fushi_voice_hook::kTextHookNameChars;
using fushi_voice_hook::LoopbackMarker;
using fushi_voice_hook::ReadyEventName;
using fushi_voice_hook::SharedHeader;
using fushi_voice_hook::SharedMemoryName;
using fushi_voice_hook::TextSlot;
using fushi_voice_hook::VoiceClip;
using fushi_voice_hook::UnityVoiceEvent;

HANDLE g_mapping = nullptr;
SharedHeader* g_header = nullptr;
uint64_t g_mapped_view_bytes = 0u;
volatile bool g_stop = false;

// 本 DLL 自己的模块句柄，DllMain 一进来就记下。通用位图呈现器建窗口类/窗口时要用它做
// hInstance——传 nullptr 会把窗口类注册到宿主 exe 名下，DLL 卸载后类残留指向已释放的
// 窗口过程。这个句柄在进程生命周期内恒定，注入的 hook DLL 也不会被 FreeLibrary。
HMODULE g_module = nullptr;

// ── C.2 捕获状态 ────────────────────────────────────────────────────────────
// 环形缓冲基址（= header 之后）与容量，HookWorker 装好后一次性缓存；SubmitSourceBuffer
// 回调只读它们（不再触碰 header 的只读字段）。g_capture_enabled 是回调总开关：DETACH/停机时
// 先置 false 再解映射，堵住回调用悬垂 g_ring_base 的窗口。
uint8_t* g_ring_base = nullptr;
uint32_t g_ring_capacity = 0;
volatile bool g_capture_enabled = false;
bool g_mh_init = false;

// ── v2 区基址（HookWorker 按 header 偏移一次性缓存）──────────────────────────
// g_clip_base：语音 clip 索引区，SubmitSourceBuffer/DsbUnlock 回调按句写（零阻塞）。
// g_text_base：文本环区，文本 hook（GetGlyphOutlineW/ExtTextOutW 等）写台词行（可加锁）。
uint8_t* g_text_base = nullptr;
uint8_t* g_clip_base = nullptr;

// ── C.2f loopback 区基址（HookWorker 按 header 偏移一次性缓存；loopback 线程独占写）──────────
// g_lb_ring_base：loopback 混音环（16-bit PCM）。g_lb_marker_base：时间戳↔位置标记表。
// 线程句柄与独立 stop word 归 LoopbackAdapter 单一所有，避免策略快速切换产生双 worker。
uint8_t* g_lb_ring_base = nullptr;
uint8_t* g_lb_marker_base = nullptr;

// MinHook 去重集：普通 hook 仍保持历史语义。只有确实会因 codec 出现多个 vtable target
// 的 XAudio2 方法使用下面两个独立 trampoline 注册表；不能把全 DLL 的不同 detour 混进
// 一个仅按 target 索引的表，否则共享实现地址会把某个 detour 绑定到别的 trampoline。
CRITICAL_SECTION g_cs;
bool g_cs_ready = false;
CRITICAL_SECTION g_text_cs;
bool g_text_cs_ready = false;
void* g_hooked_fns[64] = {nullptr};
int g_hooked_count = 0;
fushi_voice_hook::HookOriginalRegistry<16> g_submit_source_buffer_originals;
fushi_voice_hook::HookOriginalRegistry<16> g_flush_source_buffers_originals;

// 原始语音流落盘的共用出口（KiriKiri 与 Siglus 都写同一目录，供 Dart 按 tick 配对）。
//
// `>` 也是路径分隔符：KiriKiri 归档放置路径形如 `voice.xp3>坒`，条目名被哈希且无扩展名。
// 旧实现只切 `/`、`\`，于是 base 成了 `voice.xp3>坒`——含 `.xp3` 的点骗过「无点补 .ogg」，
// 落盘名 `voice.xp3_坒` 没有音频扩展名，host 的资源索引按扩展名扫就看不见它（tenshi_sz
// 真机：源资源 6.86 s 已落盘，卡里却是 5 s loopback）。扩展名按载荷魔数补（Ogg/RIFF），
// 不按名字猜。
std::wstring VoiceBaseName(const wchar_t* storagename, const uint8_t* data,
                           uint32_t len) {
  std::wstring s(storagename);
  // 分隔符判据的唯一真相源是 `kirikiri_voice_storage_name.h`——这里从尾往前扫并
  // **调用**它，而不是把字符集再抄一遍。抄一遍的代价已经付过：BUG-2115 的根因就是
  // 这个集合里少了 `>`；而 `fushi_kirikiri_voice_storage_name_test` 里那 4 条分隔符
  // 断言压的是那个函数，只要生产代码自己硬写字符集，把它改窄测试照样全绿。
  size_t cut = s.size();
  while (cut > 0 && !fushi_voice_hook::IsKirikiriPathSeparator(s[cut - 1])) {
    --cut;
  }
  std::wstring base = s.substr(cut);
  for (wchar_t& c : base) {
    if (c == L':' || c == L'*' || c == L'?' || c == L'"' || c == L'<' ||
        c == L'>' || c == L'|') {
      c = L'_';
    }
  }
  if (base.empty()) base = L"voice";
  if (base.find(L'.') == std::wstring::npos) {
    const wchar_t* sniffed =
        fushi_voice_hook::KirikiriVoicePayloadExtension(data, len);
    base += sniffed != nullptr ? sniffed : L".ogg";
  }
  return base;
}

bool WriteVoiceOggAt(const uint8_t* data, uint32_t len,
                     const wchar_t* storagename, uint64_t tick_ms,
                     uint64_t text_event_id = 0) {
  if (data == nullptr || len == 0) return false;
  wchar_t temp[MAX_PATH] = {0};
  const DWORD n = GetTempPathW(MAX_PATH, temp);
  if (n == 0 || n >= MAX_PATH) return false;
  std::wstring dir = std::wstring(temp) + L"fushi_gal_voice";
  if (!CreateDirectoryW(dir.c_str(), nullptr) &&
      GetLastError() != ERROR_ALREADY_EXISTS) {
    return false;
  }
  std::wstring file =
      dir + L"\\" + fushi_voice_hook::BuildVoiceResourceFileName(
                          tick_ms, VoiceBaseName(storagename, data, len),
                          text_event_id);
  HANDLE f = CreateFileW(file.c_str(), GENERIC_WRITE, 0, nullptr,
                         CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (f == INVALID_HANDLE_VALUE) return false;
  DWORD written = 0;
  const bool write_ok = WriteFile(f, data, len, &written, nullptr) != FALSE &&
      written == len;
  const bool close_ok = CloseHandle(f) != FALSE;
  if (!write_ok || !close_ok) {
    DeleteFileW(file.c_str());
    return false;
  }
  return true;
}

// 首次拿到语音格式的写入闩：多路 CreateSourceVoice 只让第一个写 header 格式字段。
volatile LONG g_format_set = 0;

// ── COM 方法 vtable 槽（按 xaudio2.h 接口声明顺序推定，跨 XAudio2 2.7/2.8/2.9 稳定）──────
// IXAudio2 : IUnknown -> QueryInterface(0) AddRef(1) Release(2)
//            RegisterForCallbacks(3) UnregisterForCallbacks(4) CreateSourceVoice(5) ...
//            StartEngine(8) StopEngine(9) CommitChanges(10)
constexpr size_t kIdxCreateSourceVoice = 5;
constexpr size_t kIdxCommitChanges = 10;
// IXAudio2Voice（**不**继承 IUnknown）: GetVoiceDetails(0)...DestroyVoice(18)
// IXAudio2SourceVoice : Start(19) Stop(20) SubmitSourceBuffer(21)
//                       FlushSourceBuffers(22) ...
constexpr size_t kIdxDestroyVoice = 18;
constexpr size_t kIdxSourceVoiceStart = 19;
constexpr size_t kIdxSourceVoiceStop = 20;
constexpr size_t kIdxSubmitSourceBuffer = 21;
constexpr size_t kIdxFlushSourceBuffers = 22;

// 原函数（MinHook trampoline）。detour 经此调回原实现。
typedef HRESULT(WINAPI* XAudio2Create_t)(IXAudio2** ppXAudio2, UINT32 Flags,
                                         XAUDIO2_PROCESSOR XAudio2Processor);
typedef HRESULT(STDMETHODCALLTYPE* CreateSourceVoice_t)(
    IXAudio2* self, IXAudio2SourceVoice** ppSourceVoice,
    const WAVEFORMATEX* pSourceFormat, UINT32 Flags, float MaxFrequencyRatio,
    IXAudio2VoiceCallback* pCallback, const XAUDIO2_VOICE_SENDS* pSendList,
    const XAUDIO2_EFFECT_CHAIN* pEffectChain);
typedef HRESULT(STDMETHODCALLTYPE* SubmitSourceBuffer_t)(
    IXAudio2SourceVoice* self, const XAUDIO2_BUFFER* pBuffer,
    const XAUDIO2_BUFFER_WMA* pBufferWMA);
typedef HRESULT(STDMETHODCALLTYPE* SourceVoiceStartStop_t)(
    IXAudio2SourceVoice* self, UINT32 Flags, UINT32 OperationSet);
typedef HRESULT(STDMETHODCALLTYPE* FlushSourceBuffers_t)(
    IXAudio2SourceVoice* self);
typedef void(STDMETHODCALLTYPE* DestroyVoice_t)(IXAudio2Voice* self);
typedef HRESULT(STDMETHODCALLTYPE* CommitChanges_t)(IXAudio2* self,
                                                     UINT32 OperationSet);

XAudio2Create_t g_orig_XAudio2Create9 = nullptr;
XAudio2Create_t g_orig_XAudio2Create8 = nullptr;
CreateSourceVoice_t g_orig_CreateSourceVoice = nullptr;
SourceVoiceStartStop_t g_orig_SourceVoiceStart = nullptr;
SourceVoiceStartStop_t g_orig_SourceVoiceStop = nullptr;
DestroyVoice_t g_orig_DestroyVoice = nullptr;
CommitChanges_t g_orig_CommitChanges = nullptr;

// ── DirectSound COM 方法 vtable 槽（按 dsound.h 接口声明顺序，跨 DS8 稳定）───────────
// IDirectSound8 : IUnknown(0-2) 后 CreateSoundBuffer(3) GetCaps(4) DuplicateSoundBuffer(5)...
constexpr size_t kIdxCreateSoundBuffer = 3;
// IDirectSoundBuffer : IUnknown(0-2) 后 GetCaps(3)...Lock(11) Play(12)...
// SetFrequency(17) Stop(18) Unlock(19) Restore(20)
constexpr size_t kIdxDsbSetFrequency = 17;
constexpr size_t kIdxDsbUnlock = 19;

// DirectSound 导出函数 + 两个 COM 方法的原实现（MinHook trampoline）。DirectSoundCreate 与
// DirectSoundCreate8 是两个不同导出（各自地址、各自 trampoline）；CreateSoundBuffer/Unlock 是
// dsound 对象共享的 vtable 槽（同一实现地址，HookFn 去重只装一次，单 trampoline 够用）。
typedef HRESULT(WINAPI* DirectSoundCreate8_t)(LPCGUID pcGuidDevice,
                                              LPDIRECTSOUND8* ppDS8,
                                              LPUNKNOWN pUnkOuter);
typedef HRESULT(WINAPI* DirectSoundCreate_t)(LPCGUID pcGuidDevice,
                                             LPDIRECTSOUND* ppDS,
                                             LPUNKNOWN pUnkOuter);
typedef HRESULT(STDMETHODCALLTYPE* CreateSoundBuffer_t)(
    IDirectSound8* self, LPCDSBUFFERDESC pcDesc, LPDIRECTSOUNDBUFFER* ppBuf,
    LPUNKNOWN pUnkOuter);
typedef HRESULT(STDMETHODCALLTYPE* DsbUnlock_t)(IDirectSoundBuffer* self,
                                                LPVOID pv1, DWORD cb1,
                                                LPVOID pv2, DWORD cb2);
typedef HRESULT(STDMETHODCALLTYPE* DsbSetFrequency_t)(
    IDirectSoundBuffer* self, DWORD frequency);

DirectSoundCreate8_t g_orig_DirectSoundCreate8 = nullptr;
DirectSoundCreate_t g_orig_DirectSoundCreate = nullptr;
CreateSoundBuffer_t g_orig_CreateSoundBuffer = nullptr;
DsbSetFrequency_t g_orig_DsbSetFrequency = nullptr;
DsbUnlock_t g_orig_DsbUnlock = nullptr;
fushi_voice_hook::DirectSoundFormatRegistry<256> g_dsound_formats;

typedef HRESULT(WINAPI* CoCreateInstance_t)(REFCLSID rclsid,
                                             LPUNKNOWN pUnkOuter,
                                             DWORD dwClsContext,
                                             REFIID riid, LPVOID* ppv);
CoCreateInstance_t g_orig_CoCreateInstance = nullptr;

// 独立测试用 proof-of-life 标记文件：%TEMP%\fushi_voice_hook_<pid>.marker。injector 之外也
// 能据此确认 DLL 真的被加载执行（不依赖事件）。
void WriteMarkerFile(DWORD pid) {
  wchar_t temp[MAX_PATH] = {0};
  const DWORD n = GetTempPathW(MAX_PATH, temp);
  if (n == 0 || n > MAX_PATH) {
    return;
  }
  std::wstring path =
      std::wstring(temp) + L"fushi_voice_hook_" + std::to_wstring(pid) +
      L".marker";
  HANDLE f = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                         CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (f == INVALID_HANDLE_VALUE) {
    return;
  }
  const char msg[] = "hibiki voice hook attached\n";
  DWORD written = 0;
  WriteFile(f, msg, sizeof(msg) - 1, &written, nullptr);
  CloseHandle(f);
}

// 从 COM 对象取 vtable 第 idx 槽的函数地址。COM 对象首字段即 vtable 指针。
void* VtableSlot(void* com_obj, size_t idx) {
  void** vtbl = *reinterpret_cast<void***>(com_obj);
  return vtbl[idx];
}

// 对函数地址 target 装 MinHook inline hook（去重 + 立即 enable）。多实例共享同一函数地址时只
// hook 一次。原函数指针写进 *original（trampoline）。返回是否已就绪（含去重命中）。
bool HookFn(void* target, void* detour, void** original) {
  if (target == nullptr || !g_cs_ready) {
    return false;
  }
  bool ok = false;
  EnterCriticalSection(&g_cs);
  bool already = false;
  for (int i = 0; i < g_hooked_count; i++) {
    if (g_hooked_fns[i] == target) {
      already = true;
      break;
    }
  }
  if (already) {
    ok = true;
  } else {
    const MH_STATUS created = MH_CreateHook(target, detour, original);
    if (created == MH_OK || created == MH_ERROR_ALREADY_CREATED) {
      const MH_STATUS enabled = MH_EnableHook(target);
      if (enabled == MH_OK || enabled == MH_ERROR_ENABLED) {
        if (g_hooked_count < 64) {
          g_hooked_fns[g_hooked_count++] = target;
        }
        ok = true;
      }
    }
  }
  LeaveCriticalSection(&g_cs);
  return ok;
}

// 多 codec XAudio2 方法专用：一个 detour 可以对应多个 target，每个 target 必须保留自己的
// trampoline。注册表按 detour 分开，避免普通 HookFn 的跨适配器 target 去重语义被改写。
template <size_t Capacity>
bool HookFnWithOriginalRegistry(
    void* target, void* detour,
    fushi_voice_hook::HookOriginalRegistry<Capacity>* originals) {
  if (target == nullptr || originals == nullptr || !g_cs_ready) return false;
  bool ok = false;
  EnterCriticalSection(&g_cs);
  void* trampoline = originals->Lookup(target);
  if (trampoline != nullptr) {
    ok = true;
  } else {
    const MH_STATUS created = MH_CreateHook(target, detour, &trampoline);
    if (created == MH_OK && originals->Publish(target, trampoline)) {
      const MH_STATUS enabled = MH_EnableHook(target);
      if (enabled == MH_OK || enabled == MH_ERROR_ENABLED) {
        ok = true;
      } else {
        originals->Erase(target, trampoline);
        MH_RemoveHook(target);
      }
    } else if (created == MH_OK) {
      MH_RemoveHook(target);
    }
  }
  LeaveCriticalSection(&g_cs);
  return ok;
}

template <typename Function, size_t Capacity>
Function OriginalHookForVtableSlot(
    void* com_obj, size_t idx,
    const fushi_voice_hook::HookOriginalRegistry<Capacity>& originals) {
  return reinterpret_cast<Function>(originals.Lookup(VtableSlot(com_obj, idx)));
}

// 首次拿到可发布的 PCM 格式：block_align 最后写，作为跨进程「格式就绪」完成标记。
// XAudio2 ADPCM 在工作线程解码成 16-bit 后也走这里，绝不把 4-bit 压缩源伪装成 PCM。
void MaybeRecordPcmFormat(uint32_t sample_rate, uint32_t channels,
                          uint32_t bits_per_sample, uint32_t is_float) {
  if (g_header == nullptr || sample_rate == 0 || channels == 0 ||
      bits_per_sample == 0 || bits_per_sample % 8 != 0) {
    return;
  }
  if (InterlockedCompareExchange(&g_format_set, 1, 0) != 0) {
    return;  // 已有其它 voice 抢先写过格式。
  }
  g_header->sample_rate = sample_rate;
  g_header->channels = channels;
  g_header->bits_per_sample = bits_per_sample;
  g_header->is_float = is_float;
  g_header->block_align = channels * (bits_per_sample / 8);
}

void MaybeRecordFormat(const WAVEFORMATEX* format) {
  fushi_voice_hook::XAudioSourceFormat parsed;
  if (!fushi_voice_hook::ParseXAudioSourceFormat(format, &parsed) ||
      parsed.encoding ==
          fushi_voice_hook::XAudioSourceEncoding::kMicrosoftAdpcm) {
    return;
  }
  MaybeRecordPcmFormat(
      parsed.sample_rate, parsed.channels, parsed.bits_per_sample,
      parsed.encoding == fushi_voice_hook::XAudioSourceEncoding::kPcmFloat ? 1u
                                                                           : 0u);
}

// ── 多写者安全的环形缓冲写入（无锁原子预留）─────────────────────────────────
// 背景：v5 起本环有**多类写者**——XAudio2/DirectSound 混音前回调（各自线程）与 KiriKiri
// wuvorbis/wuopus 解码回调（解码线程），可能并发写同一个环。旧的「单写者 write_pos/total_written
// 直接 += 」是非原子 RMW，两写者交错会互相覆盖计数、算错 clip 的 ring_offset。改成：用
// InterlockedExchangeAdd64 原子把 total_written 前移 len，返回的旧值即本段在**线性字节流**里的
// 起点——并发写者各拿不相交区间 [start, start+len)，模 cap 落到互不重叠的环内偏移。这是 wait-free
// 的（一条 lock xadd，常数时间无锁无分配），不违反音频回调零阻塞红线。
//
// 写序仍是「先占区间→memcpy→（clip 路径最后写 seq）」。host 侧对 clip 一律用 seq 门控 +
// total_at_write 覆盖判定，故预留先于 memcpy 完成不会让 host 读到半写数据（clip.seq 未就绪即跳过）。
// GrabRecent 的裸最近切片本就容忍「至多滞后一包」，此处等价。

// 原子预留 total_len 字节，返回起点环内偏移（start % cap）。多写者不相交。write_pos 仅作
// GrabRecent 的近似提示（多写者间竞态无害）。调用方保证 total_len<=cap。
inline uint32_t RingReserve(uint32_t total_len) {
  const uint32_t cap = g_ring_capacity;
  const uint64_t start = static_cast<uint64_t>(InterlockedExchangeAdd64(
      reinterpret_cast<volatile LONGLONG*>(&g_header->total_written),
      static_cast<LONGLONG>(total_len)));
  g_header->write_pos = static_cast<uint32_t>((start + total_len) % cap);
  return static_cast<uint32_t>(start % cap);
}

// 把 [data,len) 写进已预留区间内的绝对环偏移 at（wrap 处理）。多段合一 clip 时，第二段起点
// = 第一段起点 + 第一段长度（同一次预留内，保证环内连续）。
inline void RingWriteAt(uint32_t at, const uint8_t* data, uint32_t len) {
  const uint32_t cap = g_ring_capacity;
  at %= cap;
  const uint32_t first = (len <= cap - at) ? len : (cap - at);
  memcpy(g_ring_base + at, data, first);
  if (len > first) {
    memcpy(g_ring_base, data + first, len - first);
  }
}

// 单段追加便捷式：原子预留 + 写入，返回本段起点偏移（供 RecordVoiceClip 记 ring_offset）。
inline uint32_t RingAppendVoice(const uint8_t* data, uint32_t len) {
  const uint32_t cap = g_ring_capacity;
  if (cap == 0 || len == 0 || g_ring_base == nullptr || g_header == nullptr) {
    return 0;
  }
  if (len >= cap) {
    // 超过一整圈：只保留最后 cap 字节（单段>60s 实际不会发生，防御性）。
    data += (len - cap);
    len = cap;
  }
  const uint32_t off = RingReserve(len);
  RingWriteAt(off, data, len);
  return off;
}

// ── C.3 语音 clip 索引：每段捕获的语音额外记一条位置/时刻/格式，供 host 按文本时间戳配对
// 「该句语音」。零阻塞红线：只 GetTickCount64 + 填结构 + 自增，常数时间无锁无分配无 IO，可留
// 在音频回调里。写序：先填全部字段（seq 副标记先于 count），最后 clip_write_count++（host 读
// 到新 count 才取该槽，保证读到完整记录）。ring_offset=本段 memcpy 前的 write_pos；
// total_at_write=写后的 total_written（host 用 (当前 total_written - total_at_write) > ring_capacity
// 判该 clip 是否已被环形覆盖）。
inline void RecordVoiceClipFmt(uint32_t ring_offset, uint32_t byte_len,
                               uint64_t source_ptr, uint32_t sample_rate,
                               uint32_t channels, uint32_t bits_per_sample,
                               uint32_t is_float,
                               uint64_t timestamp_ms = 0,
                               uint64_t total_at_write = 0) {
  if (g_clip_base == nullptr || g_header == nullptr || byte_len == 0) {
    return;
  }
  // 多写者：clip 槽号也要原子预留（XAudio2/DS 回调与解码回调并发写 clip 索引）。原子 fetch-add
  // 拿唯一 idx，填完所有字段后**最后**写 seq 作完成标记——host 一律 seq==期望值才采纳该槽，
  // 故预留先于填充不会让 host 读到半写 clip（与文本环同款多写者纪律）。
  const uint64_t idx = static_cast<uint64_t>(InterlockedExchangeAdd64(
      reinterpret_cast<volatile LONGLONG*>(&g_header->clip_write_count),
      1));
  const size_t off = static_cast<size_t>(idx % kClipCount) * sizeof(VoiceClip);
  auto* clip = reinterpret_cast<VoiceClip*>(g_clip_base + off);
  clip->timestamp_ms = timestamp_ms == 0 ? GetTickCount64() : timestamp_ms;
  clip->total_at_write = total_at_write == 0 ? g_header->total_written
                                              : total_at_write;
  clip->ring_offset = ring_offset;
  clip->byte_len = byte_len;
  clip->sample_rate = sample_rate;
  clip->channels = channels;
  clip->bits_per_sample = bits_per_sample;
  clip->is_float = is_float;
  clip->pad = 0;
  clip->source_ptr = source_ptr;   // 该段所属源（区分语音源 vs BGM 源；解码路径=解码器句柄）
  clip->seq = idx + 1;             // 有效性完成标记，**最后**写
}

// 输出路径（XAudio2/DirectSound）便捷式：clip 格式沿用 header 全局格式（这些路径只装一种格式）。
inline void RecordVoiceClip(uint32_t ring_offset, uint32_t byte_len,
                            uint64_t source_ptr) {
  if (g_header == nullptr) {
    return;
  }
  RecordVoiceClipFmt(ring_offset, byte_len, source_ptr, g_header->sample_rate,
                     g_header->channels, g_header->bits_per_sample,
                     g_header->is_float);
}

// 通知 injector IPC 契约已经可用。必须在任何 MinHook/引擎探测之前调用：
// 这些重型安装可能被目标进程里已有的 hook 拖慢，不能因此让 injector 超时并释放共享内存。
bool SignalReady(DWORD pid, bool legacy_hibiki_ipc) {
  const std::wstring evt = ReadyEventName(pid, legacy_hibiki_ipc);
  HANDLE ready = OpenEventW(EVENT_MODIFY_STATE, FALSE, evt.c_str());
  if (ready == nullptr) return false;
  const bool signaled = SetEvent(ready) != FALSE;
  CloseHandle(ready);
  return signaled;
}

// 通用位图呈现器必须在 adapters 之前引入：KiriKiri 适配器要调 ClaimLookupPresenter()
// 来认领呈现，把通用呈现器挡在门外（两条路径同时显示卡片会出现双份）。
#include "lookup_overlay_window.inc"

#include "adapters/unity_adapter.inc"
#include "adapters/windows_audio_adapter.inc"
#include "adapters/siglus_adapter.inc"
#include "adapters/tyrano_adapter.inc"
#include "adapters/kirikiri_adapter.inc"
#include "adapters/renpy_adapter.inc"
#include "adapters/text_render_adapter.inc"
#include "adapters/siglus_lookup.inc"
#include "adapters/loopback_adapter.inc"
#include "generated/adapter_includes.inc"

#include "generic_input_shield.inc"
#include "adapter_registry.inc"

// 工作线程：打开共享内存 -> 校验契约 -> 标记 hooked -> 由 registry 安装 adapter -> 通知 injector。
DWORD WINAPI HookWorker(LPVOID module_context) {
  const DWORD pid = GetCurrentProcessId();
  AdapterRegistry registry;
  WriteMarkerFile(pid);

  wchar_t module_path[MAX_PATH] = {0};
  const DWORD module_path_length = GetModuleFileNameW(
      reinterpret_cast<HMODULE>(module_context), module_path, MAX_PATH);
  const bool legacy_hibiki_ipc =
      module_path_length > 0 && module_path_length < MAX_PATH &&
      fushi_voice_hook::ComponentUsesLegacyHibikiIpc(
          std::wstring(module_path, module_path_length));
  const std::wstring shm = SharedMemoryName(pid, legacy_hibiki_ipc);
  g_mapping = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE, shm.c_str());
  if (g_mapping != nullptr) {
    g_header = static_cast<SharedHeader*>(
        MapViewOfFile(g_mapping, FILE_MAP_ALL_ACCESS, 0, 0, 0));
    if (g_header != nullptr) {
      MEMORY_BASIC_INFORMATION memory = {};
      if (VirtualQuery(g_header, &memory, sizeof(memory)) == sizeof(memory) &&
          memory.AllocationBase == g_header && memory.BaseAddress == g_header &&
          memory.RegionSize >= sizeof(SharedHeader)) {
        g_mapped_view_bytes = static_cast<uint64_t>(memory.RegionSize);
      }
    }
  }
  // Fail closed before any adapter can observe the mapping. Polling an unknown
  // contract is unsafe even when today's baseline adapters happen not to read
  // the new fields: a later adapter would silently turn that accident into an
  // out-of-bounds or fail-open policy read.
  if (g_header == nullptr || g_header->magic != kSharedMagic ||
      g_header->version != kSharedVersion) {
    if (g_header != nullptr) {
      UnmapViewOfFile(g_header);
      g_header = nullptr;
    }
    g_mapped_view_bytes = 0u;
    if (g_mapping != nullptr) {
      CloseHandle(g_mapping);
      g_mapping = nullptr;
    }
    return 1;
  }

  g_header->hooked = 1;
  fushi_voice_hook::g_geometry_provider_registry.Reset(g_header);
  // 此时 DLL、共享内存与契约均已就绪，先让 injector 进入 hold 保住映射。
  // 后面的 MinHook/Siglus/KiriKiri 探测允许异步继续，不能阻塞 proof-of-life。
  if (!SignalReady(pid, legacy_hibiki_ipc)) return 1;

  // ── C.2/C.3：缓存各区基址后安装捕获 hook ────────────────────────────
  g_ring_base = reinterpret_cast<uint8_t*>(g_header) + sizeof(SharedHeader);
  g_ring_capacity = g_header->ring_capacity;
  // v2：文本环 / clip 索引区基址（injector 已填偏移），供文本 hook 与 clip 记录用。
  g_text_base =
      reinterpret_cast<uint8_t*>(g_header) + g_header->text_region_offset;
  g_clip_base =
      reinterpret_cast<uint8_t*>(g_header) + g_header->clip_region_offset;
  // C.2f：loopback 环 + 标记表基址（injector 已填偏移），供 loopback 线程写。
  g_lb_ring_base =
      reinterpret_cast<uint8_t*>(g_header) + g_header->loopback_ring_offset;
  g_lb_marker_base =
      reinterpret_cast<uint8_t*>(g_header) + g_header->loopback_marker_offset;
  // Apply/ack native loopback policy before potentially expensive engine
  // probing. Default deny therefore reaches stopped/applied immediately and
  // still never creates the loopback worker; explicit allow remains
  // independent of MinHook just as the historical fallback was.
  registry.InstallFallbackAdapters();
  // install() 只起 worker 并发布 starting；allow 的 applied/running 确认要等 worker
  // 真正 Start() 成功后的下一轮 PollPolicy。若把那一轮留到 MH_Initialize() +
  // InstallStartupAdapters() 之后，早注入 5s 的确认预算基本必然超时（BUG-2131）。
  // 这里用一个短的有界追平循环，只推进策略状态机、不碰引擎适配器：worker 起流通常
  // 在几百毫秒内完成，追平后立即继续引擎探测；追不平也照常往下走，绝不无界等待。
  {
    const ULONGLONG ack_deadline = GetTickCount64() + 1500ull;
    while (!g_stop && GetTickCount64() < ack_deadline) {
      registry.PollLoopbackPolicyOnly();
      if (fushi_voice_hook::NativeLoopbackRequestAcknowledged(g_header)) break;
      Sleep(20);
    }
  }
  InitializeCriticalSection(&g_cs);
  g_cs_ready = true;
  InitializeCriticalSection(&g_text_cs);
  g_text_cs_ready = true;
  InitializeCriticalSection(&g_dec_cs);
  g_dec_cs_ready = true;  // 解码器表锁须先于装解码 hook 就绪（detour 立即可能触发）。
  InitializeCriticalSection(&g_renpy_cs);
  g_renpy_cs_ready = true;  // Ren'Py 表锁须先于装 FFmpeg hook 就绪（detour 立即可能触发）。
  if (MH_Initialize() == MH_OK) {
    g_mh_init = true;
    g_capture_enabled = true;  // detour 上线（未加载时 hook 随后命中）。
    registry.InstallStartupAdapters();
    TryInstallGenericLookupInputShield();
  }

  // registry 保留原有各 adapter 的 150 次重试预算和调用顺序；工作线程只管生命周期。
  while (!g_stop) {
    registry.Poll();
    TryInstallGenericLookupInputShield();
    ProcessGenericLookupInputShield();
    fushi_voice_hook::g_geometry_provider_registry.Reconcile(g_header);
    // 通用位图呈现器：host 打开查词后才起，且只在没有引擎适配器认领呈现时起。
    // 放在 Poll 之后是因为认领发生在适配器安装里——先 Poll 再问，才不会在 KiriKiri
    // 认领之前抢跑起一个多余的分层窗口。它自带 UI 线程，这里只是点火，不阻塞本循环。
    if (g_header != nullptr && fushi_voice_hook::HasLookupRegion(g_header) &&
        g_header->lookup_enabled != 0) {
      StartLookupOverlayIfUnclaimed();
    }
    Sleep(registry.PollDelayMs());
  }
  // 呈现器先于 adapter 收尾停：它每 16ms 读一次 g_header，必须在解映射之前停稳。
  StopLookupOverlay();
  ShutdownGenericLookupInputShield();

  // 收尾在工作线程里做（不在 loader lock 中）：先提交仍在组装的 legacy TextMesh
  // 末句，再在同一把 adapter 锁内关总开关，确保正常结束不会静默丢尾句。
  if (g_cs_ready) EnterCriticalSection(&g_cs);
  FlushUnityTextMeshLine();
  g_capture_enabled = false;
  if (g_cs_ready) LeaveCriticalSection(&g_cs);
  registry.Shutdown();
  if (g_mh_init) {
    MH_DisableHook(MH_ALL_HOOKS);
    MH_Uninitialize();
    g_mh_init = false;
  }
  return 0;
}

}  // namespace

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID reserved) {
  switch (reason) {
    case DLL_PROCESS_ATTACH:
      g_module = module;
      DisableThreadLibraryCalls(module);
      // 活儿丢给工作线程（loader lock 之外）。CreateThread 在 DllMain 中是允许的。
      CreateThread(nullptr, 0, HookWorker, module, 0, nullptr);
      break;
    case DLL_PROCESS_DETACH:
      // 先关捕获总开关，堵住 SubmitSourceBuffer 回调用悬垂 g_ring_base 的窗口，再解映射。
      // 注意：MinHook 拆卸放在工作线程（见 HookWorker 收尾），不在此 loader lock 中做——
      // 进程正常退出（reserved != NULL）时其它线程已停，OS 回收即可；动态 FreeLibrary 卸载
      // 极罕见（注入的 hook DLL 常驻进程生命周期），此路径 trampoline 残留由 OS 退出兜底。
      g_capture_enabled = false;
      g_stop = true;
      // 先断 loopback 环基址（缩小 loopback 线程悬垂写窗口；进程正常退出路径 OS 已先杀线程）。
      g_lb_ring_base = nullptr;
      g_lb_marker_base = nullptr;
      if (g_header != nullptr) {
        UnmapViewOfFile(g_header);
        g_header = nullptr;
      }
      g_mapped_view_bytes = 0u;
      if (g_mapping != nullptr) {
        CloseHandle(g_mapping);
        g_mapping = nullptr;
      }
      break;
    default:
      break;
  }
  return TRUE;
}
