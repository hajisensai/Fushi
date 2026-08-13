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

// TextRender 之外的捕获路径（Layer.drawText / MessageLayer.processCh）只在换游戏、
// TextRender 一条都不命中时才有诊断价值。运行日志已证伪它们在本样本上的作用，故默认
// **编译期关闭**：游戏内渲染意味着主线程上的每一毫秒都直接变掉帧，不能为了"万一有用"
// 在生产路径上并行跑四份没人读的排版计算。
constexpr bool kKirikiriLookupProbePaths = false;

// TJS 传感器。职责边界只有四件事：采字符几何、做命中测试、把 host 给的位图端到游戏渲染树
// 里、把落在卡片上的输入转发出去。分词、查词、卡片排版、外字、发音、制卡全部在 Hibiki
// 进程；这里没有网络客户端、没有认证凭据、没有 JSON、也不 eval 任何拼出来的源码。
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
	// 卡片层就是卡片本身：按 host 给的 cardW×cardH 建、摆在 anchor 上，**不覆盖全屏**，而且
	// 延迟到真要显示第一帧时才建。命中判定用引擎天然的矩形命中（htRect），不依赖"alpha 为 0
	// 的像素会把点击透传下去"这条未在本引擎验证过的行为。这条选择是为了把失败面关死：全视口
	// 层一旦穿透语义不符预期，用户没查词时整个游戏就点不动了——那是把"查词不好使"放大成
	// "游戏坏了"。现在最坏情况也只是卡片自己那块矩形吃掉点击，而那块本来就该吃掉。
	// 事件坐标是层内坐标；入队时加回层位置换成视口坐标，减 anchor 由 DLL 做（帧元数据在它手上）。
	function onMouseDown(x, y, button)
	{
		if(button == mbLeft) global.fushiLookupQueueInput(1, x, y, 0);
	}
	function onMouseUp(x, y, button)
	{
		if(button == mbLeft) global.fushiLookupQueueInput(2, x, y, 0);
	}
	function onMouseMove(x, y)
	{
		global.fushiLookupQueueInput(0, x, y, 0);
	}
	function onMouseWheel(shift, delta, x, y)
	{
		global.fushiLookupQueueInput(3, x, y, delta);
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
		if(typeof global.kag == "undefined" || global.kag === null) return;
		try
		{
			// 这一批必须最先建立：DLL 每帧都会求值 fushiLookupNotify，晚一步就是每帧一次
			// TJS 异常。
			global.fushiLookupNotify = 0;
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
			global.fushiLookupInputQueue = [];
			global.fushiLookupShiftDown = false;
			global.fushiLookupProbeMode = __FUSHI_PROBE_MODE__;
			global.fushiLookupProbeDrawText = 0;
			global.fushiLookupProbeProcessCh = 0;
			global.fushiLookupProbeError = "";
			global.fushiLookupCardPath = "__FUSHI_CARD_PATH__";
			global.fushiLookupCardSeq = 0;
			global.fushiLookupRegistry = [];
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
			global.fushiLookupBoundRenderer = void;
			global.fushiLookupBoundLayer = void;
			global.fushiLookupBoundX = 0;
			global.fushiLookupBoundY = 0;

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

			// 上限 8 + 淘汰最久未用。TJS 没有弱引用，registry 只增不减就等于把每个用过的
			// renderer 连同它的整行几何永久钉在游戏进程里（prototype 的真实泄漏源）。
			global.fushiLookupEntryFor = function(renderer)
			{
				var registry = global.fushiLookupRegistry;
				var oldest = 0;
				for(var i = 0; i < registry.count; i++)
				{
					if(registry[i].renderer === renderer) return registry[i];
					if(registry[i].used < registry[oldest].used) oldest = i;
				}
				if(registry.count < 8)
				{
					var fresh = %[renderer:renderer, glyphs:[], line:"", used:0,
						minX:0, minY:0, maxX:0, maxY:0, layer:void, originX:0, originY:0];
					registry.add(fresh);
					return fresh;
				}
				var reused = registry[oldest];
				reused.renderer = renderer;
				reused.glyphs = [];
				reused.line = "";
				reused.used = 0;
				reused.layer = void;
				reused.originX = 0;
				reused.originY = 0;
				return reused;
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

			// 高亮层同样延迟到第一次真要高亮时才建。它是全视口的，但 hitThreshold=256 是
			// 引擎里"永不命中"这个明确取值——与卡片依赖的 alpha 穿透不是一回事，不会把
			// 输入吃掉。
			global.fushiLookupEnsureHighlight = function()
			{
				var primary = global.kag.primaryLayer;
				var layer = global.fushiLookupHighlightLayer;
				if(layer === void || !isvalid layer)
				{
					layer = new Layer(global.kag, primary.parent);
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
				if(global.fushiLookupHoverKey == "") return;
				global.fushiLookupHoverKey = "";
				global.fushiLookupHitEntry = void;
				var layer = global.fushiLookupHighlightLayer;
				var previous = global.fushiLookupHighlightRect;
				if(layer !== void && isvalid layer && previous !== void)
				{
					layer.fillRect(previous.x, previous.y, previous.w, previous.h, 0);
					layer.visible = false;
					layer.update();
				}
				global.fushiLookupHighlightRect = void;
			};

			// 收起 = 层不可见。不可见层在引擎里既不绘制也不参与命中，这是引擎最基本的语义，
			// 不像 alpha 穿透那样需要额外验证。层留着复用（下一次查词多半尺寸相近），只是
			// 绝不会停在"可见且可命中"的状态上。
			global.fushiLookupDismiss = function()
			{
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
						card = new FushiLookupCardLayer(global.kag,
							global.kag.primaryLayer.parent);
						global.kag.add(card);
						card.name = "Hibiki in-game lookup card";
						card.fushiLookupIgnore = true;
						card.type = ltAlpha;
						card.absolute = 2147483000;
						card.opacity = 255;
						card.hitType = htRect;
						card.visible = false;
						global.fushiLookupCard = card;
					}
					if(card.imageWidth != cardW || card.imageHeight != cardH)
					{
						card.setImageSize(cardW, cardH);
						card.setSizeToImageSize();
					}
					card.setPos(anchorX, anchorY);
				}
				catch(e) {}
			};

)TJS" LR"TJS(

			// DLL 写完像素之后调。seq==0 或空尺寸 = 收起卡片（host 关开关 / 投空帧）。
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
					global.fushiLookupCardSeq = seq;
					card.visible = true;
					card.update();
					var entry = global.fushiLookupHitEntry;
					// 卡片归属在这一刻定下（BUG-1606）：之后只有**这条**台词重绘才收卡。
					global.fushiLookupCardEntry = entry;
					if(entry !== void && highlightLen > 0)
						global.fushiLookupPaintHighlight(entry, global.fushiLookupHitOffsetX,
							global.fushiLookupHitOffsetY, highlightStart, highlightLen);
				}
				catch(e) {}
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
				catch(e) {}
				global.fushiLookupApply(seq, highlightStart, highlightLen, anchorX, anchorY,
					cardW, cardH);
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
			global.fushiLookupCapture = function(renderer)
			{
				try
				{
					if(typeof renderer.getCharacters != "Object") return;
					var characters = (renderer.getCharacters incontextof renderer)(0, 0);
					if(characters === void || typeof characters.count == "undefined") return;
					var glyphs = [], line = "";
					var minX = 0, minY = 0, maxX = 0, maxY = 0;
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
						}
						else
						{
							if(x < minX) minX = x;
							if(y < minY) minY = y;
							if(x + w > maxX) maxX = x + w;
							if(y + h > maxY) maxY = y + h;
						}
						glyphs.add(%[ch:text, x:x, y:y, w:w, h:h]);
						line += text;
					}
					if(glyphs.count == 0) return;
					var entry = global.fushiLookupEntryFor(renderer);
					var changed = entry.line != line;
					entry.glyphs = glyphs;
					entry.line = line;
					entry.minX = minX;
					entry.minY = minY;
					entry.maxX = maxX;
					entry.maxY = maxY;
					entry.used = ++global.fushiLookupClock;
					// 台词真的换了才收卡片：同一行重复 render（打字机动画）不该把用户正在读的
					// 卡片一帧一帧地打掉。
					//
					// BUG-1606：判据必须落在**这张卡自己依附的那条台词**（fushiLookupCardEntry
					// 是卡片真正显示那一刻记下的 entry）上。旧判据是「任意 renderer 上的行文本变
					// 了」，于是同一句里说话人切换（多角色同时说话时名字层 / 第二消息层逐字重绘）
					// 每多一个字就把用户正在读的卡片打掉一次，鼠标一动又被 hover 拉回来——表现
					// 就是卡片反复闪没。名字层、选项层、历史层与这张卡无关，它们的重绘不该收卡。
					//
					// 收窄不会漏收：真的换台词时 host 侧「会话最新行变了」会走
					// GalIngameLookupController.onLineChanged() → dismiss，那条判据看的是文本
					// hook 的行流，与这里是哪个 renderer 无关。
					//
					// 卡片与悬停高亮的归属是两件事：高亮跟着最后一次命中的 entry
					// （fushiLookupHitEntry）走，它的字形几何一旦重排就必须清，但那不该顺手把
					// 另一条台词上的卡片一起收掉。
					if(changed)
					{
						if(global.fushiLookupCardEntry === entry)
							global.fushiLookupDismiss();
						else if(global.fushiLookupHitEntry === entry)
							global.fushiLookupClearHover();
					}
				}
				catch(e) {}
			};

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
					global.fushiLookupClassicSource = 1;
				}
				catch(e) {}
			};

			// drawCh 是逐字符调用，先用一组"上次绑定"快照挡住重复调用，别让每个字都去扫 registry。
			global.fushiLookupBindOrigin = function(renderer, layer, originX, originY)
			{
				if(global.fushiLookupBoundRenderer === renderer &&
					global.fushiLookupBoundLayer === layer &&
					global.fushiLookupBoundX == originX &&
					global.fushiLookupBoundY == originY) return;
				if(layer === void || layer === null || !isvalid layer) return;
				if(typeof originX != "Integer" && typeof originX != "Real") return;
				if(typeof originY != "Integer" && typeof originY != "Real") return;
				var entry = global.fushiLookupEntryFor(renderer);
				entry.layer = layer;
				entry.originX = originX;
				entry.originY = originY;
				global.fushiLookupBoundRenderer = renderer;
				global.fushiLookupBoundLayer = layer;
				global.fushiLookupBoundX = originX;
				global.fushiLookupBoundY = originY;
			};

)TJS" LR"TJS(

			global.fushiLookupReport = function(entry, index, offsetX, offsetY, submit)
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
				global.fushiLookupHitCharIndex = index;
				global.fushiLookupHitCharCount = entry.glyphs.count;
				global.fushiLookupHitGlyphX = glyph.x + offsetX;
				global.fushiLookupHitGlyphY = glyph.y + offsetY;
				global.fushiLookupHitGlyphW = glyph.w;
				global.fushiLookupHitGlyphH = glyph.h;
				global.fushiLookupHitViewW = primary.imageWidth;
				global.fushiLookupHitViewH = primary.imageHeight;
				global.fushiLookupHitFlags = submit ? 1 : 0;
				// **整行**，不截断。制卡要的是完整句子，分词是 host 的事。
				global.fushiLookupHitLine = entry.line;
				global.fushiLookupHitSeq++;
				global.fushiLookupNotify++;
				global.fushiLookupPaintHighlight(entry, offsetX, offsetY, index, 1);
			};

			global.fushiLookupProbe = function(submit)
			{
				var primary = global.kag.primaryLayer;
				var px = primary.cursorX - primary.imageLeft;
				var py = primary.cursorY - primary.imageTop;
				var registry = global.fushiLookupRegistry;
				for(var i = registry.count - 1; i >= 0; i--)
				{
					var entry = registry[i];
					if(entry.glyphs.count == 0) continue;
					var layer = entry.layer;
					if(layer === void || layer === null || !isvalid layer) continue;
					var rx = layer.cursorX - layer.imageLeft - entry.originX;
					var ry = layer.cursorY - layer.imageTop - entry.originY;
					// 廉价矩形判定挡在前面：整行包围盒不含光标就整条跳过，逐字扫描只在真正
					// 落在台词上时才发生。
					if(rx < entry.minX || rx >= entry.maxX) continue;
					if(ry < entry.minY || ry >= entry.maxY) continue;
					if(!global.fushiLookupVisible(layer)) continue;
					var glyphs = entry.glyphs;
					for(var g = glyphs.count - 1; g >= 0; g--)
					{
						var glyph = glyphs[g];
						if(rx < glyph.x || rx >= glyph.x + glyph.w) continue;
						if(ry < glyph.y || ry >= glyph.y + glyph.h) continue;
						global.fushiLookupReport(entry, g, px - rx, py - ry, submit);
						return true;
					}
				}
				if(!submit) global.fushiLookupClearHover();
				return false;
			};

			// 卡片层自己（htRect）已经吃掉落在它矩形内的事件；KAG 全局钩子这一侧再判一次，
			// 免得同一次点击既推进剧情又被卡片处理。层现在就是卡片本身，所以这是一次纯矩形
			// 判定——不再需要 getMainPixel 去问 alpha。
			global.fushiLookupOverCard = function()
			{
				if(global.fushiLookupCardSeq == 0) return false;
				try
				{
					var card = global.fushiLookupCard;
					if(card === void || !isvalid card || !card.visible) return false;
					var x = card.cursorX - card.imageLeft;
					var y = card.cursorY - card.imageTop;
					return x >= 0 && y >= 0 && x < card.imageWidth && y < card.imageHeight;
				}
				catch(e) { return false; }
			};

)TJS" LR"TJS(

			global.fushiLookupLeftClickHook = function()
			{
				if(global.fushiLookupOverCard()) return true;
				return global.fushiLookupProbe(true);
			};
			global.fushiLookupMouseMoveHook = function(x, y)
			{
				if(global.fushiLookupOverCard()) return false;
				global.fushiLookupProbe(false);
				return false;
			};
			global.fushiLookupKeyDownHook = function(key, shift)
			{
				global.fushiLookupShiftDown = (key == 0x10);
				if(key == 0x1B && global.fushiLookupCardSeq != 0)
				{
					global.fushiLookupDismiss();
					return true;
				}
				if(key == 0x10) return global.fushiLookupProbe(true);
				return false;
			};

			// bootstrap 只装传感器，**一个渲染层都不建**：卡片层由 fushiLookupPrepare 在真要
			// 显示第一帧时建，高亮层由 fushiLookupEnsureHighlight 在第一次真要高亮时建。
			// 没查词的时候游戏渲染树与它注入前逐字节一致。
			global.fushiLookupCard = void;
			global.fushiLookupHighlightLayer = void;

			if(typeof global.TextRender == "Object")
			{
				if(typeof global.TextRender.render == "Object")
				{
					global.fushiLookupOriginalRender = global.TextRender.render;
					global.TextRender.render = function(a, b, c, d, e, f)
					{
						var result = (global.fushiLookupOriginalRender incontextof this)(...);
						global.fushiLookupCapture(this);
						return result;
					};
				}
				if(typeof global.TextRender.done == "Object")
				{
					global.fushiLookupOriginalDone = global.TextRender.done;
					global.TextRender.done = function()
					{
						var result = (global.fushiLookupOriginalDone incontextof this)(...);
						global.fushiLookupCapture(this);
						return result;
					};
				}
				if(typeof global.TextRender.drawCh == "Object")
				{
					global.fushiLookupOriginalDrawCh = global.TextRender.drawCh;
					global.TextRender.drawCh = function(layer, ox, oy, ch)
					{
						global.fushiLookupBindOrigin(this, layer, ox, oy);
						return (global.fushiLookupOriginalDrawCh incontextof this)(...);
					};
				}
			}
			else
			{
				// 没有 KAGEX TextRender 的经典 KAG3 游戏：逐字几何只从原生 Layer.drawText 经过。
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

			global.kag.addHook("leftClick", global.fushiLookupLeftClickHook);
			global.kag.addHook("mouseMove", global.fushiLookupMouseMoveHook);
			global.kag.addHook("keyDown", global.fushiLookupKeyDownHook);

			Debug.notice("[HibikiLookup] sensor installed");
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

std::wstring g_lookup_card_path;  // 备路 PNG，恒在 %TEMP%（游戏目录一个字节都不写）

// 卡片层就是卡片本身（cardW×cardH，摆在 anchor 上），所以目标缓冲整块都归本帧所有：
// 既不需要脏矩形，也不需要在层内做偏移——这两样都是"全视口卡片层"那版才需要的。
int32_t g_lookup_frame_anchor_x = 0;
int32_t g_lookup_frame_anchor_y = 0;
uint64_t g_lookup_presented_seq = 0;
uint64_t g_lookup_hit_seq = 0;
int64_t g_lookup_last_notify = -1;
bool g_lookup_card_shown = false;
bool g_lookup_sensor_live = false;
// 经典 KAG3 采集面已自证（置位后不再求值）。
bool g_lookup_classic_source_known = false;
bool g_lookup_input_pending = false;  // 上一帧撞到每帧搬运上限，队列里还有剩
uint32_t g_lookup_sensor_idle_ticks = 0;

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

// 回执脚本。七个实参**全部**是 std::to_wstring 出来的整数，脚本里不存在任何来自 host、
// 游戏或用户的字符串——注入面不是"escape 得更严"，而是结构上没有可注入的位置。参数个数
// 不是约束点：约束点是"不许把动态字符串拼进会被 eval 的文本"。
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
  if (!g_lookup_card_shown) return;
  g_lookup_card_shown = false;
  ApplyKirikiriLookupCard(0, 0, 0, 0, 0, 0, 0, false);
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

void PresentKirikiriLookupFrame() {
  if (g_header == nullptr) return;
  fushi_voice_hook::LookupHitSlot* hit = fushi_voice_hook::LookupHitOf(g_header);
  const uint64_t hit_seq = hit == nullptr ? 0 : ReadKirikiriSharedU64(&hit->seq);

  fushi_voice_hook::LookupFrame* best = nullptr;
  uint32_t best_index = 0;
  uint64_t best_seq = 0;
  for (uint32_t i = 0; i < g_header->lookup_frame_count; ++i) {
    fushi_voice_hook::LookupFrame* frame = fushi_voice_hook::LookupFrameAt(g_header, i);
    if (frame == nullptr || frame->ready == 0) continue;
    // 判据只有一份，在契约头（ShouldApplyLookupFrame），replay 测试跑的是同一个函数。
    // seq 是**发布序**（host 每投一帧 +1），hit_seq 才是"回应哪次查询"；两者分开之后
    // 收卡帧就是普通一帧，不会再被自己刚 present 过的那个 seq 挡在门外——那正是收卡
    // 一直不生效的根因。
    const uint64_t seq = ReadKirikiriSharedU64(&frame->seq);
    if (seq <= best_seq) continue;  // 本轮已找到更新的候选
    if (!fushi_voice_hook::ShouldApplyLookupFrame(seq, frame->hit_seq,
                                                  g_lookup_presented_seq,
                                                  hit_seq)) {
      continue;
    }
    best = frame;
    best_index = i;
    best_seq = seq;
  }
  if (best == nullptr) return;
  g_lookup_presented_seq = best_seq;

  // 收卡由 flags 自述，不靠"width==0 就是收卡"的魔法编码——后者要求每个读侧都记住这条
  // 隐规则，而它和"host 投了张废帧"在字节上完全一样。必须在 IsLookupFrameSane 之前认掉：
  // 收卡帧按定义没有像素，过不了那道校验。
  if ((best->flags & fushi_voice_hook::kLookupFrameDismiss) != 0) {
    g_lookup_card_shown = true;  // 强制发一次收起，别让"以为已经隐藏"把信号吞掉
    HideKirikiriLookupCard();
    return;
  }

  // 跨进程来的 width/height/pitch 全是不可信输入：先过契约校验，再谈拷贝。
  if (!fushi_voice_hook::IsLookupFrameSane(g_header, best) ||
      static_cast<uint32_t>(best_seq % g_header->lookup_frame_count) != best_index) {
    SetLookupDiag(fushi_voice_hook::kLookupDiagFrameRejected);
    return;
  }
  const uint8_t* pixels = fushi_voice_hook::LookupBitmapAt(g_header, best_index);
  if (pixels == nullptr) {
    SetLookupDiag(fushi_voice_hook::kLookupDiagFrameRejected);
    return;
  }

  const uint32_t highlight_start = best->highlight_start;
  const uint32_t highlight_len = best->highlight_len;
  const int32_t anchor_x = best->anchor_x;
  const int32_t anchor_y = best->anchor_y;
  const uint32_t width = best->width;
  const uint32_t height = best->height;
  const uint32_t source_pitch = best->pitch;

  // 建/调卡片层必须在取写指针**之前**：层是按本帧 cardW×cardH 建的，尺寸变化会重新分配
  // 缓冲，先取指针再改尺寸就是往已经释放的内存里写。
  PrepareKirikiriLookupCard(anchor_x, anchor_y, width, height);

  int64_t layer_w = 0;
  int64_t layer_h = 0;
  int64_t buffer = 0;
  int64_t stride64 = 0;
  // 写指针**每帧重取**：copy-on-write 与 layer 尺寸变化都会让上一帧的指针失效，缓存它就是
  // 往已经不属于该层的内存里写。pitch 必须在取写指针之后读——取写指针可能换掉整块缓冲。
  const bool geometry =
      EvaluateTjsInteger(L"global.fushiLookupCard.imageWidth", &layer_w) &&
      EvaluateTjsInteger(L"global.fushiLookupCard.imageHeight", &layer_h) &&
      EvaluateTjsInteger(L"global.fushiLookupCard.mainImageBufferForWrite", &buffer) &&
      EvaluateTjsInteger(L"global.fushiLookupCard.mainImageBufferPitch", &stride64) &&
      buffer != 0;

  if (!geometry) {
    // 备路：主路不可用时由 host 把这张 cardW×cardH 的卡片写成 PNG 落 %TEMP%，
    // TJS loadImages 进来。慢一个数量级，但零新 ABI，且同样不碰游戏目录（.sig 校验）。
    if (g_lookup_card_path.empty()) return;
    SetLookupDiag(fushi_voice_hook::kLookupDiagFallbackPngRoute);
    g_lookup_frame_anchor_x = anchor_x;
    g_lookup_frame_anchor_y = anchor_y;
    g_lookup_card_shown = true;
    ApplyKirikiriLookupCard(best_seq, highlight_start, highlight_len, anchor_x,
                            anchor_y, width, height, true);
    SetLookupDiag(fushi_voice_hook::kLookupDiagFramePresented);
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
    SetLookupDiag(fushi_voice_hook::kLookupDiagFrameRejected);
    return;
  }

  if (!BlitLookupFrameGuarded(
          reinterpret_cast<uint8_t*>(static_cast<uintptr_t>(buffer)), stride, width,
          height, source_pitch, pixels)) {
    SetLookupDiag(fushi_voice_hook::kLookupDiagFrameRejected);
    return;
  }

  // 拷完复查 seq/ready：host 若在拷贝中途改写了这一格，画面就是撕裂的半张卡，宁可不显示
  // 让下一帧重来。
  if (ReadKirikiriSharedU64(&best->seq) != best_seq || best->ready == 0) return;

  g_lookup_frame_anchor_x = anchor_x;
  g_lookup_frame_anchor_y = anchor_y;
  g_lookup_card_shown = true;
  ApplyKirikiriLookupCard(best_seq, highlight_start, highlight_len, anchor_x,
                          anchor_y, width, height, false);
  SetLookupDiag(fushi_voice_hook::kLookupDiagFramePresented);
}

void PublishKirikiriLookupHit() {
  fushi_voice_hook::LookupHitSlot* slot = fushi_voice_hook::LookupHitOf(g_header);
  if (slot == nullptr) return;
  int64_t seq = 0;
  if (!EvaluateTjsInteger(L"global.fushiLookupHitSeq", &seq)) return;
  if (seq <= 0 || static_cast<uint64_t>(seq) == g_lookup_hit_seq) return;

  int64_t char_index = 0;
  int64_t char_count = 0;
  int64_t glyph_x = 0;
  int64_t glyph_y = 0;
  int64_t glyph_w = 0;
  int64_t glyph_h = 0;
  int64_t view_w = 0;
  int64_t view_h = 0;
  int64_t flags = 0;
  if (!EvaluateTjsInteger(L"global.fushiLookupHitCharIndex", &char_index) ||
      !EvaluateTjsInteger(L"global.fushiLookupHitCharCount", &char_count) ||
      !EvaluateTjsInteger(L"global.fushiLookupHitGlyphX", &glyph_x) ||
      !EvaluateTjsInteger(L"global.fushiLookupHitGlyphY", &glyph_y) ||
      !EvaluateTjsInteger(L"global.fushiLookupHitGlyphW", &glyph_w) ||
      !EvaluateTjsInteger(L"global.fushiLookupHitGlyphH", &glyph_h) ||
      !EvaluateTjsInteger(L"global.fushiLookupHitViewW", &view_w) ||
      !EvaluateTjsInteger(L"global.fushiLookupHitViewH", &view_h) ||
      !EvaluateTjsInteger(L"global.fushiLookupHitFlags", &flags)) {
    return;
  }
  if (char_count <= 0 || char_index < 0 || char_index >= char_count) return;

  // 只在游戏主线程用；放静态区避免每次命中往栈上压 2.4KB。
  static wchar_t line[kKirikiriLookupLineChars];
  if (!EvaluateTjsString(L"global.fushiLookupHitLine", line,
                         kKirikiriLookupLineChars)) {
    return;
  }
  const uint32_t line_bytes = EncodeLookupLineUtf8(
      line, slot->line_utf8, fushi_voice_hook::kLookupLineBytes);
  if (line_bytes == 0) return;

  slot->char_index = static_cast<uint32_t>(char_index);
  slot->char_count = static_cast<uint32_t>(char_count);
  slot->glyph_x = static_cast<int32_t>(glyph_x);
  slot->glyph_y = static_cast<int32_t>(glyph_y);
  slot->glyph_w = static_cast<int32_t>(glyph_w);
  slot->glyph_h = static_cast<int32_t>(glyph_h);
  slot->view_w = static_cast<int32_t>(view_w);
  slot->view_h = static_cast<int32_t>(view_h);
  slot->flags = static_cast<uint32_t>(flags) & fushi_voice_hook::kLookupHitFlagSubmit;
  slot->line_bytes = line_bytes;
  // seq **最后**写：Interlocked 是全栅栏，保证上面的 payload 对 host 先可见。
  WriteKirikiriSharedU64(&slot->seq, static_cast<uint64_t>(seq));
  g_lookup_hit_seq = static_cast<uint64_t>(seq);
  InterlockedIncrement64(
      reinterpret_cast<volatile LONGLONG*>(&g_header->lookup_hit_count));
  SetLookupDiag(fushi_voice_hook::kLookupDiagGeometryObserved |
                fushi_voice_hook::kLookupDiagHitSubmitted);
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
  if (LookupEnabledNow() == 0) {
    HideKirikiriLookupCard();
    return;
  }
  if (!g_lookup_variant_ready) {
    if (!ProbeTjsVariantLayout()) return;
    g_lookup_variant_ready = true;
    SetLookupDiag(fushi_voice_hook::kLookupDiagExpressionReady);
  }
  if (!g_lookup_sensor_live) {
    // TJS bootstrap 由 System.addContinuousHandler 驱动，可能比这里晚若干帧；在它建立
    // 之前每帧求值都会走一次 TJS 异常，故退避到每 30 帧探一次。
    if (++g_lookup_sensor_idle_ticks < 30) return;
    g_lookup_sensor_idle_ticks = 0;
  }
  int64_t notify = 0;
  // 稳态下每帧只有这一次求值：notify 不变就一行 TJS 都不再跑。
  if (!EvaluateTjsInteger(L"global.fushiLookupNotify", &notify)) return;
  if (!g_lookup_sensor_live) {
    g_lookup_sensor_live = true;
    SetLookupDiag(fushi_voice_hook::kLookupDiagSensorInstalled);
  }
  if (notify != g_lookup_last_notify) {
    g_lookup_last_notify = notify;
    // 采集面自证：经典 KAG3 的标志要等第一次真捕获到几何才置 1，所以在这里查（notify 变
    // 化 = 用户真悬停到字上），查到就不再查。稳态下这条求值一次都不跑。
    if (!g_lookup_classic_source_known) {
      int64_t classic = 0;
      if (EvaluateTjsInteger(L"global.fushiLookupClassicSource", &classic) &&
          classic != 0) {
        g_lookup_classic_source_known = true;
        SetLookupDiag(fushi_voice_hook::kLookupDiagClassicTextSource);
      }
    }
    PublishKirikiriLookupHit();
    DrainKirikiriLookupInput();
  } else if (g_lookup_input_pending) {
    DrainKirikiriLookupInput();
  }
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

// 幂等安装。`lookup_enabled==0` 时**一个 hook 都不装**，因此这里既是首装点也是重试点：
// 用户在游戏起来之后才打开查词是常态，而 exporter 只在 V2Link / exe 直取那一瞬间到手。
void PollKirikiriLookupInstall() {
  if (g_stop || g_lookup_exporter == nullptr) return;
  if (!fushi_voice_hook::HasLookupRegion(g_header)) return;
  if (LookupEnabledNow() == 0) return;
  if (InterlockedCompareExchange(&g_lookup_bootstrap_state, 0, 0) != 0) return;

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
  if (exporter != nullptr) g_lookup_exporter = exporter;
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
  InstallKirikiriLookupSensor(exporter);
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
