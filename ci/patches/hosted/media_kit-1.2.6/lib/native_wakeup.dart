// Fushi overlay for media_kit 1.2.6. See the accompanying PATCHES.md.
// Keep the original media_kit MIT license supplied with this package.

import 'src/player/native/core/initializer_native_callable.dart';
import 'src/player/native/core/port_wakeup.dart';

export 'src/player/native/core/port_wakeup.dart';

/// Routes the libmpv wakeup of every player created from now on through
/// [wakeup] (a native trampoline posting to a Dart native port) instead of a
/// `NativeCallable.listener` (feedback Wgbo462Sfc).
///
/// Call once at startup, before the first `Player` is created; players that
/// already exist keep their callback until disposed. Without it the release
/// backend registers upstream's `NativeCallable`, which aborts the process when
/// libmpv wakes up after the owning isolate (Flutter engine) is gone. The
/// event-isolate backend (Windows debug, execmem-restricted platforms) gives
/// libmpv no Dart function pointer and is unaffected.
void installMpvPortWakeup(MpvPortWakeup wakeup) =>
    InitializerNativeCallable.portWakeup = wakeup;
