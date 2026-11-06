import 'dart:async';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/web_browser/features/web_browser_feature.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';

/// 网页内容是哪一类可以交给 Fushi 的东西：决定浏览器工具条上那一个上下文按钮
/// （「用 Fushi 播放」/「用 Fushi 阅读」，见 `web_open_in_fushi_action.dart`）。
enum WebPageContentKind { video, comic, novel }

/// 页面内容探针的读数（[kWebPageContentProbeScript] 的结果）。
@immutable
class WebPageContentProbe {
  const WebPageContentProbe({
    required this.largeVideos,
    required this.tallImages,
    required this.textLength,
    this.pageSurfaces = const <Size>[],
    this.viewport = Size.zero,
    this.scrolls = true,
  });

  /// 解析探针返回的 JSON；坏数据返回 null。
  static WebPageContentProbe? tryParse(Object? raw) {
    Object? decoded = raw;
    if (raw is String) {
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        return null;
      }
    }
    if (decoded is! Map) return null;
    int read(String key) {
      final Object? v = decoded is Map ? decoded[key] : null;
      return v is num ? v.toInt() : 0;
    }

    final List<Size> surfaces = <Size>[];
    final Object? rawSurfaces = decoded['p'];
    if (rawSurfaces is List) {
      for (final Object? entry in rawSurfaces) {
        if (entry is List &&
            entry.length == 2 &&
            entry[0] is num &&
            entry[1] is num) {
          surfaces.add(
            Size((entry[0] as num).toDouble(), (entry[1] as num).toDouble()),
          );
        }
      }
    }
    return WebPageContentProbe(
      largeVideos: read('v'),
      tallImages: read('i'),
      textLength: read('t'),
      pageSurfaces: surfaces,
      viewport: Size(read('w').toDouble(), read('h').toDouble()),
      // 缺项按「会滚动」：老读数 / 坏数据不触发翻页规则。
      scrolls: decoded['s'] != 0,
    );
  }

  /// 画面够大（≥ 320×180 且占视口宽度四成以上）的 `<video>` 个数。缩略图悬停预览不算。
  final int largeVideos;

  /// 漫画页那种竖长大图（渲染高 ≥ 400、宽占视口四成以上）的张数。
  final int tallImages;

  /// 最长一段正文的字数：同一个父元素下所有 `<p>` 的字数之和取最大。
  final int textLength;

  /// 视口里铺开的大块图面（渲染尺寸，CSS px）：在视口取样点下面、本身带一张够大的图的
  /// `<img>` / `<canvas>` / 背景图元素。翻页式阅读器（canvas 绘页、背景图贴页、一屏一两页
  /// 的 `<img>`）的「页」就是它们，[tallImages] 数不到这种页面（反馈 tNQr1gO6_2）。
  final List<Size> pageSurfaces;

  /// 视口尺寸（CSS px）；[Size.zero] = 读数里没有。
  final Size viewport;

  /// 文档能否纵向滚出视口很多（滚动高度 > 1.5 屏）。翻页阅读器一屏就是全部。
  final bool scrolls;
}

/// 小说正文的最少字数：一章网络小说远多于此，导航 / 简介 / 评论区很少超过。
const int kWebPageNovelMinTextLength = 1500;

/// 认作漫画页的最少竖长图张数。
const int kWebPageComicMinImages = 3;

/// 正文再长，竖长图多到这个数也算漫画（带对白文字稿的漫画站）。
const int kWebPageComicDominantImages = 8;

/// 翻页式漫画页的正文上限：比这多的 `<p>` 正文就不是「一屏只有页面图」。
const int kWebPageFlipMaxText = 300;

/// 一张图面算「漫画页」要占的最少视口高度比例。
const double kWebPageFlipMinHeightFraction = 0.6;

/// 一张图面算「漫画页」要占的最少视口宽度比例（跨页里的单页约三分之一屏宽）。
const double kWebPageFlipMinWidthFraction = 0.2;

/// 单页的高宽比区间（B6 / A5 / 单行本约 1.41–1.5，留余量）。
const double kWebPageSinglePageMinAspect = 1.25;
const double kWebPageSinglePageMaxAspect = 1.65;

