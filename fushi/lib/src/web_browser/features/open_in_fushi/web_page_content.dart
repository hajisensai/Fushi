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

    return WebPageContentProbe(
      largeVideos: read('v'),
      tallImages: read('i'),
      textLength: read('t'),
    );
  }

  /// 画面够大（≥ 320×180 且占视口宽度四成以上）的 `<video>` 个数。缩略图悬停预览不算。
  final int largeVideos;

  /// 漫画页那种竖长大图（渲染高 ≥ 400、宽占视口四成以上）的张数。
  final int tallImages;

  /// 最长一段正文的字数：同一个父元素下所有 `<p>` 的字数之和取最大。
  final int textLength;
}

/// 小说正文的最少字数：一章网络小说远多于此，导航 / 简介 / 评论区很少超过。
const int kWebPageNovelMinTextLength = 1500;

/// 认作漫画页的最少竖长图张数。
const int kWebPageComicMinImages = 3;

/// 正文再长，竖长图多到这个数也算漫画（带对白文字稿的漫画站）。
const int kWebPageComicDominantImages = 8;

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
  return null;
}

/// 只读探针：数大视频、竖长图与最长正文段，返回 JSON 字符串。不改页面。
const String kWebPageContentProbeScript =
    '(function(){var W=window.innerWidth||1;var v=0,i=0,t=0;'
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
    'return JSON.stringify({v:v,i:i,t:t});})();';

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
