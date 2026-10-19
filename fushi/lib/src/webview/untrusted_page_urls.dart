/// 站点页面经 JS 上报的地址（不可信数据）落地前的校验。
///
/// 页面脚本完全受站点控制：它报的 `href` 决定这一集落成哪本书、它报的图片地址会被
/// Fushi 去下载。不校验的话，页面可以往库里写任意条目、让 app 去拉本机 / 任意地址。
library;

import 'package:fushi/src/media/novel/online/lnreader_fetch_bridge.dart'
    show isLnReaderBlockedHost;

/// 页面上报的 [reported] 地址只在与 WebView 自己报的 [webViewUrl]（导航回调给的，
/// 可信）同一主机时采信；主机不同、不是 http(s) 时退回 [webViewUrl]。WebView 地址
/// 还不知道（首帧前）时只保留 http(s) 的上报值。
String trustedPageHref(String reported, String? webViewUrl) {
  final Uri? page = webViewUrl == null || webViewUrl.isEmpty
      ? null
      : Uri.tryParse(webViewUrl);
  final Uri? claimed = Uri.tryParse(reported);
  final bool claimedOk =
      claimed != null &&
      (claimed.scheme == 'https' || claimed.scheme == 'http') &&
      claimed.host.isNotEmpty;
  if (page == null || page.host.isEmpty) return claimedOk ? reported : '';
  if (claimedOk && claimed.host.toLowerCase() == page.host.toLowerCase()) {
    return reported;
  }
  return webViewUrl!;
}

/// 页面 / 站点 metadata 给的远端图片地址：只收 https 绝对地址、且主机不是本机
/// （localhost / 回环 / 链路本地字面量）；否则 null。解析后指向本机的域名由下载端
/// 建连接时再判（`guardLnReaderConnections`）。
Uri? safeRemoteImageUrl(String raw) {
  final String value = raw.trim();
  if (value.isEmpty) return null;
  final Uri? uri = Uri.tryParse(value);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
  if (isLnReaderBlockedHost(uri.host)) return null;
  return uri;
}
