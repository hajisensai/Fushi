import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/video/stream_video_launch.dart';
import 'package:fushi/src/media/video/url_stream_video.dart'
    show isKnownWebPageVideoUrl;
import 'package:fushi/src/media/video/web_video_bridge.dart'
    show kWebVideoNetflixHosts;
import 'package:fushi/src/media/video/web_video_session.dart'
    show
        webBrowserSiteCookieNames,
        webVideoBrowserLoginSyncSettled,
        webVideoIsWatchPage;
import 'package:fushi/src/media/video/web_video_sites.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/web_browser/features/play_in_fushi/youtube_watch_page.dart';
import 'package:fushi/src/web_browser/features/web_browser_feature.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';
import 'package:fushi/src/web_browser/web_browser_site_launch.dart';
import 'package:fushi/utils.dart';

/// 交给 Fushi 播放器期间按住页面的媒体：暂停在播的 `<video>` / `<audio>`，并在捕获阶段拦
/// `play` 事件，之后谁开播都立刻停。只暂停一次不够（BUG-3801，用户「感觉有两个视频在播放」）：
/// 自动交接发生在地址刚变到观看页时，站点的 `<video>` 还没建；退回选集页后预告片也会自动播。
/// 幂等；由 [kWebBrowserReleaseMediaScript] 解除。
const String kWebBrowserHoldMediaScript =
    '(function(){var n=0;if(!window.__fushiMediaHold){'
    'window.__fushiMediaHold=function(e){var v=e.target;'
    'if(v&&v.pause){try{v.pause();}catch(_){}}};'
    'document.addEventListener("play",window.__fushiMediaHold,true);}'
    'var vs=document.querySelectorAll("video,audio");'
    'for(var i=0;i<vs.length;i++){try{if(!vs[i].paused){vs[i].pause();n++;}}'
    'catch(e){}}return n;})();';

/// 解除 [kWebBrowserHoldMediaScript]（播放页关掉、浏览器标签页重新在前台时）。
const String kWebBrowserReleaseMediaScript =
    '(function(){var h=window.__fushiMediaHold;if(h){'
    'document.removeEventListener("play",h,true);'
    'window.__fushiMediaHold=null;}})();';

