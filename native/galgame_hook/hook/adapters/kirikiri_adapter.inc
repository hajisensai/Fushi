// P1 zero-behaviour-change split: included inside dll_main.cpp anonymous namespace.
#include <winhttp.h>
// ══ C.2c KiriKiri 解码器捕获链（引擎级干净人声）══════════════════════════════════
// XAudio2/DirectSound 抓的是**输出**（混音后各源），KiriKiriZ 的人声不走这两条（实测输出源全
// 是 BGM/SE）。人声在**解码环节**：KiriKiriZ 给每个正在播放的声音建一个独立解码器实例，语音是
// 台词播放时新建的短时解码器。故在解码后、混音前把每个解码器输出的纯 PCM 抓走——无 BGM 混音。
//
// wuvorbis.dll：libvorbisfile 风格封装（wu_ov_open_callbacks/wu_ov_info/wu_ov_read/
//   wu_ov_read_float/wu_ov_clear，dumpbin 确认）。wu_ov_read 返回 16-bit 交织 PCM
//   （word=2,sgned=1 时）；wu_ov_read_float 返回按声道分平面的 float PCM。
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

typedef size_t(__cdecl* MiniOvReadCallback)(void* ptr, size_t size, size_t nmemb,
                                            void* datasource);
typedef int(__cdecl* MiniOvSeekCallback)(void* datasource, int64_t offset, int whence);
typedef long(__cdecl* MiniOvTellCallback)(void* datasource);

constexpr uint32_t kMaxVoiceDumpBytes = 32u * 1024u * 1024u;

typedef int(__cdecl* wu_ov_open_callbacks_t)(void* datasource, void* vf,
                                             const char* initial, long ibytes,
                                             MiniOvCallbacks callbacks);
typedef void*(__cdecl* wu_ov_info_t)(void* vf, int link);
typedef long(__cdecl* wu_ov_read_t)(void* vf, char* buffer, int length,
                                    int bigendianp, int word, int sgned,
                                    int* bitstream);
typedef long(__cdecl* wu_ov_read_float_t)(void* vf, float*** pcm_channels,
                                          int samples, int* bitstream);
typedef int(__cdecl* wu_ov_clear_t)(void* vf);

// 原始 libopus（opus_int32 = int，opus_int16 = int16_t）。
typedef void*(__cdecl* opus_decoder_create_t)(int Fs, int channels, int* error);
typedef int(__cdecl* opus_decode_t)(void* st, const unsigned char* data, int len,
                                    int16_t* pcm, int frame_size, int decode_fec);
typedef void(__cdecl* opus_decoder_destroy_t)(void* st);

wu_ov_open_callbacks_t g_orig_wu_ov_open_callbacks = nullptr;
wu_ov_info_t g_orig_wu_ov_info = nullptr;  // 不 hook，只 GetProcAddress 直接调（读格式）
wu_ov_read_t g_orig_wu_ov_read = nullptr;
wu_ov_read_float_t g_orig_wu_ov_read_float = nullptr;
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

constexpr int kKirikiriVoiceTaskSlots = 8;
constexpr size_t kKirikiriStorageNameChars = 520;

struct KiriKiriVoicePairingContext {
  uint64_t resource_tick_ms = 0;
  uint64_t baseline_text_seq = 0;
  uint64_t selected_thread_id = 0;
};

struct KiriKiriVoiceTask {
  volatile LONG state = 0;  // 0=free, 1=producing, 2=pending, 3=consuming
  uint8_t* data = nullptr;
  uint32_t len = 0;
  KiriKiriVoicePairingContext pairing;
  wchar_t storage_name[kKirikiriStorageNameChars] = {};
};

KiriKiriVoiceTask g_kirikiri_voice_tasks[kKirikiriVoiceTaskSlots];

uint64_t ReadKirikiriSharedU64(volatile uint64_t* value) {
  return value == nullptr
             ? 0
             : static_cast<uint64_t>(InterlockedCompareExchange64(
                   reinterpret_cast<volatile LONGLONG*>(value), 0, 0));
}

KiriKiriVoicePairingContext CaptureKirikiriVoicePairingContext(
    bool stable_pairing_eligible) {
  KiriKiriVoicePairingContext context;
  context.resource_tick_ms = GetTickCount64();
  if (!stable_pairing_eligible || g_header == nullptr) return context;
  context.selected_thread_id =
      ReadKirikiriSharedU64(&g_header->selected_text_thread_id);
  if (context.selected_thread_id != 0) {
    context.baseline_text_seq =
        ReadKirikiriSharedU64(&g_header->text_write_count);
  }
  return context;
}

// Takes ownership of data on every path. The detour has already made one
// bounded copy while the engine stream is valid; disk IO and text association
// stay on HookWorker.
void EnqueueKirikiriVoiceResourceOwned(
    uint8_t* data, uint32_t len, const wchar_t* storage_name,
    const KiriKiriVoicePairingContext& pairing) {
  if (data == nullptr || len == 0) {
    free(data);
    return;
  }
  for (int i = 0; i < kKirikiriVoiceTaskSlots; ++i) {
    KiriKiriVoiceTask* task = &g_kirikiri_voice_tasks[i];
    if (InterlockedCompareExchange(&task->state, 1, 0) != 0) continue;
    task->data = data;
    task->len = len;
    task->pairing = pairing;
    wcsncpy_s(task->storage_name, kKirikiriStorageNameChars,
              storage_name == nullptr ? L"voice.ogg" : storage_name,
              _TRUNCATE);
    MemoryBarrier();
    InterlockedExchange(&task->state, 2);
    return;
  }
  free(data);
}

void ProcessKirikiriVoiceTasks() {
  for (int i = 0; i < kKirikiriVoiceTaskSlots; ++i) {
    KiriKiriVoiceTask* task = &g_kirikiri_voice_tasks[i];
    if (InterlockedCompareExchange(&task->state, 3, 2) != 2) continue;

    // 只扫一条道，候选上界就是道深（旧值 kTextSlotCount 现在是总槽数，放栈上会白占 20KB）。
    fushi_voice_hook::VoiceTextCandidate
        candidates[fushi_voice_hook::kTextLaneSlotCount] = {};
    size_t candidate_count = 0;
    uint64_t selected_thread_id = task->pairing.selected_thread_id;
    if (g_header == nullptr || g_text_base == nullptr ||
        ReadKirikiriSharedU64(&g_header->selected_text_thread_id) !=
            selected_thread_id) {
      selected_thread_id = 0;
    } else {
      // v13：文本按线程分道后，只扫**选定线程那一条道**。以前扫全局环是因为环里本来就只有
      // 选定线程的行；放开非胜出线程后再扫全局，等于把每条线程的行都读进候选数组（配对解析
      // 器仍会按 thread_id 过滤掉它们，但候选数组会先被别的线程刷爆，真候选被顶出去）。
      // 读取可以跨越写者分区——分区只约束**认领**，不约束读。
      fushi_voice_hook::TextLane* lanes =
          fushi_voice_hook::TextLanesOf(g_header);
      const uint32_t lane_count =
          lanes == nullptr ? 0 : g_header->text_lane_count;
      uint32_t lane_index = 0;
      bool lane_found = false;
      for (uint32_t i = 0; i < lane_count; ++i) {
        if (ReadKirikiriSharedU64(&lanes[i].thread_id) == selected_thread_id) {
          lane_index = i;
          lane_found = true;
          break;
        }
      }
      if (lane_found) {
        const uint64_t lane_written =
            ReadKirikiriSharedU64(&lanes[lane_index].write_count);
        const uint32_t lane_slots = g_header->text_lane_slot_count;
        uint64_t first_lane_seq =
            lane_written > lane_slots ? lane_written - lane_slots + 1 : 1;
        for (uint64_t lane_seq = first_lane_seq;
             lane_seq <= lane_written &&
             candidate_count < fushi_voice_hook::kTextLaneSlotCount;
             ++lane_seq) {
          auto* slot = reinterpret_cast<TextSlot*>(
              fushi_voice_hook::TextLaneSlotAt(g_header, lane_index,
                                                lane_seq));
          if (slot == nullptr) continue;
          if (ReadKirikiriSharedU64(&slot->lane_seq) != lane_seq) continue;
          MemoryBarrier();
          fushi_voice_hook::VoiceTextCandidate candidate;
          candidate.seq = ReadKirikiriSharedU64(&slot->seq);
          candidate.timestamp_ms = slot->timestamp_ms;
          candidate.thread_id = slot->thread_id;
          candidate.byte_len = slot->byte_len;
          candidate.is_line =
              slot->event_kind == fushi_voice_hook::kTextEventLine;
          MemoryBarrier();
          if (ReadKirikiriSharedU64(&slot->lane_seq) != lane_seq) continue;
          candidates[candidate_count++] = candidate;
        }
      }
    }

    const uint64_t deadline_ms =
        task->pairing.resource_tick_ms +
        fushi_voice_hook::kKirikiriFollowingTextWindowMs;
    const auto decision = fushi_voice_hook::ResolveFollowingSelectedText(
        task->pairing.resource_tick_ms, deadline_ms, GetTickCount64(),
        selected_thread_id, task->pairing.baseline_text_seq, candidates,
        candidate_count);
    if (decision.state ==
        fushi_voice_hook::VoiceResourcePairState::kWait) {
      InterlockedExchange(&task->state, 2);
      continue;
    }

    WriteVoiceOggAt(task->data, task->len, task->storage_name,
                    task->pairing.resource_tick_ms, decision.text_event_id);
    if (g_header != nullptr) {
      g_header->reserved_luna |= kDiagKirikiriVoiceStreamDumped;
    }
    free(task->data);
    task->data = nullptr;
    task->len = 0;
    task->pairing = {};
    task->storage_name[0] = 0;
    InterlockedExchange(&task->state, 0);
  }
}

void StopKirikiriVoiceTasks() {
  for (int i = 0; i < kKirikiriVoiceTaskSlots; ++i) {
    KiriKiriVoiceTask* task = &g_kirikiri_voice_tasks[i];
    if (InterlockedCompareExchange(&task->state, 3, 2) != 2) continue;
    free(task->data);
    task->data = nullptr;
    task->len = 0;
    task->pairing = {};
    task->storage_name[0] = 0;
    InterlockedExchange(&task->state, 0);
  }
}

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

