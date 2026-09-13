/// `/api/subscriptions` 的 shelf 路由（鉴权由 FushiSyncServer middleware 统一做）。
///
/// ```
/// GET    /api/subscriptions                 {subscriptions: [...]}
/// POST   /api/subscriptions                 HostSubscriptionCreateRequest → {subscription}
/// POST   /api/subscriptions/check           全部立刻检查
/// POST   /api/subscriptions/<id>/enable     {enabled: bool}
/// POST   /api/subscriptions/<id>/check
/// DELETE /api/subscriptions/<id>
/// ```
library;

import 'dart:convert';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/subscriptions/host_subscription_host.dart';
import 'package:shelf/shelf.dart' as shelf;

shelf.Response _json(Object body, {int status = 200}) => shelf.Response(
      status,
      body: jsonEncode(body),
      headers: const <String, String>{'Content-Type': 'application/json'},
    );

Future<shelf.Response> handleHostSubscriptionRequest(
  HostSubscriptionHost host,
  shelf.Request request,
  String method,
  String reqPath,
) async {
  final List<String> seg = reqPath
      .substring('/api/subscriptions'.length)
      .split('/')
      .where((String s) => s.isNotEmpty)
      .map(Uri.decodeComponent)
      .toList(growable: false);
  try {
    if (seg.isEmpty) {
      if (method == 'GET') {
        final List<VideoDownloadSubscriptionRow> rows = await host.list();
        final Map<String, Map<String, int>> counts = await host.itemCounts();
        return _json(<String, Object?>{
          'subscriptions': <Object?>[
            for (final VideoDownloadSubscriptionRow r in rows)
              videoDownloadSubscriptionToWire(r,
                  itemCounts: counts[r.subscriptionId]),
          ],
        });
      }
      if (method == 'POST') {
        final Object? decoded = jsonDecode(await request.readAsString());
        if (decoded is! Map) {
          return shelf.Response(400, body: 'JSON object body required');
        }
        final VideoDownloadSubscriptionRow row = await host.create(
          HostSubscriptionCreateRequest.fromJson(
              Map<String, dynamic>.from(decoded)),
        );
        return _json(<String, Object?>{
          'subscription': videoDownloadSubscriptionToWire(row)
        });
      }
      return shelf.Response(405);
    }
    if (seg.length == 1 && seg.first == 'check') {
      if (method != 'POST') return shelf.Response(405);
      await host.checkNow(null);
      return _json(const <String, Object?>{'ok': true});
    }
    final String id = seg.first;
    if (id.contains('..') || id.contains('/')) return shelf.Response(400);
    if (seg.length == 1) {
      if (method != 'DELETE') return shelf.Response(405);
      await host.delete(id);
      return _json(const <String, Object?>{'ok': true});
    }
    if (method != 'POST') return shelf.Response(405);
    switch (seg[1]) {
      case 'enable':
        final Object? decoded = jsonDecode(await request.readAsString());
        final Object? enabled = decoded is Map ? decoded['enabled'] : null;
        if (enabled is! bool) {
          return shelf.Response(400, body: 'enabled (bool) required');
        }
        await host.setEnabled(id, enabled);
        return _json(const <String, Object?>{'ok': true});
      case 'check':
        await host.checkNow(id);
        return _json(const <String, Object?>{'ok': true});
    }
    return shelf.Response.notFound('Unknown subscriptions route');
  } on HostSubscriptionRejected catch (e) {
    return _json(<String, Object?>{'reason': e.reason, 'message': e.message},
        status: e.status);
  } on ArgumentError catch (e) {
    return shelf.Response(400, body: '${e.message}');
  } on FormatException catch (e) {
    return shelf.Response(400, body: e.message);
  }
}

/// host 拒绝请求的结构化原因（客户端按 `reason` 分流：`provider_unavailable` 给
/// 「host 上没有这个索引器」文案并附 `available`）。
class HostSubscriptionRejected implements Exception {
  const HostSubscriptionRejected(this.status, this.reason, this.message);
  final int status;
  final String reason;
  final String message;

  @override
  String toString() => '$reason: $message';
}
