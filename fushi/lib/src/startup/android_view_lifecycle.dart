import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:fushi/src/startup/exit_flush_registry.dart';

/// Activity attachment is shorter-lived than audio_service's cached engine.
///
/// Persist pending page writes when the view goes away, including detached,
/// without shutting down engine-owned databases, services, or registrations.
/// A subsequent Activity can attach even while this flush is still running.
class AndroidViewLifecycle {
  AndroidViewLifecycle({ExitFlushRegistry? registry})
      : _registry = registry ?? ExitFlushRegistry.instance;

  final ExitFlushRegistry _registry;
  Future<void>? _flushInFlight;
  bool _flushRequested = false;

  Future<void> handleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        return Future<void>.value();
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        return _flush();
    }
  }

  Future<void> _flush() {
    _flushRequested = true;
    final Future<void>? pending = _flushInFlight;
    if (pending != null) return pending;
    final Completer<void> completion = Completer<void>();
    _flushInFlight = completion.future;
    unawaited(_drain(completion));
    return completion.future;
  }

  Future<void> _drain(Completer<void> completion) async {
    try {
      do {
        _flushRequested = false;
        await _registry.flushAll(clearCallbacks: false);
        // A later view event can arrive after the registry took its snapshot.
        // Drain that request serially so newly deferred page writes are saved.
      } while (_flushRequested);
      completion.complete();
    } catch (error, stack) {
      completion.completeError(error, stack);
    } finally {
      _flushInFlight = null;
    }
  }
}
