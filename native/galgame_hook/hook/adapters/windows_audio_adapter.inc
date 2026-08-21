// P1 zero-behaviour-change split: included inside dll_main.cpp anonymous namespace.
// XAudio2 source voice 的格式按对象保存：同一游戏可同时创建 PCM、float 与 ADPCM voice，不能再
// 用「首个格式」解释所有 source。ADPCM 的 Submit 回调只抢一个预分配槽并 memcpy；解码、切
// PlayBegin/PlayLength 和发布 PCM 全部留给 HookWorker 的 Poll。
fushi_voice_hook::XAudioSourceFormatRegistry<512> g_xaudio_formats;

constexpr size_t kXAudioAdpcmJobCount = 4;
constexpr uint32_t kMaxXAudioAdpcmJobBytes = 8u * 1024u * 1024u;
struct XAudioAdpcmJob {
  volatile LONG state = 0;  // 0=free, 1=writing, 2=ready, 3=processing
  uint8_t* encoded = nullptr;
  uint32_t encoded_bytes = 0;
  uint32_t play_begin = 0;
  uint32_t play_length = 0;
  uint64_t source_ptr = 0;
  uint64_t submit_timestamp_ms = 0;
  uint64_t timestamp_ms = 0;
  fushi_voice_hook::XAudioSourceFormat format;
};
XAudioAdpcmJob g_xaudio_adpcm_jobs[kXAudioAdpcmJobCount];
volatile LONG g_xaudio_adpcm_queue_initialized = 0;

// SGRE preloads hundreds of one-shot ADPCM voices many seconds before Start.
// Decode promptly so the four callback-copy slots stay available, but publish
// VoiceClip only after the corresponding SourceVoice::Start supplies the real
// playback boundary used by Luna text pairing.
constexpr size_t kPendingXAudioClipCount = 1024;
constexpr uint64_t kPendingXAudioClipMaxAgeMs = 60000;
struct PendingXAudioClip {
  bool occupied = false;  // HookWorker is the sole reader/writer.
  uint32_t ring_offset = 0;
  uint32_t byte_len = 0;
  uint32_t sample_rate = 0;
  uint32_t channels = 0;
  uint64_t source_ptr = 0;
  uint64_t submit_timestamp_ms = 0;
  uint64_t total_at_write = 0;
};
PendingXAudioClip g_pending_xaudio_clips[kPendingXAudioClipCount];

bool InitializeXAudioAdpcmQueue() {
  if (InterlockedCompareExchange(&g_xaudio_adpcm_queue_initialized, 1, 0) !=
      0) {
    return true;
  }
  for (XAudioAdpcmJob& job : g_xaudio_adpcm_jobs) {
    job.encoded = static_cast<uint8_t*>(VirtualAlloc(
        nullptr, kMaxXAudioAdpcmJobBytes, MEM_COMMIT | MEM_RESERVE,
        PAGE_READWRITE));
    if (job.encoded == nullptr) {
      for (XAudioAdpcmJob& allocated : g_xaudio_adpcm_jobs) {
        if (allocated.encoded != nullptr) {
          VirtualFree(allocated.encoded, 0, MEM_RELEASE);
          allocated.encoded = nullptr;
        }
      }
      InterlockedExchange(&g_xaudio_adpcm_queue_initialized, 0);
      return false;
    }
  }
  return true;
}

void ShutdownXAudioAdpcmQueue() {
  if (InterlockedExchange(&g_xaudio_adpcm_queue_initialized, 0) == 0) return;
  for (XAudioAdpcmJob& job : g_xaudio_adpcm_jobs) {
    if (job.encoded != nullptr) {
      VirtualFree(job.encoded, 0, MEM_RELEASE);
      job.encoded = nullptr;
    }
    InterlockedExchange(&job.state, 0);
  }
}

bool EnqueueXAudioAdpcmJob(
    uint64_t source_ptr, const fushi_voice_hook::XAudioSourceFormat& format,
    const XAUDIO2_BUFFER* buffer) {
  if (buffer == nullptr || buffer->pAudioData == nullptr ||
      buffer->AudioBytes == 0 ||
      buffer->AudioBytes > kMaxXAudioAdpcmJobBytes ||
      InterlockedCompareExchange(&g_xaudio_adpcm_queue_initialized, 0, 0) ==
          0) {
    return false;
  }
  for (XAudioAdpcmJob& job : g_xaudio_adpcm_jobs) {
    if (InterlockedCompareExchange(&job.state, 1, 0) != 0) continue;
    job.format = format;
    job.source_ptr = source_ptr;
    job.submit_timestamp_ms = GetTickCount64();
    job.timestamp_ms = g_xaudio_formats.TimestampForSubmit(
        static_cast<uintptr_t>(source_ptr), job.submit_timestamp_ms);
    job.encoded_bytes = buffer->AudioBytes;
    job.play_begin = buffer->PlayBegin;
    job.play_length = buffer->PlayLength;
    memcpy(job.encoded, buffer->pAudioData, buffer->AudioBytes);
    InterlockedExchange(&job.state, 2);
    return true;
  }
  return false;
}

