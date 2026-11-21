#include "audio_loopback_capture.h"

#include "audio_loopback_leases.h"
#include "audio_session_ducker.h"

#include <audioclient.h>
#include <audioclientactivationparams.h>
#include <audiopolicy.h>
#include <mmdeviceapi.h>
#include <mmreg.h>
#include <ksmedia.h>
#include <tlhelp32.h>
#include <wrl/client.h>
#include <wrl/implements.h>

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cwctype>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <thread>

// galgame 一键制卡 A 阶段的 WASAPI loopback 采集实现（系统混音），以及网页视频制卡队列的
// 进程树 + 静音模式。见 audio_loopback_capture.h。
namespace fushi {

namespace {

using Microsoft::WRL::ClassicCom;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::FtmBase;
using Microsoft::WRL::Make;
using Microsoft::WRL::RuntimeClass;
using Microsoft::WRL::RuntimeClassFlags;

// 环形缓冲保留的时长（秒）。48k 立体声 float32 ≈ 384KB/s，60s ≈ 23MB，内存有界。
constexpr int kRingSeconds = 60;
// 采集轮询间隔。WASAPI 共享 loopback 无独立事件时按此步长拉包（10ms 足够低延迟，
// 又不空转 CPU）。
constexpr DWORD kPollIntervalMs = 10;
// silent 模式兜底重扫会话的间隔（新会话主要靠 IAudioSessionNotification 即时压低）。
constexpr DWORD kDuckRescanMs = 250;
// 目标进程树刷新间隔（Chromium 按需起 / 退音频服务进程）。
constexpr DWORD kTreeRefreshMs = 1000;

// NtQueryInformationProcess(ProcessCommandLineInformation)：Win8.1+ 直接给 UNICODE_STRING，
// 不用读对方 PEB。只需 PROCESS_QUERY_LIMITED_INFORMATION。
bool ReadCommandLine(DWORD pid, std::wstring& out) {
  struct UnicodeString {
    USHORT Length;
    USHORT MaximumLength;
    PWSTR Buffer;
  };
  using NtQueryFn = LONG(WINAPI*)(HANDLE, ULONG, PVOID, ULONG, PULONG);
  static const NtQueryFn query = reinterpret_cast<NtQueryFn>(
      GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "NtQueryInformationProcess"));
  if (query == nullptr) {
    return false;
  }
  HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (h == nullptr) {
    return false;
  }
  constexpr ULONG kProcessCommandLineInformation = 60;
  ULONG need = 0;
  query(h, kProcessCommandLineInformation, nullptr, 0, &need);
  bool ok = false;
  if (need > 0 && need < (1u << 20)) {
    std::vector<uint8_t> buf(need);
    if (query(h, kProcessCommandLineInformation, buf.data(), need, &need) >= 0) {
      const auto* us = reinterpret_cast<const UnicodeString*>(buf.data());
      if (us->Buffer != nullptr) {
        out.assign(us->Buffer, us->Length / sizeof(wchar_t));
        ok = true;
      }
    }
  }
  CloseHandle(h);
  return ok;
}

std::wstring Lower(std::wstring s) {
  for (wchar_t& c : s) {
    c = static_cast<wchar_t>(std::towlower(c));
    if (c == L'/') {
      c = L'\\';
    }
  }
  while (!s.empty() && s.back() == L'\\') {
    s.pop_back();
  }
  return s;
}

// 命令行里 `--user-data-dir=` 的值（去引号）。没有返回空。
std::wstring UserDataDirArg(const std::wstring& cmdline) {
  const std::wstring key = L"--user-data-dir=";
  const size_t at = cmdline.find(key);
  if (at == std::wstring::npos) {
    return std::wstring();
  }
  size_t i = at + key.size();
  if (i < cmdline.size() && cmdline[i] == L'"') {
    const size_t end = cmdline.find(L'"', i + 1);
    return cmdline.substr(i + 1, end == std::wstring::npos ? std::wstring::npos
                                                            : end - i - 1);
  }
  const size_t end = cmdline.find(L' ', i);
  return cmdline.substr(i, end == std::wstring::npos ? std::wstring::npos
                                                      : end - i);
}

// 本进程子进程中，user data folder 为 [udf]（WebView2 实际传 `<udf>\EBWebView`）的
// msedgewebview2.exe 浏览器进程（命令行不带 `--type=`）。找不到回 0。
DWORD FindWebViewBrowser(const std::wstring& udf) {
  const std::wstring want = Lower(udf);
  const std::wstring want_eb = want + L"\\ebwebview";
  const DWORD self = GetCurrentProcessId();
  HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snap == INVALID_HANDLE_VALUE) {
    return 0;
  }
  std::vector<DWORD> candidates;
  PROCESSENTRY32W pe{};
  pe.dwSize = sizeof(pe);
  for (BOOL ok = Process32FirstW(snap, &pe); ok; ok = Process32NextW(snap, &pe)) {
    if (pe.th32ParentProcessID == self &&
        _wcsicmp(pe.szExeFile, L"msedgewebview2.exe") == 0) {
      candidates.push_back(pe.th32ProcessID);
    }
  }
  CloseHandle(snap);
  for (DWORD pid : candidates) {
    std::wstring cmd;
    if (!ReadCommandLine(pid, cmd) || cmd.find(L"--type=") != std::wstring::npos) {
      continue;
    }
    const std::wstring dir = Lower(UserDataDirArg(cmd));
    if (dir == want || dir == want_eb) {
      return pid;
    }
  }
  return 0;
}

