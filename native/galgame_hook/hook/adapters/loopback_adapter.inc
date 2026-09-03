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

enum : LONG {
  kLbWorkerIdle = 0,
  kLbWorkerStarting = 1,
  kLbWorkerRunning = 2,
  kLbWorkerStopping = 3,
  kLbWorkerExited = 4,
};

// Process-local control is deliberately independent from g_stop: a runtime
// full->cleanOnly/resourceOnly transition must stop only loopback while every
// engine/text adapter keeps running. The owning LoopbackAdapter never starts a
// replacement until the prior HANDLE is signalled and reaped.
struct LoopbackWorkerControl {
  volatile LONG stop_requested = 0;
  volatile LONG phase = kLbWorkerIdle;
  volatile LONG request_seq = 0;
};

bool LbShouldStop(const LoopbackWorkerControl* control) {
  if (g_stop || control == nullptr || g_header == nullptr ||
      InterlockedCompareExchange(
          const_cast<volatile LONG*>(&control->stop_requested), 0, 0) != 0) {
    return true;
  }
  const fushi_voice_hook::NativeLoopbackRequestSnapshot request =
      fushi_voice_hook::ReadNativeLoopbackRequest(g_header);
  const uint32_t worker_request_seq =
      static_cast<uint32_t>(InterlockedCompareExchange(
          const_cast<volatile LONG*>(&control->request_seq), 0, 0));
  return !fushi_voice_hook::NativeLoopbackWorkerMayCapture(
      request, worker_request_seq);
}

void LbDiag(uint32_t bits) {
  if (g_header != nullptr) {
    fushi_voice_hook::AtomicOrShared32(&g_header->loopback_diag, bits);
  }
}

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
      LbDiag(fushi_voice_hook::kLoopbackDiagUnknownFormat);
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
    LbDiag(fushi_voice_hook::kLoopbackDiagNonSilentPacket);
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

// loopback capture thread. This function is reachable only after the policy
// controller has observed an exact allow request. It checks the independent
// stop word before every privacy-sensitive startup boundary, and publishes no
// shared policy acknowledgement itself: the single HookWorker controller does
// that only after observing running or after this HANDLE is fully signalled.
DWORD WINAPI LoopbackWorker(LPVOID context) {
  auto* control = static_cast<LoopbackWorkerControl*>(context);
  if (control == nullptr || g_header == nullptr || g_lb_ring_base == nullptr ||
      LbShouldStop(control)) {
    if (control != nullptr) {
      InterlockedExchange(&control->phase, kLbWorkerExited);
    }
    return 0;
  }

  LbDiag(fushi_voice_hook::kLoopbackDiagWorkerEntered);
  if (LbShouldStop(control)) {
    InterlockedExchange(&control->phase, kLbWorkerExited);
    return 0;
  }

  const HRESULT hrco = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool com_owned = SUCCEEDED(hrco);  // S_OK/S_FALSE both need uninit.
  IMMDeviceEnumerator* enumr = nullptr;
  IMMDevice* device = nullptr;
  IAudioClient* client = nullptr;
  IAudioCaptureClient* capture = nullptr;
  WAVEFORMATEX* mix = nullptr;
  LbSrcFmt src_fmt = kLbUnknown;
  uint32_t ch = 0;
  uint32_t rate = 0;
  bool started = false;
  HRESULT hr = hrco;

  if (SUCCEEDED(hr) && !LbShouldStop(control)) {
    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                          __uuidof(IMMDeviceEnumerator),
                          reinterpret_cast<void**>(&enumr));
  }
  if (SUCCEEDED(hr) && enumr != nullptr && !LbShouldStop(control)) {
    hr = enumr->GetDefaultAudioEndpoint(eRender, eConsole, &device);
  }
  if (SUCCEEDED(hr) && device != nullptr && !LbShouldStop(control)) {
    hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                          reinterpret_cast<void**>(&client));
  }
  if (SUCCEEDED(hr) && client != nullptr && !LbShouldStop(control)) {
    hr = client->GetMixFormat(&mix);
  }
  if (SUCCEEDED(hr) && mix != nullptr && !LbShouldStop(control)) {
    src_fmt = LbParseFormat(mix, &rate, &ch);
    LbDiag(fushi_voice_hook::kLoopbackDiagDeviceReady);
    g_header->loopback_sample_rate = rate;
    g_header->loopback_channels = ch;
    g_header->loopback_bits_per_sample = 16;
    g_header->loopback_block_align = ch * 2u;
    const REFERENCE_TIME kBufDur = 10000000;  // 1s (100ns units)
    // This diagnostic is the exact boundary the deny policy must never cross.
    LbDiag(fushi_voice_hook::kLoopbackDiagInitializeAttempted);
    hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                            AUDCLNT_STREAMFLAGS_LOOPBACK, kBufDur, 0, mix,
                            nullptr);
  }
  if (SUCCEEDED(hr) && client != nullptr && !LbShouldStop(control)) {
    hr = client->GetService(__uuidof(IAudioCaptureClient),
                            reinterpret_cast<void**>(&capture));
  }
  if (SUCCEEDED(hr) && capture != nullptr && !LbShouldStop(control)) {
    hr = client->Start();
    started = SUCCEEDED(hr);
    if (started) {
      LbDiag(fushi_voice_hook::kLoopbackDiagCaptureStarted);
      InterlockedExchange(&control->phase, kLbWorkerRunning);
    }
  }

  std::vector<int16_t> scratch;
  ULONGLONG last_marker = GetTickCount64();
  if (started) LbWriteMarker();

  while (started && !LbShouldStop(control)) {
    UINT32 packet = 0;
    HRESULT gp = capture->GetNextPacketSize(&packet);
    while (SUCCEEDED(gp) && packet != 0 && !LbShouldStop(control)) {
      BYTE* data = nullptr;
      UINT32 frames = 0;
      DWORD flags = 0;
      const HRESULT gb =
          capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
      if (FAILED(gb)) break;
      const bool silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
      if (silent) {
        LbDiag(fushi_voice_hook::kLoopbackDiagSilentPacket);
      }
      LbConvertStore(data, frames, ch, src_fmt, silent, &scratch);
      capture->ReleaseBuffer(frames);
      gp = capture->GetNextPacketSize(&packet);
    }
    const ULONGLONG now = GetTickCount64();
    if (now - last_marker >= 200) {
      LbWriteMarker();
      last_marker = now;
    }
    Sleep(10);
  }

  const bool policy_stopped = LbShouldStop(control);
  if (policy_stopped) {
    InterlockedExchange(&control->phase, kLbWorkerStopping);
    LbDiag(fushi_voice_hook::kLoopbackDiagPolicyStopObserved);
  } else if (!started) {
    LbDiag(fushi_voice_hook::kLoopbackDiagFailed);
  }

  // The controller may acknowledge stopped only after this complete reverse
  // release and the thread HANDLE becomes signalled.
  if (client != nullptr && started) client->Stop();
  if (capture != nullptr) capture->Release();
  if (client != nullptr) client->Release();
  if (device != nullptr) device->Release();
  if (enumr != nullptr) enumr->Release();
  if (mix != nullptr) CoTaskMemFree(mix);
  if (com_owned) CoUninitialize();
  InterlockedExchange(&control->phase, kLbWorkerExited);
  return !started && !policy_stopped ? 1u : 0u;
}
