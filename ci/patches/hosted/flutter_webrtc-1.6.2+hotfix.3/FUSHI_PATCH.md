# Fushi Windows game-window capture patch

This exact-version override preserves the upstream desktop path and propagates
`RTCDesktopCapturer::Start` failure while cleaning up allocated audio/video tracks.

Fushi Windows defines `FUSHI_GAME_STREAM_WGC` and adds the app-owned
`game_stream_webrtc_capture.cpp` adapter to the plugin target. Only the explicit
`video.fushiClientArea` constraint selects it. It feeds a custom WebRTC video source
from Windows.Graphics.Capture, using the captured texture's real row pitch and
cropping to the target client area. The existing plugin capturer map owns WGC and
application loopback audio, so normal track/stream disposal stops both.

Why: the pinned libwebrtc Windows desktop conversion uses `GetWindowRect` sizes
instead of captured-frame dimensions and catches conversion exceptions silently.
A real-window probe on a 200% DPI display produced a frame in a DPI-unaware process
but zero frames after enabling per-monitor-v2 awareness, matching Flutter. Track
creation and a successful native Start therefore do not certify usable capture.

Capture limits for the `video.fushiClientArea` path come from
`video.mandatory` (all optional; Dart int or double both accepted, whereas
upstream `findDouble` silently drops an int `frameRate`):

- `frameRate`: rounded and clamped to 1..120 (default 30 when absent).
- `maxWidth` / `maxHeight`: output caps, clamped to 320x180..3840x2160; absent
  or non-positive values select 1920x1080.

The client area is scaled down (never up) to fit inside the caps, preserving the
aspect ratio, with even dimensions for I420. The returned track `settings`
report the scaled `width` / `height` and the clamped `frameRate`. The clamps live
in `fushi/windows/runner/game_stream_webrtc_capture_helpers.h` and are covered by
`game_stream_webrtc_capture_helper_test.cpp`. WGC captures the target window's
own surface, so the game may stay behind other windows while streaming.

`FUSHI_GAME_STREAM_CAPTURE_TRACE` optionally names a private local diagnostics
file for desktop start/state events. It records no media or signaling.

Remove this override when upstream exposes client-area WGC capture with correct
stride/dimensions, deterministic disposal, and startup failure propagation; rerun
the PMv2 real-window capture spike before changing the backend.

## Other whole-file overrides in this directory

- `windows/application_loopback_capturer.cc` (BUG-2725): the feeder thread
  wakes on a 5 ms high-resolution waitable timer and hands WebRTC every 10 ms
  chunk real time owes (`fushi/windows/runner/game_stream_audio_feed_clock.h`,
  bounded bursts, re-anchor after long stalls) instead of exactly one chunk per
  tick of a periodic timer that runs slow; prebuffer 100 ms. No
  `timeBeginPeriod`: the high-resolution timer does not depend on the process
  timer resolution, and on the coarse fallback timer the clock still catches
  up by elapsed time. Covered by
  `fushi/windows/runner/tests/game_stream_audio_feed_clock_test.cpp`.
- `common/cpp/src/flutter_peerconnection.cc` (BUG-2727):
  `updateRtpParameters` writes the edited encodings back with
  `set_encodings()` (upstream edited a copy, so every `setParameters` limit was
  dropped), and applies only values that are actually set — positive
  bitrates / frame rate / layer count, `scaleResolutionDownBy >= 1`, non-empty
  `scalabilityMode` — accepting Dart ints as int32 or int64. The getter
  reports unset fields as 0 / "" and Dart sends the whole map back; written
  verbatim those make libwebrtc reject the entire call.

Both are whole-file copies of 1.6.2+hotfix.3; move or drop them together with
this version directory when upgrading flutter_webrtc.