// 在 libvorbisfile 接管 datasource 前，经它提供的标准 C read/seek/tell 回调复制完整原始 Ogg。
// 这是 KiriKiri2/BCB 最稳定的解密后边界：不解析 BCB C++ stream/vtable，且每个解码器仍是混音前
// 的独立资源。不可 seek、超限、短读或不是 OggS 时直接放弃，不影响游戏原调用。
void DumpVorbisDatasourceGuarded(void* datasource, void* vf, MiniOvCallbacks callbacks) {
  if (!g_capture_enabled || g_header == nullptr || datasource == nullptr ||
      callbacks.read_func == nullptr || callbacks.seek_func == nullptr ||
      callbacks.tell_func == nullptr ||
      InterlockedCompareExchange(
          &fushi_voice_hook::g_qlie_profile_active, 0, 0) != 0) {
    return;
  }
  auto read_cb = reinterpret_cast<MiniOvReadCallback>(callbacks.read_func);
  auto seek_cb = reinterpret_cast<MiniOvSeekCallback>(callbacks.seek_func);
  auto tell_cb = reinterpret_cast<MiniOvTellCallback>(callbacks.tell_func);
  __try {
    const long original = tell_cb(datasource);
    if (original < 0 || seek_cb(datasource, 0, SEEK_END) != 0) return;
    const long end = tell_cb(datasource);
    if (end <= 0 || static_cast<uint32_t>(end) > kMaxVoiceDumpBytes) {
      seek_cb(datasource, original, SEEK_SET);
      return;
    }
    if (seek_cb(datasource, 0, SEEK_SET) != 0) {
      seek_cb(datasource, original, SEEK_SET);
      return;
    }

    const uint32_t size = static_cast<uint32_t>(end);
    uint8_t* buf = static_cast<uint8_t*>(malloc(size));
    if (buf == nullptr) {
      seek_cb(datasource, original, SEEK_SET);
      return;
    }
    const size_t got = read_cb(buf, 1, size, datasource);
    seek_cb(datasource, original, SEEK_SET);
    if (got == size && size >= 4 && memcmp(buf, "OggS", 4) == 0) {
      wchar_t source_name[80] = {};
      swprintf_s(source_name, L"kirikiri-vorbis-%p.ogg", vf);
      // Anonymous decoder opens can include BGM/SE. Keep them unmarked and
      // defer disk IO to HookWorker; only named voice storage may opt into a
      // stable selected-thread association.
      EnqueueKirikiriVoiceResourceOwned(
          buf, size, source_name,
          CaptureKirikiriVoicePairingContext(false));
      buf = nullptr;
      g_header->reserved_luna |= 0x40000;  // callback observed
    }
    free(buf);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return;
  }
}

// -- detour: wu_ov_open_callbacks --（建解码流 -> 原始 Ogg + 登记句柄 + 尝试拿格式）
int __cdecl Detour_wu_ov_open_callbacks(void* datasource, void* vf,
                                        const char* initial, long ibytes,
                                        MiniOvCallbacks callbacks) {
  DumpVorbisDatasourceGuarded(datasource, vf, callbacks);
  const int r = g_orig_wu_ov_open_callbacks(datasource, vf, initial, ibytes,
                                            callbacks);
  if (r == 0 && vf != nullptr) {
    if (InterlockedCompareExchange(
            &fushi_voice_hook::g_qlie_profile_active, 0, 0) != 0 &&
        g_header != nullptr) {
      g_header->reserved_hook_diagnostics |=
          fushi_voice_hook::kDiagQlieVorbisOpenObserved;
    }
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
      if (InterlockedCompareExchange(
              &fushi_voice_hook::g_qlie_profile_active, 0, 0) != 0) {
        g_header->reserved_hook_diagnostics |=
            fushi_voice_hook::kDiagQlieVorbisPcmCaptured;
      }
    }
  }
  return ret;
}

