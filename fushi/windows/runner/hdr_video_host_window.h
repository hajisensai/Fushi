#ifndef RUNNER_HDR_VIDEO_HOST_WINDOW_H_
#define RUNNER_HDR_VIDEO_HOST_WINDOW_H_

#include <windows.h>

namespace fushi {

// Windows HDR passthrough host (docs/plans/2026-08-30-video-hdr-passthrough.md
// §4.1). libmpv renders into this top-level popup with its own D3D11 swapchain
// (`vo=gpu-next --gpu-context=d3d11 --wid=<this>`), which is the only way an
// HDR / 10-bit signal can reach the display: the Flutter compositor is 8-bit
// SDR end to end. The popup is glued directly *behind* the main window; the
// main window gets DWM blur-behind with an empty region so the alpha of the
// Flutter child swapchain is honoured and whatever Flutter leaves transparent
// (the video hole) shows this window through, while every Flutter overlay on
// top of the video keeps compositing normally (Phase 0 variant 6,
// .codex-test/hdr-passthrough/RESULTS.md).
class HdrVideoHostWindow {
 public:
  explicit HdrVideoHostWindow(HWND main);
  ~HdrVideoHostWindow();

  HdrVideoHostWindow(const HdrVideoHostWindow&) = delete;
  HdrVideoHostWindow& operator=(const HdrVideoHostWindow&) = delete;

  // Creates the host popup (idempotent) and enables the main-window
  // transparency. Returns the host HWND or nullptr.
  HWND Create();

  // Video rectangle in physical pixels, relative to the main window's client
  // origin (what Flutter's localToGlobal * devicePixelRatio yields).
  void SetClientRect(int x, int y, int width, int height);

  // Re-applies position/size/z-order after the main window moved, resized,
  // (de)activated or (un)minimised. Cheap; safe to call on every such message.
  void SyncPlacement();

  // Destroys the host and restores the main window. Idempotent.
  void Destroy();

  bool IsCreated() const { return hwnd_ != nullptr; }
  HWND handle() const { return hwnd_; }

  // Window procedure of the host popup (public for the class registration).
  static LRESULT CALLBACK WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam);

 private:
  // The empty-region blur-behind recipe (GLFW transparent framebuffer, Win8+):
  // it is what makes DWM blend the main window by its alpha against the window
  // behind it. DwmExtendFrameIntoClientArea only shows the frame material.
  void SetMainTransparency(bool enable);
  void ResizeChildren();

  HWND main_;
  HWND hwnd_ = nullptr;
  RECT client_rect_ = {};
  bool has_rect_ = false;
};

// Current output colour space of the monitor the main window sits on
// (IDXGIOutput6::GetDesc1). colour_space == 12 is
// DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020 (Windows HDR on).
struct HdrDisplayInfo {
  bool valid = false;
  int color_space = -1;
  float max_luminance = 0.0f;
  unsigned bits_per_color = 0;
};
HdrDisplayInfo QueryHdrDisplayInfo(HWND main);

}  // namespace fushi

#endif  // RUNNER_HDR_VIDEO_HOST_WINDOW_H_
