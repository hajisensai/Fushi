/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:collection';
import 'dart:ffi';
import 'dart:isolate';

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
    // Fushi overlay (BUG-5413): with a port wakeup installed, libmpv calls a
    // native trampoline that posts to this isolate's port instead of a
    // NativeCallable, so a wakeup after this isolate died is dropped instead
    // of aborting the process.
    final Pointer<NativeFunction<PortWakeupFunction>>? trampoline = _portWakeup;
    final _Wakeup wakeup = trampoline == null
        ? _CallableWakeup(ctx, _callback)
        : _PortWakeup(ctx, trampoline, _callback);
    _locks[ctx.address] = Lock();
    _eventCallbacks[ctx.address] = callback;
    _wakeUps[ctx.address] = wakeup;
    // Fushi overlay (H6Vou-6uYX): once the process has started exiting, a new
    // handle must not hand libmpv a callback the engine is about to free.
    if (!_quiescedForProcessExit) {
      mpv.mpv_set_wakeup_callback(ctx, wakeup.function, wakeup.data);
    }
    return ctx;
  }

  /// Fushi overlay (BUG-5413). Native `void (*)(void *)` trampoline that posts
  /// to a Dart port; see `lib/native_wakeup.dart`. Null = upstream
  /// NativeCallable wakeups.
  static Pointer<NativeFunction<PortWakeupFunction>>? _portWakeup;

  /// Fushi overlay (BUG-5413). Handles created afterwards use [trampoline].
  static void usePortWakeup(
    Pointer<NativeFunction<PortWakeupFunction>> trampoline,
  ) {
    _portWakeup = trampoline;
  }

  /// Fushi overlay (H6Vou-6uYX). Set by [quiesceForProcessExit]; never reset,
  /// the process is going away.
  static bool _quiescedForProcessExit = false;

  /// Fushi overlay (H6Vou-6uYX). Clears the libmpv wakeup callback of every
  /// live handle, without disposing anything.
  ///
  /// `mpv_set_wakeup_callback` takes the same lock libmpv holds while invoking
  /// the callback, so when this returns no core thread is inside or can reach
  /// a wakeup of this isolate. The wakeups stay registered here so a later
  /// [dispose] closes them as usual. See `lib/native_exit.dart`.
  static void quiesceForProcessExit() {
    _quiescedForProcessExit = true;
    final InitializerNativeCallable? instance = _instance;
    if (instance == null) return;
    for (final int address in instance._wakeUps.keys) {
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

    _wakeUps.remove(ctx.address)?.close();
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
  final _wakeUps = HashMap<int, _Wakeup>();
}

typedef WakeUpCallback = Void Function(Pointer<generated.mpv_handle>);
typedef WakeUpNativeCallable = NativeCallable<WakeUpCallback>;

/// Fushi overlay (BUG-5413). `void (*)(void *)`, libmpv's wakeup signature.
typedef PortWakeupFunction = Void Function(Pointer<Void>);

/// Fushi overlay (BUG-5413). `Dart_PostCObject`.
typedef PostCObjectFunction = Int8 Function(Int64, Pointer<Dart_CObject>);

/// Fushi overlay (BUG-5413). The trampoline's `d`: `{ post, port, value }`.
final class PortWakeupData extends Struct {
  external Pointer<NativeFunction<PostCObjectFunction>> post;

  @Int64()
  external int port;

  @Int64()
  external int value;
}

/// The callback libmpv holds for one handle, and what releases it.
sealed class _Wakeup {
  Pointer<NativeFunction<Void Function(Pointer<Void>)>> get function;
  Pointer<Void> get data;

  /// Only after `mpv_set_wakeup_callback(ctx, null, null)` returned.
  void close();
}

/// Upstream: a listener [NativeCallable] owned by this isolate.
final class _CallableWakeup implements _Wakeup {
  _CallableWakeup(
    Pointer<generated.mpv_handle> ctx,
    void Function(Pointer<generated.mpv_handle>) callback,
  ) : _ctx = ctx,
      _callable = WakeUpNativeCallable.listener(callback);

  final Pointer<generated.mpv_handle> _ctx;
  final WakeUpNativeCallable _callable;

  @override
  Pointer<NativeFunction<Void Function(Pointer<Void>)>> get function =>
      _callable.nativeFunction.cast();

  @override
  Pointer<Void> get data => _ctx.cast();

  @override
  void close() => _callable.close();
}

/// Fushi overlay (BUG-5413): the trampoline posts `ctx` to [_port]. A port
/// closes with its isolate and a post to a closed port is dropped, so libmpv
/// may outlive this isolate. [_data] stays allocated until [close]; when the
/// isolate dies without disposing, it leaks with the libmpv handle it serves.
final class _PortWakeup implements _Wakeup {
  _PortWakeup(
    Pointer<generated.mpv_handle> ctx,
    this._trampoline,
    void Function(Pointer<generated.mpv_handle>) callback,
  ) : _port = ReceivePort('media_kit wakeup'),
      _data = calloc<PortWakeupData>() {
    _port.listen((Object? _) => callback(ctx));
    _data.ref
      ..post = NativeApi.postCObject
      ..port = _port.sendPort.nativePort
      ..value = ctx.address;
  }

  final Pointer<NativeFunction<PortWakeupFunction>> _trampoline;
  final ReceivePort _port;
  final Pointer<PortWakeupData> _data;

  @override
  Pointer<NativeFunction<Void Function(Pointer<Void>)>> get function =>
      _trampoline;

  @override
  Pointer<Void> get data => _data.cast();

  @override
  void close() {
    _port.close();
    calloc.free(_data);
  }
}

typedef EventCallback = Future<void> Function(Pointer<generated.mpv_event>);
typedef EventCallbackMap = HashMap<int, EventCallback>;