DWORD ResolveTarget(const LoopbackOptions& options) {
  if (options.target_pid != 0) {
    return options.target_pid;
  }
  return FindWebViewBrowser(options.user_data_folder);
}

// ── process loopback 激活 ───────────────────────────────────────────────────

class ActivateHandler
    : public RuntimeClass<RuntimeClassFlags<ClassicCom>, FtmBase,
                          IActivateAudioInterfaceCompletionHandler> {
 public:
  ActivateHandler() : done_(CreateEventW(nullptr, TRUE, FALSE, nullptr)) {}
  ~ActivateHandler() override {
    if (done_ != nullptr) {
      CloseHandle(done_);
    }
  }
  STDMETHOD(ActivateCompleted)(IActivateAudioInterfaceAsyncOperation*) override {
    SetEvent(done_);
    return S_OK;
  }
  HANDLE done() const { return done_; }

 private:
  HANDLE done_;
};

// process loopback 固定请求 48k 立体声 float32（该虚拟设备不支持 GetMixFormat；
// AUTOCONVERTPCM 让引擎替我们重采样）。silent 模式放大还原依赖浮点格式。
WAVEFORMATEX ProcessLoopbackFormat() {
  WAVEFORMATEX w{};
  w.wFormatTag = WAVE_FORMAT_IEEE_FLOAT;
  w.nChannels = 2;
  w.nSamplesPerSec = 48000;
  w.wBitsPerSample = 32;
  w.nBlockAlign = static_cast<WORD>(w.nChannels * w.wBitsPerSample / 8);
  w.nAvgBytesPerSec = w.nSamplesPerSec * w.nBlockAlign;
  return w;
}

HRESULT ActivateProcessLoopback(DWORD pid, ComPtr<IAudioClient>& out) {
  AUDIOCLIENT_ACTIVATION_PARAMS params{};
  params.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
  params.ProcessLoopbackParams.TargetProcessId = pid;
  params.ProcessLoopbackParams.ProcessLoopbackMode =
      PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;
  PROPVARIANT pv{};
  pv.vt = VT_BLOB;
  pv.blob.cbSize = sizeof(params);
  pv.blob.pBlobData = reinterpret_cast<BYTE*>(&params);
  ComPtr<ActivateHandler> handler = Make<ActivateHandler>();
  if (handler == nullptr || handler->done() == nullptr) {
    return E_OUTOFMEMORY;
  }
  ComPtr<IActivateAudioInterfaceAsyncOperation> op;
  HRESULT hr = ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK,
                                           __uuidof(IAudioClient), &pv,
                                           handler.Get(), &op);
  if (FAILED(hr)) {
    return hr;
  }
  if (WaitForSingleObject(handler->done(), 5000) != WAIT_OBJECT_0) {
    return HRESULT_FROM_WIN32(ERROR_TIMEOUT);
  }
  HRESULT activate = E_FAIL;
  ComPtr<IUnknown> unk;
  hr = op->GetActivateResult(&activate, &unk);
  if (FAILED(hr)) {
    return hr;
  }
  if (FAILED(activate)) {
    return activate;
  }
  return unk.As(&out);
}