bool StorePendingXAudioClip(uint32_t ring_offset, uint32_t byte_len,
                           uint64_t source_ptr, uint32_t sample_rate,
                           uint32_t channels, uint64_t submit_timestamp_ms,
                           uint64_t total_at_write) {
  for (PendingXAudioClip& pending : g_pending_xaudio_clips) {
    if (pending.occupied) continue;
    pending.ring_offset = ring_offset;
    pending.byte_len = byte_len;
    pending.sample_rate = sample_rate;
    pending.channels = channels;
    pending.source_ptr = source_ptr;
    pending.submit_timestamp_ms = submit_timestamp_ms;
    pending.total_at_write = total_at_write;
    pending.occupied = true;
    return true;
  }
  return false;
}

void PublishStartedXAudioClips() {
  const uint64_t now = GetTickCount64();
  for (PendingXAudioClip& pending : g_pending_xaudio_clips) {
    if (!pending.occupied) continue;
    const uint64_t playback_timestamp =
        g_xaudio_formats.ResolvePlaybackTimestamp(
            static_cast<uintptr_t>(pending.source_ptr),
            pending.submit_timestamp_ms);
    if (playback_timestamp != 0) {
      RecordVoiceClipFmt(
          pending.ring_offset, pending.byte_len, pending.source_ptr,
          pending.sample_rate, pending.channels, 16, 0, playback_timestamp,
          pending.total_at_write);
      pending.occupied = false;
      continue;
    }
    if (now > pending.submit_timestamp_ms &&
        now - pending.submit_timestamp_ms > kPendingXAudioClipMaxAgeMs) {
      pending.occupied = false;
    }
  }
}

void ProcessPendingXAudioAdpcmJobs() {
  std::vector<int16_t> decoded;
  for (XAudioAdpcmJob& job : g_xaudio_adpcm_jobs) {
    if (InterlockedCompareExchange(&job.state, 3, 2) != 2) continue;
    const bool decoded_ok = fushi_voice_hook::DecodeMicrosoftAdpcm(
        job.format, job.encoded, job.encoded_bytes, &decoded);
    if (decoded_ok && job.format.channels != 0) {
      const uint64_t total_frames = decoded.size() / job.format.channels;
      const uint64_t begin = std::min<uint64_t>(job.play_begin, total_frames);
      const uint64_t available = total_frames - begin;
      const uint64_t frame_count =
          job.play_length == 0
              ? available
              : std::min<uint64_t>(job.play_length, available);
      const uint64_t byte_len =
          frame_count * job.format.channels * sizeof(int16_t);
      if (byte_len != 0 && byte_len <= g_ring_capacity &&
          byte_len <= std::numeric_limits<uint32_t>::max()) {
        MaybeRecordPcmFormat(job.format.sample_rate, job.format.channels, 16,
                             0);
        const auto* pcm = reinterpret_cast<const uint8_t*>(
            decoded.data() + begin * job.format.channels);
        const uint32_t length = static_cast<uint32_t>(byte_len);
        const uint32_t offset = RingAppendVoice(pcm, length);
        const uint64_t total_at_write =
            g_header == nullptr ? 0 : g_header->total_written;
        uint64_t playback_timestamp = job.timestamp_ms;
        if (playback_timestamp == 0) {
          playback_timestamp = g_xaudio_formats.ResolvePlaybackTimestamp(
              static_cast<uintptr_t>(job.source_ptr),
              job.submit_timestamp_ms);
        }
        if (playback_timestamp != 0) {
          RecordVoiceClipFmt(offset, length, job.source_ptr,
                             job.format.sample_rate, job.format.channels, 16,
                             0, playback_timestamp, total_at_write);
        } else {
          StorePendingXAudioClip(
              offset, length, job.source_ptr, job.format.sample_rate,
              job.format.channels, job.submit_timestamp_ms, total_at_write);
        }
        if (g_header != nullptr) {
          InterlockedOr(reinterpret_cast<volatile LONG*>(
                            &g_header->reserved_hook_diagnostics),
                        static_cast<LONG>(
                            fushi_voice_hook::kDiagXAudioAdpcmPcmCaptured));
        }
      }
    }
    InterlockedExchange(&job.state, 0);
  }
  PublishStartedXAudioClips();
}