/// 浏览器标签页播不了、一进观看页就该直接交给播放页的地址：Netflix 的 `/watch/<id>`。
///
/// 浏览器标签页的画面是捕获合成出来的，DRM 视频走 DComp overlay，捕获到的是纯黑，4K 捕获
/// 还卡（2026-10-27 用户：Netflix 在浏览器里黑屏、卡，要再点一次「用 Fushi 播放」才进播放器）；
/// 播放页的窗口宿主档才有硬件 PlayReady。浏览 / 详情页（预告片）不算，用户在那里选集。
bool webBrowserWatchPageNeedsPlayer(Uri? url) {
  if (url == null) return false;
  final String host = url.host.toLowerCase();
  final bool drmSite = kWebVideoNetflixHosts.any(
    (String d) => host == d || host.endsWith('.$d'),
  );
  return drmSite && webVideoIsWatchPage(url.toString());
}

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
///
/// 浏览器播不了的观看页（[webBrowserWatchPageNeedsPlayer]）不等用户点：地址一变到那里就自动
/// 交给播放页，标签页退回上一页（回来时停在选集页，而不是一张黑掉的观看页）。
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

  /// 每个标签页最近一次自动交给播放页的地址：退不回去（观看页就是第一页）时标签页还停在
  /// 原地，同一地址不再自动交第二次。
  final Map<String, String> _autoHandedOff = <String, String>{};

  @override
  void onUrlChanged(
    BuildContext context,
    WebBrowserTab tab,
    InAppWebViewController controller,
    Uri? url,
  ) {
    if (url == null ||
        tab.incognito ||
        !_playerAvailable() ||
        !webBrowserWatchPageNeedsPlayer(url)) {
      return;
    }
    final String key = url.toString();
    if (_autoHandedOff[tab.id] == key) return;
    _autoHandedOff[tab.id] = key;
    unawaited(_openPage(context, tab, url, controller, leaveWatchPage: true));
  }

  /// 媒体被按住的标签页（播放页还在前面）。
  final Set<String> _held = <String>{};

  @override
  Future<void> onLoadStop(
    WebBrowserTab tab,
    InAppWebViewController controller,
    Uri? url,
  ) async {
    // 按住期间整页换了文档（退回上一页不是单页应用内换页）：新文档重新按住。
    if (_held.contains(tab.id)) {
      await _evaluate(controller, kWebBrowserHoldMediaScript);
    }
  }

  @override
  void onTabClosed(WebBrowserTab tab) {
    _autoHandedOff.remove(tab.id);
    _held.remove(tab.id);
  }

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
            : () => unawaited(_openPage(context, tab, url, tab.controller)),
      ),
    ];
  }

  Future<void> _openPage(
    BuildContext context,
    WebBrowserTab tab,
    Uri url,
    InAppWebViewController? controller, {
    bool leaveWatchPage = false,
  }) async {
    if (!_launching.add(tab.id)) return;
    await _holdPage(tab, controller);
    final Future<Set<String>> cookiesBefore = webBrowserSiteCookieNames(url);
    try {
      if (leaveWatchPage) await _leavePage(controller);
      if (!context.mounted) return;
      await openInWebVideoPlayer(
        context,
        url: url,
        title: webVideoSiteDefaultTitle(url.toString()),
        repo: _repository(),
        backToBrowser: true,
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('web_browser.play_in_fushi', e, stack);
      FushiToast.show(msg: t.video_load_failed_generic);
    } finally {
      _launching.remove(tab.id);
      if (context.mounted) {
        unawaited(
          _releasePageWhenBack(
            context,
            tab,
            controller,
            site: url,
            cookiesBefore: cookiesBefore,
          ),
        );
      } else {
        // 标签页已经没了：没有页面可解除。
        _held.remove(tab.id);
      }
    }
  }

  Future<void> _play(
    BuildContext context,
    WebBrowserTab tab,
    String videoId,
  ) async {
    if (!_launching.add(tab.id)) return;
    final InAppWebViewController? controller = tab.controller;
    await _holdPage(tab, controller);
    try {
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
      if (context.mounted) {
        unawaited(_releasePageWhenBack(context, tab, controller));
      } else {
        // 标签页已经没了：没有页面可解除。
        _held.remove(tab.id);
      }
    }
  }

  /// 自动交接后标签页退回上一页（选集页），不停在播不了的观看页上继续拉流。
  Future<void> _leavePage(InAppWebViewController? controller) async {
    if (controller == null) return;
    try {
      if (await controller.canGoBack()) await controller.goBack();
    } catch (e) {
      debugPrint('[web-browser] leave watch page failed: $e');
    }
  }

  Future<void> _holdPage(
    WebBrowserTab tab,
    InAppWebViewController? controller,
  ) async {
    _held.add(tab.id);
    if (controller != null) {
      await _evaluate(controller, kWebBrowserHoldMediaScript);
    }
  }

  /// 播放页那一串路由（含换成制卡队列的内置播放页，`pushReplacement` 时 push 的 future 已经
  /// 完成）都关掉、浏览器重新在前台时才解除按住，否则制卡重放期间浏览器的预告片又会响。
  ///
  /// [site] / [cookiesBefore]：交接时浏览器里这个站点的 cookie 名。播放页关掉时会把它里面
  /// 的登录态抄回浏览器（`syncWebVideoLoginToBrowser`）；回来后浏览器多出了 cookie（用户在
  /// 播放页里登录了）就刷新标签页，否则页面还停在未登录态（BUG-3801）。
  Future<void> _releasePageWhenBack(
    BuildContext context,
    WebBrowserTab tab,
    InAppWebViewController? controller, {
    Uri? site,
    Future<Set<String>>? cookiesBefore,
  }) async {
    await untilRouteIsCurrent(context);
    if (!_held.remove(tab.id) || controller == null) return;
    await _evaluate(controller, kWebBrowserReleaseMediaScript);
    if (site == null || cookiesBefore == null) return;
    await webVideoBrowserLoginSyncSettled(site);
    final Set<String> before = await cookiesBefore;
    final Set<String> after = await webBrowserSiteCookieNames(site);
    if (after.difference(before).isEmpty) return;
    try {
      await controller.reload();
    } catch (e) {
      debugPrint('[web-browser] reload after login sync failed: $e');
    }
  }

  Future<void> _evaluate(
    InAppWebViewController controller,
    String source,
  ) async {
    try {
      await controller.evaluateJavascript(source: source);
    } catch (e) {
      // 页面正在导航 / WebView 刚被回收：新文档由 [onLoadStop] 补上。
      debugPrint('[web-browser] page media script failed: $e');
    }
  }
}

/// [context] 所在路由重新成为最上面一页时完成（盖在上面的页都关掉了）。按 `secondaryAnimation`
/// 判：上面有页时它停在 completed，最后一页关掉才回到 dismissed；`pushReplacement` 换上来
/// 的新页接着驱动它，所以中途换页不会提前完成。路由已经在最上面 / 已卸载 / 不是过渡路由时
/// 立刻完成。
Future<void> untilRouteIsCurrent(BuildContext context) {
  if (!context.mounted) return Future<void>.value();
  final ModalRoute<Object?>? route = ModalRoute.of(context);
  final Animation<double>? secondary = route?.secondaryAnimation;
  if (route == null ||
      secondary == null ||
      route.isCurrent ||
      !route.isActive ||
      secondary.status == AnimationStatus.dismissed) {
    return Future<void>.value();
  }
  final Completer<void> done = Completer<void>();
  void onStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed) return;
    secondary.removeStatusListener(onStatus);
    if (!done.isCompleted) done.complete();
  }

  secondary.addStatusListener(onStatus);
  return done.future;
}
