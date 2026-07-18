#include <windows.h>

#include <mmreg.h>
#include <xaudio2.h>

#include <MinHook.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

#include "voice_hook_ipc.h"

// galgame 一键制卡 C 阶段 hook DLL（C.1 注入管线 + C.2 XAudio2 语音捕获）。
//
// C.1 建立注入管线与共享内存契约：注入进游戏后打开 injector 建好的共享内存、校验 magic/version、
// 标记 hooked=1、SetEvent 通知 injector。
// C.2 在 HookWorker 里经 MinHook 安装 XAudio2 语音捕获链：
//   XAudio2Create -> 每个 IXAudio2::CreateSourceVoice -> 每个 source voice 的 SubmitSourceBuffer，
//   在语音进混音**之前**把 PCM memcpy 进共享内存的环形缓冲。回调里只 memcpy + 推 write_pos/
//   total_written，无锁无分配无 IO（回调阻塞即爆音，spec 红线）。
//
// loader lock 纪律：DllMain 里**不**做 IPC/同步/加载库/MinHook，只 DisableThreadLibraryCalls +
// CreateThread 把活儿丢给工作线程（在 loader lock 之外跑），这是 hook DLL 的正确形态。
namespace {

using hibiki_voice_hook::kSharedMagic;
using hibiki_voice_hook::kSharedVersion;
using hibiki_voice_hook::ReadyEventName;
using hibiki_voice_hook::SharedHeader;
using hibiki_voice_hook::SharedMemoryName;

HANDLE g_mapping = nullptr;
SharedHeader* g_header = nullptr;
volatile bool g_stop = false;

// ── C.2 捕获状态 ────────────────────────────────────────────────────────────
// 环形缓冲基址（= header 之后）与容量，HookWorker 装好后一次性缓存；SubmitSourceBuffer
// 回调只读它们（不再触碰 header 的只读字段）。g_capture_enabled 是回调总开关：DETACH/停机时
// 先置 false 再解映射，堵住回调用悬垂 g_ring_base 的窗口。
uint8_t* g_ring_base = nullptr;
uint32_t g_ring_capacity = 0;
volatile bool g_capture_enabled = false;
bool g_mh_init = false;

// MinHook 去重集：同一 SubmitSourceBuffer/CreateSourceVoice 实现常被多个实例共享同一 vtable，
// 对同一函数地址只 MH_CreateHook 一次（重复 create 会报 MH_ERROR_ALREADY_CREATED）。
CRITICAL_SECTION g_cs;
bool g_cs_ready = false;
void* g_hooked_fns[16] = {nullptr};
int g_hooked_count = 0;

// 首次拿到语音格式的写入闩：多路 CreateSourceVoice 只让第一个写 header 格式字段。
volatile LONG g_format_set = 0;

// ── COM 方法 vtable 槽（按 xaudio2.h 接口声明顺序推定，跨 XAudio2 2.7/2.8/2.9 稳定）──────
// IXAudio2 : IUnknown -> QueryInterface(0) AddRef(1) Release(2)
//            RegisterForCallbacks(3) UnregisterForCallbacks(4) CreateSourceVoice(5) ...
constexpr size_t kIdxCreateSourceVoice = 5;
// IXAudio2Voice（**不**继承 IUnknown）: GetVoiceDetails(0)...DestroyVoice(18)
// IXAudio2SourceVoice : Start(19) Stop(20) SubmitSourceBuffer(21) ...
constexpr size_t kIdxSubmitSourceBuffer = 21;

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

XAudio2Create_t g_orig_XAudio2Create9 = nullptr;
XAudio2Create_t g_orig_XAudio2Create8 = nullptr;
CreateSourceVoice_t g_orig_CreateSourceVoice = nullptr;
SubmitSourceBuffer_t g_orig_SubmitSourceBuffer = nullptr;

// 独立测试用 proof-of-life 标记文件：%TEMP%\hibiki_voice_hook_<pid>.marker。injector 之外也
// 能据此确认 DLL 真的被加载执行（不依赖事件）。
void WriteMarkerFile(DWORD pid) {
  wchar_t temp[MAX_PATH] = {0};
  const DWORD n = GetTempPathW(MAX_PATH, temp);
  if (n == 0 || n > MAX_PATH) {
    return;
  }
  std::wstring path =
      std::wstring(temp) + L"hibiki_voice_hook_" + std::to_wstring(pid) +
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
  } else if (MH_CreateHook(target, detour, original) == MH_OK &&
             MH_EnableHook(target) == MH_OK) {
    if (g_hooked_count < 16) {
      g_hooked_fns[g_hooked_count++] = target;
    }
    ok = true;
  }
  LeaveCriticalSection(&g_cs);
  return ok;
}

