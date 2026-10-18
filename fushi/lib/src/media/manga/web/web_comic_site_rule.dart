import 'dart:convert';

import 'package:flutter/foundation.dart';

/// 网页漫画的站点规则（`assets/web_comic/site_rules.json`）。
///
/// 规则只描述**站点知识**（哪些 URL 是章节页、图从哪里取、要带什么 Referer /
/// 请求头、上下章链接在哪），执行全在注入的扫图脚本里；没有命中规则的页面走
/// 脚本的通用自动扫图。规则只来自随包资产（可信），本期不开放用户自定义——
/// `script` 取图方式会在页面里执行任意代码，开放给用户粘贴等于开放注入。
///
/// 每条规则都带 [verified]：没有在真机上走通「打开章节 → 交给阅读器 → 翻完」的
/// 规则一律 `false`，UI 不据此做任何承诺，只是给维护者看的状态位。
@immutable
class WebComicSiteRule {
  const WebComicSiteRule({
    required this.id,
    required this.name,
    required this.hosts,
    required this.chapterUrlPattern,
    required this.images,
    this.seriesKeyPattern,
    this.referer = WebComicRefererMode.page,
    this.refererUrl,
    this.headers = const <String, String>{},
    this.nextSelector,
    this.prevSelector,
    this.verified = false,
  });

  /// 稳定 id（进章节 raw，换章 / 重扫时据此找回规则）。
  final String id;
  final String name;

  /// 命中的 host：精确 host，或 `*.example.com`（匹配 example.com 本身与任意子域）。
  final List<String> hosts;

  /// 匹配 `path + ?query` 的正则；命中才算章节页。可带命名分组，供 [images]
  /// 模板里的 `{name}` 引用。
  final String chapterUrlPattern;

  /// 从**完整 URL** 推出作品身份的正则（第一个捕获组）；null / 不命中 = 以章节
  /// URL 本身当作品身份（一章一本书）。
  final String? seriesKeyPattern;

  final WebComicImageSource images;
  final WebComicRefererMode referer;

  /// [referer] 为 [WebComicRefererMode.fixed] 时用的固定 Referer。
  final String? refererUrl;

  /// 取图时额外带的请求头（Referer / Cookie / User-Agent 由宿主管，不在这里写）。
  final Map<String, String> headers;

  /// 下一章 / 上一章链接的 CSS 选择器（取 `href`）；null = 走脚本的通用文案匹配。
  final String? nextSelector;
  final String? prevSelector;
  final bool verified;

  /// 该规则是否覆盖 [host]。
  bool matchesHost(String host) {
    final String lower = host.toLowerCase();
    for (final String pattern in hosts) {
      final String p = pattern.toLowerCase();
      if (p.startsWith('*.')) {
        final String base = p.substring(2);
        if (lower == base || lower.endsWith('.$base')) return true;
      } else if (lower == p) {
        return true;
      }
    }
    return false;
  }

  /// [url] 是不是本规则的章节页（host 命中且 path+query 命中 [chapterUrlPattern]）。
  bool matchesChapter(Uri url) =>
      matchesHost(url.host) && chapterMatch(url) != null;

  /// 章节正则对 `path + ?query` 的匹配结果（带命名分组）；不命中返回 null。
  RegExpMatch? chapterMatch(Uri url) {
    final String target = url.hasQuery ? '${url.path}?${url.query}' : url.path;
    return RegExp(chapterUrlPattern).firstMatch(target);
  }

  /// 作品身份：[seriesKeyPattern] 第一个捕获组拼上 host；不命中返回 null。
  String? seriesKeyOf(Uri url) {
    final String? pattern = seriesKeyPattern;
    if (pattern == null || pattern.isEmpty) return null;
    final RegExpMatch? match = RegExp(pattern).firstMatch(url.toString());
    if (match == null || match.groupCount < 1) return null;
    final String? group = match.group(1);
    if (group == null || group.isEmpty) return null;
    return '${url.host.toLowerCase()}/$group';
  }

  /// 交给扫图脚本的配置（脚本只认这一份形状）。
  Map<String, Object?> toScriptConfig() => <String, Object?>{
    'id': id,
    'chapterUrlPattern': chapterUrlPattern,
    'images': images.toJson(),
    if (nextSelector != null) 'nextSelector': nextSelector,
    if (prevSelector != null) 'prevSelector': prevSelector,
  };

