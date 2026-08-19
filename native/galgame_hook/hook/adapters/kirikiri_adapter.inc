// P1 zero-behaviour-change split: included inside dll_main.cpp anonymous namespace.
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

// 游戏内查词传感器的安装重试点（x86 才有真实实现；KiriKiriZ 是 32 位引擎，x64 为空）。
// 为什么要重试：`lookup_enabled` 是 host 运行期开关，而 exporter 只在 V2Link / exe 直取那
// 一瞬间到手。若用户在游戏起来之后才打开查词，安装窗口早过去了；这里借 registry 每轮都会
// 调的 ProcessPendingEvents 复查开关，拿缓存的 exporter 补装。
void PollKirikiriLookupInstall();

uint64_t ReadKirikiriSharedU64(volatile uint64_t* value) {
  return value == nullptr
             ? 0
             : static_cast<uint64_t>(InterlockedCompareExchange64(
                   reinterpret_cast<volatile LONGLONG*>(value), 0, 0));
}

uint32_t ReadKirikiriSharedU32(volatile uint32_t* value) {
  return value == nullptr
             ? 0
             : static_cast<uint32_t>(InterlockedCompareExchange(
                   reinterpret_cast<volatile LONG*>(value), 0, 0));
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
  PollKirikiriLookupInstall();
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
// TVPExecuteExpression 与 TVPExecuteScript 同型，但 result 会被真正填成一个 tTJSVariant。
// 它是 hook 侧读回 TJS 传感器读数（命中几何、整行台词、输入事件）的唯一通道。
typedef void(__stdcall* TVPExecuteExpressionStub_t)(const TjsString& content, void* result);
typedef void(__stdcall* TVPAddContinuousEventHookStub_t)(TvpContinuousEventCallback* callback);
typedef void(__stdcall* TVPRemoveContinuousEventHookStub_t)(TvpContinuousEventCallback* callback);

TVPCreateIStreamStub_t g_orig_TVPCreateIStreamStub = nullptr;
TVPCreateStream_t g_orig_TVPCreateStream = nullptr;

TJSAllocVariantStringStub_t g_lookup_alloc_string = nullptr;
TJSVariantStringReleaseStub_t g_lookup_release_string = nullptr;
TVPExecuteScriptStub_t g_lookup_execute_script = nullptr;
TVPExecuteExpressionStub_t g_lookup_execute_expression = nullptr;
TVPAddContinuousEventHookStub_t g_lookup_add_continuous = nullptr;
TVPRemoveContinuousEventHookStub_t g_lookup_remove_continuous = nullptr;
ITVPFunctionExporter* g_lookup_exporter = nullptr;
TjsVariantString* g_lookup_bootstrap_script = nullptr;
volatile LONG g_lookup_bootstrap_state = 0;  // 0=off, 1=registered, 2=running, 3=done
// HookWorker 只登记"该装了"这个意图；真正碰引擎的安装动作只在引擎主线程上跑 (BUG-1724)。
volatile LONG g_lookup_install_requested = 0;
// 拥有游戏顶层窗口的线程 id，0 = 还没解析出来（窗口尚未建立）。
volatile LONG g_lookup_engine_main_tid = 0;

// TextRender 之外的捕获路径（Layer.drawText / MessageLayer.processCh）只在换游戏、
// TextRender 一条都不命中时才有诊断价值。运行日志已证伪它们在本样本上的作用，故默认
// **编译期关闭**：游戏内渲染意味着主线程上的每一毫秒都直接变掉帧，不能为了"万一有用"
// 在生产路径上并行跑四份没人读的排版计算。
constexpr bool kKirikiriLookupProbePaths = false;

// TJS 传感器。职责边界是：采字符几何、做命中测试、在游戏 Layer 上即时绘制选词高亮，
// 并承载 host 回投的 Fushi popup BGRA 位图与卡片输入。分词、查词、排版、背景和文字
// 都只由 Hibiki/Fushi 现有 popup 实现；TJS 不维护第二套词典卡渲染器。这里没有网络
// 客户端、认证凭据或 JSON。
//
// 三条通道都由 DLL 在游戏主线程的连续帧回调里驱动：
//   hook→host   TJS 把值写进 global，DLL 用 TVPExecuteExpression 读走再落进共享内存。
//               每帧只读 fushiLookupNotify 一个整数；它不变就一行 TJS 都不再跑。
//   host→hook   DLL 先调 global.fushiLookupPrepare(anchorX, anchorY, cardW, cardH) 把卡片
//               层建/调到位，再把 BGRA8（**直通 alpha、自顶向下**，与契约头一致；直通对应
//               ltAlpha，预乘才是 ltAddAlpha）memcpy 进它的像素缓冲，最后调
//               global.fushiLookupApply(seq, highlightStart, highlightLen,
//                                       anchorX, anchorY, cardW, cardH)。
//               两个入口的实参全是整数——"只允许整数"约束的是不许拼动态字符串，不是参数个数。
constexpr wchar_t kKirikiriLookupBootstrapScript[] = LR"TJS(
class FushiLookupCardLayer extends Layer
{
	function FushiLookupCardLayer(owner, parent)
	{
		super.Layer(owner, parent);
	}
	// 命中卡片子层时，KiriKiri 直接把按下/抬起派发给该 Layer，不再经过 primary
	// 的 KAG leftClick hook。这里是卡片按钮输入的主路；全局 hook 仅负责 primary
	// 路径上的防穿透兜底。
	function onMouseDown(x, y, button)
	{
		if(button == mbLeft) global.fushiLookupQueueInput(1, x, y, 0);
	}
	function onMouseUp(x, y, button)
	{
		if(button == mbLeft) global.fushiLookupQueueInput(2, x, y, 0);
	}
	// 卡片层就是卡片本身：按 host 给的 cardW×cardH 建、摆在 anchor 上，**不覆盖全屏**，而且
	// 延迟到真要显示第一帧时才建。命中判定用引擎天然的矩形命中（htRect），不依赖"alpha 为 0
	// 的像素会把点击透传下去"这条未在本引擎验证过的行为。这条选择是为了把失败面关死：全视口
	// 层一旦穿透语义不符预期，用户没查词时整个游戏就点不动了——那是把"查词不好使"放大成
	// "游戏坏了"。现在最坏情况也只是卡片自己那块矩形吃掉点击，而那块本来就该吃掉。
	// 事件坐标是层内坐标；入队时加回层位置换成视口坐标，减 anchor 由 DLL 做（帧元数据在它手上）。
	function onMouseMove(x, y)
	{
		global.fushiLookupQueueInput(0, x, y, 0);
	}
	function onMouseLeave()
	{
		global.fushiLookupQueueInput(4, 0, 0, 0);
	}
}

if(typeof global.fushiLookupBootstrap == "undefined")
{
	global.fushiLookupBootstrap = function(tick)
	{
		// kag 会早于 textrender.dll 的 TextRender 类就绪。这里必须把三条实际要覆写的
		// 方法一起作为 bootstrap 的前置条件；否则早注入时下面的一次性 typeof 分支会
		// 静默跳过包装器，却仍安装鼠标 hook、移除 continuous handler，之后整局都不会
		// 再得到逐字符几何（registry 永远为 0，且因为没有异常也不会置 SensorFault）。
		// 未就绪时只返回并保留 handler，下一帧继续观察真实生命周期，不用 sleep/盲重试。
		if(typeof global.kag != "Object" || global.kag === null ||
			typeof global.kag.addHook != "Object") return;
		// TextRender **半就绪**（类已在、三个方法还没挂全）必须继续等——那正是上面说的
		// 早注入窗口。但"完全没有 TextRender"是**另一回事**：经典 KAG3 游戏（没装
		// textrender.dll）永远等不到它，在这里一并 return 就等于把下面的 KAGEX 缺席门
		// else 分支变成死代码，那类游戏的游戏内查词连自证探针都装不上。
		// 判据因此落在"类在不在"上，而不是把两种情况合成一条。
		if(typeof global.TextRender == "Object" && global.TextRender !== null &&
			(typeof global.TextRender.render != "Object" ||
			typeof global.TextRender.done != "Object" ||
			typeof global.TextRender.drawCh != "Object")) return;
		var installStage = 0;
		try
		{
			// 这一批必须最先建立：DLL 每帧都会求值 fushiLookupNotify，晚一步就是每帧一次
			// TJS 异常。
			global.fushiLookupNotify = 0;
			// 传感器在引擎回调里吞下的异常次数。**不是可有可无的计数器**：我们注册进
			// 游戏事件循环的每个入口都必须异常透明（异常逃逸 = 游戏弹致命错误框），
			// 而「不让它逃逸」和「假装没发生」只差这一个计数。DLL 在 notify 变化的同
			// 一次求值里读走它并置 kLookupDiagSensorFault，故稳态零额外开销。
			global.fushiLookupFaults = 0;
			// 采集是否真的产出过逐字符几何。与「有没有命中」必须分开：命中还依赖坐标
			// 换算和鼠标位置，两件事挤在一个诊断位里，真机上就分不出「文字没采到」和
			// 「采到了但点不中」——而这两者的修法完全不同（第一次真机排查就卡在这）。
			global.fushiLookupGeometry = 0;
			// hover 未命中的原因位（TJS 侧 1/2/4/8/16，DLL 映射到 kLookupDiagHover*）。
			global.fushiLookupMiss = 0;
			// 一次采集周期内 bindOrigin 真正生效的次数。drawCh 会逐字调用，但官方
			// KAGEX 语义明确 ox/oy 是共享行原点、ch.x/ch.y 才是逐字位置。
			global.fushiLookupBindTicks = 0;
			global.fushiLookupBindRevision = 0;
			// 按**绘制目标层的父层**分组的 drawCh 落点跨度。
			//
			// 这是把「采到的一行」和「它画在哪个层」对起来的唯一可靠判据：本引擎里
			// drawCh 的 this 与 render 的 this 不是同一个对象（renderer 身份对不上），
			// 淡入又由持续回调驱动（时序也对不上）。但几何对得上——同一行的 drawCh
			// 落点集合与 getCharacters 的字形坐标集合只差一个常数平移，**跨度必然相等**。
			global.fushiLookupBindGroups = [];
			// 建卡片层走到第几步。非 0 = 上一次 prepare 在这一步抛了异常；DLL 把它
			// 搬进共享内存，真机上一眼看出是哪一行，不必再靠猜和往返。
			global.fushiLookupStep = 0;
			// 被 catch 掉的异常**原文**（含出错点标签）。位只说得出"成没成"，说不出
			// "为什么"；DLL 每轮把它读走写进 %TEMP%ushi_galhook.log。
			global.fushiLookupLastError = "";
			global.fushiLookupErrorSeq = 0;
			// 一次 submit 的坐标链快照。它与异常出口完全分开：异常不能被诊断覆盖，坐标
			// trace 也不能伪装成异常。每个游戏进程最多记 4 次人工提交，每次 registry 最多
			// 8 项且只含数值/枚举，不记录台词、字形、图层名或其他游戏内容。
			global.fushiLookupCoordTrace = "";
			global.fushiLookupCoordTraceSeq = 0;
			global.fushiLookupCoordTraceBudget = 4;
			// Capture 已产出字形、却没有发布可命中 entry 时，用这一条 bounded trace
			// 区分「无 drawCh 分组 / span 不匹配 / 宿主不可见 / 锚点未解析」。只记录
			// 数量、布尔状态与跨度，不读取或拼接台词/字形内容。
			global.fushiLookupCaptureTraceBudget = 8;
			global.fushiLookupCaptureTraceLast = "";
			// 不读取 renderer/台词/字形，只回答“我们装上的 wrapper 现在是否仍是入口”。
			// mouseMove 只建立一次启动基线；低频 leftClick 会继续复核，并且仅在状态变化时
			// 发布。游戏可能在“恢复上次进度”以后才重载系统脚本，一次性检查会漏掉该时序。
			global.fushiLookupWrapperAuditPending = true;
			global.fushiLookupWrapperAuditLastState = -1;
			global.fushiLookupOffsetReachedPrimary = 0;
			// 光标换算的暂存（避免在 hover 热路径上每条记录都分配一个字典）。
			global.fushiLookupOffX = 0;
			global.fushiLookupOffY = 0;
			global.fushiLookupHitSeq = 0;
			global.fushiLookupHitCharIndex = 0;
			global.fushiLookupHitCharCount = 0;
			global.fushiLookupHitGlyphX = 0;
			global.fushiLookupHitGlyphY = 0;
			global.fushiLookupHitGlyphW = 0;
			global.fushiLookupHitGlyphH = 0;
			global.fushiLookupHitViewW = 0;
			global.fushiLookupHitViewH = 0;
			global.fushiLookupHitFlags = 0;
			global.fushiLookupHitLine = "";
			global.fushiLookupVisualSeq = 0;
			global.fushiLookupSubmitSeq = 0;

)TJS" LR"TJS(

			// Esc 只取消当时已经存在的 submit。这个单调 fence 留在游戏侧，因而即使
			// host 已经开始查词、结构帧尚未回到游戏，取消也不会被在途结果反弹覆盖。
			global.fushiLookupDismissedSubmitSeq = 0;
			global.fushiLookupSubmitCharIndex = 0;
			global.fushiLookupSubmitCharCount = 0;
			global.fushiLookupSubmitGlyphX = 0;
			global.fushiLookupSubmitGlyphY = 0;
			global.fushiLookupSubmitGlyphW = 0;
			global.fushiLookupSubmitGlyphH = 0;
			global.fushiLookupSubmitViewW = 0;
			global.fushiLookupSubmitViewH = 0;
			global.fushiLookupSubmitLine = "";
			global.fushiLookupInputQueue = [];
			global.fushiLookupShiftDown = false;
			global.fushiLookupProbeMode = __FUSHI_PROBE_MODE__;
			global.fushiLookupProbeDrawText = 0;
			global.fushiLookupProbeProcessCh = 0;
			global.fushiLookupProbeError = "";
			global.fushiLookupCardPath = "__FUSHI_CARD_PATH__";
			global.fushiLookupCardSeq = 0;
			// 制卡截图的临时视觉抑制。它与永久 dismiss 分开：不动 submit/Esc fence，
			// 下一张完整卡片帧会清除此位并恢复。同一事务的成功 token 由 DLL 回读。
			global.fushiLookupCaptureSuppressed = false;
			global.fushiLookupCaptureSuppressSeq = 0;
			global.fushiLookupRegistry = [];
			// TJS `new` 会把类成员复制到实例；脚本晚注入时，仅覆写
			// global.TextRender 不会改变已经存在的 LangRender/TextRender 对象。
			// 这份有界 sidecar ledger 只持有消息窗口的 renderer，不给游戏对象塞标记。
			global.fushiLookupInstancePatches = [];
			global.fushiLookupInstanceSweepActive = false;
			// 已经暴露给游戏的 method closure 可能脱离 owner 字段继续存活；record
			// 因而必须比字段 identity 更长寿。实例与 getRender 都只做有界保留，
			// 安装/回滚失败也不能删除 original。
			global.fushiLookupInstanceGetRenderPatches = [];
			global.fushiLookupInstanceGetRenderOwner = void;
			global.fushiLookupInstanceGetRenderOriginal = void;
			global.fushiLookupInstanceGetRenderWrapper = void;
			global.fushiLookupInstanceGetRenderInstalling = false;
			global.fushiLookupInstanceGetRenderInstallFailed = false;
			global.fushiLookupInstancePluginSource = 0;
			global.fushiLookupInstancePluginCount = -1;
			global.fushiLookupInstancePluginIndex = -1;
			// 只发布私有消息 renderer 桥的结构计数，不读取对象字符串、台词或字形。
			// 这用于把「插件根不存在 / renders 形态不符 / renderer 方法面不符 /
			// wrapper 安装失败」四个静默出口在真机上分开。
			global.fushiLookupInstanceShapeLast = "";
			global.fushiLookupInstanceRejectShape = 0;
			global.fushiLookupInstanceRejectClass = 0;
			global.fushiLookupInstanceRejectMixed = 0;
			global.fushiLookupInstanceRejectFull = 0;
			global.fushiLookupInstanceAlreadyClass = 0;
			// Registry entry 本身会被 8 槽 LRU 复用。lease 把一次 renderer→entry
			// 绑定与 entry 对象地址分开；迟到回调即使仍持有旧 entry 引用，也不能在
			// 复用后改写另一个 renderer 的 slot。
			global.fushiLookupRendererLease = 0;
			// KAG message slot 的逻辑台词世代。renderer 会随口型/表情重建，不能
			// 把它当台词生命周期；(page,index) 才能隔离 ai=0 正文与 ai=1 姓名层。
			global.fushiLookupSlots = [];
			global.fushiLookupClock = 0;
			global.fushiLookupHoverKey = "";
			global.fushiLookupHitEntry = void;
			// 当前**卡片**依附的 entry（BUG-1606）。与 fushiLookupHitEntry 分开：后者是最后
			// 一次命中（含纯悬停），前者只在卡片真正显示那一刻定下，是收卡的唯一归属判据。
			global.fushiLookupCardEntry = void;
			// DLL 侧读它自证这局走的是经典 KAG3 采集面（真机上分得清哪条路绑上了）。
			global.fushiLookupClassicSource = 0;
			global.fushiLookupHitOffsetX = 0;
			global.fushiLookupHitOffsetY = 0;
			global.fushiLookupHighlightRect = void;
			// Entry/slot retirement runs inside the renderer ledger transaction and
			// must never call back into a game Layer.  Queue the one visible highlight
			// rectangle here; a transaction-external leaf flushes it afterwards.
			global.fushiLookupPendingHighlightEraseRect = void;
			global.fushiLookupPendingHighlightEraseSeq = 0;
			global.fushiLookupHighlightFlushActive = false;
			global.fushiLookupPendingVisualDismiss = false;
			global.fushiLookupVisualFlushActive = false;
			global.fushiLookupBoundRenderer = void;
			global.fushiLookupBoundLayer = void;
			global.fushiLookupBoundX = 0;
			global.fushiLookupBoundY = 0;
			global.fushiLookupRefreshActive = false;

)TJS" LR"TJS(

			global.fushiLookupField = function(value, name)
			{
				try
				{
					var found = value[name];
					if(found !== void) return found;
				}
				catch(e) {}
				return void;
			};

			// 记一个「未命中原因」位。只在 0→1 那一次搭 notify 的车通知 DLL：未命中是
			// 高频事件（鼠标每动一像素都可能未命中），每次都通知等于把诊断做成性能问题。
			global.fushiLookupMark = function(bit)
			{
				if((global.fushiLookupMiss & bit) != 0) return;
				global.fushiLookupMiss = global.fushiLookupMiss | bit;
				global.fushiLookupNotify++;
			};

			// 把光标位置换算到某个图层的局部坐标系，结果写进 fushiLookupOffX/Y。
			//
			// 🔴 **不能问那个图层自己**。`layer.cursorX / layer.imageLeft` 是图像属性，
			// 要求该层此刻可绘制；而文字的绘制目标层归游戏所有，翻页/换场景后会被
			// freeImage 或改成非可绘制类型，一读就抛 "Not drawable layer type"。真机上
			// 的表现是：每次鼠标移动都把这条记录判死淘汰掉，下一次渲染再建、再淘汰，
			// 命中数永远是 0。
			//
			// left/top/parent 是**图层树**属性，与该层有没有图像、是什么类型都无关，
			// 任何状态下都能读。KAG 的 fore.messages[] 是 primary 的子树，而
			// back.messages[] 是它的兄弟子树；所以既不能把 message.left/top 直接当成
			// primary 坐标，也不能因为父链没经过 primary 就把合法 back 页判成离屏层。
			// 分别累加 layer 与 primary 到共同根的绝对图层坐标，二者相减才是严格的
			// layer→primary 偏移。guard 防御游戏把图层树接成环（这里跑在游戏主线程，
			// 死循环就会直接卡死游戏）。
			global.fushiLookupComputeOffset = function(layer)
			{
				var primary = global.kag.primaryLayer;
				global.fushiLookupOffX = 0;
				global.fushiLookupOffY = 0;
				global.fushiLookupOffsetReachedPrimary = 0;
				var layerX = 0, layerY = 0;
				var layerRoot = void;
				var current = layer;
				var guard = 0;
				while(current !== void && current !== null && isvalid current)
				{
					if(current === primary)
						global.fushiLookupOffsetReachedPrimary = 1;
					if(++guard > 32)
					{
						global.fushiLookupMark(16);
						return false;
					}
					layerRoot = current;
					layerX += current.left;
					layerY += current.top;
					current = current.parent;
				}

				var primaryX = 0, primaryY = 0;
				var primaryRoot = void;
				current = primary;
				guard = 0;
				while(current !== void && current !== null && isvalid current)
				{
					if(++guard > 32)
					{
						global.fushiLookupMark(16);
						return false;
					}
					primaryRoot = current;
					primaryX += current.left;
					primaryY += current.top;
					current = current.parent;
				}

				if(layerRoot === void || primaryRoot === void ||
					layerRoot !== primaryRoot)
				{
					global.fushiLookupMark(16);
					return false;
				}
				global.fushiLookupOffX = layerX - primaryX;
				global.fushiLookupOffY = layerY - primaryY;
				return true;
			};

			// 只做 bounded trace 的发布，不复用 LastError/ErrorSeq。字符串在调用前已由固定
			// 标签和数字组成；这里再统一扣预算，保证每个进程最多写四行。
			global.fushiLookupPublishCoordTrace = function(trace)
			{
				if(global.fushiLookupCoordTraceBudget <= 0) return;
				global.fushiLookupCoordTrace = trace;
				global.fushiLookupCoordTraceBudget--;
				global.fushiLookupCoordTraceSeq++;
				global.fushiLookupNotify++;
			};

			// KAG 双缓冲页的脱敏身份：0=未知、1=fore、2=back。只比较对象身份，不读取
			// name，也不把任何游戏文本送进日志。
			global.fushiLookupPageOf = function(layer)
			{
				try
				{
					var foreBase = global.kag.fore.base;
					var backBase = global.kag.back.base;
					var current = layer;
					var guard = 0;
					while(current !== void && current !== null && isvalid current)
					{
						if(current === foreBase) return 1;
						if(current === backBase) return 2;
						if(++guard > 32) break;
						current = current.parent;
					}
				}
				catch(e) {}
				return 0;
			};

			// 每条 registry 记录的固定格式。state/glyphIndex 仅由 probe 的常量分支传入；
			// formatter 不读取 entry.line，调用方也不传 glyph.ch，避免诊断日志落入游戏内容。
			global.fushiLookupCoordEntry = function(index, entry, offsetOk, rx, ry,
				state, glyphIndex)
			{
				return "|i=" + index + ",hp=" + entry.hostPage + ",ap=" +
					entry.anchorPage + ",ak=" + entry.anchorKind + ",ai=" +
					entry.anchorIndex + ",rp=" +
					global.fushiLookupOffsetReachedPrimary +
					",ok=" + offsetOk + ",o=" + global.fushiLookupOffX + "," +
					global.fushiLookupOffY + ",im=" + entry.imgLeft + "," + entry.imgTop +
					",or=" + entry.originX + "," + entry.originY + ",b=" + entry.minX +
					"," + entry.minY + "," + entry.maxX + "," + entry.maxY + ",r=" +
					rx + "," + ry + ",z=" + state + ",g=" + glyphIndex;
			};

			// 记下被吞掉的异常原文。site 标明出错点，e.message 是引擎给的真实原因。
			global.fushiLookupNoteError = function(site, e)
			{
				try
				{
					global.fushiLookupLastError = site + ": " + e.message;
				}
				catch(e2)
				{
					global.fushiLookupLastError = site + ": <no message>";
				}
				global.fushiLookupErrorSeq++;
				global.fushiLookupNotify++;
			};

			// 记一次「在引擎回调里吞下的异常」。只做整数自增，自身不可能再抛。
			// 顺带 ++notify 是有意的：DLL 只在 notify 变化时才回读，不搭这趟车故障就要等
			// 到下一次真命中才被看见，而故障恰恰会阻止命中发生。重复的 notify 不会造成
			// 重复命中——host 按 hit seq 去重。
			global.fushiLookupFault = function()
			{
				global.fushiLookupFaults++;
				global.fushiLookupNotify++;
			};

			global.fushiLookupAuditWrappers = function(force)
			{
				if(!force && !global.fushiLookupWrapperAuditPending) return;
				global.fushiLookupWrapperAuditPending = false;
				var state = 0;
				try
				{
					if(typeof global.TextRender != "Object" || global.TextRender === null)
						state = state | 1;
					else
					{
						if(typeof global.TextRender.render != "Object") state = state | 2;
						else if(global.fushiLookupRenderInstallFailed ||
							global.TextRender.render !== global.fushiLookupInstalledRenderWrapper)
							state = state | 4;
						if(typeof global.TextRender.done != "Object") state = state | 8;
						else if(global.fushiLookupDoneInstallFailed ||
							global.TextRender.done !== global.fushiLookupInstalledDoneWrapper)
							state = state | 16;
						if(typeof global.TextRender.drawCh != "Object") state = state | 32;
						else if(global.fushiLookupDrawChInstallFailed ||
							global.TextRender.drawCh !== global.fushiLookupInstalledDrawChWrapper)
							state = state | 64;
					}
					// renderMsgwinPlugin 是 Limelight 私有扩展；不存在时不是通用
					// Kirikiri 故障。只有实例真的出现后才审计它的 bridge。
					var plugin = global.fushiLookupResolveMsgwinPlugin();
					if(plugin !== void)
					{
						if(typeof plugin.getRender != "Object") state = state | 512;
						else if(global.fushiLookupInstanceGetRenderInstallFailed ||
							plugin !== global.fushiLookupInstanceGetRenderOwner ||
							plugin.getRender !== global.fushiLookupInstanceGetRenderWrapper)
							state = state | 1024;
					}
					var patches = global.fushiLookupInstancePatches;
					for(var pi = 0; pi < patches.count && pi < 16; pi++)
					{
						var patch = patches[pi];
						if(patch.state == 1 &&
							(patch.renderer.render !== patch.renderWrapper ||
							 patch.renderer.done !== patch.doneWrapper ||
							 patch.renderer.drawCh !== patch.drawChWrapper))
						{
							state = state | 2048;
							break;
						}
					}
				}
				catch(e) { state = state | 128; }
				if(state != global.fushiLookupWrapperAuditLastState)
				{
					global.fushiLookupWrapperAuditLastState = state;
					global.fushiLookupNoteError("wrapper.identity", %[message: "state=" + state]);
				}
			};

			// 上限 8 + 淘汰最久未用。TJS 没有弱引用，registry 只增不减就等于把每个用过的
			// renderer 连同它的整行几何永久钉在游戏进程里（prototype 的真实泄漏源）。
			global.fushiLookupFindEntry = function(renderer)
			{
				var registry = global.fushiLookupRegistry;
				for(var i = 0; i < registry.count; i++)
					if(registry[i].renderer === renderer && registry[i].rendererLease > 0)
						return registry[i];
				return void;
			};

)TJS" LR"TJS(

			global.fushiLookupEntryFor = function(renderer)
			{
				var registry = global.fushiLookupRegistry;
				var nonActiveInvalid = -1, nonActive = -1;
				var activeInvalid = -1, activeOldest = -1;
				var nonActiveInvalidClock = 0, nonActiveClock = 0;
				var activeInvalidClock = 0, activeOldestClock = 0;
				for(var i = 0; i < registry.count; i++)
				{
					if(registry[i].renderer === renderer && registry[i].rendererLease > 0)
						return registry[i];
					var candidate = registry[i];
					var active = false;
					var activityClock = candidate.used;
					var slots = global.fushiLookupSlots;
					for(var si = 0; si < slots.count; si++)
					{
						if(slots[si].activeEntry === candidate)
						{
							active = true;
							if(slots[si].clock > activityClock) activityClock = slots[si].clock;
							break;
						}
					}
					var validRenderer = false;
					try
					{
						validRenderer = candidate.renderer !== void &&
							candidate.renderer !== null && isvalid candidate.renderer;
					}
					catch(e) { validRenderer = false; }
					if(!active && !validRenderer &&
						(nonActiveInvalid < 0 || activityClock < nonActiveInvalidClock))
					{
						nonActiveInvalid = i;
						nonActiveInvalidClock = activityClock;
					}
					else if(!active && validRenderer &&
						(nonActive < 0 || activityClock < nonActiveClock))
					{
						nonActive = i;
						nonActiveClock = activityClock;
					}
					else if(active && !validRenderer &&
						(activeInvalid < 0 || activityClock < activeInvalidClock))
					{
						activeInvalid = i;
						activeInvalidClock = activityClock;
					}
					else if(active && validRenderer &&
						(activeOldest < 0 || activityClock < activeOldestClock))
					{
						activeOldest = i;
						activeOldestClock = activityClock;
					}
				}
				if(registry.count < 8)
				{
					var fresh = %[renderer:renderer,
						rendererLease:++global.fushiLookupRendererLease,
						glyphs:[], line:"", used:0,
						bindAttemptRevision:global.fushiLookupBindRevision,
						observedPage:0, observedIndex:-1, observedIdentity:void,
						minX:0, minY:0, maxX:0, maxY:0, layer:void, visibleHost:void,
						currentIdentity:void, bindingStrength:0,
						logicalLine:"", slotPage:0, slotIndex:-1, slotGeneration:0,
						renderEpoch:0, retiredRenderEpoch:0,
						originX:0, originY:0,
						baseOx:0, baseOy:0, hasBase:false, imgLeft:0, imgTop:0,
						passMinOx:0, passMinOy:0, passHas:false, passLayer:void,
						hostPage:0, anchorPage:0, anchorKind:0, anchorIndex:-1];
					registry.add(fresh);
					return fresh;
				}
				// 只要还有 non-active 槽，绝不逐出 slot.activeEntry。有声表情重绘
				// 会制造大量弱/无 candidate renderer；旧 LRU 只看 entry.used，会把仍由
				// slot.clock 持续证明在用的 A 逐出。八槽全 active 时才有界退休最旧者。
				var victim = (nonActiveInvalid >= 0) ? nonActiveInvalid :
					((nonActive >= 0) ? nonActive :
					((activeInvalid >= 0) ? activeInvalid : activeOldest));
				var reused = registry[victim];
				// 先撤销旧 lease，再清旧 binding；Capture 会在读取 characters 后再次
				// 校验 lease，因此任何重入/迟到回调都只能失败关闭。
				reused.rendererLease = 0;
				reused.glyphs = [];
				reused.line = "";
				reused.used = 0;
				global.fushiLookupClearEntryBinding(reused);
				reused.renderer = renderer;
				reused.logicalLine = "";
				reused.slotPage = 0;
				reused.slotIndex = -1;
				reused.slotGeneration = 0;
				reused.renderEpoch = 0;
				reused.retiredRenderEpoch = 0;
				reused.bindAttemptRevision = global.fushiLookupBindRevision;
				reused.observedPage = 0;
				reused.observedIndex = -1;
				reused.observedIdentity = void;
				// lease 是整条 reused entry 的发布位，所有字段完整后最后写。
				reused.rendererLease = ++global.fushiLookupRendererLease;
				return reused;
			};

			// Merge an old highlight into one bounded pending rectangle. This helper is
			// deliberately pure ledger work: no Layer read/write, no isvalid, no update.
			global.fushiLookupQueueHighlightErase = function(rect)
			{
				if(rect === void || rect === null) return;
				var pending = global.fushiLookupPendingHighlightEraseRect;
				if(pending === void || pending === null)
				{
					global.fushiLookupPendingHighlightEraseRect =
						%[x:rect.x, y:rect.y, w:rect.w, h:rect.h];
				}
				else
				{
					var left = pending.x < rect.x ? pending.x : rect.x;
					var top = pending.y < rect.y ? pending.y : rect.y;
					var pendingRight = pending.x + pending.w;
					var rectRight = rect.x + rect.w;
					var right = pendingRight > rectRight ? pendingRight : rectRight;
					var pendingBottom = pending.y + pending.h;
					var rectBottom = rect.y + rect.h;
					var bottom = pendingBottom > rectBottom ? pendingBottom : rectBottom;
					global.fushiLookupPendingHighlightEraseRect =
						%[x:left, y:top, w:right - left, h:bottom - top];
				}
				global.fushiLookupPendingHighlightEraseSeq++;
			};

			// The only Layer-touching half of highlight retirement. A reentrant flush
			// never recurses; a rectangle queued during fill/update changes seq and is
			// retained for the next leaf. Failed Layer calls likewise keep the work.
			global.fushiLookupFlushPendingHighlightErase = function()
			{
				if(global.fushiLookupHighlightFlushActive) return false;
				var pending = global.fushiLookupPendingHighlightEraseRect;
				if(pending === void || pending === null) return true;
				var seq = global.fushiLookupPendingHighlightEraseSeq;
				global.fushiLookupHighlightFlushActive = true;
				var completed = false;
				try
				{
					var highlight = global.fushiLookupHighlightLayer;
					if(highlight !== void && highlight !== null && isvalid highlight)
					{
						highlight.fillRect(pending.x, pending.y,
							pending.w, pending.h, 0);
						highlight.visible = false;
						highlight.update();
					}
					completed = true;
				}
				catch(e) { global.fushiLookupFault(); }
				global.fushiLookupHighlightFlushActive = false;
				if(completed && global.fushiLookupPendingHighlightEraseSeq == seq)
					global.fushiLookupPendingHighlightEraseRect = void;
				return global.fushiLookupPendingHighlightEraseRect === void;
			};

			// 字形快照与宿主绑定是两笔不同来源的数据。只有“台词已换且当轮
			// 无法建立新 candidate”时才单独清理它；同一 renderer 的同句重复 Capture
			// 必须在新 candidate 完整后才替换旧绑定。有声台词会因口型/表情重绘反复
			// 进入这里，某一轮 drawCh 宿主短暂不可见不能摧毁上一轮仍有效的坐标。
			global.fushiLookupClearEntryBinding = function(entry)
			{
				// active handoff/退休时旧 HitEntry 不能留在 hover fence 里。hover key 只有
				// line#index；同句 B 接管后若不清，PaintHighlight 会因 key 相同提前返回，
				// 但 HitEntry 仍指向已经清空的 A。
				if(global.fushiLookupHitEntry === entry)
				{
					global.fushiLookupQueueHighlightErase(
						global.fushiLookupHighlightRect);
					global.fushiLookupHitEntry = void;
					global.fushiLookupHoverKey = "";
					global.fushiLookupHighlightRect = void;
					global.fushiLookupHitOffsetX = 0;
					global.fushiLookupHitOffsetY = 0;
				}
				entry.layer = void;
				entry.visibleHost = void;
				entry.currentIdentity = void;
				entry.bindingStrength = 0;
				entry.originX = 0;
				entry.originY = 0;
				entry.baseOx = 0;
				entry.baseOy = 0;
				entry.hasBase = false;
				entry.imgLeft = 0;
				entry.imgTop = 0;
				entry.passMinOx = 0;
				entry.passMinOy = 0;
				entry.passHas = false;
				entry.passLayer = void;
				entry.hostPage = 0;
				entry.anchorPage = 0;
				entry.anchorKind = 0;
				entry.anchorIndex = -1;
				// activeEntry 是 slot 当前可探测快照，清 binding 时必须同步摘链。
				var slots = global.fushiLookupSlots;
				for(var si = 0; si < slots.count; si++)
				{
					if(slots[si].activeEntry === entry)
					{
						slots[si].activeEntry = void;
						slots[si].activeStrength = 0;
					}
				}
			};

)TJS" LR"TJS(

			// 同一个 KAG 消息槽可能被多个 TextRender entry 捕获。退休只清「active
			// glyph/binding」，logicalLine/slotGeneration 保留；否则 A/B renderer 在同句
			// 交替时，被退休的一方会把自己误判成新台词并 dismiss。
			global.fushiLookupRetireAnchorPeers = function(entry, anchorPage, anchorIndex)
			{
				if(anchorPage == 0 || anchorIndex < 0) return;
				var registry = global.fushiLookupRegistry;
				for(var i = 0; i < registry.count; i++)
				{
					var peer = registry[i];
					if(peer === entry) continue;
					if(peer.slotPage != anchorPage || peer.slotIndex != anchorIndex) continue;
					peer.glyphs = [];
					peer.line = "";
					peer.used = 0;
					// render 是真实的原函数调用边界；done 不递增。记录退休时已见
					// render 世代，随后同世代才到的 done 不能把旧台词重新提交。
					peer.retiredRenderEpoch = peer.renderEpoch;
					global.fushiLookupClearEntryBinding(peer);
				}
			};

			global.fushiLookupFindSlot = function(page, index)
			{
				var slots = global.fushiLookupSlots;
				for(var i = 0; i < slots.count; i++)
					if(slots[i].page == page && slots[i].index == index) return slots[i];
				return void;
			};

			// 只从 kag.current 在 fore/back.messages[] 中的严格对象身份解 slot。
			// currentNum 会在双缓冲页复用，单独拿它推进世代会误杀另一页。
			global.fushiLookupResolveCurrentSlot = function()
			{
				var current = global.fushiLookupField(global.kag, "current");
				if(current === void || current === null || !isvalid current) return void;
				try
				{
					var pages = [global.kag.fore.messages, global.kag.back.messages];
					for(var p = 0; p < pages.count; p++)
					{
						var messages = pages[p];
						for(var i = 0; i < messages.count; i++)
							if(messages[i] === current)
								return %[page:p + 1, index:i, identity:current];
					}
				}
				catch(e) {}
				return void;
			};

			global.fushiLookupSlotFor = function(page, index, identity)
			{
				var found = global.fushiLookupFindSlot(page, index);
				if(found !== void)
				{
					found.clock = ++global.fushiLookupClock;
					if(identity !== void && identity !== null && isvalid identity)
						found.currentIdentity = identity;
					return found;
				}
				var slots = global.fushiLookupSlots;
				if(slots.count >= 8)
				{
					var oldestInactive = -1, oldestActive = -1;
					var inactiveClock = 0, activeClock = 0;
					for(var i = 0; i < slots.count; i++)
					{
						var clock = slots[i].clock;
						if(slots[i].activeEntry === void || slots[i].activeEntry === null)
						{
							if(oldestInactive < 0 || clock < inactiveClock)
							{
								oldestInactive = i;
								inactiveClock = clock;
							}
						}
						else
						{
							if(slots[i].activeEntry.used > clock) clock = slots[i].activeEntry.used;
							if(oldestActive < 0 || clock < activeClock)
							{
								oldestActive = i;
								activeClock = clock;
							}
						}
					}
					var oldest = (oldestInactive >= 0) ? oldestInactive : oldestActive;
					var retired = slots[oldest].activeEntry;
					if(retired !== void && retired !== null)
					{
						retired.glyphs = [];
						retired.line = "";
						retired.retiredRenderEpoch = retired.renderEpoch;
						global.fushiLookupClearEntryBinding(retired);
					}
					slots.erase(oldest);
				}
				var fresh = %[page:page, index:index, line:"", generation:0,
					currentIdentity:identity, activeEntry:void, activeStrength:0,
					clock:++global.fushiLookupClock];
				slots.add(fresh);
				return fresh;
			};

			// 把一次已由 candidate anchorPage/index 证明的非空 Capture 纳入
			// slot 世代。只有完整 candidate 才能进入这里；无 candidate 的表情/口型
			// 重绘不会改变 slot，也不会摧毁上一轮仍可用的同句绑定。
			global.fushiLookupAdoptSlot = function(entry, line, page, index, identity,
				capturePhase)
			{
				var slot = global.fushiLookupSlotFor(page, index, identity);
				// 一个 entry 同时只能归属一个 slot。renderer 可在 fore/back 切换时复用；
				// 迁入目标前从其余 slot 的 active 摘链，防止同一对象形成幽灵 active。
				var allSlots = global.fushiLookupSlots;
				for(var si = 0; si < allSlots.count; si++)
				{
					var other = allSlots[si];
					if(other === slot) continue;
					if(other.activeEntry === entry)
					{
						other.activeEntry = void;
						other.activeStrength = 0;
					}
				}
				var advanced = false;
				if(slot.line == "")
				{
					slot.line = line;
					slot.generation++;
				}
				else if(slot.line != line)
				{
					// 同一个 KAG MessageLayer 会被下一句复用，现有接口没有消息内容
					// generation，无法把“屏上真的 A→B→A”与“A 的迟到回调”严格区分。
					// 这里以完整、可见、已投影到同一 page/index 的 candidate 作为唯一
					// 提交边界；无 candidate 的 Capture 绝不推进。这样不会把旧字形留作
					// 当前命中，也不依赖 render 次数/文本 tombstone 猜世代。
					// entry 曾属于此 slot、且仍报告退休前的同一句时，只允许新的
					// TextRender.render 世代重新取得提交权。done 只是同一 render 的
					// 尾声，不能把已退休的 A 倒回当前 B。真正再次绘制 A 会先递增
					// renderEpoch，因此合法 A→B→A 不依赖永久文本 tombstone。
					// fresh renderer 的字符数组可能到 done 才完整，所以合法 B 的 done
					// 仍可提交；只有已经从这个 slot 退休的旧 entry 才受下面 epoch 门。
					if(entry.slotPage == page && entry.slotIndex == index &&
						entry.slotGeneration < slot.generation &&
						entry.logicalLine == line &&
						entry.renderEpoch <= entry.retiredRenderEpoch)
						return %[slot:slot, stale:true, same:false, advanced:false];
					global.fushiLookupRetireAnchorPeers(entry, page, index);
					slot.line = line;
					slot.generation++;
					slot.activeEntry = void;
					slot.activeStrength = 0;
					advanced = true;
				}
				var same = entry.logicalLine == line && entry.slotPage == page &&
					entry.slotIndex == index && entry.slotGeneration == slot.generation;
				entry.logicalLine = line;
				entry.slotPage = page;
				entry.slotIndex = index;
				entry.slotGeneration = slot.generation;
				return %[slot:slot, same:same, advanced:advanced];
			};

)TJS" LR"TJS(

			// 返回 1=仍是捕获时那一个 kag.current，-1=已有另一个 current（记录已过期），
			// 0=捕获时无法建立稳定身份。只有 1 可以绕过 drawCh 短命宿主的 visible 状态；
			// 0 仍走 visibleHost 兼容路径，-1 则失败关闭，不能让旧词靠仍可见的宿主复活。
			global.fushiLookupCurrentIdentityState = function(entry)
			{
				if(entry.slotPage != 0 && entry.slotIndex >= 0)
				{
					var slot = global.fushiLookupFindSlot(entry.slotPage, entry.slotIndex);
					if(slot === void || slot.generation != entry.slotGeneration ||
						slot.line != entry.logicalLine || slot.activeEntry !== entry) return -1;
				}
				if(entry.anchorKind == 0) return 0;
				var captured = entry.currentIdentity;
				if(captured === void || captured === null) return 0;
				if(!isvalid captured) return -1;
				var resolved = global.fushiLookupResolveCurrentSlot();
				// 既有强身份时，getter 短暂不可得必须拒绝，不能降级回
				// visibleHost；否则旧 MessageLayer 复用时会短暂复活旧词。
				if(resolved === void) return -1;
				if(resolved.page == entry.slotPage && resolved.index == entry.slotIndex)
					return resolved.identity === captured ? 1 : -1;
				// 另一个共存 slot（典型是 ai=1 姓名层 vs ai=0 正文）成为
				// global current 不能判本 entry 过期；这时回退检查它自己的 visibleHost。
				return 0;
			};

			global.fushiLookupVisible = function(layer)
			{
				var current = layer;
				while(current !== void && current !== null && isvalid current)
				{
					if(!current.visible || current.opacity <= 0) return false;
					current = current.parent;
				}
				return true;
			};

			global.fushiLookupEntryVisible = function(entry)
			{
				try
				{
					var layer = entry.layer;
					if(layer !== void && layer !== null && isvalid layer &&
						global.fushiLookupVisible(layer)) return true;
					var host = entry.visibleHost;
					return host !== void && host !== null && isvalid host &&
						global.fushiLookupVisible(host);
				}
				catch(e) { return false; }
			};

			// 高亮层同样延迟到第一次真要高亮时才建。它是全视口的，但 hitThreshold=256 是
			// 引擎里"永不命中"这个明确取值——与卡片依赖的 alpha 穿透不是一回事，不会把
			// 输入吃掉。
			global.fushiLookupEnsureHighlight = function()
			{
				var primary = global.kag.primaryLayer;
				var layer = global.fushiLookupHighlightLayer;
				if(layer === void || !isvalid layer)
				{
					// 🔴 必须挂在 **primary 之下**，不是它的兄弟。
					//
					// 高亮是按 primary 的坐标算出来的；建成兄弟层时它的原点是 primary
					// **父层**的原点，两者相差 primary 自身的 left/top 与 imageLeft/Top。
					// 窗口一缩放这个差就变 —— 真机症状正是「缩放后高亮偏移」。挂到
					// primary 下之后，两边同系，缩放时一起走。
					layer = new Layer(global.kag, primary);
					global.kag.add(layer);
					layer.name = "Hibiki subtitle highlight";
					layer.fushiLookupIgnore = true;
					layer.type = ltAlpha;
					layer.absolute = 2147482000;
					layer.opacity = 255;
					layer.hitType = htMask;
					layer.hitThreshold = 256;
					layer.visible = false;
					global.fushiLookupHighlightLayer = layer;
					global.fushiLookupHighlightRect = void;
				}
				if(layer.imageWidth != primary.imageWidth ||
					layer.imageHeight != primary.imageHeight)
				{
					layer.setImageSize(primary.imageWidth, primary.imageHeight);
					layer.setSizeToImageSize();
					layer.setPos(0, 0);
					layer.fillRect(0, 0, layer.imageWidth, layer.imageHeight, 0);
					global.fushiLookupHighlightRect = void;
				}
				return layer;
			};

)TJS" LR"TJS(

			// 只擦上一次的包围盒，且只有命中字符**变化**时才会走到这里。prototype 每次
			// mousemove 都对一个 primaryLayer 尺寸的层做全屏 fillRect，那是按秒计的主线程开销。
			global.fushiLookupPaintHighlight = function(entry, offsetX, offsetY, start, length)
			{
				// Never paint over pixels whose logical owner was just retired. If the
				// transaction-external erase cannot finish, clear the hover de-dup key so
				// the same glyph retries on the next input instead of becoming permanent.
				if(!global.fushiLookupFlushPendingHighlightErase())
				{
					global.fushiLookupHoverKey = "";
					return;
				}
				// WGC 抓的是整个游戏 HWND；截图屏障生效期间，即使鼠标移动/新 submit 又走到
				// 高亮热路径，也不能把游戏内 Layer 画回截图。保留 hover 身份，恢复 full frame
				// 时仍可按当前 entry 重画。
				if(global.fushiLookupCaptureSuppressed)
				{
					var suppressedLayer = global.fushiLookupHighlightLayer;
					if(suppressedLayer !== void && isvalid suppressedLayer)
					{
						suppressedLayer.visible = false;
						suppressedLayer.update();
					}
					return;
				}
				var layer = global.fushiLookupEnsureHighlight();
				if(layer === void || !isvalid layer) return;
				var previous = global.fushiLookupHighlightRect;
				if(previous !== void)
					layer.fillRect(previous.x, previous.y, previous.w, previous.h, 0);
				global.fushiLookupHighlightRect = void;
				var glyphs = entry.glyphs;
				if(start < 0 || start >= glyphs.count || length <= 0)
				{
					layer.visible = false;
					layer.update();
					return;
				}
				var last = start + length - 1;
				if(last >= glyphs.count) last = glyphs.count - 1;
				var x0 = glyphs[start].x + offsetX, y0 = glyphs[start].y + offsetY;
				var x1 = x0 + glyphs[start].w, y1 = y0 + glyphs[start].h;
				for(var i = start + 1; i <= last; i++)
				{
					var g = glyphs[i];
					var gx = g.x + offsetX, gy = g.y + offsetY;
					if(gx < x0) x0 = gx;
					if(gy < y0) y0 = gy;
					if(gx + g.w > x1) x1 = gx + g.w;
					if(gy + g.h > y1) y1 = gy + g.h;
				}
				if(x0 < 0) x0 = 0;
				if(y0 < 0) y0 = 0;
				if(x1 > layer.imageWidth) x1 = layer.imageWidth;
				if(y1 > layer.imageHeight) y1 = layer.imageHeight;
				if(x1 <= x0 || y1 <= y0)
				{
					layer.visible = false;
					layer.update();
					return;
				}
				layer.colorRect(x0, y0, x1 - x0, y1 - y0, 0x31d7ff, 88);
				global.fushiLookupHighlightRect = %[x:x0, y:y0, w:x1 - x0, h:y1 - y0];
				layer.visible = true;
				layer.update();
			};

			global.fushiLookupClearHover = function()
			{
				if(global.fushiLookupHoverKey == "" &&
					global.fushiLookupHighlightRect === void) return;
				global.fushiLookupQueueHighlightErase(global.fushiLookupHighlightRect);
				global.fushiLookupHoverKey = "";
				global.fushiLookupHitEntry = void;
				global.fushiLookupHighlightRect = void;
			};

			// 收起 = 层不可见。不可见层在引擎里既不绘制也不参与命中，这是引擎最基本的语义，
			// 不像 alpha 穿透那样需要额外验证。层留着复用（下一次查词多半尺寸相近），只是
			// 绝不会停在"可见且可命中"的状态上。
			global.fushiLookupDismissNow = function()
			{
				// generic dismiss 是永久收卡；它必须退出临时截图状态。否则下一次普通 hover
				// 会被上一笔已经结束的制卡永久压住。
				global.fushiLookupCaptureSuppressed = false;
				global.fushiLookupCaptureSuppressSeq = 0;
				try
				{
					var card = global.fushiLookupCard;
					if(card !== void && isvalid card && card.visible)
					{
						card.visible = false;
						card.update();
					}
				}
				catch(e) {}
				global.fushiLookupCardSeq = 0;
				global.fushiLookupCardEntry = void;
				global.fushiLookupClearHover();
			};

			// Visual work is committed only after the registry/slot transaction has
			// returned. Clear the flag before touching a Layer so reentrant rendering
			// can queue another leaf without recursion or losing that later request.
			global.fushiLookupFlushVisualWork = function()
			{
				if(global.fushiLookupVisualFlushActive) return false;
				global.fushiLookupVisualFlushActive = true;
				var dismiss = global.fushiLookupPendingVisualDismiss;
				global.fushiLookupPendingVisualDismiss = false;
				try
				{
					if(dismiss) global.fushiLookupDismissNow();
					global.fushiLookupFlushPendingHighlightErase();
				}
				catch(e) { global.fushiLookupFault(); }
				global.fushiLookupVisualFlushActive = false;
				return !global.fushiLookupPendingVisualDismiss &&
					global.fushiLookupPendingHighlightEraseRect === void;
			};

			global.fushiLookupDismiss = function()
			{
				global.fushiLookupPendingVisualDismiss = true;
				return global.fushiLookupFlushVisualWork();
			};

)TJS" LR"TJS(

			// 临时隐藏仅服务于游戏窗口截图：保留 card seq、hover identity 与 submit fence，
			// 只让两个游戏内 Layer 不参与合成。success token 必须最后写；DLL 只有读到精确
			// seq 才会在下一次 continuous callback 向 host 确认。
			global.fushiLookupSuppressForCapture = function(seq)
			{
				global.fushiLookupCaptureSuppressSeq = 0;
				global.fushiLookupCaptureSuppressed = true;
				try
				{
					var card = global.fushiLookupCard;
					if(card !== void && isvalid card)
					{
						card.visible = false;
						card.update();
					}
					var highlight = global.fushiLookupHighlightLayer;
					if(highlight !== void && isvalid highlight)
					{
						highlight.visible = false;
						highlight.update();
					}
					global.fushiLookupCaptureSuppressSeq = seq;
				}
				catch(e)
				{
					// 保持 suppressed=true 以失败关闭；没有 success token，host 会有界失败，
					// 而不会把一张可能仍含 popup 的截图静默写进卡片。
					global.fushiLookupNoteError("captureSuppress", e);
					global.fushiLookupFault();
				}
			};

			// 只给人工 Esc 使用；generic dismiss 还承担 host 收卡/禁用/失败回滚，不能让
			// 那些路径推进人工取消 fence 或制造 notify 回环。没有可见卡时仍取消在途 submit，
			// 但返回 false，让游戏自己的 Esc 行为继续执行。
			global.fushiLookupCancelCurrent = function()
			{
				var hadVisibleCard = false;
				try
				{
					var card = global.fushiLookupCard;
					hadVisibleCard = global.fushiLookupCardSeq != 0 ||
						(card !== void && isvalid card && card.visible);
				}
				catch(e) {}
				var submitSeq = global.fushiLookupSubmitSeq;
				if(submitSeq > global.fushiLookupDismissedSubmitSeq)
				{
					// fence 先提交、notify 最后唤醒 DLL；这与 SubmitSeq 的 seqlock 发布顺序一致。
					global.fushiLookupDismissedSubmitSeq = submitSeq;
					global.fushiLookupNotify++;
				}
				global.fushiLookupDismiss();
				return hadVisibleCard;
			};

			// DLL 写像素**之前**调：把卡片层建/调到 anchor + cardW×cardH。第一次真要显示
			// 时才建层——没查词的时候游戏渲染树里根本没有这个对象。
			global.fushiLookupPrepare = function(anchorX, anchorY, cardW, cardH)
			{
				try
				{
					if(cardW <= 0 || cardH <= 0) return;
					var card = global.fushiLookupCard;
					if(card === void || !isvalid card)
					{
						// 先试带鼠标事件的子类；建不出来就退回普通 Layer。
						//
						// 真机实测：普通 `new Layer(...)` 建得出来（高亮层就是这么建的、
						// 用户看得见），而自定义子类建不出来 —— CardLayerMissing 因此常亮，
						// 卡片永远不显示。子类只多提供"卡片内鼠标事件转发"，不该由它决定
						// 卡片能不能出现：宁可先让卡片可见、暂时不能在卡片里点，也好过
						// 整张卡片都没有。退路走了就置位，别让降级悄悄发生。
						// 用 bootstrap 期自检的结论，不再每帧试错一次。
						// 🔴 必须挂在 **primary 之下**，不是它的兄弟。
						//
						// 两个后果都实测到了：① 兄弟层不在 KAG 的输入分发树里，卡片收
						// 不到按下/抬起/移动事件（input_count 恒 0 → 卡片内点击/嵌套查词
						// 全部失效，而属性自检显示 hitType=htRect 明明设上了）；
						// ② anchor 是 primary 坐标系的量，挂在祖父层下连 setPos 都在另一
						// 个坐标系里。高亮层此前踩的是同一个坑（缩放后偏移）。
						if(global.fushiLookupCardClassOk)
						{
							card = new FushiLookupCardLayer(global.kag,
								global.kag.primaryLayer);
						}
						else
						{
							card = new Layer(global.kag, global.kag.primaryLayer);
							global.fushiLookupMark(32);
						}
						global.kag.add(card);
						// 🔴 装饰性属性逐项隔离。它们都不该有权决定卡片能不能存在：
						// 真机实测 prepare 整体抛异常、卡片层永远建不出来，而退回普通
						// Layer 的那条路并没有被触发——说明抛的不是构造，是下面这些赋值
						// 里的某一个（引擎对 hitType/absolute 之类的取值范围各有脾气）。
						// 一个可选属性不被接受就把整张卡片废掉，是把小毛病放大成功能全灭。
						global.fushiLookupStep = 1;
						try { card.name = "Hibiki in-game lookup card"; } catch(e) {}
						global.fushiLookupStep = 2;
						try { card.fushiLookupIgnore = true; } catch(e) {}
						global.fushiLookupStep = 3;
						try { card.absolute = 2147483000; } catch(e) {}
						global.fushiLookupStep = 4;
						try { card.opacity = 255; } catch(e) {}
						global.fushiLookupStep = 5;
						try { card.hitType = htRect; } catch(e) {}
						global.fushiLookupStep = 6;
						// type 与 visible 是**必需**的（直通 alpha + 先隐藏），不隔离：
						// 它们失败就等于卡片没法正确显示，应该让外层如实记账。
						card.type = ltAlpha;
						card.visible = false;
						global.fushiLookupCard = card;
						global.fushiLookupStep = 7;
					}
					global.fushiLookupStep = 8;
					if(card.imageWidth != cardW || card.imageHeight != cardH)
					{
						card.setImageSize(cardW, cardH);
						card.setSizeToImageSize();
					}
					global.fushiLookupStep = 9;
					card.setPos(anchorX, anchorY);
					global.fushiLookupStep = 0;
				}
				catch(e)
				{
					// 建/调卡片层失败必须留痕，且要留**原因**：CardLayerMissing 只说得出
					// "层不在"，说不出为什么不在，那正是要靠一版版试才能收敛的东西。
					global.fushiLookupNoteError("prepare@step" + global.fushiLookupStep, e);
					global.fushiLookupFault();
				}
			};

)TJS" LR"TJS(

			// DLL 写完像素之后调（旧位图兼容路）。seq==0 或空尺寸 = 收起卡片。
			// 几何随帧一起传进来，这里当**不变量**用：与 prepare 时的层不一致就说明写像素
			// 与本次显示之间层被动过，露出来只会是半张错位的卡片，宁可等下一帧。
			global.fushiLookupApply = function(seq, highlightStart, highlightLen,
				anchorX, anchorY, cardW, cardH)
			{
				try
				{
					if(seq == 0 || cardW <= 0 || cardH <= 0)
					{
						global.fushiLookupDismiss();
						return;
					}
					var card = global.fushiLookupCard;
					if(card === void || !isvalid card) return;
					if(card.imageWidth != cardW || card.imageHeight != cardH ||
						card.left != anchorX || card.top != anchorY) return;
					// 完整结构帧就是截图后的恢复提交；先解除抑制，再显示卡片并重画高亮。
					global.fushiLookupCaptureSuppressed = false;
					global.fushiLookupCaptureSuppressSeq = 0;
					card.visible = true;
					card.update();
					var entry = global.fushiLookupHitEntry;
					// 卡片归属在这一刻定下（BUG-1606）：之后只有**这条**台词重绘才收卡。
					global.fushiLookupCardEntry = entry;
					if(entry !== void && highlightLen > 0)
						global.fushiLookupPaintHighlight(entry, global.fushiLookupHitOffsetX,
							global.fushiLookupHitOffsetY, highlightStart, highlightLen);
					// success token 最后提交。C++ 只认这个值；在 visible/update/highlight
					// 之前写会把半途异常误报成“已经完整绘制”。
					global.fushiLookupCardSeq = seq;
				}
				catch(e) {}
				global.fushiLookupFlushVisualWork();
			};

			// 兼容旧 host 的无像素高亮帧。绝不 prepare、改尺寸、改位置或把隐藏的卡重新
			// visible；新主路的 hover 已由 fushiLookupReport 在游戏线程同步完成。
			global.fushiLookupApplyHighlight = function(highlightStart, highlightLen)
			{
				try
				{
					var card = global.fushiLookupCard;
					if(card === void || !isvalid card || !card.visible ||
						global.fushiLookupCardSeq == 0) return;
					var entry = global.fushiLookupHitEntry;
					if(entry !== void && highlightLen > 0)
						global.fushiLookupPaintHighlight(entry, global.fushiLookupHitOffsetX,
							global.fushiLookupHitOffsetY, highlightStart, highlightLen);
				}
				catch(e) {}
				global.fushiLookupFlushVisualWork();
			};

			// 备路：主路（mainImageBufferForWrite）查询或求值失败时，host 把 cardW×cardH 的
			// 卡片写成 PNG 落在 %TEMP%，由这里 loadImages 进来。路径在 bootstrap 时由 DLL
			// 一次性代入，不参与任何运行期拼接；游戏目录始终不被写入（资产带 .sig 校验）。
			global.fushiLookupApplyPng = function(seq, highlightStart, highlightLen,
				anchorX, anchorY, cardW, cardH)
			{
				try
				{
					global.fushiLookupPrepare(anchorX, anchorY, cardW, cardH);
					var card = global.fushiLookupCard;
					if(card === void || !isvalid card) return;
					card.loadImages(global.fushiLookupCardPath);
					card.setSizeToImageSize();
					card.setPos(anchorX, anchorY);
					card.type = ltAlpha;
				}
				catch(e)
				{
					global.fushiLookupNoteError("applyPng", e);
				}
				global.fushiLookupApply(seq, highlightStart, highlightLen, anchorX, anchorY,
					cardW, cardH);
				global.fushiLookupFlushVisualWork();
			};

			// 输入转发。层事件给的是层内坐标；这里加回层位置换成视口坐标入队，减 anchor 仍由
			// DLL 做——帧元数据在它手上，层位置与当前帧 anchor 万一不同步时它的值才是对的。
			// 打包成一个正整数，DLL 取一次就是一个事件。
			global.fushiLookupQueueInput = function(kind, x, y, wheel)
			{
				var queue = global.fushiLookupInputQueue;
				var card = global.fushiLookupCard;
				if(card !== void && isvalid card)
				{
					x = x + card.left;
					y = y + card.top;
				}
				// 连续 move 就地合并：鼠标一秒能出上百个 move，逐个过共享内存毫无意义。
				if(kind == 0 && queue.count > 0 && (queue[queue.count - 1] & 15) == 0)
					queue.erase(queue.count - 1);
				if(x < -32768) x = -32768;
				if(x > 32767) x = 32767;
				if(y < -32768) y = -32768;
				if(y > 32767) y = 32767;
				if(wheel < -2048) wheel = -2048;
				if(wheel > 2047) wheel = 2047;
				var keys = 0;
				if(global.fushiLookupShiftDown) keys = keys | 1;
				queue.add((1 << 52) | ((y + 32768) << 36) | ((x + 32768) << 20) |
					((wheel + 2048) << 8) | (keys << 4) | kind);
				if(queue.count > 64) queue.erase(0);
				global.fushiLookupNotify++;
			};

			global.fushiLookupInputTake = function()
			{
				var queue = global.fushiLookupInputQueue;
				if(queue.count == 0) return 0;
				var packed = queue[0];
				queue.erase(0);
				return packed;
			};

)TJS" LR"TJS(

			// TextRender.render / done → renderer.getCharacters(0,0) 是本样本唯一命中的捕获
			// 边界（其余四条路径已被运行日志证伪）。只留自己的几何快照，绝不长期持有引擎
			// 返回的 characters 数组。
			global.fushiLookupCapture = function(renderer, capturePhase,
				expectedLease, expectedRenderEpoch, expectedBindRevision)
			{
				var entry = void;
				var slotAdoption = void;
				var logicalSlot = void;
				var entrySameLogical = false;
				try
				{
					// Capture 绝不创建/复用 registry entry。render wrapper 已经为这次
					// 原函数调用固定 lease+epoch；done 只允许复用仍驻留的精确 renderer。
					// 被 LRU 淘汰的 renderer 因而天然形成 tombstone，不需要永久保存文本。
					entry = global.fushiLookupFindEntry(renderer);
					if(!global.fushiLookupCaptureTokenCurrent(entry, renderer,
						expectedLease, expectedRenderEpoch)) return;
					var bindAttemptFloor = entry.bindAttemptRevision;
					var bindRevision = (typeof expectedBindRevision == "Integer") ?
						expectedBindRevision : global.fushiLookupBindRevision;
					if(renderer === void || renderer === null || !isvalid renderer ||
						typeof renderer.getCharacters != "Object") return;
					// getCharacters 可能是带私有 ObjThis 的 closure。再次 incontextof 到
					// 外层 MsgwinRender 会破坏该上下文，并在真机触发 void -> Object。
					var getCharacters = renderer.getCharacters;
					var characters = getCharacters(0, 0);
					if(characters === void || characters === null ||
						typeof characters != "Object" || !isvalid characters ||
						typeof characters.count != "Integer") return;
					// getCharacters 是游戏代码，允许重入。它返回后必须重新确认这仍是
					// 同一次 renderer lease/render epoch，才能触碰 entry 或 slot。
					if(!global.fushiLookupCaptureTokenCurrent(entry, renderer,
						expectedLease, expectedRenderEpoch)) return;
					var glyphs = [], line = "";
					var minX = 0, minY = 0, maxX = 0, maxY = 0;
					// Candidate pairing compares drawCh origins with glyph origins.  Width/height
					// belong to the hit box, not to the translation-invariant origin span.
					var originMinX = 0, originMinY = 0, originMaxX = 0, originMaxY = 0;
					var maxGlyphW = 0;
					for(var i = 0; i < characters.count; i++)
					{
						var character = characters[i];
						var text = global.fushiLookupField(character, "text");
						if(typeof text != "String" || text == "") continue;
						var x = global.fushiLookupField(character, "x");
						var y = global.fushiLookupField(character, "y");
						var w = global.fushiLookupField(character, "cw");
						var h = global.fushiLookupField(character, "size");
						if(x === void) x = global.fushiLookupField(character, "left");
						if(y === void) y = global.fushiLookupField(character, "top");
						if(w === void) w = global.fushiLookupField(character, "width");
						if(h === void) h = global.fushiLookupField(character, "height");
						if(x === void || y === void || w === void || h === void) continue;
						if(w <= 0 || h <= 0) continue;
						if(glyphs.count == 0)
						{
							minX = x; minY = y; maxX = x + w; maxY = y + h;
							originMinX = x; originMaxX = x;
							originMinY = y; originMaxY = y;
						}
						else
						{
							if(x < minX) minX = x;
							if(y < minY) minY = y;
							if(x + w > maxX) maxX = x + w;
							if(y + h > maxY) maxY = y + h;
							if(x < originMinX) originMinX = x;
							if(x > originMaxX) originMaxX = x;
							if(y < originMinY) originMinY = y;
							if(y > originMaxY) originMaxY = y;
						}
						if(w > maxGlyphW) maxGlyphW = w;
						glyphs.add(%[ch:text, x:x, y:y, w:w, h:h]);
						line += text;
					}
					if(glyphs.count == 0) return;
					// 采集真的产出了几何。只在 0→1 那一次搭 notify 的车通知 DLL，之后
					// 每行台词都不再有额外开销。
					if(global.fushiLookupGeometry == 0)
					{
						global.fushiLookupGeometry = 1;
						global.fushiLookupNotify++;
					}
					// 这一趟渲染里 bindOrigin 生效了不止一次 = drawCh 确实逐字调用。
					// ox/oy 本身是整行共享原点；逐字位置来自 ch.x/ch.y，并已在 BindOrigin
					// 合成为实际 drawX/drawY 后再累计。
					global.fushiLookupBindTicks = 0;
					var resolvedCurrent = global.fushiLookupResolveCurrentSlot();
					if(capturePhase != 3 && resolvedCurrent !== void)
					{
						if(!global.fushiLookupCaptureTokenCurrent(entry, renderer,
							expectedLease, expectedRenderEpoch)) return;
						entry.observedPage = resolvedCurrent.page;
						entry.observedIndex = resolvedCurrent.index;
						entry.observedIdentity = resolvedCurrent.identity;
					}
					// resolvedCurrent 只是后面 candidate 的身份证据，不在这里采纳 slot。
					// canonical slot 必须先由 best.host 投影出 anchorPage/index，否则
					// global current 会把交错的姓名/正文 renderer 退休到错页。
					// 解出「渲染器局部坐标 → 图层坐标」的平移量。
					//
					// 两边都是同一批字符、同一个纯平移，所以最小值必然落在同一个字上：
					//   平移量 = min(drawCh 的 ox) - min(字形 x)
					// 这样解还有一个不靠假设的好处——**基线 vs 顶边、内边距、字距**这类
					// 约定差异是常量，会被减法自动吸收；换成"认定 oy 是基线再补 ascent"
					// 那种写法，一换引擎/字体就重新错一遍。
					//
					// 打字机动画下一趟只画新出现的几个字，本趟 min(ox) 未必是行首。所以
					// 同一行内取**累计**最小值（换行才重置）：行首字一旦画过，平移量就锁
					// 定正确，之后不再漂。
					// 锚点解析只要求「这个 renderer 绑过绘制层」，不要求本趟渲染内绑过：
					// 淡入是由持续回调驱动的，drawCh 完全可能落在 render() 之外，那时
					// passHas 为假。把锚点一起门控掉，结果是 entry.layer 永远是 void、
					// 整条记录被跳过——真机上表现为"什么都不发生"，连未命中都不记。
					// 用**跨度**把这一行与它的宿主层配对：同一行的 drawCh 落点与字形坐标
					// 只差一个常数平移，所以 (maxOx-minOx) 必然等于 (maxX-minX)。身份和
					// 时序在本引擎都不可靠，几何是唯一站得住的判据。
					var best = void;
					var bestErr = 0;
					// candidate 先全部解到局部变量，下面不读/写 entry 的绑定。
					// 这使宿主、KAG 页或 image 属性在表情切换中抛异常时，同句的旧
					// binding 仍是一条完整快照，而不是被拆成一半。
					var candidateReady = false;
					var candidateStrength = 0;
					var candidateLayer = void;
					var candidateVisibleHost = void;
					var candidateCurrentIdentity = void;
					var candidateHostPage = 0;
					var candidateAnchorPage = 0;
					var candidateAnchorKind = 0;
					var candidateAnchorIndex = -1;
					var candidateBaseOx = 0;
					var candidateBaseOy = 0;
					var candidateOriginX = 0;
					var candidateOriginY = 0;
					var candidateImgLeft = 0;
					var candidateImgTop = 0;
					var glyphOriginSpanX = originMaxX - originMinX;
					var glyphOriginSpanY = originMaxY - originMinY;

)TJS" LR"TJS(

					var groups = global.fushiLookupBindGroups;
					var spanMatchCount = 0;
					var visibleMatchCount = 0;
					for(var gi = 0; gi < groups.count; gi++)
					{
						var g = groups[gi];
						if(capturePhase == 3 &&
							(g.revision <= bindAttemptFloor || g.revision > bindRevision))
							continue;
						if(g.host === void || g.host === null || !isvalid g.host) continue;
						if(g.count <= 0) continue;
						if(!global.fushiLookupBindGroupAnchorValid(g)) continue;
						// A refresh may be woken by any renderer's drawCh.  Once an entry has a
						// proven slot, or render/done observed one, never let a similarly sized
						// name/body group migrate it to another KAG message slot.
						var expectedPage = (entry.slotPage != 0) ? entry.slotPage :
							entry.observedPage;
						var expectedIndex = (entry.slotPage != 0) ? entry.slotIndex :
							entry.observedIndex;
						if(capturePhase == 3 && (expectedPage == 0 || expectedIndex < 0 ||
							g.anchorPage != expectedPage || g.anchorIndex != expectedIndex))
							continue;
						// Both sets are origins in their respective coordinate spaces, so a pure
						// translation preserves their spans.  BindGroup extrema are reset per draw
						// run below; historical lines therefore cannot make this comparison pass.
						// One glyph has span zero and pairs with a one-glyph draw run.  The X
						// tolerance admits at most one not-yet-complete typewriter advance; larger
						// differences (such as name vs dialogue) fail closed and keep the old bind.
						var spanErrX = Math.abs((g.maxOx - g.minOx) - glyphOriginSpanX);
						var spanErrY = Math.abs((g.maxOy - g.minOy) - glyphOriginSpanY);
						var toleranceX = maxGlyphW + 2;
						if(toleranceX < 2) toleranceX = 2;
						var toleranceY = 2;
						if(spanErrX > toleranceX || spanErrY > toleranceY) continue;
						spanMatchCount++;
						// drawCh 的逐字淡入宿主会在角色口型/表情切换时转为 hidden，即使最终
						// KAG message 仍在屏上。可见性必须由冻结的 current identity / message
						// anchor 证明；短命 host 只保留为页交换兼容回退。
						if(!global.fushiLookupBindGroupVisible(g)) continue;
						visibleMatchCount++;
						var err = spanErrX + spanErrY;
						if(best === void || err < bestErr ||
							(err == bestErr && g.clock > best.clock))
						{
							best = g;
							bestErr = err;
						}
					}
					// 容差按字宽给：半个字以内算同一行，超出就宁可不认——错认比不认更糟，
					// 卡片会稳定地弹在另一行上。
					if(best !== void)
					{

)TJS" LR"TJS(

						// 🔴 锚点必须是 **KAG 的消息层**，不是 drawCh 那条父链。
						//
						// 实测：文字子层「表メッセージレイヤ0:テキスト」自报 top=0，父链
						// 一路 0 到 primary，于是算出文字在画面顶部；而 kag.fore.messages[0]
						// 报 (0,752)，752+行原点135=887，与实测的 880 吻合。子层的 top 不是
						// 它的屏幕位置——真相只在 KAG 的消息层上。
						//
						// 尺寸不能拿来认领身份：同一页可以有多个同尺寸消息层，“取第一个”会
						// 稳定拿到 top=0 的闲置层。KAG 自己维护的身份真值是 currentNum；页交换
						// 后 currentPage 会变，但 fore/back.messages[currentNum] 仍是同一逻辑消息
						// 层。先按绘制宿主页投影 currentNum；旧/定制 KAG 若不暴露 currentNum，
						// 再从 current 的对象身份找数组下标并投影到宿主页。绝不跨页按尺寸首取。
						var anchorMsg = best.anchorIdentity;
						var anchorPage = best.anchorPage;
						var anchorKind = (best.anchorStrength >= 2) ? 2 : 1;
						var anchorIndex = best.anchorIndex;
						var hostPage = best.hostPage;
						var identityEvidence = resolvedCurrent;
						if(identityEvidence === void)
							identityEvidence = global.fushiLookupResolveCurrentSlot();
						var currentMsg = (identityEvidence === void) ? void :
							identityEvidence.identity;
						var identityIndex = (identityEvidence === void) ? -1 :
							identityEvidence.index;
						var identityPage = (identityEvidence === void) ? 0 :
							identityEvidence.page;
						// 只有 current 自身确实位于 candidate 的同一页/同一下标，才保存可绕过
						// visibleHost 的稳定身份。currentNum 单独相等不够，页交换时会复用下标。
						if(anchorKind != 0 && anchorPage != 0 && anchorIndex >= 0 &&
							currentMsg !== void && currentMsg !== null && isvalid currentMsg &&
							identityPage == anchorPage && identityIndex == anchorIndex &&
							currentMsg === anchorMsg)
							candidateCurrentIdentity = currentMsg;
						candidateStrength = (candidateCurrentIdentity !== void) ? 2 :
							((anchorKind != 0 && anchorPage != 0 && anchorIndex >= 0) ? 1 : 0);
						// 坐标使用冻结的 KAG message；可见性在 Capture/Probe 都接受稳定
						// message 或短命 draw host 任一路，兼容口型 hidden 与页交换两种时序。
						candidateLayer = (anchorMsg !== void && isvalid anchorMsg)
							? anchorMsg : best.host;
						candidateVisibleHost = best.host;
						candidateHostPage = hostPage;
						candidateAnchorPage = anchorPage;
						candidateAnchorKind = anchorKind;
						candidateAnchorIndex = anchorIndex;
						candidateBaseOx = best.minOx;
						candidateBaseOy = best.minOy;
						candidateOriginX = candidateBaseOx - minX;
						candidateOriginY = candidateBaseOy - minY;
						try
						{
							candidateImgLeft = candidateLayer.imageLeft;
							candidateImgTop = candidateLayer.imageTop;
						}
						catch(e)
						{
							candidateImgLeft = 0;
							candidateImgTop = 0;
						}
						candidateReady = true;
					}

					// 严格 current getter 不可得时，currentNum 投影出的 page/index 仍能
					// 在 candidate 完整后纳入世代。若连 slot 也无法识别，才退回 renderer
					// 本地 logicalLine；这个降级不能退休其他 renderer。
					if(slotAdoption === void && candidateAnchorKind != 0 &&
						candidateAnchorPage != 0 && candidateAnchorIndex >= 0)
					{
						// A phase-3 refresh is globally woken; it may never migrate an already
						// associated (or render-observed) renderer to the other name/body slot.
						var fixedPage = (entry.slotPage != 0) ? entry.slotPage :
							entry.observedPage;
						var fixedIndex = (entry.slotPage != 0) ? entry.slotIndex :
							entry.observedIndex;
						if(capturePhase == 3 && (fixedPage == 0 || fixedIndex < 0 ||
							candidateAnchorPage != fixedPage ||
							candidateAnchorIndex != fixedIndex)) candidateReady = false;
						if(!candidateReady) slotAdoption = void;
						else
						{
						if(!global.fushiLookupCaptureTokenCurrent(entry, renderer,
							expectedLease, expectedRenderEpoch)) return;
						slotAdoption = global.fushiLookupAdoptSlot(entry, line,
							candidateAnchorPage, candidateAnchorIndex,
							candidateCurrentIdentity, capturePhase);
						if(slotAdoption.stale) return;
						logicalSlot = slotAdoption.slot;
						entrySameLogical = slotAdoption.same;
						}
					}
					if(slotAdoption === void)
					{
						if(!global.fushiLookupCaptureTokenCurrent(entry, renderer,
							expectedLease, expectedRenderEpoch)) return;
						entrySameLogical = entry.logicalLine == line;
						if(!entrySameLogical)
						{
							// 同一个已关联 renderer 先报告了异句、但这轮 drawCh candidate
							// 尚未齐全：冻结它所属 slot 的旧 active，防止 MessageLayer 对象
							// 复用期间把屏上的新句命中成旧字形。只定向处理已证明归属的
							// slot；无法归属的姓名/表情临时 renderer 不影响正文。
							if(entry.slotPage != 0 && entry.slotIndex >= 0)
							{
								var owned = global.fushiLookupFindSlot(
									entry.slotPage, entry.slotIndex);
								if(owned !== void && owned.activeEntry === entry)
								{
									owned.activeEntry = void;
									owned.activeStrength = 0;
								}
							}
							entry.glyphs = [];
							entry.line = "";
							global.fushiLookupClearEntryBinding(entry);
							if(!global.fushiLookupCaptureTokenCurrent(entry, renderer,
								expectedLease, expectedRenderEpoch)) return;
							entry.logicalLine = line;
							entry.slotPage = 0;
							entry.slotIndex = -1;
							entry.slotGeneration++;
						}
					}

					// 已识别 slot 时，candidate 必须回到同一 page/index；其他页的最新
					// visible host 不是当前台词。同一逻辑世代内强度只能不降：
					// strict current identity(2) > currentNum slot(1) > host-only(0)。
					if(candidateReady && logicalSlot !== void &&
						(candidateAnchorPage != logicalSlot.page ||
						candidateAnchorIndex != logicalSlot.index)) candidateReady = false;
					// 同一 active entry 的瞬时弱 candidate 不能把严格 current identity
					// 降成 currentNum/host-only。口型/表情重绘正会反复经过这里；保留
					// 强 binding 后，只更新本轮字形即可。
					if(candidateReady && entrySameLogical && entry.hasBase &&
						candidateStrength < entry.bindingStrength) candidateReady = false;
					if(candidateReady && logicalSlot !== void &&
						logicalSlot.activeEntry !== void &&
						logicalSlot.activeEntry !== entry &&
						logicalSlot.line == line)
					{
						var activeEntry = logicalSlot.activeEntry;
						var activeUsable = activeEntry.glyphs.count > 0 && activeEntry.hasBase &&
							activeEntry.slotGeneration == logicalSlot.generation &&
							activeEntry.slotPage == logicalSlot.page &&
							activeEntry.slotIndex == logicalSlot.index;
						if(activeUsable)
						{
							var activeIdentityState = global.fushiLookupCurrentIdentityState(activeEntry);
							activeUsable = activeIdentityState > 0 ||
								(activeIdentityState == 0 &&
								global.fushiLookupEntryVisible(activeEntry));
						}
						// 同句完整、几何相容且可见的 candidate 不被历史强度
						// 永久冻结。旧 active 仍可用时保持它；宿主 hidden/失效后 B
						// 才原子接管。B 的 strength=1 之后不能绕过 hidden，但不会
						// 被已死 strength=2 A 锁死。
						// 更强的 strict-current candidate 可立即接管；同强/更弱的 B
						// 仅在 A 已不可用时接管。否则一次短命弱宿主会抢走稳定身份，
						// 但也不能让可见的弱 A 永久挡住表情切换后的唯一强 B。
						if(activeUsable && candidateStrength <= logicalSlot.activeStrength)
							candidateReady = false;
					}

)TJS" LR"TJS(

					if(global.fushiLookupCaptureTraceBudget > 0)
					{
						var group0SpanX = -1, group0SpanY = -1, group0Count = -1;
						var group1SpanX = -1, group1SpanY = -1, group1Count = -1;
						if(groups.count > 0)
						{
							group0SpanX = groups[0].maxOx - groups[0].minOx;
							group0SpanY = groups[0].maxOy - groups[0].minOy;
							group0Count = groups[0].count;
						}
						if(groups.count > 1)
						{
							group1SpanX = groups[1].maxOx - groups[1].minOx;
							group1SpanY = groups[1].maxOy - groups[1].minOy;
							group1Count = groups[1].count;
						}
						var captureTrace = "ph=" + capturePhase + ",g=" + glyphs.count +
							",bg=" + groups.count + ",sm=" + spanMatchCount +
							",vm=" + visibleMatchCount + ",b=" +
							((best === void) ? 0 : 1) + ",cr=" +
							(candidateReady ? 1 : 0) + ",ak=" + candidateAnchorKind +
							",ap=" + candidateAnchorPage + ",ai=" + candidateAnchorIndex +
							",sa=" + ((slotAdoption === void) ? 0 : 1) + ",ls=" +
							((logicalSlot === void) ? 0 : 1) + ",same=" +
							(entrySameLogical ? 1 : 0) + ",base=" +
							(entry.hasBase ? 1 : 0) + ",sx=" + glyphOriginSpanX +
							",sy=" + glyphOriginSpanY + ",g0=" + group0SpanX + "/" +
							group0SpanY + "/" + group0Count + ",g1=" + group1SpanX +
							"/" + group1SpanY + "/" + group1Count + ",be=" + bestErr;
						if(captureTrace != global.fushiLookupCaptureTraceLast)
						{
							global.fushiLookupCaptureTraceLast = captureTrace;
							global.fushiLookupCaptureTraceBudget--;
							global.fushiLookupNoteError("capture.shape", %[message:captureTrace]);
						}
					}

)TJS" LR"TJS(

					if(!global.fushiLookupCaptureTokenCurrent(entry, renderer,
						expectedLease, expectedRenderEpoch)) return;
					entry.used = ++global.fushiLookupClock;
					if(candidateReady)
					{
						if(logicalSlot !== void)
							global.fushiLookupRetireAnchorPeers(entry,
								logicalSlot.page, logicalSlot.index);
						if(!global.fushiLookupCaptureTokenCurrent(entry, renderer,
							expectedLease, expectedRenderEpoch)) return;
						entry.glyphs = glyphs;
						entry.line = line;
						entry.minX = minX;
						entry.minY = minY;
						entry.maxX = maxX;
						entry.maxY = maxY;
						entry.layer = candidateLayer;
						entry.visibleHost = candidateVisibleHost;
						entry.currentIdentity = candidateCurrentIdentity;
						entry.bindingStrength = candidateStrength;
						entry.hostPage = candidateHostPage;
						entry.anchorPage = candidateAnchorPage;
						entry.anchorKind = candidateAnchorKind;
						entry.anchorIndex = candidateAnchorIndex;
						entry.baseOx = candidateBaseOx;
						entry.baseOy = candidateBaseOy;
						entry.hasBase = true;
						entry.originX = candidateOriginX;
						entry.originY = candidateOriginY;
						entry.imgLeft = candidateImgLeft;
						entry.imgTop = candidateImgTop;
						entry.passMinOx = 0;
						entry.passMinOy = 0;
						entry.passHas = false;
						entry.passLayer = void;
						if(logicalSlot !== void)
						{
							logicalSlot.activeEntry = entry;
							logicalSlot.activeStrength = candidateStrength;
						}
						// Hide the previous card only after the new slot/entry snapshot is fully
						// committed. A stale outer Capture must not hide a newer reentrant card.
						if(slotAdoption !== void && slotAdoption.advanced)
							global.fushiLookupPendingVisualDismiss = true;
					}
					else if(entrySameLogical && entry.hasBase)
					{
						// 同句的无 candidate/弱 candidate 只更新字形，旧的强 binding
						// 与 currentIdentity 原样保留，等 getter/visibleHost 恢复后继续命中。
						entry.glyphs = glyphs;
						entry.line = line;
						entry.minX = minX;
						entry.minY = minY;
						entry.maxX = maxX;
						entry.maxY = maxY;
					}
					else
					{
						entry.glyphs = [];
						entry.line = "";
						if(entry.hasBase) global.fushiLookupClearEntryBinding(entry);
						if(!global.fushiLookupCaptureTokenCurrent(entry, renderer,
							expectedLease, expectedRenderEpoch)) return;
					}
				}
				catch(e)
				{
					// 可识别 slot 的新异句已在 candidate 前推进 generation/退休 peer；
					// 同句异常则不动 active binding。这里只记错，不再做会倒退状态的回滚。
					global.fushiLookupNoteError("capture", e);
					global.fushiLookupFault();
				}
			};

			// Capture 中会调用 getCharacters 与多段游戏 getter，它们都可能重入渲染
			// 并复用 registry entry。每个首次触碰 entry/slot 的发布边界前统一再校验
			// lease+epoch，避免外层 Capture 在 ABA 后改写新 renderer 的状态。
			global.fushiLookupCaptureTokenCurrent = function(entry, renderer,
				expectedLease, expectedRenderEpoch)
			{
				return entry !== void && expectedLease > 0 &&
					global.fushiLookupFindEntry(renderer) === entry &&
					entry.renderer === renderer && entry.rendererLease == expectedLease &&
					entry.renderEpoch == expectedRenderEpoch &&
					expectedRenderEpoch > entry.retiredRenderEpoch;
			};

			global.fushiLookupMessagesForPage = function(page)
			{
				try
				{
					if(page == 1) return global.kag.fore.messages;
					if(page == 2) return global.kag.back.messages;
				}
				catch(e) {}
				return void;
			};


)TJS" LR"TJS(

			// ── classic KAG3 采集面 ──────────────────────────────────────────────────
			// KAGEX 的 TextRender 只存在于装了 textrender.dll 的游戏（ATRI、天使☆騒々）。
			// 经典 KAG3 游戏（Fate/stay night[Realta Nua]、PRETTY×CATION2、フタマタ恋愛）
			// 整个 global.TextRender 都不存在，上面那条捕获路径一次都绑不上——这些游戏里逐字
			// 几何**只**从原生 Layer.drawText 经过：无论上层 KAG 系统脚本被游戏改成什么样，
			// 每个字最终都要走这一个原生方法。所以它是这类游戏唯一正确的采集面，不是"又一条
			// 兜底"。
			//
			// 产出与 fushiLookupCapture 逐字段同形（glyphs/line/包围盒/layer/origin），下游
			// 命中测试、高亮、上报一行都不用分支：drawText 的 x/y 已经是该 layer 的图像坐标，
			// 所以 origin 恒为 0。
			//
			// 段落边界不靠 hook 清屏，靠横书推进本身的不变式：字要么同行右移、要么换行下移。
			// 一旦回到左上，就是这一层开始画下一屏文本。竖排在此判据外（plan 的非目标），
			// 竖排游戏会退化成每列重开一段——命中仍然正确，只是整行文本按列切碎。
			global.fushiLookupCaptureDrawText = function(layer, x, y, text)
			{
				try
				{
					if(typeof text != "String" || text == "") return;
					if(layer === void || layer === null || !isvalid layer) return;
					// 卡片层与高亮层是我们自己建的，绝不能把它们当台词采集回来。
					if(typeof layer.fushiLookupIgnore != "undefined") return;
					if(typeof x != "Integer" && typeof x != "Real") return;
					if(typeof y != "Integer" && typeof y != "Real") return;
					var font = layer.font;
					if(font === void || font === null || !isvalid font) return;
					// KiriKiri 允许负 height 表示"按像素而非 pt"，几何要的是绝对值。
					var h = font.height;
					if(h < 0) h = -h;
					if(h <= 0) return;
					var entry = global.fushiLookupEntryFor(layer);
					var glyphs = entry.glyphs;
					var restart = glyphs.count == 0;
					if(!restart)
					{
						var last = glyphs[glyphs.count - 1];
						if(y < last.y) restart = true;
						else if(y == last.y && x <= last.x) restart = true;
						// 上界：没被上面判据认出来的清屏不至于让一层无限长。
						else if(glyphs.count >= 512) restart = true;
					}
					if(restart)
					{
						glyphs = [];
						entry.glyphs = glyphs;
						entry.line = "";
						// 与 fushiLookupCapture 同一条 BUG-1606 归属判据：只有这张卡自己依附的
						// 那条台词换了才收卡；逐字推进（restart==false）一次都不收。
						if(global.fushiLookupCardEntry === entry)
							global.fushiLookupDismiss();
						else if(global.fushiLookupHitEntry === entry)
							global.fushiLookupClearHover();
					}
					// glyphs 与 line 必须逐字符 1:1——host 拿 charIndex 去 line 里切词。
					var cursor = x;
					var line = entry.line;
					var added = 0;
					for(var i = 0; i < text.length; i++)
					{
						var ch = text.charAt(i);
						var w = font.getTextWidth(ch);
						if(typeof w != "Integer" && typeof w != "Real") continue;
						if(w <= 0) continue;
						glyphs.add(%[ch:ch, x:cursor, y:y, w:w, h:h]);
						line += ch;
						cursor += w;
						added++;
					}
					if(added == 0) return;
					entry.line = line;
					// 包围盒增量维护：drawText 逐字调用，每次重扫全量就是 O(n^2)。
					if(added == glyphs.count)
					{
						entry.minX = x;
						entry.minY = y;
						entry.maxX = cursor;
						entry.maxY = y + h;
					}
					else
					{
						if(x < entry.minX) entry.minX = x;
						if(y < entry.minY) entry.minY = y;
						if(cursor > entry.maxX) entry.maxX = cursor;
						if(y + h > entry.maxY) entry.maxY = y + h;
					}
					entry.layer = layer;
					entry.originX = 0;
					entry.originY = 0;
					entry.used = ++global.fushiLookupClock;
					// 位 1 = drawText 真捕到过字形（位 0 = 补丁装上了）。
					global.fushiLookupClassicSource = global.fushiLookupClassicSource | 2;
				}
				catch(e) {}
			};

			// MessageLayer.processCh 探针。**只自证是否触发**，不产出几何：KAG3 的 MessageLayer
			// 把字符位置放在自己的行对象里，字段名各游戏改得千差万别，没有真机确认之前编造
			// 字段名只会造出一条看起来在跑、实际全是 void 的假采集面。先用真机判「字到底走不
			// 走这里」，再按实测到的结构补几何。
			global.fushiLookupCaptureProcessCh = function(layer, ch)
			{
				try
				{
					if(typeof ch != "String" || ch == "") return;
					global.fushiLookupClassicSource = global.fushiLookupClassicSource | 4;
				}
				catch(e) {}
			};

			// Freeze the KAG message slot while drawCh is actually executing.  A later
			// mouse event must not project an arbitrary historical host through the then
			// current currentNum; doing so aliases the coexisting name/body renderers.
			global.fushiLookupStampBindGroup = function(group, host)
			{
				group.hostPage = global.fushiLookupPageOf(host);
				group.anchorPage = 0;
				group.anchorIndex = -1;
				group.anchorIdentity = void;
				group.currentIdentity = void;
				group.anchorStrength = 0;
				var messages = global.fushiLookupMessagesForPage(group.hostPage);
				var currentNum = global.fushiLookupField(global.kag, "currentNum");
				if(messages !== void && typeof currentNum == "Integer" &&
					currentNum >= 0 && currentNum < messages.count)
				{
					try
					{
						var indexed = messages[currentNum];
						if(indexed !== void && indexed !== null && isvalid indexed)
						{
							group.anchorIdentity = indexed;
							group.anchorPage = global.fushiLookupPageOf(indexed);
							group.anchorIndex = currentNum;
							group.anchorStrength = 1;
						}
					}
					catch(e) {}
				}
				var resolved = global.fushiLookupResolveCurrentSlot();
				if(resolved !== void && messages !== void && resolved.index >= 0 &&
					resolved.index < messages.count)
				{
					try
					{
						var projected = messages[resolved.index];
						if(projected !== void && projected !== null && isvalid projected &&
							(group.anchorIdentity === void ||
							 (resolved.page == group.anchorPage &&
							  resolved.index == group.anchorIndex)))
						{
							group.anchorIdentity = projected;
							group.anchorPage = global.fushiLookupPageOf(projected);
							group.anchorIndex = resolved.index;
							if(resolved.page == group.anchorPage &&
								resolved.identity === projected)
							{
								group.currentIdentity = resolved.identity;
								group.anchorStrength = 2;
							}
						}
					}
					catch(e) {}
				}
			};

			global.fushiLookupBindGroupAnchorValid = function(group)
			{
				if(group.anchorPage == 0 || group.anchorIndex < 0 ||
					group.anchorIdentity === void || group.anchorIdentity === null ||
					!isvalid group.anchorIdentity) return false;
				var messages = global.fushiLookupMessagesForPage(group.anchorPage);
				if(messages === void || group.anchorIndex >= messages.count) return false;
				try { return messages[group.anchorIndex] === group.anchorIdentity; }
				catch(e) { return false; }
			};

			global.fushiLookupBindGroupVisible = function(group)
			{
				if(!global.fushiLookupBindGroupAnchorValid(group)) return false;
				try
				{
					if(group.currentIdentity !== void && group.currentIdentity !== null &&
						isvalid group.currentIdentity)
					{
						var resolved = global.fushiLookupResolveCurrentSlot();
						if(resolved !== void && resolved.page == group.anchorPage &&
							resolved.index == group.anchorIndex &&
							resolved.identity === group.currentIdentity) return true;
					}
					if(global.fushiLookupVisible(group.anchorIdentity)) return true;
					if(group.host !== void && group.host !== null && isvalid group.host &&
						global.fushiLookupVisible(group.host)) return true;
				}
				catch(e) {}
				return false;
			};

)TJS" LR"TJS(

			// drawCh 是逐字符调用。KAGEX 的 ox/oy 是整行共享原点，字符自身位置在
			// ch.x/ch.y；真正落点必须是两者相加。只累计 ox/oy 会得到 count>1 但跨度
			// 永远 0/0，导致任何非单字行都不可能通过 Capture 的几何配对。
			global.fushiLookupBindOrigin = function(renderer, layer, originX, originY, ch)
			{
				if(layer === void || layer === null || !isvalid layer) return;
				if(typeof originX != "Integer" && typeof originX != "Real") return;
				if(typeof originY != "Integer" && typeof originY != "Real") return;
				var charX = global.fushiLookupField(ch, "x");
				var charY = global.fushiLookupField(ch, "y");
				if((typeof charX != "Integer" && typeof charX != "Real") ||
					(typeof charY != "Integer" && typeof charY != "Real")) return;
				var drawX = originX + charX;
				var drawY = originY + charY;
				if(global.fushiLookupBoundRenderer === renderer &&
					global.fushiLookupBoundLayer === layer &&
					global.fushiLookupBoundX == drawX &&
					global.fushiLookupBoundY == drawY) return;
				global.fushiLookupBindTicks++;
				// drawX/drawY 与 getCharacters 的 x/y 是同一批字符在不同坐标系中的
				// 原点集合，两者只差整行平移；跨度可用于姓名/正文隔离。
				//
				// 🔴 累加器必须挂在 **entry（即 renderer）** 上，不能是全局。屏幕上会
				// 同时有多行文字各自淡入，多个渲染器的 drawCh 交错到来；用全局累加，
				// min(ox) 会取到 A 行的 x、min(oy) 取到 B 行的 y，锚点层也会被最后一次
				// 绑定换成另一行的。真机实测就是这样：base=(468,135) 里 468 是底部那行的
				// x、135 是顶部那行的 y——一个坐标原点由两行拼出来，必然谁都对不上。
				// 落点按**父层**分组累加。父层就是这行文字真正的坐标空间（drawCh 给的是
				// 逐字符淡入层，49x68 只装得下一个字）。
				var host = layer.parent;
				if(host === void || host === null || !isvalid host) host = layer;
				var groups = global.fushiLookupBindGroups;
				var slot = void;
				for(var gi = 0; gi < groups.count; gi++)
				{
					if(groups[gi].host === host) { slot = groups[gi]; break; }
				}
				if(slot === void)
				{
					// 先清退役宿主；全部有效时再清 clock 最小的最久未用项。
					// 表情/口型动画会频繁创建短命 drawCh 层，FIFO erase(0) 会把仍在
					// 刷新的消息宿主误删，随后同句 Capture 就再也找不到 candidate。
					if(groups.count >= 8)
					{
						var victim = 0;
						var victimClock = groups[0].clock;
						for(var vi = 0; vi < groups.count; vi++)
						{
							var victimHost = groups[vi].host;
							if(victimHost === void || victimHost === null || !isvalid victimHost)
							{
								victim = vi;
								break;
							}
							if(groups[vi].clock < victimClock)
							{
								victim = vi;
								victimClock = groups[vi].clock;
							}
						}
						groups.erase(victim);
					}
					slot = %[host:host, minOx:drawX, maxOx:drawX,
						minOy:drawY, maxOy:drawY, lastOx:drawX, lastOy:drawY,
						count:0, clock:0, revision:0, hostPage:0,
						anchorPage:0, anchorIndex:-1, anchorIdentity:void,
						currentIdentity:void, anchorStrength:0];
					groups.add(slot);
					global.fushiLookupStampBindGroup(slot, host);
				}
				// One TextRender entry can wrap over several visual rows (observed bbox height
				// exceeds 90px).  Moving down to larger Y plus an X rewind is still the same
				// run, so keep all row extrema.  Reset only when Y clearly moves upward, or
				// when drawing returns near this run's top baseline and X also rewinds.
				// Two pixels absorb integer/sub-pixel conversion jitter.
				var yRewound = drawY < slot.lastOy - 2;
				var returnedTop = drawY <= slot.minOy + 2 && drawX < slot.lastOx - 2;
				var newRun = slot.count > 0 && (yRewound || returnedTop);
				if(newRun)
				{
					slot.minOx = drawX;
					slot.maxOx = drawX;
					slot.minOy = drawY;
					slot.maxOy = drawY;
					slot.count = 0;
					global.fushiLookupStampBindGroup(slot, host);
				}
				if(drawX < slot.minOx) slot.minOx = drawX;
				if(drawX > slot.maxOx) slot.maxOx = drawX;
				if(drawY < slot.minOy) slot.minOy = drawY;
				if(drawY > slot.maxOy) slot.maxOy = drawY;
				slot.count++;
				slot.lastOx = drawX;
				slot.lastOy = drawY;
				slot.clock = ++global.fushiLookupClock;
				slot.revision = ++global.fushiLookupBindRevision;
				// 本引擎的 drawCh this 与 render this 不保证相同；不能靠 renderer identity
				// 唤醒 Capture。全局 revision 只说明“出现了新几何”，Probe 重跑后仍必须通过
				// span + visibleHost + page/index 三道门，绝不按最新组直接认领。
				global.fushiLookupBoundRenderer = renderer;
				global.fushiLookupBoundLayer = layer;
				global.fushiLookupBoundX = drawX;
				global.fushiLookupBoundY = drawY;
			};

			// Mouse/key Probe 是 drawCh 事务外的低频叶子。每个 entry 每批 drawCh 只
			// 重捕获一次；lease/epoch token 仍负责拒绝 LRU 复用、退休 renderer 与重入 ABA。
			global.fushiLookupRefreshPendingCaptures = function()
			{
				if(global.fushiLookupRefreshActive) return;
				global.fushiLookupRefreshActive = true;
				try
				{
					// Freeze one batch. drawCh triggered by getCharacters/reentrant game
					// getters receives a newer revision and is intentionally left for next
					// input; it cannot leak into this Capture's candidate set.
					var targetRevision = global.fushiLookupBindRevision;
					var registry = global.fushiLookupRegistry;
					for(var i = 0; i < registry.count && i < 8; i++)
					{
						var entry = registry[i];
						if(targetRevision <= entry.bindAttemptRevision) continue;
						var renderer = entry.renderer;
						var lease = entry.rendererLease;
						var epoch = entry.renderEpoch;
						if(renderer === void || renderer === null || !isvalid renderer ||
							lease <= 0 || epoch <= entry.retiredRenderEpoch) continue;
						global.fushiLookupCapture(renderer, 3, lease, epoch,
							targetRevision);
						// Consume this frozen batch even when Capture returned early (empty
						// characters, stale slot, getter exception). Otherwise every mouseMove
						// repeats the same getCharacters call indefinitely.
						if(global.fushiLookupCaptureTokenCurrent(entry, renderer, lease, epoch) &&
							entry.bindAttemptRevision < targetRevision)
							entry.bindAttemptRevision = targetRevision;
					}
				}
				catch(e) { global.fushiLookupNoteError("capture.refresh", e); }
				global.fushiLookupRefreshActive = false;
			};

)TJS" LR"TJS(

			// offsetX/offsetY 是 primary **图像**坐标，只供与 entry.glyphs 同系的高亮
			// 位图绘制；paintX/paintY 是 primary **图层**坐标，供挂在 primary 下的高亮层
			// 与卡片 Layer 定位。两者只差 primary.imageLeft/Top，但那个差会随缩放变化。
			// IPC 的 glyph/view 必须报图层坐标与 primary.width/height：host 算出的 anchor
			// 最终直接交给 card.setPos，而 imageWidth/Height 可能是缩放 backing image（本样本
			// 1920x1440），并不等于实际可见/输入 Layer（1920x1080）。混用会把卡片下半截
			// 放到视口外，也会让 screenshot→Layer 输入变换错误。
			global.fushiLookupReport = function(entry, index, offsetX, offsetY, submit,
				paintX, paintY)
			{
				var key = entry.line + "#" + index;
				// 命中字符没变就什么都不做：既不重绘高亮，也不惊动 host。
				if(!submit && key == global.fushiLookupHoverKey) return;
				global.fushiLookupHoverKey = key;
				var glyph = entry.glyphs[index];
				var primary = global.kag.primaryLayer;
				global.fushiLookupHitEntry = entry;
				global.fushiLookupHitOffsetX = offsetX;
				global.fushiLookupHitOffsetY = offsetY;
				// 🔴 全部收敛成 Integer。DLL 侧 EvaluateTjsInteger 只认 TJS 的 Integer
				// 类型，读到 Real 直接返回 false；而 renderer.getCharacters 给的字形坐标
				// **是 Real**（诊断里打出来是 "+0.0" 这种带正号的形式）。少一个 int，
				// 发布函数那一整批求值就整体失败、原地 return——命中永远送不到 host。
				// 真机上的表现极具迷惑性：高亮照常出现（那是 TJS 自己画的），卡片却永远
				// 不来，看起来像"host 坏了"，其实是类型不匹配把整条链掐在了注入侧。
				// IPC 那几个字段本来就是 int32，这里收敛也是契约要求。
				global.fushiLookupHitCharIndex = int index;
				global.fushiLookupHitCharCount = int entry.glyphs.count;
				global.fushiLookupHitGlyphX = int (glyph.x + paintX);
				global.fushiLookupHitGlyphY = int (glyph.y + paintY);
				global.fushiLookupHitGlyphW = int glyph.w;
				global.fushiLookupHitGlyphH = int glyph.h;
				global.fushiLookupHitViewW = int primary.width;
				global.fushiLookupHitViewH = int primary.height;
				global.fushiLookupHitFlags = submit ? 1 : 0;
				// **整行**，不截断。制卡要的是完整句子，分词是 host 的事。
				global.fushiLookupHitLine = entry.line;
				global.fushiLookupHitSeq++;
				global.fushiLookupVisualSeq = global.fushiLookupHitSeq;
				if(submit)
				{
					// submit 是耐久快照；hover 只更新上面的 visual 命中，绝不能覆盖一笔
					// 尚未被 host 消费的点击。SubmitSeq 最后写，作为 TJS 内部 seqlock。
					global.fushiLookupSubmitCharIndex = int index;
					global.fushiLookupSubmitCharCount = int entry.glyphs.count;
					global.fushiLookupSubmitGlyphX = int (glyph.x + paintX);
					global.fushiLookupSubmitGlyphY = int (glyph.y + paintY);
					global.fushiLookupSubmitGlyphW = int glyph.w;
					global.fushiLookupSubmitGlyphH = int glyph.h;
					global.fushiLookupSubmitViewW = int primary.width;
					global.fushiLookupSubmitViewH = int primary.height;
					global.fushiLookupSubmitLine = entry.line;
					global.fushiLookupSubmitSeq = global.fushiLookupHitSeq;
				}
				global.fushiLookupNotify++;
				global.fushiLookupPaintHighlight(entry, paintX, paintY, index, 1);
			};

			global.fushiLookupProbe = function(submit)
			{
				// Mouse/key hooks are transaction-external leaves. Complete any queued
				// retirement pixels before hit testing or drawing a new hover.
				global.fushiLookupFlushVisualWork();
				global.fushiLookupRefreshPendingCaptures();
				global.fushiLookupFlushVisualWork();
				var primary = global.kag.primaryLayer;
				// 两套坐标，用途不同，混用就是恒定偏移：
				//   px/py = primary **图像**坐标，只用于把命中换算成卡片落点（视口尺寸
				//           取的也是 primary.imageWidth/Height，必须同系）。
				//   lx/ly = primary **图层**坐标，才是沿父链累加 left/top 的那一系
				//           （left/top 是图层坐标里的量）。命中判定必须用它。
				var px = primary.cursorX - primary.imageLeft;
				var py = primary.cursorY - primary.imageTop;
				var lx = primary.cursorX;
				var ly = primary.cursorY;
				var registry = global.fushiLookupRegistry;
				var traceOn = submit && global.fushiLookupCoordTraceBudget > 0;
				var trace = "";
				var traced = 0;
				if(traceOn)
					trace = "lookup.coord.v1 L=" + lx + "," + ly + ",I=" + px + "," +
						py + ",N=" + registry.count;
				for(var i = registry.count - 1; i >= 0; i--)
				{
					var entry = registry[i];
					if(entry.glyphs.count == 0) continue;
					var layer = entry.layer;
					// 坐标换算只用图层树属性（left/top/parent），不碰任何图像属性——
					// 见 fushiLookupComputeOffset 的注释：问图层自己要 cursorX/imageLeft
					// 会在它不可绘制时抛异常，而那正是翻页后的常态。
					//
					// try 仍然留着，但它不再是主路的一部分：`isvalid` 只保证对象活着，
					// 图层树本身也可能在游戏拆场景的中途被动到。真抛了就把这条记录判死
					// ——清空槽位后本条不再被探，槽位（used=0）立刻成为 LRU 首选被复用。
					// 只 continue 不清空的话，每一次鼠标移动都会在同一条死记录上再抛一次。
					var rx = 0;
					var ry = 0;
					var offsetOk = 0;
					var dead = false;
					try
					{
						// 完整的坐标链，一节都不能少：
						//   primary 图层坐标 -(父链 left/top)-> 文字层图层坐标
						//                    -(imageLeft/Top)-> 文字层图像坐标
						//                    -(平移量)--------> 渲染器局部坐标
						// imgLeft/imgTop 在 drawCh 里取（那一刻层必然可绘制），平移量由
						// min(ox) 与 min(字形 x) 配对解出。
						if(!global.fushiLookupComputeOffset(layer))
						{
							if(traceOn && traced < 8)
							{
								trace += global.fushiLookupCoordEntry(i, entry, 0, 0, 0, "D", -1);
								traced++;
							}
							continue;
						}
						offsetOk = 1;
						rx = lx - global.fushiLookupOffX - entry.imgLeft - entry.originX;
						ry = ly - global.fushiLookupOffY - entry.imgTop - entry.originY;
					}
					catch(e)
					{
						dead = true;
					}
					if(dead)
					{
						if(traceOn && traced < 8)
						{
							trace += global.fushiLookupCoordEntry(i, entry, offsetOk, rx, ry,
								"X", -1);
							traced++;
						}
						entry.glyphs = [];
						entry.line = "";
						entry.used = 0;
						global.fushiLookupClearEntryBinding(entry);
						global.fushiLookupFault();
						continue;
					}
					// 廉价矩形判定挡在前面：整行包围盒不含光标就整条跳过，逐字扫描只在真正
					// 落在台词上时才发生。
					if(rx < entry.minX || rx >= entry.maxX ||
						ry < entry.minY || ry >= entry.maxY)
					{
						if(traceOn && traced < 8)
						{
							trace += global.fushiLookupCoordEntry(i, entry, offsetOk, rx, ry,
								"B", -1);
							traced++;
						}
						global.fushiLookupMark(1);
						continue;
					}
					// 有声角色的口型/表情会把 drawCh 的短命 visibleHost 设 hidden，但 KAG
					// current 消息对象仍是同一句的稳定身份。严格身份相等时继续使用消息层坐标；
					// 身份不可得才回退 visibleHost，明确不一致则无条件拒绝旧 entry。
					var currentIdentityState = global.fushiLookupCurrentIdentityState(entry);
					if(currentIdentityState < 0 ||
						(currentIdentityState == 0 &&
							!global.fushiLookupEntryVisible(entry)))
					{
						if(traceOn && traced < 8)
						{
							trace += global.fushiLookupCoordEntry(i, entry, offsetOk, rx, ry,
								"V", -1);
							traced++;
						}
						global.fushiLookupMark(4);
						continue;
					}
					var glyphs = entry.glyphs;
					for(var g = glyphs.count - 1; g >= 0; g--)
					{
						var glyph = glyphs[g];
						if(rx < glyph.x || rx >= glyph.x + glyph.w) continue;
						if(ry < glyph.y || ry >= glyph.y + glyph.h) continue;
						if(traceOn && traced < 8)
						{
							trace += global.fushiLookupCoordEntry(i, entry, offsetOk, rx, ry,
								"H", g);
							traced++;
						}
						if(traceOn) global.fushiLookupPublishCoordTrace(trace);
						global.fushiLookupReport(entry, g, px - rx, py - ry, submit,
							lx - rx, ly - ry);
						return true;
					}
					// 走到这里 = 整行包围盒命中、图层可见，却没有任何字形命中。与包围盒
					// 未命中是两种不同的坐标错误（前者是行内偏移，后者是整层偏移）。
					if(traceOn && traced < 8)
					{
						trace += global.fushiLookupCoordEntry(i, entry, offsetOk, rx, ry,
							"G", -1);
						traced++;
					}
					global.fushiLookupMark(2);
				}
				if(traceOn) global.fushiLookupPublishCoordTrace(trace);
				if(!submit) global.fushiLookupClearHover();
				global.fushiLookupFlushVisualWork();
				return false;
			};

			// 卡片子层命中时由 Layer 的 down/up 处理；这里判定 primary 路径是否仍落在
			// 卡片矩形内，防止同一次点击意外继续推进剧情。坐标使用已由滚轮真机证明的
			// primary 光标坐标减卡片位置。
			global.fushiLookupOverCard = function()
			{
				if(global.fushiLookupCardSeq == 0) return false;
				try
				{
					var card = global.fushiLookupCard;
					if(card === void || !isvalid card || !card.visible) return false;
					var primary = global.kag.primaryLayer;
					var x = primary.cursorX - card.left;
					var y = primary.cursorY - card.top;
					return x >= 0 && y >= 0 && x < card.imageWidth && y < card.imageHeight;
				}
				catch(e) { return false; }
			};

)TJS" LR"TJS(

			global.fushiLookupLeftClickHook = function()
			{
				// 🔴 这三个 hook 挂在 kag 的事件分发上，异常一旦逃逸就会被引擎当成脚本
				// 致命错误弹框（"致命的なエラーが発生しました"），玩家的这一局当场被打断
				// ——我们注进去的传感器把别人的游戏搞挂了。C++ 那侧的泵早就守着这条边界
				// （KiriKiriLookupPumpCallback 的 catch(...)），TJS 这侧必须同样守。
				// 兜底一律返回 false = **不消费**这次事件：查词坏掉是小事，把玩家的点击
				// 吞掉、剧情推不动是大事。
				try
				{
					// 低频兜底：getRender 是未来实例的主入口；人工点击时再有界复核
					// renders[]，覆盖游戏直接替换 textRender 而未经过 getRender 的路径。
					global.fushiLookupInstallGetRenderBridge();
					global.fushiLookupSweepMsgwinRenders();
					global.fushiLookupAuditWrappers(true);
					if(global.fushiLookupOverCard())
					{
						var card = global.fushiLookupCard;
						var primary = global.kag.primaryLayer;
						var localX = primary.cursorX - card.left;
						var localY = primary.cursorY - card.top;
						// WebView2 需要完整的一次指针序列。显式 move 还可在鼠标未先移动时
						// 同步 hover target；QueueInput 会合并紧邻的重复 move。
						global.fushiLookupQueueInput(0, localX, localY, 0);
						global.fushiLookupQueueInput(1, localX, localY, 0);
						global.fushiLookupQueueInput(2, localX, localY, 0);
						return true;
					}
					return global.fushiLookupProbe(true);
				}
				catch(e) { global.fushiLookupFault(); return false; }
			};
			global.fushiLookupMouseMoveHook = function(x, y)
			{
				try
				{
					global.fushiLookupAuditWrappers(false);
					if(global.fushiLookupOverCard()) return false;
					global.fushiLookupProbe(false);
				}
				catch(e) { global.fushiLookupFault(); }
				return false;
			};
			// KAGEX 的 Window.onMouseWheel 先把事件交给 focusedLayer，再调用这个全局
			// `onMouseWheelHook`。卡片只是 primary 的普通子层，并不取得键盘焦点，所以不能
			// 依赖 Layer.onMouseWheel；那条路在真机上 input_count 恒定不动。这里用 primary
			// 的光标坐标减去卡片位置，得到与卡片位图/WebView 同系的局部坐标。卡内返回 true
			// 会阻止 KAGEX 继续把同一滚轮解释成历史/推进剧情。
			global.fushiLookupMouseWheelHook = function(shift, delta, x, y)
			{
				try
				{
					if(global.fushiLookupCardSeq == 0) return false;
					var card = global.fushiLookupCard;
					if(card === void || !isvalid card || !card.visible) return false;
					var primary = global.kag.primaryLayer;
					var localX = primary.cursorX - card.left;
					var localY = primary.cursorY - card.top;
					if(localX < 0 || localY < 0 ||
						localX >= card.imageWidth || localY >= card.imageHeight) return false;
					global.fushiLookupQueueInput(3, localX, localY, delta);
					return true;
				}
				catch(e) { global.fushiLookupFault(); return false; }
			};
			global.fushiLookupKeyDownHook = function(key, shift)
			{
				try
				{
					global.fushiLookupShiftDown = (key == 0x10);
					if(key == 0x1B)
					{
						if(global.fushiLookupCancelCurrent()) return true;
					}
					if(key == 0x10) return global.fushiLookupProbe(true);
				}
				catch(e) { global.fushiLookupFault(); }
				return false;
			};

			// bootstrap 只装传感器，**一个渲染层都不建**：卡片层由 fushiLookupPrepare 在真要
			// 显示第一帧时建，高亮层由 fushiLookupEnsureHighlight 在第一次真要高亮时建。
			// 没查词的时候游戏渲染树与它注入前逐字节一致。
			global.fushiLookupCard = void;
			global.fushiLookupHighlightLayer = void;

			// 自定义卡片层能不能建，bootstrap 期就试一次并记下来。
			//
			// 为什么不留到用时再试：它只在 host 投第一帧时才被触发，而失败原因（引擎
			// 拒绝子类 / super 调用形式不符 / KAG.add 不收）只有异常原文说得清。放在
			// 这里，传感器一装好就有结论，且**失败原因直接进日志**，不必靠一版版试。
			// 结果供 fushiLookupPrepare 复用：能建就用带鼠标事件的子类（卡片内点击、
			// 移动与嵌套查词靠它；滚轮走 Window 全局 hook），不能建就直接退回普通 Layer，
			// 不再每帧抛一次。
			global.fushiLookupCardClassOk = false;
			try
			{
				var probeLayer = new FushiLookupCardLayer(global.kag,
					global.kag.primaryLayer);
				global.fushiLookupCardClassOk = true;
				// 顺带把 prepare 会设的每个属性都试一遍，逐项记原因。
				//
				// 真机实测：子类本身建得出来，抛异常的是**某个属性赋值**——而它被逐项
				// 隔离后静默跳过，于是卡片能显示、却收不到层鼠标事件（input_count 恒 0，
				// 卡片内点击/嵌套查词全部失效）。哪个属性不被接受，只有异常原文
				// 说得清；放在 bootstrap 里试，一次就有结论。
				try { global.kag.add(probeLayer); }
				catch(e) { global.fushiLookupNoteError("probe.kagAdd", e); }
				try { probeLayer.name = "probe"; }
				catch(e) { global.fushiLookupNoteError("probe.name", e); }
				try { probeLayer.fushiLookupIgnore = true; }
				catch(e) { global.fushiLookupNoteError("probe.ignoreFlag", e); }
				try { probeLayer.absolute = 2147483000; }
				catch(e) { global.fushiLookupNoteError("probe.absolute", e); }
				try { probeLayer.opacity = 255; }
				catch(e) { global.fushiLookupNoteError("probe.opacity", e); }
				try { probeLayer.hitType = htRect; }
				catch(e) { global.fushiLookupNoteError("probe.hitType", e); }
				try { probeLayer.type = ltAlpha; }
				catch(e) { global.fushiLookupNoteError("probe.type", e); }
				try { probeLayer.setImageSize(64, 64); probeLayer.setSizeToImageSize(); }
				catch(e) { global.fushiLookupNoteError("probe.setImageSize", e); }
				try { probeLayer.setPos(0, 0); }
				catch(e) { global.fushiLookupNoteError("probe.setPos", e); }
				try { probeLayer.visible = false; }
				catch(e) { global.fushiLookupNoteError("probe.visible", e); }
				global.fushiLookupNoteError("probe.done",
					%[message: "card class OK; property probe finished"]);
				invalidate probeLayer;
			}
			catch(e)
			{
				global.fushiLookupNoteError("cardClassProbe", e);
			}

)TJS" LR"TJS(

			// Limelight 的 RenderMsgwinPlugin 在 bootstrap 前已经创建了 MsgwinRender；
			// 这些对象保留的是 `new` 时复制进去的旧函数。游戏调用方会用
			// `method incontextof renderer` 重绑方法的 this，因此 wrapper 自身必须绑定到
			// renderer；original 只能从外置 sidecar 账本按 renderer identity 取回，不能
			// 藏在 wrapper 的 this 字典里。
			global.fushiLookupFindInstancePatch = function(renderer)
			{
				try
				{
					var patches = global.fushiLookupInstancePatches;
					for(var i = 0; i < patches.count; i++)
					{
						var patch = patches[i];
						if(patch.renderer === renderer && patch.state >= 0) return patch;
					}
				}
				catch(e) { global.fushiLookupFault(); }
				return void;
			};

			global.fushiLookupMakeInstanceRenderWrapper = function(owner)
			{
				return (function(a, b, c, d, e, f)
				{
					var renderer = this;
					var patch = global.fushiLookupFindInstancePatch(renderer);
					var original = (patch === void) ? void : patch.originalRender;
					if(typeof original != "Object")
					{
						global.fushiLookupFault();
						// 已暴露的方法引用可能比 sidecar record 活得更久。绝不能吞掉
						// 游戏原调用；优先落回已安装的 class bridge，再落回 class original。
						original = global.fushiLookupInstalledRenderWrapper;
						if(typeof original != "Object")
							original = global.fushiLookupOriginalRender;
						if(typeof original != "Object") return void;
					}
					var captureLease = 0, captureEpoch = 0;
					try
					{
						var epochEntry = global.fushiLookupEntryFor(renderer);
						epochEntry.renderEpoch++;
						captureLease = epochEntry.rendererLease;
						captureEpoch = epochEntry.renderEpoch;
					}
					catch(e) { global.fushiLookupFault(); }
					// original 是直接从 renderer 实例字段读出的 closure，已保留真实
					// ObjThis；其异常与返回值均原样穿透，只有旁路采集异常会被隔离。
					var result = (original incontextof renderer)(...);
					try { global.fushiLookupCapture(renderer, 1, captureLease, captureEpoch); }
					catch(e) { global.fushiLookupFault(); }
					try { global.fushiLookupFlushVisualWork(); }
					catch(e) { global.fushiLookupFault(); }
					return result;
				} incontextof owner);
			};

			global.fushiLookupMakeInstanceDoneWrapper = function(owner)
			{
				return (function()
				{
					var renderer = this;
					var patch = global.fushiLookupFindInstancePatch(renderer);
					var original = (patch === void) ? void : patch.originalDone;
					if(typeof original != "Object")
					{
						global.fushiLookupFault();
						original = global.fushiLookupInstalledDoneWrapper;
						if(typeof original != "Object") original = global.fushiLookupOriginalDone;
						if(typeof original != "Object") return void;
					}
					var doneLease = 0, doneEpoch = 0;
					try
					{
						var doneEntry = global.fushiLookupFindEntry(renderer);
						if(doneEntry !== void)
						{
							doneLease = doneEntry.rendererLease;
							doneEpoch = doneEntry.renderEpoch;
						}
					}
					catch(e) { global.fushiLookupFault(); }
					var result = (original incontextof renderer)(...);
					try
					{
						if(doneLease > 0)
							global.fushiLookupCapture(renderer, 2, doneLease, doneEpoch);
					}
					catch(e) { global.fushiLookupFault(); }
					try { global.fushiLookupFlushVisualWork(); }
					catch(e) { global.fushiLookupFault(); }
					return result;
				} incontextof owner);
			};

			global.fushiLookupMakeInstanceDrawChWrapper = function(owner)
			{
				return (function(layer, ox, oy, ch)
				{
					var renderer = this;
					var patch = global.fushiLookupFindInstancePatch(renderer);
					var original = (patch === void) ? void : patch.originalDrawCh;
					if(typeof original != "Object")
					{
						global.fushiLookupFault();
						original = global.fushiLookupInstalledDrawChWrapper;
						if(typeof original != "Object")
							original = global.fushiLookupOriginalDrawCh;
						if(typeof original != "Object") return void;
					}
					try { global.fushiLookupBindOrigin(renderer, layer, ox, oy, ch); }
					catch(e) { global.fushiLookupFault(); }
					return (original incontextof renderer)(...);
				} incontextof owner);
			};

)TJS" LR"TJS(

			// 原子地给一个既有 textRender 实例加 bridge。state=0 是重入闸门，
			// state=1 已安装，state=2 保留 original 并允许在同一 record 上重试。
			global.fushiLookupPatchRendererInstance = function(renderer)
			{
				var patch = void;
				var noted = false;
				try
				{
					if(renderer === void || renderer === null || !isvalid renderer ||
						renderer === global.TextRender ||
						typeof renderer.render != "Object" ||
						typeof renderer.done != "Object" ||
						typeof renderer.drawCh != "Object" ||
						typeof renderer.getCharacters != "Object")
					{
						global.fushiLookupInstanceRejectShape++;
						return false;
					}
					// `LangRender` 类还被 StandLayer 等 UI 共用；只许补它的消息实例。
					if(typeof global.LangRender == "Object" && renderer === global.LangRender)
					{
						global.fushiLookupInstanceRejectClass++;
						return false;
					}

					var patches = global.fushiLookupInstancePatches;
					for(var i = 0; i < patches.count; i++)
					{
						var existing = patches[i];
						var alive = false;
						try
						{
							alive = existing.renderer !== void &&
								existing.renderer !== null && isvalid existing.renderer;
						}
						catch(e) { alive = false; }
						// method closure 可以脱离 renderer 字段继续存活；即使 owner 已
						// invalid，也不能删除它的 original record。容量满时明确失败关闭，
						// 后续由有 active-set 证据的独立回收事务处理。
						if(!alive) continue;
						if(existing.renderer === renderer)
						{
							patch = existing;
							if(existing.state == 0) return false;
							if(renderer.render === existing.renderWrapper &&
								renderer.done === existing.doneWrapper &&
								renderer.drawCh === existing.drawChWrapper)
							{
								existing.state = 1;
								return true;
							}

							// 表情/口型脚本会重注册 MsgwinRender 的部分方法。不能把账本
							// 标死后留下另外两个旧 wrapper：那会让残留 wrapper 再也找不到
							// original 并吞掉游戏调用。先以 state=0 保持重入时 original 可用，
							// 仅恢复仍由本 bridge 持有的字段；全部摘除后再以当前方法为新
							// baseline 原子重建。
								existing.state = 0;
							try
							{
								if(typeof existing.stableRenderWrapper == "Object" &&
									renderer.render === existing.stableRenderWrapper)
									renderer.render = existing.originalRender;
								if(typeof existing.stableDoneWrapper == "Object" &&
									renderer.done === existing.stableDoneWrapper)
									renderer.done = existing.originalDone;
								if(typeof existing.stableDrawChWrapper == "Object" &&
									renderer.drawCh === existing.stableDrawChWrapper)
									renderer.drawCh = existing.originalDrawCh;
								if((typeof existing.stableRenderWrapper == "Object" &&
										renderer.render === existing.stableRenderWrapper) ||
									(typeof existing.stableDoneWrapper == "Object" &&
										renderer.done === existing.stableDoneWrapper) ||
									(typeof existing.stableDrawChWrapper == "Object" &&
										renderer.drawCh === existing.stableDrawChWrapper))
								{
									existing.state = 2;
									return false;
								}
								// record 已经可能被逸出的 method closure 引用。字段全部摘除后
								// 也只原地重建，绝不 erase original。
								break;
							}
							catch(e)
							{
								existing.state = 2;
								global.fushiLookupNoteError("instance.rebind", e);
								return false;
							}
						}
					}

)TJS" LR"TJS(

					var originalRender = renderer.render;
					var originalDone = renderer.done;
					var originalDrawCh = renderer.drawCh;
					// bootstrap readiness 只覆盖安装当刻；若游戏随后替换/清掉类入口，
					// `incontextof` 的左值可能已经是 void。这里必须先 fail closed，不能
					// 让诊断桥把游戏启动变成 TJS 致命异常。
					if(typeof global.fushiLookupInstalledRenderWrapper != "Object" ||
						typeof global.fushiLookupInstalledDoneWrapper != "Object" ||
						typeof global.fushiLookupInstalledDrawChWrapper != "Object")
					{
						global.fushiLookupInstanceRejectShape++;
						if(patch !== void) patch.state = 2;
						return false;
					}
					var installedRender =
						(global.fushiLookupInstalledRenderWrapper incontextof renderer);
					var installedDone =
						(global.fushiLookupInstalledDoneWrapper incontextof renderer);
					var installedDrawCh =
						(global.fushiLookupInstalledDrawChWrapper incontextof renderer);
					// bootstrap 后创建的实例已经复制了三条 class wrapper；全相等即已覆盖。
					if(originalRender === installedRender &&
						originalDone === installedDone &&
						originalDrawCh === installedDrawCh)
					{
						if(patch !== void)
						{
							patch.originalRender = originalRender;
							patch.originalDone = originalDone;
							patch.originalDrawCh = originalDrawCh;
							patch.wrapRender = false;
							patch.wrapDone = false;
							patch.wrapDrawCh = false;
							patch.renderWrapper = installedRender;
							patch.doneWrapper = installedDone;
							patch.drawChWrapper = installedDrawCh;
							patch.state = 2;
						}
						global.fushiLookupInstanceAlreadyClass++;
						return true;
					}
					if(patch === void && patches.count >= 16)
					{
						global.fushiLookupInstanceRejectFull++;
						return false;
					}

					// MsgwinRender/LangRender 会覆写其中一部分方法，同时从已补丁的
					// TextRender 继承其余方法。只给真正的 override 补 sidecar；已经是
					// class wrapper 的字段保留原样，避免重复 Capture。
					var wrapRender = originalRender !== installedRender;
					var wrapDone = originalDone !== installedDone;
					var wrapDrawCh = originalDrawCh !== installedDrawCh;
					if(patch === void)
					{
						patch = %[renderer:renderer, state:0,
							stableRenderWrapper:void, stableDoneWrapper:void,
							stableDrawChWrapper:void];
						patches.add(patch);
					}
					patch.renderer = renderer;
					patch.state = 0;
					patch.originalRender = originalRender;
					patch.originalDone = originalDone;
					patch.originalDrawCh = originalDrawCh;
					patch.wrapRender = wrapRender;
					patch.wrapDone = wrapDone;
					patch.wrapDrawCh = wrapDrawCh;
					patch.renderWrapper = installedRender;
					patch.doneWrapper = installedDone;
					patch.drawChWrapper = installedDrawCh;
					if(wrapRender)
					{
						if(typeof patch.stableRenderWrapper != "Object")
							patch.stableRenderWrapper =
								global.fushiLookupMakeInstanceRenderWrapper(renderer);
						patch.renderWrapper = patch.stableRenderWrapper;
					}
					if(wrapDone)
					{
						if(typeof patch.stableDoneWrapper != "Object")
							patch.stableDoneWrapper =
								global.fushiLookupMakeInstanceDoneWrapper(renderer);
						patch.doneWrapper = patch.stableDoneWrapper;
					}
					if(wrapDrawCh)
					{
						if(typeof patch.stableDrawChWrapper != "Object")
							patch.stableDrawChWrapper =
								global.fushiLookupMakeInstanceDrawChWrapper(renderer);
						patch.drawChWrapper = patch.stableDrawChWrapper;
					}
					if((wrapRender && typeof patch.renderWrapper != "Object") ||
						(wrapDone && typeof patch.doneWrapper != "Object") ||
						(wrapDrawCh && typeof patch.drawChWrapper != "Object"))
						throw "lookup instance wrapper unavailable";

					if(wrapRender) renderer.render = patch.renderWrapper;
					if(renderer.render === patch.renderWrapper && wrapDone)
						renderer.done = patch.doneWrapper;
					if(renderer.render === patch.renderWrapper &&
						renderer.done === patch.doneWrapper && wrapDrawCh)
						renderer.drawCh = patch.drawChWrapper;
					if(renderer.render === patch.renderWrapper &&
						renderer.done === patch.doneWrapper &&
						renderer.drawCh === patch.drawChWrapper)
					{
						patch.state = 1;
						global.fushiLookupWrapperAuditPending = true;
						return true;
					}
				}
				catch(e)
				{
					noted = true;
					global.fushiLookupNoteError("instance.install", e);
				}

				// 只回滚仍等于本次 wrapper 的字段，不覆盖游戏在重入中做出的更新。
				if(patch !== void)
				{
					try
					{
						if(patch.wrapRender && renderer.render === patch.renderWrapper)
							renderer.render = patch.originalRender;
					}
					catch(e) { global.fushiLookupFault(); }
					try
					{
						if(patch.wrapDone && renderer.done === patch.doneWrapper)
							renderer.done = patch.originalDone;
					}
					catch(e) { global.fushiLookupFault(); }
					try
					{
						if(patch.wrapDrawCh && renderer.drawCh === patch.drawChWrapper)
							renderer.drawCh = patch.originalDrawCh;
					}
					catch(e) { global.fushiLookupFault(); }
					var survivor = false;
					try
					{
						survivor = (patch.wrapRender &&
							renderer.render === patch.renderWrapper) ||
							(patch.wrapDone && renderer.done === patch.doneWrapper) ||
							(patch.wrapDrawCh &&
								renderer.drawCh === patch.drawChWrapper);
					}
					catch(e) { survivor = true; }
					// 字段是否仍等于 wrapper 不能证明 method closure 已不可达；失败记录
					// 永久保留 original。state=2 允许下一轮在同一 record 上重试。
					patch.state = 2;
					if(!noted)
						global.fushiLookupNoteError("instance.install",
							%[message:"wrapper identity readback failed"]);
				}
				return false;
			};

)TJS" LR"TJS(

			global.fushiLookupPatchMsgwinRender = function(msgwin)
			{
				try
				{
					if(msgwin === void || msgwin === null || !isvalid msgwin) return false;
					// 本目标 renders[] 的元素本身就是 MsgwinRender；只有 direct 四方法
					// 门不成立时才兼容下钻 textRender。direct 已有正确形状但正处在
					// setter 重入/重建/失败状态时也必须就地 fail closed，不能顺势再补
					// 内层对象而形成双 bridge。
					var directShape = typeof msgwin.render == "Object" &&
						typeof msgwin.done == "Object" &&
						typeof msgwin.drawCh == "Object" &&
						typeof msgwin.getCharacters == "Object";
					if(directShape)
						return global.fushiLookupPatchRendererInstance(msgwin);
					var renderer = global.fushiLookupField(msgwin, "textRender");
					return global.fushiLookupPatchRendererInstance(renderer);
				}
				catch(e) { global.fushiLookupFault(); return false; }
			};

			// 标准 KAG 把插件保存在 MainWindow.kagPlugins；目标游戏的
			// renderMsgwinPlugin 也从 addPlugin 进入这里，并不是 global 成员。
			// 只查两个廉价别名和这一层有界标准容器，不做对象图递归扫描。
			global.fushiLookupIsMsgwinPlugin = function(candidate)
			{
				try
				{
					if(candidate === void || candidate === null || !isvalid candidate ||
						typeof candidate.getRender != "Object" ||
						typeof candidate.getRenderId != "Object") return false;
					var renders = candidate.renders;
					return typeof renders == "Object" && renders !== null &&
						isvalid renders && typeof renders.count == "Integer" &&
						renders.count >= 0;
				}
				catch(e) { return false; }
			};

			global.fushiLookupResolveMsgwinPlugin = function()
			{
				global.fushiLookupInstancePluginSource = 0;
				global.fushiLookupInstancePluginCount = -1;
				global.fushiLookupInstancePluginIndex = -1;
				try
				{
					var direct = global.fushiLookupField(global, "renderMsgwinPlugin");
					if(global.fushiLookupIsMsgwinPlugin(direct))
					{
						global.fushiLookupInstancePluginSource = 1;
						return direct;
					}
					var kag = global.kag;
					var alias = global.fushiLookupField(kag, "renderMsgwinPlugin");
					if(global.fushiLookupIsMsgwinPlugin(alias))
					{
						global.fushiLookupInstancePluginSource = 2;
						return alias;
					}
					var plugins = global.fushiLookupField(kag, "kagPlugins");
					if(typeof plugins != "Object" || plugins === null || !isvalid plugins)
						return void;
					var count = plugins.count;
					global.fushiLookupInstancePluginCount = count;
					var limit = count;
					if(limit > 64) limit = 64;
					for(var i = 0; i < limit; i++)
					{
						var candidate = plugins[i];
						if(!global.fushiLookupIsMsgwinPlugin(candidate)) continue;
						global.fushiLookupInstancePluginSource = 3;
						global.fushiLookupInstancePluginIndex = i;
						return candidate;
					}
				}
				catch(e) { global.fushiLookupFault(); }
				return void;
			};

)TJS" LR"TJS(

			global.fushiLookupAuditInstanceShape = function()
			{
				var flags = 0, count = -1, seen = 0, textRender = 0;
				var render = 0, done = 0, drawCh = 0, characters = 0;
				var direct = 0, installed = 0, failed = 0;
				try
				{
					var plugin = global.fushiLookupResolveMsgwinPlugin();
					if(plugin === void) flags = flags | 1;
					else
					{
						if(plugin === null || !isvalid plugin) flags = flags | 2;
						else
						{
							if(typeof plugin.getRender != "Object") flags = flags | 4;
							var renders = global.fushiLookupField(plugin, "renders");
							if(typeof renders != "Object" || renders === null || !isvalid renders)
								flags = flags | 8;
							else
							{
								count = renders.count;
								var limit = count;
								if(limit > 16) limit = 16;
								for(var i = 0; i < limit; i++)
								{
									var item = renders[i];
									if(item === void || item === null || !isvalid item) continue;
									seen++;
									if(typeof item.render == "Object" &&
										typeof item.done == "Object" &&
										typeof item.drawCh == "Object" &&
										typeof item.getCharacters == "Object") direct++;
									var renderer = global.fushiLookupField(item, "textRender");
									if(renderer === void || renderer === null || !isvalid renderer)
										continue;
									textRender++;
									if(typeof renderer.render == "Object") render++;
									if(typeof renderer.done == "Object") done++;
									if(typeof renderer.drawCh == "Object") drawCh++;
									if(typeof renderer.getCharacters == "Object") characters++;
								}
							}
						}
					}
					var patches = global.fushiLookupInstancePatches;
					for(var pi = 0; pi < patches.count && pi < 16; pi++)
					{
						if(patches[pi].state == 1) installed++;
						else if(patches[pi].state < 0) failed++;
					}
				}
				catch(e) { flags = flags | 16; }
				var shape = "f=" + flags + ",src=" +
					global.fushiLookupInstancePluginSource + ",kc=" +
					global.fushiLookupInstancePluginCount + ",ki=" +
					global.fushiLookupInstancePluginIndex + ",c=" + count + ",s=" + seen +
					",t=" + textRender + ",r=" + render + ",d=" + done +
					",h=" + drawCh + ",g=" + characters + ",q=" + direct +
					",ok=" + installed + ",bad=" + failed + ",rej=" +
					global.fushiLookupInstanceRejectShape + "/" +
					global.fushiLookupInstanceRejectClass + "/" +
					global.fushiLookupInstanceRejectMixed + "/" +
					global.fushiLookupInstanceRejectFull + ",base=" +
					global.fushiLookupInstanceAlreadyClass;
				if(shape != global.fushiLookupInstanceShapeLast)
				{
					global.fushiLookupInstanceShapeLast = shape;
					global.fushiLookupNoteError("instance.shape", %[message:shape]);
				}
			};

)TJS" LR"TJS(

			global.fushiLookupSweepMsgwinRenders = function()
			{
				if(global.fushiLookupInstanceSweepActive) return;
				global.fushiLookupInstanceSweepActive = true;
				try { global.fushiLookupAuditInstanceShape(); }
				catch(e) { global.fushiLookupFault(); }
				try
				{
					var plugin = global.fushiLookupResolveMsgwinPlugin();
					if(plugin === void)
					{
						global.fushiLookupInstanceSweepActive = false;
						return;
					}
					if(typeof plugin == "Object" && plugin !== null && isvalid plugin)
					{
						var renders = plugin.renders;
						var count = renders.count;
						if(count > 16) count = 16;
						for(var i = 0; i < count; i++)
							global.fushiLookupPatchMsgwinRender(renders[i]);
					}
				}
				catch(e) { global.fushiLookupFault(); }
				global.fushiLookupInstanceSweepActive = false;
				try { global.fushiLookupAuditInstanceShape(); }
				catch(e) { global.fushiLookupFault(); }
			};

			global.fushiLookupFindGetRenderPatch = function(owner)
			{
				try
				{
					var patches = global.fushiLookupInstanceGetRenderPatches;
					for(var i = 0; i < patches.count; i++)
					{
						var patch = patches[i];
						if(patch.owner === owner && patch.state >= 0) return patch;
					}
				}
				catch(e) { global.fushiLookupFault(); }
				return void;
			};

			global.fushiLookupMakeGetRenderWrapper = function(owner)
			{
				return (function()
				{
					// 游戏原函数必须是第一个可抛调用；返回对象/异常完全透明。
					var patch = global.fushiLookupFindGetRenderPatch(this);
					var original = (patch === void) ? void : patch.original;
					if(typeof original != "Object" &&
						global.fushiLookupInstanceGetRenderOwner === this)
						original = global.fushiLookupInstanceGetRenderOriginal;
					if(typeof original != "Object")
					{
						global.fushiLookupFault();
						return void;
					}
					var result = (original incontextof this)(...);
					try
					{
						// 运行时标识符证明常见返回值是 MsgwinRender；若这个变体直接
						// 返回 textRender，本身的严格三方法闸门也能安全覆盖。
						if(!global.fushiLookupPatchMsgwinRender(result))
							global.fushiLookupPatchRendererInstance(result);
					}
					catch(e) { global.fushiLookupFault(); }
					return result;
				} incontextof owner);
			};

			global.fushiLookupInstallGetRenderBridge = function()
			{
				if(global.fushiLookupInstanceGetRenderInstalling) return false;
				global.fushiLookupInstanceGetRenderInstalling = true;
				var plugin = void, original = void, wrapper = void, patch = void;
				try
				{
					// 这是目标游戏私有扩展，缺失绝不阻断通用 Kirikiri bootstrap。
					plugin = global.fushiLookupResolveMsgwinPlugin();
					if(plugin === void)
					{
						global.fushiLookupInstanceGetRenderInstalling = false;
						return false;
					}
					if(plugin === null || !isvalid plugin ||
						typeof plugin.getRender != "Object" ||
						typeof plugin.renders != "Object")
					{
						global.fushiLookupInstanceGetRenderInstalling = false;
						return false;
					}
					patch = global.fushiLookupFindGetRenderPatch(plugin);
					if(patch !== void && patch.state == 0)
					{
						global.fushiLookupInstanceGetRenderInstalling = false;
						return false;
					}
					if(patch !== void && plugin.getRender === patch.wrapper &&
						typeof patch.original == "Object")
					{
						patch.state = 1;
						global.fushiLookupInstanceGetRenderOwner = plugin;
						global.fushiLookupInstanceGetRenderOriginal = patch.original;
						global.fushiLookupInstanceGetRenderWrapper = patch.wrapper;
						global.fushiLookupInstanceGetRenderInstallFailed = false;
						global.fushiLookupInstanceGetRenderInstalling = false;
						return true;
					}
					original = plugin.getRender;
					if(patch === void)
					{
						var patches = global.fushiLookupInstanceGetRenderPatches;
						if(patches.count >= 16)
						{
							global.fushiLookupInstanceGetRenderInstalling = false;
							return false;
						}
						patch = %[owner:plugin, original:original, wrapper:void, state:0];
						patches.add(patch);
					}
					else
					{
						patch.state = 0;
						patch.original = original;
					}
					if(typeof patch.wrapper != "Object")
						patch.wrapper = global.fushiLookupMakeGetRenderWrapper(plugin);
					wrapper = patch.wrapper;
					if(typeof wrapper != "Object")
						throw "lookup getRender wrapper unavailable";
					// record/original 先发布，setter 若重入，wrapper 也能 call-through。
					global.fushiLookupInstanceGetRenderOwner = plugin;
					global.fushiLookupInstanceGetRenderOriginal = original;
					global.fushiLookupInstanceGetRenderWrapper = wrapper;
					plugin.getRender = wrapper;
					if(plugin.getRender === wrapper)
					{
						patch.state = 1;
						global.fushiLookupInstanceGetRenderInstallFailed = false;
						global.fushiLookupInstanceGetRenderInstalling = false;
						return true;
					}
				}
				catch(e) { global.fushiLookupNoteError("getRender.install", e); }
				try
				{
					if(plugin !== void && plugin !== null && isvalid plugin &&
						wrapper !== void && plugin.getRender === wrapper)
						plugin.getRender = original;
				}
				catch(e) { global.fushiLookupFault(); }
				var survivor = false;
				try
				{
					survivor = plugin !== void && plugin !== null && isvalid plugin &&
						wrapper !== void && plugin.getRender === wrapper;
				}
				catch(e) { survivor = true; }
				// 方法引用可从 owner 字段逸出；无论字段回滚是否成功都保留 owner
				// record 和 original，后续同 owner 在原 record 上重试。
				if(patch !== void) patch.state = 2;
				global.fushiLookupInstanceGetRenderInstallFailed = true;
				global.fushiLookupInstanceGetRenderInstalling = false;
				return false;
			};

)TJS" LR"TJS(

			if(typeof global.TextRender == "Object")
			{
				if(typeof global.TextRender.render == "Object")
				{
					installStage = 10;
					global.fushiLookupOriginalRender = global.TextRender.render;
					// 覆写游戏自己的方法：原函数**先**跑且其返回值原样透出，我们的采集
					// 只能是尾随的旁路，且不得抛。抛出去等于我们替游戏决定了它的文字
					// 渲染失败。
					global.TextRender.render = function(a, b, c, d, e, f)
					{
						// render 是可观察的独立绘制边界。账本失败不得影响游戏原函数；
						// done 不递增，因此迟到 done 仍停在退休世代。
						var captureLease = 0, captureEpoch = 0;
						try
						{
							var epochEntry = global.fushiLookupEntryFor(this);
							epochEntry.renderEpoch++;
							captureLease = epochEntry.rendererLease;
							captureEpoch = epochEntry.renderEpoch;
						}
						catch(e) { global.fushiLookupFault(); }
						var result = (global.fushiLookupOriginalRender incontextof this)(...);
						try { global.fushiLookupCapture(this, 1, captureLease, captureEpoch); }
						catch(e) { global.fushiLookupFault(); }
						try { global.fushiLookupFlushVisualWork(); }
						catch(e) { global.fushiLookupFault(); }
						return result;
					};
					global.fushiLookupInstalledRenderWrapper = global.TextRender.render;
					global.fushiLookupRenderInstallFailed =
						global.fushiLookupInstalledRenderWrapper === global.fushiLookupOriginalRender;
					installStage = 11;
				}
				if(typeof global.TextRender.done == "Object")
				{
					installStage = 20;
					global.fushiLookupOriginalDone = global.TextRender.done;
					global.TextRender.done = function()
					{
						// 在 original 前只做异常隔离的只读 token 快照；original 仍是函数体
						// 第一个可能向游戏抛出的调用。若 original 内重入新 render，返回后
						// 旧 done 的 epoch 已不匹配，会失败关闭。
						var doneLease = 0, doneEpoch = 0;
						try
						{
							var doneEntry = global.fushiLookupFindEntry(this);
							if(doneEntry !== void)
							{
								doneLease = doneEntry.rendererLease;
								doneEpoch = doneEntry.renderEpoch;
							}
						}
						catch(e) { global.fushiLookupFault(); }
						var result = (global.fushiLookupOriginalDone incontextof this)(...);
						try
						{
							// done 不能调用 EntryFor：若这个 renderer 已被 LRU 淘汰，重新
							// 建 entry 会抹掉退休证据，让迟到 done 把旧 binding 复活。
							if(doneLease > 0)
								global.fushiLookupCapture(this, 2, doneLease, doneEpoch);
						}
						catch(e) { global.fushiLookupFault(); }
						try { global.fushiLookupFlushVisualWork(); }
						catch(e) { global.fushiLookupFault(); }
						return result;
					};
					global.fushiLookupInstalledDoneWrapper = global.TextRender.done;
					global.fushiLookupDoneInstallFailed =
						global.fushiLookupInstalledDoneWrapper === global.fushiLookupOriginalDone;
					installStage = 21;
				}
				if(typeof global.TextRender.drawCh == "Object")
				{
					installStage = 30;
					global.fushiLookupOriginalDrawCh = global.TextRender.drawCh;
					// 🔴 全文最危险的一处：绑定原点必须发生在原函数**之前**（它要的就是这
					// 次绘制的落点），于是我们的代码横在了游戏「把这个字画出来」的必经路
					// 上。这里抛一次异常，这个字就永远画不出来；抛在每个字上，整段台词
					// 就是空白。try 不是为了掩盖 bind 的 bug，而是保证**无论如何原函数都
					// 要跑**——采集失败只该让查词失灵，不该让游戏少画一个字。
					global.TextRender.drawCh = function(layer, ox, oy, ch)
					{
						try { global.fushiLookupBindOrigin(this, layer, ox, oy, ch); }
						catch(e) { global.fushiLookupFault(); }
						return (global.fushiLookupOriginalDrawCh incontextof this)(...);
					};
					global.fushiLookupInstalledDrawChWrapper = global.TextRender.drawCh;
					global.fushiLookupDrawChInstallFailed =
						global.fushiLookupInstalledDrawChWrapper === global.fushiLookupOriginalDrawCh;
					installStage = 31;
				}
			}
			else
			{
				// ⚠️ 真机实测结论（2026-08-14，务必先读再改）：
				//   Fate/stay night[Realta Nua]（KiriKiri2、无 textrender.dll）——传感器装上、
				//   查词开关打开、连推 7 句台词，**drawText 与 processCh 两条包装一次都没被
				//   调用**（classic_patch_installed 亮，classic_geometry_captured 与
				//   classic_processch_fired 全灭），同期 LunaHook 正常收到 7 行文本。
				//   フタマタ恋愛（KiriKiri、KAGParser.dll）——TJS exporter 始终没拿到，整个
				//   传感器（含原有 KAGEX 路径）根本没装起来，lookup_diag 恒为 0。
				//
				// 也就是说：给**原生类** Layer 的成员赋值，在 TJS 里拦不住实例上的调用；而
				// MessageLayer 在这些游戏里也不是可覆写的全局 TJS 类。下面两条目前只作为
				// **自证探针**存在——它们不产出可用几何，只回答"这台游戏的字走不走这里"。
				// 想让经典 KAG3 真能用，得先在真机上找到这些游戏实际的绘字边界（候选：引擎
				// 内部 TVPDrawText 的原生 detour），而不是继续在 TJS 层加包装。
				//
				// 没有 KAGEX TextRender 的经典 KAG3 游戏：逐字几何原以为只从原生 Layer.drawText 经过。
				// 这是**有条件**的全局补丁——装了 textrender.dll 的游戏走上面那条，一行都不多绕，
				// 所以"全局类补丁让所有 UI 绘制多绕一层"的代价只落在别无来源的游戏上；而在那些
				// 游戏里，不绕就等于游戏内查词整个不存在。
				// 传感器本身只在 host 真开启查词后才安装（PollKirikiriLookupInstall），关着的时候
				// 游戏渲染路径与注入前逐字节一致。
				global.fushiLookupOriginalDrawText = global.Layer.drawText;
				global.Layer.drawText = function(x, y, text, color, opacity, antialiased)
				{
					// 先让游戏画完再采集：原方法抛异常时不留半条几何。
					var result = (global.fushiLookupOriginalDrawText incontextof this)(...);
					global.fushiLookupCaptureDrawText(this, x, y, text);
					return result;
				};
				// 位 0 = 补丁真的装上了（这一行跑到就说明 else 分支没有中途抛异常）。
				global.fushiLookupClassicSource = global.fushiLookupClassicSource | 1;
				// MessageLayer 是 KAG3 的 **TJS 类**，Layer 是引擎的**原生类**。给原生类的
				// 成员赋值在 TJS 里拦不住实例上的调用（Fate/stay night[Realta Nua] 实测：补丁
				// 装上、游戏连画 4 句台词，包装一次都没被调用），TJS 类才拦得住。两条同时挂、
				// 各自自证，真机一轮就能判出这台游戏的字到底从哪儿过。
				if(typeof global.MessageLayer == "Object")
				{
					global.fushiLookupOriginalProcessCh = global.MessageLayer.processCh;
					global.MessageLayer.processCh = function(ch, steptime)
					{
						var result =
							(global.fushiLookupOriginalProcessCh incontextof this)(...);
						global.fushiLookupCaptureProcessCh(this, ch);
						return result;
					} incontextof global.MessageLayer;
				}
			}
			// 私有插件已出现时才封未来入口并扫既有 MsgwinRender；它不是通用
			// Kirikiri readiness。若插件稍后加载，首次 leftClick 会执行同一安全 ensure。
			var fushiLookupResolvedMsgwinPlugin =
				global.fushiLookupResolveMsgwinPlugin();
			if(fushiLookupResolvedMsgwinPlugin !== void)
			{
				installStage = 35;
				global.fushiLookupInstallGetRenderBridge();
				installStage = 36;
				global.fushiLookupSweepMsgwinRenders();
				installStage = 37;
			}

)TJS" LR"TJS(

			// 默认关闭的探测分支：换游戏、TextRender 一条都不命中时才开，用来判断"文本到底
			// 走哪条路"。只数次数，不做几何、不建 registry、不改任何绘制结果。
			if(global.fushiLookupProbeMode)
			{
				try
				{
					global.fushiLookupProbeOriginalDrawText = global.Layer.drawText;
					global.Layer.drawText = function(x, y, text, color, opacity, antialiased)
					{
						global.fushiLookupProbeDrawText++;
						return (global.fushiLookupProbeOriginalDrawText incontextof this)(...);
					};
					global.fushiLookupProbeOriginalProcessCh = global.MessageLayer.processCh;
					global.MessageLayer.processCh = function(ch, steptime)
					{
						global.fushiLookupProbeProcessCh++;
						return (global.fushiLookupProbeOriginalProcessCh incontextof this)(...);
					} incontextof global.MessageLayer;
				}
				catch(error)
				{
					global.fushiLookupProbeError = error.message;
				}
			}

			installStage = 40;
			global.kag.addHook("leftClick", global.fushiLookupLeftClickHook);
			installStage = 41;
			global.kag.addHook("mouseMove", global.fushiLookupMouseMoveHook);
			installStage = 42;
			global.kag.addHook("onMouseWheelHook", global.fushiLookupMouseWheelHook);
			installStage = 43;
			global.kag.addHook("keyDown", global.fushiLookupKeyDownHook);
			installStage = 50;

			Debug.notice("[HibikiLookup] sensor installed");
			System.removeContinuousHandler(global.fushiLookupBootstrap);
			global.fushiLookupBootstrap = void;
		}
		catch(e)
		{
			try
			{
				if(typeof global.fushiLookupNoteError == "Object")
					global.fushiLookupNoteError("bootstrap.stage",
						%[message: "stage=" + installStage]);
			}
			catch(e2) {}
			Debug.notice("[HibikiLookup] install failed: " + e.message);
			System.removeContinuousHandler(global.fushiLookupBootstrap);
			global.fushiLookupBootstrap = void;
		}
	};
	System.addContinuousHandler(global.fushiLookupBootstrap);
}
)TJS";

