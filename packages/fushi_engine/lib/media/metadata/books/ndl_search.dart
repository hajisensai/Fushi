/// 国立国会図書館サーチ（NDL Search）OpenSearch：`https://ndlsearch.ndl.go.jp/api/opensearch`。
///
/// 免 key，按标题（`title=`）或 ISBN（`isbn=`）搜，`mediatype=books` 只要图书。RSS 2.0
/// 每个 `<item>` 映射：`dc:title`、`dc:creator`（典拠形人名规整）、`dc:publisher`、
/// `dcndl:seriesTitle`、`dcndl:volume`、`dc:identifier[xsi:type=dcndl:ISBN]`、
/// `dcterms:issued`、`link`。封面是按 ISBN 拼的缩略图
/// `https://ndlsearch.ndl.go.jp/thumbnail/<ISBN>.jpg`——**必须带 Referer**（2026-11
/// 实测不带回 CloudFront 403，带了 200 / 无图 404）。没有 ISBN 的条目拿不到封面，跳过；
/// 同一 ISBN 多条（纸本 / 特装 / 不同馆藏）只留第一条。
///
/// 服务端按同时连接数限流（并发会回 429），节流见 [kBookCatalogMinIntervals]。
library;

import 'package:xml/xml.dart';

import 'package:fushi_engine/media/metadata/books/book_catalog.dart';

/// 缩略图请求必须带的头。
const Map<String, String> kNdlThumbnailHeaders = <String, String>{
  'Referer': 'https://ndlsearch.ndl.go.jp/',
};

/// 按 ISBN-13 拼 NDL 缩略图 URL（不保证一定有图，无图时 404）。
String ndlThumbnailUrl(String isbn13) =>
    'https://ndlsearch.ndl.go.jp/thumbnail/$isbn13.jpg';

const String _dc = 'http://purl.org/dc/elements/1.1/';
const String _dcndl = 'http://ndl.go.jp/dcndl/terms/';
const String _dcterms = 'http://purl.org/dc/terms/';
const String _xsi = 'http://www.w3.org/2001/XMLSchema-instance';

/// NDL Search 客户端。
class NdlSearchClient {
  NdlSearchClient(this._http);

  final BookCatalogHttp _http;

  /// 按标题搜（输入里认得出 ISBN 时按 ISBN 搜）。失败抛 [BookCatalogException]。
  Future<List<BookCatalogRecord>> search(String query, {int limit = 20}) async {
    final String term = query.trim();
    if (term.isEmpty) return const <BookCatalogRecord>[];
    final String? isbn = findIsbnIn(term);
    return _query(<String, String>{
      if (isbn != null) 'isbn': isbn else 'title': term,
      'mediatype': 'books',
      'cnt': '$limit',
    });
  }

  /// 按 ISBN 直取；无记录返回 null。
  Future<BookCatalogRecord?> fetchByIsbn(String isbn) async {
    final String? normalized = normalizeIsbn13(isbn);
    if (normalized == null) return null;
    final List<BookCatalogRecord> found = await _query(<String, String>{
      'isbn': normalized,
      'mediatype': 'books',
      'cnt': '5',
    });
    return found.isEmpty ? null : found.first;
  }

  Future<List<BookCatalogRecord>> _query(Map<String, String> params) async {
    final BookCatalogResponse res = await _http.get(
      Uri.https('ndlsearch.ndl.go.jp', '/api/opensearch', params),
      headers: const <String, String>{'Accept': 'application/rss+xml'},
    );
    if (!res.isOk) {
      throw BookCatalogException(
        'NDL Search HTTP ${res.statusCode}',
        statusCode: res.statusCode,
      );
    }
    return parseNdlOpenSearchResponse(res.body);
  }
}

/// 纯函数：解析 OpenSearch RSS。XML 解析失败 / 是 `<error>` 文档抛
/// [BookCatalogException]；没有 `<item>` 是空结果。
List<BookCatalogRecord> parseNdlOpenSearchResponse(String body) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(body);
  } on XmlException catch (e) {
    throw BookCatalogException('NDL Search malformed XML: ${e.message}');
  }
  final XmlElement root = doc.rootElement;
  if (root.name.local == 'error') {
    final String message = root.getElement('message')?.innerText.trim() ?? '';
    throw BookCatalogException(
      'NDL Search error: $message',
      statusCode: int.tryParse(root.getElement('code')?.innerText.trim() ?? ''),
    );
  }
  final List<BookCatalogRecord> out = <BookCatalogRecord>[];
  final Set<String> seen = <String>{};
  for (final XmlElement item in root.findAllElements('item')) {
    final BookCatalogRecord? record = mapNdlItem(item);
    if (record != null && seen.add(record.id)) out.add(record);
  }
  return out;
}

/// 单个 `<item>` → [BookCatalogRecord]；无标题 / 无 ISBN 返回 null。
BookCatalogRecord? mapNdlItem(XmlElement item) {
  String? first(String local, String ns) =>
      catalogString(item.getElement(local, namespace: ns)?.innerText);
  final String? title =
      first('title', _dc) ?? catalogString(item.getElement('title')?.innerText);
  if (title == null) return null;
  String? isbn;
  for (final XmlElement id in item.findElements('identifier', namespace: _dc)) {
    final String type = id.getAttribute('type', namespace: _xsi) ?? '';
    if (!type.endsWith('ISBN') && !type.endsWith('ISBN13')) continue;
    isbn = normalizeIsbn13(id.innerText);
    if (isbn != null) break;
  }
  if (isbn == null) return null;
  final List<String> creators = <String>[
    for (final XmlElement c in item.findElements('creator', namespace: _dc))
      ?catalogPersonName(c.innerText),
  ];
  return BookCatalogRecord(
    id: isbn,
    title: title,
    author: creators.isEmpty ? null : creators.toSet().join(', '),
    publisher: first('publisher', _dc),
    series: first('seriesTitle', _dcndl),
    volume: first('volume', _dcndl),
    isbn: isbn,
    year: catalogYear(first('issued', _dcterms) ?? first('date', _dc)),
    coverUrl: ndlThumbnailUrl(isbn),
    coverHeaders: kNdlThumbnailHeaders,
    pageUrl: catalogString(item.getElement('link')?.innerText),
  );
}
