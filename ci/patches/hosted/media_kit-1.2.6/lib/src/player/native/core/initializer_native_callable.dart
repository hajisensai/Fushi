/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:collection';
import 'dart:ffi';

import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as generated;
import 'package:synchronized/synchronized.dart';

/// {@template initializer_native_callable}
///
/// InitializerNativeCallable
/// -------------------------
/// Initializes [Pointer<mpv_handle>] & notifies about events through the supplied callback.
///
/// {@endtemplate}
class InitializerNativeCallable {
  /// Singleton instance.
  static InitializerNativeCallable? _instance;

  /// {@macro initializer}
  InitializerNativeCallable._(this.mpv);

  /// {@macro initializer}
  factory InitializerNativeCallable(generated.MPV mpv) {
    _instance ??= InitializerNativeCallable._(mpv);
    return _instance!;
  }

  /// Generated libmpv C API bindings.
  final generated.MPV mpv;

  /// Creates [Pointer<mpv_handle>].
  Future<Pointer<generated.mpv_handle>> create(
    Future<void> Function(Pointer<generated.mpv_event>) callback, {
    Map<String, String> options = const {},
  }) async {
    final ctx = mpv.mpv_create();
    for (final entry in options.entries) {
      final name = entry.key.toNativeUtf8();
      final value = entry.value.toNativeUtf8();
      mpv.mpv_set_option_string(ctx, name.cast(), value.cast());
      calloc.free(name);
      calloc.free(value);
    }
    mpv.mpv_initialize(ctx);
    final nativeCallable = WakeUpNativeCallable.listener(_callback);
    final nativeFunction = nativeCallable.nativeFunction;
    _locks[ctx.address] = Lock();
    _eventCallbacks[ctx.address] = callback;
    _wakeUpNativeCallables[ctx.address] = nativeCallable;
    // Fushi overlay (H6Vou-6uYX): once the process has started exiting, a new
    // handle must not hand libmpv a callback the engine is about to free.
    if (!_quiescedForProcessExit) {
      mpv.mpv_set_wakeup_callback(ctx, nativeFunction.cast(), ctx.cast());
    }
    return ctx;
  }

  /// Fushi overlay (H6Vou-6uYX). Set by [quiesceForProcessExit]; never reset,
  /// the process is going away.
  static bool _quiescedForProcessExit = false;

  /// Fushi overlay (H6Vou-6uYX). Clears the libmpv wakeup callback of every
  /// live handle, without disposing anything.
  ///
  /// `mpv_set_wakeup_callback` takes the same lock libmpv holds while invoking
  /// the callback, so when this returns no core thread is inside or can reach
  /// a [NativeCallable] of this isolate. The callables stay registered here so
  /// a later [dispose] closes them as usual. See `lib/native_exit.dart`.
  static void quiesceForProcessExit() {
    _quiescedForProcessExit = true;
    final InitializerNativeCallable? instance = _instance;
    if (instance == null) return;
    for (final int address in instance._wakeUpNativeCallables.keys) {
      instance.mpv.mpv_set_wakeup_callback(
        Pointer<generated.mpv_handle>.fromAddress(address),
        nullptr,
        nullptr,
      );
    }
  }

  /// Disposes [Pointer<mpv_handle>].
  void dispose(Pointer<generated.mpv_handle> ctx) {
    _locks.remove(ctx.address);
    _eventCallbacks.remove(ctx.address);

    // Clear the wakeup callback in libmpv before closing NativeCallable
    // to prevent libmpv from invoking a deleted callback
    mpv.mpv_set_wakeup_callback(ctx, nullptr, nullptr);

    _wakeUpNativeCallables.remove(ctx.address)?.close();
  }

  void _callback(Pointer<generated.mpv_handle> ctx) {
    _locks[ctx.address]?.synchronized(() async {
      while (true) {
        final event = mpv.mpv_wait_event(ctx, 0);
        if (event == nullptr) return;
        if (event.ref.event_id == generated.mpv_event_id.MPV_EVENT_NONE) return;
        await _eventCallbacks[ctx.address]?.call(event);
      }
    });
  }

  final _locks = HashMap<int, Lock>();
  final _eventCallbacks = EventCallbackMap();
  final _wakeUpNativeCallables = WakeUpNativeCallableMap();
}

typedef WakeUpCallback = Void Function(Pointer<generated.mpv_handle>);
typedef WakeUpNativeCallable = NativeCallable<WakeUpCallback>;
typedef WakeUpNativeCallableMap = HashMap<int, WakeUpNativeCallable>;

typedef EventCallback = Future<void> Function(Pointer<generated.mpv_event>);
typedef EventCallbackMap = HashMap<int, EventCallback>;
