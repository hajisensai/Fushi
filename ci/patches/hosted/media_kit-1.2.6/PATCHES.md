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

## BUG-3325: built-in Lua scripts stay off

`lib/src/player/native/player/real.dart` passes
`load-{stats-overlay,console,auto-profiles,select,positioning,commands,context-menu}=no`
as pre-`mpv_initialize` options. The bundled libmpv is built with Lua on Windows
(LuaJIT) and Android (Lua 5.2) so the user mpv script feature (`load-script`,
BUG-2032) works; mpv's `libmpv` profile only disables the OSC, so without these
options every player would also start mpv's own scripts. mpv reads them only
during `mpv_initialize`, which is why they live here and not in Fushi's per-open
properties (`ytdl=no` is set per open by `buildLuaHostBaselineProperties`).
Builds without Lua reject the option names; `Initializer.create` ignores
`mpv_set_option_string` results, so this is a no-op there. Remove only together
with a decision to ship mpv's built-in scripts.

## BUG-3507: property access and commands never block the calling thread

`lib/src/player/native/player/real.dart` adds
`NativePlayer.getPropertyAsync(property)` (same contract as `getProperty`: `''`
when unavailable, throws once disposed) and `NativePlayer.commandWithResult(args)`
(returns libmpv's result code instead of logging it), and routes the public
`setProperty` through `mpv_set_property_async` when `configuration.async` is on
(the default).

Upstream `getProperty` / `setProperty` call `mpv_get_property_string` /
`mpv_set_property_string` synchronously. Both wait for the mpv core lock on the
caller's thread, which in a Flutter app is the UI thread; the `await`s in front
of them are completed futures, so a batch of reads never yields to the event
loop. A user's diagnostic log showed the event loop held for 0.4–0.6 s per
sampling round while the core was busy: Windows could not composite new video
texture frames, so the picture froze while audio kept playing.

The async variants queue `mpv_*_async`; replies arrive as
`MPV_EVENT_GET_PROPERTY_REPLY` / `MPV_EVENT_SET_PROPERTY_REPLY` /
`MPV_EVENT_COMMAND_REPLY` on the event loop. libmpv's contract lets async calls
be reordered against each other (current mpv happens to dispatch them FIFO), so
callers that need ordering await each request before the next. `setProperty`
re-checks `disposed` after its initialization await, and late replies after
`dispose` are not reported as unregistered IDs. `dispose` completes every
pending async request (reads with `''`, writes and `_command` with success,
`commandWithResult` with `MPV_ERROR_UNINITIALIZED`) so no caller waits for a
reply that will never come.

The event loop is serial: it awaits `_handler` (and therefore observer and hook
callbacks) before fetching the next event. Code running inside those callbacks
must not await an async read, write or command, or it waits for a reply queued
behind itself. Fushi's observers schedule their work with `unawaited`.

The event loop itself no longer takes the core lock either:

- `observeProperty` (`MPV_FORMAT_NONE`) answered every event with a synchronous
  `mpv_get_property_string`. A value-observed property (`observePropertyChanges`)
  gets a `FORMAT_NONE` event only when it becomes unavailable, so nothing is read
  (upstream's read returned NULL and no listener ran). A plain `observeProperty`
  subscription queues an async read at event time and runs the listener when the
  reply arrives; a chain keeps listener calls in event order.
- The `on_load` / `on_unload` hook body (`Media.httpHeaders` →
  `http-header-fields`, `Media.start` / `end`, `onLoadHooks` / `onUnloadHooks`)
  read and wrote properties synchronously. It now runs off the event loop
  (`_runHook`, chained) with `mpv_get_property_async` / `mpv_set_property_async`,
  awaiting each reply before the next request, so the hook is released only after
  every write was applied.
- `mpv_hook_add` and `mpv_hook_continue` take the core lock (`lock_core` in
  `player/client.c`) and libmpv has no async variant (mpv 0.39 has no `hook-ack`
  command either), so they run on a helper isolate via `compute`, like upstream's
  `screenshot` / playlist reads. `dispose` waits for in-flight hook releases
  before `mpv_terminate_destroy`; once disposed a pending hook is not released
  (mpv drops a destroyed client's hooks itself).
- `mpv_observe_property` / `mpv_unobserve_property` stay on the calling thread:
  they take only the client's own `ctx->lock`, never the core lock.

Regression tests: `fushi/test/third_party/media_kit_async_property_test.dart`,
`fushi/test/third_party/media_kit_async_hooks_test.dart` (real libmpv;
`FUSHI_TEST_LIBMPV`; the hook test serves a WAV over local HTTP and checks the
header and `Media.start` still reach mpv) and the source guard
`fushi/test/media/video/video_mpv_ui_thread_native_calls_guard_test.dart`.
Remove when upstream stops reading and writing properties synchronously on the
caller's thread.

## BUG-4730: libmpv callbacks are detached when the process starts exiting

`lib/src/player/native/core/initializer_native_callable.dart` (otherwise
upstream 1.2.6 apart from formatting) adds
`InitializerNativeCallable.quiesceForProcessExit()`, exposed as
`quiesceNativeCallbacksForProcessExit()` by the new public library
`lib/native_exit.dart`. It clears the libmpv wakeup callback of every live
handle and makes later handles skip registering one. Nothing is disposed or
closed, so commands still work and a later `Player.dispose` stays safe.

The release backend gives libmpv a `NativeCallable.listener` per player and
only unregisters it in `Player.dispose`. An app exit does not dispose players,
and the process can end without reaching Dart's `exit`: on macOS a second quit
request during the exit chain goes through `NSApp terminate`, where the Flutter
engine's `applicationWillTerminate:` shuts the engine down and frees the
callbacks while libmpv's core thread still posts property changes (feedback
H6Vou-6uYX: SIGSEGV at an unmapped address under
`mp_client_send_property_changes`). Fushi calls the entry point synchronously
from `AppExitCoordinator.begin`, the first step of every intentional exit.
`mpv_set_wakeup_callback` takes the lock libmpv holds while invoking the
callback, so no core thread can be inside or reach a Dart callback afterwards.

Regression test: the `quiesce` mode of
`fushi/test/third_party/media_kit_hot_restart_test.dart` (real libmpv: owner
isolate killed without dispose after quiescing; exits `-1073740791` with
`Callback invoked after it has been deleted` without the fix). Remove when
upstream unregisters its callbacks before the engine can free them.

## BUG-5027: a locked screenshot holds the player lock for the capture only

`lib/src/player/native/player/real.dart` splits `NativePlayer.screenshot` in
two. `_screenshotRaw` (helper isolate, registered in `_offThreadNativeCalls`
like before) runs `screenshot-raw` and copies the BGRA frame into a
`TransferableTypedData`; only this step runs under `lock` when
`synchronized` is true. `_encodeScreenshot` (a second helper isolate) builds
the JPEG / PNG after the lock is released; it never touches the handle, so
`dispose` does not wait for it. `format: null` still returns the raw BGRA
bytes. `format: 'image/x-fushi-bgra'` (section below) skips both the
`TransferableTypedData` copy and the encode.

Upstream encodes inside the locked section, on the same isolate as the
capture. The pure-Dart encode takes hundreds of ms for a 1080p frame, and
every `play()` / `pause()` / `seek()` queued behind a screenshot waited for
it: mining a card and resuming right away resumed only after the JPEG was
done. The captured frame is unchanged (the capture still runs in lock order).

Regression tests: `fushi/test/third_party/media_kit_screenshot_lock_test.dart`
(real libmpv + ffmpeg: `FUSHI_TEST_LIBMPV`, `FUSHI_TEST_FFMPEG`; a `pause()`
queued right after a JPEG screenshot completes first) and the structural
guard in `fushi/test/media/video/video_mpv_ui_thread_native_calls_guard_test.dart`.
Remove when upstream encodes outside its lock.

## BUG-4911: property writes report libmpv's result

`lib/src/player/native/player/real.dart` adds
`NativePlayer.setPropertyWithResult(property, value)`: the body of the
patched async `setProperty` (BUG-3507), returning the
`MPV_EVENT_SET_PROPERTY_REPLY` error (or the immediate `mpv_set_property_async`
error, or the synchronous `mpv_set_property_string` result when
`configuration.async` is off). `setProperty` now delegates to it and still
returns nothing. Upstream drops the code, so a rejected write (unknown name,
bad value, not settable at runtime) left no trace; Fushi's single batch helper
`setMpvPropertiesInOrder` (`fushi/lib/src/media/video/video_mpv_config.dart`)
logs it. Returns `MPV_ERROR_UNINITIALIZED` when the player got disposed while
waiting for initialization; a write still pending at `dispose` resolves to 0.

Regression test: `fushi/test/media/video/video_mpv_property_batch_test.dart`
(helper contract) and the guard above (`setProperty` delegates, the write
stays async). Remove together with the BUG-3507 property patch.

## Raw BGRA screenshot transform (`image/x-fushi-bgra`)

`lib/src/player/native/player/real.dart`: `screenshot` accepts
`format: 'image/x-fushi-bgra'` together with a `fushiRawTransform` callback
(carried to the capture isolate in `_ScreenshotData.rawTransform`; a missing
callback is an `ArgumentError`). The callback runs inside `_screenshotRaw` on
the capture helper isolate with the `screenshot-raw` frame size, row stride and
a view of mpv's BGRA buffer, before the node is freed — the view is valid only
during the call, so the transform copies what it keeps. Its returned bytes are
the screenshot result as is: no `TransferableTypedData` copy of the whole
frame, no `_encodeScreenshot`. Because it must run before the node is freed it
is part of the capture call, so with `synchronized: true` it runs under `lock`
(Fushi's only caller passes `synchronized: false`), and `dispose` waits for it
through `_offThreadNativeCalls` like any capture. Upstream's `null` format
copies the whole frame and drops the dimensions, and the JPEG / PNG formats run
a pure-Dart encode (hundreds of ms per 1080p frame). The smart subtitle mask
(`fushi/lib/src/media/video/smart_subtitle_mask_sampler.dart`) samples frames
continuously during playback and only needs a small RGBA crop: the transform
(`fushi/lib/src/media/video/raw_video_frame.dart`) copies just those rows on
the capture isolate, so no full frame is copied or sent between isolates.
Additive: no existing format changes. Remove if upstream offers a cropped raw
screenshot.

## BUG-4941: the mpv handle is destroyed on a helper isolate

`lib/src/player/native/player/real.dart` runs the delayed
`mpv_terminate_destroy` of `dispose` through `compute` (top-level
`_terminateDestroy`), after the in-flight helper-isolate calls finish, exactly
like `_hookContinue` / `_screenshotRaw`.

`mpv_terminate_destroy` blocks until the mpv core thread has exited
(`mp_destroy_client` in `player/client.c`: `mp_dispatch_lock`, then
`mp_thread_join`). Upstream calls it on the isolate that disposed the player,
i.e. the Flutter UI isolate, which on Android is the platform main thread. With
the core stuck on a stream that never opens (`Failed to recognize file
format`), feedback wcOJwX-sHh got two ANRs whose main-thread stacks sat in
`pthread_join` and `pthread_cond_wait` inside that one libmpv function, under
the same Dart frame.

Regression test: the source guard
`fushi/test/media/video/video_mpv_ui_thread_native_calls_guard_test.dart`
(`destroys the mpv handle off the UI thread`). Remove when upstream stops
destroying the handle on the caller's thread.