// -- detour: wu_ov_read_float --
// QLIE 的角色语音会走 libvorbisfile 的浮点接口。返回值是每声道样本数，pcm_channels 是
// planar float；用固定 thread_local 缓冲做有界的 16-bit 交织转换，避免音频线程堆分配/IO。
long __cdecl Detour_wu_ov_read_float(void* vf, float*** pcm_channels,
                                     int samples, int* bitstream) {
  const long ret =
      g_orig_wu_ov_read_float(vf, pcm_channels, samples, bitstream);
  if (!g_capture_enabled || g_header == nullptr || ret <= 0 ||
      pcm_channels == nullptr || *pcm_channels == nullptr) {
    return ret;
  }

  uint32_t rate = 0;
  uint32_t channels = 0;
  if (!DecoderGetFormat(vf, &rate, &channels) || rate == 0 || channels == 0 ||
      channels > 8) {
    return ret;
  }

  constexpr uint32_t kMaxInterleavedSamples = 16384;
  thread_local int16_t converted[kMaxInterleavedSamples];
  const uint32_t returned_frames = static_cast<uint32_t>(ret);
  const uint32_t frame_cap = kMaxInterleavedSamples / channels;
  float** planar = *pcm_channels;
  for (uint32_t first_frame = 0; first_frame < returned_frames;) {
    const uint32_t remaining = returned_frames - first_frame;
    const uint32_t frame_count =
        remaining < frame_cap ? remaining : frame_cap;
    __try {
      for (uint32_t frame = 0; frame < frame_count; ++frame) {
        for (uint32_t channel = 0; channel < channels; ++channel) {
          float value = planar[channel][first_frame + frame];
          if (value > 1.0f) value = 1.0f;
          if (value < -1.0f) value = -1.0f;
          converted[frame * channels + channel] =
              static_cast<int16_t>(value * 32767.0f);
        }
      }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
      return ret;
    }

    const uint32_t bytes = frame_count * channels * sizeof(int16_t);
    const uint32_t off =
        RingAppendVoice(reinterpret_cast<const uint8_t*>(converted), bytes);
    RecordVoiceClipFmt(off, bytes, reinterpret_cast<uint64_t>(vf), rate,
                       channels, 16, 0);
    first_frame += frame_count;
  }
  if (returned_frames != 0 &&
      InterlockedCompareExchange(
          &fushi_voice_hook::g_qlie_profile_active, 0, 0) != 0) {
    g_header->reserved_hook_diagnostics |=
        fushi_voice_hook::kDiagQlieVorbisFloatPcmCaptured;
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
      const bool open_ok = HookFn(
          reinterpret_cast<void*>(GetProcAddress(vorb, "wu_ov_open_callbacks")),
          reinterpret_cast<void*>(&Detour_wu_ov_open_callbacks),
          reinterpret_cast<void**>(&g_orig_wu_ov_open_callbacks));
      void* p_read = reinterpret_cast<void*>(GetProcAddress(vorb, "wu_ov_read"));
      const bool read_ok =
          HookFn(p_read, reinterpret_cast<void*>(&Detour_wu_ov_read),
                 reinterpret_cast<void**>(&g_orig_wu_ov_read));
      void* p_read_float =
          reinterpret_cast<void*>(GetProcAddress(vorb, "wu_ov_read_float"));
      const bool read_float_ok =
          HookFn(p_read_float,
                 reinterpret_cast<void*>(&Detour_wu_ov_read_float),
                 reinterpret_cast<void**>(&g_orig_wu_ov_read_float));
      if (g_header != nullptr) {
        g_header->reserved_luna |=
            (p_read == nullptr) ? 0x400 : (read_ok ? 0x100 : 0x200);
        if (open_ok &&
            InterlockedCompareExchange(
                &fushi_voice_hook::g_qlie_profile_active, 0, 0) == 0) {
          g_header->hook_diagnostics |=
              fushi_voice_hook::kDiagKirikiriVorbisOpenHookReady;
        }
        if (InterlockedCompareExchange(
                &fushi_voice_hook::g_qlie_profile_active, 0, 0) != 0 &&
            p_read_float != nullptr && read_float_ok) {
          g_header->reserved_hook_diagnostics |=
              fushi_voice_hook::kDiagQlieVorbisFloatHookReady;
        }
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
// 调用约定关键事实：KrkrZ 内部 TVPCreateStream 是 MSVC __fastcall(ecx=name, edx=mode)；Krkr2
// 则由 BCB 编译，寄存器约定是 eax=name, edx=mode。插件可见的 TVPCreateIStream 导入桩在两者中都
// 是稳定的 __stdcall ABI，并把 tTJSBinaryStream 包成标准 COM IStream。故 KrkrZ 保留更上游的内部
// TVPCreateStream hook；Krkr2 直接 hook 导入桩并读 IStream，避免跨编译器调用 BCB C++ 对象/vtable。

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
// 插件 SDK 的 TVPCreateIStream 导入桩：跨 MSVC/BCB 都是 __stdcall，返回标准 COM IStream。
typedef IStream*(__stdcall* TVPCreateIStreamStub_t)(const void* name, uint32_t mode);
// 内部 TVPCreateStream：KrkrZ = MSVC __fastcall(ecx=name(const ttstr&), edx=mode)，返回 tTJSBinaryStream*。
typedef TjsBinaryStream*(__fastcall* TVPCreateStream_t)(const void* name, uint32_t mode);

// KiriKiri 官方插件 ABI 的连续帧回调。V2Link 发生在 Plugins.link 的加载栈里，不能在那里重入
// TJS；先登记此回调，下一次引擎事件循环再在游戏主线程执行一次 bootstrap。
struct TvpContinuousEventCallback {
  virtual void __cdecl OnContinuousCallback(uint64_t tick) = 0;
};

// ttstr 在 x86 插件 ABI 中只有一个 tTJSVariantString*。字符串必须用引擎导出的分配/释放桩创建，
// 不能把 hook DLL 自己的 wchar_t 缓冲冒充成 ttstr（引用计数与长/短串所有权都属于 TJS）。
struct TjsString {
  TjsVariantString* ptr;
};

typedef TjsVariantString*(__stdcall* TJSAllocVariantStringStub_t)(const wchar_t* value);
typedef void(__stdcall* TJSVariantStringReleaseStub_t)(TjsVariantString* value);
typedef void(__stdcall* TVPExecuteScriptStub_t)(const TjsString& content, void* result);
typedef void(__stdcall* TVPAddContinuousEventHookStub_t)(TvpContinuousEventCallback* callback);
typedef void(__stdcall* TVPRemoveContinuousEventHookStub_t)(TvpContinuousEventCallback* callback);

TVPCreateIStreamStub_t g_orig_TVPCreateIStreamStub = nullptr;
TVPCreateStream_t g_orig_TVPCreateStream = nullptr;

TJSAllocVariantStringStub_t g_lookup_alloc_string = nullptr;
TJSVariantStringReleaseStub_t g_lookup_release_string = nullptr;
TVPExecuteScriptStub_t g_lookup_execute_script = nullptr;
TVPAddContinuousEventHookStub_t g_lookup_add_continuous = nullptr;
TVPRemoveContinuousEventHookStub_t g_lookup_remove_continuous = nullptr;
TjsVariantString* g_lookup_bootstrap_script = nullptr;
volatile LONG g_lookup_bootstrap_state = 0;  // 0=off, 1=registered, 2=running, 3=done
CRITICAL_SECTION g_lookup_response_cs;
bool g_lookup_response_cs_ready = false;
std::wstring g_lookup_response_script;
std::wstring g_lookup_request_path;
HANDLE g_lookup_worker = nullptr;

constexpr wchar_t kKirikiriLookupBootstrapScript[] = LR"TJS(
class FushiLookupHitLayer extends Layer
{
	var fushiLookupMessage;
	function FushiLookupHitLayer(owner, parent, message)
	{
		super.Layer(owner, parent);
		fushiLookupMessage = message;
	}
	function onMouseDown(x, y, button)
	{
		if(button == mbLeft) global.fushiLookupSubmit(fushiLookupMessage, x, y);
	}
	function onMouseMove(x, y)
	{
		var index = global.fushiLookupGlyphAt(fushiLookupMessage, x, y);
		if(index >= 0)
		{
			global.fushiLookupPaint(fushiLookupMessage, index, 1, 72);
		}
	}
}

if(typeof global.fushiLookupBootstrap == "undefined")
{
	global.fushiLookupBootstrap = function(tick)
	{
		if(typeof global.kag == "undefined" || global.kag === null) return;
		try
		{
			if(typeof global.fushiLookupCard == "undefined")
			{
				var owner = global.kag;
				var root = owner.primaryLayer.parent;
				var layer = new Layer(owner, root);
				owner.add(layer);
				layer.name = "Hibiki in-game dictionary";
				layer.fushiLookupIgnore = true;
				layer.setPos(64, 54);
				layer.setSize(760, 344);
				layer.type = ltAlpha;
				layer.absolute = 2147483000;
				layer.hitType = htMask;
				layer.hitThreshold = 256;
				layer.fillRect(0, 0, layer.width, layer.height, 0x071525);
				layer.colorRect(0, 0, 8, layer.height, 0x31d7ff, 255);
				layer.font.height = 28;
				layer.font.bold = true;
				layer.drawText(26, 14, "HIBIKI // IN-GAME LOOKUP", 0x31d7ff, 255, true);
				layer.font.height = 22;
				layer.font.bold = false;
				layer.drawText(26, 58, "Click a subtitle glyph, or press Shift over it", 0xffffff, 255, true);
				layer.drawText(26, 88, "Waiting for a subtitle lookup", 0xa7b8c9, 255, true);
				layer.visible = true;
				global.fushiLookupCard = layer;
			}

			global.fushiLookupRequestPath = "__FUSHI_REQUEST_PATH__";
			global.fushiLookupSequence = 0;
			global.fushiLookupPending = void;

			global.fushiLookupEnsureHighlight = function(message)
			{
				if(typeof message.fushiLookupAbsolute != "undefined")
				{
					if(typeof global.fushiLookupAbsoluteHighlight != "undefined")
					{
						global.fushiLookupAbsoluteHighlight.setPos(0, 0);
						global.fushiLookupAbsoluteHighlight.setSize(global.kag.primaryLayer.width,
							global.kag.primaryLayer.height);
						return global.fushiLookupAbsoluteHighlight;
					}
					var absoluteHighlight = new Layer(global.kag, global.kag.primaryLayer.parent);
					global.kag.add(absoluteHighlight);
					absoluteHighlight.name = "Hibiki absolute subtitle word highlight";
					absoluteHighlight.fushiLookupIgnore = true;
					absoluteHighlight.setPos(0, 0);
					absoluteHighlight.setSize(global.kag.primaryLayer.width, global.kag.primaryLayer.height);
					absoluteHighlight.type = ltAlpha;
					absoluteHighlight.absolute = 2147482000;
					absoluteHighlight.hitType = htMask;
					absoluteHighlight.hitThreshold = 256;
					absoluteHighlight.visible = true;
					global.fushiLookupAbsoluteHighlight = absoluteHighlight;
					return absoluteHighlight;
				}
				if(typeof message.fushiLookupHighlight != "undefined")
				{
					message.fushiLookupHighlight.setPos(message.imageLeft, message.imageTop);
					message.fushiLookupHighlight.setSize(message.imageWidth, message.imageHeight);
					return message.fushiLookupHighlight;
				}
				var hl = new FushiLookupHitLayer(global.kag, message, message);
				global.kag.add(hl);
				hl.name = "Hibiki subtitle word highlight";
				hl.fushiLookupIgnore = true;
				hl.setPos(message.imageLeft, message.imageTop);
				hl.setSize(message.imageWidth, message.imageHeight);
				hl.type = ltAlpha;
				hl.absolute = 2147482000;
				hl.hitType = htMask;
				hl.hitThreshold = 256;
				hl.visible = true;
				message.fushiLookupHighlight = hl;
				return hl;
			};

			global.fushiLookupGetGlyphs = function(message)
			{
				if(typeof message.fushiLookupLayerGlyphs != "undefined" &&
					message.fushiLookupLayerGlyphs.count > 0) return message.fushiLookupLayerGlyphs;
				if(typeof message.fushiLookupGlyphs != "undefined") return message.fushiLookupGlyphs;
				return void;
			};

			global.fushiLookupPaint = function(message, start, length, opacity)
			{
				var hl = global.fushiLookupEnsureHighlight(message);
				hl.fillRect(0, 0, hl.width, hl.height, 0);
				var glyphs = global.fushiLookupGetGlyphs(message);
				if(glyphs === void) return;
				var units = 0;
				var offsetX = typeof message.fushiLookupGlyphOffsetX == "undefined" ? 0 :
					message.fushiLookupGlyphOffsetX;
				var offsetY = typeof message.fushiLookupGlyphOffsetY == "undefined" ? 0 :
					message.fushiLookupGlyphOffsetY;
				for(var i = start; i < glyphs.count && units < length; i++)
				{
					var g = glyphs[i];
					hl.colorRect(g.x + offsetX, g.y + offsetY, g.w, g.h, 0x00d8ff, opacity);
					units += g.ch.length;
				}
			};

			global.fushiLookupGlyphAt = function(message, x, y)
			{
				var glyphs = global.fushiLookupGetGlyphs(message);
				if(glyphs === void) return -1;
				for(var i = glyphs.count - 1; i >= 0; i--)
				{
					var g = glyphs[i];
					if(x >= g.x && x < g.x + g.w && y >= g.y && y < g.y + g.h) return i;
				}
				return -1;
			};

			global.fushiLookupShowLoading = function(query)
			{
				var layer = global.fushiLookupCard;
				layer.fillRect(0, 0, layer.width, layer.height, 0x071525);
				layer.colorRect(0, 0, 8, layer.height, 0x31d7ff, 255);
				layer.font.bold = true; layer.font.height = 28;
				layer.drawText(26, 14, "HIBIKI // LOOKING UP", 0x31d7ff, 255, true);
				layer.font.bold = false; layer.font.height = 30;
				layer.drawText(26, 58, query, 0xffffff, 255, true);
				layer.font.height = 20;
				layer.drawText(26, 108, "Searching Hibiki dictionaries...", 0xa7b8c9, 255, true);
				layer.visible = true;
			};

			global.fushiLookupSubmit = function(message, x, y)
			{
				var index = global.fushiLookupGlyphAt(message, x, y);
				if(index < 0) return false;
				var glyphs = global.fushiLookupGetGlyphs(message);
				var query = "";
				for(var i = index; i < glyphs.count && query.length < 48; i++)
				{
					var ch = glyphs[i].ch;
					if(ch == "。" || ch == "、" || ch == "！" || ch == "？" || ch == "\n") break;
					query += ch;
				}
				if(query == "") return false;
				var id = ++global.fushiLookupSequence;
				global.fushiLookupPending = %[id:id, message:message, start:index, query:query];
				global.fushiLookupPaint(message, index, 1, 96);
				global.fushiLookupShowLoading(query);
				[id, query].save(global.fushiLookupRequestPath);
				return true;
			};

)TJS" LR"TJS(

			global.fushiLookupShowResult = function(id, expression, reading, dictionary, definition, bestLength)
			{
				var pending = global.fushiLookupPending;
				if(pending === void || pending.id != id) return;
				global.fushiLookupPaint(pending.message, pending.start, bestLength, 150);
				var layer = global.fushiLookupCard;
				layer.fillRect(0, 0, layer.width, layer.height, 0x071525);
				layer.colorRect(0, 0, 8, layer.height, 0x31d7ff, 255);
				layer.font.bold = true; layer.font.height = 26;
				layer.drawText(26, 12, "HIBIKI // LIVE LOOKUP", 0x31d7ff, 255, true);
				layer.font.height = 38;
				layer.drawText(26, 52, expression, 0xffffff, 255, true);
				layer.font.bold = false; layer.font.height = 22;
				layer.drawText(26, 98, reading, 0x65dfff, 255, true);
				layer.font.height = 17;
				layer.drawText(26, 132, dictionary, 0xa7b8c9, 255, true);
				layer.colorRect(26, 160, layer.width - 52, 2, 0x31d7ff, 210);
				layer.font.height = 20;
				var clean = definition.replace(/\r/g, "").replace(/\n+/g, " ");
				var line = 0;
				for(var pos = 0; pos < clean.length && line < 7; pos += 30, line++)
					layer.drawText(26, 178 + line * 23, clean.substr(pos, 30), 0xffffff, 255, true);
				layer.visible = true;
			};

			global.fushiLookupRecordGlyph = function(message, ch)
			{
				if(typeof message.fushiLookupGlyphs == "undefined") message.fushiLookupGlyphs = [];
				var glyphs = message.fushiLookupGlyphs;
				var cw = message.lineLayer.font.getTextWidth(ch) + message.pitch;
				var lx, ly, w, h;
				if(!message.vertical)
				{
					lx = message.lineLayerPos - cw; ly = message.lineLayerBase - message.fontSize;
					w = cw; h = message.fontSize;
				}
				else
				{
					lx = message.lineLayerBase - (message.fontSize >> 1); ly = message.lineLayerPos - cw;
					w = message.fontSize; h = cw;
				}
				var ox = message.lineLayerOriginX, oy = message.lineLayerOriginY;
				glyphs.add(%[ch:ch, lx:lx, ly:ly, w:w, h:h, ox:ox, oy:oy,
					x:message.lineLayer.left+lx, y:message.lineLayer.top+ly]);
				for(var i = glyphs.count - 1; i >= 0; i--)
				{
					var g = glyphs[i];
					if(g.ox != ox || g.oy != oy) break;
					g.x = message.lineLayer.left + g.lx;
					g.y = message.lineLayer.top + g.ly;
				}
			};

			global.fushiLookupLayerRegistry = [];
			global.fushiLookupLayerRunSequence = 0;
			global.fushiLookupLayerGlyphSequence = 0;
			global.fushiLookupLayerDrawCount = 0;
			global.fushiLookupLayerLastText = "";

			global.fushiLookupTextHasJapanese = function(text)
			{
				return typeof text == "String" && /[\u3000-\u30ff\u3400-\u9fff\uff00-\uffef]/.test(text);
			};

			global.fushiLookupRemoveLayerGlyphs = function(layer, x, y, w, h)
			{
				if(typeof layer.fushiLookupLayerGlyphs == "undefined" || w <= 0 || h <= 0) return;
				var kept = [];
				var glyphs = layer.fushiLookupLayerGlyphs;
				for(var i = 0; i < glyphs.count; i++)
				{
					var g = glyphs[i];
					if(g.x + g.w <= x || g.y + g.h <= y || g.x >= x + w || g.y >= y + h)
						kept.add(g);
				}
				layer.fushiLookupLayerGlyphs = kept;
			};

			global.fushiLookupCaptureLayerText = function(layer, x, y, text)
			{
				if(typeof layer.fushiLookupIgnore != "undefined" ||
					!global.fushiLookupTextHasJapanese(text)) return;
				var angle = layer.font.angle;
				if(angle != 0 && angle != 2700) return;
				if(typeof layer.fushiLookupLayerGlyphs == "undefined") layer.fushiLookupLayerGlyphs = [];
				if(typeof layer.fushiLookupLayerRegistered == "undefined")
				{
					layer.fushiLookupLayerRegistered = true;
					global.fushiLookupLayerRegistry.add(layer);
				}
				var height = Math.abs(layer.font.height);
				if(height < 1) height = 1;
				var total = layer.font.getTextWidth(text);
				if(angle == 0)
					global.fushiLookupRemoveLayerGlyphs(layer, x, y, total, height);
				else
					global.fushiLookupRemoveLayerGlyphs(layer, x - height, y, height, total);
				var run = ++global.fushiLookupLayerRunSequence;
				for(var i = 0; i < text.length; i++)
				{
					var ch = text.charAt(i);
					var begin = layer.font.getTextWidth(text.substr(0, i));
					var finish = layer.font.getTextWidth(text.substr(0, i + 1));
					var advance = finish - begin;
					if(advance < 1) advance = 1;
					var gx, gy, gw, gh;
					if(angle == 0)
					{
						gx = x + begin; gy = y; gw = advance; gh = height;
					}
					else
					{
						gx = x - height; gy = y + begin; gw = height; gh = advance;
					}
					layer.fushiLookupLayerGlyphs.add(%[ch:ch, x:gx, y:gy, w:gw, h:gh,
						run:run, seq:++global.fushiLookupLayerGlyphSequence, angle:angle]);
				}
				global.fushiLookupLayerDrawCount++;
				global.fushiLookupLayerLastText = text;
			};

			global.fushiLookupOriginalLayerDrawText = global.Layer.drawText;
			global.Layer.drawText = function(x, y, text, color, opacity, antialiased)
			{
				var result = (global.fushiLookupOriginalLayerDrawText incontextof this)(...);
				global.fushiLookupCaptureLayerText(this, x, y, text);
				return result;
			};

			global.fushiLookupOriginalLayerFillRect = global.Layer.fillRect;
			global.Layer.fillRect = function(x, y, width, height, value)
			{
				var result = (global.fushiLookupOriginalLayerFillRect incontextof this)(...);
				if(typeof this.fushiLookupIgnore == "undefined" && this.face != dfProvince)
					global.fushiLookupRemoveLayerGlyphs(this, x, y, width, height);
				return result;
			};

)TJS" LR"TJS(

			global.fushiLookupTextRenderRegistry = [];
			global.fushiLookupTextRenderCaptureCount = 0;
			global.fushiLookupTextRenderLastMethod = "";
			global.fushiLookupTextRenderLastError = "";
			global.fushiLookupTextRenderPatchTrace = [];
			global.fushiLookupTextRenderActiveDraw = void;

			global.fushiLookupTextRenderValue = function(value, name, fallback)
			{
				try
				{
					var found = value[name];
					if(found !== void) return found;
				}
				catch(e) {}
				return fallback;
			};

			global.fushiLookupTextRenderDescribe = function(value)
			{
				var type = typeof value;
				if(type == "String") return value.substr(0, 80);
				if(type == "Integer" || type == "Real") return "" + value;
				return "<" + type + ">";
			};

			global.fushiLookupTextRenderSample = function(value)
			{
				var names = ["text", "x", "y", "cw", "size", "left", "top", "width", "height",
					"pos", "link", "linkName"];
				var sample = [];
				for(var i = 0; i < names.count; i++)
				{
					var found = global.fushiLookupTextRenderValue(value, names[i], void);
					if(found !== void) sample.add(names[i] + "=" +
						global.fushiLookupTextRenderDescribe(found));
				}
				return sample.join(",");
			};

			global.fushiLookupFindTextRenderTarget = function(renderer)
			{
				for(var registryIndex = 0;
					registryIndex < global.fushiLookupTextRenderRegistry.count; registryIndex++)
					if(global.fushiLookupTextRenderRegistry[registryIndex].renderer === renderer)
						return global.fushiLookupTextRenderRegistry[registryIndex];
				return void;
			};

			global.fushiLookupBindTextRenderOrigin = function(renderer, layer, originX, originY, source)
			{
				if(layer === void || layer === null || !isvalid layer ||
					(typeof originX != "Integer" && typeof originX != "Real") ||
					(typeof originY != "Integer" && typeof originY != "Real")) return;
				var target = global.fushiLookupFindTextRenderTarget(renderer);
				if(target === void) return;
				target.targetLayer = layer;
				target.originX = originX;
				target.originY = originY;
				target.originSource = source;
			};

			global.fushiLookupCaptureTextRender = function(renderer, method, a, b, c, d, e, f)
			{
				try
				{
					if(typeof renderer.getCharacters != "Object") return;
					var characters = (renderer.getCharacters incontextof renderer)(0, 0);
					if(characters === void || typeof characters.count == "undefined") return;
					var glyphs = [];
					for(var i = 0; i < characters.count; i++)
					{
						var character = characters[i];
						var text = global.fushiLookupTextRenderValue(character, "text", "");
						if(typeof text != "String" || text == "") continue;
						var x = global.fushiLookupTextRenderValue(character, "left",
							global.fushiLookupTextRenderValue(character, "x", void));
						var y = global.fushiLookupTextRenderValue(character, "top",
							global.fushiLookupTextRenderValue(character, "y", void));
						var width = global.fushiLookupTextRenderValue(character, "width",
							global.fushiLookupTextRenderValue(character, "cw", void));
						var height = global.fushiLookupTextRenderValue(character, "height",
							global.fushiLookupTextRenderValue(character, "size", void));
						if(x === void || y === void || width === void || height === void ||
							width <= 0 || height <= 0) continue;
						glyphs.add(%[ch:text, x:x, y:y, w:width, h:height, run:0, seq:i]);
					}

					var target = global.fushiLookupFindTextRenderTarget(renderer);
					if(target === void)
					{
						target = %[renderer:renderer, fushiLookupAbsolute:true,
							fushiLookupGlyphOffsetX:0, fushiLookupGlyphOffsetY:0];
						global.fushiLookupTextRenderRegistry.add(target);
					}
					target.fushiLookupLayerGlyphs = glyphs;
					target.characters = characters;
					target.method = method;
					target.capture = ++global.fushiLookupTextRenderCaptureCount;
					target.args = [global.fushiLookupTextRenderDescribe(a),
						global.fushiLookupTextRenderDescribe(b), global.fushiLookupTextRenderDescribe(c),
						global.fushiLookupTextRenderDescribe(d), global.fushiLookupTextRenderDescribe(e),
						global.fushiLookupTextRenderDescribe(f)];
					target.sample = characters.count > 0 ?
						global.fushiLookupTextRenderSample(characters[0]) : "";
					target.lastSample = characters.count > 0 ?
						global.fushiLookupTextRenderSample(characters[characters.count - 1]) : "";
					if(typeof global.fushiLookupTextRenderActiveDraw != "undefined" &&
						global.fushiLookupTextRenderActiveDraw !== void &&
						global.fushiLookupTextRenderActiveDraw.renderer === renderer)
						global.fushiLookupBindTextRenderOrigin(renderer,
							global.fushiLookupTextRenderActiveDraw.layer,
							global.fushiLookupTextRenderActiveDraw.originX,
							global.fushiLookupTextRenderActiveDraw.originY, "TextRender.draw");
					global.fushiLookupTextRenderLastTarget = target;
					global.fushiLookupTextRenderLastMethod = method;
				}
				catch(error)
				{
					global.fushiLookupTextRenderLastError = method + ":" + error.message;
				}
			};

)TJS" LR"TJS(

			try
			{
				global.fushiLookupTextRenderPatchTrace.add("TextRenderBase=" + typeof global.TextRenderBase);
				if(typeof global.TextRenderBase == "Object")
				{
					global.fushiLookupTextRenderPatchTrace.add("TextRenderBase.render=" +
						typeof global.TextRenderBase.render);
					if(typeof global.TextRenderBase.render == "Object")
					{
						global.fushiLookupOriginalTextRenderBaseRender = global.TextRenderBase.render;
						global.TextRenderBase.render = function(a, b, c, d, e, f)
						{
							var result = (global.fushiLookupOriginalTextRenderBaseRender incontextof this)(...);
							global.fushiLookupCaptureTextRender(this, "TextRenderBase.render",
								a, b, c, d, e, f);
							return result;
						};
					}
					global.fushiLookupTextRenderPatchTrace.add("TextRenderBase.done=" +
						typeof global.TextRenderBase.done);
					if(typeof global.TextRenderBase.done == "Object")
					{
						global.fushiLookupOriginalTextRenderBaseDone = global.TextRenderBase.done;
						global.TextRenderBase.done = function()
						{
							var result = (global.fushiLookupOriginalTextRenderBaseDone incontextof this)(...);
							global.fushiLookupCaptureTextRender(this, "TextRenderBase.done",
								void, void, void, void, void, void);
							return result;
						};
					}
				}
			}
			catch(error)
			{
				global.fushiLookupTextRenderPatchTrace.add("TextRenderBase!" + error.message);
			}

)TJS" LR"TJS(

			try
			{
				global.fushiLookupTextRenderPatchTrace.add("TextRender=" + typeof global.TextRender);
				if(typeof global.TextRender == "Object" && global.TextRender !== global.TextRenderBase)
				{
					global.fushiLookupTextRenderPatchTrace.add("TextRender.draw=" +
						typeof global.TextRender.draw);
					if(typeof global.TextRender.draw == "Object")
					{
						global.fushiLookupOriginalTextRenderDraw = global.TextRender.draw;
						global.TextRender.draw = function(layer, ox, oy, width, height, text,
							autoIndent, base)
						{
							var previous = typeof global.fushiLookupTextRenderActiveDraw == "undefined" ?
								void : global.fushiLookupTextRenderActiveDraw;
							global.fushiLookupTextRenderActiveDraw = %[
								renderer:this, layer:layer, originX:ox, originY:oy];
							var result;
							try
							{
								result = (global.fushiLookupOriginalTextRenderDraw incontextof this)(...);
							}
							catch(error)
							{
								global.fushiLookupTextRenderActiveDraw = previous;
								throw error;
							}
							global.fushiLookupTextRenderActiveDraw = previous;
							global.fushiLookupBindTextRenderOrigin(this, layer, ox, oy,
								"TextRender.draw");
							return result;
						};
					}
					global.fushiLookupTextRenderPatchTrace.add("TextRender.drawAll=" +
						typeof global.TextRender.drawAll);
					if(typeof global.TextRender.drawAll == "Object")
					{
						global.fushiLookupOriginalTextRenderDrawAll = global.TextRender.drawAll;
						global.TextRender.drawAll = function(layer, ox, oy)
						{
							var previous = typeof global.fushiLookupTextRenderActiveDraw == "undefined" ?
								void : global.fushiLookupTextRenderActiveDraw;
							global.fushiLookupTextRenderActiveDraw = %[
								renderer:this, layer:layer, originX:ox, originY:oy];
							var result;
							try
							{
								result = (global.fushiLookupOriginalTextRenderDrawAll incontextof this)(...);
							}
							catch(error)
							{
								global.fushiLookupTextRenderActiveDraw = previous;
								throw error;
							}
							global.fushiLookupTextRenderActiveDraw = previous;
							global.fushiLookupBindTextRenderOrigin(this, layer, ox, oy,
								"TextRender.drawAll");
							return result;
						};
					}
					global.fushiLookupTextRenderPatchTrace.add("TextRender.drawCh=" +
						typeof global.TextRender.drawCh);
					if(typeof global.TextRender.drawCh == "Object")
					{
						global.fushiLookupOriginalTextRenderDrawCh = global.TextRender.drawCh;
						global.TextRender.drawCh = function(layer, ox, oy, ch)
						{
							global.fushiLookupBindTextRenderOrigin(this, layer, ox, oy,
								"TextRender.drawCh");
							return (global.fushiLookupOriginalTextRenderDrawCh incontextof this)(...);
						};
					}
					global.fushiLookupTextRenderPatchTrace.add("TextRender.render=" +
						typeof global.TextRender.render);
					if(typeof global.TextRender.render == "Object")
					{
						global.fushiLookupOriginalTextRenderRender = global.TextRender.render;
						global.TextRender.render = function(a, b, c, d, e, f)
						{
							var result = (global.fushiLookupOriginalTextRenderRender incontextof this)(...);
							global.fushiLookupCaptureTextRender(this, "TextRender.render",
								a, b, c, d, e, f);
							return result;
						};
					}
					global.fushiLookupTextRenderPatchTrace.add("TextRender.done=" +
						typeof global.TextRender.done);
					if(typeof global.TextRender.done == "Object")
					{
						global.fushiLookupOriginalTextRenderDone = global.TextRender.done;
						global.TextRender.done = function()
						{
							var result = (global.fushiLookupOriginalTextRenderDone incontextof this)(...);
							global.fushiLookupCaptureTextRender(this, "TextRender.done",
								void, void, void, void, void, void);
							return result;
						};
					}
				}
			}
			catch(error)
			{
				global.fushiLookupTextRenderPatchTrace.add("TextRender!" + error.message);
			}

)TJS" LR"TJS(

			global.fushiLookupPatchMessage = function(message)
			{
				if(message === void || !isvalid message) return;
				if(typeof message.fushiLookupGlyphs == "undefined") message.fushiLookupGlyphs = [];
				if(typeof message.fushiLookupProcessChCount == "undefined") message.fushiLookupProcessChCount = 0;
				if(typeof message.fushiLookupLastCh == "undefined") message.fushiLookupLastCh = "";
				if(typeof message.processCh != "Object") return;
				if(typeof message.fushiLookupInstanceWrapperProcessCh != "undefined" &&
					message.processCh === message.fushiLookupInstanceWrapperProcessCh) return;
				message.fushiLookupInstancePatched = true;
				message.fushiLookupInstanceOriginalProcessCh = message.processCh;
				message.fushiLookupInstanceWrapperProcessCh = function(ch, steptime)
				{
					this.fushiLookupProcessChCount++;
					this.fushiLookupLastCh = ch;
					var result = (this.fushiLookupInstanceOriginalProcessCh incontextof this)(...);
					if(!result) global.fushiLookupRecordGlyph(this, ch);
					return result;
				} incontextof message;
				message.processCh = message.fushiLookupInstanceWrapperProcessCh;
				if(typeof message.clear == "Object" &&
					(typeof message.fushiLookupInstanceWrapperClear == "undefined" ||
					message.clear !== message.fushiLookupInstanceWrapperClear)
				)
				{
					message.fushiLookupInstanceOriginalClear = message.clear;
					message.fushiLookupInstanceWrapperClear = function(all)
					{
						this.fushiLookupGlyphs = [];
						if(typeof this.fushiLookupHighlight != "undefined")
							this.fushiLookupHighlight.fillRect(0, 0, this.fushiLookupHighlight.width,
								this.fushiLookupHighlight.height, 0);
						return (this.fushiLookupInstanceOriginalClear incontextof this)(...);
					} incontextof message;
					message.clear = message.fushiLookupInstanceWrapperClear;
				}
			};

			global.fushiLookupPatchAllMessages = function()
			{
				var pages = [global.kag.fore.messages, global.kag.back.messages];
				for(var page = 0; page < pages.count; page++)
					for(var message = 0; message < pages[page].count; message++)
						global.fushiLookupPatchMessage(pages[page][message]);
				if(typeof global.kag.current != "undefined" && global.kag.current !== void)
					global.fushiLookupPatchMessage(global.kag.current);
			};
			if(typeof global.kag.tagHandlers == "Object" &&
				typeof global.kag.tagHandlers.ch == "Object")
			{
				global.fushiLookupOriginalChHandler = global.kag.tagHandlers.ch;
				global.fushiLookupChHandler = function(elm)
				{
					if(typeof this.current != "undefined" && this.current !== void)
						global.fushiLookupPatchMessage(this.current);
					return (global.fushiLookupOriginalChHandler incontextof this)(...);
				} incontextof global.kag;
				global.kag.tagHandlers.ch = global.fushiLookupChHandler;
			}
			global.fushiLookupPatchAllMessages();
			global.fushiLookupRefreshMessages = function(tick)
			{
				try { global.fushiLookupPatchAllMessages(); } catch(e) {}
			};
			System.addContinuousHandler(global.fushiLookupRefreshMessages);

)TJS" LR"TJS(

			global.fushiLookupAtTextRenderRegistry = function(submit)
			{
				var primary = global.kag.primaryLayer;
				var cursorX = primary.cursorX - primary.imageLeft;
				var cursorY = primary.cursorY - primary.imageTop;
				global.fushiLookupLastTrace.add("textRender captures=" +
					global.fushiLookupTextRenderCaptureCount + " registry=" +
					global.fushiLookupTextRenderRegistry.count + " lastMethod=" +
					global.fushiLookupTextRenderLastMethod + " error=" +
					global.fushiLookupTextRenderLastError + " cursor=" + cursorX + "," + cursorY);

)TJS" LR"TJS(

				for(var patchIndex = 0;
					patchIndex < global.fushiLookupTextRenderPatchTrace.count; patchIndex++)
					global.fushiLookupLastTrace.add("textRenderPatch=" +
						global.fushiLookupTextRenderPatchTrace[patchIndex]);
				for(var registryIndex = global.fushiLookupTextRenderRegistry.count - 1;
					registryIndex >= 0; registryIndex--)
				{
					var target = global.fushiLookupTextRenderRegistry[registryIndex];
					var glyphs = target.fushiLookupLayerGlyphs;
					var targetLayer = global.fushiLookupTextRenderValue(target,
						"targetLayer", void);
					var originX = global.fushiLookupTextRenderValue(target, "originX", void);
					var originY = global.fushiLookupTextRenderValue(target, "originY", void);
					var originSource = global.fushiLookupTextRenderValue(target,
						"originSource", "unbound");
					var row = "textRender=" + registryIndex + " method=" + target.method +
						" capture=" + target.capture + " chars=" + target.characters.count +
						" glyphs=" + glyphs.count + " args=" + target.args.join("|") +
						" first={" + target.sample + "} last={" +
						target.lastSample + "}";
					if(glyphs.count > 0)
					{
						var first = glyphs[0], last = glyphs[glyphs.count - 1];
						row += " bounds=" + first.ch + "@" + first.x + "," + first.y + "," +
							first.w + "," + first.h + ".." + last.ch + "@" + last.x + "," +
							last.y + "," + last.w + "," + last.h;
					}
					if(targetLayer === void || targetLayer === null || !isvalid targetLayer ||
						originX === void || originY === void)
					{
						global.fushiLookupLastTrace.add(row + " origin=unbound");
						continue;
					}
					var layerX = targetLayer.cursorX - targetLayer.imageLeft;
					var layerY = targetLayer.cursorY - targetLayer.imageTop;
					var localX = layerX - originX;
					var localY = layerY - originY;
					var visible = global.fushiLookupLayerIsVisible(targetLayer);
					target.fushiLookupGlyphOffsetX = cursorX - layerX + originX;
					target.fushiLookupGlyphOffsetY = cursorY - layerY + originY;
					row += " origin=" + originSource + "@" + originX + "," + originY +
						" layerCursor=" + targetLayer.cursorX + "," + targetLayer.cursorY +
						" image=" + targetLayer.imageLeft + "," + targetLayer.imageTop +
						" local=" + localX + "," + localY + " visible=" + visible;
					global.fushiLookupLastTrace.add(row);
					if(!visible) continue;
					var index = global.fushiLookupGlyphAt(target, localX, localY);
					if(index < 0) continue;
					global.fushiLookupPaint(target, index, 1, 72);
					if(submit) return global.fushiLookupSubmit(target, localX, localY);
					return true;
				}
				return false;
			};

			global.fushiLookupLayerIsVisible = function(layer)
			{
				var current = layer;
				while(current !== void && current !== null && isvalid current)
				{
					if(!current.visible || current.opacity <= 0) return false;
					current = current.parent;
				}
				return true;
			};

			global.fushiLookupAtLayerRegistry = function(submit)
			{
				global.fushiLookupLastTrace.add("drawText=" + global.fushiLookupLayerDrawCount +
					" registry=" + global.fushiLookupLayerRegistry.count +
					" lastText=" + global.fushiLookupLayerLastText);
				for(var registryIndex = global.fushiLookupLayerRegistry.count - 1;
					registryIndex >= 0; registryIndex--)
				{
					var layer = global.fushiLookupLayerRegistry[registryIndex];
					if(layer === void || !isvalid layer ||
						typeof layer.fushiLookupLayerGlyphs == "undefined" ||
						layer.fushiLookupLayerGlyphs.count == 0) continue;
					var visible = global.fushiLookupLayerIsVisible(layer);
					var x = layer.cursorX - layer.imageLeft;
					var y = layer.cursorY - layer.imageTop;
					var glyphs = layer.fushiLookupLayerGlyphs;
					var last = glyphs[glyphs.count - 1];
					global.fushiLookupLastTrace.add("layer=" + registryIndex +
						" visible=" + visible + " cursor=" + layer.cursorX + "," + layer.cursorY +
						" image=" + layer.imageLeft + "," + layer.imageTop +
						" local=" + x + "," + y + " glyphs=" + glyphs.count +
						" last=" + last.ch + "@" + last.x + "," + last.y + "," + last.w + "," + last.h);
					if(!visible) continue;
					var index = global.fushiLookupGlyphAt(layer, x, y);
					if(index < 0) continue;
					global.fushiLookupPaint(layer, index, 1, 72);
					if(submit) return global.fushiLookupSubmit(layer, x, y);
					return true;
				}
				return false;
			};

			global.fushiLookupAtCursor = function(submit)
			{
				global.fushiLookupLastTrace = [];
				if(global.fushiLookupAtTextRenderRegistry(submit)) return true;
				if(global.fushiLookupAtLayerRegistry(submit)) return true;
				global.fushiLookupPatchAllMessages();
				var pages = [global.kag.fore.messages, global.kag.back.messages];
				var sawCurrent = false;
				for(var page = 0; page < pages.count; page++)
				{
					var messages = pages[page];
					for(var i = messages.count - 1; i >= 0; i--)
					{
						var message = messages[i];
						if(typeof message.fushiLookupGlyphs == "undefined") continue;
						var glyphs = message.fushiLookupGlyphs;
						var x = message.cursorX - message.imageLeft;
						var y = message.cursorY - message.imageTop;
						var isCurrent = typeof global.kag.current != "undefined" && global.kag.current === message;
						if(isCurrent) sawCurrent = true;
						var row = "page=" + page + " message=" + i +
							" visible=" + message.visible + " cursor=" + message.cursorX + "," + message.cursorY +
							" image=" + message.imageLeft + "," + message.imageTop +
							" local=" + x + "," + y + " glyphs=" + glyphs.count +
							" processCh=" + message.fushiLookupProcessChCount +
							" lastCh=" + message.fushiLookupLastCh + " current=" + isCurrent +
							" wrapped=" + (typeof message.fushiLookupInstanceWrapperProcessCh != "undefined" &&
								message.processCh === message.fushiLookupInstanceWrapperProcessCh);
						if(glyphs.count > 0)
						{
							var first = glyphs[0], last = glyphs[glyphs.count - 1];
							row += " first=" + first.x + "," + first.y + "," + first.w + "," + first.h +
								" last=" + last.x + "," + last.y + "," + last.w + "," + last.h;
						}
						global.fushiLookupLastTrace.add(row);
						var index = global.fushiLookupGlyphAt(message, x, y);
						if(index < 0) continue;
						global.fushiLookupPaint(message, index, 1, 72);
						if(submit) return global.fushiLookupSubmit(message, x, y);
						return true;
					}
				}
				if(global.fushiLookupLastTrace.count == 0) global.fushiLookupLastTrace.add("no-message");
				if(!sawCurrent && typeof global.kag.current != "undefined" && global.kag.current !== void)
				{
					var current = global.kag.current;
					global.fushiLookupLastTrace.add("current-outside-pages glyphs=" +
						(typeof current.fushiLookupGlyphs == "undefined" ? -1 : current.fushiLookupGlyphs.count) +
						" processCh=" + (typeof current.fushiLookupProcessChCount == "undefined" ? -1 : current.fushiLookupProcessChCount) +
						" lastCh=" + (typeof current.fushiLookupLastCh == "undefined" ? "" : current.fushiLookupLastCh));
				}
				return false;
			};

)TJS" LR"TJS(

			global.fushiLookupLeftClickHook = function()
			{
				var hit = global.fushiLookupAtCursor(true);
				try
				{
					var trace = ["leftClick", hit];
					for(var traceIndex = 0; traceIndex < global.fushiLookupLastTrace.count; traceIndex++)
						trace.add(global.fushiLookupLastTrace[traceIndex]);
					trace.save(global.fushiLookupRequestPath + ".trace");
				} catch(e) {}
				return hit;
			};
			global.fushiLookupMouseMoveHook = function(x, y)
			{
				global.fushiLookupAtCursor(false);
				return false;
			};
			global.fushiLookupKeyDownHook = function(key, shift)
			{
				if(key == VK_SHIFT) return global.fushiLookupAtCursor(true);
				return false;
			};
			global.kag.addHook("leftClick", global.fushiLookupLeftClickHook);
			global.kag.addHook("mouseMove", global.fushiLookupMouseMoveHook);
			global.kag.addHook("keyDown", global.fushiLookupKeyDownHook);

			global.fushiLookupOriginalProcessCh = global.MessageLayer.processCh;
			global.MessageLayer.processCh = function(ch, steptime)
			{
				var result = (global.fushiLookupOriginalProcessCh incontextof this)(...);
				if(!result && typeof this.fushiLookupInstancePatched == "undefined")
					global.fushiLookupRecordGlyph(this, ch);
				return result;
			} incontextof global.MessageLayer;

			global.fushiLookupOriginalClear = global.MessageLayer.clear;
			global.MessageLayer.clear = function(all)
			{
				this.fushiLookupGlyphs = [];
				if(typeof this.fushiLookupHighlight != "undefined")
					this.fushiLookupHighlight.fillRect(0, 0, this.fushiLookupHighlight.width, this.fushiLookupHighlight.height, 0);
				return (global.fushiLookupOriginalClear incontextof this)(...);
			} incontextof global.MessageLayer;

			global.fushiLookupOriginalMouseMove = global.MessageLayer.onMouseMove;
			global.MessageLayer.onMouseMove = function(x, y)
			{
				var localX = x - this.imageLeft, localY = y - this.imageTop;
				var index = global.fushiLookupGlyphAt(this, localX, localY);
				if(index >= 0)
				{
					global.fushiLookupPaint(this, index, 1, 72);
				}
				return (global.fushiLookupOriginalMouseMove incontextof this)(...);
			} incontextof global.MessageLayer;

			global.fushiLookupOriginalMouseDown = global.MessageLayer.onMouseDown;
			global.MessageLayer.onMouseDown = function(x, y, button)
			{
				if(button == mbLeft && global.fushiLookupSubmit(this, x - this.imageLeft, y - this.imageTop)) return;
				return (global.fushiLookupOriginalMouseDown incontextof this)(...);
			} incontextof global.MessageLayer;

			global.fushiLookupOriginalKeyDown = global.MessageLayer.onKeyDown;
			global.MessageLayer.onKeyDown = function(key, shift)
			{
				if(key == VK_SHIFT && global.fushiLookupSubmit(this, this.cursorX - this.imageLeft, this.cursorY - this.imageTop)) return;
				return (global.fushiLookupOriginalKeyDown incontextof this)(...);
			} incontextof global.MessageLayer;

			Debug.notice("[HibikiLookup] KAGEX glyph lookup installed");
			System.removeContinuousHandler(global.fushiLookupBootstrap);
			global.fushiLookupBootstrap = void;
		}
		catch(e)
		{
			Debug.notice("[HibikiLookup] install failed: " + e.message);
			System.removeContinuousHandler(global.fushiLookupBootstrap);
			global.fushiLookupBootstrap = void;
		}
	};
	System.addContinuousHandler(global.fushiLookupBootstrap);
}
)TJS";

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) return {};
  const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                                         static_cast<int>(value.size()), nullptr, 0);
  if (count <= 0) return {};
  std::wstring result(static_cast<size_t>(count), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), result.data(), count);
  return result;
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int count = WideCharToMultiByte(CP_UTF8, 0, value.data(),
                                        static_cast<int>(value.size()), nullptr, 0,
                                        nullptr, nullptr);
  if (count <= 0) return {};
  std::string result(static_cast<size_t>(count), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                      result.data(), count, nullptr, nullptr);
  return result;
}

