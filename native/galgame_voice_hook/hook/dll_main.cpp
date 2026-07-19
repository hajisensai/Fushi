#include <windows.h>

#include <mmreg.h>
#include <xaudio2.h>

// DirectSound（旧引擎 KiriKiri/吉里吉里等混音前干净语音）。只用头文件里的接口/结构定义，
// **不链接 dsound.lib**——不 CoCreateInstance、不用任何 CLSID/IID 常量，仅 GetProcAddress 拿
// 导出 + vtable hook，故纯头文件即可（避开 dsound.lib 依赖）。DIRECTSOUND_VERSION 必须在
// include 前定义为 0x0800，才能拿到 IDirectSound8 定义。
#define DIRECTSOUND_VERSION 0x0800
#include <dsound.h>

// C.2e Ren'Py/FFmpeg 捕获：按前缀（avcodec-54*/avformat-54*）枚举已加载模块用 Toolhelp 快照。
#include <tlhelp32.h>

#include <MinHook.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include "voice_hook_ipc.h"

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
void* g_hooked_fns[48] = {nullptr};
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
    if (g_hooked_count < 48) {
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
                               uint32_t is_float) {
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
  clip->timestamp_ms = GetTickCount64();
  clip->total_at_write = g_header->total_written;  // 写后累计（含并发写者，判覆盖偏保守，安全）
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
          // C.3：这一次 SubmitSourceBuffer = 一段语音，记一条 clip（起始偏移=原子预留返回值）。
          const uint32_t off = RingAppendVoice(pBuffer->pAudioData + begin,
                                               static_cast<uint32_t>(len));
          RecordVoiceClip(off, static_cast<uint32_t>(len),
                          reinterpret_cast<uint64_t>(self));
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
    // C.3：一次 Unlock = 一段语音；pv2/cb2 是 DS 缓冲回绕的第二片，与 pv1 须在环形里连续，合成
    // 一条 clip。多写者下必须**一次预留整段**再分段写入，否则并发写者可能插进 pv1/pv2 之间，
    // 破坏 [ring_offset, byte_len) 的连续性。
    uint32_t seg_len = 0;
    if (pv1 != nullptr && cb1 != 0) {
      seg_len += cb1;
    }
    if (pv2 != nullptr && cb2 != 0) {
      seg_len += cb2;
    }
    if (seg_len != 0 && seg_len <= g_ring_capacity) {
      const uint32_t off = RingReserve(seg_len);
      uint32_t at = off;
      if (pv1 != nullptr && cb1 != 0) {
        RingWriteAt(at, reinterpret_cast<const uint8_t*>(pv1), cb1);
        at += cb1;
      }
      if (pv2 != nullptr && cb2 != 0) {
        RingWriteAt(at, reinterpret_cast<const uint8_t*>(pv2), cb2);
      }
      RecordVoiceClip(off, seg_len, reinterpret_cast<uint64_t>(self));
    }
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

// ══ C.2c KiriKiri 解码器捕获链（引擎级干净人声）══════════════════════════════════
// XAudio2/DirectSound 抓的是**输出**（混音后各源），KiriKiriZ 的人声不走这两条（实测输出源全
// 是 BGM/SE）。人声在**解码环节**：KiriKiriZ 给每个正在播放的声音建一个独立解码器实例，语音是
// 台词播放时新建的短时解码器。故在解码后、混音前把每个解码器输出的纯 PCM 抓走——无 BGM 混音。
//
// wuvorbis.dll：libvorbisfile 风格封装（wu_ov_open_callbacks/wu_ov_info/wu_ov_read/wu_ov_clear，
//   dumpbin 确认）。wu_ov_read 返回 16-bit 交织 PCM（word=2,sgned=1 时）。
// wuopus.dll：dumpbin 确认**没有** wu_op_* 封装，导出的是**原始 libopus**
//   （opus_decoder_create/opus_decode/opus_decoder_destroy）。故 opus 按原始 libopus API hook：
//   opus_decode 返回**每通道样本数**（非字节），格式取自 opus_decoder_create 的 Fs/channels。
//
// per-handle 表把每个解码器句柄映射到它的真实 rate/channels——clip 必须用**该解码器**的采样率/
// 声道（不同声音可能不同采样率），不能用 header 全局格式，否则播放变调（本任务最易错点）。
// source_ptr = 解码器句柄：host 现有 GrabUtterance 按 source_ptr 把同源多段解码 PCM 拼成整句。
//
// 并发：wu_ov_read / opus_decode 在解码线程跑，per-handle 表用专用 CRITICAL_SECTION 保护（open/
// read/clear 的表查改，非混音回调，短临界区可接受）；PCM 入环走无锁原子预留（见 RingReserve）。

// vorbis_info 前三字段（MSVC x86/x64：int=4、long=4，故两架构布局一致）。只读 channels/rate。
struct MiniVorbisInfo {
  int version;
  int channels;
  long rate;
};
// ov_callbacks 按值传参占位：4 个函数指针，detour 只透传不解释（布局须与真 ov_callbacks 一致）。
struct MiniOvCallbacks {
  void* read_func;
  void* seek_func;
  void* close_func;
  void* tell_func;
};

typedef int(__cdecl* wu_ov_open_callbacks_t)(void* datasource, void* vf,
                                             const char* initial, long ibytes,
                                             MiniOvCallbacks callbacks);
typedef void*(__cdecl* wu_ov_info_t)(void* vf, int link);
typedef long(__cdecl* wu_ov_read_t)(void* vf, char* buffer, int length,
                                    int bigendianp, int word, int sgned,
                                    int* bitstream);
typedef int(__cdecl* wu_ov_clear_t)(void* vf);

// 原始 libopus（opus_int32 = int，opus_int16 = int16_t）。
typedef void*(__cdecl* opus_decoder_create_t)(int Fs, int channels, int* error);
typedef int(__cdecl* opus_decode_t)(void* st, const unsigned char* data, int len,
                                    int16_t* pcm, int frame_size, int decode_fec);
typedef void(__cdecl* opus_decoder_destroy_t)(void* st);

wu_ov_open_callbacks_t g_orig_wu_ov_open_callbacks = nullptr;
wu_ov_info_t g_orig_wu_ov_info = nullptr;  // 不 hook，只 GetProcAddress 直接调（读格式）
wu_ov_read_t g_orig_wu_ov_read = nullptr;
wu_ov_clear_t g_orig_wu_ov_clear = nullptr;
opus_decoder_create_t g_orig_opus_decoder_create = nullptr;
opus_decode_t g_orig_opus_decode = nullptr;
opus_decoder_destroy_t g_orig_opus_decoder_destroy = nullptr;

// per-handle 解码器表（固定数组 + 线性扫描，无堆分配；表满降级丢弃不阻断解码）。kind 用于
// 只对 vorbis 句柄做 wu_ov_info 补格式——绝不能把 OpusDecoder* 当 OggVorbis_File* 传给 wu_ov_info。
enum DecoderKind : uint8_t { kDecVorbis = 0, kDecOpus = 1 };
struct DecoderState {
  void* handle;       // OggVorbis_File* / OpusDecoder*；nullptr = 空槽
  uint32_t rate;      // 该解码器真实采样率
  uint32_t channels;  // 该解码器真实声道数
  uint8_t kind;       // DecoderKind
};
constexpr int kMaxDecoders = 64;  // 并发解码器上界（BGM+若干 SE+语音，实际远小于此）
DecoderState g_decoders[kMaxDecoders] = {};
CRITICAL_SECTION g_dec_cs;
bool g_dec_cs_ready = false;

// 登记/更新一个解码器句柄的格式（同句柄复用槽；表满则忽略）。调用方不持锁。
void DecoderAdd(void* handle, uint32_t rate, uint32_t channels, uint8_t kind) {
  if (handle == nullptr || !g_dec_cs_ready) {
    return;
  }
  EnterCriticalSection(&g_dec_cs);
  int slot = -1;
  for (int i = 0; i < kMaxDecoders; i++) {
    if (g_decoders[i].handle == handle) {
      slot = i;  // 同句柄优先复用
      break;
    }
    if (slot < 0 && g_decoders[i].handle == nullptr) {
      slot = i;  // 记住首个空槽（继续找同句柄）
    }
  }
  if (slot >= 0) {
    g_decoders[slot].handle = handle;
    g_decoders[slot].rate = rate;
    g_decoders[slot].channels = channels;
    g_decoders[slot].kind = kind;
  }
  LeaveCriticalSection(&g_dec_cs);
}

// 取某句柄的 rate/channels；vorbis 开流时拿不到格式（channels==0）则**首次 read 时**补一次
// wu_ov_info（在锁外调，避免持锁进外部函数）。返回是否命中该句柄。
bool DecoderGetFormat(void* handle, uint32_t* rate, uint32_t* channels) {
  if (handle == nullptr || !g_dec_cs_ready) {
    return false;
  }
  int slot = -1;
  uint8_t kind = kDecVorbis;
  EnterCriticalSection(&g_dec_cs);
  for (int i = 0; i < kMaxDecoders; i++) {
    if (g_decoders[i].handle == handle) {
      slot = i;
      *rate = g_decoders[i].rate;
      *channels = g_decoders[i].channels;
      kind = g_decoders[i].kind;
      break;
    }
  }
  LeaveCriticalSection(&g_dec_cs);
  if (slot < 0) {
    return false;
  }
  if (kind == kDecVorbis && (*channels == 0 || *rate == 0) &&
      g_orig_wu_ov_info != nullptr) {
    const auto* info =
        reinterpret_cast<const MiniVorbisInfo*>(g_orig_wu_ov_info(handle, -1));
    if (info != nullptr && info->channels > 0 && info->rate > 0) {
      *rate = static_cast<uint32_t>(info->rate);
      *channels = static_cast<uint32_t>(info->channels);
      EnterCriticalSection(&g_dec_cs);
      if (g_decoders[slot].handle == handle) {  // 槽未被复用才回填
        g_decoders[slot].rate = *rate;
        g_decoders[slot].channels = *channels;
      }
      LeaveCriticalSection(&g_dec_cs);
    }
  }
  return true;
}

// 解码器关闭：从表移除该句柄。调用方不持锁。
void DecoderRemove(void* handle) {
  if (handle == nullptr || !g_dec_cs_ready) {
    return;
  }
  EnterCriticalSection(&g_dec_cs);
  for (int i = 0; i < kMaxDecoders; i++) {
    if (g_decoders[i].handle == handle) {
      g_decoders[i].handle = nullptr;
      break;
    }
  }
  LeaveCriticalSection(&g_dec_cs);
}

// -- detour: wu_ov_open_callbacks --（建解码流 -> 登记句柄 + 尝试拿格式）
int __cdecl Detour_wu_ov_open_callbacks(void* datasource, void* vf,
                                        const char* initial, long ibytes,
                                        MiniOvCallbacks callbacks) {
  const int r = g_orig_wu_ov_open_callbacks(datasource, vf, initial, ibytes,
                                            callbacks);
  if (r == 0 && vf != nullptr) {
    uint32_t rate = 0, channels = 0;
    if (g_orig_wu_ov_info != nullptr) {
      const auto* info =
          reinterpret_cast<const MiniVorbisInfo*>(g_orig_wu_ov_info(vf, -1));
      if (info != nullptr) {
        if (info->channels > 0) channels = static_cast<uint32_t>(info->channels);
        if (info->rate > 0) rate = static_cast<uint32_t>(info->rate);
      }
    }
    DecoderAdd(vf, rate, channels, kDecVorbis);  // 拿不到格式则首次 read 时补
  }
  return r;
}

// -- detour: wu_ov_read --（解码一段 16-bit PCM -> 入环 + 记 clip，格式用该 vf 真实 rate/channels）
long __cdecl Detour_wu_ov_read(void* vf, char* buffer, int length, int bigendianp,
                               int word, int sgned, int* bitstream) {
  const long ret =
      g_orig_wu_ov_read(vf, buffer, length, bigendianp, word, sgned, bitstream);
  if (g_header != nullptr) g_header->reserved_luna |= 4;  // diag: wu_ov_read 触发
  // 只抓 16-bit signed little-endian 交织 PCM（KiriKiri 语音常态）；其它先跳过。
  if (g_capture_enabled && g_header != nullptr && ret > 0 && buffer != nullptr &&
      word == 2 && sgned == 1 && bigendianp == 0) {
    g_header->reserved_luna |= 8;  // diag: wu_ov_read 写 clip
    uint32_t rate = 0, channels = 0;
    if (DecoderGetFormat(vf, &rate, &channels) && channels > 0 && rate > 0) {
      const uint32_t len = static_cast<uint32_t>(ret);
      const uint32_t off =
          RingAppendVoice(reinterpret_cast<const uint8_t*>(buffer), len);
      RecordVoiceClipFmt(off, len, reinterpret_cast<uint64_t>(vf), rate, channels,
                         16, 0);
    }
  }
  return ret;
}

// -- detour: wu_ov_clear --（关闭解码流 -> 移除句柄）
int __cdecl Detour_wu_ov_clear(void* vf) {
  const int r = g_orig_wu_ov_clear(vf);
  DecoderRemove(vf);
  return r;
}

// -- detour: opus_decoder_create --（建解码器 -> 登记句柄 + Fs/channels）
void* __cdecl Detour_opus_decoder_create(int Fs, int channels, int* error) {
  void* st = g_orig_opus_decoder_create(Fs, channels, error);
  if (st != nullptr && Fs > 0 && channels > 0) {
    DecoderAdd(st, static_cast<uint32_t>(Fs), static_cast<uint32_t>(channels),
               kDecOpus);
  }
  return st;
}

// -- detour: opus_decode --（解码 -> 入环 + 记 clip）。ret=每通道样本数，字节=ret*channels*2。
int __cdecl Detour_opus_decode(void* st, const unsigned char* data, int len,
                               int16_t* pcm, int frame_size, int decode_fec) {
  const int ret =
      g_orig_opus_decode(st, data, len, pcm, frame_size, decode_fec);
  if (g_header != nullptr) g_header->reserved_luna |= 16;  // diag: opus_decode 触发
  if (g_capture_enabled && g_header != nullptr && ret > 0 && pcm != nullptr) {
    g_header->reserved_luna |= 32;  // diag: opus_decode 写 clip
    uint32_t rate = 0, channels = 0;
    if (DecoderGetFormat(st, &rate, &channels) && channels > 0 && rate > 0) {
      const uint32_t bytes =
          static_cast<uint32_t>(ret) * channels * 2u;  // 16-bit 交织
      const uint32_t off =
          RingAppendVoice(reinterpret_cast<const uint8_t*>(pcm), bytes);
      RecordVoiceClipFmt(off, bytes, reinterpret_cast<uint64_t>(st), rate,
                         channels, 16, 0);
    }
  }
  return ret;
}

// -- detour: opus_decoder_destroy --（销毁 -> 移除句柄）
void __cdecl Detour_opus_decoder_destroy(void* st) {
  g_orig_opus_decoder_destroy(st);
  DecoderRemove(st);
}

// 装 KiriKiri 解码器 hook：wuvorbis 的 wu_ov_*（+ 直接取 wu_ov_info 供 detour 调）与 wuopus 的
// 原始 libopus。DLL 未加载则跳过（不是所有游戏是 KiriKiri，或注入时插件尚未载入）。装在
// XAudio2/DirectSound/文本 hook 之后（见 HookWorker）。
//
// 局限（需真实游戏验证）：wuvorbis/wuopus 在游戏 plugin/ 子目录，若注入时尚未 load，按裸名
// LoadLibrary 找不到即跳过——KiriKiriZ 启动即加载插件，注入进运行中的游戏时通常已就绪；只捕获
// 注入**之后**新建的解码器（KiriKiri 每句台词新建短解码器，故运行中注入仍能抓到后续台词语音）。
// 幂等 + 返回是否两个解码器插件都已装齐。CREATE_SUSPENDED 早期注入时 wuvorbis/wuopus 在游戏
// plugin/ 子目录尚未加载（裸名 LoadLibrary 找不到子目录插件），故不 LoadLibrary，只 GetModuleHandle
// 轮询——游戏启动后自会用全路径加载插件，之后按基名即可命中。HookWorker 保活循环前段反复调本函数
// 直到装齐（见下）。静态标志保证每个插件只 hook 一次。
bool TryHookKirikiriDecoders() {
  static bool vorb_done = false;
  static bool opus_done = false;
  if (!vorb_done) {
    HMODULE vorb = GetModuleHandleW(L"wuvorbis.dll");
    if (vorb != nullptr) {
      // wu_ov_info 不 hook，detour 里直接调它读格式——须在装 open/read hook 前就绪。
      g_orig_wu_ov_info =
          reinterpret_cast<wu_ov_info_t>(GetProcAddress(vorb, "wu_ov_info"));
      HookFn(
          reinterpret_cast<void*>(GetProcAddress(vorb, "wu_ov_open_callbacks")),
          reinterpret_cast<void*>(&Detour_wu_ov_open_callbacks),
          reinterpret_cast<void**>(&g_orig_wu_ov_open_callbacks));
      void* p_read = reinterpret_cast<void*>(GetProcAddress(vorb, "wu_ov_read"));
      const bool read_ok =
          HookFn(p_read, reinterpret_cast<void*>(&Detour_wu_ov_read),
                 reinterpret_cast<void**>(&g_orig_wu_ov_read));
      if (g_header != nullptr) {
        g_header->reserved_luna |=
            (p_read == nullptr) ? 0x400 : (read_ok ? 0x100 : 0x200);
      }
      HookFn(reinterpret_cast<void*>(GetProcAddress(vorb, "wu_ov_clear")),
             reinterpret_cast<void*>(&Detour_wu_ov_clear),
             reinterpret_cast<void**>(&g_orig_wu_ov_clear));
      vorb_done = true;
      if (g_header != nullptr) g_header->reserved_luna |= 1;  // diag: vorbis 已hook
    }
  }
  if (!opus_done) {
    HMODULE opus = GetModuleHandleW(L"wuopus.dll");
    if (opus != nullptr) {
      HookFn(
          reinterpret_cast<void*>(GetProcAddress(opus, "opus_decoder_create")),
          reinterpret_cast<void*>(&Detour_opus_decoder_create),
          reinterpret_cast<void**>(&g_orig_opus_decoder_create));
      void* p_dec = reinterpret_cast<void*>(GetProcAddress(opus, "opus_decode"));
      const bool dec_ok =
          HookFn(p_dec, reinterpret_cast<void*>(&Detour_opus_decode),
                 reinterpret_cast<void**>(&g_orig_opus_decode));
      if (g_header != nullptr) {
        g_header->reserved_luna |=
            (p_dec == nullptr) ? 0x2000 : (dec_ok ? 0x800 : 0x1000);
      }
      HookFn(
          reinterpret_cast<void*>(GetProcAddress(opus, "opus_decoder_destroy")),
          reinterpret_cast<void*>(&Detour_opus_decoder_destroy),
          reinterpret_cast<void**>(&g_orig_opus_decoder_destroy));
      opus_done = true;
      if (g_header != nullptr) g_header->reserved_luna |= 2;  // diag: opus 已hook
    }
  }
  return vorb_done && opus_done;
}

// ══ C.2d KiriKiriZ 原始语音 OGG 捕获（引擎内部 TVPCreateStream hook）══════════════
// XAudio2/DirectSound 抓输出、解码器 hook 抓 wuvorbis/wuopus 解码——但 KiriKiriZ 的人声实测三条都
// 不触发：语音在 voice.xp3 里，播放路径是
//   storagename("voice/xxx.ogg") → 引擎内部 TVPCreateStream(name,mode) → 已解密 OGG 流 → OggVorbis 解码
// 故正确 hook 点 = 引擎内部 TVPCreateStream（KrkrExtract 的 GetTVPCreateStreamCall 定位的同一函数）。
// 它对每次文件访问都带 storagename(ttstr) + 一个能读出**解密后原始字节**的 tTJSBinaryStream。过滤
// storagename 含 "voice" 或后缀 .ogg/.opus → 拿到"当前播放那句"的原始 OGG，落盘供 host 按时间戳与文
// 本环配对。参考实现照搬自本机 KrkrExtract（CodeAna.cpp KrkrZ 分支 / tp_stub.*）。
//
// 调用约定关键事实（纠正任务描述）：KrkrExtract 的 KrkrZ 分支反汇编显示内部 TVPCreateStream 是 MSVC
// __fastcall(ecx=name, edx=mode)（stub 里 mov edx,[ebp+C]; mov ecx,[ebp+8]; call）。任务描述里
// "eax=name / BCB fastcall"其实对应 Krkr2(BCB) 分支（mov eax,[ebp+8]）。otomeki=KrkrZ，故此处按
// MSVC __fastcall 实现；stub 扫描同时识别 eax(BCB) 变体并置诊断位后安全跳过（避免用错约定崩游戏）。

#if defined(_M_IX86)

// ── tjs 基础对象布局（x86；tjs_char=wchar_t=UTF-16LE，全部照 KrkrExtract tp_stub.h）──────────────
// ttstr 对象首 4 字节即 tTJSVariantString*（偏移+0）；空串时该指针为 NULL。
#pragma pack(push, 4)
struct TjsVariantString {
  int32_t ref_count;         // +0
  wchar_t* long_string;      // +4  堆上长字符串（非空优先用它）
  wchar_t short_string[22];  // +8  内联短字符串（TJS_VS_SHORT_LEN+1）
  int32_t length;            // +52
  uint32_t heap_flag;        // +56
  uint32_t hint;             // +60
};  // sizeof = 64
#pragma pack(pop)

// tTJSBinaryStream 抽象类 vtable。TJS_INTF_METHOD = __cdecl（不是 __stdcall，x86 下 this 走栈）。
// 槽序：0=Seek 1=Read 2=Write 3=SetEndOfStorage 4=GetSize。只用 Seek/Read/GetSize，Write/
// SetEndOfStorage 必须声明占位以把 GetSize 对齐到槽 4。
struct TjsBinaryStream {
  virtual uint64_t __cdecl Seek(int64_t offset, int32_t whence) = 0;             // 0：返回新绝对位置
  virtual uint32_t __cdecl Read(void* buffer, uint32_t read_size) = 0;          // 1：返回实际读到字节
  virtual uint32_t __cdecl Write(const void* buffer, uint32_t write_size) = 0;  // 2：占位
  virtual void __cdecl SetEndOfStorage() = 0;                                   // 3：占位
  virtual uint64_t __cdecl GetSize() = 0;                                       // 4：返回总字节数
};

// iTVPFunctionExporter（tp_stub.h:4593），TJS_INTF_METHOD = __cdecl。只用第二个方法按 narrow 串查函数。
struct ITVPFunctionExporter {
  virtual bool __cdecl QueryFunctions(const wchar_t** name, void** function, uint32_t count) = 0;
  virtual bool __cdecl QueryFunctionsByNarrowString(const char** name, void** function,
                                                    uint32_t count) = 0;
};

// exe 导出的 TVPGetFunctionExporter（无参 __stdcall，返回 exporter 单例）。
typedef ITVPFunctionExporter*(__stdcall* TVPGetFunctionExporter_t)();
// 内部 TVPCreateStream：KrkrZ = MSVC __fastcall(ecx=name(const ttstr&), edx=mode)，返回 tTJSBinaryStream*。
typedef TjsBinaryStream*(__fastcall* TVPCreateStream_t)(const void* name, uint32_t mode);

TVPCreateStream_t g_orig_TVPCreateStream = nullptr;

// exe 直取 / V2Link 两条拿 exporter 的路径共享的一次性安装闩（InterlockedCompareExchange）。
volatile LONG g_voice_installed = 0;

constexpr uint32_t kMaxVoiceDumpBytes = 32u * 1024u * 1024u;  // 单个语音/OGG 落盘上限（防御性）

// E8 rel32 的调用目标 = p + 5 + *(int32*)(p+1)（照 my.h GetCallDestination）。
inline uint8_t* GetCallDest(const uint8_t* p) {
  const int32_t rel = *reinterpret_cast<const int32_t*>(p + 1);
  return const_cast<uint8_t*>(p) + 5 + rel;
}

// 紧凑 x86 指令长度解码器（覆盖 MSVC SEH 序言指令集，够定位 CallIStream 内首个 call；未知返回 0 使
// 调用方安全放弃定位而非误步）。替代 KrkrExtract 的完整 LDE GetOpCodeSize32，避免移植整套反汇编器。
uint32_t InsnLen32(const uint8_t* p) {
  uint32_t i = 0;
  for (;;) {  // 前缀（段/操作数/地址/rep/lock）逐个吃掉。
    const uint8_t b = p[i];
    if (b == 0x66 || b == 0x67 || b == 0xF0 || b == 0xF2 || b == 0xF3 || b == 0x2E ||
        b == 0x36 || b == 0x3E || b == 0x26 || b == 0x64 || b == 0x65) {
      i++;
      continue;
    }
    break;
  }
  const uint8_t op = p[i++];
  auto modrm_len = [&]() -> uint32_t {
    const uint8_t m = p[i];
    const uint8_t mod = static_cast<uint8_t>(m >> 6);
    const uint8_t rm = static_cast<uint8_t>(m & 7);
    uint32_t len = 1;  // modrm 本身
    if (mod != 3) {
      if (rm == 4) {  // SIB
        const uint8_t sib = p[i + 1];
        len += 1;
        if (mod == 0 && (sib & 7) == 5) len += 4;  // disp32
      } else if (mod == 0 && rm == 5) {
        len += 4;  // disp32
      }
      if (mod == 1) {
        len += 1;  // disp8
      } else if (mod == 2) {
        len += 4;  // disp32
      }
    }
    return len;
  };
  switch (op) {
    case 0x90: case 0xC3: case 0xC9: case 0xCC: case 0xF4:
      return i;
    case 0xC2:
      return i + 2;  // ret imm16
    case 0x40: case 0x41: case 0x42: case 0x43: case 0x44: case 0x45: case 0x46: case 0x47:
    case 0x48: case 0x49: case 0x4A: case 0x4B: case 0x4C: case 0x4D: case 0x4E: case 0x4F:
    case 0x50: case 0x51: case 0x52: case 0x53: case 0x54: case 0x55: case 0x56: case 0x57:
    case 0x58: case 0x59: case 0x5A: case 0x5B: case 0x5C: case 0x5D: case 0x5E: case 0x5F:
    case 0x91: case 0x92: case 0x93: case 0x94: case 0x95: case 0x96: case 0x97:
      return i;  // push/pop/inc/dec/xchg-eax reg
    case 0x6A:
      return i + 1;  // push imm8
    case 0x68:
      return i + 4;  // push imm32
    case 0xEB:
      return i + 1;  // jmp rel8
    case 0xE8: case 0xE9:
      return i + 4;  // call/jmp rel32
    case 0xA0: case 0xA1: case 0xA2: case 0xA3:
      return i + 4;  // mov al/eax,[moffs32] 及反向
    case 0xA8:
      return i + 1;  // test al,imm8
    case 0xA9:
      return i + 4;  // test eax,imm32
    case 0xB0: case 0xB1: case 0xB2: case 0xB3: case 0xB4: case 0xB5: case 0xB6: case 0xB7:
      return i + 1;  // mov r8,imm8
    case 0xB8: case 0xB9: case 0xBA: case 0xBB: case 0xBC: case 0xBD: case 0xBE: case 0xBF:
      return i + 4;  // mov r32,imm32
    case 0x04: case 0x0C: case 0x14: case 0x1C: case 0x24: case 0x2C: case 0x34: case 0x3C:
      return i + 1;  // arith al,imm8
    case 0x05: case 0x0D: case 0x15: case 0x1D: case 0x25: case 0x2D: case 0x35: case 0x3D:
      return i + 4;  // arith eax,imm32
    case 0x70: case 0x71: case 0x72: case 0x73: case 0x74: case 0x75: case 0x76: case 0x77:
    case 0x78: case 0x79: case 0x7A: case 0x7B: case 0x7C: case 0x7D: case 0x7E: case 0x7F:
      return i + 1;  // jcc rel8
    case 0x80: case 0x83: case 0xC0: case 0xC1: case 0xC6: case 0x6B:
      return i + modrm_len() + 1;  // modrm + imm8
    case 0x81: case 0xC7: case 0x69:
      return i + modrm_len() + 4;  // modrm + imm32
    case 0x00: case 0x01: case 0x02: case 0x03:
    case 0x08: case 0x09: case 0x0A: case 0x0B:
    case 0x10: case 0x11: case 0x12: case 0x13:
    case 0x18: case 0x19: case 0x1A: case 0x1B:
    case 0x20: case 0x21: case 0x22: case 0x23:
    case 0x28: case 0x29: case 0x2A: case 0x2B:
    case 0x30: case 0x31: case 0x32: case 0x33:
    case 0x38: case 0x39: case 0x3A: case 0x3B:
    case 0x84: case 0x85: case 0x86: case 0x87:
    case 0x88: case 0x89: case 0x8A: case 0x8B:
    case 0x8D: case 0x8F:
    case 0xD0: case 0xD1: case 0xD2: case 0xD3:
    case 0xFE: case 0xFF: case 0x62: case 0x63:
      return i + modrm_len();  // 纯 modrm
    case 0x0F: {
      const uint8_t op2 = p[i++];
      if (op2 >= 0x80 && op2 <= 0x8F) return i + 4;  // jcc rel32
      return i + modrm_len();                        // setcc/movzx/movsx/imul 等（best effort）
    }
    default:
      return 0;  // 未知 → 放弃定位
  }
}

// 主模块（游戏 exe）映像范围，用于校验定位到的函数指针落在代码段内。
void GetMainModuleRange(uint8_t** base, uint32_t* size) {
  *base = nullptr;
  *size = 0;
  HMODULE h = GetModuleHandleW(nullptr);
  if (h == nullptr) return;
  auto b = reinterpret_cast<uint8_t*>(h);
  auto dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(b);
  if (dos->e_magic != IMAGE_DOS_SIGNATURE) return;
  auto nt = reinterpret_cast<const IMAGE_NT_HEADERS*>(b + dos->e_lfanew);
  if (nt->Signature != IMAGE_NT_SIGNATURE) return;
  *base = b;
  *size = nt->OptionalHeader.SizeOfImage;
}

// 目标是否像函数入口（常见 MSVC 序言首字节）；配合模块范围 + IsBadCodePtr 三重校验，杜绝把游戏
// hook 到中途/垃圾地址（会崩游戏）。
inline bool PlausiblePrologue(const uint8_t* p) {
  const uint8_t b = p[0];
  return b == 0x55 || b == 0x53 || b == 0x56 || b == 0x57 || b == 0x83 || b == 0x6A ||
         b == 0x68 || b == 0x8B || b == 0xB8 || b == 0xE9;
}

// 从导入的 TVPCreateIStream stub（stdcall 薄壳）定位 CallIStream（exe::TVPCreateIStream fastcall）。
// KrkrZ: 8B 55 0C(mov edx,[ebp+C]) 8B 4D 08(mov ecx,[ebp+8]) E8(call)；Krkr2: 8B 45 08(mov eax)。
// 命中 ecx → MSVC(is_bcb=false)；命中 eax → BCB(is_bcb=true)。返回 CallIStream，未命中返回 nullptr。
uint8_t* FindCallIStreamFromStub(uint8_t* stub, bool* is_bcb) {
  *is_bcb = false;
  for (int i = 0; i < 0x40; i++) {
    const uint8_t* p = stub + i;
    if (p[0] == 0x8B && p[1] == 0x55 && p[2] == 0x0C) {  // mov edx,[ebp+0C]
      const uint8_t* q = p + 3;
      if (q[0] == 0x8B && q[2] == 0x08 && q[3] == 0xE8) {  // mov ?,[ebp+08] ; call
        if (q[1] == 0x4D) {                                // ecx → KrkrZ
          *is_bcb = false;
          return GetCallDest(q + 3);
        }
        if (q[1] == 0x45) {  // eax → Krkr2
          *is_bcb = true;
          return GetCallDest(q + 3);
        }
      }
    }
  }
  return nullptr;
}

// 在 CallIStream 体内步进指令、取首个 call 目标 = 引擎内部 TVPCreateStream。逐指令步进（非裸扫 E8）
// 从根本上避免立即数里的杂散 E8 被误认；再对目标做模块范围 + IsBadCodePtr + 序言三重校验。
uint8_t* FindInternalTVPCreateStream(uint8_t* call_istream, uint8_t* mod_base, uint32_t mod_size) {
  uint32_t off = 0;
  while (off < 0x100) {
    const uint8_t* p = call_istream + off;
    if (p[0] == 0xC3 || p[0] == 0xCC) break;  // ret/int3 兜底
    if (p[0] == 0xE8) {                        // call rel32
      uint8_t* dest = GetCallDest(p);
      const bool in_mod =
          (mod_base != nullptr && dest >= mod_base && dest < mod_base + mod_size);
      if (in_mod && !IsBadCodePtr(reinterpret_cast<FARPROC>(dest)) && PlausiblePrologue(dest)) {
        return dest;
      }
    }
    const uint32_t len = InsnLen32(p);
    if (len == 0) break;  // 未知指令 → 放弃（宁可不 hook 也不误 hook）
    off += len;
  }
  return nullptr;
}

// SEH 守卫读取整条流字节（malloc 缓冲，无 C++ 析构对象故可用 __try）。读前后都 Seek 回 0，务必把
// 原流位置还原到 0 再返回给游戏，否则游戏读不到内容。异常一律吞掉，尽力不崩游戏。
bool ReadStreamAllGuarded(TjsBinaryStream* s, uint8_t** out_buf, uint32_t* out_len) {
  *out_buf = nullptr;
  *out_len = 0;
  __try {
    const uint64_t size = s->GetSize();
    if (size == 0 || size > kMaxVoiceDumpBytes) {
      s->Seek(0, 0);  // 还原位置
      return false;
    }
    uint8_t* buf = static_cast<uint8_t*>(malloc(static_cast<size_t>(size)));
    if (buf == nullptr) {
      s->Seek(0, 0);
      return false;
    }
    s->Seek(0, 0);
    uint64_t done = 0;
    while (done < size) {
      const uint64_t remain = size - done;
      const uint32_t want = static_cast<uint32_t>(remain > 0x100000 ? 0x100000 : remain);
      const uint32_t got = s->Read(buf + done, want);
      if (got == 0) break;
      done += got;
    }
    s->Seek(0, 0);  // 还原给游戏
    if (done == 0) {
      free(buf);
      return false;
    }
    *out_buf = buf;
    *out_len = static_cast<uint32_t>(done);
    return true;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;  // 流 vtable 异常：放弃本次（buf 若已分配极罕见泄漏，换不崩游戏）。
  }
}

// SEH 守卫从 ttstr 拷出 storagename（只用裸数组，可 __try）。判空 Ptr / long?:short。
bool ExtractStorageNameGuarded(const void* name, wchar_t* out, size_t out_cap) {
  __try {
    auto pp = reinterpret_cast<TjsVariantString* const*>(name);
    TjsVariantString* vs = *pp;
    if (vs == nullptr) return false;
    const wchar_t* src = vs->long_string != nullptr ? vs->long_string : vs->short_string;
    if (src == nullptr) return false;
    size_t k = 0;
    for (; src[k] != 0 && k + 1 < out_cap; k++) out[k] = src[k];
    out[k] = 0;
    return k > 0;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
}

// storagename 是否语音：小写化后含 "voice" 或后缀 .ogg/.opus（任务约定过滤；host 侧再按时间戳精配）。
bool IsVoiceStorageName(const wchar_t* name) {
  wchar_t low[520];
  size_t n = 0;
  for (; name[n] != 0 && n + 1 < 520; n++) {
    wchar_t c = name[n];
    if (c >= L'A' && c <= L'Z') c = static_cast<wchar_t>(c - L'A' + L'a');
    low[n] = c;
  }
  low[n] = 0;
  if (n >= 4 && wcscmp(low + n - 4, L".ogg") == 0) return true;
  if (n >= 5 && wcscmp(low + n - 5, L".opus") == 0) return true;
  return wcsstr(low, L"voice") != nullptr;
}

// 从 storagename 取 basename 并净化非法文件名字符；无扩展名则补 .ogg。
std::wstring VoiceBaseName(const wchar_t* storagename) {
  std::wstring s(storagename);
  const size_t pos = s.find_last_of(L"/\\");
  std::wstring base = (pos == std::wstring::npos) ? s : s.substr(pos + 1);
  for (wchar_t& c : base) {
    if (c == L':' || c == L'*' || c == L'?' || c == L'"' || c == L'<' || c == L'>' || c == L'|') {
      c = L'_';
    }
  }
  if (base.empty()) base = L"voice";
  if (base.find(L'.') == std::wstring::npos) base += L".ogg";
  return base;
}

// 落盘：%TEMP%\hibiki_gal_voice\<GetTickCount64>_<basename>。tick 与文本环 timestamp_ms 同源供配对。
void WriteVoiceOgg(const uint8_t* data, uint32_t len, const wchar_t* storagename) {
  if (data == nullptr || len == 0) return;
  wchar_t temp[MAX_PATH] = {0};
  const DWORD n = GetTempPathW(MAX_PATH, temp);
  if (n == 0 || n > MAX_PATH) return;
  std::wstring dir = std::wstring(temp) + L"hibiki_gal_voice";
  CreateDirectoryW(dir.c_str(), nullptr);  // 已存在则失败无害
  std::wstring file =
      dir + L"\\" + std::to_wstring(GetTickCount64()) + L"_" + VoiceBaseName(storagename);
  HANDLE f = CreateFileW(file.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                         FILE_ATTRIBUTE_NORMAL, nullptr);
  if (f == INVALID_HANDLE_VALUE) return;
  DWORD written = 0;
  WriteFile(f, data, len, &written, nullptr);
  CloseHandle(f);
}

// ── detour：引擎内部 TVPCreateStream（MSVC __fastcall：ecx=name(const ttstr&), edx=mode）──────────
// 先调原函数拿到已解密流；storagename 命中语音则读全字节落盘（流位置在 ReadStreamAllGuarded 内还原
// 回 0）。非命中零开销直接返回。此 hook 不在音频回调线程，允许文件 IO；全程 SEH + 判空防御不崩游戏。
TjsBinaryStream* __fastcall Detour_TVPCreateBinaryStream(const void* name, uint32_t mode) {
  TjsBinaryStream* stream = g_orig_TVPCreateStream(name, mode);
  if (g_header != nullptr) {
    g_header->reserved_luna |= 0x40000;  // diag: detour 触发过
  }
  if (g_capture_enabled && stream != nullptr && name != nullptr && g_header != nullptr) {
    wchar_t storage[520];
    if (ExtractStorageNameGuarded(name, storage, 520) && IsVoiceStorageName(storage)) {
      uint8_t* buf = nullptr;
      uint32_t buf_len = 0;
      if (ReadStreamAllGuarded(stream, &buf, &buf_len)) {
        WriteVoiceOgg(buf, buf_len, storage);
        free(buf);
        g_header->reserved_luna |= 0x80000;  // diag: 命中并 dump 过一个 voice OGG
      }
    }
  }
  return stream;
}

// 读主模块 VersionInfo 确认 KrkrZ（仅诊断，不门控——真正决策走 stub 反汇编模式自校验）。
void DetectKrkrVersionDiag() {
  if (g_header == nullptr) return;
  wchar_t path[MAX_PATH] = {0};
  if (GetModuleFileNameW(GetModuleHandleW(nullptr), path, MAX_PATH) == 0) return;
  DWORD handle = 0;
  const DWORD size = GetFileVersionInfoSizeW(path, &handle);
  if (size == 0) return;
  void* buf = malloc(size);
  if (buf == nullptr) return;
  if (GetFileVersionInfoW(path, handle, size, buf)) {
    const wchar_t* hay = static_cast<const wchar_t*>(buf);
    const size_t count = size / sizeof(wchar_t);
    auto has = [&](const wchar_t* needle) -> bool {
      const size_t nlen = wcslen(needle);
      if (nlen == 0 || count < nlen) return false;
      for (size_t i = 0; i + nlen <= count; i++) {
        if (memcmp(hay + i, needle, nlen * sizeof(wchar_t)) == 0) return true;
      }
      return false;
    };
    if (has(L"TVP(KIRIKIRI) Z core")) {
      g_header->reserved_luna |= 0x100000;  // diag: 版本确认 KrkrZ
    } else if (has(L"TVP(KIRIKIRI) 2 core")) {
      g_header->reserved_luna |= 0x200000;  // diag: 版本是 Krkr2
    }
  }
  free(buf);
}

// exe 直取路径：调 exe 导出的 TVPGetFunctionExporter（未加壳游戏最早、最简）。加壳 exe 不导出该符号时
// 置 0x1000000 返回 nullptr，改由 LoadLibrary→V2Link 兜底（见 InstallLoadLibraryHooks / HandleV2Link）。
ITVPFunctionExporter* ObtainExporter() {
  HMODULE exe = GetModuleHandleW(nullptr);
  if (exe == nullptr) return nullptr;
  auto getexp =
      reinterpret_cast<TVPGetFunctionExporter_t>(GetProcAddress(exe, "TVPGetFunctionExporter"));
  if (getexp == nullptr) {
    if (g_header != nullptr) g_header->reserved_luna |= 0x1000000;  // diag: exe 未导出该符号
    return nullptr;
  }
  __try {
    return getexp();
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return nullptr;
  }
}

// 幂等一次性安装：拿到 exporter（任一路径）后跑「导入 TVPCreateIStream + 反汇编定位内部
// TVPCreateStream + 装 detour」。InterlockedCompareExchange 保证 exe 直取 / V2Link 两条路径只跑一次。
void InstallVoiceStreamHookWithExporter(ITVPFunctionExporter* exporter) {
  if (exporter == nullptr) return;
  if (InterlockedCompareExchange(&g_voice_installed, 1, 0) != 0) return;  // 已装过，幂等

  DetectKrkrVersionDiag();  // 诊断版本（非门控）

  static const char* kSig = "IStream * ::TVPCreateIStream(const ttstr &,tjs_uint32)";
  const char* name = kSig;
  void* stub = nullptr;
  bool ok = false;
  __try {
    ok = exporter->QueryFunctionsByNarrowString(&name, &stub, 1);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    ok = false;
  }
  if (!ok || stub == nullptr) {
    if (g_header != nullptr) g_header->reserved_luna |= 0x400000;
    return;
  }

  bool is_bcb = false;
  uint8_t* call_istream = FindCallIStreamFromStub(static_cast<uint8_t*>(stub), &is_bcb);
  if (call_istream == nullptr) {
    if (g_header != nullptr) g_header->reserved_luna |= 0x400000;  // 定位失败
    return;
  }
  if (is_bcb) {
    // Krkr2(BCB, eax=name) 变体：MSVC __fastcall detour 不适用，安全跳过（用错约定会崩游戏）。
    if (g_header != nullptr) g_header->reserved_luna |= 0x800000;
    return;
  }
  uint8_t* mod_base = nullptr;
  uint32_t mod_size = 0;
  GetMainModuleRange(&mod_base, &mod_size);
  uint8_t* internal = FindInternalTVPCreateStream(call_istream, mod_base, mod_size);
  if (internal == nullptr) {
    if (g_header != nullptr) g_header->reserved_luna |= 0x400000;  // 定位失败
    return;
  }
  if (HookFn(internal, reinterpret_cast<void*>(&Detour_TVPCreateBinaryStream),
             reinterpret_cast<void**>(&g_orig_TVPCreateStream))) {
    if (g_header != nullptr) g_header->reserved_luna |= 0x20000;  // 内部函数定位成功并 hook
  }
}

// ── 加壳 exe 兜底：hook LoadLibrary → 截获插件 V2Link 拿 exporter ──────────────────────────────
// otomeki.exe 加壳、不导出 TVPGetFunctionExporter（真机 decdiag 0x1000000）。照 KrkrExtract
// InitHookWithDll(KrkrExtract.cpp:1667) + HookV2Link(Hook.cpp:1081) + XeV2Link(Hook.cpp:208)：hook
// LoadLibrary*，新加载的插件若导出 V2Link 就 hook 它；引擎随后调该 V2Link(exporter) 时，detour 里拿到
// exporter 完成一次性安装，再转发原 V2Link 保证插件正常初始化。CREATE_SUSPENDED 早注入时插件尚未加载，
// 正好由后续 LoadLibrary 触发（那时 exe 也已自解壳）。
typedef HRESULT(NTAPI* V2Link_t)(ITVPFunctionExporter*);
constexpr int kMaxV2Link = 4;  // 同时 hook 前几个导出 V2Link 的新插件（任一被调用即拿到单例 exporter）
V2Link_t g_v2link_orig[kMaxV2Link] = {nullptr};
void* g_v2link_targets[kMaxV2Link] = {nullptr};
int g_v2link_count = 0;

// V2Link detour 公共体：拿到 exporter → 置诊断 → 幂等安装 → 转发原 V2Link（不破坏插件初始化）。
HRESULT HandleV2Link(ITVPFunctionExporter* exporter, V2Link_t orig) {
  if (exporter != nullptr) {
    if (g_header != nullptr) g_header->reserved_luna |= 0x4000000;  // 经 V2Link 拿到 exporter
    InstallVoiceStreamHookWithExporter(exporter);                   // 幂等
  }
  if (orig != nullptr) return orig(exporter);
  return S_OK;
}

// 每个 hook 槽一个独立 detour（MinHook 共享 detour 无法区分各自 trampoline，故按 slot 展开）。
#define HIBIKI_V2LINK_DETOUR(i)                               \
  HRESULT NTAPI Detour_V2Link_##i(ITVPFunctionExporter* e) {  \
    return HandleV2Link(e, g_v2link_orig[i]);                 \
  }
HIBIKI_V2LINK_DETOUR(0)
HIBIKI_V2LINK_DETOUR(1)
HIBIKI_V2LINK_DETOUR(2)
HIBIKI_V2LINK_DETOUR(3)
void* const g_v2link_detours[kMaxV2Link] = {
    reinterpret_cast<void*>(&Detour_V2Link_0), reinterpret_cast<void*>(&Detour_V2Link_1),
    reinterpret_cast<void*>(&Detour_V2Link_2), reinterpret_cast<void*>(&Detour_V2Link_3),
};

// 新加载的模块若导出 V2Link 且未 hook 过就 hook 它（分配下一个 slot）。已完成安装后不再抓新 V2Link。
// 本函数在 LoadLibrary detour（loader lock 内）被调；MinHook 装 hook 只 VirtualProtect+改 5 字节 +
// 短暂 SuspendThread，不获取堆锁/不等待其它线程，loader lock 内低风险（与 KrkrExtract 同款时机）。
void MaybeHookModuleV2Link(HMODULE mod) {
  if (mod == nullptr || !g_cs_ready || g_voice_installed) return;
  FARPROC v2 = GetProcAddress(mod, "V2Link");
  if (v2 == nullptr) return;
  EnterCriticalSection(&g_cs);
  bool already = false;
  for (int i = 0; i < g_v2link_count; i++) {
    if (g_v2link_targets[i] == reinterpret_cast<void*>(v2)) {
      already = true;
      break;
    }
  }
  if (!already && g_v2link_count < kMaxV2Link) {
    const int slot = g_v2link_count;
    if (MH_CreateHook(reinterpret_cast<void*>(v2), g_v2link_detours[slot],
                      reinterpret_cast<void**>(&g_v2link_orig[slot])) == MH_OK &&
        MH_EnableHook(reinterpret_cast<void*>(v2)) == MH_OK) {
      g_v2link_targets[g_v2link_count++] = reinterpret_cast<void*>(v2);
    }
  }
  LeaveCriticalSection(&g_cs);
}

// LoadLibrary(W/ExW/A/ExA) detour：先调原函数拿 HMODULE，再看是否新插件的 V2Link 该 hook。
typedef HMODULE(WINAPI* LoadLibraryW_t)(LPCWSTR);
typedef HMODULE(WINAPI* LoadLibraryExW_t)(LPCWSTR, HANDLE, DWORD);
typedef HMODULE(WINAPI* LoadLibraryA_t)(LPCSTR);
typedef HMODULE(WINAPI* LoadLibraryExA_t)(LPCSTR, HANDLE, DWORD);
LoadLibraryW_t g_orig_LoadLibraryW = nullptr;
LoadLibraryExW_t g_orig_LoadLibraryExW = nullptr;
LoadLibraryA_t g_orig_LoadLibraryA = nullptr;
LoadLibraryExA_t g_orig_LoadLibraryExA = nullptr;

HMODULE WINAPI Detour_LoadLibraryW(LPCWSTR lib) {
  HMODULE m = g_orig_LoadLibraryW(lib);
  MaybeHookModuleV2Link(m);
  return m;
}
HMODULE WINAPI Detour_LoadLibraryExW(LPCWSTR lib, HANDLE file, DWORD flags) {
  HMODULE m = g_orig_LoadLibraryExW(lib, file, flags);
  MaybeHookModuleV2Link(m);
  return m;
}
HMODULE WINAPI Detour_LoadLibraryA(LPCSTR lib) {
  HMODULE m = g_orig_LoadLibraryA(lib);
  MaybeHookModuleV2Link(m);
  return m;
}
HMODULE WINAPI Detour_LoadLibraryExA(LPCSTR lib, HANDLE file, DWORD flags) {
  HMODULE m = g_orig_LoadLibraryExA(lib, file, flags);
  MaybeHookModuleV2Link(m);
  return m;
}

// 装 LoadLibrary hook（kernel32 早已加载）。四个导出各一份，用现有 HookFn（单函数、去重）。W/ExW 覆盖
// 引擎宽字符加载，A/ExA 兜住少数窄字符路径。任一装上即算就绪。
bool InstallLoadLibraryHooks() {
  HMODULE k = GetModuleHandleW(L"kernel32.dll");
  if (k == nullptr) return false;
  bool any = false;
  any |= HookFn(reinterpret_cast<void*>(GetProcAddress(k, "LoadLibraryW")),
                reinterpret_cast<void*>(&Detour_LoadLibraryW),
                reinterpret_cast<void**>(&g_orig_LoadLibraryW));
  any |= HookFn(reinterpret_cast<void*>(GetProcAddress(k, "LoadLibraryExW")),
                reinterpret_cast<void*>(&Detour_LoadLibraryExW),
                reinterpret_cast<void**>(&g_orig_LoadLibraryExW));
  any |= HookFn(reinterpret_cast<void*>(GetProcAddress(k, "LoadLibraryA")),
                reinterpret_cast<void*>(&Detour_LoadLibraryA),
                reinterpret_cast<void**>(&g_orig_LoadLibraryA));
  any |= HookFn(reinterpret_cast<void*>(GetProcAddress(k, "LoadLibraryExA")),
                reinterpret_cast<void*>(&Detour_LoadLibraryExA),
                reinterpret_cast<void**>(&g_orig_LoadLibraryExA));
  return any;
}

// 装 KiriKiriZ 语音流 hook。两条拿 exporter 的路径，幂等只安装一次：
//  ① exe 直取 TVPGetFunctionExporter（未加壳游戏更早可用；加壳返回 null，置 0x1000000）。
//  ② hook LoadLibrary → 插件 V2Link 兜底（对付加壳 exe，异步在游戏加载插件时完成）。
// LoadLibrary hook 装好即返回 true 停止轮询；真正安装可能稍后由 V2Link detour 异步触发。保活循环里
// exporter 迟迟没到不必强等——V2Link 会随游戏加载插件自动触发（30s 轮询窗口足够覆盖插件加载）。
bool TryHookKirikiriVoiceStream() {
  static bool ll_installed = false;

  if (!ll_installed) {
    if (InstallLoadLibraryHooks()) {
      ll_installed = true;
      if (g_header != nullptr) g_header->reserved_luna |= 0x2000000;  // LoadLibrary hook 已装
    }
  }

  if (!g_voice_installed) {
    ITVPFunctionExporter* exp = ObtainExporter();  // exe 直取（加壳置 0x1000000 返回 null）
    if (exp != nullptr) {
      if (g_header != nullptr) g_header->reserved_luna |= 0x10000;  // 经 exe 导出拿到 exporter
      InstallVoiceStreamHookWithExporter(exp);                      // 幂等
    }
  }

  return ll_installed;
}

#else  // !_M_IX86

// KiriKiriZ 是 32 位引擎；x64 构建此路径为空实现（仅保证两架构都能编译）。
bool TryHookKirikiriVoiceStream() { return true; }

#endif  // _M_IX86

// ══ C.2e Ren'Py / FFmpeg（libavcodec-54 / libavformat-54）纯人声捕获 ══════════════════
// Ren'Py（测试 Sakura Swim Club）音频经独立 DLL 解码：avformat-54.dll 打开输入流、
// avcodec-54.dll 解码。语音文件 url 常带 "voice" 或音频后缀（.ogg/.opus/.wav/.mp3…）。抓法与
// KiriKiriZ OGG 那条同出口（%TEMP%\hibiki_gal_voice 落盘），只是这里抓的是**解码后 PCM**（Ren'Py
// 不像 KiriKiri 有可 hook 的 wuvorbis/TVPCreateStream，只能落在 FFmpeg 解码链上）：
//   avformat_open_input(ps,url,…)        -> url 命中语音则把 *ps（AVFormatContext*）登记为语音 ctx
//   avformat_find_stream_info(ic,…)      -> 遍历 ic->streams[i]->codec（AVCodecContext*），读该音频
//                                           流 sample_rate/channels 缓存，并登记 avctx→ctx 关联
//   avcodec_decode_audio4(avctx,frame,…) -> avctx 命中语音关联 && *got_frame!=0 时，把 frame 解码
//                                           PCM（交织/planar 合并、统一转 16-bit）累积进该 ctx 缓冲
//   avformat_close_input / av_close_input_file -> 该 ctx 关闭时把累积 PCM 写成 WAV 落盘
//
// avctx↔语音 ctx 关联难点：AVCodecContext 不回指 AVFormatContext。解法＝在 find_stream_info 后遍历
// fmt_ctx->streams[i]->codec，把这些 avctx 记进 avctx→ctx 表；decode 里按 avctx 查表命中即取该 ctx
// 缓冲。sample_rate/channels 在 find_stream_info 时（结构里已填好）读一次并缓存，故 decode 热路径
// **不再触碰 AVCodecContext 偏移**（只读可信度高的 AVFrame 早段字段）。
//
// ── 手工结构偏移（最易错点；据 FFmpeg n1.0 = libavcodec 54.59.100 源码逐字段核算）────────────────
// 假设：目标 DLL 是**标准发行 FFmpeg 1.0**——LIBAVCODEC_VERSION_MAJOR=54 时全部 FF_API_* 废弃宏
// 判真，故那些"废弃"字段仍占位（共约 24 字节在 AVCodecContext.sample_rate 之前）。若目标 DLL 用
// -DFF_API_xxx=0 定制剥掉这些字段，sample_rate 会前移最多 24 字节（x86 落 412–436 / x64 落
// 456–480）——这是全组件最高风险数。故 sample_rate/channels 一律 sanity 校验（rate∈[8000,192000]、
// ch∈[1,8]），不过关即跳过该流（不落盘、绝不崩游戏）。AVFrame 早段（data/nb_samples/format）在
// 整个 lavc-54 区间稳定，可信度高。全部读结构处 SEH + 判空兜底。
// Ren'Py 的 python.exe 是 x86 —— x86 偏移为主目标；x64 仅为两架构编译对齐（lavc-54 x64 的 Ren'Py
// 基本不存在），x64 偏移可信度更低但不影响主路径。
#if defined(_M_IX86)
constexpr size_t kAvfDataOff = 0;          // AVFrame.data[0]
constexpr size_t kAvfExtDataOff = 64;      // AVFrame.extended_data
constexpr size_t kAvfNbSamplesOff = 76;    // AVFrame.nb_samples
constexpr size_t kAvfFormatOff = 80;       // AVFrame.format（enum AVSampleFormat）
constexpr size_t kAvcSampleRateOff = 436;  // AVCodecContext.sample_rate（高风险，见上）
constexpr size_t kAvcChannelsOff = 440;    // AVCodecContext.channels（高风险）
constexpr size_t kAvfmtNbStreamsOff = 24;  // AVFormatContext.nb_streams
constexpr size_t kAvfmtStreamsOff = 28;    // AVFormatContext.streams（AVStream**）
constexpr size_t kAvsCodecOff = 8;         // AVStream.codec（AVCodecContext*）
#else  // _M_X64
constexpr size_t kAvfDataOff = 0;
constexpr size_t kAvfExtDataOff = 96;
constexpr size_t kAvfNbSamplesOff = 112;
constexpr size_t kAvfFormatOff = 116;
constexpr size_t kAvcSampleRateOff = 480;
constexpr size_t kAvcChannelsOff = 484;
constexpr size_t kAvfmtNbStreamsOff = 44;
constexpr size_t kAvfmtStreamsOff = 48;
constexpr size_t kAvsCodecOff = 8;
#endif

// AVSampleFormat：0..4 交织（U8/S16/S32/FLT/DBL），5..9 planar（U8P/S16P/S32P/FLTP/DBLP），10=NB。
// planar 每声道一个平面（≤8 声道 data[c] 即平面，>8 走 extended_data）；交织全在 data[0]。

// FFmpeg 函数原型（Win32 x86 = __cdecl；x64 单一 ABI，__cdecl 被忽略无害）。不含 FFmpeg 头（版本
// 难对齐），全按 void* 透传，只在自家 detour 里按上面手工偏移解释结构。
typedef int(__cdecl* avformat_open_input_t)(void** ps, const char* url, void* fmt,
                                            void** options);
typedef int(__cdecl* avformat_find_stream_info_t)(void* ic, void** options);
typedef int(__cdecl* avcodec_decode_audio4_t)(void* avctx, void* frame,
                                              int* got_frame_ptr, const void* avpkt);
typedef void(__cdecl* avformat_close_input_t)(void** ps);
typedef void(__cdecl* av_close_input_file_t)(void* ctx);

avformat_open_input_t g_orig_avformat_open_input = nullptr;
avformat_find_stream_info_t g_orig_avformat_find_stream_info = nullptr;
avcodec_decode_audio4_t g_orig_avcodec_decode_audio4 = nullptr;
avformat_close_input_t g_orig_avformat_close_input = nullptr;
av_close_input_file_t g_orig_av_close_input_file = nullptr;

// 语音 AVFormatContext 表（定长，避堆分配；pcm 累积缓冲懒分配、close 落盘后释放）。
struct RenpyFmt {
  void* fmt_ctx;          // AVFormatContext*；nullptr=空槽
  uint32_t sample_rate;   // 该 ctx 音频流采样率（find_stream_info 缓存）
  uint32_t channels;      // 声道数
  uint8_t* pcm;           // 累积的 16-bit 交织 PCM（懒分配 kRenpyPcmCap）
  uint32_t pcm_len;       // 已累积字节
  uint32_t pcm_cap;       // 缓冲容量
  wchar_t basename[128];  // 落盘文件名（从 url 取；url 空则 renpy_<ctx低32位>）
};
// avctx→ctx 关联表（find_stream_info 建，decode 查）。
struct RenpyAvctx {
  void* avctx;   // AVCodecContext*；nullptr=空
  int fmt_slot;  // g_renpy_fmt 下标
};
constexpr int kMaxRenpyFmt = 64;
constexpr int kMaxRenpyAvctx = 128;
constexpr uint32_t kRenpyPcmCap = 8u * 1024u * 1024u;  // 单 ctx 累积上界（~43s 48k 立体声 16bit）
RenpyFmt g_renpy_fmt[kMaxRenpyFmt] = {};
RenpyAvctx g_renpy_avctx[kMaxRenpyAvctx] = {};
CRITICAL_SECTION g_renpy_cs;  // 专用锁：三表查改（非音频混音回调，短临界区）
bool g_renpy_cs_ready = false;

// 按前缀（小写）枚举已加载模块，命中返回其 HMODULE。用于 "avcodec-54.dll" 精确找不到时兜住命名
// 变体（仍限 major 54——偏移是 54 专属，别匹配到别的 major，否则用错偏移会读到垃圾）。
HMODULE FindLoadedModuleByPrefix(const wchar_t* prefix_lower) {
  HMODULE result = nullptr;
  HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32,
                                         GetCurrentProcessId());
  if (snap == INVALID_HANDLE_VALUE) return nullptr;
  MODULEENTRY32W me;
  me.dwSize = sizeof(me);
  const size_t plen = wcslen(prefix_lower);
  if (Module32FirstW(snap, &me)) {
    do {
      wchar_t name[MAX_MODULE_NAME32 + 1];
      int i = 0;
      for (; me.szModule[i] != 0 && i < MAX_MODULE_NAME32; i++) {
        wchar_t c = me.szModule[i];
        if (c >= L'A' && c <= L'Z') c = static_cast<wchar_t>(c - L'A' + L'a');
        name[i] = c;
      }
      name[i] = 0;
      if (wcsncmp(name, prefix_lower, plen) == 0) {
        result = me.hModule;
        break;
      }
    } while (Module32NextW(snap, &me));
  }
  CloseHandle(snap);
  return result;
}

