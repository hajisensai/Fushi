import 'package:flutter/services.dart';

/// Fushi patch: per-WebView static hardware layer (Hybrid Composition only).
///
/// The fork renders Hybrid Composition WebViews without a hardware layer
/// (`InAppWebView.prepare()` pins `LAYER_TYPE_NONE`): a layer on a page that
/// scrolls is redrawn every frame. The one case a layer pays off is a WebView
/// that stays still while something else animates over it — the in-app
/// dictionary popup scrolling above the reader. Then the layer lets the window
/// reuse the reader's pixels instead of re-running its draw functor each frame.
///
/// Turn it on only while the WebView is static and covered by an animating
/// overlay, and off as soon as the overlay goes away. Native side:
/// `InAppWebView.setStaticLayer` via the per-view channel.
abstract final class AndroidWebViewStaticLayer {
  /// Sets the layer for the WebView whose controller reports [viewId]
  /// (`InAppWebViewController.getViewId()`). Returns whether it was applied
  /// (false off Hybrid Composition or when the view is gone).
  static Future<bool> set(Object viewId, {required bool enabled}) async {
    final MethodChannel channel = MethodChannel(
      'com.pichillilorenzo/flutter_inappwebview_$viewId',
    );
    try {
      return await channel.invokeMethod<bool>(
            'fushiSetStaticLayer',
            <String, Object?>{'enabled': enabled},
          ) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }
}
