/// `/api/manga-sources` 的 shelf 路由（鉴权由 FushiSyncServer middleware 统一做）。
///
/// ```
/// GET  /api/manga-sources                    {sources: [RemoteMangaSourceInfo]}
/// GET  /api/manga-sources/<id>/filters       {filters: [bridge json]}
/// POST /api/manga-sources/<id>/browse        {mode, page, query?, filters?} → {items, hasNextPage}
/// POST /api/manga-sources/<id>/details       {series} → {series, chapters}
/// POST /api/manga-sources/<id>/pages         {series, chapter} → {pages: [page json]}
/// POST /api/manga-sources/<id>/page-image    {series, chapter, page} → 图片字节
/// POST /api/manga-sources/<id>/cover         {url} → 图片字节
/// ```
///
/// 除清单 / 过滤器外一律 POST + JSON body：作品 / 章节 / 页的 `raw` 是对端运行时
/// 的不透明 payload，塞进 URL 既要编码又有长度上限，body 里原样往返最省事。
library;

import 'dart:convert';

import 'package:fushi_engine/sync/manga_sources/host_manga_source_host.dart';
import 'package:shelf/shelf.dart' as shelf;

const String kMangaSourcesApiPrefix = '/api/manga-sources';

shelf.Response _json(Object body, {int status = 200}) => shelf.Response(
  status,
  body: jsonEncode(body),
  headers: const <String, String>{'Content-Type': 'application/json'},
);

shelf.Response _image(RemoteMangaImage image) => shelf.Response.ok(
  image.bytes,
  headers: <String, String>{
    'Content-Type': image.contentType,
    'Content-Length': '${image.bytes.length}',
  },
);

Future<Map<String, Object?>?> _readJsonObject(shelf.Request request) async {
  final Object? decoded = jsonDecode(await request.readAsString());
  return decoded is Map<Object?, Object?>
      ? decoded.cast<String, Object?>()
      : null;
}

Future<shelf.Response> handleHostMangaSourceRequest(
  HostMangaSourceHost host,
  shelf.Request request,
  String method,
  String reqPath,
) async {
  final List<String> seg = reqPath
      .substring(kMangaSourcesApiPrefix.length)
      .split('/')
      .where((String s) => s.isNotEmpty)
      .map(Uri.decodeComponent)
      .toList(growable: false);
  try {
    if (seg.isEmpty) {
      if (method != 'GET') return shelf.Response(405);
      final List<RemoteMangaSourceInfo> sources = await host.listSources();
      return _json(<String, Object?>{
        'sources': <Object?>[
          for (final RemoteMangaSourceInfo s in sources) s.toJson(),
        ],
      });
    }
    if (seg.length != 2) return shelf.Response.notFound('Unknown route');
    final String sourceId = seg[0];
    final String action = seg[1];
    if (action == 'filters') {
      if (method != 'GET') return shelf.Response(405);
      return _json(<String, Object?>{'filters': await host.filters(sourceId)});
    }
    if (method != 'POST') return shelf.Response(405);
    final Map<String, Object?>? body = await _readJsonObject(request);
    if (body == null) {
      return shelf.Response(400, body: 'JSON object body required');
    }
    switch (action) {
      case 'browse':
        final RemoteMangaBrowseMode? mode = RemoteMangaBrowseMode.fromWire(
          body['mode'],
        );
        if (mode == null) return shelf.Response(400, body: 'Bad mode');
        final RemoteMangaBrowsePage page = await host.browse(
          sourceId,
          mode: mode,
          page: (body['page'] as num?)?.toInt() ?? 1,
          query: body['query']?.toString() ?? '',
          filters: jsonMapList(body['filters']),
        );
        return _json(page.toJson());
      case 'details':
        final RemoteMangaSeriesDetail detail = await host.details(
          sourceId,
          jsonMap(body['series']),
        );
        return _json(detail.toJson());
      case 'pages':
        final List<Map<String, Object?>> pages = await host.pages(
          sourceId,
          jsonMap(body['series']),
          jsonMap(body['chapter']),
        );
        return _json(<String, Object?>{'pages': pages});
      case 'page-image':
        return _image(
          await host.pageImage(
            sourceId,
            jsonMap(body['series']),
            jsonMap(body['chapter']),
            jsonMap(body['page']),
          ),
        );
      case 'cover':
        final String url = body['url']?.toString() ?? '';
        if (url.isEmpty) return shelf.Response(400, body: 'url required');
        return _image(await host.coverImage(sourceId, url));
    }
    return shelf.Response.notFound('Unknown route');
  } on HostMangaSourceException catch (error) {
    final int status = error.code == HostMangaSourceException.codeSourceNotFound
        ? 404
        : 502;
    return _json(error.toJson(), status: status);
  } on FormatException catch (error) {
    return shelf.Response(400, body: 'Bad JSON: ${error.message}');
  } on ArgumentError catch (error) {
    return shelf.Response(400, body: '$error');
  }
}
