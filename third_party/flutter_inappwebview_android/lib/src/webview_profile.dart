import 'package:flutter/services.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';

/// Hibiki patch: named WebView profiles (androidx.webkit `MULTI_PROFILE`).
///
/// Upstream's `incognito` setting wipes the **global** cookie jar instead of
/// isolating the page. A non-default profile has its own cookies, web storage,
/// cache and service workers; Fushi gives each incognito browsing session one
/// profile and deletes it when the session ends. Native side:
/// `WebViewProfileManager.java`.
///
/// The platform interface has no field for this, so the name is attached to
/// the [InAppWebViewSettings] instance handed to the `InAppWebView` widget
/// ([setProfileName]); [AndroidInAppWebViewWidget] forwards it in the creation
/// params and the native side applies it before the view is used.
abstract final class AndroidWebViewProfile {
  static const MethodChannel _channel = MethodChannel(
    'com.pichillilorenzo/flutter_inappwebview_profile',
  );

  /// Settings-map key read by `FlutterWebView.java`.
  static const String settingsKey = 'webViewProfileName';

  static final Expando<String> _names = Expando<String>('webViewProfileName');

  /// Puts every WebView created from [settings] into profile [name] (null =
  /// default profile). Only call it after [isSupported] answered true.
  static void setProfileName(InAppWebViewSettings settings, String? name) {
    _names[settings] = name;
  }

  static String? profileNameOf(InAppWebViewSettings? settings) =>
      settings == null ? null : _names[settings];

  /// Whether the system WebView supports `MULTI_PROFILE`.
  static Future<bool> isSupported() async =>
      await _channel.invokeMethod<bool>('isSupported') ?? false;

  /// Deletes profile [name] (its cookies, storage, cache). If WebViews of the
  /// profile are still alive the deletion happens when the last one is
  /// destroyed. Returns true when deleted or scheduled.
  static Future<bool> deleteProfile(String name) async =>
      await _channel.invokeMethod<bool>('deleteProfile', <String, Object?>{
        'name': name,
      }) ??
      false;

  /// Deletes every profile whose name starts with [prefix] and that no live
  /// WebView uses (leftovers of a session the process died in).
  static Future<List<String>> deleteUnusedProfiles(String prefix) async {
    final List<Object?>? deleted = await _channel.invokeMethod<List<Object?>>(
      'deleteUnusedProfiles',
      <String, Object?>{'prefix': prefix},
    );
    return deleted?.whereType<String>().toList() ?? <String>[];
  }

  /// The `Cookie` header value profile [name] would send to [url] (null when
  /// there is none or the profile does not exist).
  static Future<String?> getCookie(String name, String url) =>
      _channel.invokeMethod<String>('getCookie', <String, Object?>{
        'name': name,
        'url': url,
      });
}