std::wstring EscapeTjsString(const std::wstring& value) {
  std::wstring result;
  result.reserve(value.size() + 16);
  for (wchar_t ch : value) {
    switch (ch) {
      case L'\\': result += L"\\\\"; break;
      case L'\"': result += L"\\\""; break;
      case L'\r': result += L"\\r"; break;
      case L'\n': result += L"\\n"; break;
      case 0x2028: result += L" "; break;
      case 0x2029: result += L" "; break;
      default: result.push_back(ch); break;
    }
  }
  return result;
}

std::string EscapeJsonString(const std::string& value) {
  std::string result;
  result.reserve(value.size() + 16);
  static constexpr char hex[] = "0123456789abcdef";
  for (unsigned char ch : value) {
    switch (ch) {
      case '\\': result += "\\\\"; break;
      case '\"': result += "\\\""; break;
      case '\r': result += "\\r"; break;
      case '\n': result += "\\n"; break;
      case '\t': result += "\\t"; break;
      default:
        if (ch < 0x20) {
          result += "\\u00";
          result.push_back(hex[ch >> 4]);
          result.push_back(hex[ch & 15]);
        } else {
          result.push_back(static_cast<char>(ch));
        }
        break;
    }
  }
  return result;
}

void AppendUtf8CodePoint(std::string& output, uint32_t codepoint) {
  if (codepoint <= 0x7f) {
    output.push_back(static_cast<char>(codepoint));
  } else if (codepoint <= 0x7ff) {
    output.push_back(static_cast<char>(0xc0 | (codepoint >> 6)));
    output.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
  } else if (codepoint <= 0xffff) {
    output.push_back(static_cast<char>(0xe0 | (codepoint >> 12)));
    output.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3f)));
    output.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
  } else {
    output.push_back(static_cast<char>(0xf0 | (codepoint >> 18)));
    output.push_back(static_cast<char>(0x80 | ((codepoint >> 12) & 0x3f)));
    output.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3f)));
    output.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
  }
}

