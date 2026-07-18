#ifndef RUNNER_WINDOW_CAPTURE_H_
#define RUNNER_WINDOW_CAPTURE_H_

#include <windows.h>

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace hibiki {

struct ExternalWindow {
  HWND hwnd = nullptr;
  DWORD process_id = 0;
  std::string title;
  std::string executable_path;
};

struct WindowCaptureResult {
  std::vector<uint8_t> png;
  std::string error;
  bool ok = false;
};

// Enumerates visible, named top-level windows except [self].
std::vector<ExternalWindow> EnumerateTopLevelWindows(HWND self);

// Captures one Windows.Graphics.Capture frame on the current UI
// DispatcherQueue and encodes it as PNG. The callback runs exactly once on the
// calling thread. Failures return an empty PNG and a non-empty error.
using WindowCaptureCallback = std::function<void(WindowCaptureResult)>;
void CaptureWindowPngAsync(HWND hwnd, WindowCaptureCallback callback);

}  // namespace hibiki

#endif  // RUNNER_WINDOW_CAPTURE_H_