// ── DLL 侧：像素落地 + 传感器读数搬运 ─────────────────────────────────────────────
//
// 这一整段只做三件事：把 host 的 BGRA 帧 memcpy 进游戏渲染树里的卡片 Layer、把 TJS 传感器
// 的读数搬进共享内存、把落在卡片上的输入搬进输入环。prototype 里的 WinHTTP 客户端、
// 认证 token 环境变量、手写 JSON 解析器、临时文件 IPC 轮询线程、拼 TJS 源码再 eval——全部
// 不在了：跨边界的东西只剩一块位图和一串整数。

// 本地缓冲上界。真正的契约上界是 kLookupLineBytes（UTF-8 字节），这里只是宽松的字符数。
constexpr size_t kKirikiriLookupLineChars = 1200;

// tTJSVariant 的字段偏移**不是**插件 ABI 的稳定部分（各 krkr 分支的 pack 与字段序都可能
// 不同），所以不写死：安装时求值一个已知 64 位常量，按候选布局逐个比对，命中的那套才启用。
// 猜错的代价是把游戏进程里的随机内存当指针解引用，宁可探一次。
struct TjsVariantLayout {
  uint32_t type_offset;
  uint32_t value_offset;
};

constexpr uint32_t kTjsVariantBytes = 64;  // 实测 16；留足余量并全部清零后再交给引擎赋值
constexpr uint32_t kTjsVariantTypeString = 2;
constexpr uint32_t kTjsVariantTypeInteger = 4;
constexpr int64_t kTjsVariantProbeMagic = 0x0123456789ABCDEFLL;
constexpr TjsVariantLayout kTjsVariantLayouts[] = {{0u, 8u}, {0u, 4u}, {8u, 0u}};
constexpr int kTjsVariantProbeAttempts = 8;

