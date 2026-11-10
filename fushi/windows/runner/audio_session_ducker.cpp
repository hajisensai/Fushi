#include "audio_session_ducker.h"

#include <tlhelp32.h>

#include <utility>

namespace fushi {

using Microsoft::WRL::ComPtr;

namespace {

// 会话所属进程 id；拿不到回 0。
DWORD SessionProcessId(IAudioSessionControl* control) {
  ComPtr<IAudioSessionControl2> control2;
  DWORD pid = 0;
  if (FAILED(control->QueryInterface(IID_PPV_ARGS(&control2))) ||
      FAILED(control2->GetProcessId(&pid))) {
    return 0;
  }
  return pid;
}

// 对 [managers] 上的每个会话调 [visit]。
template <typename Visit>
void ForEachSession(const std::vector<ComPtr<IAudioSessionManager2>>& managers,
                    Visit visit) {
  for (const auto& manager : managers) {
    ComPtr<IAudioSessionEnumerator> sessions;
    if (FAILED(manager->GetSessionEnumerator(&sessions))) {
      continue;
    }
    int count = 0;
    sessions->GetCount(&count);
    for (int i = 0; i < count; ++i) {
      ComPtr<IAudioSessionControl> control;
      if (SUCCEEDED(sessions->GetSession(i, &control))) {
        visit(control.Get());
      }
    }
  }
}

}  // namespace

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

std::vector<ComPtr<IAudioSessionManager2>> OpenRenderSessionManagers() {
  std::vector<ComPtr<IAudioSessionManager2>> managers;
  ComPtr<IMMDeviceEnumerator> enumerator;
  if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                              CLSCTX_ALL, IID_PPV_ARGS(&enumerator)))) {
    return managers;
  }
  ComPtr<IMMDeviceCollection> devices;
  if (FAILED(enumerator->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE,
                                            &devices))) {
    return managers;
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
      managers.push_back(manager);
    }
  }
  return managers;
}

int RestoreResidualDuckedSessions(
    const std::vector<ComPtr<IAudioSessionManager2>>& managers,
    const std::set<DWORD>& tree) {
  int restored = 0;
  ForEachSession(managers, [&](IAudioSessionControl* control) {
    const DWORD pid = SessionProcessId(control);
    ComPtr<ISimpleAudioVolume> volume;
    float level = 1.0f;
    if (pid != 0 && tree.count(pid) != 0 &&
        SUCCEEDED(control->QueryInterface(IID_PPV_ARGS(&volume))) &&
        SUCCEEDED(volume->GetMasterVolume(&level)) && IsDuckedVolume(level)) {
      volume->SetMasterVolume(1.0f, nullptr);
      ++restored;
    }
  });
  return restored;
}

// ── SessionDucker ─────────────────────────────────────────────────────────

void SessionDucker::SetTree(DWORD root, std::set<DWORD> tree) {
  std::lock_guard<std::mutex> lock(mutex_);
  root_ = root;
  tree_ = std::move(tree);
}

void SessionDucker::DuckAll() {
  ForEachSession(managers_, [this](IAudioSessionControl* control) {
    Duck(control);
  });
}

void SessionDucker::Duck(IAudioSessionControl* control) {
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
    // 没见过的 pid：可能是目标刚按需拉起的音频进程（建会话的回调早于下一次定时刷新
    // 树）。当场重算一次树；确认不属于目标的记进 foreign_，不再为它重算。
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
    entry.original = IsDuckedVolume(current) ? 1.0f : current;
    it = ducked_.emplace(id, entry).first;
  }
  float now = 0.0f;
  if (FAILED(it->second.volume->GetMasterVolume(&now)) ||
      now != kSilentDuckLevel) {
    it->second.volume->SetMasterVolume(kSilentDuckLevel, nullptr);
  }
}

void SessionDucker::RestoreAll() {
  std::lock_guard<std::mutex> lock(mutex_);
  for (auto& [id, entry] : ducked_) {
    entry.volume->SetMasterVolume(entry.original, nullptr);
  }
  ducked_.clear();
}

// ── DuckedTreeProbe ───────────────────────────────────────────────────────

void DuckedTreeProbe::Open(DWORD root) {
  root_ = root;
  managers_ = OpenRenderSessionManagers();
  Refresh();
}

void DuckedTreeProbe::Refresh() {
  volumes_.clear();
  if (root_ == 0) {
    return;
  }
  const std::set<DWORD> tree = ProcessTree(root_);
  const DWORD self = GetCurrentProcessId();
  ForEachSession(managers_, [&](IAudioSessionControl* control) {
    const DWORD pid = SessionProcessId(control);
    ComPtr<ISimpleAudioVolume> volume;
    if (pid != 0 && pid != self && tree.count(pid) != 0 &&
        SUCCEEDED(control->QueryInterface(IID_PPV_ARGS(&volume)))) {
      volumes_.push_back(volume);
    }
  });
}

bool DuckedTreeProbe::Ducked() const {
  // 压低方对整棵树的会话一视同仁，任一会话停在压低值上即视为整路已压低。
  for (const auto& volume : volumes_) {
    float level = 1.0f;
    if (SUCCEEDED(volume->GetMasterVolume(&level)) && IsDuckedVolume(level)) {
      return true;
    }
  }
  return false;
}

void DuckedTreeProbe::Close() {
  volumes_.clear();
  managers_.clear();
  root_ = 0;
}

}  // namespace fushi
