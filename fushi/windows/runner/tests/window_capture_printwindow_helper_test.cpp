#undef NDEBUG
#include <windows.h>

#include <cstdlib>
#include <cstdio>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr wchar_t kProbeModeVariable[] = L"FUSHI_PRINTWINDOW_PROBE_MODE";
constexpr wchar_t kHangMode[] = L"hang";
constexpr wchar_t kNormalMode[] = L"normal";
constexpr wchar_t kClassName[] = L"FushiPrintWindowHelperGate";
constexpr UINT kProbeHangMessage = WM_APP + 1;

BOOL FushiProbePrintWindow(HWND hwnd, HDC dc, UINT /*flags*/) {
  if (wcsstr(GetCommandLineW(), L"--fushi-print-window-helper") != nullptr) {
    wchar_t mode[32] = {};
    const DWORD length = GetEnvironmentVariableW(
        kProbeModeVariable, mode,
        static_cast<DWORD>(sizeof(mode) / sizeof(mode[0])));
    if (length > 0 && length < sizeof(mode) / sizeof(mode[0]) &&
        wcscmp(mode, kHangMode) == 0) {
      SendMessageW(hwnd, kProbeHangMessage,
                   static_cast<WPARAM>(GetCurrentProcessId()), 0);
      return FALSE;
    }
    // This target is the synthetic lifecycle gate. Keep its pixels
    // deterministic and leave the real user32 smoke to the separate probe;
    // the production path still passes the original flags to PrintWindow.
    RECT client{};
    GetClientRect(hwnd, &client);
    HBRUSH brush = CreateSolidBrush(RGB(24, 68, 120));
    FillRect(dc, &client, brush);
    DeleteObject(brush);
    return TRUE;
  }
  return FALSE;
}

}  // namespace

#define PrintWindow FushiProbePrintWindow
#include "../window_capture.cpp"
#undef PrintWindow

namespace fushi {

WindowCaptureResult CapturePrintWindowForTest(HWND hwnd) {
  WindowCaptureResult result;
  TryCapturePrintWindow(hwnd, &result);
  return result;
}

}  // namespace fushi

namespace {

HANDLE g_ready = nullptr;
HANDLE g_helper_seen = nullptr;
HANDLE g_target_hang_finished = nullptr;
HANDLE g_helper_process = nullptr;
HWND g_window = nullptr;

void Check(bool condition, const char* message) {
  if (!condition) {
    std::fprintf(stderr, "%s\n", message);
    std::exit(EXIT_FAILURE);
  }
}

LRESULT CALLBACK ProbeWindowProc(HWND hwnd, UINT message, WPARAM wparam,
                                 LPARAM lparam) {
  switch (message) {
    case WM_PRINT:
    case WM_PRINTCLIENT: {
      RECT client{};
      GetClientRect(hwnd, &client);
      HBRUSH brush = CreateSolidBrush(RGB(24, 68, 120));
      FillRect(reinterpret_cast<HDC>(wparam), &client, brush);
      DeleteObject(brush);
      return 1;
    }
    case kProbeHangMessage:
      if (g_helper_process != nullptr) {
        CloseHandle(g_helper_process);
        g_helper_process = nullptr;
      }
      g_helper_process = OpenProcess(SYNCHRONIZE, FALSE,
                                     static_cast<DWORD>(wparam));
      SetEvent(g_helper_seen);
      Sleep(1400);
      SetEvent(g_target_hang_finished);
      return 1;
    case WM_CLOSE:
      DestroyWindow(hwnd);
      return 0;
    case WM_DESTROY:
      PostQuitMessage(0);
      return 0;
    default:
      return DefWindowProcW(hwnd, message, wparam, lparam);
  }
}

void ProbeWindowThread() {
  WNDCLASSW window_class{};
  window_class.hInstance = GetModuleHandleW(nullptr);
  window_class.lpfnWndProc = &ProbeWindowProc;
  window_class.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
  window_class.lpszClassName = kClassName;
  RegisterClassW(&window_class);
  g_window = CreateWindowExW(
      WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, kClassName,
      L"PrintWindow helper gate", WS_POPUP, -32000, -32000, 640, 420,
      nullptr, nullptr, window_class.hInstance, nullptr);
  Check(g_window != nullptr, "probe window creation failed");
  ShowWindow(g_window, SW_SHOWNOACTIVATE);
  UpdateWindow(g_window);
  SetEvent(g_ready);
  MSG message{};
  while (GetMessageW(&message, nullptr, 0, 0) > 0) {
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }
}

}  // namespace

