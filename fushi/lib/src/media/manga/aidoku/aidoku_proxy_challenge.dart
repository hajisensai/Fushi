import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:fushi/src/media/manga/aidoku/aidoku_network_session.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi/src/utils/net/app_native_proxy.dart';
import 'package:fushi_engine/utils/net/app_proxy.dart';

/// null means the existing platform-browser route can be used. A requested
/// proxy or explicit direct mode must never silently fall back to system rules.
Future<bool?> solveAidokuProxyChallenge({
  required Uri url,
  required String userAgent,
  required AidokuCookieJar jar,
  required String title,
  required String closeLabel,
  @visibleForTesting TargetPlatform? platform,
  @visibleForTesting Future<Uri> Function()? endpointFactory,
}) async {
  final TargetPlatform target = platform ?? defaultTargetPlatform;
  if (target != TargetPlatform.iOS && target != TargetPlatform.macOS) {
    return null;
  }
  final String directive = resolveAppProxyDirective(url);
  final bool requiresProxyControl =
      directive != 'DIRECT' ||
      appUserProxyModeReader() == kProxyModeManual ||
      appUserProxyModeReader() == kProxyModeDirect;
  bool supported = false;
  try {
    supported =
        await FushiChannels.cloudflareProxyBrowser.invokeMethod<bool>(
          'isSupported',
        ) ??
        false;
  } on MissingPluginException {
    // Older native bundles cannot promise an isolated browser proxy.
  }
  if (!supported) {
    if (requiresProxyControl) {
      throw PlatformException(
        code: 'CHALLENGE_PROXY_UNSUPPORTED',
        message: 'Proxy verification requires iOS 17 or macOS 14 or newer.',
      );
    }
    return null;
  }
  await jar.ensureLoaded();
  final List<AidokuCookie> initial = jar.cookiesFor(url);
  final Set<String> stale = initial
      .where((AidokuCookie cookie) => cookie.name == kCloudflareClearanceCookie)
      .map((AidokuCookie cookie) => cookie.value)
      .toSet();
  final Uri endpoint =
      await (endpointFactory ?? ensureAppChallengeProxyEndpoint)();
  final Object? result = await FushiChannels.cloudflareProxyBrowser
      .invokeMethod<Object?>('solve', <String, Object?>{
        'url': url.toString(),
        'userAgent': userAgent,
        'proxyEndpoint': endpoint.toString(),
        'title': title,
        'closeLabel': closeLabel,
        'staleClearance': stale.toList(growable: false),
        // The jar does not retain HttpOnly/SameSite. Never downgrade a login
        // cookie by recreating it as a JavaScript-readable browser cookie.
        'cookies': const <Object?>[],
      });
  if (result == null) return false;
  if (result is! List<Object?>) {
    throw const FormatException('Invalid verification cookie response');
  }
  // Recheck the cookie boundary in Dart before persisting native results.
  final int now = DateTime.now().millisecondsSinceEpoch;
  final List<AidokuCookie> cookies = result
      .whereType<Map<Object?, Object?>>()
      .map(
        (Map<Object?, Object?> item) =>
            AidokuCookie.fromJson(item.cast<String, Object?>()),
      )
      .where(
        (AidokuCookie cookie) =>
            cookie.isValid &&
            cookie.matchesHost(url.host) &&
            !cookie.isExpiredAt(now),
      )
      .toList(growable: false);
  if (!cookies.any(
    (AidokuCookie cookie) =>
        cookie.name == kCloudflareClearanceCookie &&
        cookie.value.isNotEmpty &&
        !stale.contains(cookie.value),
  )) {
    return false;
  }
  // A clearance is bound to the exit used to solve it. Do not commit it after
  // a user has changed the application route while the browser was open.
  if (resolveAppProxyDirective(url) != directive) return false;
  await jar.replaceForHost(url.host, <AidokuCookie>[
    ...jar
        .cookiesFor(url)
        .where(
          (AidokuCookie cookie) => cookie.name != kCloudflareClearanceCookie,
        ),
    ...cookies.where(
      (AidokuCookie cookie) =>
          cookie.name == kCloudflareClearanceCookie &&
          cookie.value.isNotEmpty &&
          !stale.contains(cookie.value),
    ),
  ]);
  return true;
}