  /// 解析一条规则；缺必填字段 / 正则编译不过返回 null（坏规则不能拖垮整份表）。
  static WebComicSiteRule? tryParse(Object? json) {
    if (json is! Map) return null;
    final Map<String, Object?> map = json.cast<String, Object?>();
    final String id = map['id']?.toString().trim() ?? '';
    final String name = map['name']?.toString().trim() ?? '';
    final Object? rawHosts = map['hosts'];
    final List<String> hosts = rawHosts is List
        ? <String>[
            for (final Object? host in rawHosts)
              if (host != null && host.toString().trim().isNotEmpty)
                host.toString().trim(),
          ]
        : const <String>[];
    final String pattern = map['chapterUrlPattern']?.toString() ?? '';
    final WebComicImageSource? images = WebComicImageSource.tryParse(
      map['images'],
    );
    if (id.isEmpty ||
        name.isEmpty ||
        hosts.isEmpty ||
        pattern.isEmpty ||
        images == null ||
        !_compiles(pattern)) {
      return null;
    }
    final String? seriesPattern = _nonEmpty(map['seriesKeyPattern']);
    if (seriesPattern != null && !_compiles(seriesPattern)) return null;
    final WebComicRefererMode referer = WebComicRefererMode.fromWire(
      map['referer']?.toString(),
    );
    final String? refererUrl = _nonEmpty(map['refererUrl']);
    if (referer == WebComicRefererMode.fixed &&
        (refererUrl == null || Uri.tryParse(refererUrl)?.hasScheme != true)) {
      return null;
    }
    final Object? rawHeaders = map['headers'];
    return WebComicSiteRule(
      id: id,
      name: name,
      hosts: List<String>.unmodifiable(hosts),
      chapterUrlPattern: pattern,
      seriesKeyPattern: seriesPattern,
      images: images,
      referer: referer,
      refererUrl: refererUrl,
      headers: rawHeaders is Map
          ? Map<String, String>.unmodifiable(<String, String>{
              for (final MapEntry<Object?, Object?> e in rawHeaders.entries)
                if (e.key != null && e.value != null)
                  e.key.toString(): e.value.toString(),
            })
          : const <String, String>{},
      nextSelector: _nonEmpty(map['nextSelector']),
      prevSelector: _nonEmpty(map['prevSelector']),
      verified: map['verified'] == true,
    );
  }

  static bool _compiles(String pattern) {
    try {
      RegExp(pattern);
      return true;
    } on FormatException {
      return false;
    }
  }

  static String? _nonEmpty(Object? value) {
    final String? text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }
}

/// Referer 怎么定。
enum WebComicRefererMode {
  /// 章节页完整 URL（默认，最接近浏览器真实行为）。
  page('page'),

  /// 章节页的 origin + `/`（部分 CDN 只认站点根）。
  origin('origin'),

  /// 规则里写死的地址（[WebComicSiteRule.refererUrl]）。
  fixed('fixed'),

  /// 不带 Referer（带了反而被拒的公开 CDN）。
  none('none');

  const WebComicRefererMode(this.wireValue);

  final String wireValue;

  static WebComicRefererMode fromWire(String? value) {
    for (final WebComicRefererMode mode in WebComicRefererMode.values) {
      if (mode.wireValue == value) return mode;
    }
    return WebComicRefererMode.page;
  }
}

/// 取图方式。四种形状各自只带自己需要的字段，脚本按 `mode` 分派。
sealed class WebComicImageSource {
  const WebComicImageSource();

  String get mode;

  Map<String, Object?> toJson();

  static WebComicImageSource? tryParse(Object? json) {
    if (json is! Map) return null;
    final Map<String, Object?> map = json.cast<String, Object?>();
    switch (map['mode']?.toString()) {
      case 'dom':
        final String selector = map['selector']?.toString().trim() ?? '';
        if (selector.isEmpty) return null;
        final Object? attrs = map['attributes'];
        return WebComicDomImageSource(
          selector: selector,
          attributes: attrs is List && attrs.isNotEmpty
              ? List<String>.unmodifiable(<String>[
                  for (final Object? a in attrs)
                    if (a != null) a.toString(),
                ])
              : const <String>['src'],
          scroll: map['scroll'] == true,
        );
      case 'global':
        final String path = map['path']?.toString().trim() ?? '';
        if (path.isEmpty) return null;
        final String? regex = map['regex']?.toString();
        if (regex != null && regex.isNotEmpty && !_compiles(regex)) {
          return null;
        }
        return WebComicGlobalImageSource(
          path: path,
          regex: regex == null || regex.isEmpty ? null : regex,
          imageTemplate: map['imageTemplate']?.toString(),
        );
      case 'api':
        final String url = map['url']?.toString().trim() ?? '';
        final String itemsPath = map['itemsPath']?.toString().trim() ?? '';
        if (url.isEmpty || itemsPath.isEmpty) return null;
        final String method = (map['method']?.toString() ?? 'GET')
            .toUpperCase();
        if (method != 'GET' && method != 'POST') return null;
        final Object? body = map['body'];
        return WebComicApiImageSource(
          url: url,
          method: method,
          body: body == null
              ? null
              : body is String
              ? body
              : jsonEncode(body),
          contentType: map['contentType']?.toString(),
          itemsPath: itemsPath,
          imageTemplate: map['imageTemplate']?.toString() ?? '{item}',
        );
      case 'script':
        final String code = map['code']?.toString() ?? '';
        if (code.trim().isEmpty) return null;
        return WebComicScriptImageSource(code: code);
    }
    return null;
  }

