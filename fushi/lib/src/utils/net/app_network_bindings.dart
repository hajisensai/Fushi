import 'package:flutter/foundation.dart';

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
  installAnkiRemoteMediaHttpClientFactory();
  installAnkiAddonDownloadHttpClientFactory();
  await primeProxy();
}
