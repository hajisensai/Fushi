#include "audio_loopback_capture.h"

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
// 音量不高于它的会话视为「被我们压低过」（崩溃残留）：没人会手动把音量调到 -80 dB。
constexpr float kDuckedThreshold = kSilentDuckLevel * 10.0f;

// ── 进程树 ────────────────────────────────────────────────────────────────

// [root] 及其全部后代进程 id。
std::set<DWORD> ProcessTree(DWORD root) {
  std::set<DWORD> tree{root};
  HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snap == INVALID_HANDLE_VALUE) {
    return tree;
  }
  std::vector<std::pair<DWORD, DWORD>> edges;  // (pid, parent)
  PROCESSENTRY32W pe{};
  pe.dwSize = sizeof(pe);
  for (BOOL ok = Process32FirstW(snap, &pe); ok; ok = Process32NextW(snap, &pe)) {
    edges.emplace_back(pe.th32ProcessID, pe.th32ParentProcessID);
  }
  CloseHandle(snap);
  bool grew = true;
  while (grew) {
    grew = false;
    for (const auto& [pid, parent] : edges) {
      if (pid != parent && tree.count(parent) != 0 && tree.count(pid) == 0) {
        tree.insert(pid);
        grew = true;
      }
    }
  }
  return tree;
}

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

// ── silent：压低目标进程树的音频会话 ────────────────────────────────────────

// 一个被压低的会话：还原时写回 [original]。
struct DuckedSession {
  ComPtr<ISimpleAudioVolume> volume;
  float original = 1.0f;
};

// 对一组渲染端点上属于目标进程树的会话做「压低 / 还原」。线程安全（mutex_），因为
// IAudioSessionNotification 回调在系统线程上来。
class SessionDucker {
 public:
  // 打开全部活动渲染端点的会话管理器（Chromium 不一定渲染到默认端点）。
  void Open() {
    ComPtr<IMMDeviceEnumerator> enumerator;
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                CLSCTX_ALL, IID_PPV_ARGS(&enumerator)))) {
      return;
    }
    ComPtr<IMMDeviceCollection> devices;
    if (FAILED(enumerator->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE,
                                              &devices))) {
      return;
    }
    UINT count = 0;
    devices->GetCount(&count);
    for (UINT i = 0; i < count; ++i) {
      ComPtr<IMMDevice> device;
      ComPtr<IAudioSessionManager2> manager;
      if (SUCCEEDED(devices->Item(i, &device)) &&
          SUCCEEDED(device->Activate(
              __uuidof(IAudioSessionManager2), CLSCTX_ALL, nullptr,
              reinterpret_cast<void**>(manager.GetAddressOf())))) {
        managers_.push_back(manager);
      }
    }
  }

  void SetTree(DWORD root, std::set<DWORD> tree) {
    std::lock_guard<std::mutex> lock(mutex_);
    root_ = root;
    tree_ = std::move(tree);
  }

  // 扫一遍全部会话：树内的压到 kSilentDuckLevel（首次见到时记下原音量）。
  void DuckAll() {
    for (const auto& manager : managers_) {
      ComPtr<IAudioSessionEnumerator> sessions;
      if (FAILED(manager->GetSessionEnumerator(&sessions))) {
        continue;
      }
      int count = 0;
      sessions->GetCount(&count);
      for (int i = 0; i < count; ++i) {
        ComPtr<IAudioSessionControl> control;
        if (SUCCEEDED(sessions->GetSession(i, &control))) {
          Duck(control.Get());
        }
      }
    }
  }

  // 单个会话（扫描或新建通知）：属于目标树就压低。
  void Duck(IAudioSessionControl* control) {
    ComPtr<IAudioSessionControl2> control2;
    if (FAILED(control->QueryInterface(IID_PPV_ARGS(&control2)))) {
      return;
    }
    DWORD pid = 0;
    if (FAILED(control2->GetProcessId(&pid)) || pid == GetCurrentProcessId()) {
      // 本进程自己的会话（含采集方的 loopback 流）绝不压：实测会把回取信号再衰减一遍。
      return;
    }
    LPWSTR id_raw = nullptr;
    if (FAILED(control2->GetSessionInstanceIdentifier(&id_raw)) ||
        id_raw == nullptr) {
      return;
    }
    const std::wstring id(id_raw);
    CoTaskMemFree(id_raw);
    ComPtr<ISimpleAudioVolume> volume;
    if (FAILED(control->QueryInterface(IID_PPV_ARGS(&volume)))) {
      return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (tree_.count(pid) == 0) {
      // 没见过的 pid：可能是 Chromium 刚按需拉起的音频服务进程（建会话的回调早于下一次
      // 定时刷新树）。当场重算一次树；确认不属于目标的记进 foreign_，不再为它重算。
      if (root_ == 0 || foreign_.count(pid) != 0) {
        return;
      }
      tree_ = ProcessTree(root_);
      if (tree_.count(pid) == 0) {
        foreign_.insert(pid);
        return;
      }
    }
    auto it = ducked_.find(id);
    if (it == ducked_.end()) {
      float current = 1.0f;
      volume->GetMasterVolume(&current);
      DuckedSession entry;
      entry.volume = volume;
      // 已经停在压低值上 = 上次崩溃残留（会话音量按可执行文件持久化），还原目标取 1.0。
      entry.original = current <= kDuckedThreshold ? 1.0f : current;
      it = ducked_.emplace(id, entry).first;
    }
    float now = 0.0f;
    if (FAILED(it->second.volume->GetMasterVolume(&now)) ||
        now != kSilentDuckLevel) {
      it->second.volume->SetMasterVolume(kSilentDuckLevel, nullptr);
    }
  }

  void RestoreAll() {
    std::lock_guard<std::mutex> lock(mutex_);
    for (auto& [id, entry] : ducked_) {
      entry.volume->SetMasterVolume(entry.original, nullptr);
    }
    ducked_.clear();
  }

  const std::vector<ComPtr<IAudioSessionManager2>>& managers() const {
    return managers_;
  }

 private:
  std::vector<ComPtr<IAudioSessionManager2>> managers_;
  std::mutex mutex_;
  DWORD root_ = 0;
  std::set<DWORD> tree_;
  std::set<DWORD> foreign_;  // 已确认不属于目标树的会话进程
  std::map<std::wstring, DuckedSession> ducked_;
};

