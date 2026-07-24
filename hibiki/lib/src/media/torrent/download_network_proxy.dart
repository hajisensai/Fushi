import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'package:hibiki/src/utils/misc/update_checker.dart';

/// Proxy policy for the discovery/subtitle HTTP requests used by downloads.
///
/// Torrent payload traffic is owned by qBittorrent/the embedded engine and is
/// deliberately not affected by this setting.
enum DownloadNetworkProxyMode {
  auto,
  direct,
  custom;

  static DownloadNetworkProxyMode parse(String? value) {
    return switch (value) {
      'direct' => DownloadNetworkProxyMode.direct,
      'custom' => DownloadNetworkProxyMode.custom,
      _ => DownloadNetworkProxyMode.auto,
    };
  }
}

class DownloadNetworkProxyConfig {
  const DownloadNetworkProxyConfig({
    this.mode = DownloadNetworkProxyMode.auto,
    this.customProxy = '',
  });

  final DownloadNetworkProxyMode mode;
  final String customProxy;
}

/// Builds a client for AniList, Nyaa and Jimaku.
///
/// Auto mode shares the updater's platform resolver, whose priority is:
/// environment variables > enabled GUI/system proxy > DIRECT. Keeping one
/// resolver prevents update and download requests from disagreeing about the
/// machine's active proxy.
Future<http.Client> buildDownloadHttpClient(
  DownloadNetworkProxyConfig config,
) async {
  final HttpClient client = HttpClient();
  try {
    await applyDownloadNetworkProxy(client, config);
  } catch (_) {
    client.close(force: true);
    rethrow;
  }
  return IOClient(client);
}

/// Applies the policy to an existing client. Public so the three routing modes
/// can be tested without making a real network request.
Future<void> applyDownloadNetworkProxy(
  HttpClient client,
  DownloadNetworkProxyConfig config,
) async {
  final String? fixedDirective = fixedDownloadProxyDirective(config);
  if (fixedDirective == null) {
    await applyUpdateProxy(client);
    return;
  }
  client.findProxy = (_) => fixedDirective;
}

/// Returns the fixed directive for direct/custom modes. Auto returns null
/// because its result depends on environment and platform system settings.
String? fixedDownloadProxyDirective(DownloadNetworkProxyConfig config) {
  if (config.mode == DownloadNetworkProxyMode.auto) return null;
  if (config.mode == DownloadNetworkProxyMode.direct) return 'DIRECT';
  final String? normalized = normalizeUserProxyHostPort(config.customProxy);
  if (normalized == null) {
    throw const FormatException('Invalid download proxy');
  }
  return 'PROXY $normalized';
}