// url（char*，UTF-8/本地编码）是否语音：小写后先排 BGM/SE/music/sound，再命中 "voice"/"vo_" 或音频
// 后缀。粗过滤即可——host 侧再按文本时间戳精配（与 KiriKiri OGG 同款「就近配对」）。
bool IsVoiceUrl(const char* url) {
  if (url == nullptr) return false;
  char low[520];
  size_t n = 0;
  for (; url[n] != 0 && n + 1 < 520; n++) {
    char c = url[n];
    if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
    low[n] = c;
  }
  low[n] = 0;
  if (n == 0) return false;
  if (strstr(low, "bgm") != nullptr || strstr(low, "music") != nullptr ||
      strstr(low, "sound") != nullptr || strstr(low, "/se/") != nullptr ||
      strstr(low, "\\se\\") != nullptr || strstr(low, "se_") != nullptr) {
    return false;  // 明显 BGM/环境音/音效
  }
  if (strstr(low, "voice") != nullptr || strstr(low, "/vo/") != nullptr ||
      strstr(low, "vo_") != nullptr) {
    return true;
  }
  static const char* kExts[] = {".ogg", ".opus", ".wav", ".mp3", ".wma", ".m4a", ".flac"};
  for (const char* e : kExts) {
    const size_t el = strlen(e);
    if (n >= el && strcmp(low + n - el, e) == 0) return true;
  }
  return false;
}

