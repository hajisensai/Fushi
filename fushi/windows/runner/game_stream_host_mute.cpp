#include "game_stream_host_mute.h"

#include "audio_session_ducker.h"

namespace fushi {

namespace {

using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Make;

// 兜底重扫会话的间隔（新会话主要靠 IAudioSessionNotification 即时压低）。
constexpr DWORD kDuckRescanMs = 250;
// 目标进程树刷新间隔（游戏可能按需拉起子进程出声）。
constexpr ULONGLONG kTreeRefreshMs = 1000;

}  // namespace

GameStreamHostMute::~GameStreamHostMute() {
  Stop();
}

bool GameStreamHostMute::Start(DWORD pid) {
  if (pid == 0) {
    return false;
  }
  if (thread_.joinable() && pid_ == pid) {
    return true;
  }
  Stop();
  stop_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (stop_event_ == nullptr) {
    return false;
  }
  {
    std::lock_guard<std::mutex> lock(init_mutex_);
    init_done_ = false;
    init_ok_ = false;
  }
  pid_ = pid;
  thread_ = std::thread(&GameStreamHostMute::Run, this, pid);
  bool ok = false;
  {
    std::unique_lock<std::mutex> lock(init_mutex_);
    init_cv_.wait(lock, [this] { return init_done_; });
    ok = init_ok_;
  }
  if (!ok) {
    // 初始化失败时线程已自行退出。
    Stop();
  }
  return ok;
}

void GameStreamHostMute::Stop() {
  if (stop_event_ != nullptr) {
    SetEvent(stop_event_);
  }
  if (thread_.joinable()) {
    thread_.join();
  }
  if (stop_event_ != nullptr) {
    CloseHandle(stop_event_);
    stop_event_ = nullptr;
  }
  pid_ = 0;
}

int GameStreamHostMute::RestoreResidual(DWORD pid) {
  if (pid == 0 || (thread_.joinable() && pid_ == pid)) {
    return 0;
  }
  // 平台线程是 STA；会话枚举与压低线程一样放在 MTA 上做。
  int restored = 0;
  std::thread worker([pid, &restored] {
    const HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    restored = RestoreResidualDuckedSessions(OpenRenderSessionManagers(),
                                             ProcessTree(pid));
    if (SUCCEEDED(co)) {
      CoUninitialize();
    }
  });
  worker.join();
  return restored;
}

void GameStreamHostMute::Run(DWORD pid) {
  const HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  {
    SessionDucker ducker;
    ComPtr<DuckOnCreate> on_create;
    bool ok = SUCCEEDED(co);
    if (ok) {
      ducker.Open();
      ok = !ducker.managers().empty();
    }
    if (ok) {
      ducker.SetTree(pid, ProcessTree(pid));
      ducker.DuckAll();
      on_create = Make<DuckOnCreate>(&ducker);
      if (on_create != nullptr) {
        for (const auto& manager : ducker.managers()) {
          manager->RegisterSessionNotification(on_create.Get());
        }
      }
    }
    {
      std::lock_guard<std::mutex> lock(init_mutex_);
      init_ok_ = ok;
      init_done_ = true;
    }
    init_cv_.notify_all();

    if (ok) {
      ULONGLONG last_tree = GetTickCount64();
      while (WaitForSingleObject(stop_event_, kDuckRescanMs) == WAIT_TIMEOUT) {
        const ULONGLONG now = GetTickCount64();
        if (now - last_tree >= kTreeRefreshMs) {
          ducker.SetTree(pid, ProcessTree(pid));
          last_tree = now;
        }
        ducker.DuckAll();
      }
      if (on_create != nullptr) {
        for (const auto& manager : ducker.managers()) {
          manager->UnregisterSessionNotification(on_create.Get());
        }
      }
      ducker.RestoreAll();
    }
  }
  if (SUCCEEDED(co)) {
    CoUninitialize();
  }
}

}  // namespace fushi
