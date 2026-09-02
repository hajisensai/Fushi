/// OPDS 1.2（Atom XML）目录解析。
///
/// 覆盖范围：navigation feed、acquisition feed、`rel="next"` 分页、
/// `rel="search"` 的 OpenSearch 描述文档发现。产出统一的 [OpdsFeed]。
///
/// ## 命名空间：本文件的头号陷阱
///
/// OPDS feed 允许用任意前缀绑定 Atom / OPDS / Dublin Core 命名空间，实测
/// 各服务端写法完全不一致：Calibre-Web 发裸 `<entry>`，某些代理层发
/// `<atom:entry>`，Dublin Core 字段则是 `<dc:issued>` / `<dcterms:issued>`。
/// 而 `package:xml` 的 [XmlNode.findAllElements] 不传 `namespace` 时按
/// **qualified name** 匹配——`'entry'` 匹配不到 `<atom:entry>`，于是整个目录
/// 解析成 0 条，表现为「这个 OPDS 服务器连不上/是空的」。
///
/// 本仓在 EPUB 解析上已经栽过同一个跟头（见 `epub_parser.dart` 的
/// `_elements` 注释：Calibre 4.x 导出的 `<opf:item>` 让整本书 0 章）。
/// 修法同样不是逐个调用点补 `namespace: '*'`——那样下次新增查找还会漏——
/// 而是让按 local-name 匹配成为本文件里**唯一**的查找方式：所有按标签名/
/// 属性名的查找一律走下面三个原语。守卫见
/// `test/media/discovery/sources/opds_atom_namespace_test.dart`。
library;

import 'package:xml/xml.dart';

import 'package:fushi/src/media/discovery/sources/opds/opds_feed.dart';

/// OPDS 目录 feed 的 MIME 前缀（`kind=navigation` / `kind=acquisition` 都以此打头）。
const String kOpdsCatalogMediaType = 'application/atom+xml';

/// OpenSearch 描述文档的 MIME。
const String kOpenSearchDescriptionMediaType =
    'application/opensearchdescription+xml';

/// 解析一份 OPDS 1.2 Atom 目录。
///
/// [baseUri] 是本 feed 自身的地址，用于把相对 href resolve 成绝对 URL——
/// OPDS 服务端普遍发相对链接（`href="/opds/series/12"`），不 resolve 就没法请求。
OpdsFeed parseOpdsAtomFeed(String xml, {required Uri baseUri}) {
  final XmlDocument document = XmlDocument.parse(xml);
  final XmlElement? feed = _firstElement(document, 'feed');
  if (feed == null) {
    // OPDS「partial entry」：COPS / Calibre-Web 的出版物条目可以只带一条
    // `rel="alternate"` 的 catalog 链接，指向一份**根是 `<entry>` 而不是
    // `<feed>`** 的单条目文档，真正的 acquisition 链接在那份文档里。
    // 不兜这一形态的话，那种条目会渲染成一个点进去就报
    //「不是可读的 OPDS 目录」的死目录。
    final XmlElement? entry = _firstElement(document, 'entry');
    if (entry != null) {
      final OpdsEntry? parsed = _parseEntry(entry, baseUri);
      return OpdsFeed(
        entries: <OpdsEntry>[if (parsed != null) parsed],
      );
    }
    throw const FormatException('OPDS Atom document has no <feed> or <entry>');
  }

  String? nextHref;
  String? searchDescriptionHref;
  String? searchTemplate;
  for (final XmlElement link in _childElements(feed, 'link')) {
    final String? rel = _attribute(link, 'rel');
    final String? href = _attribute(link, 'href');
    if (href == null || href.trim().isEmpty) continue;
    final String resolved = _resolve(baseUri, href);
    switch (rel) {
      case 'next':
        nextHref = resolved;
      case 'search':
        final String type = _attribute(link, 'type') ?? '';
        // 两种写法都在野：指向 OpenSearch 描述文档（需二次抓取），
        // 或直接给一个含 {searchTerms} 的模板 URL。
        if (type.toLowerCase().startsWith(kOpenSearchDescriptionMediaType)) {
          searchDescriptionHref = resolved;
        } else if (href.contains('{searchTerms}')) {
          // 注意用未 resolve 的 href 判模板：Uri.resolve 会把 `{}` 百分号编码，
          // 之后再做字符串替换就永远匹配不上 `{searchTerms}` 了。
          searchTemplate = _resolveTemplate(baseUri, href);
        } else {
          searchDescriptionHref = resolved;
        }
      default:
        break;
    }
  }

  return OpdsFeed(
    entries: <OpdsEntry>[
      for (final XmlElement entry in _childElements(feed, 'entry'))
        if (_parseEntry(entry, baseUri) case final OpdsEntry parsed) parsed,
    ],
    nextHref: nextHref,
    searchTemplate: searchTemplate,
    searchDescriptionHref: searchDescriptionHref,
  );
}

/// 从 OpenSearch 描述文档里取出可用的搜索模板。
///
/// 择优：优先 Atom 类型的 `<Url>`，否则取第一条带 `{searchTerms}` 的。
/// 拿不到返回 null（源会退回「本源不支持搜索」，而不是把用户的关键词
/// 拼成一个无意义的 URL 打过去）。
String? parseOpenSearchTemplate(String xml, {required Uri baseUri}) {
  final XmlDocument document = XmlDocument.parse(xml);
  String? fallback;
  for (final XmlElement url in _elements(document, 'Url')) {
    final String? template = _attribute(url, 'template');
    if (template == null || !template.contains('{searchTerms}')) continue;
    final String resolved = _resolveTemplate(baseUri, template);
    final String type = (_attribute(url, 'type') ?? '').toLowerCase();
    if (type.startsWith(kOpdsCatalogMediaType)) return resolved;
    fallback ??= resolved;
  }
  return fallback;
}

