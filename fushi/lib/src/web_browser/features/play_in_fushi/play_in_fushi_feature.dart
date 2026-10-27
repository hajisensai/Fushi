import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/video/stream_video_launch.dart';
import 'package:fushi/src/media/video/url_stream_video.dart'
    show isKnownWebPageVideoUrl;
import 'package:fushi/src/media/video/web_video_sites.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/web_browser/features/play_in_fushi/youtube_watch_page.dart';
import 'package:fushi/src/web_browser/features/web_browser_feature.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';
import 'package:fushi/src/web_browser/web_browser_site_launch.dart';
import 'package:fushi/utils.dart';

/// 暂停页面里所有在播的 `<video>`（交给 Fushi 播放器前调，免得两边同时出声）。
const String kWebBrowserPauseVideosScript =
    '(function(){var n=0;var vs=document.querySelectorAll("video");'
    'for(var i=0;i<vs.length;i++){try{if(!vs[i].paused){vs[i].pause();n++;}}'
    'catch(e){}}return n;})();';

/// 「用 Fushi 播放」：在 YouTube 观看页把当前视频交给 Fushi 自己的视频播放页。
///
/// 起播路径全部复用既有实现，这里不另写解析：
/// - 普通标签页：按规范化观看页地址落成一本普通流媒体书（[ensureWebVideoEpisodeBook]，
///   与「视频库 › 网站」播起某一集、粘贴 URL 导入同一身份 `streamVideoBookUid`，
///   已有则复用），再用 [VideoFushiPage.neutralized] 打开——续看、进度、制卡、观看
///   统计都按这本书记；平台分流（Windows 网页档 / 其它平台 mpv + YouTube 解析）
///   由视频页自己决定，和书架打开同一本书完全一致。
/// - 无痕标签页：不落库，走 [buildOnlineVideoExtraLaunch]（与作品页预告片同一条
///   不建书的临时起播路径）。
///
/// YouTube 流播放不属于 `StoreRestrictedCapability`（粘贴 YouTube 地址导入在 iOS
/// 上照常可用），所以五端都装。
///
/// 有播放页的平台（Windows，[playerAvailable]）上，其它网页也给「用 Fushi 播放」：把当前
/// 页面整页交给播放页（[openInWebVideoPlayer]，Netflix 硬件 DRM / Fushi 字幕层 / 每集
/// 落库），接着在那里选集播放（用户 2026-10-26：视频站点与浏览器站点合成一份，进
/// 播放页靠按钮而不是另开一个列表）。已知视频站（[isKnownWebPageVideoUrl]）放工具栏，
/// 其它网页收在「⋯」里。无痕标签页不给：播放页用的是常规登录存储，还会把看过的集落库。
class PlayInFushiFeature extends WebBrowserFeature {
  PlayInFushiFeature({
    required VideoBookRepository Function() repository,
    required int? Function() youtubeTargetHeight,
    bool Function()? playerAvailable,
  }) : _repository = repository,
       _youtubeTargetHeight = youtubeTargetHeight,
       _playerAvailable = playerAvailable ?? webVideoSitesAvailable;

  final VideoBookRepository Function() _repository;
  final int? Function() _youtubeTargetHeight;
  final bool Function() _playerAvailable;

  /// 正在起播的标签页（防连点）。
  final Set<String> _launching = <String>{};

  @override
  String get id => 'play_in_fushi';

  @override
  List<WebBrowserAction> actions(BuildContext context, WebBrowserTab tab) {
    final String? videoId = youtubeWatchVideoIdOf(tab.url);
    if (videoId == null) return _pageActions(context, tab);
    return <WebBrowserAction>[
      WebBrowserAction(
        id: 'play_in_fushi',
        icon: FushiIcons.playCircle,
        label: t.web_browser_play_in_fushi,
        placement: WebBrowserActionPlacement.toolbar,
        priority: 80,
        onPressed: _launching.contains(tab.id)
            ? null
            : () => unawaited(_play(context, tab, videoId)),
      ),
    ];
  }

