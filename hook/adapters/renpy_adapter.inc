// Included inside dll_main.cpp anonymous namespace.
// ══ Ren'Py / FFmpeg 通用资源事件 + major 54 PCM 兼容层 ═══════════════════════════════
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
uint32_t g_renpy_avformat_major = 0;

constexpr int kRenpyResourceEventCount = 32;
constexpr int kRenpyPcmEventCount = 8;
constexpr int kRenpyWriteEventCount = 8;
constexpr uint32_t kRenpyPcmEventBytes = 256u * 1024u;

struct RenpyResourceEvent {
  volatile LONG state;  // 0=free, 1=producer writing, 2=worker ready
  char url[520];
};

struct RenpyPcmEvent {
  volatile LONG state;  // 0=free, 1=producer writing, 2=worker ready, 3=worker owns
  int fmt_slot;
  void* fmt_ctx;
  int sample_format;
  uint32_t frames;
  uint32_t channels;
  uint32_t bytes_per_sample;
  uint32_t plane_count;
  uint32_t plane_offsets[8];
  uint32_t plane_lengths[8];
  uint8_t payload[kRenpyPcmEventBytes];
};

struct RenpyWriteEvent {
  volatile LONG state;
  uint8_t* pcm;
  uint32_t length;
  uint32_t sample_rate;
  uint32_t channels;
  wchar_t basename[128];
};

RenpyResourceEvent g_renpy_resource_events[kRenpyResourceEventCount] = {};
RenpyPcmEvent g_renpy_pcm_events[kRenpyPcmEventCount] = {};
RenpyWriteEvent g_renpy_write_events[kRenpyWriteEventCount] = {};
volatile LONG g_renpy_worker_stop = 0;
HANDLE g_renpy_worker = nullptr;
char g_renpy_last_resource[520] = {0};
uint64_t g_renpy_last_resource_tick = 0;
volatile LONG g_renpy_resource_counter = 0;

HMODULE FindLoadedFfmpegModule(hibiki_voice_hook::FfmpegModuleKind kind,
                               uint32_t* major);

