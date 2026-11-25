/// 远程复习库的 shelf 路由（docs/specs/2026-11-01-srs-remote-review-design.md；线格式 V2 与协商见
/// srs_remote_generation.dart）。鉴权由 FushiSyncServer 的 middleware 统一做，这里不豁免任何端点。
///
/// ```
/// POST /api/srs/remote2/call         {g: 4, profile?, op, args, request?, col?, tz?}
///                                    → {profile, col, ids, rev, fp, tt, now, ts, sched, rwkv, rk?, dev, result}
/// GET  /api/srs/remote2/media/<名字>                                   → 字节
/// *    /api/srs/remote/*（V1）                                         → 426 upgrade_required（拍板 D31 的拒绝桩）
/// ```
/// `g` 不是 4（缺、类型不对、别的代）→ 426 [SrsRemoteStoreError.upgradeRequired]，不碰库。`col` 是客户端握手时看到的
/// 集合（写操作据此拒绝落到换过的集合上，[SrsRemoteStoreService.call]）。`tz` 是客户端设备此刻的 UTC 偏移（分钟，
/// [kSrsRemoteDeviceOffsetKey]）：不是整数 → 400；整数但越界 → 当没带，按主机自己的偏移算。其余不认识的顶层键一律
/// 忽略。失败一律 `{error: <机读码>}`（[SrsRemoteStoreError]）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_core/fushi_core.dart' show mimeTypeForFilePath;
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/srs/srs_remote_generation.dart';
import 'package:fushi_engine/srs/srs_remote_store.dart';
import 'package:shelf/shelf.dart' as shelf;

shelf.Response _json(Object? body, {int status = 200}) => shelf.Response(
  status,
  body: jsonEncode(body),
  headers: const <String, String>{'Content-Type': 'application/json'},
);

shelf.Response _error(int status, String code) =>
    _json(<String, Object?>{'error': code}, status: status);

/// [reqPath] 是不是远程复习的端点（V2，或只回拒绝的 V1）。
bool isSrsRemoteStorePath(String reqPath) =>
    reqPath.startsWith(kSrsRemoteStoreV2PathPrefix) ||
    reqPath.startsWith(kSrsRemoteStorePathPrefix);

/// [reqPath] 满足 [isSrsRemoteStorePath] 时调用。
Future<shelf.Response> handleSrsRemoteStoreRequest(
  SrsRemoteStoreService service,
  shelf.Request request,
  String method,
  String reqPath,
) async {
  if (!reqPath.startsWith(kSrsRemoteStoreV2PathPrefix)) {
    // V1（旧客户端）：新代主机一律 426，不读请求体、不碰库（D31）。
    final SrsRemoteStoreError e = kSrsRemoteV1RefusedOnGen4;
    return _error(e.status, e.code);
  }
  final String path = reqPath.substring(kSrsRemoteStoreV2PathPrefix.length);
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
    if (srsRemoteV2GenerationError(body[kSrsRemoteGenerationKey])
        case final SrsRemoteStoreError e) {
      return _error(e.status, e.code);
    }
    final Object? name = body['op'];
    final Object? args = body['args'];
    final Object? profile = body['profile'];
    final Object? requestId = body['request'];
    final Object? deviceOffset = body[kSrsRemoteDeviceOffsetKey];
    final Object? collection = body['col'];
    if (name is! String ||
        (args != null && args is! Map) ||
        (profile != null && profile is! String) ||
        (requestId != null && requestId is! String) ||
        (collection != null && collection is! String) ||
        (deviceOffset != null && deviceOffset is! int)) {
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
        collection: collection as String?,
        deviceOffsetMin: deviceOffset as int?,
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
