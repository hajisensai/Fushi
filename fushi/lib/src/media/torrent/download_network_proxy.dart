import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'package:fushi/src/utils/net/app_proxy.dart';

/// 下载网络链路（AniList / Nyaa / Jimaku）单次请求的**整体**超时上限。
///
/// 这三家都在墙外，用户常挂代理（`auto` 模式还要先解析系统代理再建隧道），
/// 握手 + TLS + 代理转发叠起来轻松超过十几秒。旧值 20s 是按直连拍的，代理下
/// 经常在请求本来能成功的情况下先被这层 `.timeout()` 掐断，UI 只剩
/// `TimeoutException after 0:00:20` + 「请点重试」。
///
/// 与 [kDownloadConnectionTimeout] 分层，两者语义不同、不可合并：
/// 连不上由连接超时快速失败，连得上但慢的才吃满这个整体上限。
///
/// 覆盖范围除发现类 API 往返外，也包含 Jimaku 字幕文件的字节下载
/// （文件只有几十 KB，与一次 API 往返同量级；将来若要做大文件或批量字幕，
/// 应为传输另立常量而不是继续放大这一个）。
///
/// **60s 这个数值缺实测支撑**：已证实的只有「20s 这道门被用户实际打到」
/// （报错截图 `TimeoutException after 0:00:20`），但没有耗时日志、没抓过成功
/// 请求的 duration、未分链路测，所以 60/40/90 之间无可区分依据——它是基于
/// 用户真实被掐断的**定性放宽**，不是测出来的值。后续若加上耗时采样，
/// 应当用真实 p95 回填这里（并相应放开守卫测试里的下界断言）。
const Duration kDownloadDiscoveryTimeout = Duration(seconds: 60);

/// 下载网络链路**建立连接**（DNS + TCP + 代理隧道 + TLS 握手）的超时上限。
///
/// 与整体超时分层的理由：这条链路最典型的失败不是「被拒绝」而是「丢包」——
/// 目标在墙外、或用户代理进程已退出导致端口不通时，SYN 被静默丢弃，
/// socket 层不会快速报错，会一路挂到应用层超时。若不设这一层，
/// [kDownloadDiscoveryTimeout] 放宽到 60s 就意味着连不上的场景要空转一分钟；
/// 而 UI 在等待期只有一个无进度、无耗时、无取消的转圈（搜索按钮同时 disabled），
/// 那是比原 bug 更难受的体验倒退。
///
/// 10s 足够覆盖「代理可达、只是慢」的握手；连不上则在 10s 内落到错误态 +
/// 重试按钮。同仓 `sync_http.dart` / `galgame_helper_installer.dart` /
/// `magpie_installer.dart` 用的是同一范式。
const Duration kDownloadConnectionTimeout = Duration(seconds: 10);

/// Proxy policy for the discovery/subtitle HTTP requests used by downloads.
///
/// Torrent payload traffic is owned by qBittorrent/the embedded engine and is
/// deliberately not affected by this setting.
///
/// **默认 = direct（BUG-1538 / TODO-2798）**：下载域流量默认不走代理，只有用户
/// 显式选了 auto（跟随环境变量/系统代理）或 custom（手填 host:port）才套代理。
/// 已保存 `'auto'` 的用户不受影响——只有「从未设置」和「未知值」落到 direct。
/// 未知值落 direct 而不是 auto，是因为下载域的失败模式不对称：误直连最多是慢/
/// 连不上并在 10s 内报错重试，误套一个不存在的代理则把所有请求黑洞掉。
enum DownloadNetworkProxyMode {
  auto,
  direct,
  custom;

  static DownloadNetworkProxyMode parse(String? value) {
    return switch (value) {
      'auto' => DownloadNetworkProxyMode.auto,
      'custom' => DownloadNetworkProxyMode.custom,
      _ => DownloadNetworkProxyMode.direct,
    };
  }
}

class DownloadNetworkProxyConfig {
  const DownloadNetworkProxyConfig({
    this.mode = DownloadNetworkProxyMode.direct,
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
  final HttpClient client = HttpClient()
    ..connectionTimeout = kDownloadConnectionTimeout;
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
    await applyAppProxy(client);
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
