#ifndef RUNNER_GAMESCOPE_OVERLAY_H_
#define RUNNER_GAMESCOPE_OVERLAY_H_

// Steam Deck Game Mode (Gamescope) support for Fushi's out-of-app windows.
// Header-only so the runner and the lookup card process (linux/lookup_card/)
// share one copy. GDK calls only, no Xlib link needed.
//
// In Game Mode, Gamescope shows one app at a time (the game). Other X windows
// on Steam's display (:0, where Fushi runs) are not drawn unless they carry one
// of Gamescope's window properties (see steamcompmgr.cpp in Gamescope):
//
//   GAMESCOPE_EXTERNAL_OVERLAY = 1   drawn above the game, full output size,
//                                    from the top-left corner, at 1:1. Never
//                                    receives input. Gamescope draws one such
//                                    window: the one with the highest
//                                    _NET_WM_WINDOW_OPACITY.
//   STEAM_OVERLAY = 1 and            the slot Steam's own overlay (the Quick
//   STEAM_INPUT_FOCUS = 1            Access menu) uses: drawn above external
//                                    overlays, scaled to fit the output, and it
//                                    receives ALL touch / mouse input while it
//                                    holds the slot. One window wins: the
//                                    highest opacity, ties go to the last one
//                                    in the window list.
//
// Gamescope does not check whether a window is mapped when it picks these, so
// a window must drop its properties when it hides (SetRole(kNone)).
//
// Fushi windows set a tiny bit less than full opacity: Steam's overlay shows
// itself at full opacity, so the Quick Access menu always wins the input slot,
// and the lookup card (kCardRank) wins over the screen OCR layer
// (kFreezeLayerRank) without the two having to coordinate.

#include <gtk/gtk.h>

#include <cstdint>

namespace fushi {
namespace gamescope {

enum Role : unsigned {
  kNone = 0,
  // Drawn above the game (external overlay). No input.
  kDraw = 1u << 0,
  // Steam overlay slot with input: every touch goes to this window. The window
  // must cover the whole output, or Gamescope scales it up.
  kInput = 1u << 1,
};

// Window opacity ranks (full opacity is 0xFFFFFFFF, Steam's own overlay).
constexpr uint32_t kFreezeLayerRank = 0xFFFFFFFDu;
constexpr uint32_t kCardRank = 0xFFFFFFFEu;

// True when this process runs inside a Gamescope session (Steam Deck Game
// Mode): Gamescope keeps GAMESCOPE_FOCUSED_APP on the root window of every X
// display it manages. Read once; a process never moves between sessions.
inline bool InGameMode() {
  static const bool in_game_mode = [] {
    GdkDisplay* display = gdk_display_get_default();
    if (display == nullptr) return false;
    GdkWindow* root = gdk_screen_get_root_window(
        gdk_display_get_default_screen(display));
    if (root == nullptr) return false;
    GdkAtom type = GDK_NONE;
    gint format = 0;
    gint length = 0;
    guchar* data = nullptr;
    const gboolean found = gdk_property_get(
        root, gdk_atom_intern_static_string("GAMESCOPE_FOCUSED_APP"),
        GDK_NONE, 0, 1, FALSE, &type, &format, &length, &data);
    g_free(data);
    return found && type != GDK_NONE;
  }();
  return in_game_mode;
}

namespace detail {

inline void SetCardinal(GdkWindow* window, const char* name, gulong value) {
  // Format 32 property data is an array of C longs (Xlib convention).
  const long data = static_cast<long>(value);
  gdk_property_change(window, gdk_atom_intern_static_string(name),
                      gdk_atom_intern_static_string("CARDINAL"), 32,
                      GDK_PROP_MODE_REPLACE,
                      reinterpret_cast<const guchar*>(&data), 1);
}

inline void Delete(GdkWindow* window, const char* name) {
  gdk_property_delete(window, gdk_atom_intern_static_string(name));
}

}  // namespace detail

// Gives |window| a Game Mode role (a combination of Role bits) with opacity
// |rank|. A no-op outside Game Mode. Realizes |window|.
inline void SetRole(GtkWidget* window, unsigned role, uint32_t rank) {
  if (window == nullptr || !InGameMode()) return;
  gtk_widget_realize(window);
  GdkWindow* gdk_window = gtk_widget_get_window(window);
  if (gdk_window == nullptr) return;
  if (role == kNone) {
    detail::Delete(gdk_window, "GAMESCOPE_EXTERNAL_OVERLAY");
    detail::Delete(gdk_window, "STEAM_OVERLAY");
    detail::Delete(gdk_window, "STEAM_INPUT_FOCUS");
  } else {
    detail::SetCardinal(gdk_window, "_NET_WM_WINDOW_OPACITY", rank);
    if (role & kDraw) {
      detail::SetCardinal(gdk_window, "GAMESCOPE_EXTERNAL_OVERLAY", 1);
    } else {
      detail::Delete(gdk_window, "GAMESCOPE_EXTERNAL_OVERLAY");
    }
    if (role & kInput) {
      detail::SetCardinal(gdk_window, "STEAM_OVERLAY", 1);
      detail::SetCardinal(gdk_window, "STEAM_INPUT_FOCUS", 1);
    } else {
      detail::Delete(gdk_window, "STEAM_OVERLAY");
      detail::Delete(gdk_window, "STEAM_INPUT_FOCUS");
    }
  }
  gdk_display_flush(gdk_window_get_display(gdk_window));
}

}  // namespace gamescope
}  // namespace fushi

#endif  // RUNNER_GAMESCOPE_OVERLAY_H_
