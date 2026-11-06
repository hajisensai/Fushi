#ifndef RUNNER_GLOBAL_LOOKUP_CHANNEL_H_
#define RUNNER_GLOBAL_LOOKUP_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>

// Linux side of the app-external global lookup (X11 sessions):
//   - `app.fushi.reader/global_lookup`: forwarded as-is to the lookup card
//     helper process (linux/lookup_card/, it explains why it is a separate
//     process), which is started on the first call and again after it dies;
//   - `app.fushi.reader/foreground_selection`: `captureSelection` answers the
//     primary selection, i.e. the text currently highlighted in whichever app
//     owns it: the compositor's (Wayland data control, wayland_selection.h)
//     when there is one, else X11 PRIMARY. Nothing is copied and the clipboard
//     is never touched.
typedef struct _FushiGlobalLookup FushiGlobalLookup;

FushiGlobalLookup* fushi_global_lookup_new(FlBinaryMessenger* messenger);
void fushi_global_lookup_free(FushiGlobalLookup* lookup);

#endif  // RUNNER_GLOBAL_LOOKUP_CHANNEL_H_
