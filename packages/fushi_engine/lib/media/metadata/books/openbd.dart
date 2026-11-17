/// openBD（`https://api.openbd.jp/v1/get?isbn=...`）：只按 ISBN 查，免 key。
///
/// 映射：`summary.title / series / volume / publisher / pubdate`；作者优先 ONIX
/// `DescriptiveDetail.Contributor[].PersonName.content`（规整典拠形人名），没有再用
/// `summary.author`；简介取 ONIX `CollateralDetail.TextContent`（TextType 03 详细 >
/// 02 短）；封面 `summary.cover`。openBD 收录的封面很少（2026-11 实测多数为空），
/// 没封面时回落到 NDL 的 ISBN 缩略图（[ndlThumbnailUrl]，要带 Referer）。
library;

import 'dart:convert';

import 'package:fushi_engine/media/metadata/books/book_catalog.dart';
import 'package:fushi_engine/media/metadata/books/ndl_search.dart';

/// openBD 客户端。
class OpenBdClient {
  OpenBdClient(this._http);

  final BookCatalogHttp _http;

  /// 按 ISBN 查（ISBN-10 / 13，可含连字符）。非法 ISBN / 未收录返回 null。
  Future<BookCatalogRecord?> fetchByIsbn(String isbn) async {
    final String? normalized = normalizeIsbn13(isbn);
    if (normalized == null) return null;
    final BookCatalogResponse res = await _http.get(
      Uri.https('api.openbd.jp', '/v1/get', <String, String>{
        'isbn': normalized,
      }),
      headers: const <String, String>{'Accept': 'application/json'},
    );
    if (!res.isOk) {
      throw BookCatalogException(
        'openBD HTTP ${res.statusCode}',
        statusCode: res.statusCode,
      );
    }
    return parseOpenBdResponse(res.body);
  }
}

/// 纯函数：解析 `/v1/get` 响应（数组，未收录的位置是 `null`）。返回第一条可用记录；
/// 未收录返回 null；不是 JSON 数组抛 [BookCatalogException]。
BookCatalogRecord? parseOpenBdResponse(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException catch (e) {
    throw BookCatalogException('openBD malformed JSON: ${e.message}');
  }
  if (decoded is! List<Object?>) {
    throw const BookCatalogException('openBD response is not an array');
  }
  for (final Object? entry in decoded) {
    if (entry is! Map<String, Object?>) continue;
    final BookCatalogRecord? record = mapOpenBdEntry(entry);
    if (record != null) return record;
  }
  return null;
}

/// 单条 openBD 记录 → [BookCatalogRecord]；无 ISBN / 无标题返回 null。
BookCatalogRecord? mapOpenBdEntry(Map<String, Object?> entry) {
  final Map<String, Object?> summary = _map(entry['summary']);
  final Map<String, Object?> onix = _map(entry['onix']);
  final String? isbn = normalizeIsbn13(catalogString(summary['isbn']) ?? '');
  final String? title = catalogString(summary['title']);
  if (isbn == null || title == null) return null;

  final List<String> authors = <String>[];
  final Object? contributors = _map(onix['DescriptiveDetail'])['Contributor'];
  if (contributors is List<Object?>) {
    for (final Object? c in contributors) {
      final String? name = catalogPersonName(
        catalogString(_map(_map(c)['PersonName'])['content']),
      );
      if (name != null && !authors.contains(name)) authors.add(name);
    }
  }
  final String? author = authors.isNotEmpty
      ? authors.join(', ')
      : _cleanSummaryAuthor(catalogString(summary['author']));

  final String? cover = catalogString(summary['cover']);
  return BookCatalogRecord(
    id: isbn,
    title: title,
    author: author,
    publisher: catalogString(summary['publisher']),
    series: catalogString(summary['series']),
    volume: catalogString(summary['volume']),
    isbn: isbn,
    year: catalogYear(catalogString(summary['pubdate'])),
    summary: _textContent(_map(onix['CollateralDetail'])['TextContent']),
    coverUrl: cover ?? ndlThumbnailUrl(isbn),
    coverHeaders: cover == null ? kNdlThumbnailHeaders : null,
    pageUrl: 'https://www.hanmoto.com/bd/isbn/$isbn',
  );
}

/// `summary.author` 形如「松本ひで吉／著 しのとうこ／イラスト」或典拠形「天乃,聖樹」。
String? _cleanSummaryAuthor(String? raw) {
  if (raw == null) return null;
  final List<String> names = <String>[
    for (final String part in raw.split(RegExp(r'\s+')))
      ?catalogPersonName(part.split('／').first),
  ];
  return names.isEmpty ? null : names.join(', ');
}

String? _textContent(Object? raw) {
  if (raw is! List<Object?>) return null;
  String? short;
  for (final Object? t in raw) {
    final Map<String, Object?> m = _map(t);
    final String? text = catalogString(m['Text']);
    if (text == null) continue;
    if (m['TextType'] == '03') return text;
    short ??= text;
  }
  return short;
}

Map<String, Object?> _map(Object? v) =>
    v is Map<String, Object?> ? v : const <String, Object?>{};
