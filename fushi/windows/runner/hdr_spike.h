#ifndef RUNNER_HDR_SPIKE_H_
#define RUNNER_HDR_SPIKE_H_

#include <windows.h>

namespace fushi {

// Phase 0 spike for docs/plans/2026-08-30-video-hdr-passthrough.md §3.
// NOT shipped behaviour: everything here is gated on the FUSHI_HDR_SPIKE
// environment variable, whose value selects the transparency variant under
// test. The question answered is "can the Flutter child swapchain's alpha
// reach DWM so that a top-level window sitting directly *behind* the main
// window shows through wherever Flutter paints nothing?".
//
//  1 = DwmExtendFrameIntoClientArea(-1) on the main window
//  2 = 1 + WS_EX_LAYERED / LWA_ALPHA(255) on the main window
//  3 = 2 + WS_EX_LAYERED / LWA_ALPHA(255) on the Flutter child HWND
//  4 = WS_EX_LAYERED / LWA_COLORKEY(magenta) on the main window
//      (the Dart spike tree paints magenta in the "video" hole)
//  5 = 4 applied to the Flutter child HWND instead of the main window
class HdrSpike {
 public:
  // 0 = spike disabled (default for every real launch).
  static int Variant();
  static void Start(HWND main, HWND flutter_child);
  // Keep the probe window glued to the main window's client rect and
  // immediately below it in z-order.
  static void Sync(HWND main);
  static void Stop();
  // Logs WM_WINDOWPOSCHANGING/CHANGED parameters + the current ex-style, to
  // find out who strips WS_EX_TOPMOST from the main window.
  static void TraceWindowPos(HWND main, UINT message, const WINDOWPOS* pos);
};

}  // namespace fushi

#endif  // RUNNER_HDR_SPIKE_H_
