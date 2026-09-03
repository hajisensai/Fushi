/// OPDS 2.0（JSON）目录解析。产出与 1.2 完全相同的 [OpdsFeed]。
///
/// 2.0 是 Readium Web Publication Manifest 的一族：顶层是
/// `metadata` / `links` / `navigation` / `groups` / `publications`。
/// Kavita 0.8+ 只发这一版；Komga 两版都发。
///
/// ## 两处必须在**解析边界**归一的方言差异
///
/// 1. **搜索模板**：1.2 用 OpenSearch 的 `{searchTerms}`，2.0 用 RFC 6570 的
///    `{?query}` / `{&query}`。两种都留到下游，替换逻辑就得写两遍并各自
///    带一套边界（`?` 还是 `&`）。这里统一转成 `{searchTerms}`，下游只留一条规则。
/// 2. **标量字段的多形态**：`metadata.author` 在野有三种写法——字符串、
///    `{"name": "..."}`、以及两者的数组；`title` 还可能是语言映射
///    `{"en": "..."}`。不在这里收敛，`as String` 会在真实服务器上直接抛。
library;

import 'dart:convert';

import 'package:fushi/src/media/discovery/sources/opds/opds_feed.dart';

/// OPDS 2.0 的 feed MIME。
const String kOpdsJsonMediaType = 'application/opds+json';

/// 解析一份 OPDS 2.0 JSON 目录。
///
/// [baseUri] 用于把相对 href resolve 成绝对 URL。
OpdsFeed parseOpdsJsonFeed(String body, {required Uri baseUri}) {
  final Object? decoded = jsonDecode(body);
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('OPDS 2.0 feed root is not a JSON object');
  }

  String? nextHref;
  String? searchTemplate;
  String? searchDescriptionHref;
  for (final Map<String, Object?> link in _mapList(decoded['links'])) {
    final String? href = _string(link['href']);
    if (href == null) continue;
    final Set<String> rels = _rels(link['rel']);
    if (rels.contains('next')) {
      nextHref ??= _resolve(baseUri, href);
    }
    if (rels.contains('search')) {
      // 与 1.2 侧同一条判据（`opds_atom_parser.dart` 的 `case 'search'`）：
      // 只有**带模板占位符**的 href 才是能直接用的搜索模板。非模板的 search
      // link（OpenSearch 描述文档，或服务端只给了一个搜索页地址）必须走
      // searchDescriptionHref 二次抓取——把它当模板用的话，下游
      // `replaceAll('{searchTerms}', …)` 替换 0 次，**用户的关键词被静默丢掉，
      // 服务端返回的是未过滤的全量结果**：用户以为搜到了，其实搜索没生效。
      if (_hasSearchTemplateToken(href)) {
        searchTemplate ??= _normalizeSearchTemplate(baseUri, href);
      } else {
        searchDescriptionHref ??= _resolve(baseUri, href);
      }
    }
  }

  final List<OpdsEntry> entries = <OpdsEntry>[
    ..._navigation(decoded['navigation'], baseUri),
    ..._publications(decoded['publications'], baseUri),
  ];
  // groups 是服务端分好的展示分组（「最近添加」「随机」…）。本仓发现页是
  // 平铺列表，这里按文档顺序摊平；分组标题本身不产生条目——它不可下钻，
  // 造一个点不开的目录只会让用户以为是坏链接。
  for (final Map<String, Object?> group in _mapList(decoded['groups'])) {
    entries
      ..addAll(_navigation(group['navigation'], baseUri))
      ..addAll(_publications(group['publications'], baseUri));
  }

  return OpdsFeed(
    entries: entries,
    nextHref: nextHref,
    searchTemplate: searchTemplate,
    searchDescriptionHref: searchDescriptionHref,
  );
}

List<OpdsEntry> _navigation(Object? raw, Uri baseUri) => <OpdsEntry>[
      for (final Map<String, Object?> item in _mapList(raw))
        if (_string(item['href']) case final String href)
          if (_title(item['title']) ?? _title(_map(item['metadata'])?['title'])
              case final String title)
            OpdsNavigationEntry(
              title: title,
              href: _resolve(baseUri, href),
              summary: _title(_map(item['metadata'])?['description']),
              itemCount: _int(_map(item['metadata'])?['numberOfItems']),
            ),
    ];

List<OpdsEntry> _publications(Object? raw, Uri baseUri) => <OpdsEntry>[
      for (final Map<String, Object?> item in _mapList(raw))
        if (_publication(item, baseUri) case final OpdsPublicationEntry entry)
          entry,
    ];

