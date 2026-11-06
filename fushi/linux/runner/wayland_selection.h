#ifndef RUNNER_WAYLAND_SELECTION_H_
#define RUNNER_WAYLAND_SELECTION_H_

#include <optional>
#include <string>

// The compositor's primary selection (the text highlighted in ANY app, Wayland
// or XWayland), read through ext-data-control-v1 on its own short-lived Wayland
// connection. Fushi itself runs on X11 (XWayland), and KWin only copies a
// Wayland app's selection into X11 when an X11 window has focus; the floating
// ball never takes focus, so X11 PRIMARY stays empty for text selected in
// Konsole, Firefox, etc. Data control is how clipboard managers read the
// selection without focus.
//
// Blocking (round trips + reading the source app's pipe, each bounded by
// |timeout_ms|): call it off the main thread. nullopt = no Wayland display or
// no data-control support (fall back to X11 PRIMARY); "" = nothing selected.
std::optional<std::string> ReadWaylandPrimarySelection(int timeout_ms);

#endif  // RUNNER_WAYLAND_SELECTION_H_
