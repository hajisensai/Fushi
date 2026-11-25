// Fushi overlay for media_kit 1.2.6. See the accompanying PATCHES.md.
// Keep the original media_kit MIT license supplied with this package.

import 'src/player/native/core/initializer_native_callable.dart';

/// Detaches every libmpv wakeup callback that points into the Dart VM, before
/// the process starts terminating.
///
/// The release backend registers a `NativeCallable.listener` per player as the
/// libmpv wakeup callback. Process termination that does not go through
/// `Player.dispose` (macOS `NSApp terminate` shuts the Flutter engine down
/// first, freeing those trampolines) leaves libmpv's core thread calling into
/// freed memory (feedback H6Vou-6uYX). Call this synchronously as the first
/// step of every intentional exit. Afterwards libmpv never calls back into
/// Dart: existing players stop delivering events and players created later
/// never register a callback. Commands and property writes still work, and a
/// later `Player.dispose` remains safe.
///
/// Synchronous, idempotent and a no-op when no player was ever created. The
/// event-isolate backend (Windows debug, execmem-restricted platforms) gives
/// libmpv no Dart function pointer and needs nothing here.
void quiesceNativeCallbacksForProcessExit() =>
    InitializerNativeCallable.quiesceForProcessExit();
