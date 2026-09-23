#include <windows.h>

#include <cstdlib>
#include <cstdio>
#include <string>
#include <thread>

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
