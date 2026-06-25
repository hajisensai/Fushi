// TODO-617 global lookup overlay — Dart side of the bare WebView2 window.
//
// The main Dart engine owns the dictionary (HoshiDicts FFI + AppModel). This
// channel pushes a self-contained popupJson to the native overlay for rendering
// and answers the overlay's reverse calls: image:// gaiji bytes (getMedia) and
// JS bridge messages (jsMessage — dismiss/audio in later phases).
//
// Native counterpart: windows/runner/global_lookup_window.cpp +
// FlutterWindow::RegisterGlobalLookupChannel().

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';

/// Thin wrapper over [HibikiChannels.globalLookup]. Static because there is a
/// single overlay per process.
abstract final class GlobalLookupChannel {
  static const MethodChannel _channel = HibikiChannels.globalLookup;

  /// Sets the absolute folder that holds popup.html / popup.js / popup.css and
  /// popup_bridge_adapter.js (flutter_assets/assets/popup at runtime). Must be
  /// called once before the first [showAt].
  static Future<void> prepare(String assetsDir) =>
      _channel.invokeMethod<void>('prepare', <String, Object?>{
        'assetsDir': assetsDir,
      });

  /// Shows the overlay at screen coordinates (physical pixels) without stealing
  /// focus. Returns false if the native window could not be created.
  static Future<bool> showAt({
    required int x,
    required int y,
    int width = 420,
    int height = 600,
    bool atCursor = false,
  }) async {
    final bool? ok =
        await _channel.invokeMethod<bool>('showAt', <String, Object?>{
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'atCursor': atCursor,
    });
    return ok ?? false;
  }

  /// Injects [popupJson] and calls window.renderPopup() in the overlay WebView.
  static Future<void> render(String popupJson) =>
      _channel.invokeMethod<void>('render', <String, Object?>{
        'json': popupJson,
      });

  /// Resizes the overlay window (physical px), clamped to the work area by
  /// native. Keeps the current top-left anchor.
  static Future<void> resize({required int width, required int height}) =>
      _channel.invokeMethod<void>('resize', <String, Object?>{
        'width': width,
        'height': height,
      });

  /// Resolves a deferred JS bridge promise (audio handlers). The overlay adapter
  /// does `JSON.parse(arg)` on the second argument of
  /// window.__hibikiBridgeResolve(id, arg) — i.e. it expects a JS *string*
  /// containing the reply's JSON. So we double-encode: the inner jsonEncode
  /// produces the reply JSON text, the outer jsonEncode turns that into a JS
  /// string literal native can splice in verbatim (keeping the native side free
  /// of any escaping logic).
  static Future<void> resolveBridge(int id, Object? value) =>
      _channel.invokeMethod<void>('resolveBridge', <String, Object?>{
        'id': id,
        'value': jsonEncode(jsonEncode(value)),
      });

  static Future<void> hide() => _channel.invokeMethod<void>('hide');

  static Future<bool> isShowing() async =>
      (await _channel.invokeMethod<bool>('isShowing')) ?? false;

  /// Wires the overlay's reverse calls. [onGetMedia] resolves gaiji bytes for an
  /// `image://` url (via HoshiDicts.getMediaFile); [onJsMessage] receives raw
  /// bridge messages decoded from JSON.
  static void setHandlers({
    required Future<Uint8List> Function(String url) onGetMedia,
    required void Function(Map<String, Object?> message) onJsMessage,
  }) {
    _channel.setMethodCallHandler((MethodCall call) async {
      switch (call.method) {
        case 'getMedia':
          final Map<Object?, Object?> args =
              call.arguments as Map<Object?, Object?>;
          final String url = args['url'] as String;
          return await onGetMedia(url);
        case 'jsMessage':
          final Object? raw = call.arguments;
          if (raw is String) {
            final Object? decoded = jsonDecode(raw);
            if (decoded is Map) {
              onJsMessage(decoded.cast<String, Object?>());
            }
          }
          return null;
        default:
          return null;
      }
    });
  }
}
