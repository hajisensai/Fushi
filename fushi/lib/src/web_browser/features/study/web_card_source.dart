import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';

/// 浏览器里查词制卡时这张卡的来源：页面标题 + 网址。
///
/// 去向（需要接线，见报告）：标题进 `AnkiMiningContext.documentTitle`（卡面
/// `{document-title}`），网址进 `{source-link}`（无库内定位 `CardSourceLink` 时渲染成
/// 指向原网页的链接，见 [toSourceLinkHtml]）。
@immutable
class WebBrowserCardSource {
  const WebBrowserCardSource({required this.title, required this.url});

  final String title;
  final Uri url;

  /// `{source-link}` 的 HTML：`<a href="网址">标题</a>`（无标题时用主机名）。
  String toSourceLinkHtml() {
    final String label = title.trim().isEmpty ? url.host : title.trim();
    return '<a href="${const HtmlEscape(HtmlEscapeMode.attribute).convert(url.toString())}">'
        '${const HtmlEscape(HtmlEscapeMode.element).convert(label)}</a>';
  }

  @override
  bool operator ==(Object other) =>
      other is WebBrowserCardSource && other.title == title && other.url == url;

  @override
  int get hashCode => Object.hash(title, url);
}

/// 标签页当前页面作为卡片来源。只认 http(s)；无痕标签页返回 null（不把浏览痕迹写进
/// 卡片——卡片会随牌组分享 / 同步出去）。网址去掉片段（`#…` 只是页内锚点）。
WebBrowserCardSource? webBrowserCardSourceOf(WebBrowserTab tab) {
  if (tab.incognito) return null;
  final Uri? url = tab.url;
  if (url == null || (url.scheme != 'http' && url.scheme != 'https')) {
    return null;
  }
  return WebBrowserCardSource(
    title: tab.displayTitle,
    url: url.hasFragment ? url.removeFragment() : url,
  );
}
