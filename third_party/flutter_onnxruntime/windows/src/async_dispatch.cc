// Hibiki fork: see async_dispatch.h.

#include "async_dispatch.h"

#include <string>

namespace flutter_onnxruntime {

namespace {

constexpr UINT kDispatchMessage = WM_USER + 0x4F52; // 'OR'
constexpr wchar_t kWindowClassName[] = L"FlutterOnnxruntimeDispatchWindow";

} // namespace

// ── WorkQueue ────────────────────────────────────────────────────────────────

WorkQueue::WorkQueue(const char *name) : thread_([this, name = std::string(name)]() {
  // Best-effort thread naming for debuggers; failure is irrelevant.
  std::wstring wide(name.begin(), name.end());
  SetThreadDescription(GetCurrentThread(), wide.c_str());
  Run();
}) {}

WorkQueue::~WorkQueue() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    stopping_ = true;
  }
  cv_.notify_all();
  if (thread_.joinable()) {
    thread_.join();
  }
}

bool WorkQueue::Post(std::function<void()> task) {
  if (PlatformThreadDispatcher::SyncModeRequested()) {
    task();
    return true;
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopping_) {
      return false;
    }
    tasks_.push_back(std::move(task));
  }
  cv_.notify_one();
  return true;
}

void WorkQueue::Run() {
  for (;;) {
    std::function<void()> task;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      cv_.wait(lock, [this] { return stopping_ || !tasks_.empty(); });
      if (stopping_ && tasks_.empty()) {
        return;
      }
      task = std::move(tasks_.front());
      tasks_.pop_front();
    }
    task();
  }
}

// ── PlatformThreadDispatcher ─────────────────────────────────────────────────

PlatformThreadDispatcher::PlatformThreadDispatcher() {
  WNDCLASSEXW wc = {};
  wc.cbSize = sizeof(wc);
  wc.lpfnWndProc = &PlatformThreadDispatcher::WndProc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = kWindowClassName;
  // Registering twice (plugin re-registered in the same process) is harmless:
  // ERROR_CLASS_ALREADY_EXISTS just means the earlier registration is reused.
  RegisterClassExW(&wc);
  hwnd_ = CreateWindowExW(0, kWindowClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, wc.hInstance, nullptr);
}

PlatformThreadDispatcher::~PlatformThreadDispatcher() {
  if (hwnd_ != nullptr) {
    DestroyWindow(hwnd_);
    hwnd_ = nullptr;
  }
}

// static
bool PlatformThreadDispatcher::SyncModeRequested() {
  static const bool sync = [] {
    wchar_t buffer[8] = {};
    DWORD n = GetEnvironmentVariableW(L"FLUTTER_ONNXRUNTIME_SYNC", buffer, 8);
    return n > 0 && n < 8 && buffer[0] == L'1';
  }();
  return sync;
}

void PlatformThreadDispatcher::Post(std::function<void()> callback) {
  if (SyncModeRequested() || hwnd_ == nullptr) {
    // No dispatcher window (creation failed): run inline rather than drop the
    // reply. This only happens in pathological environments and keeps the
    // caller from hanging forever on a Future that never completes.
    callback();
    return;
  }
  auto *boxed = new std::function<void()>(std::move(callback));
  if (!PostMessageW(hwnd_, kDispatchMessage, 0, reinterpret_cast<LPARAM>(boxed))) {
    delete boxed;
  }
}

// static
LRESULT CALLBACK PlatformThreadDispatcher::WndProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == kDispatchMessage) {
    auto *boxed = reinterpret_cast<std::function<void()> *>(lparam);
    if (boxed != nullptr) {
      (*boxed)();
      delete boxed;
    }
    return 0;
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

} // namespace flutter_onnxruntime