// ── 采集状态 ──────────────────────────────────────────────────────────────

// 一路采集（一个来源）的状态。所有跨线程字段用 init_mutex / ring_mutex 保护。
struct CaptureState {
  LoopbackOptions options;  // 这一路的来源
  std::wstring key;         // LoopbackSourceKey(options)
  std::thread thread;
  std::atomic<bool> stop{false};
  std::atomic<bool> running{false};

  // start 握手：采集线程完成 COM 初始化后填这些并 notify。
  std::mutex init_mutex;
  std::condition_variable init_cv;
  bool init_done = false;
  LoopbackFormat format;  // ok 表示初始化是否成功
  LoopbackError error = LoopbackError::kNone;

  // 环形缓冲（字节），ring_mutex 保护。
  std::mutex ring_mutex;
  std::vector<uint8_t> ring;
  size_t capacity = 0;   // = byteRate * kRingSeconds，帧对齐
  size_t write_pos = 0;  // 下一个写入位置
  size_t filled = 0;     // 当前有效字节数（<= capacity）
  int block_align = 0;   // 每帧字节数 = channels * bits/8
  int byte_rate = 0;     // 每秒字节数
};

// 全进程的采集注册表：每个来源最多一路采集，每路挂若干租约（见 audio_loopback_leases.h）。
// 所有公开方法都先拿 mutex；起停（含握手与 join）在锁内完成，保证同一来源「旧的一路
// 停干净（含 silent 还原音量）之后新的一路才开始压低」。
struct Registry {
  std::mutex mutex;
  std::map<uint32_t, std::unique_ptr<CaptureState>> sessions;
  LoopbackLeaseTable leases;
  uint32_t next_session = 0;
};

Registry g_registry;

// 查词那一刻钉住的一段 PCM（跨应用语音缓存）。只留最近一份：桌面应用外查词同一时刻
// 只有一张根查词卡，新查词顶替旧的；制卡时按 id 落盘，id 不匹配（已被顶替）就不给，
// 绝不把别的查词的声音挂到这张卡上。
struct PinnedSnapshot {
  std::mutex mutex;
  uint64_t next_id = 0;
  uint64_t id = 0;
  uint32_t session = 0;
  LoopbackFormat format;
  std::vector<uint8_t> pcm;
};

PinnedSnapshot g_pinned;

// 系统混音没有 silent 一说（只有进程树模式会压低会话音量）。
LoopbackOptions Normalize(const LoopbackOptions& options) {
  LoopbackOptions normalized = options;
  if (!normalized.process_tree()) {
    normalized.silent = false;
  }
  return normalized;
}

std::wstring SourceKey(const LoopbackOptions& options) {
  return LoopbackSourceKey(options.user_data_folder,
                           static_cast<uint32_t>(options.target_pid));
}

// 注册表锁内调用：停掉 [s] 的采集线程（silent 模式线程收尾时还原会话音量）。
void StopSessionLocked(CaptureState& s) {
  s.stop.store(true);
  if (s.thread.joinable()) {
    s.thread.join();
  }
}

// 注册表锁内调用：会话 [id] 没了，钉住的快照若来自它也一并释放（内存有界）。
void DropPinnedForSession(uint32_t id) {
  std::lock_guard<std::mutex> lock(g_pinned.mutex);
  if (g_pinned.session == id) {
    g_pinned.id = 0;
    g_pinned.session = 0;
    g_pinned.format = LoopbackFormat{};
    g_pinned.pcm.clear();
    g_pinned.pcm.shrink_to_fit();
  }
}

