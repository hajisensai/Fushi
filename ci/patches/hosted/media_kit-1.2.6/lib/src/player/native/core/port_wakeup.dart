// Fushi overlay for media_kit 1.2.6. See the accompanying PATCHES.md.
// Keep the original media_kit MIT license supplied with this package.

import 'dart:ffi';

/// A native wakeup trampoline that posts to a Dart native port instead of
/// calling a `NativeCallable` (feedback Wgbo462Sfc).
///
/// libmpv only accepts a `void (*)(void *data)` wakeup callback. With a
/// `NativeCallable.listener` that pointer belongs to the creating isolate and
/// the VM deletes it when that isolate shuts down; the libmpv core thread then
/// aborts the process with `Callback invoked after it has been deleted`.
/// libmpv handles routinely outlive the isolate: on Android audio_service
/// destroys the Flutter engine shortly after the activity finishes while the
/// process (and every undisposed player) lives on, and Dart has no synchronous
/// hook before that to unregister anything.
///
/// An implementation provides [fire], a native function that stays loaded for
/// the life of the process, and [create] / [free] for its `data` argument,
/// which posts the given value to the given native port. Posting to a port
/// whose isolate is gone fails harmlessly.
abstract interface class MpvPortWakeup {
  /// `void fire(void *target)`; libmpv may call it from any thread.
  Pointer<NativeFunction<Void Function(Pointer<Void>)>> get fire;

  /// Allocates a target that makes [fire] post [value] to [nativePort].
  Pointer<Void> create(int nativePort, int value);

  /// Releases a target from [create]. Called only after libmpv has stopped
  /// using it (`mpv_set_wakeup_callback(ctx, NULL, NULL)` returned).
  void free(Pointer<Void> target);
}
