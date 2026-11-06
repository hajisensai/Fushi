/// `/api/assistant` 的 shelf 路由（鉴权由 FushiSyncServer middleware 统一做）。
///
/// ```
/// POST   /api/assistant/sessions                 {feature, locale, resume?} → {id, revision, view}
/// GET    /api/assistant/sessions/<id>?after=&wait=  长轮询          → {id, revision, view}
/// POST   /api/assistant/sessions/<id>/actions    {type, ...}      → {id, revision, view}
/// DELETE /api/assistant/sessions/<id>
///
/// // 远端会话历史（BUG-4067，能力位 `agentHistory` ≥ 1 才有；只对已配对设备）
/// GET    /api/assistant/history?feature=          → {sessions: [{id, title, createdAt, updatedAt, tokens}]}
/// PATCH  /api/assistant/history/<sid>             {feature, title} → {ok}
/// DELETE /api/assistant/history/<sid>?feature=    → {ok}
/// ```
///
/// 开不了会话（host 没指派 AI / 下载没配好 / 要续接的会话正被别处打开着）→ 409
/// `{reason}`；会话不存在 → 404。历史路由：共享口令 / 认不出的设备 → 403
/// `{error: paired_peer_required}`；会话不在或不是这台设备发起的 → 404（不区分）。
///
/// 兼容：老 host 没有 `history` 路由也不认 `resume` 字段——客户端只在能力位宣告了
/// `agentHistory` 时才发它们；老客户端从不发，行为同升级前。
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

bool _badId(String id) => id.isEmpty || id.contains('..') || id.contains('/');

Future<shelf.Response> handleHostAssistantRequest(
  HostAssistantSessions sessions,
  shelf.Request request,
  String method,
  String reqPath, {
  HostAssistantCaller caller = HostAssistantCaller.anonymous,
}) async {
  final List<String> seg = reqPath
      .substring('/api/assistant'.length)
      .split('/')
      .where((String s) => s.isNotEmpty)
      .map(Uri.decodeComponent)
      .toList(growable: false);
  if (seg.isEmpty) return shelf.Response.notFound('Unknown assistant route');
  try {
    if (seg.first == 'history') {
      return await _handleHistory(sessions, request, method, seg, caller);
    }
    if (seg.first != 'sessions') {
      return shelf.Response.notFound('Unknown assistant route');
    }
    if (seg.length == 1) {
      if (method != 'POST') return shelf.Response(405);
      final Map<String, Object?>? body = await _readObject(request);
      if (body == null) {
        return shelf.Response(400, body: 'JSON object body required');
      }
      final String feature = (body['feature'] ?? '').toString().trim();
      if (feature.isEmpty) return shelf.Response(400, body: 'Missing feature');
      final String locale = (body['locale'] ?? '').toString().trim();
      final Object? resume = body['resume'];
      if (resume != null && (resume is! String || _badId(resume))) {
        return shelf.Response(400, body: 'resume must be a session id');
      }
      return _json(
        await sessions.open(
          feature,
          locale: locale,
          caller: caller,
          resume: resume as String?,
        ),
      );
    }
    final String id = seg[1];
    if (_badId(id)) return shelf.Response(400);
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
  } on HostAssistantPeerRequired {
    return _json(const <String, Object?>{
      'error': 'paired_peer_required',
    }, status: 403);
  } on HostAssistantHistoryNotFound {
    return shelf.Response.notFound('No such session');
  } on ArgumentError catch (e) {
    return shelf.Response(400, body: '${e.message}');
  } on FormatException catch (e) {
    return shelf.Response(400, body: e.message);
  }
}

Future<shelf.Response> _handleHistory(
  HostAssistantSessions sessions,
  shelf.Request request,
  String method,
  List<String> seg,
  HostAssistantCaller caller,
) async {
  if (seg.length == 1) {
    if (method != 'GET') return shelf.Response(405);
    final String feature = (request.url.queryParameters['feature'] ?? '')
        .trim();
    if (feature.isEmpty) return shelf.Response(400, body: 'Missing feature');
    return _json(<String, Object?>{
      'sessions': await sessions.listHistory(feature, caller),
    });
  }
  if (seg.length != 2) {
    return shelf.Response.notFound('Unknown assistant route');
  }
  final String id = seg[1];
  if (_badId(id)) return shelf.Response(400);
  switch (method) {
    case 'PATCH':
      final Map<String, Object?>? body = await _readObject(request);
      if (body == null) {
        return shelf.Response(400, body: 'JSON object body required');
      }
      final String feature = (body['feature'] ?? '').toString().trim();
      final Object? title = body['title'];
      if (feature.isEmpty) return shelf.Response(400, body: 'Missing feature');
      if (title is! String || title.trim().isEmpty) {
        return shelf.Response(400, body: 'title must be a non-empty string');
      }
      await sessions.renameHistory(feature, id, title, caller);
      return _json(const <String, Object?>{'ok': true});
    case 'DELETE':
      final String feature = (request.url.queryParameters['feature'] ?? '')
          .trim();
      if (feature.isEmpty) return shelf.Response(400, body: 'Missing feature');
      await sessions.deleteHistory(feature, id, caller);
      return _json(const <String, Object?>{'ok': true});
    default:
      return shelf.Response(405);
  }
}