/// 跨页（两页拼成一张图面）的高宽比区间：两张单页约 0.70–0.75。下限收紧到 0.66，
/// 让 16:10 / 平板横屏的整屏画布（约 0.58–0.63）落在外面。
const double kWebPageSpreadMinAspect = 0.66;
const double kWebPageSpreadMaxAspect = kWebPageSinglePageMaxAspect / 2;

/// [surface] 是不是一张占屏的漫画页（或跨页）：够高、够宽、形状像书页。只看形状不看
/// 域名——整屏地图 / 游戏画布是 16:9 横幅或竖长全屏，落不进书页的高宽比区间。
bool isWebPageFlipPageSurface(Size surface, Size viewport) {
  if (viewport.width <= 0 || viewport.height <= 0) return false;
  if (surface.width <= 0 || surface.height <= 0) return false;
  final double minHeight = viewport.height * kWebPageFlipMinHeightFraction;
  if (surface.height < (minHeight > 400 ? minHeight : 400)) return false;
  if (surface.width < viewport.width * kWebPageFlipMinWidthFraction) {
    return false;
  }
  final double aspect = surface.height / surface.width;
  return (aspect >= kWebPageSinglePageMinAspect &&
          aspect <= kWebPageSinglePageMaxAspect) ||
      (aspect >= kWebPageSpreadMinAspect && aspect <= kWebPageSpreadMaxAspect);
}

/// 读数 → 内容类别（纯函数）；认不出返回 null（三个入口都收在「⋯」里）。
WebPageContentKind? classifyWebPageContent(WebPageContentProbe probe) {
  if (probe.largeVideos > 0) return WebPageContentKind.video;
  if (probe.tallImages >= kWebPageComicDominantImages) {
    return WebPageContentKind.comic;
  }
  if (probe.textLength >= kWebPageNovelMinTextLength) {
    return WebPageContentKind.novel;
  }
  if (probe.tallImages >= kWebPageComicMinImages) {
    return WebPageContentKind.comic;
  }
  // 翻页阅读器：一屏就是全部（不长滚动），屏上铺着书页形状的大图面，几乎没有正文。
  if (!probe.scrolls &&
      probe.textLength < kWebPageFlipMaxText &&
      probe.pageSurfaces.any(
        (Size s) => isWebPageFlipPageSurface(s, probe.viewport),
      )) {
    return WebPageContentKind.comic;
  }
  return null;
}

/// 只读探针：数大视频、竖长图与最长正文段，在视口 5×3 个取样点下收大块图面（`<img>`
/// 原图高 ≥ 600 / `<canvas>` 位图高 ≥ 600 / 背景图是 url 的元素，每点只看最上面 6 层），
/// 再记视口尺寸与文档是否长滚动，返回 JSON 字符串。不改页面。
const String kWebPageContentProbeScript =
    '(function(){var W=window.innerWidth||1,H=window.innerHeight||1;'
    'var v=0,i=0,t=0,P=[],s=0;'
    'var vs=document.querySelectorAll("video");'
    'for(var a=0;a<vs.length;a++){var r=vs[a].getBoundingClientRect();'
    'if(r.width>=320&&r.height>=180&&r.width>=W*0.4)v++;}'
    'var is=document.images;'
    'for(var b=0;b<is.length;b++){var m=is[b];var q=m.getBoundingClientRect();'
    'if(q.height>=400&&q.width>=W*0.4&&(m.naturalHeight||0)>=600)i++;}'
    'var ps=document.querySelectorAll("p");var sums=new Map();'
    'for(var c=0;c<ps.length;c++){var p=ps[c].parentElement;'
    'var n=(sums.get(p)||0)+(ps[c].textContent||"").trim().length;'
    'sums.set(p,n);if(n>t)t=n;}'
    'if(document.elementsFromPoint){var seen=new Set();'
    'var xs=[0.15,0.325,0.5,0.675,0.85],ys=[0.3,0.5,0.7];'
    'for(var x=0;x<xs.length;x++)for(var y=0;y<ys.length;y++){'
    'var es=document.elementsFromPoint(W*xs[x],H*ys[y]);'
    'for(var k=0;k<es.length&&k<6;k++){var e=es[k];'
    'if(seen.has(e))continue;seen.add(e);var g=e.getBoundingClientRect();'
    'if(g.height<400||g.width<W*0.2)continue;var tg=e.tagName;'
    'var ok=tg==="CANVAS"?(e.height||0)>=600:tg==="IMG"?'
    '(e.naturalHeight||0)>=600:(getComputedStyle(e).backgroundImage||"")'
    '.indexOf("url(")>=0;'
    'if(ok&&P.length<8)P.push([Math.round(g.width),Math.round(g.height)]);}}}'
    'var se=document.scrollingElement||document.documentElement;'
    's=se&&se.scrollHeight>H*1.5?1:0;'
    'return JSON.stringify({v:v,i:i,t:t,p:P,w:W,h:H,s:s});})();';