namespace {

// Same position-dependent sentinel the helper writes before PrintWindow.
std::vector<uint8_t> SentinelBuffer(UINT width, UINT height) {
  std::vector<uint8_t> bytes(static_cast<size_t>(width) * height * 4u);
  for (size_t i = 0; i < bytes.size(); ++i) {
    bytes[i] = static_cast<uint8_t>(0xA5u ^ (i & 0x3Fu));
  }
  return bytes;
}

void PaintBlock(std::vector<uint8_t>* bytes, UINT width, UINT left, UINT top,
                UINT right, UINT bottom, uint8_t blue, uint8_t green,
                uint8_t red) {
  for (UINT y = top; y < bottom; ++y) {
    for (UINT x = left; x < right; ++x) {
      const size_t i = (static_cast<size_t>(y) * width + x) * 4u;
      (*bytes)[i] = blue;
      (*bytes)[i + 1] = green;
      (*bytes)[i + 2] = red;
      (*bytes)[i + 3] = 0;
    }
  }
}

fushi::PrintWindowWorkerStatus Classify(std::vector<uint8_t>* bytes,
                                        UINT width, UINT height,
                                        UINT native_width, UINT native_height,
                                        fushi::PrintWindowPaintedRegion* region) {
  return fushi::ValidatePrintWindowPixels(bytes->data(), bytes->size(), width,
                                          height, native_width, native_height,
                                          region);
}

// BUG: a DPI-unaware VCL form at 300% scaling. The capture process measures
// the physical client (36x27 here), the window itself renders its logical
// client (12x9), and PrintWindow paints only that top-left block. That frame
// is complete in the window's own coordinate space, not "partial".
void CheckDpiVirtualizedPixelLayouts() {
  using fushi::PrintWindowPaintedRegion;
  using fushi::PrintWindowWorkerStatus;
  constexpr UINT kWidth = 36;
  constexpr UINT kHeight = 27;
  constexpr UINT kNativeWidth = 12;
  constexpr UINT kNativeHeight = 9;

  {
    std::vector<uint8_t> bytes = SentinelBuffer(kWidth, kHeight);
    PaintBlock(&bytes, kWidth, 0, 0, kWidth, kHeight, 10, 20, 30);
    PrintWindowPaintedRegion region;
    Check(Classify(&bytes, kWidth, kHeight, kNativeWidth, kNativeHeight,
                   &region) == PrintWindowWorkerStatus::kComplete &&
              region.width == kWidth && region.height == kHeight,
          "a full physical paint must stay a complete physical frame");
  }
  {
    std::vector<uint8_t> bytes = SentinelBuffer(kWidth, kHeight);
    PaintBlock(&bytes, kWidth, 0, 0, kNativeWidth, kNativeHeight, 10, 20, 30);
    PrintWindowPaintedRegion region;
    Check(Classify(&bytes, kWidth, kHeight, kNativeWidth, kNativeHeight,
                   &region) == PrintWindowWorkerStatus::kComplete,
          "a full native-size paint of a DPI-virtualized window was rejected");
    Check(region.width == kNativeWidth && region.height == kNativeHeight &&
              region.painted_right == kNativeWidth &&
              region.painted_bottom == kNativeHeight,
          "native-size paint must report the native image region");
    Check(bytes[3] == 0xFF, "accepted pixels must be normalized to opaque");
  }
  {
    // Same top-left block, but the window's own client is the physical one:
    // this is a genuinely partial paint and must stay rejected.
    std::vector<uint8_t> bytes = SentinelBuffer(kWidth, kHeight);
    PaintBlock(&bytes, kWidth, 0, 0, kNativeWidth, kNativeHeight, 10, 20, 30);
    PrintWindowPaintedRegion region;
    Check(Classify(&bytes, kWidth, kHeight, kWidth, kHeight, &region) ==
                  PrintWindowWorkerStatus::kPartialPixels &&
              region.width == 0 && region.painted_right == kNativeWidth,
          "a top-left paint of a non-virtualized client must stay partial");
  }
  {
    std::vector<uint8_t> bytes = SentinelBuffer(kWidth, kHeight);
    PaintBlock(&bytes, kWidth, 0, 0, kNativeWidth, kNativeHeight, 10, 20, 30);
    PaintBlock(&bytes, kWidth, kNativeWidth, 0, kNativeWidth + 1, 1, 10, 20,
               30);
    PrintWindowPaintedRegion region;
    Check(Classify(&bytes, kWidth, kHeight, kNativeWidth, kNativeHeight,
                   &region) == PrintWindowWorkerStatus::kPartialPixels,
          "paint leaking outside the native client must stay partial");
  }
  {
    std::vector<uint8_t> bytes = SentinelBuffer(kWidth, kHeight);
    PaintBlock(&bytes, kWidth, 0, 1, kNativeWidth, kNativeHeight, 10, 20, 30);
    PrintWindowPaintedRegion region;
    Check(Classify(&bytes, kWidth, kHeight, kNativeWidth, kNativeHeight,
                   &region) == PrintWindowWorkerStatus::kPartialPixels,
          "a native client with unpainted rows must stay partial");
  }
  {
    std::vector<uint8_t> bytes = SentinelBuffer(kWidth, kHeight);
    PrintWindowPaintedRegion region;
    Check(Classify(&bytes, kWidth, kHeight, kNativeWidth, kNativeHeight,
                   &region) == PrintWindowWorkerStatus::kNoPixels,
          "an untouched buffer must report no pixels");
  }
  {
    std::vector<uint8_t> bytes = SentinelBuffer(kWidth, kHeight);
    PaintBlock(&bytes, kWidth, 0, 0, kNativeWidth, kNativeHeight, 0, 0, 0);
    PrintWindowPaintedRegion region;
    Check(Classify(&bytes, kWidth, kHeight, kNativeWidth, kNativeHeight,
                   &region) == PrintWindowWorkerStatus::kTransparentPixels,
          "an all-black native paint must not be accepted as a frame");
  }
  {
    std::vector<uint8_t> bytes = SentinelBuffer(kWidth, kHeight);
    PaintBlock(&bytes, kWidth, 0, 0, kNativeWidth, kNativeHeight, 10, 20, 30);
    PrintWindowPaintedRegion region;
    Check(Classify(&bytes, kWidth, kHeight, kNativeWidth, kNativeHeight,
                   &region) == PrintWindowWorkerStatus::kComplete,
          "native paint fixture invalid");
    const std::vector<uint8_t> scaled = fushi::ScaleBgraRegion(
        bytes.data(), region.width, region.height, kWidth * 4u, kWidth,
        kHeight);
    Check(scaled.size() == static_cast<size_t>(kWidth) * kHeight * 4u,
          "native paint was not scaled to the physical client");
    for (size_t i = 0; i < scaled.size(); i += 4) {
      Check(scaled[i] == 10 && scaled[i + 1] == 20 && scaled[i + 2] == 30 &&
                scaled[i + 3] == 0xFF,
            "scaled physical frame must contain only native client pixels");
    }
  }
}

}  // namespace

