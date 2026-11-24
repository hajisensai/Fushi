// Fushi overlay for media_kit 1.2.6. See the accompanying PATCHES.md.
// Keep the original media_kit MIT license supplied with this package.

import 'dart:ffi';

import 'src/player/native/core/initializer_native_callable.dart';

export 'src/player/native/core/initializer_native_callable.dart'
    show PortWakeupData, PortWakeupFunction, PostCObjectFunction;

/// Makes players created afterwards in this isolate deliver libmpv wakeups
/// through a Dart port instead of a `NativeCallable.listener`.
///
/// [trampoline] is a native `void (*)(void *d)` that, when called with `d`
/// pointing at a [PortWakeupData], posts `d->value` as an int to `d->port`
/// with `d->post` (`Dart_PostCObject`). Fushi passes `ffc_port_wakeup` from
/// fushi_compute.
///
/// Why (BUG-5413, feedback Wgbo462Sfc): libmpv's core thread outlives the
/// isolate that created the player whenever that isolate dies without
/// `Player.dispose`. On Android audio_service destroys the FlutterEngine after
/// the Activity is gone while the process stays cached; a listener callable is
/// deleted with its isolate, and libmpv's next wakeup makes the VM abort the
/// process ("Callback invoked after it has been deleted"). A port closes with
/// its isolate instead, and a post to a closed port is simply dropped.
///
/// Call once per isolate before creating players. The event-isolate backend
/// (Windows debug, execmem-restricted platforms) gives libmpv no Dart function
/// pointer and is unaffected.
void useNativePortWakeup(
  Pointer<NativeFunction<PortWakeupFunction>> trampoline,
) => InitializerNativeCallable.usePortWakeup(trampoline);
