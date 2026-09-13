part of '../fushi_sync_server.dart';

/// 视频刮削元数据端点（`docs/specs/2026-09-12-interconnect-scrape-metadata.md` §1.3）。
///
/// | 方法 | 路径 | 语义 |
/// |---|---|---|
/// | GET  | `/api/library/metadata?since=<ms>` | 7c：host 全部作品（增量按 updatedAt） |
/// | POST | `/api/library/metadata/candidates` | 7a：`{key, query}` → 候选列表 |
/// | POST | `/api/library/metadata/scrape` | 7a：`{key, lookup}` → host 重刮 |
/// | PUT  | `/api/library/metadata` | 7b：`{key, lookup, work, replaceIdentity}` → host 落库 |
///
/// 鉴权走中间件（无豁免）。host 不实现 [VideoMetadataHost] → 404（老 host 天然如此，
/// client 静默跳过）。可解释拒绝回 409 + [VideoMetadataWriteResult] JSON；坏 JSON /
/// 缺字段 400。
extension _FushiSyncServerVideoMetadata on FushiSyncServer {
  Future<shelf.Response> _handleLibraryVideoMetadata(
    shelf.Request request,
    String method,
    String reqPath,
  ) async {
    final Object? svc = _libraryService;
    if (svc is! VideoMetadataHost) {
      return shelf.Response.notFound('Video metadata host off');
    }
    final VideoMetadataHost host = svc;

    if (reqPath == '/api/library/metadata') {
      switch (method) {
        case 'GET':
          final int? since =
              int.tryParse(request.url.queryParameters['since'] ?? '');
          final List<VideoMetadataWorkEntry> entries =
              await host.listVideoMetadata(since: since);
          return jsonResponse(<String, Object?>{
            'works': <Object?>[
              for (final VideoMetadataWorkEntry e in entries) e.toJson(),
            ],
          });
        case 'PUT':
          final Map<String, dynamic>? json = await readJsonObjectBody(request);
          if (json == null) return shelf.Response(400, body: 'Invalid JSON');
          final VideoMetadataWorkKey key;
          final VideoMetadataLookup? lookup;
          final VideoMetadataWork work;
          try {
            key = VideoMetadataWorkKey.fromJson(json['key']);
            lookup = decodeVideoMetadataLookup(json['lookup']);
            final Object? rawWork = json['work'];
            if (rawWork is! Map) throw const FormatException('work missing');
            work = decodeVideoMetadataWork(rawWork.cast<String, Object?>());
          } on FormatException catch (e) {
            return shelf.Response(400, body: 'Invalid body: $e');
          }
          if (lookup == null) {
            return shelf.Response(400, body: 'Invalid body: lookup missing');
          }
          final VideoMetadataWriteResult result = await host.putVideoMetadata(
            key: key,
            lookup: lookup,
            work: work,
            replaceIdentity: json['replaceIdentity'] == true,
          );
          return _writeResultResponse(result);
        default:
          return shelf.Response(405);
      }
    }

    if (reqPath == '/api/library/metadata/candidates') {
      if (method != 'POST') return shelf.Response(405);
      final Map<String, dynamic>? json = await readJsonObjectBody(request);
      if (json == null) return shelf.Response(400, body: 'Invalid JSON');
      final VideoMetadataWorkKey key;
      try {
        key = VideoMetadataWorkKey.fromJson(json['key']);
      } on FormatException catch (e) {
        return shelf.Response(400, body: 'Invalid body: $e');
      }
      final Object? query = json['query'];
      if (query is! String) {
        return shelf.Response(400, body: 'Invalid body: query missing');
      }
      final List<VideoMetadataCandidateEntry> candidates =
          await host.searchVideoMetadataCandidates(key: key, query: query);
      return jsonResponse(<String, Object?>{
        'candidates': <Object?>[
          for (final VideoMetadataCandidateEntry c in candidates) c.toJson(),
        ],
      });
    }

    if (reqPath == '/api/library/metadata/scrape') {
      if (method != 'POST') return shelf.Response(405);
      final Map<String, dynamic>? json = await readJsonObjectBody(request);
      if (json == null) return shelf.Response(400, body: 'Invalid JSON');
      final VideoMetadataWorkKey key;
      final VideoMetadataLookup? lookup;
      try {
        key = VideoMetadataWorkKey.fromJson(json['key']);
        lookup = decodeVideoMetadataLookup(json['lookup']);
      } on FormatException catch (e) {
        return shelf.Response(400, body: 'Invalid body: $e');
      }
      if (lookup == null) {
        return shelf.Response(400, body: 'Invalid body: lookup missing');
      }
      final VideoMetadataWriteResult result =
          await host.scrapeVideoMetadata(key: key, lookup: lookup);
      return _writeResultResponse(result);
    }

    return shelf.Response.notFound('Not found');
  }

  /// 成功 200、可解释拒绝 409，body 都是 [VideoMetadataWriteResult.toJson]。
  shelf.Response _writeResultResponse(VideoMetadataWriteResult result) {
    final String body = jsonEncode(result.toJson());
    return shelf.Response(
      result.isOk ? 200 : 409,
      body: body,
      headers: <String, String>{
        'Content-Type': 'application/json; charset=utf-8',
      },
    );
  }
}