// 从 url 取净化后的 basename 存进定长缓冲（url 空则 renpy_<ctx低32位>）。非音频回调，允许 Win32 调用。
void MakeRenpyBaseName(const char* url, void* ctx, wchar_t* out, int out_cap) {
  out[0] = 0;
  wchar_t wide[520];
  int wn = 0;
  if (url != nullptr && url[0] != 0) {
    wn = MultiByteToWideChar(CP_UTF8, 0, url, -1, wide, 520);
    if (wn <= 0) wn = MultiByteToWideChar(CP_ACP, 0, url, -1, wide, 520);
  }
  if (wn <= 0) {
    const unsigned low =
        static_cast<unsigned>(reinterpret_cast<uintptr_t>(ctx) & 0xffffffffu);
    static const wchar_t kHex[] = L"0123456789abcdef";
    wchar_t tmp[16];
    int t = 0;
    tmp[t++] = L'r'; tmp[t++] = L'e'; tmp[t++] = L'n'; tmp[t++] = L'p'; tmp[t++] = L'y';
    tmp[t++] = L'_';
    for (int s = 28; s >= 0; s -= 4) tmp[t++] = kHex[(low >> s) & 0xfu];
    tmp[t] = 0;
    lstrcpynW(out, tmp, out_cap);
    return;
  }
  const int len = lstrlenW(wide);
  int pos = 0;
  for (int i = len; i > 0; i--) {
    if (wide[i - 1] == L'/' || wide[i - 1] == L'\\') {
      pos = i;
      break;
    }
  }
  int o = 0;
  for (int i = pos; wide[i] != 0 && o + 1 < out_cap; i++) {
    wchar_t c = wide[i];
    if (c == L':' || c == L'*' || c == L'?' || c == L'"' || c == L'<' || c == L'>' ||
        c == L'|') {
      c = L'_';
    }
    out[o++] = c;
  }
  out[o] = 0;
  if (o == 0) lstrcpynW(out, L"renpy", out_cap);
}