// 把 [s] 环里「最近 [back_ms] 毫秒」拷进 [out]（按时间先后，帧对齐）。
LoopbackFormat GrabFromSession(CaptureState& s, int back_ms,
                               std::vector<uint8_t>& out) {
  out.clear();
  LoopbackFormat fmt;
  {
    std::lock_guard<std::mutex> lock(s.init_mutex);
    fmt = s.format;
  }
  if (!fmt.ok || back_ms <= 0) {
    return LoopbackFormat{};
  }
  // 采集线程已自行退出（渲染端点被拔掉 / 失效）：环停在退出那一刻，里面是不知多久
  // 以前的声音，绝不能当成「最近 back_ms」交出去挂到卡上。同来源的下一次 Start 会
  // 重起一路并把租约迁过去（见 Start 的 stale 分支）。
  if (!s.running.load()) {
    return LoopbackFormat{};
  }
  std::lock_guard<std::mutex> lock(s.ring_mutex);
  if (s.filled == 0 || s.byte_rate <= 0) {
    return LoopbackFormat{};
  }
  size_t want = static_cast<size_t>(s.byte_rate) *
                static_cast<size_t>(back_ms) / 1000;
  want = (std::min)(want, s.filled);
  if (s.block_align > 0) {
    want -= (want % s.block_align);
  }
  if (want == 0) {
    return LoopbackFormat{};
  }
  // 最近 want 字节起点 = write_pos 往回 want（环形）。
  const size_t start = (s.write_pos + s.capacity - want) % s.capacity;
  out.resize(want);
  const size_t first = (std::min)(want, s.capacity - start);
  memcpy(out.data(), s.ring.data() + start, first);
  if (want > first) {
    memcpy(out.data() + first, s.ring.data(), want - first);
  }
  return fmt;
}

