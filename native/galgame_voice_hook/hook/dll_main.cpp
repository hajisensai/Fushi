#include <windows.h>

#include <mmreg.h>
#include <xaudio2.h>

// DirectSound（旧引擎 KiriKiri/吉里吉里等混音前干净语音）。只用头文件里的接口/结构定义，
// **不链接 dsound.lib**——不 CoCreateInstance、不用任何 CLSID/IID 常量，仅 GetProcAddress 拿
// 导出 + vtable hook，故纯头文件即可（避开 dsound.lib 依赖）。DIRECTSOUND_VERSION 必须在
// include 前定义为 0x0800，才能拿到 IDirectSound8 定义。
#define DIRECTSOUND_VERSION 0x0800
#include <dsound.h>

#include <MinHook.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

#include "voice_hook_ipc.h"

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
namespace {

using hibiki_voice_hook::kClipCount;
using hibiki_voice_hook::kSharedMagic;
using hibiki_voice_hook::kSharedVersion;
using hibiki_voice_hook::kTextSlotBytes;
using hibiki_voice_hook::kTextSlotCount;
using hibiki_voice_hook::ReadyEventName;
using hibiki_voice_hook::SharedHeader;
using hibiki_voice_hook::SharedMemoryName;
using hibiki_voice_hook::TextSlot;
using hibiki_voice_hook::VoiceClip;

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

// ── v2 区基址（HookWorker 按 header 偏移一次性缓存）──────────────────────────
// g_clip_base：语音 clip 索引区，SubmitSourceBuffer/DsbUnlock 回调按句写（零阻塞）。
// g_text_base：文本环区，文本 hook（GetGlyphOutlineW/ExtTextOutW 等）写台词行（可加锁）。
uint8_t* g_text_base = nullptr;
uint8_t* g_clip_base = nullptr;

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

// ── DirectSound COM 方法 vtable 槽（按 dsound.h 接口声明顺序，跨 DS8 稳定）───────────
// IDirectSound8 : IUnknown(0-2) 后 CreateSoundBuffer(3) GetCaps(4) DuplicateSoundBuffer(5)...
constexpr size_t kIdxCreateSoundBuffer = 3;
// IDirectSoundBuffer : IUnknown(0-2) 后 GetCaps(3)...Lock(11) Play(12)...Unlock(19) Restore(20)
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

DirectSoundCreate8_t g_orig_DirectSoundCreate8 = nullptr;
DirectSoundCreate_t g_orig_DirectSoundCreate = nullptr;
CreateSoundBuffer_t g_orig_CreateSoundBuffer = nullptr;
DsbUnlock_t g_orig_DsbUnlock = nullptr;

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

// ── C.3 语音 clip 索引：每段捕获的语音额外记一条位置/时刻/格式，供 host 按文本时间戳配对
// 「该句语音」。零阻塞红线：只 GetTickCount64 + 填结构 + 自增，常数时间无锁无分配无 IO，可留
// 在音频回调里。写序：先填全部字段（seq 副标记先于 count），最后 clip_write_count++（host 读
// 到新 count 才取该槽，保证读到完整记录）。ring_offset=本段 memcpy 前的 write_pos；
// total_at_write=写后的 total_written（host 用 (当前 total_written - total_at_write) > ring_capacity
// 判该 clip 是否已被环形覆盖）。
inline void RecordVoiceClip(uint32_t ring_offset, uint32_t byte_len) {
  if (g_clip_base == nullptr || g_header == nullptr || byte_len == 0) {
    return;
  }
  const uint64_t idx = g_header->clip_write_count;
  const size_t off = static_cast<size_t>(idx % kClipCount) * sizeof(VoiceClip);
  auto* clip = reinterpret_cast<VoiceClip*>(g_clip_base + off);
  clip->timestamp_ms = GetTickCount64();
  clip->total_at_write = g_header->total_written;  // 写后累计
  clip->ring_offset = ring_offset;
  clip->byte_len = byte_len;
  clip->sample_rate = g_header->sample_rate;
  clip->channels = g_header->channels;
  clip->bits_per_sample = g_header->bits_per_sample;
  clip->is_float = g_header->is_float;
  clip->pad = 0;
  clip->seq = idx + 1;                    // 有效性副标记（先于 count）
  g_header->clip_write_count = idx + 1;   // 最后自增：host 据此取新 clip
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
          // C.3：这一次 SubmitSourceBuffer = 一段语音，记一条 clip（起始偏移=写前 write_pos）。
          const uint32_t off = g_header->write_pos;
          RingAppendVoice(pBuffer->pAudioData + begin,
                          static_cast<uint32_t>(len));
          RecordVoiceClip(off, static_cast<uint32_t>(len));
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
}

// ══ C.2b DirectSound 捕获链（旧引擎 KiriKiri/吉里吉里等）══════════════════════════
// XAudio2 之外的另一条混音前干净语音路径，装法与 XAudio2 同构：hook 导出的 DirectSoundCreate8/
// DirectSoundCreate 拿到 IDirectSound8*，包裹它的 CreateSoundBuffer(槽3)；每建一个 secondary
// buffer 就 vtable-hook 该 buffer 的 Unlock(槽19)，在游戏写完 PCM、Unlock 回锁前 memcpy 走。

// ── detour：IDirectSoundBuffer::Unlock（槽19）─────────────────────────────────
// 游戏把 PCM 写进锁定区后调 Unlock 交还；pv1/cb1（+回绕段 pv2/cb2）正是刚写完的字节区与实际
// 字节数，无需和 Lock 关联、无需 map，直接 memcpy 进环形缓冲。零阻塞红线：只 RingAppendVoice，
// 绝不加锁/分配/IO/日志。
HRESULT STDMETHODCALLTYPE Detour_DsbUnlock(IDirectSoundBuffer* self, LPVOID pv1,
                                           DWORD cb1, LPVOID pv2, DWORD cb2) {
  if (g_capture_enabled && g_header != nullptr) {
    // C.3：一次 Unlock = 一段语音；pv2/cb2 是 DS 缓冲回绕的第二片，与 pv1 在环形里连续，合成
    // 一条 clip（起始偏移=写前 write_pos，byte_len=cb1+cb2）。
    const uint32_t off = g_header->write_pos;
    uint32_t seg_len = 0;
    if (pv1 != nullptr && cb1 != 0) {
      RingAppendVoice(reinterpret_cast<const uint8_t*>(pv1), cb1);
      seg_len += cb1;
    }
    if (pv2 != nullptr && cb2 != 0) {
      RingAppendVoice(reinterpret_cast<const uint8_t*>(pv2), cb2);
      seg_len += cb2;
    }
    RecordVoiceClip(off, seg_len);
  }
  return g_orig_DsbUnlock(self, pv1, cb1, pv2, cb2);
}

// ── detour：IDirectSound8::CreateSoundBuffer（槽3）────────────────────────────
// 先调原函数建 buffer，成功后按两道门决定是否 hook 它的 Unlock：
//  ① 跳过主缓冲（DSBCAPS_PRIMARYBUFFER）：主缓冲是最终混音目标，抓它=抓混音不干净；只要
//     secondary（每个音单独的流）。
//  ② 格式一致性门控：环形缓冲只装**一种**格式的音，否则不同 bits/rate/channels 的字节混进
//     同一缓冲会播放乱码。首个 secondary 的格式经 MaybeRecordFormat 记进 header（全局只写一
//     次）；此后只有 (nSamplesPerSec,nChannels,wBitsPerSample) 与已记录格式全等的 buffer 才
//     hook Unlock，不等就跳过。（只 hook Unlock、不 hook Lock——Unlock 已带回写入区+字节数，
//     少一个 hook、少一处出错面。）
HRESULT STDMETHODCALLTYPE Detour_CreateSoundBuffer(IDirectSound8* self,
                                                   LPCDSBUFFERDESC pcDesc,
                                                   LPDIRECTSOUNDBUFFER* ppBuf,
                                                   LPUNKNOWN pUnkOuter) {
  const HRESULT hr = g_orig_CreateSoundBuffer(self, pcDesc, ppBuf, pUnkOuter);
  if (SUCCEEDED(hr) && pcDesc != nullptr && ppBuf != nullptr &&
      *ppBuf != nullptr && g_header != nullptr) {
    const bool is_primary = (pcDesc->dwFlags & DSBCAPS_PRIMARYBUFFER) != 0;
    const WAVEFORMATEX* fmt = pcDesc->lpwfxFormat;
    if (!is_primary && fmt != nullptr) {
      // 先尝试记格式（已记录则 no-op），再比对；全等才 hook Unlock。
      MaybeRecordFormat(fmt);
      if (fmt->nSamplesPerSec == g_header->sample_rate &&
          fmt->nChannels == g_header->channels &&
          fmt->wBitsPerSample == g_header->bits_per_sample) {
        HookFn(VtableSlot(*ppBuf, kIdxDsbUnlock),
               reinterpret_cast<void*>(&Detour_DsbUnlock),
               reinterpret_cast<void**>(&g_orig_DsbUnlock));
      }
    }
  }
  return hr;
}

// 对一个 IDirectSound(8) 实例 vtable-hook 其 CreateSoundBuffer（去重：dsound 对象共享同一
// vtable）。参数用 void*：DirectSoundCreate 返回 IDirectSound*、DirectSoundCreate8 返回
// IDirectSound8*，两者 CreateSoundBuffer 都在槽 3、同一实现地址。
void HookCreateSoundBufferOn(void* ds) {
  if (ds == nullptr) {
    return;
  }
  HookFn(VtableSlot(ds, kIdxCreateSoundBuffer),
         reinterpret_cast<void*>(&Detour_CreateSoundBuffer),
         reinterpret_cast<void**>(&g_orig_CreateSoundBuffer));
}

// ── detour：导出的 DirectSoundCreate8 / DirectSoundCreate ─────────────────────
// 先调原函数拿到 IDirectSound(8)*，成功后包裹它的 CreateSoundBuffer。两个导出各一份（不同
// 地址、各自 trampoline）；返回对象的 CreateSoundBuffer 都在槽 3。
HRESULT WINAPI Detour_DirectSoundCreate8(LPCGUID pcGuidDevice,
                                         LPDIRECTSOUND8* ppDS8,
                                         LPUNKNOWN pUnkOuter) {
  const HRESULT hr = g_orig_DirectSoundCreate8(pcGuidDevice, ppDS8, pUnkOuter);
  if (SUCCEEDED(hr) && ppDS8 != nullptr && *ppDS8 != nullptr) {
    HookCreateSoundBufferOn(*ppDS8);
  }
  return hr;
}
HRESULT WINAPI Detour_DirectSoundCreate(LPCGUID pcGuidDevice,
                                        LPDIRECTSOUND* ppDS,
                                        LPUNKNOWN pUnkOuter) {
  const HRESULT hr = g_orig_DirectSoundCreate(pcGuidDevice, ppDS, pUnkOuter);
  if (SUCCEEDED(hr) && ppDS != nullptr && *ppDS != nullptr) {
    HookCreateSoundBufferOn(*ppDS);
  }
  return hr;
}

// hook 导出的 DirectSoundCreate8 + DirectSoundCreate（dsound.dll，未加载则 LoadLibrary 强制
// 解析导出）。
//
// 局限（需真实游戏验证，保留诚实）：只捕获注入**之后**创建的 DS 对象/buffer（注入前已建好的
// 漏掉）；捕获**所有同格式 secondary buffer**——BGM/语音/SE 若同格式会一起进环形缓冲，按
// callsite/音量精筛只留角色语音留给 C.3；跨格式 buffer 已被格式门控排除。
void TryHookDirectSoundCreate() {
  HMODULE mod = GetModuleHandleW(L"dsound.dll");
  if (mod == nullptr) {
    mod = LoadLibraryW(L"dsound.dll");
  }
  if (mod == nullptr) {
    return;
  }
  void* c8 = reinterpret_cast<void*>(GetProcAddress(mod, "DirectSoundCreate8"));
  HookFn(c8, reinterpret_cast<void*>(&Detour_DirectSoundCreate8),
         reinterpret_cast<void**>(&g_orig_DirectSoundCreate8));
  void* c0 = reinterpret_cast<void*>(GetProcAddress(mod, "DirectSoundCreate"));
  HookFn(c0, reinterpret_cast<void*>(&Detour_DirectSoundCreate),
         reinterpret_cast<void**>(&g_orig_DirectSoundCreate));
}

// == wen ben hook (grab dialogue text) ==
// 覆盖 GDI 文本渲染 API（galgame 经典 hook 面）：GetGlyphOutlineW 逐字形渲染逐字累积成行，
// ExtTextOutW/TextOutW/DrawTextW 整串直接成行；写进共享内存文本环供 host 消费。
//
// 诚实局限：只覆盖 **GDI 渲染文本**的游戏。KiriKiriZ / RenPy / Unity 走 FreeType / DirectWrite
// / 自绘位图字体，GDI 文本 API 抓不到——那些靠 LunaTranslator 等备选覆盖，不在本组件范围。也
// 不写引擎特定 H-code（逐游戏内存 callsite/参数偏移的 DB，是 LunaHook 的活儿，超出本组件）。
//
// 并发模型：文本 hook **不是**音频回调，允许加锁 + 静态缓冲（仅音频回调是零阻塞红线）；但仍
// 不做重 IO。所有累积/去重/写环都在 g_text_cs 保护下、并以 g_capture_enabled 兜住 DETACH
// 解映射窗口（与音频回调同一总开关）。

// 文本渲染 API 原型（GetProcAddress 动态取址，不链接 gdi32/user32.lib）。
typedef DWORD(WINAPI* GetGlyphOutlineW_t)(HDC, UINT, UINT, LPGLYPHMETRICS, DWORD,
                                          LPVOID, const MAT2*);
typedef BOOL(WINAPI* ExtTextOutW_t)(HDC, int, int, UINT, const RECT*, LPCWSTR,
                                    UINT, const INT*);
typedef BOOL(WINAPI* TextOutW_t)(HDC, int, int, LPCWSTR, int);
typedef int(WINAPI* DrawTextW_t)(HDC, LPCWSTR, int, LPRECT, UINT);

GetGlyphOutlineW_t g_orig_GetGlyphOutlineW = nullptr;
ExtTextOutW_t g_orig_ExtTextOutW = nullptr;
TextOutW_t g_orig_TextOutW = nullptr;
DrawTextW_t g_orig_DrawTextW = nullptr;

// 文本累积/去重的锁与缓冲（与音频回调隔离，允许加锁）。
CRITICAL_SECTION g_text_cs;
bool g_text_cs_ready = false;
constexpr int kMaxLineChars = 500;           // 一行台词上界（UTF-16 字符数）
wchar_t g_glyph_buf[kMaxLineChars + 8];      // GetGlyphOutlineW 逐字累积缓冲
int g_glyph_len = 0;                         // 当前累积字符数
ULONGLONG g_glyph_last_tick = 0;             // 上次 GetGlyphOutlineW 时刻（判行界）
wchar_t g_last_flushed[kMaxLineChars + 8];   // 上一条已 flush 的行（去重）
int g_last_flushed_len = 0;

// 把一行文本写进共享内存文本环（调用者持 g_text_cs，仅序列化本 DLL 内部去重状态）。
// 文本环是**多写者**：本 DLL（游戏内 GDI hook）和 host 侧 injector 里的 LunaHook 写同一个环，
// 跨进程并发。故 slot 号必须用 InterlockedIncrement64 原子 fetch-add 预留——绝不与另一写者撞
// 同一槽，也绝不丢更新（旧的“读 text_write_count → 填 → plain store idx+1”是非原子 RMW，与
// 原子写者交错时会互相覆盖计数、丢行或读到半写槽）。写序：原子占号 → 填文本字节 + 字段 →
// **最后**写 seq=占到的号作完成标记（reader 校验 slot.seq==text_write_count 才取该槽；x86/x64
// store 有序 TSO，前面的数据写对 reader 先于 seq 可见）。首次 flush 置 text_hooked=1。
void WriteTextRingLocked(const wchar_t* text, int char_len) {
  if (g_text_base == nullptr || g_header == nullptr || char_len <= 0) {
    return;
  }
  // 原子预留唯一槽位：返回自增后的新值（=占到的 1 基序号，0 基 idx=reserved-1）。
  const LONGLONG reserved = InterlockedIncrement64(
      reinterpret_cast<volatile LONGLONG*>(&g_header->text_write_count));
  const uint64_t idx = static_cast<uint64_t>(reserved) - 1;
  const size_t slot_off =
      static_cast<size_t>(idx % kTextSlotCount) * kTextSlotBytes;
  uint8_t* slot = g_text_base + slot_off;
  auto* ts = reinterpret_cast<TextSlot*>(slot);
  uint32_t max_bytes = kTextSlotBytes - static_cast<uint32_t>(sizeof(TextSlot));
  max_bytes -= (max_bytes % static_cast<uint32_t>(sizeof(wchar_t)));  // wchar 边界
  uint32_t byte_len = static_cast<uint32_t>(char_len) *
                      static_cast<uint32_t>(sizeof(wchar_t));
  if (byte_len > max_bytes) {
    byte_len = max_bytes;  // 截断到槽容量（kTextSlotBytes-头长，wchar 对齐）
  }
  memcpy(slot + sizeof(TextSlot), text, byte_len);
  ts->timestamp_ms = GetTickCount64();
  ts->byte_len = byte_len;
  ts->is_utf8 = 0;                            // UTF-16LE
  ts->seq = static_cast<uint64_t>(reserved);  // 完成标记，**最后**写
  if (g_header->text_hooked == 0) {
    g_header->text_hooked = 1;            // 首次 flush：文本 hook proof-of-life
  }
}

// 过滤 + 去重 + 写环（调用者持 g_text_cs）。过滤：跳空串/纯空白/纯 ASCII 控制；只保留含至少
// 一个非 ASCII（>=0x3000，日文假名/汉字之类）或非空白字符数>=2 的串——避免把 UI 数字/单字母
// 当台词（粗过滤即可，别过度）。去重：与上一条 flush 完全相同则跳过（游戏常重绘同句）。
void FlushLineLocked(const wchar_t* text, int len) {
  if (text == nullptr || len <= 0) {
    return;
  }
  if (len > kMaxLineChars) {
    len = kMaxLineChars;  // 截断到缓冲/环槽上界
  }
  bool has_cjk = false;
  int meaningful = 0;
  for (int i = 0; i < len; i++) {
    const wchar_t c = text[i];
    // 空白/控制字符（空格 0x20、TAB 0x09、CR 0x0D、LF 0x0A、以及 <0x20 控制字符）不计。
    if (c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A || c < 0x20) {
      continue;
    }
    meaningful++;
    if (c >= 0x3000) {
      has_cjk = true;
    }
  }
  if (meaningful == 0) {
    return;  // 空串/纯空白/纯控制
  }
  if (!has_cjk && meaningful < 2) {
    return;  // 单个 ASCII 字符（UI 数字/字母噪声）
  }
  if (len == g_last_flushed_len &&
      memcmp(text, g_last_flushed,
             static_cast<size_t>(len) * sizeof(wchar_t)) == 0) {
    return;  // 与上一条完全相同（重绘同句）
  }
  memcpy(g_last_flushed, text, static_cast<size_t>(len) * sizeof(wchar_t));
  g_last_flushed_len = len;
  WriteTextRingLocked(text, len);
}

// 冲掉 GetGlyphOutlineW 逐字累积缓冲成一行（调用者持 g_text_cs）。
void FlushGlyphAccumLocked() {
  if (g_glyph_len > 0) {
    FlushLineLocked(g_glyph_buf, g_glyph_len);
    g_glyph_len = 0;
  }
}

// -- detour: GetGlyphOutlineW（gdi32，galgame 最经典逐字形文本 hook）--
// 多数 GDI VN 逐字渲染字形经此。uChar 是当前渲染字符：逐字累积成行，用**时间空隙**判行界
// （距上次 >120ms 视为新行——先 flush 已累积再重开累积），缓冲将满时强制 flush。
// GGO_GLYPH_INDEX 时 uChar 是字形索引而非字符，跳过累积（否则累出乱码 id）。
DWORD WINAPI Detour_GetGlyphOutlineW(HDC hdc, UINT uChar, UINT uFormat,
                                     LPGLYPHMETRICS lpgm, DWORD cbBuffer,
                                     LPVOID lpvBuffer, const MAT2* lpmat2) {
  if (g_capture_enabled && g_text_cs_ready &&
      (uFormat & GGO_GLYPH_INDEX) == 0) {
    EnterCriticalSection(&g_text_cs);
    const ULONGLONG now = GetTickCount64();
    if (g_glyph_len > 0 && (now - g_glyph_last_tick) > 120) {
      FlushGlyphAccumLocked();  // 时间空隙 -> 行界
    }
    if (uChar != 0 && uChar <= 0xFFFFu) {
      if (g_glyph_len >= kMaxLineChars) {
        FlushGlyphAccumLocked();  // 缓冲将满 -> 强制 flush
      }
      g_glyph_buf[g_glyph_len++] = static_cast<wchar_t>(uChar);
    }
    g_glyph_last_tick = now;
    LeaveCriticalSection(&g_text_cs);
  }
  return g_orig_GetGlyphOutlineW(hdc, uChar, uFormat, lpgm, cbBuffer, lpvBuffer,
                                 lpmat2);
}

// -- detour: ExtTextOutW / TextOutW（gdi32）+ DrawTextW（user32）--
// lpString + 字符数即整串台词，直接成一行（补 GetGlyphOutline 抓不到的整串渲染）。先冲掉逐字
// 累积再写整串，避免行被拆。ETO_GLYPH_INDEX（字形索引非字符）/ DT_CALCRECT（只测量不渲染）等
// 非真实文本内容跳过。
BOOL WINAPI Detour_ExtTextOutW(HDC hdc, int x, int y, UINT options,
                               const RECT* lprect, LPCWSTR lpString, UINT c,
                               const INT* lpDx) {
  if (g_capture_enabled && g_text_cs_ready && lpString != nullptr && c > 0 &&
      (options & ETO_GLYPH_INDEX) == 0) {
    EnterCriticalSection(&g_text_cs);
    FlushGlyphAccumLocked();
    FlushLineLocked(lpString, static_cast<int>(c));
    LeaveCriticalSection(&g_text_cs);
  }
  return g_orig_ExtTextOutW(hdc, x, y, options, lprect, lpString, c, lpDx);
}

BOOL WINAPI Detour_TextOutW(HDC hdc, int x, int y, LPCWSTR lpString, int c) {
  if (g_capture_enabled && g_text_cs_ready && lpString != nullptr && c > 0) {
    EnterCriticalSection(&g_text_cs);
    FlushGlyphAccumLocked();
    FlushLineLocked(lpString, c);
    LeaveCriticalSection(&g_text_cs);
  }
  return g_orig_TextOutW(hdc, x, y, lpString, c);
}

int WINAPI Detour_DrawTextW(HDC hdc, LPCWSTR lpchText, int cchText, LPRECT lprc,
                            UINT format) {
  if (g_capture_enabled && g_text_cs_ready && lpchText != nullptr &&
      (format & DT_CALCRECT) == 0) {
    int len = cchText;
    if (len < 0) {
      // cchText<0：以 NUL 结尾；手数长度（避免依赖 wcsnlen）。
      len = 0;
      while (len < kMaxLineChars && lpchText[len] != 0) {
        len++;
      }
    }
    if (len > 0) {
      EnterCriticalSection(&g_text_cs);
      FlushGlyphAccumLocked();
      FlushLineLocked(lpchText, len);
      LeaveCriticalSection(&g_text_cs);
    }
  }
  return g_orig_DrawTextW(hdc, lpchText, cchText, lprc, format);
}

// 装文本渲染 hook：gdi32 的 GetGlyphOutlineW/ExtTextOutW/TextOutW + user32 的 DrawTextW
// （GetModuleHandle 取已加载模块，未加载则 LoadLibrary 强制解析导出）。装在 XAudio2/
// DirectSound hook 之后（见 HookWorker）。
void TryHookTextRender() {
  HMODULE gdi = GetModuleHandleW(L"gdi32.dll");
  if (gdi == nullptr) {
    gdi = LoadLibraryW(L"gdi32.dll");
  }
  if (gdi != nullptr) {
    HookFn(reinterpret_cast<void*>(GetProcAddress(gdi, "GetGlyphOutlineW")),
           reinterpret_cast<void*>(&Detour_GetGlyphOutlineW),
           reinterpret_cast<void**>(&g_orig_GetGlyphOutlineW));
    HookFn(reinterpret_cast<void*>(GetProcAddress(gdi, "ExtTextOutW")),
           reinterpret_cast<void*>(&Detour_ExtTextOutW),
           reinterpret_cast<void**>(&g_orig_ExtTextOutW));
    HookFn(reinterpret_cast<void*>(GetProcAddress(gdi, "TextOutW")),
           reinterpret_cast<void*>(&Detour_TextOutW),
           reinterpret_cast<void**>(&g_orig_TextOutW));
  }
  HMODULE usr = GetModuleHandleW(L"user32.dll");
  if (usr == nullptr) {
    usr = LoadLibraryW(L"user32.dll");
  }
  if (usr != nullptr) {
    HookFn(reinterpret_cast<void*>(GetProcAddress(usr, "DrawTextW")),
           reinterpret_cast<void*>(&Detour_DrawTextW),
           reinterpret_cast<void**>(&g_orig_DrawTextW));
  }
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

      // ── C.2/C.3：缓存各区基址后安装捕获 hook ────────────────────────────
      g_ring_base =
          reinterpret_cast<uint8_t*>(g_header) + sizeof(SharedHeader);
      g_ring_capacity = g_header->ring_capacity;
      // v2：文本环 / clip 索引区基址（injector 已填偏移），供文本 hook 与 clip 记录用。
      g_text_base =
          reinterpret_cast<uint8_t*>(g_header) + g_header->text_region_offset;
      g_clip_base =
          reinterpret_cast<uint8_t*>(g_header) + g_header->clip_region_offset;
      InitializeCriticalSection(&g_cs);
      g_cs_ready = true;
      InitializeCriticalSection(&g_text_cs);
      g_text_cs_ready = true;
      if (MH_Initialize() == MH_OK) {
        g_mh_init = true;
        g_capture_enabled = true;  // detour 上线（未加载时 hook 随后命中）。
        TryHookXAudio2Create();
        TryHookDirectSoundCreate();
        TryHookTextRender();       // v2：文本 hook（抓台词）。
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