int main() {
  const int helper_exit = fushi::RunPrintWindowCaptureHelperIfRequested();
  if (helper_exit >= 0) {
    return helper_exit;
  }

  g_ready = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  Check(g_ready != nullptr, "probe ready event creation failed");
  g_helper_seen = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  g_target_hang_finished = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  Check(g_helper_seen != nullptr && g_target_hang_finished != nullptr,
        "probe lifecycle event creation failed");
  Check(SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED)),
        "probe COM initialization failed");
  CheckDpiVirtualizedPixelLayouts();
  std::thread window_thread(ProbeWindowThread);
  Check(WaitForSingleObject(g_ready, 2000) == WAIT_OBJECT_0 &&
            g_window != nullptr,
        "probe window did not become ready");

  SetEnvironmentVariableW(kProbeModeVariable, kNormalMode);
  fushi::WindowCaptureResult normal =
      fushi::CapturePrintWindowForTest(g_window);
  Check(normal.ok,
        "cross-process PrintWindow capture failed");
  Check(normal.ok && !normal.png.empty() &&
            normal.capture_reason == "printwindow_complete",
        "cross-process helper returned an invalid frame");

  SetEnvironmentVariableW(kProbeModeVariable, kHangMode);
  fushi::WindowCaptureResult timeout =
      fushi::CapturePrintWindowForTest(g_window);
  Check(!timeout.ok,
        "hung helper unexpectedly succeeded");
  Check(timeout.diagnostics.find(
            "PrintWindow timed out; helper process terminated") !=
            std::string::npos,
        "timeout did not terminate the helper process");
  Check(WaitForSingleObject(g_helper_seen, 1000) == WAIT_OBJECT_0 &&
            g_helper_process != nullptr,
        "helper PID was not observed by the target");
  Check(WaitForSingleObject(g_helper_process, 1000) == WAIT_OBJECT_0,
        "timed out helper process remained alive");

  // Wait for the synthetic target to leave its deliberate callback before the
  // retry, so the retry tests only the capture gate/resource lifecycle.
  Check(WaitForSingleObject(g_target_hang_finished, 2000) == WAIT_OBJECT_0,
        "probe target did not finish its deliberate callback");
  SetEnvironmentVariableW(kProbeModeVariable, kNormalMode);
  fushi::WindowCaptureResult after_timeout =
      fushi::CapturePrintWindowForTest(g_window);
  Check(after_timeout.ok,
        "capture gate remained busy after helper termination");
  Check(after_timeout.ok && !after_timeout.png.empty(),
        "post-timeout helper returned an invalid frame");

  PostMessageW(g_window, WM_CLOSE, 0, 0);
  window_thread.join();
  if (g_helper_process != nullptr) {
    CloseHandle(g_helper_process);
    g_helper_process = nullptr;
  }
  CloseHandle(g_ready);
  CloseHandle(g_helper_seen);
  CloseHandle(g_target_hang_finished);
  CoUninitialize();
  std::puts("printwindow helper lifecycle: IPC, timeout cleanup, and retry passed");
  return EXIT_SUCCESS;
}