/// 按标签页探测页面内容（[WebPageContentKind]），供「用 Fushi 播放 / 阅读」三个功能决定
/// 谁上工具栏。每次主框架加载完、单页应用换页、标签页回到前台时探一次；结果变了经
/// [actionsChanged] 让壳重建工具栏。本身不贡献动作。
class WebPageContentFeature extends WebBrowserFeature {
  final Map<String, WebPageContentKind?> _kinds =
      <String, WebPageContentKind?>{};

  /// 每个标签页最近一次探测的序号：慢的旧结果不盖掉新页面的。
  final Map<String, int> _generation = <String, int>{};
  final WebBrowserFeatureNotifier _changed = WebBrowserFeatureNotifier();

  @override
  String get id => 'page_content';

  @override
  Listenable get actionsChanged => _changed;

  /// [tab] 当前页面的内容类别；没探过 / 认不出为 null。
  WebPageContentKind? kindOf(WebBrowserTab tab) => _kinds[tab.id];

  @override
  Future<void> onLoadStop(
    WebBrowserTab tab,
    InAppWebViewController controller,
    Uri? url,
  ) => probe(tab, controller);

  @override
  void onUrlChanged(
    BuildContext context,
    WebBrowserTab tab,
    InAppWebViewController controller,
    Uri? url,
  ) {
    // 换页了：旧页面的类别作废，新页面探到之前三个入口都在「⋯」里。
    _set(tab, null);
    unawaited(probe(tab, controller));
  }

  @override
  void onTabActiveChanged(WebBrowserTab tab, {required bool active}) {
    final InAppWebViewController? controller = tab.controller;
    if (active && controller != null) unawaited(probe(tab, controller));
  }

  @override
  void onTabClosed(WebBrowserTab tab) {
    _kinds.remove(tab.id);
    _generation.remove(tab.id);
  }

  /// 测试用：直接记下 [tab] 的类别（不跑探针）。
  @visibleForTesting
  void debugSetKind(WebBrowserTab tab, WebPageContentKind? kind) =>
      _set(tab, kind);

  /// 探一次 [tab] 的页面并记下类别。
  Future<void> probe(
    WebBrowserTab tab,
    InAppWebViewController controller,
  ) async {
    final int generation = (_generation[tab.id] ?? 0) + 1;
    _generation[tab.id] = generation;
    final Uri? url = tab.url;
    if (url == null || (url.scheme != 'http' && url.scheme != 'https')) {
      _set(tab, null);
      return;
    }
    Object? raw;
    try {
      raw = await controller.evaluateJavascript(
        source: kWebPageContentProbeScript,
      );
    } catch (e) {
      // 页面正在导航 / WebView 已回收：下一次 onLoadStop 再探。
      debugPrint('[web-browser] page content probe failed: $e');
      return;
    }
    if (_generation[tab.id] != generation || tab.url != url) return;
    final WebPageContentProbe? reading = WebPageContentProbe.tryParse(raw);
    _set(tab, reading == null ? null : classifyWebPageContent(reading));
  }

  void _set(WebBrowserTab tab, WebPageContentKind? kind) {
    if (_kinds.containsKey(tab.id) && _kinds[tab.id] == kind) return;
    _kinds[tab.id] = kind;
    _changed.notify();
  }

  @override
  void dispose() => _changed.dispose();
}