HRESULT STDMETHODCALLTYPE Detour_SourceVoiceStart(IXAudio2SourceVoice* self,
                                                   UINT32 Flags,
                                                   UINT32 OperationSet) {
  const HRESULT hr = g_orig_SourceVoiceStart(self, Flags, OperationSet);
  if (SUCCEEDED(hr)) {
    g_xaudio_formats.MarkStarted(reinterpret_cast<uintptr_t>(self),
                                 GetTickCount64());
  }
  return hr;
}

HRESULT STDMETHODCALLTYPE Detour_SourceVoiceStop(IXAudio2SourceVoice* self,
                                                  UINT32 Flags,
                                                  UINT32 OperationSet) {
  const HRESULT hr = g_orig_SourceVoiceStop(self, Flags, OperationSet);
  if (SUCCEEDED(hr)) {
    g_xaudio_formats.MarkStopped(reinterpret_cast<uintptr_t>(self));
  }
  return hr;
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
    fushi_voice_hook::XAudioSourceFormat format;
    if (g_xaudio_formats.Lookup(reinterpret_cast<uintptr_t>(self), &format) &&
        format.encoding ==
            fushi_voice_hook::XAudioSourceEncoding::kMicrosoftAdpcm) {
      EnqueueXAudioAdpcmJob(reinterpret_cast<uint64_t>(self), format, pBuffer);
    } else if (format.encoding ==
                   fushi_voice_hook::XAudioSourceEncoding::kPcmInteger ||
               format.encoding ==
                   fushi_voice_hook::XAudioSourceEncoding::kPcmFloat) {
      const uint32_t ba = format.block_align;
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
          RecordVoiceClipFmt(
              off, static_cast<uint32_t>(len),
              reinterpret_cast<uint64_t>(self), format.sample_rate,
              format.channels, format.bits_per_sample,
              format.encoding ==
                      fushi_voice_hook::XAudioSourceEncoding::kPcmFloat
                  ? 1u
                  : 0u);
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
  fushi_voice_hook::XAudioSourceFormat format;
  const bool has_format =
      fushi_voice_hook::ParseXAudioSourceFormat(pSourceFormat, &format);
  const HRESULT hr = g_orig_CreateSourceVoice(
      self, ppSourceVoice, pSourceFormat, Flags, MaxFrequencyRatio, pCallback,
      pSendList, pEffectChain);
  if (SUCCEEDED(hr) && ppSourceVoice != nullptr && *ppSourceVoice != nullptr) {
    if (has_format && g_xaudio_formats.Register(
                          reinterpret_cast<uintptr_t>(*ppSourceVoice),
                          format)) {
      if (format.encoding ==
          fushi_voice_hook::XAudioSourceEncoding::kMicrosoftAdpcm) {
        if (g_header != nullptr) {
          InterlockedOr(reinterpret_cast<volatile LONG*>(
                            &g_header->reserved_hook_diagnostics),
                        static_cast<LONG>(
                            fushi_voice_hook::kDiagXAudioAdpcmObserved));
        }
      } else {
        MaybeRecordPcmFormat(
            format.sample_rate, format.channels, format.bits_per_sample,
            format.encoding ==
                    fushi_voice_hook::XAudioSourceEncoding::kPcmFloat
                ? 1u
                : 0u);
      }
    }
    HookFn(VtableSlot(*ppSourceVoice, kIdxSubmitSourceBuffer),
           reinterpret_cast<void*>(&Detour_SubmitSourceBuffer),
           reinterpret_cast<void**>(&g_orig_SubmitSourceBuffer));
    HookFn(VtableSlot(*ppSourceVoice, kIdxSourceVoiceStart),
           reinterpret_cast<void*>(&Detour_SourceVoiceStart),
           reinterpret_cast<void**>(&g_orig_SourceVoiceStart));
    HookFn(VtableSlot(*ppSourceVoice, kIdxSourceVoiceStop),
           reinterpret_cast<void*>(&Detour_SourceVoiceStop),
           reinterpret_cast<void**>(&g_orig_SourceVoiceStop));
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
    fushi_voice_hook::DirectSoundPcmFormat format;
    if (!g_dsound_formats.Lookup(reinterpret_cast<uintptr_t>(self), &format)) {
      return g_orig_DsbUnlock(self, pv1, cb1, pv2, cb2);
    }
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
      RecordVoiceClipFmt(off, seg_len, reinterpret_cast<uint64_t>(self),
                         format.sample_rate, format.channels,
                         format.bits_per_sample, format.is_float);
    }
  }
  return g_orig_DsbUnlock(self, pv1, cb1, pv2, cb2);
}