// 新会话一建立就压低（Chromium 音频服务进程按需起；等兜底扫描会漏掉开头一截）。
class DuckOnCreate
    : public RuntimeClass<RuntimeClassFlags<ClassicCom>, FtmBase,
                          IAudioSessionNotification> {
 public:
  explicit DuckOnCreate(SessionDucker* ducker) : ducker_(ducker) {}
  STDMETHOD(OnSessionCreated)(IAudioSessionControl* session) override {
    if (session != nullptr) {
      ducker_->Duck(session);
    }
    return S_OK;
  }

 private:
  SessionDucker* ducker_;
};

// ── 采集状态 ──────────────────────────────────────────────────────────────

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
  LoopbackError error = LoopbackError::kNone;
  LoopbackOptions options;  // 当前在跑的来源（Start 幂等判定用）

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

bool SameSource(const LoopbackOptions& a, const LoopbackOptions& b) {
  return a.target_pid == b.target_pid && a.silent == b.silent &&
         Lower(a.user_data_folder) == Lower(b.user_data_folder);
}

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

// silent 模式：把压低的浮点样本放大回原电平。仍高于压低后可能出现的幅度的样本说明
// 那一刻会话还没压下去（新会话与压低之间的毫秒级空窗），放大会削顶成噪声，按静音写。
void RestoreDuckedGain(float* samples, size_t count) {
  constexpr float kGain = 1.0f / kSilentDuckLevel;
  constexpr float kMaxDucked = kSilentDuckLevel * 1.5f;
  for (size_t i = 0; i < count; ++i) {
    const float s = samples[i];
    samples[i] = (s > kMaxDucked || s < -kMaxDucked) ? 0.0f : s * kGain;
  }
}