// 把 [len] 字节追加进环形缓冲（写满即覆盖最旧）。ring_mutex 已持有时调用。
void RingAppendLocked(CaptureState& s, const uint8_t* data, size_t len) {
  if (s.capacity == 0 || len == 0) {
    return;
  }
  // 超过一整圈的数据只需保留最后 capacity 字节，缓冲写满、下一次从头写。
  if (len >= s.capacity) {
    data += (len - s.capacity);
    memcpy(s.ring.data(), data, s.capacity);
    s.write_pos = 0;
    s.filled = s.capacity;
    return;
  }
  const size_t first = (std::min)(len, s.capacity - s.write_pos);
  memcpy(s.ring.data() + s.write_pos, data, first);
  if (len > first) {
    memcpy(s.ring.data(), data + first, len - first);
  }
  s.write_pos = (s.write_pos + len) % s.capacity;
  s.filled = (std::min)(s.capacity, s.filled + len);
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
void CaptureThreadMain(CaptureState* s) {
  const LoopbackOptions options = s->options;
  const HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool co_ok = SUCCEEDED(co);

  ComPtr<IAudioClient> client;
  ComPtr<IAudioCaptureClient> capture;
  WAVEFORMATEX* mix = nullptr;
  LoopbackFormat format;
  LoopbackError error = LoopbackError::kStartFailed;
  HANDLE packet_event = nullptr;
  const bool process_tree = options.process_tree();
  const bool silent = process_tree && options.silent;
  DWORD target = 0;
  SessionDucker ducker;
  ComPtr<DuckOnCreate> on_create;

  HRESULT hr = co_ok ? S_OK : co;
  if (SUCCEEDED(hr) && process_tree) {
    target = ResolveTarget(options);
    if (target == 0) {
      hr = E_FAIL;
      error = LoopbackError::kTargetNotFound;
    }
    if (SUCCEEDED(hr) && silent) {
      // 先压低再开始采集：Dart 握手一返回就会开播。
      ducker.Open();
      ducker.SetTree(target, ProcessTree(target));
      ducker.DuckAll();
      on_create = Make<DuckOnCreate>(&ducker);
      for (const auto& manager : ducker.managers()) {
        manager->RegisterSessionNotification(on_create.Get());
      }
    }
    if (SUCCEEDED(hr)) {
      hr = ActivateProcessLoopback(target, client);
      if (FAILED(hr)) {
        // 20348 之前的系统没有该虚拟设备：激活本身失败。
        error = LoopbackError::kProcessLoopbackUnsupported;
      }
    }
    if (SUCCEEDED(hr)) {
      WAVEFORMATEX wf = ProcessLoopbackFormat();
      format = ParseFormat(&wf);
      hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                              AUDCLNT_STREAMFLAGS_LOOPBACK |
                                  AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
                                  AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM,
                              1000000, 0, &wf, nullptr);
      if (FAILED(hr)) {
        error = LoopbackError::kStartFailed;
      }
    }
    if (SUCCEEDED(hr)) {
      packet_event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
      hr = packet_event != nullptr ? client->SetEventHandle(packet_event)
                                   : E_OUTOFMEMORY;
    }
  } else if (SUCCEEDED(hr)) {
    ComPtr<IMMDeviceEnumerator> enumerator;
    ComPtr<IMMDevice> device;
    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                          IID_PPV_ARGS(&enumerator));
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
  }
  if (SUCCEEDED(hr)) {
    hr = client->GetService(IID_PPV_ARGS(&capture));
  }
  if (SUCCEEDED(hr)) {
    // 环形缓冲容量：byteRate * kRingSeconds，向下取整到帧对齐。
    std::lock_guard<std::mutex> lock(s->ring_mutex);
    s->block_align = format.channels * (format.bits_per_sample / 8);
    s->byte_rate = format.sample_rate * s->block_align;
    size_t cap = static_cast<size_t>(s->byte_rate) * kRingSeconds;
    if (s->block_align > 0) {
      cap -= (cap % s->block_align);
    }
    s->capacity = cap;
    s->ring.assign(cap, 0);
    s->write_pos = 0;
    s->filled = 0;
  }
  if (SUCCEEDED(hr)) {
    hr = client->Start();
  }

  auto release_ducking = [&]() {
    if (on_create != nullptr) {
      for (const auto& manager : ducker.managers()) {
        manager->UnregisterSessionNotification(on_create.Get());
      }
    }
    ducker.RestoreAll();
  };

  // 握手回报：无论成败都要 notify，否则 Start() 永久阻塞。
  {
    std::lock_guard<std::mutex> lock(s->init_mutex);
    s->format = SUCCEEDED(hr) ? format : LoopbackFormat{};
    s->error = SUCCEEDED(hr) ? LoopbackError::kNone : error;
    // running 在 notify 之前置位：Start 一返回，同来源的下一次 Start 就必须看到「在跑」
    // 并共用这一路，不能把它当成已退出的旧会话。
    s->running.store(SUCCEEDED(hr));
    s->init_done = true;
  }
  s->init_cv.notify_all();

  if (FAILED(hr)) {
    release_ducking();
    if (packet_event != nullptr) {
      CloseHandle(packet_event);
    }
    if (mix != nullptr) {
      CoTaskMemFree(mix);
    }
    if (co_ok) {
      CoUninitialize();
    }
    return;
  }

  const bool float_samples = format.is_float && format.bits_per_sample == 32;
  DWORD last_duck = GetTickCount();
  DWORD last_tree = last_duck;
  std::vector<uint8_t> scratch;
  // 采集循环：按 kPollIntervalMs（或 process loopback 的包事件）拉尽所有已就绪包。
  while (!s->stop.load()) {
    if (packet_event != nullptr) {
      WaitForSingleObject(packet_event, kPollIntervalMs);
    } else {
      Sleep(kPollIntervalMs);
    }
    if (silent) {
      const DWORD now = GetTickCount();
      if (now - last_tree >= kTreeRefreshMs) {
        ducker.SetTree(target, ProcessTree(target));
        last_tree = now;
      }
      if (now - last_duck >= kDuckRescanMs) {
        ducker.DuckAll();
        last_duck = now;
      }
    }
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
          static_cast<size_t>(frames) * static_cast<size_t>(s->block_align);
      {
        std::lock_guard<std::mutex> lock(s->ring_mutex);
        if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0) {
          // 静音包：WASAPI 不保证 data 有效，按静音写零（保持时间轴连续）。
          static thread_local std::vector<uint8_t> silence;
          if (silence.size() < bytes) {
            silence.assign(bytes, 0);
          }
          RingAppendLocked(*s, silence.data(), bytes);
        } else if (data != nullptr && silent && float_samples) {
          scratch.assign(data, data + bytes);
          RestoreDuckedGain(reinterpret_cast<float*>(scratch.data()),
                            bytes / sizeof(float));
          RingAppendLocked(*s, scratch.data(), bytes);
        } else if (data != nullptr) {
          RingAppendLocked(*s, data, bytes);
        }
      }
      capture->ReleaseBuffer(frames);
      if (FAILED(capture->GetNextPacketSize(&packet))) {
        packet = 0;
      }
    }
  }

  client->Stop();
  // 先停采集再还原音量：还原那一刻的满电平样本不会进缓冲。
  release_ducking();
  s->running.store(false);
  if (packet_event != nullptr) {
    CloseHandle(packet_event);
  }
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
  StopAll();
}