  static bool _compiles(String pattern) {
    try {
      RegExp(pattern);
      return true;
    } on FormatException {
      return false;
    }
  }
}

/// 按选择器取 `<img>`，按 [attributes] 顺序取第一个非空属性。
class WebComicDomImageSource extends WebComicImageSource {
  const WebComicDomImageSource({
    required this.selector,
    required this.attributes,
    this.scroll = false,
  });

  final String selector;
  final List<String> attributes;

  /// 先滚一遍页面触发懒加载再取。
  final bool scroll;

  @override
  String get mode => 'dom';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'mode': mode,
    'selector': selector,
    'attributes': attributes,
    'scroll': scroll,
  };
}

/// 读页面全局变量（点路径）；值是数组直接用，是字符串则用 [regex] 全局匹配
/// 第一个捕获组。[imageTemplate] 里 `{item}` 是取到的每一项。
class WebComicGlobalImageSource extends WebComicImageSource {
  const WebComicGlobalImageSource({
    required this.path,
    this.regex,
    this.imageTemplate,
  });

  final String path;
  final String? regex;
  final String? imageTemplate;

  @override
  String get mode => 'global';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'mode': mode,
    'path': path,
    if (regex != null) 'regex': regex,
    if (imageTemplate != null) 'imageTemplate': imageTemplate,
  };
}

/// 在页面上下文里请求站点 API（带页面 cookie）。
///
/// 模板占位：`{name}` = 章节正则的命名分组，`{origin}` = 页面 origin，
/// `{$a.b}` = 响应 JSON 的根路径，`{item}` / `{item.x}` = [itemsPath] 数组的每项。
class WebComicApiImageSource extends WebComicImageSource {
  const WebComicApiImageSource({
    required this.url,
    required this.method,
    required this.itemsPath,
    required this.imageTemplate,
    this.body,
    this.contentType,
  });

  final String url;
  final String method;
  final String? body;
  final String? contentType;
  final String itemsPath;
  final String imageTemplate;

  @override
  String get mode => 'api';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'mode': mode,
    'url': url,
    'method': method,
    if (body != null) 'body': body,
    if (contentType != null) 'contentType': contentType,
    'itemsPath': itemsPath,
    'imageTemplate': imageTemplate,
  };
}

/// 兜底：一段函数体（可 `await`），返回图片 URL 数组。只允许随包规则使用。
class WebComicScriptImageSource extends WebComicImageSource {
  const WebComicScriptImageSource({required this.code});

  final String code;

  @override
  String get mode => 'script';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'mode': mode,
    'code': code,
  };
}

/// 一份规则表。
@immutable
class WebComicRuleSet {
  const WebComicRuleSet(this.rules);

  static const WebComicRuleSet empty = WebComicRuleSet(<WebComicSiteRule>[]);

  final List<WebComicSiteRule> rules;

  /// 解析 `site_rules.json`；坏条目跳过，整份坏了返回空表（通用扫图照常可用）。
  static WebComicRuleSet parse(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      return empty;
    }
    final Object? list = decoded is Map ? decoded['rules'] : decoded;
    if (list is! List) return empty;
    final List<WebComicSiteRule> rules = <WebComicSiteRule>[];
    final Set<String> ids = <String>{};
    for (final Object? item in list) {
      final WebComicSiteRule? rule = WebComicSiteRule.tryParse(item);
      if (rule == null || !ids.add(rule.id)) continue;
      rules.add(rule);
    }
    return WebComicRuleSet(List<WebComicSiteRule>.unmodifiable(rules));
  }

  /// [url] 命中的章节规则（host + 章节正则都命中）；没有返回 null。
  WebComicSiteRule? matchChapter(Uri url) {
    for (final WebComicSiteRule rule in rules) {
      if (rule.matchesChapter(url)) return rule;
    }
    return null;
  }

  WebComicSiteRule? byId(String? id) {
    if (id == null) return null;
    for (final WebComicSiteRule rule in rules) {
      if (rule.id == id) return rule;
    }
    return null;
  }
}
