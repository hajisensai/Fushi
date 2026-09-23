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