// 首次拿到语音 WAVEFORMATEX：填 header 的 sample_rate/channels/bits/is_float，block_align 最后
// 写（作为「格式就绪」信号——SubmitSourceBuffer 回调据 block_align!=0 判定可安全换算字节）。
void MaybeRecordFormat(const WAVEFORMATEX* wf) {
  if (wf == nullptr || g_header == nullptr) {
    return;
  }
  if (InterlockedCompareExchange(&g_format_set, 1, 0) != 0) {
    return;  // 已有其它 voice 抢先写过格式。
  }
  g_header->sample_rate = wf->nSamplesPerSec;
  g_header->channels = wf->nChannels;
  g_header->bits_per_sample = wf->wBitsPerSample;
  uint32_t is_float = 0;
  if (wf->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
    is_float = 1;
  } else if (wf->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
             wf->cbSize >=
                 sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
    const auto* ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(wf);
    if (ext->SubFormat.Data1 == WAVE_FORMAT_IEEE_FLOAT) {
      is_float = 1;
    }
  }
  g_header->is_float = is_float;
  g_header->block_align =
      static_cast<uint32_t>(wf->nChannels) * (wf->wBitsPerSample / 8);
}

// 把 [len] 字节推进共享内存环形缓冲（写满即覆盖最旧）。单写者：只推 write_pos（回绕）+
// total_written（单调）。逻辑照抄 audio_loopback_capture.cpp 的 RingAppendLocked，但这里单写单
// 读用 volatile 无需锁。写序：memcpy -> write_pos -> total_written（reader 读 total_written 才取数，
// 至多滞后一包，spec 允许）。
inline void RingAppendVoice(const uint8_t* data, uint32_t len) {
  const uint32_t cap = g_ring_capacity;
  if (cap == 0 || len == 0 || g_ring_base == nullptr) {
    return;
  }
  if (len >= cap) {
    // 超过一整圈：只保留最后 cap 字节，从头写。
    data += (len - cap);
    memcpy(g_ring_base, data, cap);
    g_header->write_pos = 0;
    g_header->total_written += cap;
    return;
  }
  uint32_t wp = g_header->write_pos;
  uint32_t first = cap - wp;
  if (first > len) {
    first = len;
  }
  memcpy(g_ring_base + wp, data, first);
  if (len > first) {
    memcpy(g_ring_base, data + first, len - first);
  }
  wp += len;
  if (wp >= cap) {
    wp -= cap;
  }
  g_header->write_pos = wp;
  g_header->total_written += len;
}

// ── C.2 detour：IXAudio2SourceVoice::SubmitSourceBuffer ──────────────────────
// 语音送进混音前的最后一跳。零阻塞红线：只读 pBuffer 字段 + 换算字节 + RingAppendVoice，
// 绝不加锁/分配/IO/日志。PlayBegin/PlayLength 单位是**样本(每通道)**，PlayLength==0 表示到
// buffer 尾。按 block_align 换算成字节段 [PlayBegin, PlayBegin+PlayLength)。
HRESULT STDMETHODCALLTYPE Detour_SubmitSourceBuffer(
    IXAudio2SourceVoice* self, const XAUDIO2_BUFFER* pBuffer,
    const XAUDIO2_BUFFER_WMA* pBufferWMA) {
  if (g_capture_enabled && pBuffer != nullptr &&
      pBuffer->pAudioData != nullptr && g_header != nullptr) {
    const uint32_t ba = g_header->block_align;
    if (ba != 0) {
      const uint64_t total = pBuffer->AudioBytes;
      const uint64_t begin = static_cast<uint64_t>(pBuffer->PlayBegin) * ba;
      if (begin < total) {
        uint64_t len = (pBuffer->PlayLength != 0)
                           ? static_cast<uint64_t>(pBuffer->PlayLength) * ba
                           : (total - begin);
        if (begin + len > total) {
          len = total - begin;
        }
        len -= (len % ba);  // 帧对齐（防御性）。
        if (len != 0) {
          RingAppendVoice(pBuffer->pAudioData + begin,
                          static_cast<uint32_t>(len));
        }
      }
    }
  }
  // TODO(C.3 校准模式)：此切片捕获所有 source voice 的 SubmitSourceBuffer（先打通「有语音
  // 进环形缓冲」）。逐 callsite 精筛（按 game.exe SHA + callsite RVA 只留角色语音 voice、
  // BGM/SE 连 memcpy 都不做）需真实游戏抓调用栈标定，留给 C.3。
  return g_orig_SubmitSourceBuffer(self, pBuffer, pBufferWMA);
}

