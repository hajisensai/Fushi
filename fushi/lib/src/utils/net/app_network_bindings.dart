import 'package:flutter/foundation.dart';

import 'package:fushi/src/platform/mobile/ios_background_download.dart';
import 'package:fushi/src/utils/net/android_system_proxy.dart';
import 'package:fushi/src/utils/net/anki_addon_download_http.dart';
import 'package:fushi/src/utils/net/anki_remote_media_http.dart';
import 'package:fushi_engine/utils/net/app_proxy.dart';
import 'package:fushi/src/utils/net/dictionary_dio.dart';

/// Install outbound factories in every app entry point after preferences load.
///
/// Await system proxy discovery before exposing services: synchronous HTTP
/// factories otherwise see an empty proxy cache on their first request.
Future<void> installAppNetworkBindings({
  @visibleForTesting Future<void> Function() primeProxy = primeAppProxy,
}) async {
  installDictionaryDioFactory();
  installDictionaryUrlCandidatesResolver();
  // iOS：词典包交给系统后台会话下，切到后台不停（BUG-3887）。
  installIosBackgroundDictionaryTransport();
  installAnkiRemoteMediaHttpClientFactory();
  installAnkiAddonDownloadHttpClientFactory();
  // Android 的 Wi-Fi 代理只有平台通道读得到；必须早于 prime，首个请求才看得见它。
  installAndroidSystemProxyReader();
  await primeProxy();
}
