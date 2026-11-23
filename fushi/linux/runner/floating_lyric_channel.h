#ifndef RUNNER_FLOATING_LYRIC_CHANNEL_H_
#define RUNNER_FLOATING_LYRIC_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// `app.fushi.reader/floating_lyric` on Linux: audiobook floating subtitles and
// music desktop lyrics (contract: fushi/lib/src/media/audiobook/
// floating_lyric_channel.dart, same methods and arguments as the Windows and
// macOS runners). The window and its X11 / layer-shell / Wayland-toplevel
// back-ends are in floating_lyric_window.h.
//
// With FUSHI_TEST_FLOATING_LYRIC set, `app.fushi.test/floating_lyric` is
// registered too (probe / clickChar / dragBy / toolbarAction / snapshot) for
// integration_test/linux_floating_lyric_itest.dart; production starts never
// expose it.
typedef struct _FushiFloatingLyric FushiFloatingLyric;

// |main_window| picks the monitor the window first appears on (weak reference).
FushiFloatingLyric* fushi_floating_lyric_new(FlBinaryMessenger* messenger,
                                             GtkWindow* main_window);
void fushi_floating_lyric_free(FushiFloatingLyric* lyric);

#endif  // RUNNER_FLOATING_LYRIC_CHANNEL_H_
