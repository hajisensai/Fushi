// P1 zero-behaviour-change split: included inside dll_main.cpp anonymous namespace.
// ══ C.2f WASAPI loopback 兜底混音捕获 ════════════════════════════════════════════
// 前述所有 hook（XAudio2/DirectSound/KiriKiri/Ren'Py/GDI 文本）覆盖不到的游戏（Atelier Kaguya、
// 未识别引擎）音频走未 hook 的私有路径。此处**不** hook 任何 COM vtable，改用标准 WASAPI loopback
// （AUDCLNT_STREAMFLAGS_LOOPBACK）从系统默认渲染端点抓**最终混音**（voice+BGM）——游戏在放音时，
// loopback 抓到的就是它送扬声器的输出。制卡时按某句文本时间戳抽 [ts-100ms, ts+5000ms] 窗口即得
// 该句混音（带 BGM，可闻人声）。抓的是**整个系统输出**——测试/使用时应只有目标游戏在放音。
//
// 独立线程（非音频回调）：可 CoInitialize/阻塞轮询，不受零阻塞红线约束；退出必须干净（g_stop
// 通知退出、显式反序释放 COM/CoUninitialize）。混音格式常是 32-bit float（WAVEFORMATEXTENSIBLE），
// 统一转 16-bit PCM 入 loopback 专用环（独立于 voice 环，避免与 XAudio2/DS/解码 clip 混淆）。

// 混音源采样格式（GetMixFormat 解析一次）。混音端点几乎恒 float32；int16/int32 兜底；其它罕见
// 格式（24-bit 等）判 unknown，按静音填 0 保持时间轴（诊断置位）。
enum LbSrcFmt : int { kLbUnknown = 0, kLbFloat32 = 1, kLbInt16 = 2, kLbInt32 = 3 };

// 解析混音 WAVEFORMATEX：填存储用 sample_rate/channels，返回源采样格式（同 MaybeRecordFormat 口径
// 用 SubFormat.Data1 判 float/PCM，避免依赖 ksmedia.h 的 GUID 常量）。
LbSrcFmt LbParseFormat(const WAVEFORMATEX* wf, uint32_t* rate, uint32_t* channels) {
  if (wf == nullptr) {
    return kLbUnknown;
  }
  *rate = wf->nSamplesPerSec;
  *channels = wf->nChannels;
  const WORD tag = wf->wFormatTag;
  const WORD bits = wf->wBitsPerSample;
  if (tag == WAVE_FORMAT_EXTENSIBLE &&
      wf->cbSize >= sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
    const auto* ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(wf);
    if (ext->SubFormat.Data1 == WAVE_FORMAT_IEEE_FLOAT && bits == 32) {
      return kLbFloat32;
    }
    if (ext->SubFormat.Data1 == WAVE_FORMAT_PCM) {
      if (bits == 16) return kLbInt16;
      if (bits == 32) return kLbInt32;
    }
    return kLbUnknown;
  }
  if (tag == WAVE_FORMAT_IEEE_FLOAT && bits == 32) return kLbFloat32;
  if (tag == WAVE_FORMAT_PCM && bits == 16) return kLbInt16;
  if (tag == WAVE_FORMAT_PCM && bits == 32) return kLbInt32;
  return kLbUnknown;
}