/// 单个 `<entry>` → 导航条目或出版物条目。
///
/// 判据是**有没有可下载的 acquisition 链接**，不是「有没有 `kind=navigation`」：
/// 相当多的服务端在 acquisition feed 里根本不写 `kind` 参数，只靠 kind 判会
/// 把整个书目当成一堆点不开的目录。
OpdsEntry? _parseEntry(XmlElement entry, Uri baseUri) {
  final String title = _text(entry, 'title')?.trim() ?? '';
  if (title.isEmpty) return null;

  final List<OpdsAcquisitionLink> acquisitions = <OpdsAcquisitionLink>[];
  String? coverHref;
  String? navigationHref;
  int? itemCount;

  for (final XmlElement link in _childElements(entry, 'link')) {
    final String? href = _attribute(link, 'href');
    if (href == null || href.trim().isEmpty) continue;
    final String resolved = _resolve(baseUri, href);
    final String? rel = _attribute(link, 'rel');
    final String? type = _attribute(link, 'type');

    final OpdsAcquisitionRel? acquisitionRel = OpdsAcquisitionRel.fromRel(rel);
    if (acquisitionRel != null) {
      acquisitions.add(
        OpdsAcquisitionLink(
          href: resolved,
          rel: acquisitionRel,
          // MIME 优先，认不出再退回按 href 末段的扩展名定型。
          fileType: OpdsFileType.fromMediaType(type) ??
              OpdsFileType.fromPath(Uri.tryParse(resolved)?.path),
          sizeBytes: int.tryParse(_attribute(link, 'length') ?? ''),
        ),
      );
      continue;
    }

    switch (rel) {
      case 'http://opds-spec.org/image':
      case 'http://opds-spec.org/cover':
        coverHref = resolved;
      case 'http://opds-spec.org/image/thumbnail':
      case 'http://opds-spec.org/thumbnail':
        // 缩略图只在没有大图时用——列表页要的就是小图，但大图更通用。
        coverHref ??= resolved;
      case 'subsection':
      case 'collection':
      case null:
      case 'alternate':
        // 无 rel 或 subsection 的 catalog 链接就是下钻目标。
        if ((type ?? '').toLowerCase().startsWith(kOpdsCatalogMediaType)) {
          navigationHref ??= resolved;
          itemCount ??= int.tryParse(_attribute(link, 'count') ?? '');
        }
      default:
        break;
    }
  }

  if (acquisitions.isNotEmpty) {
    return OpdsPublicationEntry(
      title: title,
      // Atom <id> 缺失时退回首条 acquisition href：它在同一目录内足够唯一，
      // 而 DiscoveryResourceItem.id 只被当作去重/防重复入队的身份键。
      id: _text(entry, 'id')?.trim().isNotEmpty == true
          ? _text(entry, 'id')!.trim()
          : acquisitions.first.href,
      links: acquisitions,
      author: _authorName(entry),
      summary: (_text(entry, 'summary') ?? _text(entry, 'content'))?.trim(),
      updatedText: (_text(entry, 'updated') ?? _text(entry, 'issued'))?.trim(),
      coverHref: coverHref,
    );
  }

  if (navigationHref != null) {
    return OpdsNavigationEntry(
      title: title,
      href: navigationHref,
      summary: (_text(entry, 'summary') ?? _text(entry, 'content'))?.trim(),
      itemCount: itemCount,
    );
  }
  return null;
}

String? _authorName(XmlElement entry) {
  for (final XmlElement author in _childElements(entry, 'author')) {
    final String? name = _text(author, 'name')?.trim();
    if (name != null && name.isNotEmpty) return name;
  }
  return null;
}

/// 把相对 href resolve 成绝对 URL；解析不了就原样返回（总比丢掉链接好）。
String _resolve(Uri baseUri, String href) {
  try {
    return baseUri.resolve(href.trim()).toString();
  } on FormatException {
    return href.trim();
  }
}

/// 模板专用的 resolve：`{searchTerms}` 里的花括号不能被百分号编码，
/// 否则之后的字符串替换永远匹配不上。做法是先把占位符换成安全令牌、
/// resolve、再换回来。
String _resolveTemplate(Uri baseUri, String template) {
  const String token = 'FUSHIOPDSSEARCHTOKEN';
  final String masked = template.trim().replaceAll('{searchTerms}', token);
  final String resolved = _resolve(baseUri, masked);
  return resolved.replaceAll(token, '{searchTerms}');
}

// ── XML lookup primitives ────────────────────────────────────────────────────
// 本文件里所有按标签名/属性名的查找**必须**走这四个原语（见库文档注释）。

/// 全树按 local-name 查找。
Iterable<XmlElement> _elements(XmlNode node, String localName) =>
    node.findAllElements(localName, namespace: '*');

/// 直接子元素按 local-name 查找。
Iterable<XmlElement> _childElements(XmlElement parent, String localName) =>
    parent.findElements(localName, namespace: '*');

/// 全树第一个匹配元素。
XmlElement? _firstElement(XmlNode node, String localName) {
  for (final XmlElement element in _elements(node, localName)) {
    return element;
  }
  return null;
}

/// 直接子元素的文本内容。
String? _text(XmlElement parent, String localName) {
  for (final XmlElement element in _childElements(parent, localName)) {
    return element.innerText;
  }
  return null;
}

/// 属性按 local-name 查找：`thr:count` / `opds:facetGroup` 这类带前缀的属性
/// 用裸 `getAttribute('count')` 同样取不到。
String? _attribute(XmlElement element, String localName) =>
    element.getAttribute(localName) ??
    element.getAttribute(localName, namespace: '*');