  /// 非 YouTube 观看页：整页交给播放页（只在有播放页的平台、非无痕、http(s)）。
  List<WebBrowserAction> _pageActions(BuildContext context, WebBrowserTab tab) {
    final Uri? url = tab.url;
    if (tab.incognito ||
        url == null ||
        (url.scheme != 'http' && url.scheme != 'https') ||
        url.host.isEmpty ||
        !_playerAvailable()) {
      return const <WebBrowserAction>[];
    }
    final bool videoSite = isKnownWebPageVideoUrl(url.toString());
    return <WebBrowserAction>[
      WebBrowserAction(
        id: 'play_in_fushi',
        icon: FushiIcons.playCircle,
        label: t.web_browser_play_in_fushi,
        placement: videoSite
            ? WebBrowserActionPlacement.toolbar
            : WebBrowserActionPlacement.menu,
        priority: 80,
        onPressed: _launching.contains(tab.id)
            ? null
            : () => unawaited(_openPage(context, tab, url)),
      ),
    ];
  }

  Future<void> _openPage(
    BuildContext context,
    WebBrowserTab tab,
    Uri url,
  ) async {
    if (!_launching.add(tab.id)) return;
    try {
      await _pausePage(tab.controller);
      if (!context.mounted) return;
      await openInWebVideoPlayer(
        context,
        url: url,
        title: webVideoSiteDefaultTitle(url.toString()),
        repo: _repository(),
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('web_browser.play_in_fushi', e, stack);
      FushiToast.show(msg: t.video_load_failed_generic);
    } finally {
      _launching.remove(tab.id);
    }
  }

  Future<void> _play(
    BuildContext context,
    WebBrowserTab tab,
    String videoId,
  ) async {
    if (!_launching.add(tab.id)) return;
    try {
      await _pausePage(tab.controller);
      final String url = youtubeCanonicalWatchUrl(videoId);
      final String title = webVideoEpisodeTitle(
        pageTitle: tab.title,
        episodeUrl: url,
        siteTitle: 'YouTube',
      );
      final VideoBookRepository repo = _repository();
      final Widget page;
      if (tab.incognito) {
        final launch = await buildOnlineVideoExtraLaunch(
          id: 'web-browser:$videoId',
          title: title,
          url: url,
          youtubeTargetHeight: _youtubeTargetHeight(),
        );
        page = VideoFushiPage.neutralizedRemote(
          info: launch.info,
          repo: repo,
          client: launch.client,
        );
      } else {
        final VideoBookRow? row = await ensureWebVideoEpisodeBook(
          repo,
          episodeUrl: url,
          title: title,
        );
        if (row == null) throw StateError('video book not saved: $url');
        // 封面 / 真名补全是尽力而为，不挡起播。
        unawaited(
          refreshWebVideoEpisodeBook(
            repo,
            row,
            videoTitle: title,
            pageImage: '',
          ).then<void>(
            (_) {},
            onError: (Object e) {
              debugPrint('[web-browser] play-in-fushi cover refresh: $e');
            },
          ),
        );
        page = VideoFushiPage.neutralized(bookUid: row.bookUid, repo: repo);
      }
      if (!context.mounted) return;
      await Navigator.of(context).push<void>(
        adaptivePageRoute<void>(context: context, builder: (_) => page),
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('web_browser.play_in_fushi', e, stack);
      FushiToast.show(msg: t.video_load_failed_generic);
    } finally {
      _launching.remove(tab.id);
    }
  }

  Future<void> _pausePage(InAppWebViewController? controller) async {
    if (controller == null) return;
    try {
      await controller.evaluateJavascript(source: kWebBrowserPauseVideosScript);
    } catch (e) {
      // 页面正在导航 / WebView 刚被回收：照样起播，只是网页那边可能还在响。
      debugPrint('[web-browser] pause page video failed: $e');
    }
  }
}