// ── C.2 detour：IXAudio2::CreateSourceVoice ─────────────────────────────────
// 每次创建 source voice：先调原函数拿到 voice，成功后 ① 首次记格式，② vtable-hook 这个新
// voice 的 SubmitSourceBuffer（同一实现共享 vtable，HookFn 去重只装一次）。
HRESULT STDMETHODCALLTYPE Detour_CreateSourceVoice(
    IXAudio2* self, IXAudio2SourceVoice** ppSourceVoice,
    const WAVEFORMATEX* pSourceFormat, UINT32 Flags, float MaxFrequencyRatio,
    IXAudio2VoiceCallback* pCallback, const XAUDIO2_VOICE_SENDS* pSendList,
    const XAUDIO2_EFFECT_CHAIN* pEffectChain) {
  const HRESULT hr = g_orig_CreateSourceVoice(
      self, ppSourceVoice, pSourceFormat, Flags, MaxFrequencyRatio, pCallback,
      pSendList, pEffectChain);
  if (SUCCEEDED(hr) && ppSourceVoice != nullptr && *ppSourceVoice != nullptr) {
    MaybeRecordFormat(pSourceFormat);
    HookFn(VtableSlot(*ppSourceVoice, kIdxSubmitSourceBuffer),
           reinterpret_cast<void*>(&Detour_SubmitSourceBuffer),
           reinterpret_cast<void**>(&g_orig_SubmitSourceBuffer));
  }
  return hr;
}

// 对一个 IXAudio2 实例 vtable-hook 其 CreateSourceVoice（去重：所有实例共享同一 vtable）。
void HookCreateSourceVoiceOn(IXAudio2* x) {
  if (x == nullptr) {
    return;
  }
  HookFn(VtableSlot(x, kIdxCreateSourceVoice),
         reinterpret_cast<void*>(&Detour_CreateSourceVoice),
         reinterpret_cast<void**>(&g_orig_CreateSourceVoice));
}

// ── C.2 detour：导出的 XAudio2Create（xaudio2_9/8.dll）──────────────────────
// 先调原函数拿到 IXAudio2*，再包裹它的 CreateSourceVoice。2.9 / 2.8 各一份（不同 DLL 不同
// 地址、各自 trampoline）。
HRESULT WINAPI Detour_XAudio2Create9(IXAudio2** ppXAudio2, UINT32 Flags,
                                     XAUDIO2_PROCESSOR XAudio2Processor) {
  const HRESULT hr = g_orig_XAudio2Create9(ppXAudio2, Flags, XAudio2Processor);
  if (SUCCEEDED(hr) && ppXAudio2 != nullptr) {
    HookCreateSourceVoiceOn(*ppXAudio2);
  }
  return hr;
}
HRESULT WINAPI Detour_XAudio2Create8(IXAudio2** ppXAudio2, UINT32 Flags,
                                     XAUDIO2_PROCESSOR XAudio2Processor) {
  const HRESULT hr = g_orig_XAudio2Create8(ppXAudio2, Flags, XAudio2Processor);
  if (SUCCEEDED(hr) && ppXAudio2 != nullptr) {
    HookCreateSourceVoiceOn(*ppXAudio2);
  }
  return hr;
}

