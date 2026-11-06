#ifndef RUNNER_MAIN_SURFACE_COMPOSITION_H_
#define RUNNER_MAIN_SURFACE_COMPOSITION_H_

#include <windows.h>
#include <uxtheme.h>

namespace fushi {

// How DWM composes the main window's own surface is decided in one place
// (BUG-2964). A system backdrop (Windows 11 Mica) needs the surface to be
// see-through: the frame is extended over the whole client area so
// transparent Flutter pixels reveal the Mica material.
//
// (The HDR video passthrough used to be the second see-through feature: a
// libmpv host window glued behind the main window, revealed by DWM
// blur-behind. HDR now renders inside Flutter's own swap chain, see
// docs/specs/2026-10-06-hdr-in-flutter-compositor.md, and that host window is
// gone together with its frame-margin and non-client-rendering special cases.)
//
// GDI paints the surface with alpha 0, which DWM composes as premultiplied
// colour: a theme-coloured fill is *added* to whatever shows through (measured
// blue fill over a red host = magenta). A see-through surface must therefore
// be filled with black, the only colour that is transparent at alpha 0.
struct MainSurfaceState {
  bool system_backdrop = false;
};

inline bool MainSurfaceSeeThrough(const MainSurfaceState& state) {
  return state.system_backdrop;
}

// DwmExtendFrameIntoClientArea margins for |state|.
inline MARGINS MainFrameMargins(const MainSurfaceState& state) {
  if (state.system_backdrop) {
    return MARGINS{-1, -1, -1, -1};
  }
  // window_manager's hidden-title-bar shadow: 1 px at the top. Zero would drop
  // the shadow; -1 would make pure-black (AMOLED) themes see-through glass.
  return MARGINS{0, 0, 1, 0};
}

}  // namespace fushi

#endif  // RUNNER_MAIN_SURFACE_COMPOSITION_H_