LoopbackFormat AudioLoopbackCapture::Start(const LoopbackOptions& raw_options,
                                           uint64_t* lease,
                                           LoopbackError* error) {
  if (lease != nullptr) {
    *lease = 0;
  }
  if (error != nullptr) {
    *error = LoopbackError::kNone;
  }
  const LoopbackOptions options = Normalize(raw_options);
  const std::wstring key = SourceKey(options);
  std::lock_guard<std::mutex> registry(g_registry.mutex);
  uint32_t stale = 0;
  for (auto& entry : g_registry.sessions) {
    CaptureState& s = *entry.second;
    if (s.key != key) {
      continue;
    }
    if (s.options.silent != options.silent) {
      // 同一进程树一边压低会话音量、一边要原样录：两者互斥。
      if (error != nullptr) {
        *error = LoopbackError::kBusy;
      }
      return LoopbackFormat{};
    }
    if (s.running.load()) {
      LoopbackFormat fmt;
      {
        std::lock_guard<std::mutex> lock(s.init_mutex);
        fmt = s.format;
      }
      const uint64_t granted = g_registry.leases.Acquire(entry.first);
      if (lease != nullptr) {
        *lease = granted;
      }
      return fmt;
    }
    // 采集线程已自行退出（设备拔掉 / 渲染端点失效）：重起一路，旧租约迁过去。
    stale = entry.first;
    break;
  }

  auto session = std::make_unique<CaptureState>();
  session->options = options;
  session->key = key;
  CaptureState* s = session.get();
  s->thread = std::thread(CaptureThreadMain, s);
  LoopbackFormat result;
  LoopbackError result_error = LoopbackError::kNone;
  {
    std::unique_lock<std::mutex> lock(s->init_mutex);
    s->init_cv.wait(lock, [s] { return s->init_done; });
    result = s->format;
    result_error = s->error;
  }
  if (!result.ok) {
    // 初始化失败：线程已自行退出，join 释放。旧的那一路（若有）原样留着。
    if (s->thread.joinable()) {
      s->thread.join();
    }
    if (error != nullptr) {
      *error = result_error;
    }
    return LoopbackFormat{};
  }
  const uint32_t id = ++g_registry.next_session;
  if (stale != 0) {
    g_registry.leases.Rebind(stale, id);
    auto old = g_registry.sessions.find(stale);
    if (old != g_registry.sessions.end()) {
      StopSessionLocked(*old->second);
      g_registry.sessions.erase(old);
    }
    DropPinnedForSession(stale);
  }
  g_registry.sessions[id] = std::move(session);
  const uint64_t granted = g_registry.leases.Acquire(id);
  if (lease != nullptr) {
    *lease = granted;
  }
  return result;
}

void AudioLoopbackCapture::Release(uint64_t lease) {
  std::lock_guard<std::mutex> registry(g_registry.mutex);
  bool last = false;
  const uint32_t id = g_registry.leases.Release(lease, &last);
  if (id == 0 || !last) {
    // 未知 / 已交回的租约，或这一路还有别人在用：什么都不停。
    return;
  }
  auto it = g_registry.sessions.find(id);
  if (it != g_registry.sessions.end()) {
    StopSessionLocked(*it->second);
    g_registry.sessions.erase(it);
  }
  DropPinnedForSession(id);
}

