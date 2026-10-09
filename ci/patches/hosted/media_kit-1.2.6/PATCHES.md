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
