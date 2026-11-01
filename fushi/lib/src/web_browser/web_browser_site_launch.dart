import 'dart:async';

import 'package:fushi_core/fushi_core.dart' show VideoBookRow;
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/video/web_video_sites.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptivePageRoute;
import 'package:fushi/src/web_browser/web_browser_sites.dart';

/// [url] 所在站点在站点表 [sites] 里标了「用 Fushi 播放本站视频」（[WebBrowserSite.openInPlayer]，
/// 持久化名冻结）且本平台有播放器层（[webVideoSitesAvailable]，只有 Windows）：这类站点的
/// 观看页由浏览器自动交给播放器层（`PlayInFushiFeature`）。按 host 匹配，`www.` 与子域名算
/// 同一站点。
bool webBrowserSiteAutoPlays(
  List<WebBrowserSite> sites,
  Uri url, {
  TargetPlatform? platform,
}) {
  if (!webVideoSitesAvailable(platform: platform)) return false;
  final String host = _siteHost(url.host);
  if (host.isEmpty) return false;
  for (final WebBrowserSite site in sites) {
    if (!site.openInPlayer) continue;
    final String siteHost = _siteHost(site.url.host);
    if (siteHost.isEmpty) continue;
    if (host == siteHost || host.endsWith('.$siteHost')) return true;
  }
  return false;
}

String _siteHost(String host) {
  final String h = host.toLowerCase();
  return h.startsWith('www.') ? h.substring(4) : h;
}

/// 把浏览器标签页里的观看页 [url] 交给播放器层（Windows 网页站点后端，底层合成）：播起
/// 某一集才落成一本书。播放器层只当播放器，返回 / 离开观看页都回到交接它的浏览器标签页
/// （[VideoFushiPage.webBackToBrowser]）。拿不到底层合成时播放器层自己换成 app 内浏览器
/// （见 `web_source.part.dart`）。
Future<void> openInWebVideoPlayer(
  BuildContext context, {
  required Uri url,
  required String title,
  required VideoBookRepository repo,
}) {
  final WebVideoSite site = WebVideoSite(
    title: title.trim().isEmpty ? webVideoSiteDefaultTitle('$url') : title,
    url: url.toString(),
  );
  final VideoBookRow row = webVideoSiteRow(site);
  return Navigator.of(context).push<void>(
    adaptivePageRoute<void>(
      context: context,
      builder: (_) => VideoFushiPage.neutralized(
        bookUid: row.bookUid,
        repo: repo,
        webSite: site,
        webBackToBrowser: true,
      ),
    ),
  );
}

/// 旧「视频站点」子页的自加站点并进浏览器站点表（标成用播放页打开），并清掉旧偏好。
/// 幂等：旧偏好清空后再调什么都不做。返回并完之后的站点表。
Future<List<WebBrowserSite>> settleLegacyVideoSites(
  PrefStore prefs, {
  required String sitesJson,
  required Future<void> Function(String json) writeSitesJson,
}) async {
  final List<WebBrowserSite> sites = parseWebBrowserSites(sitesJson);
  final List<WebVideoSite> legacy = decodeWebVideoSites(
    prefs.getPref(kWebVideoSitesPrefKey),
  );
  if (legacy.isEmpty) return sites;
  final List<WebBrowserSite> merged = mergeLegacyVideoSites(
    sites,
    <(String, String)>[for (final WebVideoSite s in legacy) (s.title, s.url)],
  );
  await writeSitesJson(encodeWebBrowserSites(merged));
  await prefs.setPref(kWebVideoSitesPrefKey, '');
  return merged;
}