void AudioLoopbackCapture::StopAll() {
  std::lock_guard<std::mutex> registry(g_registry.mutex);
  g_registry.leases.Clear();
  for (auto& entry : g_registry.sessions) {
    StopSessionLocked(*entry.second);
    DropPinnedForSession(entry.first);
  }
  g_registry.sessions.clear();
}

LoopbackFormat AudioLoopbackCapture::GrabRecent(uint64_t lease, int back_ms,
                                                std::vector<uint8_t>& out) {
  out.clear();
  std::lock_guard<std::mutex> registry(g_registry.mutex);
  const uint32_t id = g_registry.leases.SessionOf(lease);
  const auto it = g_registry.sessions.find(id);
  if (id == 0 || it == g_registry.sessions.end()) {
    return LoopbackFormat{};
  }
  return GrabFromSession(*it->second, back_ms, out);
}

uint64_t AudioLoopbackCapture::PinSnapshot(uint64_t lease, int back_ms,
                                           bool* stopped) {
  if (stopped != nullptr) {
    *stopped = false;
  }
  std::vector<uint8_t> pcm;
  LoopbackFormat fmt;
  uint32_t id = 0;
  {
    std::lock_guard<std::mutex> registry(g_registry.mutex);
    id = g_registry.leases.SessionOf(lease);
    const auto it = g_registry.sessions.find(id);
    if (id == 0 || it == g_registry.sessions.end()) {
      return 0;
    }
    if (!it->second->running.load()) {
      // 租约还在、这一路的采集线程却已退出：持有方据此重新 Start（同来源重起、租约
      // 迁过去），不让常驻的跨应用缓存从此一直交不出声音。
      if (stopped != nullptr) {
        *stopped = true;
      }
      return 0;
    }
    fmt = GrabFromSession(*it->second, back_ms, pcm);
  }
  if (!fmt.ok || pcm.empty()) {
    return 0;
  }
  std::lock_guard<std::mutex> lock(g_pinned.mutex);
  g_pinned.pcm.swap(pcm);
  g_pinned.format = fmt;
  g_pinned.session = id;
  g_pinned.id = ++g_pinned.next_id;
  return g_pinned.id;
}

LoopbackFormat AudioLoopbackCapture::SaveSnapshot(uint64_t snapshot,
                                                  const std::wstring& path) {
  std::lock_guard<std::mutex> lock(g_pinned.mutex);
  if (snapshot == 0 || snapshot != g_pinned.id || g_pinned.pcm.empty() ||
      path.empty()) {
    return LoopbackFormat{};
  }
  HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                            CREATE_ALWAYS, FILE_ATTRIBUTE_TEMPORARY, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return LoopbackFormat{};
  }
  const uint8_t* data = g_pinned.pcm.data();
  size_t remaining = g_pinned.pcm.size();
  bool ok = true;
  while (remaining > 0) {
    const DWORD chunk = static_cast<DWORD>((std::min)(
        remaining, static_cast<size_t>(16u * 1024u * 1024u)));
    DWORD written = 0;
    if (!WriteFile(file, data, chunk, &written, nullptr) || written == 0) {
      ok = false;
      break;
    }
    data += written;
    remaining -= written;
  }
  CloseHandle(file);
  if (!ok) {
    DeleteFileW(path.c_str());
    return LoopbackFormat{};
  }
  return g_pinned.format;
}

int AudioLoopbackCapture::RestoreDuckedSessions(const LoopbackOptions& options) {
  // silent 采集在跑时压低是有意的：此时「还原」会让站点从扬声器外放。
  {
    std::lock_guard<std::mutex> registry(g_registry.mutex);
    for (const auto& entry : g_registry.sessions) {
      if (entry.second->running.load() && entry.second->options.silent) {
        return 0;
      }
    }
  }
  const DWORD target = ResolveTarget(options);
  if (target == 0) {
    return 0;
  }
  const HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const int restored = RestoreResidualDuckedSessions(
      OpenRenderSessionManagers(), ProcessTree(target));
  if (SUCCEEDED(co)) {
    CoUninitialize();
  }
  return restored;
}

}  // namespace fushi