bool SampleFormatLayout(int format, uint32_t* bytes_per_sample,
                        bool* planar) {
  switch (format) {
    case 0: *bytes_per_sample = 1; *planar = false; return true;
    case 1: *bytes_per_sample = 2; *planar = false; return true;
    case 2: *bytes_per_sample = 4; *planar = false; return true;
    case 3: *bytes_per_sample = 4; *planar = false; return true;
    case 4: *bytes_per_sample = 8; *planar = false; return true;
    case 5: *bytes_per_sample = 1; *planar = true; return true;
    case 6: *bytes_per_sample = 2; *planar = true; return true;
    case 7: *bytes_per_sample = 4; *planar = true; return true;
    case 8: *bytes_per_sample = 4; *planar = true; return true;
    case 9: *bytes_per_sample = 8; *planar = true; return true;
    default: return false;
  }
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

bool EnqueueRenpyResource(const char* url) {
  if (!IsVoiceUrl(url)) return false;
  for (int i = 0; i < kRenpyResourceEventCount; ++i) {
    RenpyResourceEvent* event = &g_renpy_resource_events[i];
    if (InterlockedCompareExchange(&event->state, 1, 0) != 0) continue;
    size_t length = 0;
    while (url[length] != 0 && length + 1 < sizeof(event->url)) ++length;
    memcpy(event->url, url, length);
    event->url[length] = 0;
    MemoryBarrier();
    InterlockedExchange(&event->state, 2);
    return true;
  }
  return false;
}

void CopyRenpyResource(const char* url) {
  if (url == nullptr || url[0] == 0 || strstr(url, "://") != nullptr) return;
  const uint64_t now = GetTickCount64();
  if (strcmp(url, g_renpy_last_resource) == 0 &&
      now - g_renpy_last_resource_tick < 500) {
    return;
  }
  wchar_t wide[520] = {0};
  int count = MultiByteToWideChar(CP_UTF8, 0, url, -1, wide, 520);
  if (count <= 0) count = MultiByteToWideChar(CP_ACP, 0, url, -1, wide, 520);
  if (count <= 0) return;
  if (wide[0] == L'\\' && wide[1] == L'\\') return;  // 不让 worker 阻塞在 UNC/设备路径。
  wchar_t full[32768] = {0};
  if (GetFullPathNameW(wide, 32768, full, nullptr) == 0) return;
  HANDLE source = CreateFileW(full, GENERIC_READ,
                              FILE_SHARE_READ | FILE_SHARE_WRITE |
                                  FILE_SHARE_DELETE,
                              nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                              nullptr);
  if (source == INVALID_HANDLE_VALUE) return;
  LARGE_INTEGER size = {0};
  if (!GetFileSizeEx(source, &size) || size.QuadPart <= 0 ||
      size.QuadPart > 32ll * 1024ll * 1024ll) {
    CloseHandle(source);
    return;
  }
  uint8_t header[64] = {0};
  DWORD header_read = 0;
  if (!ReadFile(source, header, sizeof(header), &header_read, nullptr)) {
    CloseHandle(source);
    return;
  }
  const auto format =
      hibiki_voice_hook::DetectAudioResourceFormat(header, header_read);
  if (format == hibiki_voice_hook::AudioResourceFormat::kUnknown) {
    CloseHandle(source);
    return;
  }
  SetFilePointer(source, 0, nullptr, FILE_BEGIN);
  wchar_t temp[MAX_PATH] = {0};
  const DWORD temp_length = GetTempPathW(MAX_PATH, temp);
  if (temp_length == 0 || temp_length > MAX_PATH) {
    CloseHandle(source);
    return;
  }
  std::wstring directory = std::wstring(temp) + L"hibiki_gal_voice";
  CreateDirectoryW(directory.c_str(), nullptr);
  wchar_t base[128] = {0};
  MakeRenpyBaseName(url, nullptr, base, 128);
  wchar_t* dot = wcsrchr(base, L'.');
  if (dot != nullptr) *dot = 0;
  const std::wstring destination =
      directory + L"\\" + std::to_wstring(GetTickCount64()) + L"_" +
      std::to_wstring(InterlockedIncrement(&g_renpy_resource_counter)) + L"_" + base +
      hibiki_voice_hook::AudioResourceExtension(format);
  HANDLE output = CreateFileW(destination.c_str(), GENERIC_WRITE, 0, nullptr,
                              CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (output == INVALID_HANDLE_VALUE) {
    CloseHandle(source);
    return;
  }
  uint8_t buffer[64 * 1024];
  bool ok = true;
  while (ok) {
    DWORD read = 0;
    if (!ReadFile(source, buffer, sizeof(buffer), &read, nullptr)) {
      ok = false;
      break;
    }
    if (read == 0) break;
    DWORD written = 0;
    ok = WriteFile(output, buffer, read, &written, nullptr) && written == read;
  }
  CloseHandle(output);
  CloseHandle(source);
  if (!ok) {
    DeleteFileW(destination.c_str());
  } else if (g_header != nullptr) {
    lstrcpynA(g_renpy_last_resource, url,
              static_cast<int>(sizeof(g_renpy_last_resource)));
    g_renpy_last_resource_tick = now;
    g_header->hook_diagnostics |=
        hibiki_voice_hook::kDiagFfmpegResourceCaptured;
  }
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

// worker 侧把回调已复制到固定事件槽的采样转成 16-bit 交织 PCM。分配、转换都不在 decode 回调。
void RenpyAppendCopiedFrame(RenpyFmt* f, const RenpyPcmEvent* event) {
    const int fmt = event->sample_format;
    const uint32_t ch = event->channels;
    const uint32_t bps = event->bytes_per_sample;
    const bool planar = event->plane_count > 1;
    const uint8_t* planes[8] = {nullptr};
    for (uint32_t c = 0; c < event->plane_count; ++c) {
      planes[c] = event->payload + event->plane_offsets[c];
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
    uint32_t frames = event->frames;
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
}

// decode 热路径：TryEnter（竞争即丢）读取 avctx→slot，固定上限 memcpy 到预分配槽并立即返回。
// 不分配、不转换、不写盘、不等待 worker，满足游戏音频回调零阻塞约束。
void EnqueueRenpyFrame(void* avctx, void* frame) {
  if (!TryEnterCriticalSection(&g_renpy_cs)) return;
  int slot = -1;
  uint32_t channels = 0;
  void* fmt_ctx = nullptr;
  for (int k = 0; k < kMaxRenpyAvctx; ++k) {
    if (g_renpy_avctx[k].avctx == avctx) {
      slot = g_renpy_avctx[k].fmt_slot;
      break;
    }
  }
  if (slot >= 0 && slot < kMaxRenpyFmt &&
      g_renpy_fmt[slot].fmt_ctx != nullptr) {
    channels = g_renpy_fmt[slot].channels;
    fmt_ctx = g_renpy_fmt[slot].fmt_ctx;
  }
  LeaveCriticalSection(&g_renpy_cs);
  if (slot < 0 || channels < 1 || channels > 8) return;

  RenpyPcmEvent* event = nullptr;
  for (int i = 0; i < kRenpyPcmEventCount; ++i) {
    if (InterlockedCompareExchange(&g_renpy_pcm_events[i].state, 1, 0) == 0) {
      event = &g_renpy_pcm_events[i];
      break;
    }
  }
  if (event == nullptr) return;
  bool copied = false;
  __try {
    const int samples = *reinterpret_cast<int*>(
        reinterpret_cast<uint8_t*>(frame) + kAvfNbSamplesOff);
    const int format = *reinterpret_cast<int*>(
        reinterpret_cast<uint8_t*>(frame) + kAvfFormatOff);
    uint32_t bps = 0;
    bool planar = false;
    if (samples <= 0 || samples > (1 << 20) ||
        !SampleFormatLayout(format, &bps, &planar)) {
      __leave;
    }
    const uint32_t plane_count = planar ? channels : 1u;
    const uint64_t bytes_per_frame = planar ? bps : bps * channels;
    uint32_t frames = static_cast<uint32_t>(samples);
    const uint64_t total_per_frame = bytes_per_frame * plane_count;
    if (total_per_frame == 0) __leave;
    const uint32_t max_frames =
        static_cast<uint32_t>(kRenpyPcmEventBytes / total_per_frame);
    if (frames > max_frames) frames = max_frames;
    if (frames == 0) __leave;
    const uint8_t* source_planes[8] = {nullptr};
    if (planar) {
      const uint8_t** extended = *reinterpret_cast<const uint8_t***>(
          reinterpret_cast<uint8_t*>(frame) + kAvfExtDataOff);
      for (uint32_t c = 0; c < channels; ++c) {
        const uint8_t* source = *reinterpret_cast<const uint8_t**>(
            reinterpret_cast<uint8_t*>(frame) + kAvfDataOff +
            static_cast<size_t>(c) * sizeof(void*));
        if (source == nullptr && extended != nullptr) source = extended[c];
        if (source == nullptr) __leave;
        source_planes[c] = source;
      }
    } else {
      source_planes[0] = *reinterpret_cast<const uint8_t**>(
          reinterpret_cast<uint8_t*>(frame) + kAvfDataOff);
      if (source_planes[0] == nullptr) __leave;
    }
    event->fmt_slot = slot;
    event->fmt_ctx = fmt_ctx;
    event->sample_format = format;
    event->frames = frames;
    event->channels = channels;
    event->bytes_per_sample = bps;
    event->plane_count = plane_count;
    uint32_t offset = 0;
    for (uint32_t plane = 0; plane < plane_count; ++plane) {
      const uint32_t length = frames * static_cast<uint32_t>(bytes_per_frame);
      event->plane_offsets[plane] = offset;
      event->plane_lengths[plane] = length;
      memcpy(event->payload + offset, source_planes[plane], length);
      offset += length;
    }
    copied = true;
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    copied = false;
  }
  MemoryBarrier();
  InterlockedExchange(&event->state, copied ? 2 : 0);
}

void ProcessRenpyPcmEvent(RenpyPcmEvent* event) {
  if (InterlockedCompareExchange(&event->state, 3, 2) != 2) return;
  EnterCriticalSection(&g_renpy_cs);
  if (event->fmt_slot >= 0 && event->fmt_slot < kMaxRenpyFmt &&
      g_renpy_fmt[event->fmt_slot].fmt_ctx == event->fmt_ctx) {
    RenpyAppendCopiedFrame(&g_renpy_fmt[event->fmt_slot], event);
  }
  LeaveCriticalSection(&g_renpy_cs);
  InterlockedExchange(&event->state, 0);
}

void DrainRenpyPcmEvents(int slot) {
  for (int i = 0; i < kRenpyPcmEventCount; ++i) {
    if (g_renpy_pcm_events[i].state == 2 &&
        g_renpy_pcm_events[i].fmt_slot == slot) {
      ProcessRenpyPcmEvent(&g_renpy_pcm_events[i]);
    }
  }
}

void EnqueueRenpyWrite(uint8_t* pcm, uint32_t length, uint32_t sample_rate,
                       uint32_t channels, const wchar_t* basename) {
  if (pcm == nullptr) return;
  for (int i = 0; i < kRenpyWriteEventCount; ++i) {
    RenpyWriteEvent* event = &g_renpy_write_events[i];
    if (InterlockedCompareExchange(&event->state, 1, 0) != 0) continue;
    event->pcm = pcm;
    event->length = length;
    event->sample_rate = sample_rate;
    event->channels = channels;
    lstrcpynW(event->basename, basename, 128);
    MemoryBarrier();
    InterlockedExchange(&event->state, 2);
    return;
  }
  free(pcm);  // 有界队列满：保游戏优先，丢弃该句。
}

void ProcessRenpyWriteEvent(RenpyWriteEvent* event) {
  if (InterlockedCompareExchange(&event->state, 3, 2) != 2) return;
  if (event->length > 0 && event->sample_rate > 0 && event->channels > 0) {
    WriteRenpyWav(event->pcm, event->length, event->sample_rate,
                  event->channels, event->basename);
    if (g_header != nullptr) g_header->reserved_luna |= 0x40000000;
  }
  free(event->pcm);
  event->pcm = nullptr;
  InterlockedExchange(&event->state, 0);
}

// ctx 关闭：从表摘出该 ctx 的累积 PCM（持锁清槽 + 清关联），再在锁外落盘 + 释放（避免文件 IO 持锁）。
void RenpyCloseCtx(void* ctx) {
  if (ctx == nullptr || !g_renpy_cs_ready) return;
  uint8_t* pcm = nullptr;
  uint32_t len = 0, rate = 0, ch = 0;
  wchar_t base[128];
  base[0] = 0;
  int closing_slot = -1;
  EnterCriticalSection(&g_renpy_cs);
  for (int i = 0; i < kMaxRenpyFmt; ++i) {
    if (g_renpy_fmt[i].fmt_ctx == ctx) {
      closing_slot = i;
      break;
    }
  }
  LeaveCriticalSection(&g_renpy_cs);
  if (closing_slot < 0) return;
  DrainRenpyPcmEvents(closing_slot);
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
  EnqueueRenpyWrite(pcm, len, rate, ch, base);
}

DWORD WINAPI RenpyWorker(void*) {
  while (InterlockedCompareExchange(&g_renpy_worker_stop, 0, 0) == 0) {
    bool processed = false;
    for (int i = 0; i < kRenpyResourceEventCount; ++i) {
      RenpyResourceEvent* event = &g_renpy_resource_events[i];
      if (InterlockedCompareExchange(&event->state, 3, 2) == 2) {
        CopyRenpyResource(event->url);
        InterlockedExchange(&event->state, 0);
        processed = true;
      }
    }
    for (int i = 0; i < kRenpyPcmEventCount; ++i) {
      if (g_renpy_pcm_events[i].state == 2) {
        ProcessRenpyPcmEvent(&g_renpy_pcm_events[i]);
        processed = true;
      }
    }
    for (int i = 0; i < kRenpyWriteEventCount; ++i) {
      if (g_renpy_write_events[i].state == 2) {
        ProcessRenpyWriteEvent(&g_renpy_write_events[i]);
        processed = true;
      }
    }
    if (!processed) Sleep(2);
  }
  for (int i = 0; i < kRenpyResourceEventCount; ++i) {
    RenpyResourceEvent* event = &g_renpy_resource_events[i];
    if (InterlockedCompareExchange(&event->state, 3, 2) == 2) {
      CopyRenpyResource(event->url);
      InterlockedExchange(&event->state, 0);
    }
  }
  for (int i = 0; i < kRenpyPcmEventCount; ++i) {
    ProcessRenpyPcmEvent(&g_renpy_pcm_events[i]);
  }
  for (int i = 0; i < kRenpyWriteEventCount; ++i) {
    ProcessRenpyWriteEvent(&g_renpy_write_events[i]);
  }
  return 0;
}

bool StartRenpyWorker() {
  if (g_renpy_worker != nullptr) return true;
  InterlockedExchange(&g_renpy_worker_stop, 0);
  g_renpy_worker = CreateThread(nullptr, 0, RenpyWorker, nullptr, 0, nullptr);
  return g_renpy_worker != nullptr;
}

void StopRenpyWorker() {
  HANDLE worker = g_renpy_worker;
  if (worker == nullptr) return;
  InterlockedExchange(&g_renpy_worker_stop, 1);
  WaitForSingleObject(worker, INFINITE);
  CloseHandle(worker);
  g_renpy_worker = nullptr;
}

// -- detour: avformat_open_input --（url 命中语音则登记 ctx；basename 供落盘命名）
int __cdecl Detour_avformat_open_input(void** ps, const char* url, void* fmt,
                                       void** options) {
  const int ret = g_orig_avformat_open_input(ps, url, fmt, options);
  if (ret == 0 && g_capture_enabled) EnqueueRenpyResource(url);
  if (ret == 0 && ps != nullptr && *ps != nullptr && g_capture_enabled &&
      g_renpy_cs_ready && g_renpy_avformat_major == 54 && IsVoiceUrl(url)) {
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
    EnqueueRenpyFrame(avctx, frame);
    if (g_header != nullptr) {
      g_header->reserved_luna |= 0x20000000;  // diag: decode frame queued
    }
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

// 所有带 major 的 avformat DLL 都挂稳定的 open_input ABI，发布通用 OGG/WAV/Opus/FLAC 资源事件。
// 只有 major 54 继续解释内部结构并挂 decode_audio4，作为旧 Ren'Py 的 PCM 兼容降级；现代 major
// 不读取私有结构偏移。所有资源 IO、PCM 转换和 WAV 落盘均由 RenpyWorker 完成。
bool TryHookRenpyAudio() {
  static bool avformat_done = false;
  static bool legacy_avcodec_done = false;
  if (!avformat_done) {
    uint32_t major = 0;
    HMODULE m = FindLoadedFfmpegModule(
        hibiki_voice_hook::FfmpegModuleKind::kAvformat, &major);
    if (m != nullptr) {
      if (!StartRenpyWorker()) return false;
      if (HookFn(reinterpret_cast<void*>(GetProcAddress(m, "avformat_open_input")),
                 reinterpret_cast<void*>(&Detour_avformat_open_input),
                 reinterpret_cast<void**>(&g_orig_avformat_open_input))) {
        g_renpy_avformat_major = major;
        avformat_done = true;
        if (g_header != nullptr) {
          g_header->reserved_luna |= 0x08000000;  // diag: avformat hook 装上
          g_header->hook_diagnostics |=
              hibiki_voice_hook::kDiagFfmpegResourceHooksReady;
        }
      }
      if (major == 54) {
        HookFn(reinterpret_cast<void*>(GetProcAddress(m, "avformat_find_stream_info")),
               reinterpret_cast<void*>(&Detour_avformat_find_stream_info),
               reinterpret_cast<void**>(&g_orig_avformat_find_stream_info));
        HookFn(reinterpret_cast<void*>(GetProcAddress(m, "avformat_close_input")),
               reinterpret_cast<void*>(&Detour_avformat_close_input),
               reinterpret_cast<void**>(&g_orig_avformat_close_input));
        HookFn(reinterpret_cast<void*>(GetProcAddress(m, "av_close_input_file")),
               reinterpret_cast<void*>(&Detour_av_close_input_file),
               reinterpret_cast<void**>(&g_orig_av_close_input_file));
      }
    }
  }
  if (g_renpy_avformat_major == 54 && !legacy_avcodec_done) {
    uint32_t major = 0;
    HMODULE m = FindLoadedFfmpegModule(
        hibiki_voice_hook::FfmpegModuleKind::kAvcodec, &major);
    if (m != nullptr && major == 54) {
      if (HookFn(reinterpret_cast<void*>(GetProcAddress(m, "avcodec_decode_audio4")),
                 reinterpret_cast<void*>(&Detour_avcodec_decode_audio4),
                 reinterpret_cast<void**>(&g_orig_avcodec_decode_audio4))) {
        legacy_avcodec_done = true;
        if (g_header != nullptr) {
          g_header->reserved_luna |= 0x08000000;  // diag: avcodec hook 装上
        }
      }
    }
  }
  return avformat_done;
}

HMODULE FindLoadedFfmpegModule(hibiki_voice_hook::FfmpegModuleKind kind,
                               uint32_t* major) {
  HMODULE result = nullptr;
  uint32_t result_major = 0;
  HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32,
                                         GetCurrentProcessId());
  if (snap == INVALID_HANDLE_VALUE) return nullptr;
  MODULEENTRY32W me = {0};
  me.dwSize = sizeof(me);
  if (Module32FirstW(snap, &me)) {
    do {
      const auto parsed = hibiki_voice_hook::ParseFfmpegModuleName(me.szModule);
      if (parsed.kind == kind && parsed.major > result_major) {
        result = me.hModule;
        result_major = parsed.major;
      }
    } while (Module32NextW(snap, &me));
  }
  CloseHandle(snap);
  if (major != nullptr) *major = result_major;
  return result;
}
