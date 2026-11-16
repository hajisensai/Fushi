/// 楽天ブックス書籍検索 API（`BooksBook/Search/20170404`）。
///
/// 需要用户自己在楽天ウェブサービス注册应用拿到的凭据。2026 年起楽天把 API 迁到
/// `openapi.rakuten.co.jp`，旧 `app.rakuten.co.jp` 已不再接受请求；新端点**同时**要
/// `applicationId` 与 `accessKey`（2026-11 实测：只给 applicationId 回 400
/// 「accessKey must be present」）。两者都填了才算可用（[RakutenBooksCredentials.isComplete]）。
///
/// 映射（`formatVersion=2`，`Items` 是对象数组）：`title`（+ `subTitle`）、`author`、
/// `publisherName`、`seriesName`、`isbn`、`salesDate`（「2014年04月10日」取年）、
/// `itemCaption`、`largeImageUrl`（去掉 `_ex=200x200` 缩放参数取原图）、`itemUrl`。
library;

import 'dart:convert';

import 'package:fushi_engine/media/metadata/books/book_catalog.dart';

/// 楽天书籍检索端点。
final Uri kRakutenBooksSearchEndpoint = Uri.parse(
  'https://openapi.rakuten.co.jp/services/api/BooksBook/Search/20170404',
);

/// 楽天ウェブサービス凭据（设备本地，用户在设置里填）。
class RakutenBooksCredentials {
  const RakutenBooksCredentials({
    required this.applicationId,
    required this.accessKey,
  });

  final String applicationId;
  final String accessKey;

  /// 两项都非空才可用。
  bool get isComplete =>
      applicationId.trim().isNotEmpty && accessKey.trim().isNotEmpty;
}

/// 楽天ブックス客户端。
class RakutenBooksClient {
  RakutenBooksClient(this._http, this.credentials);

  final BookCatalogHttp _http;
  final RakutenBooksCredentials credentials;

  /// 按书名搜（输入里认得出 ISBN 时按 ISBN 搜）。失败抛 [BookCatalogException]。
  Future<List<BookCatalogRecord>> search(String query, {int limit = 20}) async {
    final String term = query.trim();
    if (term.isEmpty) return const <BookCatalogRecord>[];
    final String? isbn = findIsbnIn(term);
    return _query(<String, String>{
      if (isbn != null) 'isbn': isbn else 'title': term,
      'hits': '${limit.clamp(1, 30)}',
    });
  }

  /// 按 ISBN 直取；无记录返回 null。
  Future<BookCatalogRecord?> fetchByIsbn(String isbn) async {
    final String? normalized = normalizeIsbn13(isbn);
    if (normalized == null) return null;
    final List<BookCatalogRecord> found = await _query(<String, String>{
      'isbn': normalized,
    });
    return found.isEmpty ? null : found.first;
  }

  Future<List<BookCatalogRecord>> _query(Map<String, String> params) async {
    if (!credentials.isComplete) {
      throw const BookCatalogException(
        'Rakuten Books applicationId / accessKey not configured',
      );
    }
    final BookCatalogResponse res = await _http.get(
      kRakutenBooksSearchEndpoint.replace(
        queryParameters: <String, String>{
          'format': 'json',
          'formatVersion': '2',
          'applicationId': credentials.applicationId.trim(),
          'accessKey': credentials.accessKey.trim(),
          'outOfStockFlag': '1',
          ...params,
        },
      ),
      headers: const <String, String>{'Accept': 'application/json'},
    );
    if (res.statusCode == 404) return const <BookCatalogRecord>[];
    if (!res.isOk) {
      throw BookCatalogException(
        'Rakuten Books HTTP ${res.statusCode}: ${rakutenErrorMessage(res.body)}',
        statusCode: res.statusCode,
      );
    }
    return parseRakutenBooksResponse(res.body);
  }
}

/// 从楽天错误体里取可读原因：新端点 `{errors:{errorCode,errorMessage}}`，旧端点
/// `{error, error_description}`。凭据本身不会出现在错误体里。
String rakutenErrorMessage(String body) {
  try {
    final Object? decoded = jsonDecode(body);
    if (decoded is Map<String, Object?>) {
      final Object? errors = decoded['errors'];
      if (errors is Map<String, Object?>) {
        return '${errors['errorMessage'] ?? errors['errorCode'] ?? ''}';
      }
      return '${decoded['error_description'] ?? decoded['error'] ?? ''}';
    }
  } on FormatException {
    // 非 JSON 错误页：不回显正文。
  }
  return '';
}

/// 纯函数：解析书籍检索响应（兼容 formatVersion 1 的 `{Item: {...}}` 包装）。
/// 无封面 / 无 ISBN / 无标题的条目跳过；JSON 解码失败抛 [BookCatalogException]。
List<BookCatalogRecord> parseRakutenBooksResponse(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException catch (e) {
    throw BookCatalogException('Rakuten Books malformed JSON: ${e.message}');
  }
  if (decoded is! Map<String, Object?>) return const <BookCatalogRecord>[];
  final Object? items = decoded['Items'] ?? decoded['items'];
  if (items is! List<Object?>) return const <BookCatalogRecord>[];
  final List<BookCatalogRecord> out = <BookCatalogRecord>[];
  final Set<String> seen = <String>{};
  for (final Object? raw in items) {
    if (raw is! Map<String, Object?>) continue;
    final Object? wrapped = raw['Item'];
    final Map<String, Object?> item = wrapped is Map<String, Object?>
        ? wrapped
        : raw;
    final BookCatalogRecord? record = mapRakutenBooksItem(item);
    if (record != null && seen.add(record.id)) out.add(record);
  }
  return out;
}

/// 单条楽天书籍 → [BookCatalogRecord]。
BookCatalogRecord? mapRakutenBooksItem(Map<String, Object?> item) {
  final String? title = catalogString(item['title']);
  final String? isbn = normalizeIsbn13(catalogString(item['isbn']) ?? '');
  final String? image =
      catalogString(item['largeImageUrl']) ??
      catalogString(item['mediumImageUrl']);
  if (title == null || isbn == null || image == null) return null;
  // 楽天没有图时给的是 noimage 占位图，对「刮封面」无用。
  if (image.contains('noimage')) return null;
  final String? subTitle = catalogString(item['subTitle']);
  final String? author = catalogString(item['author']);
  return BookCatalogRecord(
    id: isbn,
    title: subTitle == null ? title : '$title $subTitle',
    author: author?.replaceAll('/', ', '),
    publisher: catalogString(item['publisherName']),
    series: catalogString(item['seriesName']),
    isbn: isbn,
    year: catalogYear(catalogString(item['salesDate'])),
    summary: catalogString(item['itemCaption']),
    coverUrl: _fullSizeImage(image),
    pageUrl: catalogString(item['itemUrl']),
  );
}

/// `…/cabinet/1234/9784301001959.jpg?_ex=200x200` → 去掉缩放参数拿原图。
String _fullSizeImage(String url) {
  final Uri? uri = Uri.tryParse(url);
  if (uri == null || !uri.queryParameters.containsKey('_ex')) return url;
  final Map<String, String> rest = Map<String, String>.of(uri.queryParameters)
    ..remove('_ex');
  final Uri stripped = rest.isEmpty
      ? uri.replace(query: '')
      : uri.replace(queryParameters: rest);
  return stripped.toString().replaceFirst(RegExp(r'\?$'), '');
}
