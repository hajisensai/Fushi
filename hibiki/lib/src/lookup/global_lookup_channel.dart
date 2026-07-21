// TODO-617 global lookup overlay — Dart side of the bare WebView2 window.
//
// The main Dart engine owns the dictionary (HoshiDicts FFI + AppModel). This
// channel pushes a self-contained popupJson to the native overlay for rendering
// and answers the overlay's reverse calls: image:// gaiji bytes (getMedia) and
// JS bridge messages (jsMessage — dismiss/audio in later phases).
//
// spec 2026-07-10 — the implementation moved to the instance-level
// [OverlayWindowChannel] (shared with the persistent clipboard panel's second
// window). This file stays as the zero-churn static facade the 1700-line
// GlobalLookupController calls; every method is a one-line delegate to the
// shared instance bound to the global_lookup MethodChannel.
//
// Native counterpart: windows/runner/global_lookup_window.cpp +
// FlutterWindow::RegisterGlobalLookupChannel().

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:hibiki/src/lookup/overlay_window_channel.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';

export 'package:hibiki/src/lookup/overlay_window_channel.dart'
    show GlobalLookupShowResult;

abstract final class GlobalLookupChannel {
  static const OverlayWindowChannel _impl =
      OverlayWindowChannel(HibikiChannels.globalLookup);

  static Future<void> prepare(String assetsDir) => _impl.prepare(assetsDir);

  static Future<void> prewarmWebView({int width = 420, int height = 600}) =>
      _impl.prewarmWebView(width: width, height: height);

  static Future<bool> isWebViewReady() => _impl.isWebViewReady();

  static Future<GlobalLookupShowResult> showAt({
    required int x,
    required int y,
    int width = 420,
    int height = 600,
    bool atCursor = false,
  }) =>
      _impl.showAt(
        x: x,
        y: y,
        width: width,
        height: height,
        atCursor: atCursor,
      );

  static Future<void> render(String popupJson) => _impl.render(popupJson);

  static Future<void> resize({required int width, required int height}) =>
      _impl.resize(width: width, height: height);

  static Future<void> resolveBridge(int id, Object? value) =>
      _impl.resolveBridge(id, value);

  static Future<void> reveal({required int width, required int height}) =>
      _impl.reveal(width: width, height: height);

  static Future<void> revealStack({
    required int dx,
    required int dy,
    required int width,
    required int height,
    double left = 0,
    double top = 0,
  }) =>
      _impl.revealStack(
        dx: dx,
        dy: dy,
        width: width,
        height: height,
        left: left,
        top: top,
      );

  /// 防截屏（与剪贴板面板同一 pref）：把 display affinity 应用到瞬态覆盖窗。
  static Future<void> setBlockCapture(bool block) =>
      _impl.setBlockCapture(block);

  static Future<void> hide({bool notify = true}) => _impl.hide(notify: notify);

  static Future<bool> isShowing() => _impl.isShowing();

  static void setHandlers({
    required Future<Uint8List> Function(String url) onGetMedia,
    required void Function(Map<String, Object?> message) onJsMessage,
    void Function()? onOverlayHidden,
  }) =>
      _impl.setHandlers(
        onGetMedia: onGetMedia,
        onJsMessage: onJsMessage,
        onOverlayHidden: onOverlayHidden,
      );
}
