#ifndef RUNNER_SCREEN_CAPTURE_H_
#define RUNNER_SCREEN_CAPTURE_H_

#include <gtk/gtk.h>

#include <functional>
#include <memory>
#include <string>

// Whole-monitor screenshot for the desktop floating ball's screen OCR (spec
// docs/specs/2026-09-30-desktop-system-floating-ball.md, "截屏识字").
//
// Fushi draws through X11 (XWayland on a Wayland desktop such as the Steam
// Deck's Plasma). An X client only sees X windows there, so reading the root
// window gives a black screen with the X windows on it. Two paths:
//   - Wayland session: the xdg-desktop-portal Screenshot request,
//     non-interactive. The desktop asks the user once (KDE stores the answer in
//     the permission store); afterwards it is silent (~0.35 s on the Deck). The
//     portal writes a PNG file and returns its URI; it is read, then deleted,
//     because it is our temporary capture, not a screenshot the user took.
//   - X11 session: the root window, read directly.
namespace fushi {
namespace screen_capture {

struct MonitorCapture {
  // Capture of the monitor, in physical pixels.
  std::shared_ptr<GdkPixbuf> pixbuf;
  // The monitor in physical pixels (GDK logical geometry x monitor scale), the
  // same space as the ball's anchor and the global_lookup channel.
  GdkRectangle screen{};
  std::string diagnostic;
};

// |error| is empty on success, else "permission_denied" or "capture_failed".
using CaptureDone =
    std::function<void(MonitorCapture capture, const std::string& error)>;

// True when the desktop is a Wayland session (X11 root reads are blank there).
bool IsWaylandSession();

// Captures |monitor|. |done| always runs later on the GTK main thread, exactly
// once (also for the synchronous X11 path).
void CaptureMonitor(GdkMonitor* monitor, CaptureDone done);

// Asks the compositor not to animate |window| disappearing. KWin keeps a hidden
// window on screen while its close effect fades it out (~150 ms), and the
// portal screenshot taken right after hiding the ball caught the fading button
// column. Set on every window that hides itself for a capture (ball, buttons,
// the previous freeze layer). Realizes |window|; harmless elsewhere (the
// property is a KWin hint, other compositors ignore it).
void SkipCloseAnimation(GtkWidget* window);

}  // namespace screen_capture
}  // namespace fushi

#endif  // RUNNER_SCREEN_CAPTURE_H_