OpdsPublicationEntry? _publication(Map<String, Object?> raw, Uri baseUri) {
  final Map<String, Object?>? metadata = _map(raw['metadata']);
  final String? title = _title(metadata?['title']);
  if (title == null || title.trim().isEmpty) return null;

  final List<OpdsAcquisitionLink> links = <OpdsAcquisitionLink>[];
  for (final Map<String, Object?> link in _mapList(raw['links'])) {
    final String? href = _string(link['href']);
    if (href == null) continue;
    final String resolved = _resolve(baseUri, href);
    final Set<String> rels = _rels(link['rel']);
    OpdsAcquisitionRel? rel;
    for (final String candidate in rels) {
      rel = OpdsAcquisitionRel.fromRel(candidate);
      if (rel != null) break;
    }
    // OPDS 2.0 里 acquisition link **省略 `rel` 是合法写法**——`links` 长在
    // publication 底下，位置本身已经说明它是这本书的获取链接。按「没 rel 就
    // 跳过」处理会让这条 link 被丢掉，links 随之为空，**整条出版物消失**：
    // 用户看到的是「这个目录里少了一半书」，而且没有任何报错。
    // 有 rel 但没有一个是 acquisition rel（`self` / `alternate` / `cover`）
    // 仍然跳过——那些确实不是下载链接。
    if (rel == null && rels.isNotEmpty) continue;
    rel ??= OpdsAcquisitionRel.generic;
    final String? type = _string(link['type']);
    links.add(
      OpdsAcquisitionLink(
        href: resolved,
        rel: rel,
        fileType: OpdsFileType.fromMediaType(type) ??
            OpdsFileType.fromPath(Uri.tryParse(resolved)?.path),
        // 2.0 的体积字段是 properties.encrypted 之外的 `length`（少见）
        // 或 metadata 里的 `numberOfPages`——后者不是字节数，别拿来冒充。
        sizeBytes: _int(link['length']),
      ),
    );
  }
  if (links.isEmpty) return null;

  String? cover;
  for (final Map<String, Object?> image in _mapList(raw['images'])) {
    final String? href = _string(image['href']);
    if (href != null) {
      cover = _resolve(baseUri, href);
      break;
    }
  }

  return OpdsPublicationEntry(
    title: title,
    id: _string(metadata?['identifier']) ?? links.first.href,
    links: links,
    author: _contributor(metadata?['author']),
    summary: _title(metadata?['description']),
    updatedText:
        _string(metadata?['modified']) ?? _string(metadata?['published']),
    coverHref: cover,
  );
}

/// `{?query}` / `{&query}` / `{query}` → `{searchTerms}`。
///
/// RFC 6570 的 `{?query}` 展开成 `?query=VALUE`，`{&query}` 展开成
/// `&query=VALUE`——所以不能一律换成裸占位符，得把引导符号一起补上，
/// 否则拼出来的是 `https://host/searchVALUE`。
String _normalizeSearchTemplate(Uri baseUri, String href) {
  const String token = 'FUSHIOPDSSEARCHTOKEN';
  String masked = href.trim();
  if (masked.contains('{?query}')) {
    masked = masked.replaceAll('{?query}', '?query=$token');
  } else if (masked.contains('{&query}')) {
    masked = masked.replaceAll('{&query}', '&query=$token');
  } else {
    masked =
        masked.replaceAll('{searchTerms}', token).replaceAll('{query}', token);
  }
  final String resolved = _resolve(baseUri, masked);
  return resolved.replaceAll(token, '{searchTerms}');
}

/// href 里是否带搜索模板占位符（1.2 的 OpenSearch 写法 + 2.0 的 RFC 6570 写法）。
/// 没有占位符的 search link 不是模板，见 [parseOpdsJsonFeed] 里的分流注释。
bool _hasSearchTemplateToken(String href) =>
    href.contains('{searchTerms}') ||
    href.contains('{query}') ||
    href.contains('{?query}') ||
    href.contains('{&query}');

String _resolve(Uri baseUri, String href) {
  try {
    return baseUri.resolve(href.trim()).toString();
  } on FormatException {
    return href.trim();
  }
}

// ── 防御性取值：真实服务端的字段形态比规范宽 ─────────────────────────────

List<Map<String, Object?>> _mapList(Object? raw) => <Map<String, Object?>>[
      if (raw is List)
        for (final Object? item in raw)
          if (item is Map<String, Object?>) item,
    ];

Map<String, Object?>? _map(Object? raw) =>
    raw is Map<String, Object?> ? raw : null;

String? _string(Object? raw) {
  if (raw is String && raw.trim().isNotEmpty) return raw.trim();
  return null;
}

int? _int(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw);
  return null;
}

/// `rel` 可以是字符串，也可以是字符串数组。
Set<String> _rels(Object? raw) {
  if (raw is String) return <String>{raw.trim().toLowerCase()};
  if (raw is List) {
    return <String>{
      for (final Object? item in raw)
        if (item is String) item.trim().toLowerCase(),
    };
  }
  return const <String>{};
}

/// `title` / `description` 可能是纯字符串，也可能是语言映射
/// （`{"en": "...", "ja": "..."}`）。后者取第一个非空值——本仓发现页
/// 不做多语言标题择优，挑一个稳定可读的即可。
String? _title(Object? raw) {
  final String? direct = _string(raw);
  if (direct != null) return direct;
  if (raw is Map<String, Object?>) {
    for (final Object? value in raw.values) {
      final String? text = _string(value);
      if (text != null) return text;
    }
  }
  return null;
}

/// `author` 可以是字符串 / `{"name": ...}` / 两者的数组。
String? _contributor(Object? raw) {
  final String? direct = _string(raw);
  if (direct != null) return direct;
  if (raw is Map<String, Object?>) return _title(raw['name']);
  if (raw is List) {
    for (final Object? item in raw) {
      final String? name = _contributor(item);
      if (name != null) return name;
    }
  }
  return null;
}
