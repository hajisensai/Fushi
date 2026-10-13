# media_kit 1.2.6

## BUG-3003: Windows debug hot restart

`lib/src/player/native/core/initializer.dart` uses the existing
`InitializerIsolate` backend on Windows debug builds, for both creation and
disposal. libmpv survives Flutter hot restart; a `NativeCallable.listener`
registered by the old isolate does not. Native playback events or reclamation
of the retained player can therefore invoke a deleted Dart callback, including
before the new isolate starts. Clearing the callback only during reclamation
would leave this interval unsafe.

The isolate backend consumes events with `mpv_wait_event` and SendPorts without
giving libmpv a Dart function pointer. Profile/release and other platforms keep
the upstream backend choice. This does not change video rendering or disable
hot restart.

Applied by `ci/apply-patches.sh` / `tool/bootstrap.ps1`, pinned to 1.2.6.
After applying it, cold-start the development app once so all players use the
new backend; hot-reloading into a process with existing NativeCallable players
does not migrate their registrations. Subsequent hot restarts remain supported.
Remove when upstream provides a callback lifetime that remains safe across
Flutter hot restart, then rerun the native isolate-exit regression and the real
Windows video hot-restart reproduction. The separate Windows render-context
teardown risks are not claimed fixed by this patch.

## BUG-3315: value-compared property observation

`lib/src/player/native/player/real.dart` adds
`NativePlayer.observePropertyChanges(property, listener)`. It subscribes with
`MPV_FORMAT_STRING`, so libmpv compares the formatted value in its core and only
emits `MPV_EVENT_PROPERTY_CHANGE` when it actually changes; the string arrives
with the event and the listener runs without any synchronous property read.

Upstream `observeProperty` subscribes with `MPV_FORMAT_NONE`. mpv reports such
subscriptions as changed on every notification (`player/client.c`:
`prop->format == 0` sets `changed = true`), and properties notified on
`MPV_EVENT_TICK` (`sub-start`, `sub-end`, `time-pos`, the frame counters, ...)
are notified once per video frame. Each of those events is answered by a
synchronous `mpv_get_property_string` (it takes the mpv core lock) on the event
isolate before the Dart listener can de-duplicate anything. The graphic
subtitle timing observer hit exactly this: two core-locked reads per frame for
the rest of the player's life.

`observeProperty` is unchanged byte for byte; both methods share the listener
table, so `unobserveProperty` removes either kind. When a value-observed
property becomes unavailable mpv sends one `MPV_FORMAT_NONE` event; the
existing branch handles it (the read returns null and no listener runs).

Regression test: `fushi/test/third_party/media_kit_observe_changes_test.dart`
(real libmpv; `FUSHI_TEST_LIBMPV` or a Windows Debug build). It counts
callbacks for `frame-drop-count` under `vo=null`: the `FORMAT_NONE` control
fires every frame, the value-compared subscription at most twice. Remove when
upstream exposes a typed `observeProperty`.
