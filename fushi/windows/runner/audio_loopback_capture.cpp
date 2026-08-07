#include "audio_loopback_capture.h"

#include <audioclient.h>
#include <mmdeviceapi.h>
#include <mmreg.h>
#include <ksmedia.h>
#include <wrl/client.h>

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <thread>

// galgame 一键制卡 A 阶段的 WASAPI loopback 采集实现。见 audio_loopback_capture.h。
namespace fushi {

namespace {

using Microsoft::WRL::ComPtr;

// 环形缓冲保留的时长（秒）。48k 立体声 float32 ≈ 384KB/s，60s ≈ 23MB，内存有界。
constexpr int kRingSeconds = 60;
// 采集轮询间隔。WASAPI 共享 loopback 无独立事件时按此步长拉包（10ms 足够低延迟，
// 又不空转 CPU）。
constexpr DWORD kPollIntervalMs = 10;

// 全进程唯一采集状态。所有跨线程字段用 g_mutex / g_ring_mutex 保护。
struct CaptureState {
  std::thread thread;
  std::atomic<bool> stop{false};
  std::atomic<bool> running{false};

  // start 握手：采集线程完成 COM 初始化后填这些并 notify。
  std::mutex init_mutex;
  std::condition_variable init_cv;
  bool init_done = false;
  LoopbackFormat format;  // ok 表示初始化是否成功

  // 环形缓冲（字节），g_ring_mutex 保护。
  std::mutex ring_mutex;
  std::vector<uint8_t> ring;
  size_t capacity = 0;   // = byteRate * kRingSeconds，帧对齐
  size_t write_pos = 0;  // 下一个写入位置
  size_t filled = 0;     // 当前有效字节数（<= capacity）
  int block_align = 0;   // 每帧字节数 = channels * bits/8
  int byte_rate = 0;     // 每秒字节数
};

CaptureState g_state;

// 把 [len] 字节追加进环形缓冲（写满即覆盖最旧）。ring_mutex 已持有时调用。
void RingAppendLocked(const uint8_t* data, size_t len) {
  if (g_state.capacity == 0 || len == 0) {
    return;
  }
  // 超过一整圈的数据只需保留最后 capacity 字节，缓冲写满、下一次从头写。
  if (len >= g_state.capacity) {
    data += (len - g_state.capacity);
    memcpy(g_state.ring.data(), data, g_state.capacity);
    g_state.write_pos = 0;
    g_state.filled = g_state.capacity;
    return;
  }
  const size_t first = (std::min)(len, g_state.capacity - g_state.write_pos);
  memcpy(g_state.ring.data() + g_state.write_pos, data, first);
  if (len > first) {
    memcpy(g_state.ring.data(), data + first, len - first);
  }
  g_state.write_pos = (g_state.write_pos + len) % g_state.capacity;
  g_state.filled = (std::min)(g_state.capacity, g_state.filled + len);
}

// 从 GetMixFormat 的 WAVEFORMATEX 解析 LoopbackFormat（区分整型/浮点）。
LoopbackFormat ParseFormat(const WAVEFORMATEX* wf) {
  LoopbackFormat f;
  f.sample_rate = static_cast<int>(wf->nSamplesPerSec);
  f.channels = static_cast<int>(wf->nChannels);
  f.bits_per_sample = static_cast<int>(wf->wBitsPerSample);
  if (wf->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
    f.is_float = true;
  } else if (wf->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
    const auto* ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(wf);
    f.is_float =
        (ext->SubFormat == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
  }
  f.ok = f.sample_rate > 0 && f.channels > 0 && f.bits_per_sample > 0;
  return f;
}

// 采集线程主体：初始化 WASAPI loopback → 握手回报格式 → 循环拉包写环形缓冲 → 收尾。
void CaptureThreadMain() {
  const HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool co_ok = SUCCEEDED(co);

  ComPtr<IMMDeviceEnumerator> enumerator;
  ComPtr<IMMDevice> device;
  ComPtr<IAudioClient> client;
  ComPtr<IAudioCaptureClient> capture;
  WAVEFORMATEX* mix = nullptr;
  LoopbackFormat format;
  bool started = false;

  HRESULT hr = co_ok ? S_OK : co;
  if (SUCCEEDED(hr)) {
    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                          IID_PPV_ARGS(&enumerator));
  }
  if (SUCCEEDED(hr)) {
    hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
  }
  if (SUCCEEDED(hr)) {
    hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                          reinterpret_cast<void**>(client.GetAddressOf()));
  }
  if (SUCCEEDED(hr)) {
    hr = client->GetMixFormat(&mix);
  }
  if (SUCCEEDED(hr) && mix != nullptr) {
    format = ParseFormat(mix);
    // 100ms 缓冲；loopback 必须用 shared 模式 + AUDCLNT_STREAMFLAGS_LOOPBACK。
    const REFERENCE_TIME buffer_dur = 1000000;  // 100ms (100ns 单位)
    hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                            AUDCLNT_STREAMFLAGS_LOOPBACK, buffer_dur, 0, mix,
                            nullptr);
  }
  if (SUCCEEDED(hr)) {
    hr = client->GetService(IID_PPV_ARGS(&capture));
  }
  if (SUCCEEDED(hr)) {
    // 环形缓冲容量：byteRate * kRingSeconds，向下取整到帧对齐。
    std::lock_guard<std::mutex> lock(g_state.ring_mutex);
    g_state.block_align = format.channels * (format.bits_per_sample / 8);
    g_state.byte_rate = format.sample_rate * g_state.block_align;
    size_t cap = static_cast<size_t>(g_state.byte_rate) * kRingSeconds;
    if (g_state.block_align > 0) {
      cap -= (cap % g_state.block_align);
    }
    g_state.capacity = cap;
    g_state.ring.assign(cap, 0);
    g_state.write_pos = 0;
    g_state.filled = 0;
  }
  if (SUCCEEDED(hr)) {
    hr = client->Start();
    started = SUCCEEDED(hr);
  }