int JsonHex(char ch) {
  if (ch >= '0' && ch <= '9') return ch - '0';
  if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
  if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
  return -1;
}

bool ParseJsonString(const std::string& json, size_t quote, std::string* value,
                     size_t* next) {
  if (value == nullptr || quote >= json.size() || json[quote] != '\"') return false;
  value->clear();
  for (size_t i = quote + 1; i < json.size(); i++) {
    const char ch = json[i];
    if (ch == '\"') {
      if (next != nullptr) *next = i + 1;
      return true;
    }
    if (ch != '\\') {
      value->push_back(ch);
      continue;
    }
    if (++i >= json.size()) return false;
    switch (json[i]) {
      case '\"': value->push_back('\"'); break;
      case '\\': value->push_back('\\'); break;
      case '/': value->push_back('/'); break;
      case 'b': value->push_back('\b'); break;
      case 'f': value->push_back('\f'); break;
      case 'n': value->push_back('\n'); break;
      case 'r': value->push_back('\r'); break;
      case 't': value->push_back('\t'); break;
      case 'u': {
        if (i + 4 >= json.size()) return false;
        uint32_t codepoint = 0;
        for (int n = 0; n < 4; n++) {
          const int digit = JsonHex(json[++i]);
          if (digit < 0) return false;
          codepoint = (codepoint << 4) | static_cast<uint32_t>(digit);
        }
        AppendUtf8CodePoint(*value, codepoint);
        break;
      }
      default: return false;
    }
  }
  return false;
}

