/// `/api/srs/remote/*` 的 shelf 路由（远程复习库，docs/specs/2026-11-01-srs-remote-review-design.md）。
/// 鉴权由 FushiSyncServer 的 middleware 统一做，这里不豁免任何端点。
///
/// ```
/// POST /api/srs/remote/call          {profile?, op, args, request?}   → {profile, rev, fp, tt, now, ts, sched, rwkv, result}
/// GET  /api/srs/remote/media/<名字>                                    → 字节
/// ```
/// 失败一律 `{error: <机读码>}`（[SrsRemoteStoreError]）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_core/fushi_core.dart' show mimeTypeForFilePath;
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/srs/srs_remote_store.dart';
import 'package:shelf/shelf.dart' as shelf;

shelf.Response _json(Object? body, {int status = 200}) => shelf.Response(
  status,
  body: jsonEncode(body),
  headers: const <String, String>{'Content-Type': 'application/json'},
);

shelf.Response _error(int status, String code) =>
    _json(<String, Object?>{'error': code}, status: status);

/// [reqPath] 以 [kSrsRemoteStorePathPrefix] 开头时调用。
Future<shelf.Response> handleSrsRemoteStoreRequest(
  SrsRemoteStoreService service,
  shelf.Request request,
  String method,
  String reqPath,
) async {
  final String path = reqPath.substring(kSrsRemoteStorePathPrefix.length);
  String op = path;
  try {
    if (path.startsWith('media/')) {
      if (method != 'GET') return shelf.Response(405);
      final String name = Uri.decodeComponent(path.substring('media/'.length));
      final Uint8List? bytes = await service.media(name);
      if (bytes == null) return shelf.Response.notFound('No media');
      return shelf.Response.ok(
        bytes,
        headers: <String, String>{
          'Content-Type': mimeTypeForFilePath(
            name,
            fallback: 'application/octet-stream',
          ),
          'Content-Length': '${bytes.length}',
          // 名字是内容哈希：同名永远同内容。
          'Cache-Control': 'private, max-age=31536000, immutable',
        },
      );
    }
    if (path != 'call') return shelf.Response.notFound('Unknown remote op');
    if (method != 'POST') return shelf.Response(405);
    final Object? decoded = jsonDecode(await request.readAsString());
    if (decoded is! Map) return _error(400, SrsRemoteStoreError.badRequest);
    final Map<String, Object?> body = decoded.cast<String, Object?>();
    final Object? name = body['op'];
    final Object? args = body['args'];
    final Object? profile = body['profile'];
    final Object? requestId = body['request'];
    if (name is! String ||
        (args != null && args is! Map) ||
        (profile != null && profile is! String) ||
        (requestId != null && requestId is! String)) {
      return _error(400, SrsRemoteStoreError.badRequest);
    }
    op = name;
    return _json(
      await service.call(
        profile: profile as String?,
        op: name,
        args: args == null
            ? const <String, Object?>{}
            : (args as Map).cast<String, Object?>(),
        request: requestId as String?,
      ),
    );
  } on SrsRemoteStoreError catch (e) {
    if (e.detail != null) engineLog.log('SrsRemoteStore.$op', e);
    return _error(e.status, e.code);
  } on FormatException {
    return _error(400, SrsRemoteStoreError.badRequest);
  } on TypeError {
    return _error(400, SrsRemoteStoreError.badRequest);
  } catch (e, stack) {
    engineLog.log('SrsRemoteStore.$op', e, stack);
    return _error(500, 'internal');
  }
}
