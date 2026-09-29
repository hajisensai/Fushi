/// `/api/assistant` 的 shelf 路由（鉴权由 FushiSyncServer middleware 统一做）。
///
/// ```
/// POST   /api/assistant/sessions                 {feature, locale} → {id, revision, view}
/// GET    /api/assistant/sessions/<id>?after=&wait=  长轮询          → {id, revision, view}
/// POST   /api/assistant/sessions/<id>/actions    {type, ...}      → {id, revision, view}
/// DELETE /api/assistant/sessions/<id>
/// ```
///
/// 开不了会话（host 没指派 AI / 下载没配好）→ 409 `{reason}`；会话不存在 → 404。
library;

import 'dart:convert';

import 'package:fushi_engine/sync/assistant/host_assistant.dart';
import 'package:shelf/shelf.dart' as shelf;

shelf.Response _json(Object body, {int status = 200}) => shelf.Response(
      status,
      body: jsonEncode(body),
      headers: const <String, String>{'Content-Type': 'application/json'},
    );

Future<Map<String, Object?>?> _readObject(shelf.Request request) async {
  final String text = await request.readAsString();
  if (text.trim().isEmpty) return <String, Object?>{};
  final Object? decoded = jsonDecode(text);
  if (decoded is! Map) return null;
  return decoded.map(
    (Object? key, Object? value) => MapEntry<String, Object?>('$key', value),
  );
}

Future<shelf.Response> handleHostAssistantRequest(
  HostAssistantSessions sessions,
  shelf.Request request,
  String method,
  String reqPath,
) async {
  final List<String> seg = reqPath
      .substring('/api/assistant'.length)
      .split('/')
      .where((String s) => s.isNotEmpty)
      .map(Uri.decodeComponent)
      .toList(growable: false);
  if (seg.isEmpty || seg.first != 'sessions') {
    return shelf.Response.notFound('Unknown assistant route');
  }
  try {
    if (seg.length == 1) {
      if (method != 'POST') return shelf.Response(405);
      final Map<String, Object?>? body = await _readObject(request);
      if (body == null) {
        return shelf.Response(400, body: 'JSON object body required');
      }
      final String feature = (body['feature'] ?? '').toString().trim();
      if (feature.isEmpty) return shelf.Response(400, body: 'Missing feature');
      final String locale = (body['locale'] ?? '').toString().trim();
      return _json(await sessions.open(feature, locale: locale));
    }
    final String id = seg[1];
    if (id.contains('..') || id.contains('/')) return shelf.Response(400);
    if (seg.length == 2) {
      if (method == 'DELETE') {
        final bool closed = await sessions.close(id);
        if (!closed) return shelf.Response.notFound('No such session');
        return _json(const <String, Object?>{'ok': true});
      }
      if (method != 'GET') return shelf.Response(405);
      final Map<String, String> query = request.url.queryParameters;
      final int? after = int.tryParse(query['after'] ?? '');
      final int waitSeconds = int.tryParse(query['wait'] ?? '') ?? 0;
      final Map<String, Object?>? envelope = await sessions.read(
        id,
        after: after,
        wait: Duration(seconds: waitSeconds.clamp(0, 60)),
      );
      if (envelope == null) return shelf.Response.notFound('No such session');
      return _json(envelope);
    }
    if (seg.length == 3 && seg[2] == 'actions') {
      if (method != 'POST') return shelf.Response(405);
      final Map<String, Object?>? body = await _readObject(request);
      if (body == null) {
        return shelf.Response(400, body: 'JSON object body required');
      }
      final Map<String, Object?>? envelope = await sessions.act(id, body);
      if (envelope == null) return shelf.Response.notFound('No such session');
      return _json(envelope);
    }
    return shelf.Response.notFound('Unknown assistant route');
  } on HostAssistantUnavailable catch (e) {
    return _json(<String, Object?>{'reason': e.reason}, status: 409);
  } on ArgumentError catch (e) {
    return shelf.Response(400, body: '${e.message}');
  } on FormatException catch (e) {
    return shelf.Response(400, body: e.message);
  }
}