bool FindJsonStringField(const std::string& json, const char* key,
                         std::string* value, size_t start = 0,
                         size_t limit = std::string::npos) {
  const std::string needle = std::string("\"") + key + "\"";
  size_t pos = start;
  const size_t end = std::min(limit, json.size());
  while ((pos = json.find(needle, pos)) != std::string::npos && pos < end) {
    pos += needle.size();
    pos = json.find(':', pos);
    if (pos == std::string::npos || pos >= end) return false;
    pos++;
    while (pos < end && (json[pos] == ' ' || json[pos] == '\t' || json[pos] == '\r' ||
                          json[pos] == '\n')) pos++;
    if (pos < end && json[pos] == '\"') return ParseJsonString(json, pos, value, nullptr);
  }
  return false;
}

int FindJsonIntegerField(const std::string& json, const char* key, int fallback) {
  const std::string needle = std::string("\"") + key + "\"";
  size_t pos = json.find(needle);
  if (pos == std::string::npos) return fallback;
  pos = json.find(':', pos + needle.size());
  if (pos == std::string::npos) return fallback;
  while (++pos < json.size() && (json[pos] == ' ' || json[pos] == '\t')) {}
  int value = 0;
  bool any = false;
  while (pos < json.size() && json[pos] >= '0' && json[pos] <= '9') {
    any = true;
    value = value * 10 + (json[pos++] - '0');
  }
  return any ? value : fallback;
}