// 把一个 loopback 数据包的源 PCM 转 16-bit 交织写进 loopback 环（**单写者**=loopback 线程，无需
// 原子）。silent=true（AUDCLNT_BUFFERFLAGS_SILENT）或 src 为空/未知格式时填 0 保持时间轴。
// frames=每声道帧数，ch=声道数。scratch 复用避免每包分配（本线程非零阻塞红线，堆分配本可接受）。
void LbConvertStore(const BYTE* src, uint32_t frames, uint32_t ch, LbSrcFmt src_fmt,
                    bool silent, std::vector<int16_t>* scratch) {
  if (g_lb_ring_base == nullptr || g_header == nullptr || frames == 0 || ch == 0) {
    return;
  }
  const uint32_t samples = frames * ch;
  scratch->resize(samples);
  int16_t* out = scratch->data();
  const bool zero_fill = silent || src == nullptr || src_fmt == kLbUnknown;
  if (zero_fill) {
    memset(out, 0, static_cast<size_t>(samples) * sizeof(int16_t));
    if (src_fmt == kLbUnknown) {
      g_header->loopback_diag |= 0x40;  // 未知混音格式，按静音填（保持时间轴，不误抓）
    }
  } else if (src_fmt == kLbFloat32) {
    const float* f = reinterpret_cast<const float*>(src);
    for (uint32_t i = 0; i < samples; i++) {
      float v = f[i];
      if (v > 1.0f) {
        v = 1.0f;
      } else if (v < -1.0f) {
        v = -1.0f;
      }
      out[i] = static_cast<int16_t>(v * 32767.0f);
    }
  } else if (src_fmt == kLbInt16) {
    memcpy(out, src, static_cast<size_t>(samples) * sizeof(int16_t));
  } else {  // kLbInt32：取高 16 位
    const int32_t* s = reinterpret_cast<const int32_t*>(src);
    for (uint32_t i = 0; i < samples; i++) {
      out[i] = static_cast<int16_t>(s[i] >> 16);
    }
  }
  // 写入 loopback 环（单写者直接推进 total/write_pos；wrap 处理）。
  const uint32_t cap = g_header->loopback_ring_capacity;
  if (cap == 0) {
    return;
  }
  uint32_t len = samples * static_cast<uint32_t>(sizeof(int16_t));
  const uint8_t* data = reinterpret_cast<const uint8_t*>(out);
  if (len >= cap) {  // 单包超一整圈（不会发生，防御性）：只留最后 cap 字节。
    data += (len - cap);
    len = cap;
  }
  const uint64_t start = g_header->loopback_total_written;
  const uint32_t at = static_cast<uint32_t>(start % cap);
  const uint32_t first = (len <= cap - at) ? len : (cap - at);
  memcpy(g_lb_ring_base + at, data, first);
  if (len > first) {
    memcpy(g_lb_ring_base, data + first, len - first);
  }
  g_header->loopback_total_written = start + len;
  g_header->loopback_write_pos = static_cast<uint32_t>((start + len) % cap);
  if (!zero_fill) {
    g_header->loopback_diag |= 0x08;  // 捕获到非静音音频包
  }
}

// 写一条时间戳↔位置标记（单写者）。填 tick/total 后**最后**写 seq 作完成标记，再自增计数。
void LbWriteMarker() {
  if (g_lb_marker_base == nullptr || g_header == nullptr) {
    return;
  }
  const uint64_t idx = g_header->loopback_marker_count;  // 单写者：旧值即 0 基下标
  const size_t off =
      static_cast<size_t>(idx % kLoopbackMarkerCount) * sizeof(LoopbackMarker);
  auto* m = reinterpret_cast<LoopbackMarker*>(g_lb_marker_base + off);
  m->tick_ms = GetTickCount64();
  m->total_written = g_header->loopback_total_written;
  m->seq = idx + 1;                        // 完成标记，最后写
  g_header->loopback_marker_count = idx + 1;  // 单调自增（reader 用它判有效范围）
}

