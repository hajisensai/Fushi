#ifndef RUNNER_MAIN_SURFACE_COMPOSITION_H_
#define RUNNER_MAIN_SURFACE_COMPOSITION_H_

#include <windows.h>
#include <uxtheme.h>

namespace fushi {

// How DWM composes the main window's own surface is decided in one place
// (BUG-2964). Two features need that surface to be see-through and they used
// to configure DWM independently:
//
// - a system backdrop (Windows 11 Mica): the frame is extended over the whole
//   client area so transparent Flutter pixels reveal the Mica material;
// - the HDR video passthrough (hdr_video_host_window.h): DWM blur-behind makes
//   transparent Flutter pixels reveal the libmpv host window glued behind the
//   main window.
//
// Measured (Windows 11 26200, blur-behind on): any client pixel DWM treats as
// frame is drawn with the frame / caption material, opaque, on top of whatever
// the blur-behind would reveal. The plain hidden-title-bar margins {0,0,1,0}
// therefore turned client row 0 into a one-pixel DWMWA_CAPTION_COLOR line
// across the top of every HDR picture, and Mica's {-1} margins would fill the
// whole video hole with Mica. While the passthrough is live the frame must not
// extend into the client area at all.
//
// GDI paints the surface with alpha 0, which DWM composes as premultiplied
// colour: a theme-coloured fill is *added* to whatever shows through (measured
// blue fill over a red host = magenta). A see-through surface must therefore
// be filled with black, the only colour that is transparent at alpha 0.
//
// The DWM window shadow is composed *behind* the window. The hidden-title-bar
// frame leaves only 1 px of non-client area at the top, so the shadow reaches
// under client row 0; opaque app pixels hide it, see-through ones reveal it
// (measured: the passthrough picture's top row 8-17 % darker). Turning DWM
// non-client rendering off removes the shadow, but would draw the classic
// frame instead — invisible only while the frame hangs off-screen, i.e. in
// the runner's fullscreen. Windowed, the opaque caption row covers row 0, so
// nothing needs to change there. Measured: toggling the policy never dropped
// the child (Flutter) layer for a composition (10 toggles, 202 samples).
struct MainSurfaceState {
  bool system_backdrop = false;
  bool video_passthrough = false;
  bool fullscreen = false;
};

inline bool MainSurfaceSeeThrough(const MainSurfaceState& state) {
  return state.system_backdrop || state.video_passthrough;
}

// Whether DWM non-client rendering (and with it the window shadow) is off.
inline bool MainSurfaceNcRenderingDisabled(const MainSurfaceState& state) {
  return state.video_passthrough && state.fullscreen;
}

// DwmExtendFrameIntoClientArea margins for |state|.
inline MARGINS MainFrameMargins(const MainSurfaceState& state) {
  if (state.video_passthrough) {
    return MARGINS{0, 0, 0, 0};
  }
  if (state.system_backdrop) {
    return MARGINS{-1, -1, -1, -1};
  }
  // window_manager's hidden-title-bar shadow: 1 px at the top. Zero would drop
  // the shadow; -1 would make pure-black (AMOLED) themes see-through glass.
  return MARGINS{0, 0, 1, 0};
}

}  // namespace fushi

#endif  // RUNNER_MAIN_SURFACE_COMPOSITION_H_