struct LookupDictionaryEntry {
  std::string word;
  std::string reading;
  std::string dictionary;
  std::string meaning;
};

bool ParseLookupResponse(const std::string& json, int* best_length,
                         LookupDictionaryEntry* selected) {
  if (best_length == nullptr || selected == nullptr) return false;
  *best_length = FindJsonIntegerField(json, "bestLength", 1);
  const size_t entries_key = json.find("\"entries\"");
  if (entries_key == std::string::npos) return false;
  size_t pos = json.find('[', entries_key);
  if (pos == std::string::npos) return false;
  LookupDictionaryEntry fallback;
  bool have_fallback = false;
  while (++pos < json.size()) {
    while (pos < json.size() && (json[pos] == ' ' || json[pos] == '\r' ||
                                 json[pos] == '\n' || json[pos] == ',')) pos++;
    if (pos >= json.size() || json[pos] == ']') break;
    if (json[pos] != '\"') return false;
    std::string encoded_entry;
    size_t next = pos;
    if (!ParseJsonString(json, pos, &encoded_entry, &next)) return false;
    LookupDictionaryEntry entry;
    FindJsonStringField(encoded_entry, "word", &entry.word);
    FindJsonStringField(encoded_entry, "reading", &entry.reading);
    FindJsonStringField(encoded_entry, "dictionaryName", &entry.dictionary);
    FindJsonStringField(encoded_entry, "meaning", &entry.meaning);
    if (!entry.word.empty() && !entry.dictionary.empty()) {
      if (!have_fallback) {
        fallback = entry;
        have_fallback = true;
      }
      if (entry.dictionary.find("Jitendex") != std::string::npos) {
        *selected = entry;
        return true;
      }
    }
    pos = next - 1;
  }
  if (have_fallback) *selected = fallback;
  return have_fallback;
}

std::string PlainLookupMeaning(const std::string& meaning) {
  const size_t glossary = meaning.find("glossary");
  const size_t start = glossary == std::string::npos ? 0 : glossary;
  size_t limit = meaning.find("extra-info", start);
  if (limit == std::string::npos) limit = meaning.size();
  std::vector<std::string> leaves;
  size_t pos = start;
  while (pos < limit && leaves.size() < 6) {
    const size_t key = meaning.find("\"content\"", pos);
    if (key == std::string::npos || key >= limit) break;
    const size_t colon = meaning.find(':', key + 9);
    if (colon == std::string::npos || colon >= limit) break;
    size_t quote = colon + 1;
    while (quote < limit && (meaning[quote] == ' ' || meaning[quote] == '\t')) quote++;
    std::string leaf;
    size_t next = quote + 1;
    if (quote < limit && meaning[quote] == '\"' &&
        ParseJsonString(meaning, quote, &leaf, &next) &&
        !leaf.empty() && leaf != "glossary" && leaf != "noun") {
      leaves.push_back(leaf);
    }
    pos = std::max(next, key + 9);
  }
  std::string result;
  for (size_t i = 0; i < leaves.size(); i++) {
    if (!result.empty()) result += "  ";
    result += std::to_string(i + 1) + ". " + leaves[i];
  }
  return result.empty() ? "Dictionary entry found" : result;
}

bool ReadLookupRequest(int* id, std::wstring* query) {
  if (id == nullptr || query == nullptr || g_lookup_request_path.empty()) return false;
  HANDLE file = CreateFileW(g_lookup_request_path.c_str(), GENERIC_READ,
                            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  const DWORD size = GetFileSize(file, nullptr);
  if (size == INVALID_FILE_SIZE || size == 0 || size > 64 * 1024) {
    CloseHandle(file);
    return false;
  }
  std::vector<uint8_t> bytes(size);
  DWORD read = 0;
  const bool ok = ReadFile(file, bytes.data(), size, &read, nullptr) != FALSE;
  CloseHandle(file);
  if (!ok || read != size) return false;
  std::wstring text;
  if (size >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) {
    const wchar_t* begin = reinterpret_cast<const wchar_t*>(bytes.data() + 2);
    text.assign(begin, begin + (size - 2) / sizeof(wchar_t));
  } else {
    size_t offset = size >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf ? 3 : 0;
    text = Utf8ToWide(std::string(reinterpret_cast<const char*>(bytes.data() + offset),
                                  size - offset));
  }
  const size_t newline = text.find_first_of(L"\r\n");
  if (newline == std::wstring::npos) return false;
  *id = _wtoi(text.substr(0, newline).c_str());
  const size_t query_start = text.find_first_not_of(L"\r\n", newline);
  if (*id <= 0 || query_start == std::wstring::npos) return false;
  *query = text.substr(query_start);
  while (!query->empty() && (query->back() == L'\r' || query->back() == L'\n' ||
                             query->back() == L'\0')) query->pop_back();
  return !query->empty();
}

bool PostLookupRequest(const std::wstring& query, std::string* response) {
  if (response == nullptr) return false;
  wchar_t port_text[16] = {};
  wchar_t token[256] = {};
  if (GetEnvironmentVariableW(L"FUSHI_KIRIKIRI_LOOKUP_PORT", port_text, 16) == 0 ||
      GetEnvironmentVariableW(L"FUSHI_KIRIKIRI_LOOKUP_TOKEN", token, 256) == 0) return false;
  const int port = _wtoi(port_text);
  if (port <= 0 || port > 65535) return false;
  HINTERNET session = WinHttpOpen(L"FushiKirikiriLookup/1.0",
                                  WINHTTP_ACCESS_TYPE_NO_PROXY,
                                  WINHTTP_NO_PROXY_NAME,
                                  WINHTTP_NO_PROXY_BYPASS, 0);
  if (session == nullptr) return false;
  WinHttpSetTimeouts(session, 1000, 1000, 2000, 5000);
  HINTERNET connection = WinHttpConnect(session, L"127.0.0.1",
                                        static_cast<INTERNET_PORT>(port), 0);
  HINTERNET request = connection == nullptr ? nullptr :
      WinHttpOpenRequest(connection, L"POST", L"/api/lookup/dictionary", nullptr,
                         WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, 0);
  bool ok = false;
  if (request != nullptr) {
    const std::wstring auth = std::wstring(L"Authorization: Bearer ") + token + L"\r\n" +
                              L"Content-Type: application/json\r\n";
    const std::string body = std::string("{\"term\":\"") +
        EscapeJsonString(WideToUtf8(query)) + "\",\"maximumTerms\":1,\"record\":false}";
    ok = WinHttpAddRequestHeaders(request, auth.c_str(), static_cast<DWORD>(-1),
                                  WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE) != FALSE &&
         WinHttpSendRequest(request, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                            const_cast<char*>(body.data()), static_cast<DWORD>(body.size()),
                            static_cast<DWORD>(body.size()), 0) != FALSE &&
         WinHttpReceiveResponse(request, nullptr) != FALSE;
    DWORD status = 0;
    DWORD status_size = sizeof(status);
    if (!ok || !WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE |
                                    WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX,
                                    &status, &status_size, WINHTTP_NO_HEADER_INDEX) || status != 200) {
      ok = false;
    }
    while (ok) {
      DWORD available = 0;
      if (!WinHttpQueryDataAvailable(request, &available)) { ok = false; break; }
      if (available == 0) break;
      const size_t old_size = response->size();
      response->resize(old_size + available);
      DWORD chunk = 0;
      if (!WinHttpReadData(request, response->data() + old_size, available, &chunk)) {
        ok = false; break;
      }
      response->resize(old_size + chunk);
      if (response->size() > 8 * 1024 * 1024) { ok = false; break; }
    }
  }
  if (request != nullptr) WinHttpCloseHandle(request);
  if (connection != nullptr) WinHttpCloseHandle(connection);
  WinHttpCloseHandle(session);
  SecureZeroMemory(token, sizeof(token));
  return ok;
}

void QueueLookupResultScript(int id, const LookupDictionaryEntry& entry,
                             int best_length) {
  const std::wstring word = EscapeTjsString(Utf8ToWide(entry.word));
  const std::wstring reading = EscapeTjsString(Utf8ToWide(entry.reading));
  const std::wstring dictionary = EscapeTjsString(Utf8ToWide(entry.dictionary));
  const std::wstring definition = EscapeTjsString(Utf8ToWide(PlainLookupMeaning(entry.meaning)));
  std::wstring script = L"if(typeof global.fushiLookupShowResult != \"undefined\") "
                        L"global.fushiLookupShowResult(";
  script += std::to_wstring(id) + L",\"" + word + L"\",\"" + reading + L"\",\"" +
            dictionary + L"\",\"" + definition + L"\"," +
            std::to_wstring(std::max(1, best_length)) + L");";
  EnterCriticalSection(&g_lookup_response_cs);
  g_lookup_response_script = std::move(script);
  LeaveCriticalSection(&g_lookup_response_cs);
}

DWORD WINAPI KiriKiriLookupWorker(void*) {
  int last_id = 0;
  while (!g_stop) {
    int id = 0;
    std::wstring query;
    if (ReadLookupRequest(&id, &query) && id != last_id) {
      last_id = id;
      std::string response;
      LookupDictionaryEntry entry;
      int best_length = 1;
      if (PostLookupRequest(query, &response) &&
          ParseLookupResponse(response, &best_length, &entry)) {
        QueueLookupResultScript(id, entry, best_length);
      } else {
        LookupDictionaryEntry error;
        error.word = WideToUtf8(query.substr(0, std::min<size_t>(query.size(), 24)));
        error.dictionary = "Hibiki lookup";
        error.meaning = "No dictionary result. Make sure Fushi dictionary service is running.";
        QueueLookupResultScript(id, error, 1);
      }
    }
    Sleep(50);
  }
  return 0;
}

class KiriKiriLookupResultCallback final : public TvpContinuousEventCallback {
 public:
  void __cdecl OnContinuousCallback(uint64_t) override {
    if (!g_lookup_response_cs_ready || g_lookup_execute_script == nullptr ||
        g_lookup_alloc_string == nullptr || g_lookup_release_string == nullptr) return;
    std::wstring script;
    EnterCriticalSection(&g_lookup_response_cs);
    script.swap(g_lookup_response_script);
    LeaveCriticalSection(&g_lookup_response_cs);
    if (script.empty()) return;
    TjsVariantString* value = nullptr;
    try {
      value = g_lookup_alloc_string(script.c_str());
      if (value != nullptr) {
        const TjsString content = {value};
        g_lookup_execute_script(content, nullptr);
      }
    } catch (...) {
    }
    if (value != nullptr) g_lookup_release_string(value);
  }
};

KiriKiriLookupResultCallback g_lookup_result_callback;

bool PrepareKirikiriLookupRequestPath() {
  wchar_t temp[MAX_PATH] = {};
  const DWORD length = GetTempPathW(MAX_PATH, temp);
  if (length == 0 || length >= MAX_PATH) return false;
  g_lookup_request_path = temp;
  g_lookup_request_path += L"fushi-kirikiri-lookup-" + std::to_wstring(GetCurrentProcessId()) + L".txt";
  DeleteFileW(g_lookup_request_path.c_str());
  return true;
}

