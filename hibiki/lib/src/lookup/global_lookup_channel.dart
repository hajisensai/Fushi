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
/// Native reply for [GlobalLookupChannel.showAt]: window-created flag plus the
/// cursor monitor's work area in PHYSICAL px (0 when unavailable). Divide the
/// work dimensions by the device pixel ratio to get CSS px for the cascade
/// layout (TODO-893 symptom 2).
class GlobalLookupShowResult {
  const GlobalLookupShowResult({
    required this.ok,
    required this.workWidth,
    required this.workHeight,
    this.cursorWorkX = 0,
    this.cursorWorkY = 0,
  });

  /// Whether the native overlay window was created.
  final bool ok;

  /// Cursor monitor work-area width in PHYSICAL px (0 when unavailable).
  final double workWidth;

  /// Cursor monitor work-area height in PHYSICAL px (0 when unavailable).
  final double workHeight;

  /// TODO-893 v2 (symptom 3) — the overlay window-local origin's offset from the
  /// cursor monitor work-area origin, in PHYSICAL px (0 when unavailable). The
  /// window-local (0,0) maps to (cursorWorkX, cursorWorkY) inside the work area;
  /// divide by the device pixel ratio for CSS px. Used to translate the host's
  /// window-local child anchor rect into the SAME work-area-absolute domain as
  /// computeFrameRect's screenW/H, eliminating the zero-point mismatch.
  final double cursorWorkX;

  /// See [cursorWorkX]: the vertical component (PHYSICAL px).
  final double cursorWorkY;
}

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
  /// focus. Returns the native reply: whether the window was created plus the
  /// cursor monitor's work area in PHYSICAL px (TODO-893 — so the Dart cascade
  /// layout reasons about the real display, not the off-screen measurement
  /// canvas). `workW`/`workH` are 0 when the monitor could not be queried.
  static Future<GlobalLookupShowResult> showAt({
    required int x,
    required int y,
    int width = 420,
    int height = 600,
    bool atCursor = false,
  }) async {
    final Object? reply =
        await _channel.invokeMethod<Object?>('showAt', <String, Object?>{
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'atCursor': atCursor,
    });
    if (reply is Map) {
      double num2(Object? v) => (v is num) ? v.toDouble() : 0;
      return GlobalLookupShowResult(
        ok: reply['ok'] == true,
        workWidth: num2(reply['workW']),
        workHeight: num2(reply['workH']),
        cursorWorkX: num2(reply['cursorWorkX']),
        cursorWorkY: num2(reply['cursorWorkY']),
      );
    }
    // Legacy/native fallback (bool reply): no work-area reported.
    return GlobalLookupShowResult(
      ok: reply == true,
      workWidth: 0,
      workHeight: 0,
    );
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

  /// Moves the off-screen-rendered overlay to the cursor at its final size and
  /// makes it visible. Called once per lookup after the page self-measures, so
  /// the user never sees the measure→resize jitter.
  static Future<void> reveal({required int width, required int height}) =>
      _channel.invokeMethod<void>('reveal', <String, Object?>{
        'width': width,
        'height': height,
      });

  /// TODO-867 P3c E1 — reveals/resizes the overlay to the nested-stack union
  /// bounding box. [dx]/[dy] offset the window from the cursor anchor (physical
  /// px; the host bbox origin times dpr) so a child cascading left/up shifts the
  /// window while keeping the root card pinned at the cursor; [width]/[height]
  /// are the bbox size (physical px). Native clamps to the monitor work area.
  static Future<void> revealStack({
    required int dx,
    required int dy,
    required int width,
    required int height,
  }) =>
      _channel.invokeMethod<void>('revealStack', <String, Object?>{
        'dx': dx,
        'dy': dy,
        'width': width,
        'height': height,
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