// 把累积的 16-bit 交织 PCM 写成 WAV。非热路径（close 时调一次），允许 std::wstring/文件 IO。
void WriteRenpyWav(const uint8_t* pcm, uint32_t len, uint32_t rate, uint32_t channels,
                   const wchar_t* basename) {
  if (pcm == nullptr || len == 0 || rate == 0 || channels == 0) return;
  wchar_t temp[MAX_PATH] = {0};
  const DWORD n = GetTempPathW(MAX_PATH, temp);
  if (n == 0 || n > MAX_PATH) return;
  std::wstring dir = std::wstring(temp) + L"hibiki_gal_voice";
  CreateDirectoryW(dir.c_str(), nullptr);  // 已存在则失败无害（与 KiriKiri OGG 同目录）
  std::wstring base =
      (basename != nullptr && basename[0] != 0) ? std::wstring(basename) : L"renpy";
  const size_t dot = base.find_last_of(L'.');
  if (dot != std::wstring::npos) base = base.substr(0, dot);  // 去原扩展名，统一 .wav
  if (base.empty()) base = L"renpy";
  std::wstring file =
      dir + L"\\" + std::to_wstring(GetTickCount64()) + L"_" + base + L".wav";
  HANDLE fh = CreateFileW(file.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                          FILE_ATTRIBUTE_NORMAL, nullptr);
  if (fh == INVALID_HANDLE_VALUE) return;
  uint8_t hdr[44];
  const uint32_t data_size = len;
  const uint32_t riff_size = 36u + data_size;
  const uint32_t fmt_size = 16u;
  const uint16_t audio_fmt = 1u;  // PCM
  const uint16_t ch16 = static_cast<uint16_t>(channels);
  const uint32_t byte_rate = rate * channels * 2u;
  const uint16_t block_align = static_cast<uint16_t>(channels * 2u);
  const uint16_t bits = 16u;
  memcpy(hdr + 0, "RIFF", 4);
  memcpy(hdr + 4, &riff_size, 4);
  memcpy(hdr + 8, "WAVE", 4);
  memcpy(hdr + 12, "fmt ", 4);
  memcpy(hdr + 16, &fmt_size, 4);
  memcpy(hdr + 20, &audio_fmt, 2);
  memcpy(hdr + 22, &ch16, 2);
  memcpy(hdr + 24, &rate, 4);
  memcpy(hdr + 28, &byte_rate, 4);
  memcpy(hdr + 32, &block_align, 2);
  memcpy(hdr + 34, &bits, 2);
  memcpy(hdr + 36, "data", 4);
  memcpy(hdr + 40, &data_size, 4);
  DWORD written = 0;
  WriteFile(fh, hdr, 44, &written, nullptr);
  uint32_t off = 0;
  while (off < len) {
    const uint32_t chunk = (len - off > 0x100000u) ? 0x100000u : (len - off);
    if (!WriteFile(fh, pcm + off, chunk, &written, nullptr) || written == 0) break;
    off += written;
  }
  CloseHandle(fh);
}