// loopback 捕获线程：CoInitialize → 默认渲染端点 → IAudioClient loopback 初始化 → 轮询 GetBuffer
// 转 16-bit 入环 + 每 ~200ms 记标记，直到 g_stop。退出反序释放 COM。全程判空 + HRESULT 门控，
// 任一步失败即置诊断位、跳过后续、干净收尾（绝不崩游戏）。
DWORD WINAPI LoopbackWorker(LPVOID) {
  if (g_header == nullptr || g_lb_ring_base == nullptr) {
    return 0;
  }
  const HRESULT hrco = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool com_owned = SUCCEEDED(hrco);  // 成功（含 S_FALSE）都须配对 CoUninitialize
  g_header->loopback_diag |= 0x01;         // 线程启动 + COM init 尝试

  IMMDeviceEnumerator* enumr = nullptr;
  IMMDevice* device = nullptr;
  IAudioClient* client = nullptr;
  IAudioCaptureClient* capture = nullptr;
  WAVEFORMATEX* mix = nullptr;
  LbSrcFmt src_fmt = kLbUnknown;
  uint32_t ch = 0;
  uint32_t rate = 0;
  bool started = false;

  HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                __uuidof(IMMDeviceEnumerator),
                                reinterpret_cast<void**>(&enumr));
  if (SUCCEEDED(hr) && enumr != nullptr) {
    hr = enumr->GetDefaultAudioEndpoint(eRender, eConsole, &device);
  }
  if (SUCCEEDED(hr) && device != nullptr) {
    hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                          reinterpret_cast<void**>(&client));
  }
  if (SUCCEEDED(hr) && client != nullptr) {
    hr = client->GetMixFormat(&mix);
  }
  if (SUCCEEDED(hr) && mix != nullptr) {
    src_fmt = LbParseFormat(mix, &rate, &ch);
    g_header->loopback_diag |= 0x02;  // 设备/客户端就绪 + 拿到混音格式
    // 存储格式：16-bit（混音已转换），采样率/声道取自混音格式；block_align 最后填作格式就绪信号。
    g_header->loopback_sample_rate = rate;
    g_header->loopback_channels = ch;
    g_header->loopback_bits_per_sample = 16;
    g_header->loopback_block_align = ch * 2u;
    // loopback 缓冲时长 1s（容量足够，非实时精度）。共享模式 loopback 用混音格式原样初始化。
    const REFERENCE_TIME kBufDur = 10000000;  // 1s（100ns 单位）
    hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK,
                            kBufDur, 0, mix, nullptr);
  }
  if (SUCCEEDED(hr) && client != nullptr) {
    hr = client->GetService(__uuidof(IAudioCaptureClient),
                            reinterpret_cast<void**>(&capture));
  }
  if (SUCCEEDED(hr) && capture != nullptr) {
    hr = client->Start();
    started = SUCCEEDED(hr);
    if (started) {
      g_header->loopback_diag |= 0x04;  // 捕获已启动
    }
  }

  std::vector<int16_t> scratch;
  ULONGLONG last_marker = GetTickCount64();
  LbWriteMarker();  // 起点标记（total=0）

  if (started) {
    while (!g_stop) {
      UINT32 packet = 0;
      HRESULT gp = capture->GetNextPacketSize(&packet);
      while (SUCCEEDED(gp) && packet != 0 && !g_stop) {
        BYTE* data = nullptr;
        UINT32 frames = 0;
        DWORD flags = 0;
        const HRESULT gb =
            capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
        if (FAILED(gb)) {
          break;
        }
        const bool silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
        if (silent) {
          g_header->loopback_diag |= 0x10;  // 见过静音包
        }
        LbConvertStore(data, frames, ch, src_fmt, silent, &scratch);
        capture->ReleaseBuffer(frames);
        gp = capture->GetNextPacketSize(&packet);
      }
      // 每 ~200ms 记一条标记（含静音期：total 不变、tick 前进，插值仍单调正确，覆盖静音间隙）。
      const ULONGLONG now = GetTickCount64();
      if (now - last_marker >= 200) {
        LbWriteMarker();
        last_marker = now;
      }
      Sleep(10);
    }
  } else {
    g_header->loopback_diag |= 0x80;  // 初始化/启动失败（无默认渲染端点、格式不支持等）
  }

  // 收尾：停捕获 + 反序释放全部 COM，CoUninitialize（仅自己 init 成功时配对）。
  if (client != nullptr && started) {
    client->Stop();
  }
  if (capture != nullptr) {
    capture->Release();
  }
  if (client != nullptr) {
    client->Release();
  }
  if (device != nullptr) {
    device->Release();
  }
  if (enumr != nullptr) {
    enumr->Release();
  }
  if (mix != nullptr) {
    CoTaskMemFree(mix);
  }
  if (com_owned) {
    CoUninitialize();
  }
  return 0;
}
