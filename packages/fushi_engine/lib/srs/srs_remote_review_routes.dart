/// `/api/srs/review/*` 的 shelf 路由（复习远程刷卡，docs/specs/2026-11-01-srs-remote-review-design.md §2）。
/// 鉴权由 FushiSyncServer 的 middleware 统一做，这里不豁免任何端点。
///
/// ```
/// POST /api/srs/review/decks          {}                                  → {profile, decks}
/// POST /api/srs/review/next           {profile, deck, exclude}            → {profile, counts, cards}
/// POST /api/srs/review/answer         {profile, request, deck, card, base, rating, durationMs}
///                                                                         → {profile, logId, counts, cards}
/// POST /api/srs/review/undo           {profile, card, log}                → {profile, ok, card?}
/// GET  /api/srs/review/media/<名字>                                        → 字节
/// ```
/// 失败一律 `{error: <机读码>}`（[SrsRemoteReviewError]）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_core/fushi_core.dart' show mimeTypeForFilePath;
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/srs/srs_remote_review.dart';
import 'package:shelf/shelf.dart' as shelf;

shelf.Response _json(Object body, {int status = 200}) => shelf.Response(
  status,
  body: jsonEncode(body),
  headers: const <String, String>{'Content-Type': 'application/json'},
);

shelf.Response _error(int status, String code) =>
    _json(<String, Object?>{'error': code}, status: status);

/// [reqPath] 以 [kSrsRemoteReviewPathPrefix] 开头时调用。
Future<shelf.Response> handleSrsRemoteReviewRequest(
  SrsRemoteReviewService service,
  shelf.Request request,
  String method,
  String reqPath,
) async {
  final String op = reqPath.substring(kSrsRemoteReviewPathPrefix.length);
  try {
    if (op.startsWith('media/')) {
      if (method != 'GET') return shelf.Response(405);
      final String name = Uri.decodeComponent(op.substring('media/'.length));
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
    if (method != 'POST') return shelf.Response(405);
    final Object? decoded = jsonDecode(await request.readAsString());
    if (decoded is! Map) {
      return _error(400, SrsRemoteReviewError.badRequest);
    }
    final Map<String, Object?> body = decoded.cast<String, Object?>();
    String? str(String key) {
      final Object? v = body[key];
      return v is String && v.isNotEmpty ? v : null;
    }

    String need(String key) =>
        str(key) ??
        (throw const SrsRemoteReviewError(
          400,
          SrsRemoteReviewError.badRequest,
        ));
    switch (op) {
      case 'decks':
        return _json(await service.decks());
      case 'next':
        return _json(
          await service.next(
            profile: str('profile'),
            deck: need('deck'),
            exclude: <String>{
              for (final Object? id in (body['exclude'] as List?) ?? const [])
                if (id is String) id,
            },
          ),
        );
      case 'answer':
        final Object? rating = body['rating'];
        final Object? duration = body['durationMs'];
        if (rating is! int) {
          return _error(400, SrsRemoteReviewError.badRequest);
        }
        return _json(
          await service.answer(
            profile: str('profile'),
            request: need('request'),
            deck: need('deck'),
            card: need('card'),
            base: str('base'),
            rating: rating,
            durationMs: duration is int ? duration : 0,
          ),
        );
      case 'undo':
        return _json(
          await service.undo(
            profile: str('profile'),
            card: need('card'),
            log: need('log'),
          ),
        );
    }
    return shelf.Response.notFound('Unknown review op');
  } on SrsRemoteReviewError catch (e) {
    return _error(e.status, e.code);
  } on FormatException {
    return _error(400, SrsRemoteReviewError.badRequest);
  } catch (e, stack) {
    engineLog.log('SrsRemoteReview.$op', e, stack);
    return _error(500, 'internal');
  }
}
