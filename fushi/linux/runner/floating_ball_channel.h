#ifndef RUNNER_FLOATING_BALL_CHANNEL_H_
#define RUNNER_FLOATING_BALL_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// `app.fushi.reader/floating_ball` on Linux: the desktop system floating ball
// (contract: docs/specs/2026-09-30-desktop-system-floating-ball.md, same methods
// and arguments as the Windows runner). Works on X11 sessions; on Wayland
// startSystemBall answers false (no positioning of own windows there).
typedef struct _FushiFloatingBall FushiFloatingBall;

// |main_window| picks the monitor the ball first appears on (weak reference).
FushiFloatingBall* fushi_floating_ball_new(FlBinaryMessenger* messenger,
                                           GtkWindow* main_window);
void fushi_floating_ball_free(FushiFloatingBall* ball);

#endif  // RUNNER_FLOATING_BALL_CHANNEL_H_
