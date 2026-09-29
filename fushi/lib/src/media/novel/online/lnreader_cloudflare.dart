import 'dart:io';

import 'package:fushi/src/media/manga/cookie/manga_cookie_jar.dart';

/// 某个插件最近一次撞上的 Cloudflare 挑战：被拦的地址 + 当时发出的 UA。
///
/// `cf_clearance` 绑定解题时的 UA，解题页必须用 [userAgent] 逐字节相同地打开
/// [url]，拿回来的 cookie 桥才用得上。
class LnReaderCloudflareChallenge {
  const LnReaderCloudflareChallenge({
    required this.url,
    required this.userAgent,
  });

  final Uri url;
  final String userAgent;
}

/// 小说在线源的 Cloudflare 放行状态：持久 cookie + 每插件待解的挑战。
///
/// 纯 Dart（不依赖 Flutter）：[LnReaderFetchBridge] 只依赖 `dart:io`，页面在调用
/// 失败后来查 [challengeFor] 即可，不需要监听。
///
/// 与 LNReader app 同一形态：插件请求被 Cloudflare 拦下时不自动弹页（后台翻页、
/// 批量下载里弹全屏 WebView 只会打断用户），而是记下来，由页面给出「在浏览器中
/// 验证」让用户主动解；解出的 cookie 进 [jar]，之后所有插件请求都带上。
///
/// cookie 的数据结构与解题页和漫画扩展共用（[MangaCookieJar] /
/// `AidokuCloudflareChallengePage`），但**文件是小说源自己的**（放在 LNReader
/// 根目录下，删目录即彻底卸载）。
class LnReaderCloudflare {
  LnReaderCloudflare(this.jar);

  final MangaCookieJar jar;
  final Map<String, LnReaderCloudflareChallenge> _challenges =
      <String, LnReaderCloudflareChallenge>{};

  /// [pluginId] 当前待解的挑战；没有返回 null。
  LnReaderCloudflareChallenge? challengeFor(String pluginId) =>
      _challenges[pluginId];

  /// 桥看到挑战响应时调用。
  void record(String pluginId, LnReaderCloudflareChallenge challenge) {
    _challenges[pluginId] = challenge;
  }

  /// 同插件对同一站点的请求又通过了（验证成功、或 cookie 在别处已换新）。
  void clear(String pluginId, String host) {
    final LnReaderCloudflareChallenge? current = _challenges[pluginId];
    if (current == null || current.url.host != host) return;
    _challenges.remove(pluginId);
  }

  /// 用户在解题页完成验证后调用：挑战作废，下次请求带新 cookie 重试。
  void resolved(String pluginId) {
    _challenges.remove(pluginId);
  }
}

/// 响应是不是 Cloudflare 的挑战页（而不是站点自己的 403 / 503）。
///
/// `cf-mitigated: challenge` 是 Cloudflare 给挑战响应打的标准头；老式 JS 挑战
/// 没有它，就按「Cloudflare 服务器 + 403/503 + 挑战页标记」判。只看状态码会把
/// 站点真实的 403（地区限制、需要登录）误判成可以靠验证解开。
bool isLnReaderCloudflareChallenge({
  required int statusCode,
  required HttpHeaders headers,
  required List<int> body,
}) {
  if (headers.value('cf-mitigated')?.toLowerCase() == 'challenge') return true;
  if (statusCode != HttpStatus.forbidden &&
      statusCode != HttpStatus.serviceUnavailable) {
    return false;
  }
  final String server = headers.value(HttpHeaders.serverHeader) ?? '';
  if (!server.toLowerCase().contains('cloudflare')) return false;
  final String head = String.fromCharCodes(
    body.length > 64 * 1024 ? body.sublist(0, 64 * 1024) : body,
  );
  return head.contains('challenge-platform') ||
      head.contains('cf_chl_opt') ||
      head.contains('<title>Just a moment');
}
