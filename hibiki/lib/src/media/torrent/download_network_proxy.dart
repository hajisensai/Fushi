import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'package:hibiki/src/utils/misc/update_checker.dart';

/// 下载「发现」链路（AniList / Nyaa / Jimaku）单次请求的超时上限。
///
/// 这三家都在墙外，用户常挂代理（`auto` 模式还要先解析系统代理再建隧道），
/// 握手 + TLS + 代理转发叠起来轻松超过十几秒。旧值 20s 是按直连拍的，代理下
/// 经常在请求本来能成功的情况下先被这层 `.timeout()` 掐断，UI 只剩
/// `TimeoutException after 0:00:20` + 「请点重试」。
///
/// 放宽到 60s：慢链路能跑完，真断网仍会由 socket 层先报错（不会真的干等一分钟）。
/// 发现链路和订阅检查共用这一个值，避免各处再散落魔法数字。
const Duration kDownloadDiscoveryTimeout = Duration(seconds: 60);

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