// SEH 守卫读 AVFormatContext 的流表，把每个音频流的 avctx（sample_rate/channels 合法）缓存进 slot +
// 登记 avctx→slot。只读结构、不调外部函数，纯 POD，可安全 __try。调用者持 g_renpy_cs。
void RenpyRegisterStreamsGuarded(void* ic, int slot) {
  __try {
    const unsigned nb = *reinterpret_cast<unsigned*>(
        reinterpret_cast<uint8_t*>(ic) + kAvfmtNbStreamsOff);
    void** streams = *reinterpret_cast<void***>(
        reinterpret_cast<uint8_t*>(ic) + kAvfmtStreamsOff);
    if (streams == nullptr || nb == 0 || nb > 64) return;
    for (unsigned i = 0; i < nb; i++) {
      void* st = streams[i];
      if (st == nullptr) continue;
      void* avctx =
          *reinterpret_cast<void**>(reinterpret_cast<uint8_t*>(st) + kAvsCodecOff);
      if (avctx == nullptr) continue;
      const int rate = *reinterpret_cast<int*>(
          reinterpret_cast<uint8_t*>(avctx) + kAvcSampleRateOff);
      const int ch = *reinterpret_cast<int*>(
          reinterpret_cast<uint8_t*>(avctx) + kAvcChannelsOff);
      if (rate < 8000 || rate > 192000 || ch < 1 || ch > 8) {
        continue;  // 非音频流 / 偏移不对 → 跳过（不误抓、不崩）
      }
      if (g_renpy_fmt[slot].sample_rate == 0) {
        g_renpy_fmt[slot].sample_rate = static_cast<uint32_t>(rate);
        g_renpy_fmt[slot].channels = static_cast<uint32_t>(ch);
      }
      for (int k = 0; k < kMaxRenpyAvctx; k++) {
        if (g_renpy_avctx[k].avctx == avctx) break;  // 已登记
        if (g_renpy_avctx[k].avctx == nullptr) {
          g_renpy_avctx[k].avctx = avctx;
          g_renpy_avctx[k].fmt_slot = slot;
          break;
        }
      }
      if (g_header != nullptr) g_header->reserved_luna |= 0x80000000u;  // diag: 登记语音 avctx
    }
  } __except (EXCEPTION_EXECUTE_HANDLER) {
  }
}