TjsVariantLayout g_lookup_variant = {0u, 8u};
bool g_lookup_variant_ready = false;
int g_lookup_variant_attempts = 0;

// 注入侧日志出口：把 TJS 里被 catch 掉的异常**原文**落到 %TEMP%\fushi_galhook.log。
//
// 为什么需要它：hook 跑在游戏进程里，没有控制台、没有 Flutter 日志，唯一的出口是共享
// 内存——于是所有诊断都被压成"位"。位只能回答"成没成"，回答不了"为什么不成"，真机上
// 每问一次"为什么"就要改一版、重启一次游戏。而 catch 里本来就握着异常文本，把它写出来
// 一次就够。今天这条链上四个 bug（_invoke 自递归、PNG 死路、卡片层建不出来、类型不匹配）
// 全被 `catch(e) {}` + 乐观诊断位藏着，都是这么一轮轮试出来的。
void HookLogLine(const wchar_t* text) {
  if (text == nullptr || *text == L'\0') return;
  wchar_t dir[MAX_PATH] = {};
  const DWORD n = GetTempPathW(MAX_PATH, dir);
  if (n == 0 || n >= MAX_PATH) return;
  std::wstring path = dir;
  path += L"fushi_galhook.log";
  HANDLE file = CreateFileW(path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ,
                            nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  SYSTEMTIME st = {};
  GetLocalTime(&st);
  wchar_t stamp[64] = {};
  _snwprintf_s(stamp, _TRUNCATE, L"%02u:%02u:%02u.%03u pid=%lu ", st.wHour,
               st.wMinute, st.wSecond, st.wMilliseconds, GetCurrentProcessId());
  std::wstring line = stamp;
  line += text;
  line += L"\r\n";
  const int bytes = WideCharToMultiByte(CP_UTF8, 0, line.c_str(), -1, nullptr, 0,
                                        nullptr, nullptr);
  if (bytes > 1) {
    std::string utf8(static_cast<size_t>(bytes - 1), '\0');
    WideCharToMultiByte(CP_UTF8, 0, line.c_str(), -1, utf8.data(), bytes, nullptr,
                        nullptr);
    DWORD written = 0;
    WriteFile(file, utf8.data(), static_cast<DWORD>(utf8.size()), &written,
              nullptr);
  }
  CloseHandle(file);
}

std::wstring g_lookup_card_path;  // 备路 PNG，恒在 %TEMP%（游戏目录一个字节都不写）

// 卡片层就是卡片本身（cardW×cardH，摆在 anchor 上），所以目标缓冲整块都归本帧所有：
// 既不需要脏矩形，也不需要在层内做偏移——这两样都是"全视口卡片层"那版才需要的。
int32_t g_lookup_frame_anchor_x = 0;
int32_t g_lookup_frame_anchor_y = 0;
// 最近一帧真正投出的卡片尺寸。"只更新高亮"那条路不带像素，也就不带尺寸，但重画
// 高亮仍要按卡片尺寸算——所以必须记住上一帧的。
uint32_t g_lookup_frame_width = 0;
uint32_t g_lookup_frame_height = 0;
// 结构帧与兼容用 highlight-only 帧分开去重；高亮发布序绝不能越过尚未落屏的卡片。
uint64_t g_lookup_presented_seq = 0;
uint64_t g_lookup_highlight_presented_seq = 0;
uint64_t g_lookup_dropped_seq = 0;
uint64_t g_lookup_retry_seq = 0;
uint32_t g_lookup_retry_count = 0;
// hover 只在游戏线程即时绘制高亮，不跨 IPC；hook→host 单槽只发布 submit。
// g_lookup_hit_seq 仍跟踪最新任意命中，用来避免迟到卡片覆盖新的本地高亮；
// submit fence 保存最近一次真正的查词意图。
uint64_t g_lookup_hit_seq = 0;
uint64_t g_lookup_submit_hit_seq = 0;
// 游戏侧 Esc 取消 submit 的单调 fence。它不复用 generic hide：收卡/禁用/失败回滚
// 都不应取消未来或在途的用户查询；只有 fushiLookupCancelCurrent 会推进它。
uint64_t g_lookup_dismissed_submit_seq = 0;
uint64_t g_lookup_processed_submit_seq = 0;
uint64_t g_lookup_submit_retry_seq = 0;
uint32_t g_lookup_submit_retry_count = 0;
uint32_t g_lookup_submit_read_failures = 0;
uint32_t g_lookup_submit_retry_backoff = 0;
bool g_lookup_dismiss_fence_pending = false;
uint32_t g_lookup_dismiss_read_failures = 0;
uint32_t g_lookup_dismiss_read_backoff = 0;
bool g_lookup_hit_pending = false;
int64_t g_lookup_last_notify = -1;
bool g_lookup_card_shown = false;
bool g_lookup_enabled_last = false;
bool g_lookup_sensor_live = false;
// 经典 KAG3 采集面已自证（读到"真捕到字形"后不再求值）。
bool g_lookup_classic_source_known = false;
int g_lookup_classic_poll_ticks = 0;
bool g_lookup_input_pending = false;  // 上一帧撞到每帧搬运上限，队列里还有剩
// capture-suppress 在 TJS hide/update 成功的那一帧只挂起；必须到下一次 continuous
// callback 才写共享内存确认，不能把“脚本调用返回”冒充成“窗口已经进入后续合成帧”。
uint64_t g_lookup_capture_suppress_pending_ack_seq = 0;
uint32_t g_lookup_sensor_idle_ticks = 0;
uint32_t g_lookup_sensor_eval_failures = 0;
uint32_t g_lookup_sensor_eval_backoff = 0;

constexpr uint32_t kKirikiriLookupFrameRetryLimit = 3;
constexpr uint32_t kKirikiriLookupHitRetryLimit = 3;

void WriteKirikiriSharedU64(volatile uint64_t* value, uint64_t next) {
  if (value == nullptr) return;
  InterlockedExchange64(reinterpret_cast<volatile LONGLONG*>(value),
                        static_cast<LONGLONG>(next));
}

uint32_t LookupEnabledNow() {
  if (g_header == nullptr) return 0;
  return static_cast<uint32_t>(InterlockedCompareExchange(
      reinterpret_cast<volatile LONG*>(&g_header->lookup_enabled), 0, 0));
}

void SetLookupDiag(uint32_t bits) {
  if (g_header == nullptr) return;
  InterlockedOr(reinterpret_cast<volatile LONG*>(&g_header->lookup_diag),
                static_cast<LONG>(bits));
}

// UTF-16 → UTF-8，按 UTF-8 首字节边界截断。切碎多字节序列等于整行报废（host 侧按 UTF-8
// 解码），而"整行不截断"只是**语义**上的不截断——真超了 kLookupLineBytes 仍必须安全收尾。
uint32_t EncodeLookupLineUtf8(const wchar_t* line, uint8_t* out, uint32_t capacity) {
  if (line == nullptr || out == nullptr || capacity == 0) return 0;
  // 只在游戏主线程的连续帧回调里用，故用静态缓冲避免每帧几 KB 的栈压力。
  static char scratch[kKirikiriLookupLineChars * 4];
  const int written =
      WideCharToMultiByte(CP_UTF8, 0, line, -1, scratch,
                          static_cast<int>(sizeof(scratch)), nullptr, nullptr);
  if (written <= 1) return 0;  // 只有终止符 = 空行
  uint32_t bytes = static_cast<uint32_t>(written - 1);
  if (bytes > capacity) {
    bytes = capacity;
    while (bytes > 0 && (static_cast<uint8_t>(scratch[bytes]) & 0xC0u) == 0x80u) {
      bytes--;
    }
  }
  memcpy(out, scratch, bytes);
  return bytes;
}

uint32_t ReadVariantU32(const uint8_t* variant, uint32_t offset) {
  uint32_t value = 0;
  memcpy(&value, variant + offset, sizeof(value));
  return value;
}

int64_t ReadVariantI64(const uint8_t* variant, uint32_t offset) {
  int64_t value = 0;
  memcpy(&value, variant + offset, sizeof(value));
  return value;
}

// 分配 ttstr → 求值 → 释放。缓冲必须先清零：TJS 的 tTJSVariant 赋值会先 Clear() 目标，
// 全零在任何候选布局下都是 tvtVoid，Clear() 不会去释放一个野指针。
bool ExecuteTjsExpressionGuarded(const wchar_t* expression, uint8_t* variant) {
  if (g_lookup_execute_expression == nullptr || g_lookup_alloc_string == nullptr ||
      g_lookup_release_string == nullptr || expression == nullptr) {
    return false;
  }
  memset(variant, 0, kTjsVariantBytes);
  TjsVariantString* text = nullptr;
  bool ok = false;
  try {
    text = g_lookup_alloc_string(expression);
    if (text != nullptr) {
      const TjsString content = {text};
      g_lookup_execute_expression(content, variant);
      ok = true;
    }
  } catch (...) {
    // 传感器还没建立时表达式会引用不存在的 global，TJS 抛异常是正常时序而非故障。
    ok = false;
  }
  if (text != nullptr) g_lookup_release_string(text);
  return ok;
}

bool ProbeTjsVariantLayout() {
  if (g_lookup_variant_attempts >= kTjsVariantProbeAttempts) return false;
  g_lookup_variant_attempts++;
  uint8_t variant[kTjsVariantBytes];
  if (!ExecuteTjsExpressionGuarded(L"0x0123456789ABCDEF", variant)) return false;
  for (const TjsVariantLayout& candidate : kTjsVariantLayouts) {
    if (ReadVariantU32(variant, candidate.type_offset) != kTjsVariantTypeInteger) {
      continue;
    }
    if (ReadVariantI64(variant, candidate.value_offset) != kTjsVariantProbeMagic) {
      continue;
    }
    g_lookup_variant = candidate;
    return true;
  }
  return false;
}

bool EvaluateTjsInteger(const wchar_t* expression, int64_t* value) {
  if (value == nullptr || !g_lookup_variant_ready) return false;
  uint8_t variant[kTjsVariantBytes];
  if (!ExecuteTjsExpressionGuarded(expression, variant)) return false;
  if (ReadVariantU32(variant, g_lookup_variant.type_offset) != kTjsVariantTypeInteger) {
    return false;
  }
  *value = ReadVariantI64(variant, g_lookup_variant.value_offset);
  return true;
}

// SEH 守卫从 tTJSVariantString 拷字符（只碰裸数组，可 __try）。长串优先，缺则内联短串。
bool CopyTjsVariantStringGuarded(const TjsVariantString* text, wchar_t* out,
                                 size_t out_chars) {
  __try {
    const wchar_t* src =
        text->long_string != nullptr ? text->long_string : text->short_string;
    if (src == nullptr) return false;
    size_t k = 0;
    for (; src[k] != 0 && k + 1 < out_chars; k++) out[k] = src[k];
    out[k] = 0;
    return true;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
}

bool EvaluateTjsString(const wchar_t* expression, wchar_t* out, size_t out_chars) {
  if (out == nullptr || out_chars == 0 || !g_lookup_variant_ready) return false;
  uint8_t variant[kTjsVariantBytes];
  if (!ExecuteTjsExpressionGuarded(expression, variant)) return false;
  if (ReadVariantU32(variant, g_lookup_variant.type_offset) != kTjsVariantTypeString) {
    return false;
  }
  TjsVariantString* text = nullptr;
  memcpy(&text, variant + g_lookup_variant.value_offset, sizeof(text));
  if (text == nullptr) {  // TJS 用空指针表示空串
    out[0] = 0;
    return true;
  }
  const bool copied = CopyTjsVariantStringGuarded(text, out, out_chars);
  if (g_lookup_release_string != nullptr) g_lookup_release_string(text);
  return copied;
}

void ExecuteTjsScriptGuarded(const wchar_t* script) {
  if (g_lookup_execute_script == nullptr || g_lookup_alloc_string == nullptr ||
      g_lookup_release_string == nullptr || script == nullptr) {
    return;
  }
  TjsVariantString* text = nullptr;
  try {
    text = g_lookup_alloc_string(script);
    if (text != nullptr) {
      const TjsString content = {text};
      g_lookup_execute_script(content, nullptr);
    }
  } catch (...) {
    // 插件 ABI 边界绝不把 C++/TJS 异常抛回游戏事件循环。
  }
  if (text != nullptr) g_lookup_release_string(text);
}

void ApplyKirikiriLookupHighlight(uint32_t highlight_start,
                                  uint32_t highlight_len) {
  std::wstring script = L"global.fushiLookupApplyHighlight(";
  script += std::to_wstring(highlight_start);
  script += L",";
  script += std::to_wstring(highlight_len);
  script += L");";
  ExecuteTjsScriptGuarded(script.c_str());
}

// 位图回执脚本。七个实参全部是 std::to_wstring 出来的整数，脚本里不存在任何来自
// host、游戏或用户的字符串。
void ApplyKirikiriLookupCard(uint64_t seq, uint32_t highlight_start,
                             uint32_t highlight_len, int32_t anchor_x,
                             int32_t anchor_y, uint32_t card_w, uint32_t card_h,
                             bool png_route) {
  std::wstring script = png_route ? L"global.fushiLookupApplyPng("
                                  : L"global.fushiLookupApply(";
  script += std::to_wstring(seq);
  script += L",";
  script += std::to_wstring(highlight_start);
  script += L",";
  script += std::to_wstring(highlight_len);
  script += L",";
  script += std::to_wstring(anchor_x);
  script += L",";
  script += std::to_wstring(anchor_y);
  script += L",";
  script += std::to_wstring(card_w);
  script += L",";
  script += std::to_wstring(card_h);
  script += L");";
  ExecuteTjsScriptGuarded(script.c_str());
}

// 写像素之前调：卡片层不存在就建，尺寸/位置不对就调。层是**按卡片尺寸**建的，所以这一步
// 之后目标缓冲整块都属于本帧。
void PrepareKirikiriLookupCard(int32_t anchor_x, int32_t anchor_y, uint32_t card_w,
                               uint32_t card_h) {
  std::wstring script = L"global.fushiLookupPrepare(";
  script += std::to_wstring(anchor_x);
  script += L",";
  script += std::to_wstring(anchor_y);
  script += L",";
  script += std::to_wstring(card_w);
  script += L",";
  script += std::to_wstring(card_h);
  script += L");";
  ExecuteTjsScriptGuarded(script.c_str());
}

void HideKirikiriLookupCard() {
  g_lookup_card_shown = false;
  // 即使 C++ 状态认为已经隐藏，也强制把 TJS 层收起：Esc 是游戏线程本地处理的，
  // 两侧状态可能短暂不同步，hide 本身必须幂等。
  ApplyKirikiriLookupCard(0, 0, 0, 0, 0, 0, 0, false);
}

bool SuppressKirikiriLookupCardForCapture(uint64_t seq) {
  if (seq == 0) return false;
  std::wstring script = L"global.fushiLookupSuppressForCapture(";
  script += std::to_wstring(seq);
  script += L");";
  ExecuteTjsScriptGuarded(script.c_str());
  int64_t applied = 0;
  if (!EvaluateTjsInteger(L"global.fushiLookupCaptureSuppressSeq", &applied) ||
      applied != static_cast<int64_t>(seq)) {
    return false;
  }
  g_lookup_card_shown = false;
  return true;
}

void CommitKirikiriLookupCaptureSuppressAck() {
  const uint64_t seq = g_lookup_capture_suppress_pending_ack_seq;
  if (seq == 0 || g_header == nullptr) return;
  // 这里只会在**下一次** PumpKirikiriLookup 入口执行。普通 present/dismiss 绝不能推进
  // 这个字段，否则更晚的普通帧可能伪装成截图抑制已经安全生效。
  const uint64_t current =
      ReadKirikiriSharedU64(&g_header->lookup_frame_applied_seq);
  if (seq > current) {
    WriteKirikiriSharedU64(&g_header->lookup_frame_applied_seq, seq);
  }
  g_lookup_capture_suppress_pending_ack_seq = 0;
}

// 逐行拷。源侧（共享内存）按契约恒为正 pitch、恒自顶向下；目标侧是游戏 Layer，
// mainImageBufferPitch 可能为负（KiriKiri 允许自底向上的行序），故行步进用带符号 stride：
// base + row*stride 对两种行序都走出同一个视觉行序。层已按卡片尺寸备好，故整块都是本帧的，
// 不需要擦上一帧、也不需要层内偏移。
bool BlitLookupFrameGuarded(uint8_t* base, int32_t stride, uint32_t width,
                            uint32_t height, uint32_t source_pitch,
                            const uint8_t* pixels) {
  __try {
    for (uint32_t row = 0; row < height; ++row) {
      uint8_t* dst = base + static_cast<ptrdiff_t>(row) * stride;
      memcpy(dst, pixels + static_cast<size_t>(row) * source_pitch,
             static_cast<size_t>(width) * 4u);
    }
    return true;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
}

// 双缓冲槽仍可能在扫描后被 host 复用。所有分支（包括无 payload 的 dismiss/highlight）
// 先取同一份稳定元数据快照，不能在分支里继续混读 live frame。
bool SnapshotKirikiriLookupFrame(fushi_voice_hook::LookupFrame* source,
                                 fushi_voice_hook::LookupFrame* out) {
  if (source == nullptr || out == nullptr ||
      ReadKirikiriSharedU32(&source->ready) == 0) {
    return false;
  }
  const uint64_t seq = ReadKirikiriSharedU64(&source->seq);
  if (seq == 0) return false;
  fushi_voice_hook::LookupFrame staged{};
  staged.seq = seq;
  staged.hit_seq = source->hit_seq;
  staged.flags = source->flags;
  staged.width = source->width;
  staged.height = source->height;
  staged.pitch = source->pitch;
  staged.anchor_x = source->anchor_x;
  staged.anchor_y = source->anchor_y;
  staged.highlight_start = source->highlight_start;
  staged.highlight_len = source->highlight_len;
  staged.byte_len = source->byte_len;
  staged.reserved = source->reserved;
  staged.reserved2 = source->reserved2;
  staged.ready = 1;
  if (ReadKirikiriSharedU32(&source->ready) == 0 ||
      ReadKirikiriSharedU64(&source->seq) != seq) {
    return false;
  }
  *out = staged;
  return true;
}

bool KirikiriLookupFrameStillPublished(fushi_voice_hook::LookupFrame* source,
                                       uint64_t seq) {
  return source != nullptr && ReadKirikiriSharedU32(&source->ready) != 0 &&
         ReadKirikiriSharedU64(&source->seq) == seq;
}

void ResetKirikiriLookupFrameRetry(uint64_t seq) {
  if (g_lookup_retry_seq != seq) return;
  g_lookup_retry_seq = 0;
  g_lookup_retry_count = 0;
}

void MarkKirikiriLookupFramePresented(uint64_t seq) {
  g_lookup_presented_seq = seq;
  ResetKirikiriLookupFrameRetry(seq);
}

void DropKirikiriLookupFrame(fushi_voice_hook::LookupFrame* source,
                              uint64_t seq, uint64_t staged_hit_seq) {
  if (!KirikiriLookupFrameStillPublished(source, seq)) return;
  if (seq > g_lookup_dropped_seq) g_lookup_dropped_seq = seq;
  ResetKirikiriLookupFrameRetry(seq);
  // 当前 submit 的卡片失败后，旧卡不能继续冒充这次查询的结果。
  // hit_seq 必须来自已二次验证过的 staging；StillPublished 之后再读 live payload 会把
  // 已复用槽的新 hit 身份误套到旧 seq 的 drop 上。
  if (staged_hit_seq == g_lookup_submit_hit_seq) HideKirikiriLookupCard();
  SetLookupDiag(fushi_voice_hook::kLookupDiagFrameRejected);
}

void RetryOrDropKirikiriLookupFrame(fushi_voice_hook::LookupFrame* source,
                                     uint64_t seq, uint64_t staged_hit_seq) {
  if (!KirikiriLookupFrameStillPublished(source, seq)) return;
  if (g_lookup_retry_seq != seq) {
    g_lookup_retry_seq = seq;
    g_lookup_retry_count = 0;
  }
  ++g_lookup_retry_count;
  SetLookupDiag(fushi_voice_hook::kLookupDiagFrameRejected);
  if (g_lookup_retry_count >= kKirikiriLookupFrameRetryLimit) {
    DropKirikiriLookupFrame(source, seq, staged_hit_seq);
  }
}

bool RefreshKirikiriLookupDismissFence() {
  int64_t dismissed = 0;
  if (!EvaluateTjsInteger(L"global.fushiLookupDismissedSubmitSeq", &dismissed)) {
    return false;
  }
  if (dismissed > 0) {
    const uint64_t seq = static_cast<uint64_t>(dismissed);
    if (seq > g_lookup_dismissed_submit_seq) {
      g_lookup_dismissed_submit_seq = seq;
      if (seq > g_lookup_processed_submit_seq) {
        g_lookup_processed_submit_seq = seq;
      }
      if (g_lookup_submit_retry_seq == seq) {
        g_lookup_submit_retry_seq = 0;
        g_lookup_submit_retry_count = 0;
      }
      g_lookup_card_shown = false;
    }
  }
  g_lookup_dismiss_read_failures = 0;
  g_lookup_dismiss_read_backoff = 0;
  g_lookup_dismiss_fence_pending = false;
  return true;
}

void PresentKirikiriLookupFrame() {
  if (g_header == nullptr) return;
  fushi_voice_hook::LookupFrame* best = nullptr;
  fushi_voice_hook::LookupFrame best_frame{};
  uint32_t best_index = 0;
  uint64_t best_seq = 0;
  fushi_voice_hook::LookupFrame* best_highlight = nullptr;
  fushi_voice_hook::LookupFrame best_highlight_frame{};
  uint64_t best_highlight_seq = 0;
  for (uint32_t i = 0; i < g_header->lookup_frame_count; ++i) {
    fushi_voice_hook::LookupFrame* frame = fushi_voice_hook::LookupFrameAt(g_header, i);
    fushi_voice_hook::LookupFrame staged{};
    if (!SnapshotKirikiriLookupFrame(frame, &staged)) continue;
    // 判据只有一份，在契约头（ShouldApplyLookupFrame），replay 测试跑的是同一个函数。
    // hover 与 submit 身份分离；无像素高亮也用独立处理游标，不能抢过卡片结构帧。
    const bool highlight_only =
        staged.flags == fushi_voice_hook::kLookupFrameHighlightOnly;
    const uint64_t processed =
        highlight_only
            ? g_lookup_highlight_presented_seq
            : (g_lookup_presented_seq > g_lookup_dropped_seq
                   ? g_lookup_presented_seq
                   : g_lookup_dropped_seq);
    if (!highlight_only && staged.hit_seq != 0 &&
        staged.hit_seq <= g_lookup_dismissed_submit_seq) {
      // Esc 已在游戏侧取消这笔 submit。把 host 已在途/已发布的结构帧记为消费，避免
      // 单槽保持 ready 时每个游戏帧重新扫描；新 submit 的 hit_seq 单调更大，自动放行。
      if (KirikiriLookupFrameStillPublished(frame, staged.seq)) {
        if (staged.seq > g_lookup_dropped_seq) g_lookup_dropped_seq = staged.seq;
        ResetKirikiriLookupFrameRetry(staged.seq);
        SetLookupDiag(fushi_voice_hook::kLookupDiagFrameRejected);
      }
      continue;
    }
    if (!fushi_voice_hook::ShouldApplyLookupFrame(
            staged.seq, staged.hit_seq, staged.flags, processed,
            g_lookup_hit_seq, g_lookup_submit_hit_seq)) {
      continue;
    }
    if (highlight_only) {
      if (staged.seq <= best_highlight_seq) continue;
      best_highlight = frame;
      best_highlight_frame = staged;
      best_highlight_seq = staged.seq;
    } else {
      if (staged.seq <= best_seq) continue;
      best = frame;
      best_frame = staged;
      best_index = i;
      best_seq = staged.seq;
    }
  }
  // 结构帧永远优先。新主路不再投 hover 帧；这里仅兼容旧 host，且专用 TJS 函数绝不
  // prepare/visible 卡片，所以 Esc 收起后不会被一张排队中的 hover 重新弹出。
  if (best == nullptr) {
    if (best_highlight == nullptr ||
        !KirikiriLookupFrameStillPublished(best_highlight,
                                            best_highlight_seq)) {
      return;
    }
    if (g_lookup_card_shown) {
      ApplyKirikiriLookupHighlight(best_highlight_frame.highlight_start,
                                   best_highlight_frame.highlight_len);
    }
    g_lookup_highlight_presented_seq = best_highlight_seq;
    return;
  }

  const fushi_voice_hook::LookupFrame& staged = best_frame;

  // Esc 的 TJS hook 与当前函数同在游戏线程，但 notify 读取可能因传感器退避而稍后发生。
  // 真正要落一张结构帧时额外直读一次单调 fence，堵住“Esc 已隐藏、在途结果同帧重开”。
  if (!RefreshKirikiriLookupDismissFence()) {
    RetryOrDropKirikiriLookupFrame(best, best_seq, staged.hit_seq);
    return;
  }
  if (staged.hit_seq != 0 &&
      staged.hit_seq <= g_lookup_dismissed_submit_seq) {
    DropKirikiriLookupFrame(best, best_seq, staged.hit_seq);
    return;
  }

  // 收卡由 flags 自述，不靠"width==0 就是收卡"的魔法编码——后者要求每个读侧都记住这条
  // 隐规则，而它和"host 投了张废帧"在字节上完全一样。必须在 IsLookupFrameSane 之前认掉：
  // 收卡帧按定义没有像素，过不了那道校验。
  if (staged.flags == fushi_voice_hook::kLookupFrameDismiss) {
    if (!KirikiriLookupFrameStillPublished(best, best_seq)) return;
    HideKirikiriLookupCard();
    MarkKirikiriLookupFramePresented(best_seq);
    return;
  }

  // 制卡截图的临时抑制不是 dismiss：保留 submit/Esc fence，只隐藏 card/highlight。
  // TJS success token 保证 hide/update 已走完；共享内存 ack 则刻意延后一轮 continuous
  // callback，给游戏窗口合成跨过一个生命周期边界。
  if (staged.flags == fushi_voice_hook::kLookupFrameCaptureSuppress) {
    if (!KirikiriLookupFrameStillPublished(best, best_seq)) return;
    if (!SuppressKirikiriLookupCardForCapture(best_seq)) {
      RetryOrDropKirikiriLookupFrame(best, best_seq, staged.hit_seq);
      return;
    }
    MarkKirikiriLookupFramePresented(best_seq);
    g_lookup_capture_suppress_pending_ack_seq = best_seq;
    return;
  }

  // 只更新高亮：卡片像素一个字节都不动，只把高亮挪到新位置。与收卡同理，必须在
  // IsLookupFrameSane 之前认掉——它按定义不带像素，过不了那道校验。
  //
  // 悬停每换一个字就走一次普通 present 的话，等于每次都重抓整张卡（CapturePreview
  // → PNG 编解码 → 全卡 memcpy），鼠标划过一行就是几十次；真机症状就是"太卡了"。
  // 而高亮画在游戏自己的图层上、根本不在卡片位图里，这条路因此完全不需要像素。
  // 跨进程来的 width/height/pitch 全是不可信输入：先过契约校验，再谈拷贝。
  if (staged.flags != 0) {
    // 未知/组合 flag 是永久不合法输入；消费掉避免每个游戏帧重复热循环。
    DropKirikiriLookupFrame(best, best_seq, staged.hit_seq);
    return;
  }
  if (!fushi_voice_hook::IsLookupFrameSane(g_header, &staged) ||
      static_cast<uint32_t>(best_seq % g_header->lookup_frame_count) != best_index) {
    DropKirikiriLookupFrame(best, best_seq, staged.hit_seq);
    return;
  }
  const uint8_t* pixels = fushi_voice_hook::LookupBitmapAt(g_header, best_index);
  if (pixels == nullptr) {
    RetryOrDropKirikiriLookupFrame(best, best_seq, staged.hit_seq);
    return;
  }

  const uint32_t highlight_start = staged.highlight_start;
  const uint32_t highlight_len =
      staged.hit_seq == g_lookup_hit_seq ? staged.highlight_len : 0;
  const int32_t anchor_x = staged.anchor_x;
  const int32_t anchor_y = staged.anchor_y;
  const uint32_t width = staged.width;
  const uint32_t height = staged.height;
  const uint32_t source_pitch = staged.pitch;

  // 建/调卡片层必须在取写指针**之前**：层是按本帧 cardW×cardH 建的，尺寸变化会重新分配
  // 缓冲，先取指针再改尺寸就是往已经释放的内存里写。
  PrepareKirikiriLookupCard(anchor_x, anchor_y, width, height);

  int64_t layer_w = 0;
  int64_t layer_h = 0;
  int64_t buffer = 0;
  int64_t stride64 = 0;
  // 写指针**每帧重取**：copy-on-write 与 layer 尺寸变化都会让上一帧的指针失效，缓存它就是
  // 往已经不属于该层的内存里写。pitch 必须在取写指针之后读——取写指针可能换掉整块缓冲。
  // 逐段求值而不是一串 &&：一串短路只能告诉你"主路不行"，分不出是卡片层压根没建
  // 出来，还是层在但拿不到写指针——两者修法完全不同（前者查 fushiLookupPrepare，
  // 后者查层类型/引擎能力）。真机上这一处分型省下的是整整一轮往返。
  const bool layer_alive =
      EvaluateTjsInteger(L"global.fushiLookupCard.imageWidth", &layer_w) &&
      EvaluateTjsInteger(L"global.fushiLookupCard.imageHeight", &layer_h);
  if (!layer_alive) {
    SetLookupDiag(fushi_voice_hook::kLookupDiagCardLayerMissing);
  }
  const bool buffer_ok =
      layer_alive &&
      EvaluateTjsInteger(L"global.fushiLookupCard.mainImageBufferForWrite", &buffer) &&
      EvaluateTjsInteger(L"global.fushiLookupCard.mainImageBufferPitch", &stride64) &&
      buffer != 0;
  if (layer_alive && !buffer_ok) {
    SetLookupDiag(fushi_voice_hook::kLookupDiagWriteBufferNull);
  }
  const bool geometry = buffer_ok;

  if (!geometry) {
    // 仓内没有 PNG producer。旧固定路径可能命中 PID 复用后的残留图，绝不能把它当作
    // 当前帧 loadImages 后再伪报成功；保留诊断位，但明确走有界失败。
    SetLookupDiag(fushi_voice_hook::kLookupDiagFallbackPngRoute);
    SetLookupDiag(fushi_voice_hook::kLookupDiagFallbackPngMissing);
    RetryOrDropKirikiriLookupFrame(best, best_seq, staged.hit_seq);
    return;
  }
  SetLookupDiag(fushi_voice_hook::kLookupDiagBufferRouteReady);

  // 层就是卡片，所以尺寸必须**逐像素相等**——不等说明 prepare 没生效（层被别处改过、或
  // setImageSize 失败），此时按本帧尺寸拷就是越界写。这是比"装得下就行"更强也更简单的
  // 不变量：目标缓冲整块都归本帧。
  const int32_t stride = static_cast<int32_t>(stride64);
  const int32_t stride_abs = stride < 0 ? -stride : stride;
  if (layer_w != static_cast<int64_t>(width) ||
      layer_h != static_cast<int64_t>(height) ||
      stride_abs < static_cast<int32_t>(width) * 4) {
    RetryOrDropKirikiriLookupFrame(best, best_seq, staged.hit_seq);
    return;
  }

  if (!BlitLookupFrameGuarded(
          reinterpret_cast<uint8_t*>(static_cast<uintptr_t>(buffer)), stride, width,
          height, source_pitch, pixels)) {
    RetryOrDropKirikiriLookupFrame(best, best_seq, staged.hit_seq);
    return;
  }

  // 拷完复查 seq/ready：host 若在拷贝中途改写了这一格，画面就是撕裂的半张卡，宁可不显示
  // 让下一帧重来。
  if (!KirikiriLookupFrameStillPublished(best, best_seq)) return;

  g_lookup_frame_anchor_x = anchor_x;
  g_lookup_frame_anchor_y = anchor_y;
  g_lookup_frame_width = width;
  g_lookup_frame_height = height;
  ApplyKirikiriLookupCard(best_seq, highlight_start, highlight_len, anchor_x,
                          anchor_y, width, height, false);
  int64_t applied_seq = 0;
  if (!EvaluateTjsInteger(L"global.fushiLookupCardSeq", &applied_seq) ||
      applied_seq != static_cast<int64_t>(best_seq)) {
    g_lookup_card_shown = false;
    RetryOrDropKirikiriLookupFrame(best, best_seq, staged.hit_seq);
    return;
  }
  g_lookup_card_shown = true;
  MarkKirikiriLookupFramePresented(best_seq);
  SetLookupDiag(fushi_voice_hook::kLookupDiagFramePresented);
}

void ResetKirikiriLookupHitRetry(uint64_t seq) {
  if (g_lookup_submit_retry_seq != seq) return;
  g_lookup_submit_retry_seq = 0;
  g_lookup_submit_retry_count = 0;
}

bool RetryOrDropKirikiriLookupHit(uint64_t seq) {
  if (g_lookup_submit_retry_seq != seq) {
    g_lookup_submit_retry_seq = seq;
    g_lookup_submit_retry_count = 0;
  }
  ++g_lookup_submit_retry_count;
  if (g_lookup_submit_retry_count < kKirikiriLookupHitRetryLimit) return false;
  // 同一个耐久 submit 连续失败后有界放弃；否则 continuous handler 会在游戏主线程
  // 永远重试。旧卡的异步结果已被 submit fence 作废，失败时也要收掉旧卡。
  g_lookup_processed_submit_seq = seq;
  ResetKirikiriLookupHitRetry(seq);
  if (seq == g_lookup_submit_hit_seq) HideKirikiriLookupCard();
  SetLookupDiag(fushi_voice_hook::kLookupDiagSensorFault);
  return true;
}

bool ObserveKirikiriLookupSubmitSeq(uint64_t seq) {
  if (seq == 0 || seq <= g_lookup_submit_hit_seq) return false;
  g_lookup_submit_hit_seq = seq;
  if (seq > g_lookup_hit_seq) g_lookup_hit_seq = seq;
  // 只有一个真正更新的耐久 submit 才能换代 retry epoch。hover、诊断和 input 的 notify
  // 不改 SubmitSeq，因而不能借 notify 清掉同一坏快照的有界失败计数或退避。
  g_lookup_submit_retry_seq = seq;
  g_lookup_submit_retry_count = 0;
  g_lookup_submit_read_failures = 0;
  g_lookup_submit_retry_backoff = 0;
  return true;
}

void BackoffKirikiriLookupUnknownSubmit() {
  if (++g_lookup_submit_read_failures < kKirikiriLookupHitRetryLimit) return;
  g_lookup_submit_read_failures = 0;
  g_lookup_submit_retry_backoff = 30;
  SetLookupDiag(fushi_voice_hook::kLookupDiagSensorFault);
}

bool RetryKirikiriLookupSubmitTransient(uint64_t failed_seq) {
  int64_t latest = 0;
  if (!EvaluateTjsInteger(L"global.fushiLookupSubmitSeq", &latest)) {
    // 连事务游标也读不到时无法证明哪个 submit 损坏：允许退避后重读，但绝不确认/丢弃。
    BackoffKirikiriLookupUnknownSubmit();
    return false;
  }
  if (latest > 0 && static_cast<uint64_t>(latest) > failed_seq) {
    const uint64_t latest_seq = static_cast<uint64_t>(latest);
    ObserveKirikiriLookupSubmitSeq(latest_seq);
    return false;
  }
  // 辅助复读仍是同一（或不可能倒退的更小）seq，故这是“已知坏快照”，与非法几何/
  // 空行共用三次上限，最终 processed/drop；不能每 30 帧再来一轮无限 burst。
  return RetryOrDropKirikiriLookupHit(failed_seq);
}

void ObserveKirikiriLookupDismissFence() {
  if (!g_lookup_dismiss_fence_pending) return;
  if (g_lookup_dismiss_read_backoff > 0) {
    --g_lookup_dismiss_read_backoff;
    return;
  }
  if (!RefreshKirikiriLookupDismissFence()) {
    if (++g_lookup_dismiss_read_failures >= kKirikiriLookupHitRetryLimit) {
      g_lookup_dismiss_read_failures = 0;
      g_lookup_dismiss_read_backoff = 30;
      SetLookupDiag(fushi_voice_hook::kLookupDiagSensorFault);
    }
    return;
  }
}

bool PublishKirikiriLookupHit(bool new_notification) {
  fushi_voice_hook::LookupHitSlot* slot = fushi_voice_hook::LookupHitOf(g_header);
  if (slot == nullptr) return false;
  int64_t submit_seq_value = 0;
  bool have_submit_seq = false;
  if (g_lookup_submit_retry_backoff > 0) {
    // 退避期间仅新 notify 值得一次廉价游标探测；hover 的 SubmitSeq 不变，所以保持
    // cooldown。真正的新点击会给出更大的 SubmitSeq，并立即换代 epoch，不增加输入延迟。
    if (new_notification &&
        EvaluateTjsInteger(L"global.fushiLookupSubmitSeq", &submit_seq_value) &&
        submit_seq_value > 0 &&
        ObserveKirikiriLookupSubmitSeq(
            static_cast<uint64_t>(submit_seq_value))) {
      have_submit_seq = true;
    } else {
      --g_lookup_submit_retry_backoff;
      return false;
    }
  }

  // visual seq 是游戏线程即时高亮的身份；它只负责防止迟到卡片覆盖更新的本地高亮，
  // 不参与共享 submit 单槽。读失败不该阻断耐久点击快照。
  int64_t visual_seq = 0;
  if (EvaluateTjsInteger(L"global.fushiLookupVisualSeq", &visual_seq) &&
      visual_seq > 0) {
    const uint64_t visual = static_cast<uint64_t>(visual_seq);
    if (visual > g_lookup_hit_seq) g_lookup_hit_seq = visual;
  }

  if (!have_submit_seq &&
      !EvaluateTjsInteger(L"global.fushiLookupSubmitSeq", &submit_seq_value)) {
    // 连续失败时退避，但不确认/丢弃未知 submit；稍后仍会读取同一耐久快照。
    BackoffKirikiriLookupUnknownSubmit();
    return false;
  }
  if (submit_seq_value <= 0) return true;
  const uint64_t hit_seq = static_cast<uint64_t>(submit_seq_value);
  ObserveKirikiriLookupSubmitSeq(hit_seq);
  if (hit_seq <= g_lookup_processed_submit_seq) return true;

  int64_t char_index = 0;
  int64_t char_count = 0;
  int64_t glyph_x = 0;
  int64_t glyph_y = 0;
  int64_t glyph_w = 0;
  int64_t glyph_h = 0;
  int64_t view_w = 0;
  int64_t view_h = 0;
  if (!EvaluateTjsInteger(L"global.fushiLookupSubmitCharIndex", &char_index) ||
      !EvaluateTjsInteger(L"global.fushiLookupSubmitCharCount", &char_count) ||
      !EvaluateTjsInteger(L"global.fushiLookupSubmitGlyphX", &glyph_x) ||
      !EvaluateTjsInteger(L"global.fushiLookupSubmitGlyphY", &glyph_y) ||
      !EvaluateTjsInteger(L"global.fushiLookupSubmitGlyphW", &glyph_w) ||
      !EvaluateTjsInteger(L"global.fushiLookupSubmitGlyphH", &glyph_h) ||
      !EvaluateTjsInteger(L"global.fushiLookupSubmitViewW", &view_w) ||
      !EvaluateTjsInteger(L"global.fushiLookupSubmitViewH", &view_h)) {
    return RetryKirikiriLookupSubmitTransient(hit_seq);
  }
  if (char_count <= 0 || char_index < 0 || char_index >= char_count) {
    return RetryOrDropKirikiriLookupHit(hit_seq);
  }
  // 只在游戏主线程用；放静态区避免每次命中往栈上压两份 2.4KB。
  static wchar_t line[kKirikiriLookupLineChars];
  static uint8_t encoded_line[fushi_voice_hook::kLookupLineBytes];
  if (!EvaluateTjsString(L"global.fushiLookupSubmitLine", line,
                         kKirikiriLookupLineChars)) {
    return RetryKirikiriLookupSubmitTransient(hit_seq);
  }
  const uint32_t line_bytes = EncodeLookupLineUtf8(
      line, encoded_line, fushi_voice_hook::kLookupLineBytes);
  if (line_bytes == 0) return RetryOrDropKirikiriLookupHit(hit_seq);

  // SubmitSeq 最后发布。全部字段/字符串读完后复读一次；若期间又点击了新词，当前
  // staging 直接作废且不计失败，下一帧只处理更新的快照。
  int64_t verified_seq_value = 0;
  if (!EvaluateTjsInteger(L"global.fushiLookupSubmitSeq", &verified_seq_value)) {
    return RetryKirikiriLookupSubmitTransient(hit_seq);
  }
  if (verified_seq_value <= 0 ||
      static_cast<uint64_t>(verified_seq_value) != hit_seq) {
    if (verified_seq_value > 0 &&
        static_cast<uint64_t>(verified_seq_value) > hit_seq) {
      const uint64_t verified = static_cast<uint64_t>(verified_seq_value);
      ObserveKirikiriLookupSubmitSeq(verified);
      return false;
    }
    return RetryKirikiriLookupSubmitTransient(hit_seq);
  }

  // 单槽 seqlock：本地 staging 完成后，先把旧发布序清成 0，再触碰共享 payload。
  // 否则快速连续 submit 时 host 可能看见“旧 seq + 新 payload”，两次复读仍相等，
  // 最终把错行当成旧命中。lookup_hit_count 只在最终发布后递增，故 0 只表示写入中。
  WriteKirikiriSharedU64(&slot->seq, 0);

  slot->char_index = static_cast<uint32_t>(char_index);
  slot->char_count = static_cast<uint32_t>(char_count);
  slot->glyph_x = static_cast<int32_t>(glyph_x);
  slot->glyph_y = static_cast<int32_t>(glyph_y);
  slot->glyph_w = static_cast<int32_t>(glyph_w);
  slot->glyph_h = static_cast<int32_t>(glyph_h);
  slot->view_w = static_cast<int32_t>(view_w);
  slot->view_h = static_cast<int32_t>(view_h);
  slot->flags = fushi_voice_hook::kLookupHitFlagSubmit;
  memcpy(slot->line_utf8, encoded_line, line_bytes);
  slot->line_bytes = line_bytes;
  // seq **最后**写：Interlocked 是全栅栏，保证上面的 payload 对 host 先可见。
  WriteKirikiriSharedU64(&slot->seq, hit_seq);
  g_lookup_processed_submit_seq = hit_seq;
  ResetKirikiriLookupHitRetry(hit_seq);
  InterlockedIncrement64(
      reinterpret_cast<volatile LONGLONG*>(&g_header->lookup_hit_count));
  SetLookupDiag(fushi_voice_hook::kLookupDiagGeometryObserved |
                fushi_voice_hook::kLookupDiagHitSubmitted);
  return true;
}

void DrainKirikiriLookupInput() {
  fushi_voice_hook::LookupInputSlot* inputs = fushi_voice_hook::LookupInputsOf(g_header);
  const uint32_t slots = g_header->lookup_input_slot_count;
  g_lookup_input_pending = false;
  if (inputs == nullptr || slots == 0) return;
  // 每帧至多搬 32 条（TJS 侧已把连续 move 就地合并），回调不做无界循环。撞上限时置 pending，
  // 让下一帧继续搬——否则 notify 不再变化，剩下的事件会一直卡在 TJS 队列里。
  g_lookup_input_pending = true;
  for (int drained = 0; drained < 32; ++drained) {
    int64_t packed = 0;
    if (!EvaluateTjsInteger(L"global.fushiLookupInputTake()", &packed)) break;
    if (packed == 0) {
      g_lookup_input_pending = false;
      break;
    }
    const uint64_t next =
        ReadKirikiriSharedU64(&g_header->lookup_input_count) + 1;
    fushi_voice_hook::LookupInputSlot* slot = &inputs[(next - 1) % slots];
    // anchor 只有这一侧知道（它在帧元数据里），故减法在 DLL 做；TJS 报的是视口坐标。
    slot->x = static_cast<int32_t>((packed >> 20) & 0xFFFF) - 32768 -
              g_lookup_frame_anchor_x;
    slot->y = static_cast<int32_t>((packed >> 36) & 0xFFFF) - 32768 -
              g_lookup_frame_anchor_y;
    slot->kind = static_cast<uint32_t>(packed & 0xF);
    slot->wheel = static_cast<int32_t>((packed >> 8) & 0xFFF) - 2048;
    slot->keys = static_cast<uint32_t>((packed >> 4) & 0xF);
    slot->reserved = 0;
    WriteKirikiriSharedU64(&slot->seq, next);
    WriteKirikiriSharedU64(&g_header->lookup_input_count, next);
  }
}

// 游戏主线程的每帧入口。开关关着、查词区不存在、传感器还没建立时，这里一个字节都不写。
void PumpKirikiriLookup() {
  if (g_stop || !fushi_voice_hook::HasLookupRegion(g_header)) return;
  // 必须位于所有 early-return 之前：suppress 可能生效后紧接着被禁用、传感器退避或故障，
  // 这些状态都不能吞掉“下一次 continuous callback 已到达”这一事实。
  CommitKirikiriLookupCaptureSuppressAck();
  const bool enabled_now = LookupEnabledNow() != 0;
  if (!enabled_now) {
    // 禁用边沿强制对齐一次 TJS/C++ 可见状态；禁用稳态不再每帧执行一段 TJS。
    if (g_lookup_enabled_last || g_lookup_card_shown) HideKirikiriLookupCard();
    g_lookup_enabled_last = false;
    return;
  }
  g_lookup_enabled_last = true;
  if (!g_lookup_variant_ready) {
    if (!ProbeTjsVariantLayout()) return;
    g_lookup_variant_ready = true;
    SetLookupDiag(fushi_voice_hook::kLookupDiagExpressionReady);
  }
  if (!g_lookup_sensor_live) {
    // TJS bootstrap 由 System.addContinuousHandler 驱动，可能比这里晚若干帧；在它建立
    // 之前每帧求值都会走一次 TJS 异常，故退避到每 30 帧探一次。
    if (++g_lookup_sensor_idle_ticks < 30) {
      PresentKirikiriLookupFrame();
      return;
    }
    g_lookup_sensor_idle_ticks = 0;
  }
  int64_t notify = 0;
  // 稳态下每帧只有这一次求值：notify 不变就一行 TJS 都不再跑。
  if (g_lookup_sensor_eval_backoff > 0) {
    --g_lookup_sensor_eval_backoff;
    PresentKirikiriLookupFrame();
    return;
  }
  if (!EvaluateTjsInteger(L"global.fushiLookupNotify", &notify)) {
    if (++g_lookup_sensor_eval_failures >= kKirikiriLookupHitRetryLimit) {
      g_lookup_sensor_eval_failures = 0;
      g_lookup_sensor_eval_backoff = 30;
      SetLookupDiag(fushi_voice_hook::kLookupDiagSensorFault);
    }
    PresentKirikiriLookupFrame();
    return;
  }
  g_lookup_sensor_eval_failures = 0;
  if (!g_lookup_sensor_live) {
    g_lookup_sensor_live = true;
    SetLookupDiag(fushi_voice_hook::kLookupDiagSensorInstalled);
  }
  // 采集面自证。**不能**挂在 notify 变化上：notify 只有用户真悬停到字上才动，而这两位
  // 恰恰是用来诊断「一个字都没采到」的——那种情况下 notify 永远不动，挂上去就等于永远读
  // 不到。改为低频轮询（约每 60 帧一次），读到 2（真捕到字形）就彻底停。
  if (!g_lookup_classic_source_known && ++g_lookup_classic_poll_ticks >= 60) {
    g_lookup_classic_poll_ticks = 0;
    int64_t classic = 0;
    if (EvaluateTjsInteger(L"global.fushiLookupClassicSource", &classic)) {
      if ((classic & 1) != 0) {
        SetLookupDiag(fushi_voice_hook::kLookupDiagClassicTextSource);
      }
      if ((classic & 2) != 0) {
        SetLookupDiag(fushi_voice_hook::kLookupDiagClassicGeometry);
        g_lookup_classic_source_known = true;
      }
      if ((classic & 4) != 0) {
        SetLookupDiag(fushi_voice_hook::kLookupDiagClassicProcessCh);
      }
    }
  }
  const bool new_notification = notify != g_lookup_last_notify;
  if (new_notification) {
    // notify 只是唤醒提示，不是“submit 已完成”的事务游标。耐久 Submit* 快照独立重试，
    // 因此这里必须立即确认，否则一次字段求值失败会让整批诊断每个游戏帧重跑。
    g_lookup_last_notify = notify;
    g_lookup_hit_pending = true;
    g_lookup_dismiss_fence_pending = true;
    // 搭 notify 这趟车回读故障计数：稳态下不额外求值，而故障发生时 TJS 侧会主动
    // ++notify 把车叫来（见 fushiLookupFault）。只置位、不复位——"这一局里传感器
    // 曾经吞过异常"是一条不该被后续正常帧抹掉的事实。
    int64_t faults = 0;
    if (EvaluateTjsInteger(L"global.fushiLookupFaults", &faults) && faults > 0) {
      SetLookupDiag(fushi_voice_hook::kLookupDiagSensorFault);
    }
    // 采集与命中必须分开置位：合在一起时真机上分不出「文字没采到」和「采到了但点
    // 不中」，而两者修法完全不同。
    int64_t geometry = 0;
    if (EvaluateTjsInteger(L"global.fushiLookupGeometry", &geometry) &&
        geometry > 0) {
      SetLookupDiag(fushi_voice_hook::kLookupDiagGeometryObserved);
    }
    // hover 未命中的分型位。TJS 侧用小整数位（1/2/4/8/16）攒着，只在新增一位时才
    // ++notify 把车叫来，所以这里的求值频率与"出现了新的失败类型"同阶，不与鼠标动。
    // 把 TJS 侧新攒下的异常原文搬进日志。只在 seq 变化时读字符串，稳态零额外开销。
    static int64_t last_error_seq = 0;
    int64_t error_seq = 0;
    if (EvaluateTjsInteger(L"global.fushiLookupErrorSeq", &error_seq) &&
        error_seq != last_error_seq) {
      last_error_seq = error_seq;
      static wchar_t error_text[kKirikiriLookupLineChars];
      if (EvaluateTjsString(L"global.fushiLookupLastError", error_text,
                            kKirikiriLookupLineChars)) {
        HookLogLine(error_text);
      }
    }
    // 一次人工 submit 的脱敏坐标快照。与异常 seq 分道，避免诊断覆盖同一帧真正的 TJS
    // 错误；TJS 侧预算最多四次，因此这里的字符串求值也是严格有界的。
    static int64_t last_coord_trace_seq = 0;
    int64_t coord_trace_seq = 0;
    if (EvaluateTjsInteger(L"global.fushiLookupCoordTraceSeq", &coord_trace_seq) &&
        coord_trace_seq != last_coord_trace_seq) {
      last_coord_trace_seq = coord_trace_seq;
      static wchar_t coord_trace[4096];
      if (EvaluateTjsString(L"global.fushiLookupCoordTrace", coord_trace,
                            sizeof(coord_trace) / sizeof(coord_trace[0]))) {
        HookLogLine(coord_trace);
      }
    }
    int64_t miss = 0;
    if (EvaluateTjsInteger(L"global.fushiLookupMiss", &miss) && miss > 0) {
      uint32_t bits = 0;
      if (miss & 1) bits |= fushi_voice_hook::kLookupDiagHoverBoxMiss;
      if (miss & 2) bits |= fushi_voice_hook::kLookupDiagHoverGlyphMiss;
      if (miss & 4) bits |= fushi_voice_hook::kLookupDiagHoverHidden;
      if (miss & 8) bits |= fushi_voice_hook::kLookupDiagOriginPerChar;
      if (miss & 16) bits |= fushi_voice_hook::kLookupDiagLayerDetached;
      if (miss & 32) bits |= fushi_voice_hook::kLookupDiagCardPlainFallback;
      SetLookupDiag(bits);
    }
    DrainKirikiriLookupInput();
  }
  // 先同步 game-side Esc fence，再扫描 host 帧；否则同一帧里旧结构结果可能抢在取消前
  // 被画出来。失败时保持 pending 并有界退避，不让诊断/hover notify 清掉失败状态。
  ObserveKirikiriLookupDismissFence();
  if (g_lookup_hit_pending) {
    g_lookup_hit_pending = !PublishKirikiriLookupHit(new_notification);
  }
  if (!new_notification && g_lookup_input_pending) {
    DrainKirikiriLookupInput();
  }
  // host 投来的 BGRA 卡片帧在这里落进游戏图层。查词、排版与 popup 像素由 Fushi
  // 的既有离屏 WebView 负责。与 notify 无关：帧是 host 主动推的，
  // 注入侧每帧都要看一眼，否则卡片要等下一次命中才出现。
  PresentKirikiriLookupFrame();
}

class KiriKiriLookupPumpCallback final : public TvpContinuousEventCallback {
 public:
  void __cdecl OnContinuousCallback(uint64_t) override {
    try {
      PumpKirikiriLookup();
    } catch (...) {
      // 插件 ABI 边界绝不把 C++/TJS 异常抛回游戏事件循环。
    }
  }
};

KiriKiriLookupPumpCallback g_lookup_pump_callback;

// 备路 PNG 路径。反斜杠一律换成正斜杠：KiriKiri 的 storage 名接受 '/'，脚本里因此不存在
// 任何需要转义的字符，prototype 那套 TJS 字符串转义 helper 整条删除。
bool PrepareKirikiriLookupCardPath() {
  wchar_t temp[MAX_PATH] = {};
  const DWORD length = GetTempPathW(MAX_PATH, temp);
  if (length == 0 || length >= MAX_PATH) return false;
  std::wstring path = temp;
  path += L"fushi-kirikiri-card-";
  path += std::to_wstring(GetCurrentProcessId());
  path += L".png";
  for (wchar_t& ch : path) {
    if (ch == L'\\') ch = L'/';
  }
  // 反常路径（残留引号/反斜杠/换行）宁可放弃备路，也不把可疑内容塞进脚本。
  if (path.find_first_of(L"\"\\\r\n") != std::wstring::npos) return false;
  g_lookup_card_path = path;
  return true;
}

void ReplaceLookupPlaceholder(std::wstring& script, const wchar_t* placeholder,
                              const std::wstring& value) {
  const size_t pos = script.find(placeholder);
  if (pos == std::wstring::npos) return;
  script.replace(pos, wcslen(placeholder), value);
}

std::wstring BuildKirikiriLookupBootstrapScript() {
  std::wstring script = kKirikiriLookupBootstrapScript;
  ReplaceLookupPlaceholder(script, L"__FUSHI_PROBE_MODE__",
                           kKirikiriLookupProbePaths ? L"1" : L"0");
  ReplaceLookupPlaceholder(script, L"__FUSHI_CARD_PATH__", g_lookup_card_path);
  return script;
}

class KiriKiriLookupBootstrapCallback final : public TvpContinuousEventCallback {
 public:
  void __cdecl OnContinuousCallback(uint64_t) override {
    if (InterlockedCompareExchange(&g_lookup_bootstrap_state, 2, 1) != 1) return;

    // 官方实现允许 continuous callback 在遍历时移除自身；先移除再执行，确保任何异常也不会
    // 形成每帧重试。TJS 内部另用 System.addContinuousHandler 等待 global.kag 这个真实生命
    // 周期条件。
    if (g_lookup_remove_continuous != nullptr) g_lookup_remove_continuous(this);

    TjsVariantString* script = g_lookup_bootstrap_script;
    g_lookup_bootstrap_script = nullptr;
    if (script != nullptr && g_lookup_execute_script != nullptr) {
      const TjsString content = {script};
      try {
        g_lookup_execute_script(content, nullptr);
      } catch (...) {
        // 插件 ABI 边界绝不把 TJS/C++ 异常抛回游戏事件循环；脚本自身也有 TJS try/catch。
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

// 引擎主线程 = 拥有游戏顶层窗口的线程。只解析一次并缓存。
//
// 为什么需要它：安装路径要调 TJSAllocVariantString（从 TJS 全局变体字符串池分配）和
// TVPAddContinuousEventHook（写引擎每帧遍历的回调容器）。这两样在 KiriKiri 里都只归
// 主线程，没有任何内部同步。窗口还没建出来时返回 0，安装据此**失败关闭**——宁可晚装，
// 也不在引擎自身还没把窗口/绘制设备立起来时去动它 (BUG-1724)。
DWORD ResolveKirikiriEngineMainThreadId() {
  const LONG cached = InterlockedCompareExchange(&g_lookup_engine_main_tid, 0, 0);
  if (cached != 0) return static_cast<DWORD>(cached);

  struct Finder {
    DWORD pid;
    DWORD tid;
  } finder = {GetCurrentProcessId(), 0};
  EnumWindows(
      [](HWND window, LPARAM param) -> BOOL {
        Finder* self = reinterpret_cast<Finder*>(param);
        DWORD pid = 0;
        const DWORD tid = GetWindowThreadProcessId(window, &pid);
        if (pid != self->pid) return TRUE;
        if (GetWindow(window, GW_OWNER) != nullptr) return TRUE;  // 顶层窗口才算
        if (!IsWindowVisible(window)) return TRUE;
        self->tid = tid;
        return FALSE;
      },
      reinterpret_cast<LPARAM>(&finder));
  if (finder.tid == 0) return 0;
  InterlockedCompareExchange(&g_lookup_engine_main_tid,
                             static_cast<LONG>(finder.tid), 0);
  return static_cast<DWORD>(
      InterlockedCompareExchange(&g_lookup_engine_main_tid, 0, 0));
}

// HookWorker 侧的**意图登记**。这里一个引擎 API 都不能调。
//
// 原来这个函数直接在 HookWorker 上跑完整个安装（查导出表 → TJSAllocVariantString →
// TVPAddContinuousEventHook）。KiriKiri 的 TJS 堆和连续事件回调容器都是主线程独占、
// 无同步的，主线程每帧都在遍历/分配，于是 worker 的写入与之并发——真机表现为随机
// 时刻在引擎内部（实测落点 tTVPBasicDrawDevice）虚调用一个读成 NULL 的成员指针，
// 游戏弹 KiriKiri 的 "Fatal Error / Access Violation" (BUG-1724)。
// 真正的安装改由 RunKirikiriLookupInstallOnMainThread 在主线程接缝上执行。
void PollKirikiriLookupInstall() {
  if (g_stop || g_lookup_exporter == nullptr) return;
  if (!fushi_voice_hook::HasLookupRegion(g_header)) return;
  if (LookupEnabledNow() == 0) return;
  if (InterlockedCompareExchange(&g_lookup_bootstrap_state, 0, 0) != 0) return;
  InterlockedExchange(&g_lookup_install_requested, 1);
}

// 主线程接缝上的真正安装。调用点必须是引擎自己在主线程上调进来的 detour
// （TVPCreateIStream / TVPCreateStream / V2Link），并在这里再次核对线程身份：
// KiriKiri 也会在后台线程上开流（声音流式读取），只靠"在 detour 里"并不足以断定主线程。
void RunKirikiriLookupInstallOnMainThread() {
  if (g_stop || g_lookup_exporter == nullptr) return;
  if (InterlockedCompareExchange(&g_lookup_install_requested, 0, 0) == 0) return;
  if (!fushi_voice_hook::HasLookupRegion(g_header)) return;
  if (LookupEnabledNow() == 0) return;
  if (InterlockedCompareExchange(&g_lookup_bootstrap_state, 0, 0) != 0) return;

  const DWORD main_tid = ResolveKirikiriEngineMainThreadId();
  if (main_tid == 0 || GetCurrentThreadId() != main_tid) return;

  const char* names[] = {
      "tTJSVariantString * ::TJSAllocVariantString(const tjs_char *)",
      "void tTJSVariantString::Release()",
      "void ::TVPExecuteScript(const ttstr &,tTJSVariant *)",
      "void ::TVPAddContinuousEventHook(tTVPContinuousEventCallbackIntf *)",
      "void ::TVPRemoveContinuousEventHook(tTVPContinuousEventCallbackIntf *)",
  };
  void* functions[5] = {};
  if (!QueryKirikiriNativeLookupFunctions(g_lookup_exporter, names, functions, 5)) {
    return;
  }
  // 单独查：缺 TVPExecuteExpression 就读不回任何传感器读数（hit 与 input 都靠它），此时
  // 装一半比不装更糟——卡片会挂在屏幕上却永远收不到内容。
  const char* expression_name =
      "void ::TVPExecuteExpression(const ttstr &,tTJSVariant *)";
  void* expression = nullptr;
  if (!QueryKirikiriNativeLookupFunctions(g_lookup_exporter, &expression_name,
                                          &expression, 1) ||
      expression == nullptr) {
    return;
  }

  g_lookup_alloc_string =
      reinterpret_cast<TJSAllocVariantStringStub_t>(functions[0]);
  g_lookup_release_string =
      reinterpret_cast<TJSVariantStringReleaseStub_t>(functions[1]);
  g_lookup_execute_script = reinterpret_cast<TVPExecuteScriptStub_t>(functions[2]);
  g_lookup_add_continuous =
      reinterpret_cast<TVPAddContinuousEventHookStub_t>(functions[3]);
  g_lookup_remove_continuous =
      reinterpret_cast<TVPRemoveContinuousEventHookStub_t>(functions[4]);
  g_lookup_execute_expression =
      reinterpret_cast<TVPExecuteExpressionStub_t>(expression);
  if (g_lookup_alloc_string == nullptr || g_lookup_release_string == nullptr ||
      g_lookup_execute_script == nullptr || g_lookup_add_continuous == nullptr ||
      g_lookup_remove_continuous == nullptr) {
    return;
  }

  try {
    PrepareKirikiriLookupCardPath();  // 备路缺失不阻断主路
    const std::wstring bootstrap = BuildKirikiriLookupBootstrapScript();
    g_lookup_bootstrap_script = g_lookup_alloc_string(bootstrap.c_str());
    if (g_lookup_bootstrap_script == nullptr) return;
    InterlockedExchange(&g_lookup_bootstrap_state, 1);
    g_lookup_add_continuous(&g_lookup_pump_callback);
    g_lookup_add_continuous(&g_lookup_bootstrap_callback);
  } catch (...) {
    TjsVariantString* script = g_lookup_bootstrap_script;
    g_lookup_bootstrap_script = nullptr;
    InterlockedExchange(&g_lookup_bootstrap_state, 0);
    if (script != nullptr) g_lookup_release_string(script);
  }
}

// 拿到 exporter 的两条路径（exe 直取 / 插件 V2Link）共用的入口：先记住 exporter，再按
// 当前开关状态决定装不装。
void InstallKirikiriLookupSensor(ITVPFunctionExporter* exporter) {
  if (exporter != nullptr) {
    g_lookup_exporter = exporter;
    // 拿到 TJS exporter 就等于这局有脚本宿主，卡片走引擎自己的 Layer——它能跟着游戏
    // 渲染树一起做全屏/窗口变换，通用分层窗口做不到。**认领必须在这里、不是等 bootstrap
    // 成功之后**：bootstrap 要等引擎主线程回调才跑，而通用呈现器只看 lookup_enabled，
    // 晚认领就会在这段空窗期抢跑，出双份卡片。
    ClaimLookupPresenter();
  }
  PollKirikiriLookupInstall();
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
  // 引擎在主线程上开流 = 一个现成的主线程接缝。安装本身还会自查线程身份，
  // 因为 KiriKiri 也会在后台线程开流 (BUG-1724)。
  RunKirikiriLookupInstallOnMainThread();
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
  RunKirikiriLookupInstallOnMainThread();  // 同上：主线程接缝 (BUG-1724)
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
  // V2Link 由引擎在主线程的 Plugins.link 栈上调进来，所以这里也是合法的安装接缝。
  InstallKirikiriLookupSensor(exporter);
  RunKirikiriLookupInstallOnMainThread();
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
      // 未加壳游戏在这条路径上就能拿到 exporter，不必等插件 V2Link。同样幂等。
      InstallKirikiriLookupSensor(exp);
    }
  }

  return ll_installed;
}

#else  // !_M_IX86

// KiriKiriZ 是 32 位引擎；x64 构建此路径为空实现（仅保证两架构都能编译）。
bool TryHookKirikiriVoiceStream() { return true; }
void PollKirikiriLookupInstall() {}

#endif  // _M_IX86