// SetFrequency 改变的是该 buffer 的实际播放采样率，WAVEFORMATEX 本身不会随之变化；格式表还
// 必须同步这个有效采样率，不能退回首个 buffer 的全局格式。
HRESULT STDMETHODCALLTYPE Detour_DsbSetFrequency(IDirectSoundBuffer* self,
                                                 DWORD frequency) {
  const HRESULT hr = g_orig_DsbSetFrequency(self, frequency);
  if (SUCCEEDED(hr)) {
    // DSBFREQUENCY_ORIGINAL == 0；registry 用 0 恢复创建时采样率。
    g_dsound_formats.SetFrequency(reinterpret_cast<uintptr_t>(self),
                                  static_cast<uint32_t>(frequency));
  }
  return hr;
}

// ── detour：IDirectSound8::CreateSoundBuffer（槽3）────────────────────────────
// 先调原函数建 buffer，成功后按两道门决定是否 hook 它的 Unlock：
//  ① 跳过主缓冲（DSBCAPS_PRIMARYBUFFER）：主缓冲是最终混音目标，抓它=抓混音不干净；只要
//     secondary（每个音单独的流）。
//  ② 记录每个 secondary 自己的格式，并跟踪 SetFrequency 的实际播放采样率。Unlock 的 vtable
//     实现由不同 buffer 共享，装一次 detour 后会命中所有 buffer，不能靠“只给同格式对象装 hook”
//     做对象级门控。共享环可混存不同格式，因为每条 VoiceClip 都携带独立格式；host 按 source
//     分组后再合成。
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
      MaybeRecordFormat(fmt);
      uint32_t is_float = 0;
      if (fmt->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
        is_float = 1;
      } else if (fmt->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
                 fmt->cbSize >=
                     sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
        const auto* ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(fmt);
        if (ext->SubFormat.Data1 == WAVE_FORMAT_IEEE_FLOAT) {
          is_float = 1;
        }
      }
      const fushi_voice_hook::DirectSoundPcmFormat format{
          fmt->nSamplesPerSec, fmt->nChannels, fmt->wBitsPerSample, is_float};
      if (g_dsound_formats.Register(
              reinterpret_cast<uintptr_t>(*ppBuf), format)) {
        HookFn(VtableSlot(*ppBuf, kIdxDsbSetFrequency),
               reinterpret_cast<void*>(&Detour_DsbSetFrequency),
               reinterpret_cast<void**>(&g_orig_DsbSetFrequency));
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

// SiglusEngine 1.1.x 不走 DirectSoundCreate(8) 导出，而是经 COM 创建 DirectSound 对象。
// 捕获 CLSID_DirectSound/CLSID_DirectSound8 的返回接口后，复用同一 CreateSoundBuffer vtable
// hook。这样既给 raw OVK 路径提供 status/混音兜底，也覆盖其它采用 COM 建 DS 的引擎。
constexpr GUID kClsidDirectSound = {
    0x47d4d946, 0x62e8, 0x11cf, {0x93, 0xbc, 0x44, 0x45, 0x53, 0x54, 0x00, 0x00}};
constexpr GUID kClsidDirectSound8 = {
    0x3901cc3f, 0x84b5, 0x4fa4, {0xba, 0x35, 0xaa, 0x81, 0x72, 0xb8, 0xa0, 0x9b}};

bool SameGuid(REFCLSID a, const GUID& b) {
  return memcmp(&a, &b, sizeof(GUID)) == 0;
}

HRESULT WINAPI Detour_CoCreateInstance(REFCLSID rclsid, LPUNKNOWN pUnkOuter,
                                        DWORD dwClsContext, REFIID riid,
                                        LPVOID* ppv) {
  const HRESULT hr = g_orig_CoCreateInstance(rclsid, pUnkOuter, dwClsContext,
                                              riid, ppv);
  if (SUCCEEDED(hr) && ppv != nullptr && *ppv != nullptr &&
      (SameGuid(rclsid, kClsidDirectSound) ||
       SameGuid(rclsid, kClsidDirectSound8))) {
    if (g_header != nullptr) {
      g_header->reserved_luna |= 0x08000000u;
    }
    HookCreateSoundBufferOn(*ppv);
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

  HMODULE ole = GetModuleHandleW(L"ole32.dll");
  if (ole == nullptr) {
    ole = LoadLibraryW(L"ole32.dll");
  }
  if (ole != nullptr) {
    HookFn(reinterpret_cast<void*>(GetProcAddress(ole, "CoCreateInstance")),
           reinterpret_cast<void*>(&Detour_CoCreateInstance),
           reinterpret_cast<void**>(&g_orig_CoCreateInstance));
  }
}