// SEH 守卫读 AVFrame 解码 PCM，转 16-bit 交织累积进 slot 缓冲。纯 POD + malloc，可安全 __try。
// 调用者持 g_renpy_cs。channels 用 slot 缓存值（find_stream_info 读到的真实声道），不再读 avctx。
void RenpyAppendFrameGuarded(RenpyFmt* f, void* frame) {
  __try {
    const int nb = *reinterpret_cast<int*>(
        reinterpret_cast<uint8_t*>(frame) + kAvfNbSamplesOff);
    const int fmt = *reinterpret_cast<int*>(
        reinterpret_cast<uint8_t*>(frame) + kAvfFormatOff);
    if (nb <= 0 || nb > (1 << 20)) return;
    if (fmt < 0 || fmt > 9) return;  // AV_SAMPLE_FMT_U8..DBLP
    const uint32_t ch = f->channels;
    if (ch < 1 || ch > 8) return;
    int bps = 0;
    bool planar = false;
    switch (fmt) {
      case 0: bps = 1; planar = false; break;  // U8
      case 1: bps = 2; planar = false; break;  // S16
      case 2: bps = 4; planar = false; break;  // S32
      case 3: bps = 4; planar = false; break;  // FLT
      case 4: bps = 8; planar = false; break;  // DBL
      case 5: bps = 1; planar = true; break;   // U8P
      case 6: bps = 2; planar = true; break;   // S16P
      case 7: bps = 4; planar = true; break;   // S32P
      case 8: bps = 4; planar = true; break;   // FLTP
      case 9: bps = 8; planar = true; break;   // DBLP
      default: return;
    }
    const size_t ptrsz = sizeof(void*);
    const uint8_t* planes[8] = {nullptr};
    if (planar) {
      const uint8_t** ext = *reinterpret_cast<const uint8_t***>(
          reinterpret_cast<uint8_t*>(frame) + kAvfExtDataOff);
      for (uint32_t c = 0; c < ch; c++) {
        const uint8_t* p = *reinterpret_cast<const uint8_t**>(
            reinterpret_cast<uint8_t*>(frame) + kAvfDataOff +
            static_cast<size_t>(c) * ptrsz);
        if (p == nullptr && ext != nullptr) p = ext[c];  // >8 声道走 extended_data
        if (p == nullptr) return;
        planes[c] = p;
      }
    } else {
      planes[0] = *reinterpret_cast<const uint8_t**>(
          reinterpret_cast<uint8_t*>(frame) + kAvfDataOff);
      if (planes[0] == nullptr) return;
    }
    if (f->pcm == nullptr) {
      f->pcm = static_cast<uint8_t*>(malloc(kRenpyPcmCap));
      if (f->pcm == nullptr) return;
      f->pcm_cap = kRenpyPcmCap;
      f->pcm_len = 0;
    }
    const uint32_t bytes_per_out_frame = ch * 2u;  // 16-bit 交织输出
    const uint32_t room_frames = (f->pcm_cap - f->pcm_len) / bytes_per_out_frame;
    if (room_frames == 0) return;  // 满（超长语音，防御性）；已积部分等 close 落盘
    uint32_t frames = static_cast<uint32_t>(nb);
    if (frames > room_frames) frames = room_frames;
    int16_t* out = reinterpret_cast<int16_t*>(f->pcm + f->pcm_len);
    for (uint32_t s = 0; s < frames; s++) {
      for (uint32_t c = 0; c < ch; c++) {
        const uint8_t* src = planar
                                 ? planes[c] + static_cast<size_t>(s) * bps
                                 : planes[0] + (static_cast<size_t>(s) * ch + c) * bps;
        int16_t v = 0;
        switch (fmt) {
          case 0:
          case 5: {  // U8 / U8P（无符号，中心 128）
            const uint8_t u = *src;
            v = static_cast<int16_t>((static_cast<int>(u) - 128) << 8);
            break;
          }
          case 1:
          case 6: {  // S16 / S16P
            v = *reinterpret_cast<const int16_t*>(src);
            break;
          }
          case 2:
          case 7: {  // S32 / S32P
            const int32_t x = *reinterpret_cast<const int32_t*>(src);
            v = static_cast<int16_t>(x >> 16);
            break;
          }
          case 3:
          case 8: {  // FLT / FLTP
            float fx = *reinterpret_cast<const float*>(src);
            if (fx > 1.0f) {
              fx = 1.0f;
            } else if (fx < -1.0f) {
              fx = -1.0f;
            }
            v = static_cast<int16_t>(fx * 32767.0f);
            break;
          }
          case 4:
          case 9: {  // DBL / DBLP
            double dx = *reinterpret_cast<const double*>(src);
            if (dx > 1.0) {
              dx = 1.0;
            } else if (dx < -1.0) {
              dx = -1.0;
            }
            v = static_cast<int16_t>(dx * 32767.0);
            break;
          }
          default:
            break;
        }
        *out++ = v;
      }
    }
    f->pcm_len += frames * bytes_per_out_frame;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
  }
}