  // 握手回报：无论成败都要 notify，否则 Start() 永久阻塞。
  {
    std::lock_guard<std::mutex> lock(g_state.init_mutex);
    g_state.format = SUCCEEDED(hr) ? format : LoopbackFormat{};
    g_state.init_done = true;
  }
  g_state.init_cv.notify_all();

  if (FAILED(hr)) {
    if (mix != nullptr) {
      CoTaskMemFree(mix);
    }
    if (co_ok) {
      CoUninitialize();
    }
    return;
  }

  g_state.running.store(true);
  // 采集循环：按 kPollIntervalMs 拉尽所有已就绪包。
  while (!g_state.stop.load()) {
    Sleep(kPollIntervalMs);
    UINT32 packet = 0;
    if (FAILED(capture->GetNextPacketSize(&packet))) {
      break;
    }
    while (packet != 0) {
      BYTE* data = nullptr;
      UINT32 frames = 0;
      DWORD flags = 0;
      const HRESULT gb = capture->GetBuffer(&data, &frames, &flags, nullptr,
                                            nullptr);
      if (FAILED(gb)) {
        break;
      }
      const size_t bytes =
          static_cast<size_t>(frames) * static_cast<size_t>(g_state.block_align);
      {
        std::lock_guard<std::mutex> lock(g_state.ring_mutex);
        if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0) {
          // 静音包：WASAPI 不保证 data 有效，按静音写零（保持时间轴连续）。
          static thread_local std::vector<uint8_t> silence;
          if (silence.size() < bytes) {
            silence.assign(bytes, 0);
          }
          RingAppendLocked(silence.data(), bytes);
        } else if (data != nullptr) {
          RingAppendLocked(data, bytes);
        }
      }
      capture->ReleaseBuffer(frames);
      if (FAILED(capture->GetNextPacketSize(&packet))) {
        packet = 0;
      }
    }
  }

  client->Stop();
  g_state.running.store(false);
  if (mix != nullptr) {
    CoTaskMemFree(mix);
  }
  if (co_ok) {
    CoUninitialize();
  }
}

}  // namespace

AudioLoopbackCapture& AudioLoopbackCapture::Instance() {
  static AudioLoopbackCapture instance;
  return instance;
}

AudioLoopbackCapture::~AudioLoopbackCapture() {
  Stop();
}

LoopbackFormat AudioLoopbackCapture::Start() {
  if (g_state.running.load()) {
    std::lock_guard<std::mutex> lock(g_state.init_mutex);
    return g_state.format;
  }
  // 上一次的线程若已退出但未 join，先收尾。
  if (g_state.thread.joinable()) {
    g_state.stop.store(true);
    g_state.thread.join();
  }
  g_state.stop.store(false);
  {
    std::lock_guard<std::mutex> lock(g_state.init_mutex);
    g_state.init_done = false;
    g_state.format = LoopbackFormat{};
  }
  g_state.thread = std::thread(CaptureThreadMain);

  std::unique_lock<std::mutex> lock(g_state.init_mutex);
  g_state.init_cv.wait(lock, [] { return g_state.init_done; });
  const LoopbackFormat result = g_state.format;
  lock.unlock();
  if (!result.ok) {
    // 初始化失败：线程已自行退出，join 释放。
    if (g_state.thread.joinable()) {
      g_state.thread.join();
    }
  }
  return result;
}

void AudioLoopbackCapture::Stop() {
  g_state.stop.store(true);
  if (g_state.thread.joinable()) {
    g_state.thread.join();
  }
  std::lock_guard<std::mutex> lock(g_state.ring_mutex);
  g_state.ring.clear();
  g_state.ring.shrink_to_fit();
  g_state.capacity = 0;
  g_state.write_pos = 0;
  g_state.filled = 0;
}

LoopbackFormat AudioLoopbackCapture::GrabRecent(int back_ms,
                                                std::vector<uint8_t>& out) {
  out.clear();
  LoopbackFormat fmt;
  {
    std::lock_guard<std::mutex> lock(g_state.init_mutex);
    fmt = g_state.format;
  }
  if (!fmt.ok || back_ms <= 0) {
    return LoopbackFormat{};
  }
  std::lock_guard<std::mutex> lock(g_state.ring_mutex);
  if (g_state.filled == 0 || g_state.byte_rate <= 0) {
    return LoopbackFormat{};
  }
  size_t want =
      static_cast<size_t>(g_state.byte_rate) * static_cast<size_t>(back_ms) /
      1000;
  want = (std::min)(want, g_state.filled);
  if (g_state.block_align > 0) {
    want -= (want % g_state.block_align);
  }
  if (want == 0) {
    return LoopbackFormat{};
  }
  // 最近 want 字节起点 = write_pos 往回 want（环形）。
  const size_t start =
      (g_state.write_pos + g_state.capacity - want) % g_state.capacity;
  out.resize(want);
  const size_t first = (std::min)(want, g_state.capacity - start);
  memcpy(out.data(), g_state.ring.data() + start, first);
  if (want > first) {
    memcpy(out.data() + first, g_state.ring.data(), want - first);
  }
  return fmt;
}

}  // namespace fushi
