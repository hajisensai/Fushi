// TODO-617 global lookup overlay — Dart side of the bare WebView2 window.
//
// The main Dart engine owns the dictionary (FushiDicts FFI + AppModel). This
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

import 'package:flutter/foundation.dart';
import 'package:fushi/src/lookup/overlay_window_channel.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

export 'package:fushi/src/lookup/overlay_window_channel.dart'
    show GlobalLookupRoute, GlobalLookupShowResult, OverlayReverseEvent;

abstract final class GlobalLookupChannel {
  static final Object _routeZoneKey = Object();
  static const GlobalLookupRoute _defaultRoute = GlobalLookupRoute.desktop();
  static final Map<String, int> _invalidatedLookupHighWater = <String, int>{};

  static String _routeFamily(GlobalLookupRoute route) =>
      '${route.source}:${route.routeEpoch}';

  static GlobalLookupRoute get currentRoute =>
      Zone.current[_routeZoneKey] as GlobalLookupRoute? ?? _defaultRoute;

  static OverlayWindowChannel get _impl {
    final route = currentRoute;
    return OverlayWindowChannel(
      FushiChannels.globalLookup,
      target: route.target,
      routeEpoch: route.routeEpoch,
      lookupEpoch: route.lookupEpoch,
      routeIsValid: () => isRouteValid(route),
    );
  }

  /// Runs the complete lookup (including callbacks, Futures and Timers) on an
  /// immutable route. Dart zones preserve this value across async boundaries.
  static T runWithRoute<T>(GlobalLookupRoute route, T Function() body) =>
      runZoned(body, zoneValues: <Object, Object>{_routeZoneKey: route});

  /// Permanently retires one immutable route token. Futures and Timers already
  /// queued in that route's zone are then rejected at the channel boundary,
  /// and reverse callbacks stamped with it are ignored by the controller.
  /// Callers must mint monotonically new epochs; an invalidated token is never
  /// reactivated (otherwise a stale continuation could revive itself).
  static void invalidateRoute(GlobalLookupRoute route) {
    final String family = _routeFamily(route);
    final int previous = _invalidatedLookupHighWater[family] ?? -1;
    if (route.lookupEpoch > previous) {
      _invalidatedLookupHighWater[family] = route.lookupEpoch;
    }
  }

  static bool isRouteValid(GlobalLookupRoute route) =>
      route.lookupEpoch >
      (_invalidatedLookupHighWater[_routeFamily(route)] ?? -1);

  @visibleForTesting
  static String get debugTarget => _impl.target;

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
    int capWidth = 0,
    int capHeight = 0,
  }) =>
      _impl.showAt(
        x: x,
        y: y,
        width: width,
        height: height,
        atCursor: atCursor,
        capWidth: capWidth,
        capHeight: capHeight,
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
    void Function(OverlayReverseEvent event)? onRoutedJsMessage,
    void Function(OverlayReverseEvent event)? onRoutedOverlayHidden,
  }) =>
      _impl.setHandlers(
        onGetMedia: onGetMedia,
        onJsMessage: onJsMessage,
        onOverlayHidden: onOverlayHidden,
        onRoutedJsMessage: onRoutedJsMessage,
        onRoutedOverlayHidden: onRoutedOverlayHidden,
      );
}