// ctx 关闭：从表摘出该 ctx 的累积 PCM（持锁清槽 + 清关联），再在锁外落盘 + 释放（避免文件 IO 持锁）。
void RenpyCloseCtx(void* ctx) {
  if (ctx == nullptr || !g_renpy_cs_ready) return;
  uint8_t* pcm = nullptr;
  uint32_t len = 0, rate = 0, ch = 0;
  wchar_t base[128];
  base[0] = 0;
  EnterCriticalSection(&g_renpy_cs);
  for (int i = 0; i < kMaxRenpyFmt; i++) {
    if (g_renpy_fmt[i].fmt_ctx == ctx) {
      pcm = g_renpy_fmt[i].pcm;
      len = g_renpy_fmt[i].pcm_len;
      rate = g_renpy_fmt[i].sample_rate;
      ch = g_renpy_fmt[i].channels;
      lstrcpynW(base, g_renpy_fmt[i].basename, 128);
      g_renpy_fmt[i].fmt_ctx = nullptr;
      g_renpy_fmt[i].pcm = nullptr;
      g_renpy_fmt[i].pcm_len = 0;
      g_renpy_fmt[i].pcm_cap = 0;
      g_renpy_fmt[i].sample_rate = 0;
      g_renpy_fmt[i].channels = 0;
      g_renpy_fmt[i].basename[0] = 0;
      for (int k = 0; k < kMaxRenpyAvctx; k++) {
        if (g_renpy_avctx[k].avctx != nullptr && g_renpy_avctx[k].fmt_slot == i) {
          g_renpy_avctx[k].avctx = nullptr;
          g_renpy_avctx[k].fmt_slot = -1;
        }
      }
      break;
    }
  }
  LeaveCriticalSection(&g_renpy_cs);
  if (pcm != nullptr) {
    if (len > 0 && rate > 0 && ch > 0) {
      WriteRenpyWav(pcm, len, rate, ch, base);
      if (g_header != nullptr) g_header->reserved_luna |= 0x40000000;  // diag: 写出语音 WAV
    }
    free(pcm);
  }
}

