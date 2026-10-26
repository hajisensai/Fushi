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

/// 站点在本平台点开时是否进播放页：站点标了 [WebBrowserSite.openInPlayer] 且本平台
/// 有播放页（[webVideoSitesAvailable]，只有 Windows）。
bool webBrowserSiteOpensInPlayer(
  WebBrowserSite site, {
  TargetPlatform? platform,
}) => site.openInPlayer && webVideoSitesAvailable(platform: platform);

/// 在 Fushi 播放页（Windows 网页播放器）打开 [url]：站点自己的页面用来登录、选剧、
/// 选集，播起某一集才切到播放器并落成一本书。拿不到底层合成时播放页自己退回 app 内
/// 浏览器（见 `web_source.part.dart`）。
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