// 采集线程主体：初始化 WASAPI loopback → 握手回报格式 → 循环拉包写环形缓冲 → 收尾。
void CaptureThreadMain(LoopbackOptions options) {
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
    std::lock_guard<std::mutex> lock(g_state.init_mutex);
    g_state.format = SUCCEEDED(hr) ? format : LoopbackFormat{};
    g_state.error = SUCCEEDED(hr) ? LoopbackError::kNone : error;
    g_state.init_done = true;
  }
  g_state.init_cv.notify_all();

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

  g_state.running.store(true);
  const bool float_samples = format.is_float && format.bits_per_sample == 32;
  DWORD last_duck = GetTickCount();
  DWORD last_tree = last_duck;
  std::vector<uint8_t> scratch;
  // 采集循环：按 kPollIntervalMs（或 process loopback 的包事件）拉尽所有已就绪包。
  while (!g_state.stop.load()) {
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
        } else if (data != nullptr && silent && float_samples) {
          scratch.assign(data, data + bytes);
          RestoreDuckedGain(reinterpret_cast<float*>(scratch.data()),
                            bytes / sizeof(float));
          RingAppendLocked(scratch.data(), bytes);
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
  // 先停采集再还原音量：还原那一刻的满电平样本不会进缓冲。
  release_ducking();
  g_state.running.store(false);
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
  Stop();
}

LoopbackFormat AudioLoopbackCapture::Start(const LoopbackOptions& options,
                                           LoopbackError* error) {
  if (error != nullptr) {
    *error = LoopbackError::kNone;
  }
  if (g_state.running.load()) {
    std::lock_guard<std::mutex> lock(g_state.init_mutex);
    if (!SameSource(g_state.options, options)) {
      // galgame 的系统混音与网页制卡的进程树不能共用一路缓冲。
      if (error != nullptr) {
        *error = LoopbackError::kBusy;
      }
      return LoopbackFormat{};
    }
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
    g_state.error = LoopbackError::kNone;
    g_state.options = options;
  }
  g_state.thread = std::thread(CaptureThreadMain, options);

  std::unique_lock<std::mutex> lock(g_state.init_mutex);
  g_state.init_cv.wait(lock, [] { return g_state.init_done; });
  const LoopbackFormat result = g_state.format;
  const LoopbackError result_error = g_state.error;
  lock.unlock();
  if (!result.ok) {
    if (error != nullptr) {
      *error = result_error;
    }
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

int AudioLoopbackCapture::RestoreDuckedSessions(const LoopbackOptions& options) {
  // silent 采集在跑时压低是有意的：此时「还原」会让站点从扬声器外放。
  {
    std::lock_guard<std::mutex> lock(g_state.init_mutex);
    if (g_state.running.load() && g_state.options.silent) {
      return 0;
    }
  }
  const DWORD target = ResolveTarget(options);
  if (target == 0) {
    return 0;
  }
  const HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const std::set<DWORD> tree = ProcessTree(target);
  int restored = 0;
  {
    SessionDucker scan;
    scan.Open();
    for (const auto& manager : scan.managers()) {
      ComPtr<IAudioSessionEnumerator> sessions;
      if (FAILED(manager->GetSessionEnumerator(&sessions))) {
        continue;
      }
      int count = 0;
      sessions->GetCount(&count);
      for (int i = 0; i < count; ++i) {
        ComPtr<IAudioSessionControl> control;
        ComPtr<IAudioSessionControl2> control2;
        ComPtr<ISimpleAudioVolume> volume;
        DWORD pid = 0;
        float level = 1.0f;
        if (SUCCEEDED(sessions->GetSession(i, &control)) &&
            SUCCEEDED(control.As(&control2)) &&
            SUCCEEDED(control2->GetProcessId(&pid)) && tree.count(pid) != 0 &&
            SUCCEEDED(control.As(&volume)) &&
            SUCCEEDED(volume->GetMasterVolume(&level)) &&
            level <= kDuckedThreshold) {
          volume->SetMasterVolume(1.0f, nullptr);
          ++restored;
        }
      }
    }
  }
  if (SUCCEEDED(co)) {
    CoUninitialize();
  }
  return restored;
}

}  // namespace fushi