// -- detour: avformat_open_input --（url 命中语音则登记 ctx；basename 供落盘命名）
int __cdecl Detour_avformat_open_input(void** ps, const char* url, void* fmt,
                                       void** options) {
  const int ret = g_orig_avformat_open_input(ps, url, fmt, options);
  if (ret == 0 && ps != nullptr && *ps != nullptr && g_capture_enabled &&
      g_renpy_cs_ready && IsVoiceUrl(url)) {
    void* ctx = *ps;
    wchar_t base[128];
    MakeRenpyBaseName(url, ctx, base, 128);
    EnterCriticalSection(&g_renpy_cs);
    int slot = -1;
    for (int i = 0; i < kMaxRenpyFmt; i++) {
      if (g_renpy_fmt[i].fmt_ctx == nullptr) {
        slot = i;
        break;
      }
    }
    if (slot >= 0) {
      g_renpy_fmt[slot].fmt_ctx = ctx;
      g_renpy_fmt[slot].sample_rate = 0;
      g_renpy_fmt[slot].channels = 0;
      g_renpy_fmt[slot].pcm = nullptr;
      g_renpy_fmt[slot].pcm_len = 0;
      g_renpy_fmt[slot].pcm_cap = 0;
      lstrcpynW(g_renpy_fmt[slot].basename, base, 128);
    }
    LeaveCriticalSection(&g_renpy_cs);
    if (g_header != nullptr) g_header->reserved_luna |= 0x10000000;  // diag: open_input 命中语音
  }
  // TODO（url 空/自定义 AVIOContext）：Ren'Py 若走内存 AVIOContext，url 可能为空，此处保守不登记
  // （不误抓 BGM）；后续可靠 decode 端音频时长/特征兜底识别语音 ctx（当前先按有 url 的做）。
  return ret;
}

// -- detour: avformat_find_stream_info --（流建好后遍历流表，登记语音 ctx 的音频 avctx + 格式）
int __cdecl Detour_avformat_find_stream_info(void* ic, void** options) {
  const int ret = g_orig_avformat_find_stream_info(ic, options);
  if (ic != nullptr && g_capture_enabled && g_renpy_cs_ready) {
    EnterCriticalSection(&g_renpy_cs);
    int slot = -1;
    for (int i = 0; i < kMaxRenpyFmt; i++) {
      if (g_renpy_fmt[i].fmt_ctx == ic) {
        slot = i;
        break;
      }
    }
    if (slot >= 0) RenpyRegisterStreamsGuarded(ic, slot);
    LeaveCriticalSection(&g_renpy_cs);
  }
  return ret;
}

// -- detour: avcodec_decode_audio4 --（avctx 命中语音关联且解出帧时累积其 PCM）
int __cdecl Detour_avcodec_decode_audio4(void* avctx, void* frame, int* got_frame_ptr,
                                         const void* avpkt) {
  const int ret = g_orig_avcodec_decode_audio4(avctx, frame, got_frame_ptr, avpkt);
  if (g_capture_enabled && g_renpy_cs_ready && avctx != nullptr && frame != nullptr &&
      got_frame_ptr != nullptr && *got_frame_ptr != 0) {
    EnterCriticalSection(&g_renpy_cs);
    int slot = -1;
    for (int k = 0; k < kMaxRenpyAvctx; k++) {
      if (g_renpy_avctx[k].avctx == avctx) {
        slot = g_renpy_avctx[k].fmt_slot;
        break;
      }
    }
    if (slot >= 0 && slot < kMaxRenpyFmt && g_renpy_fmt[slot].fmt_ctx != nullptr) {
      if (g_header != nullptr) {
        g_header->reserved_luna |= 0x20000000;  // diag: decode 命中语音 ctx
      }
      RenpyAppendFrameGuarded(&g_renpy_fmt[slot], frame);
    }
    LeaveCriticalSection(&g_renpy_cs);
  }
  return ret;
}

// -- detour: avformat_close_input（AVFormatContext**，会置 *ps=NULL）--
void __cdecl Detour_avformat_close_input(void** ps) {
  void* ctx = (ps != nullptr) ? *ps : nullptr;  // 原函数会释放并置空，先取出
  if (g_capture_enabled) RenpyCloseCtx(ctx);
  g_orig_avformat_close_input(ps);
}
// -- detour: av_close_input_file（旧 API，AVFormatContext* 直接传）--
void __cdecl Detour_av_close_input_file(void* ctx) {
  if (g_capture_enabled) RenpyCloseCtx(ctx);
  g_orig_av_close_input_file(ctx);
}

// 装 Ren'Py/FFmpeg 捕获 hook：avformat-54 的 open_input/find_stream_info/close_input(+av_close_input_file
// 旧 API 兜底) 与 avcodec-54 的 decode_audio4。DLL 名精确找不到再按 "avcodec-54"/"avformat-54" 前缀枚举
// （仍限 major 54）。未加载则跳过（非 Ren'Py 或注入时 FFmpeg 尚未载入）。幂等，静态标志各只装一次；
// HookWorker 保活循环反复调直到装齐（Ren'Py 运行中注入时 FFmpeg DLL 通常已就绪）。
bool TryHookRenpyAudio() {
  static bool avformat_done = false;
  static bool avcodec_done = false;
  if (!avformat_done) {
    HMODULE m = GetModuleHandleW(L"avformat-54.dll");
    if (m == nullptr) m = FindLoadedModuleByPrefix(L"avformat-54");
    if (m != nullptr) {
      HookFn(reinterpret_cast<void*>(GetProcAddress(m, "avformat_open_input")),
             reinterpret_cast<void*>(&Detour_avformat_open_input),
             reinterpret_cast<void**>(&g_orig_avformat_open_input));
      HookFn(reinterpret_cast<void*>(GetProcAddress(m, "avformat_find_stream_info")),
             reinterpret_cast<void*>(&Detour_avformat_find_stream_info),
             reinterpret_cast<void**>(&g_orig_avformat_find_stream_info));
      HookFn(reinterpret_cast<void*>(GetProcAddress(m, "avformat_close_input")),
             reinterpret_cast<void*>(&Detour_avformat_close_input),
             reinterpret_cast<void**>(&g_orig_avformat_close_input));
      HookFn(reinterpret_cast<void*>(GetProcAddress(m, "av_close_input_file")),
             reinterpret_cast<void*>(&Detour_av_close_input_file),
             reinterpret_cast<void**>(&g_orig_av_close_input_file));
      if (g_orig_avformat_open_input != nullptr) {
        avformat_done = true;
        if (g_header != nullptr) {
          g_header->reserved_luna |= 0x08000000;  // diag: avformat hook 装上
        }
      }
    }
  }
  if (!avcodec_done) {
    HMODULE m = GetModuleHandleW(L"avcodec-54.dll");
    if (m == nullptr) m = FindLoadedModuleByPrefix(L"avcodec-54");
    if (m != nullptr) {
      if (HookFn(reinterpret_cast<void*>(GetProcAddress(m, "avcodec_decode_audio4")),
                 reinterpret_cast<void*>(&Detour_avcodec_decode_audio4),
                 reinterpret_cast<void**>(&g_orig_avcodec_decode_audio4))) {
        avcodec_done = true;
        if (g_header != nullptr) {
          g_header->reserved_luna |= 0x08000000;  // diag: avcodec hook 装上
        }
      }
    }
  }
  return avformat_done && avcodec_done;
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
  // LunaHook（引擎精确、干净）一旦活跃，GDI 文本 hook 让位，不再写文本环——否则游戏为粗体/描边
  // 每字重画会让 GetGlyphOutlineW 累加出「ここのの」式伪影，与 LunaHook 干净行混在一起污染卡片。
  // GDI 仅在 LunaHook 覆盖不到的引擎（luna_active==0）时作兜底文本源。音频 hook 不看此标志。
  if (g_header->luna_active != 0) {
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
      InitializeCriticalSection(&g_dec_cs);
      g_dec_cs_ready = true;  // 解码器表锁须先于装解码 hook 就绪（detour 立即可能触发）。
      InitializeCriticalSection(&g_renpy_cs);
      g_renpy_cs_ready = true;  // Ren'Py 表锁须先于装 FFmpeg hook 就绪（detour 立即可能触发）。
      if (MH_Initialize() == MH_OK) {
        g_mh_init = true;
        g_capture_enabled = true;  // detour 上线（未加载时 hook 随后命中）。
        TryHookXAudio2Create();
        TryHookDirectSoundCreate();
        TryHookTextRender();          // v2：文本 hook（抓台词）。
        TryHookKirikiriDecoders();    // C.2c：KiriKiri 解码器级干净人声。
        TryHookKirikiriVoiceStream();  // C.2d：KiriKiriZ 原始语音 OGG 捕获。
        TryHookRenpyAudio();           // C.2e：Ren'Py/FFmpeg avcodec-54 纯人声捕获。
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

  // 承载捕获期间生命周期，保活到停机。前 ~30s 反复重试装 KiriKiri 解码器 hook——早期注入时
  // wuvorbis/wuopus 插件尚未加载，须等游戏启动后加载了插件再装（幂等，装齐即停止重试）。
  int dec_retry = 0;
  bool dec_ready = false;
  int voice_retry = 0;
  bool voice_ready = false;
  int renpy_retry = 0;
  bool renpy_ready = false;
  while (!g_stop) {
    if (!dec_ready && g_capture_enabled && dec_retry < 150) {
      dec_ready = TryHookKirikiriDecoders();
      dec_retry++;
    }
    if (!voice_ready && g_capture_enabled && voice_retry < 150) {
      voice_ready = TryHookKirikiriVoiceStream();
      voice_retry++;
    }
    if (!renpy_ready && g_capture_enabled && renpy_retry < 150) {
      renpy_ready = TryHookRenpyAudio();
      renpy_retry++;
    }
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