std::wstring BuildKirikiriLookupBootstrapScript() {
  std::wstring script = kKirikiriLookupBootstrapScript;
  const std::wstring placeholder = L"__FUSHI_REQUEST_PATH__";
  const size_t pos = script.find(placeholder);
  if (pos != std::wstring::npos) {
    script.replace(pos, placeholder.size(), EscapeTjsString(g_lookup_request_path));
  }
  return script;
}

bool IsKirikiriLookupProbeRequested() {
  wchar_t value[8] = {};
  const DWORD length = GetEnvironmentVariableW(
      L"FUSHI_KIRIKIRI_NATIVE_LOOKUP_PROBE", value,
      static_cast<DWORD>(sizeof(value) / sizeof(value[0])));
  return length == 1 && value[0] == L'1';
}

class KiriKiriLookupBootstrapCallback final : public TvpContinuousEventCallback {
 public:
  void __cdecl OnContinuousCallback(uint64_t) override {
    if (InterlockedCompareExchange(&g_lookup_bootstrap_state, 2, 1) != 1) return;

    // 官方实现允许 continuous callback 在遍历时移除自身；先移除再执行，确保任何异常也不会形成
    // 每帧重试。TJS 内部另用 System.addContinuousHandler 等待 global.kag 这个真实生命周期条件。
    if (g_lookup_remove_continuous != nullptr) g_lookup_remove_continuous(this);

    TjsVariantString* script = g_lookup_bootstrap_script;
    g_lookup_bootstrap_script = nullptr;
    if (script != nullptr && g_lookup_execute_script != nullptr) {
      const TjsString content = {script};
      try {
        g_lookup_execute_script(content, nullptr);
      } catch (...) {
        // 插件 ABI 边界绝不能把 TJS/C++ 异常抛回游戏事件循环；脚本自身也有 TJS try/catch。
      }
    }
    if (script != nullptr && g_lookup_release_string != nullptr) {
      g_lookup_release_string(script);
    }
    InterlockedExchange(&g_lookup_bootstrap_state, 3);
  }
};

KiriKiriLookupBootstrapCallback g_lookup_bootstrap_callback;

bool QueryKirikiriNativeLookupFunctions(ITVPFunctionExporter* exporter,
                                        const char** names, void** functions,
                                        uint32_t count) {
  __try {
    return exporter->QueryFunctionsByNarrowString(names, functions, count);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
}

void InstallKirikiriNativeLookupProbe(ITVPFunctionExporter* exporter) {
  if (exporter == nullptr || !IsKirikiriLookupProbeRequested() ||
      InterlockedCompareExchange(&g_lookup_bootstrap_state, 0, 0) != 0) {
    return;
  }

  const char* names[] = {
      "tTJSVariantString * ::TJSAllocVariantString(const tjs_char *)",
      "void tTJSVariantString::Release()",
      "void ::TVPExecuteScript(const ttstr &,tTJSVariant *)",
      "void ::TVPAddContinuousEventHook(tTVPContinuousEventCallbackIntf *)",
      "void ::TVPRemoveContinuousEventHook(tTVPContinuousEventCallbackIntf *)",
  };
  void* functions[5] = {};
  if (!QueryKirikiriNativeLookupFunctions(exporter, names, functions, 5)) return;

  g_lookup_alloc_string =
      reinterpret_cast<TJSAllocVariantStringStub_t>(functions[0]);
  g_lookup_release_string =
      reinterpret_cast<TJSVariantStringReleaseStub_t>(functions[1]);
  g_lookup_execute_script = reinterpret_cast<TVPExecuteScriptStub_t>(functions[2]);
  g_lookup_add_continuous =
      reinterpret_cast<TVPAddContinuousEventHookStub_t>(functions[3]);
  g_lookup_remove_continuous =
      reinterpret_cast<TVPRemoveContinuousEventHookStub_t>(functions[4]);
  if (g_lookup_alloc_string == nullptr || g_lookup_release_string == nullptr ||
      g_lookup_execute_script == nullptr || g_lookup_add_continuous == nullptr ||
      g_lookup_remove_continuous == nullptr) {
    return;
  }

  try {
    if (!PrepareKirikiriLookupRequestPath()) return;
    if (!g_lookup_response_cs_ready) {
      InitializeCriticalSection(&g_lookup_response_cs);
      g_lookup_response_cs_ready = true;
    }
    const std::wstring bootstrap = BuildKirikiriLookupBootstrapScript();
    g_lookup_bootstrap_script = g_lookup_alloc_string(bootstrap.c_str());
    if (g_lookup_bootstrap_script == nullptr) return;
    InterlockedExchange(&g_lookup_bootstrap_state, 1);
    g_lookup_add_continuous(&g_lookup_result_callback);
    g_lookup_add_continuous(&g_lookup_bootstrap_callback);
    g_lookup_worker = CreateThread(nullptr, 0, KiriKiriLookupWorker, nullptr, 0, nullptr);
  } catch (...) {
    TjsVariantString* script = g_lookup_bootstrap_script;
    g_lookup_bootstrap_script = nullptr;
    InterlockedExchange(&g_lookup_bootstrap_state, 0);
    if (script != nullptr) g_lookup_release_string(script);
  }
}

// exe 直取 / V2Link 两条拿 exporter 的路径共享的一次性安装闩（InterlockedCompareExchange）。
volatile LONG g_voice_installed = 0;

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

// Krkr2 的 BCB tTJSBinaryStream vtable 不能由 MSVC 安全调用。外层 TVPCreateIStream 已将它适配为
// Windows COM IStream；在这个稳定 ABI 上读取并还原原位置，可完全绕开 BCB C++ 对象布局。
bool ReadIStreamAllGuarded(IStream* s, uint8_t** out_buf, uint32_t* out_len) {
  *out_buf = nullptr;
  *out_len = 0;
  __try {
    LARGE_INTEGER zero = {};
    ULARGE_INTEGER original = {};
    ULARGE_INTEGER end = {};
    if (FAILED(s->Seek(zero, STREAM_SEEK_CUR, &original))) {
      return false;
    }
    if (FAILED(s->Seek(zero, STREAM_SEEK_END, &end))) {
      LARGE_INTEGER restore = {};
      restore.QuadPart = static_cast<LONGLONG>(original.QuadPart);
      s->Seek(restore, STREAM_SEEK_SET, nullptr);
      return false;
    }
    if (end.QuadPart == 0 || end.QuadPart > kMaxVoiceDumpBytes) {
      LARGE_INTEGER restore = {};
      restore.QuadPart = static_cast<LONGLONG>(original.QuadPart);
      s->Seek(restore, STREAM_SEEK_SET, nullptr);
      return false;
    }

    uint8_t* buf = static_cast<uint8_t*>(malloc(static_cast<size_t>(end.QuadPart)));
    if (buf == nullptr) {
      LARGE_INTEGER restore = {};
      restore.QuadPart = static_cast<LONGLONG>(original.QuadPart);
      s->Seek(restore, STREAM_SEEK_SET, nullptr);
      return false;
    }

    s->Seek(zero, STREAM_SEEK_SET, nullptr);
    uint32_t done = 0;
    const uint32_t size = static_cast<uint32_t>(end.QuadPart);
    while (done < size) {
      const ULONG want = static_cast<ULONG>((size - done) > 0x100000 ? 0x100000 : (size - done));
      ULONG got = 0;
      if (FAILED(s->Read(buf + done, want, &got)) || got == 0) break;
      done += got;
    }

    LARGE_INTEGER restore = {};
    restore.QuadPart = static_cast<LONGLONG>(original.QuadPart);
    s->Seek(restore, STREAM_SEEK_SET, nullptr);
    if (done == 0) {
      free(buf);
      return false;
    }
    *out_buf = buf;
    *out_len = done;
    return true;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
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

// Krkr2/BCB：hook 插件导入的稳定 __stdcall 边界。wuvorbis/wuopus 通过该 API 打开 XP3 中的音频；
// 返回值已是标准 COM IStream，因此无需伪造 eax/edx 寄存器调用，也不触碰 BCB 的 C++ vtable。
IStream* __stdcall Detour_TVPCreateIStreamStub(const void* name, uint32_t mode) {
  IStream* stream = g_orig_TVPCreateIStreamStub(name, mode);
  if (g_header != nullptr) {
    g_header->reserved_luna |= 0x40000;  // diag: detour 触发过
  }
  if (g_capture_enabled && stream != nullptr && name != nullptr && g_header != nullptr) {
    wchar_t storage[520];
    if (ExtractStorageNameGuarded(name, storage, 520) && IsVoiceStorageName(storage)) {
      const KiriKiriVoicePairingContext pairing =
          CaptureKirikiriVoicePairingContext(true);
      uint8_t* buf = nullptr;
      uint32_t buf_len = 0;
      if (ReadIStreamAllGuarded(stream, &buf, &buf_len)) {
        EnqueueKirikiriVoiceResourceOwned(buf, buf_len, storage, pairing);
      }
    }
  }
  return stream;
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
      const KiriKiriVoicePairingContext pairing =
          CaptureKirikiriVoicePairingContext(true);
      uint8_t* buf = nullptr;
      uint32_t buf_len = 0;
      if (ReadStreamAllGuarded(stream, &buf, &buf_len)) {
        EnqueueKirikiriVoiceResourceOwned(buf, buf_len, storage, pairing);
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
    // Krkr2 内部是 BCB eax/edx 约定；在外层稳定 __stdcall 导入桩捕获标准 IStream。
    if (g_header != nullptr) g_header->reserved_luna |= 0x800000;
    if (HookFn(stub, reinterpret_cast<void*>(&Detour_TVPCreateIStreamStub),
               reinterpret_cast<void**>(&g_orig_TVPCreateIStreamStub))) {
      if (g_header != nullptr) {
        g_header->reserved_luna |= kDiagKirikiriVoiceStreamHookReady;
      }
    }
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
    if (g_header != nullptr) {
      g_header->reserved_luna |=
          kDiagKirikiriVoiceStreamHookReady;  // 内部函数定位成功并 hook
    }
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
  const HRESULT result = orig != nullptr ? orig(exporter) : S_OK;
  // 原插件的 V2Link 已完成后才登记连续帧回调；真正执行 TJS 还会再等到下一次引擎事件循环。
  InstallKirikiriNativeLookupProbe(exporter);
  return result;
}

// 每个 hook 槽一个独立 detour（MinHook 共享 detour 无法区分各自 trampoline，故按 slot 展开）。
#define FUSHI_V2LINK_DETOUR(i)                               \
  HRESULT NTAPI Detour_V2Link_##i(ITVPFunctionExporter* e) {  \
    return HandleV2Link(e, g_v2link_orig[i]);                 \
  }
FUSHI_V2LINK_DETOUR(0)
FUSHI_V2LINK_DETOUR(1)
FUSHI_V2LINK_DETOUR(2)
FUSHI_V2LINK_DETOUR(3)
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