// hook 导出的 XAudio2Create。用 GetModuleHandle 拿已加载的 xaudio2 模块；未加载则 LoadLibrary
// 强制解析导出（系统有则 refcount+1，游戏随后调 XAudio2Create 命中同一地址触发 detour；无则
// 跳过）。2.9 优先（Win10 主流），2.8 兜底（Win8 引擎）。
//
// 局限（需真实游戏验证）：只捕获注入**之后**创建的 XAudio2/voice——若游戏在注入前已建好引擎
// 与全部 source voice，会漏掉（需 hook LoadLibrary 或注入更早，留待 C.3/C.4）。
void TryHookXAudio2Create() {
  struct Candidate {
    const wchar_t* dll;
    void* detour;
    void** original;
  };
  const Candidate cands[] = {
      {L"xaudio2_9.dll", reinterpret_cast<void*>(&Detour_XAudio2Create9),
       reinterpret_cast<void**>(&g_orig_XAudio2Create9)},
      {L"xaudio2_8.dll", reinterpret_cast<void*>(&Detour_XAudio2Create8),
       reinterpret_cast<void**>(&g_orig_XAudio2Create8)},
  };
  for (const auto& c : cands) {
    HMODULE mod = GetModuleHandleW(c.dll);
    if (mod == nullptr) {
      mod = LoadLibraryW(c.dll);
    }
    if (mod == nullptr) {
      continue;
    }
    void* fn = reinterpret_cast<void*>(GetProcAddress(mod, "XAudio2Create"));
    HookFn(fn, c.detour, c.original);
  }

  // ── DirectSound 路径（旧引擎）：此切片**不做**。──────────────────────────
  // 需 hook IDirectSoundBuffer::Lock/Play（或 DirectSoundCreate）在混音前取 buffer 段，
  // 但 DirectSound 的 buffer 语义（循环 buffer + 写游标）与 XAudio2 差异大、且只能在真实旧
  // 引擎游戏上标定验证，写空壳无法编译/运行验证=slop。留待 C.3 逐引擎覆盖。
}

// 工作线程：打开共享内存 -> 校验契约 -> 标记 hooked -> 装 XAudio2 捕获链 -> 通知 injector。
DWORD WINAPI HookWorker(LPVOID) {
  const DWORD pid = GetCurrentProcessId();
  WriteMarkerFile(pid);

  const std::wstring shm = SharedMemoryName(pid);
  g_mapping = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE, shm.c_str());
  if (g_mapping != nullptr) {
    g_header = static_cast<SharedHeader*>(
        MapViewOfFile(g_mapping, FILE_MAP_ALL_ACCESS, 0, 0, 0));
  }
  if (g_header != nullptr) {
    // 只信任 injector 建好、契约匹配的映射。
    if (g_header->magic == kSharedMagic &&
        g_header->version == kSharedVersion) {
      g_header->hooked = 1;

      // ── C.2：安装 XAudio2 语音捕获 hook ─────────────────────────────────
      g_ring_base =
          reinterpret_cast<uint8_t*>(g_header) + sizeof(SharedHeader);
      g_ring_capacity = g_header->ring_capacity;
      InitializeCriticalSection(&g_cs);
      g_cs_ready = true;
      if (MH_Initialize() == MH_OK) {
        g_mh_init = true;
        g_capture_enabled = true;  // detour 上线（XAudio2 未加载时 hook 随后命中）。
        TryHookXAudio2Create();
      }
    }
  }

  // 通知 injector：DLL 已加载并跑到这里（proof-of-life）。事件由 injector 建好。
  const std::wstring evt = ReadyEventName(pid);
  HANDLE ready = OpenEventW(EVENT_MODIFY_STATE, FALSE, evt.c_str());
  if (ready != nullptr) {
    SetEvent(ready);
    CloseHandle(ready);
  }

  // 承载捕获期间生命周期，保活到停机。
  while (!g_stop) {
    Sleep(200);
  }

  // 收尾在工作线程里做（不在 loader lock 中）：先关捕获总开关，再拆 MinHook。
  g_capture_enabled = false;
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
      DisableThreadLibraryCalls(module);
      // 活儿丢给工作线程（loader lock 之外）。CreateThread 在 DllMain 中是允许的。
      CreateThread(nullptr, 0, HookWorker, nullptr, 0, nullptr);
      break;
    case DLL_PROCESS_DETACH:
      // 先关捕获总开关，堵住 SubmitSourceBuffer 回调用悬垂 g_ring_base 的窗口，再解映射。
      // 注意：MinHook 拆卸放在工作线程（见 HookWorker 收尾），不在此 loader lock 中做——
      // 进程正常退出（reserved != NULL）时其它线程已停，OS 回收即可；动态 FreeLibrary 卸载
      // 极罕见（注入的 hook DLL 常驻进程生命周期），此路径 trampoline 残留由 OS 退出兜底。
      g_capture_enabled = false;
      g_stop = true;
      if (g_header != nullptr) {
        UnmapViewOfFile(g_header);
        g_header = nullptr;
      }
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
