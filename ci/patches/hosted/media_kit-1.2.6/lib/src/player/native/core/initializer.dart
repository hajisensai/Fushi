/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:ffi';
import 'dart:io';

import 'package:media_kit/generated/libmpv/bindings.dart' as generated;
import 'package:media_kit/src/player/native/core/execmem_restriction.dart';
import 'package:media_kit/src/player/native/core/initializer_isolate.dart';
import 'package:media_kit/src/player/native/core/initializer_native_callable.dart';
import 'package:media_kit/src/values.dart';

/// {@template initializer}
///
/// Initializer
/// -----------
/// Initializes [Pointer<mpv_handle>] & notifies about events through the supplied callback.
///
/// {@endtemplate}
class Initializer {
  /// Singleton instance.
  static Initializer? _instance;

  /// {@macro initializer}
  Initializer._(this.mpv);

  /// {@macro initializer}
  factory Initializer(generated.MPV mpv) {
    _instance ??= Initializer._(mpv);
    return _instance!;
  }

  /// Generated libmpv C API bindings.
  final generated.MPV mpv;

  // BUG-3003: Windows hot restart destroys the Dart isolate without disposing
  // its players. libmpv outlives it and may invoke the deleted NativeCallable
  // before the new isolate can reclaim the handles. Use the existing event
  // isolate backend in debug: it waits for native events without registering
  // any Dart function pointer in libmpv. Keep create and dispose on one backend.
  // Profile/release and other platforms retain the upstream selection.
  bool get _useIsolate =>
      isExecmemRestricted || (Platform.isWindows && kDebugMode);

  /// Creates [Pointer<mpv_handle>].
  Future<Pointer<generated.mpv_handle>> create(
    Future<void> Function(Pointer<generated.mpv_event>) callback, {
    Map<String, String> options = const {},
  }) async {
    if (!_useIsolate) {
      return InitializerNativeCallable(mpv).create(callback, options: options);
    } else {
      return InitializerIsolate().create(callback, options: options);
    }
  }

  /// Disposes [Pointer<mpv_handle>].
  void dispose(Pointer<generated.mpv_handle> ctx) {
    if (!_useIsolate) {
      InitializerNativeCallable(mpv).dispose(ctx);
    } else {
      InitializerIsolate().dispose(mpv, ctx);
    }
  }
}
