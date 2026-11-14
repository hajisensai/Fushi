/// 复习库**内容**的 admin 端点与 AI 操作（配置面——提供哪几份 profile、AnkiConnect、立即同步——在
/// admin_srs.dart）。路由、操作描述与撤销是 app 的 `fushi_cli srs …` / AI 助手背后的同一份 engine 实现
/// （`srs_ctl_routes.dart` / `srs_ctl_ops.dart`），这里只做服务端的装配：
///
/// - `GET  /api/admin/srs/decks`                       牌组与今天的新卡 / 学习 / 到期数；
/// - `GET  /api/admin/srs/notes`                       搜索笔记 / 卡片（`q` / `field` / `deck` / `mode` / `limit` / `offset`）；
/// - `GET  /api/admin/srs/notes/<id>`                  一条笔记；
/// - `GET  /api/admin/srs/stats`                       统计（`deck` 只看那棵子树）；
/// - `GET  /api/admin/srs/conflicts`                   冲突中心；
/// - `POST /api/admin/srs/conflicts/held/<id>/delete`  被扣住的删除：以删除为准；
/// - `POST /api/admin/srs/conflicts/held/<id>/keep`    被扣住的删除：保留（`confirm: true`）；
/// - `POST /api/admin/srs/conflicts/fields/resolve`    被覆盖的设置 / 标志：`kind` / `entity` / `key` / `keep`；
/// - `POST /api/admin/srs/duplicates/merge`            合并重复笔记：`keep` / `absorb`；
/// - `POST /api/admin/srs/duplicates/dismiss`          标记不是重复：`notes`；
/// - `POST /api/admin/srs/notes/batch/card-type|set-field|find-replace`  批量改笔记（`dryRun` 预演）。
///
/// 服务端一个进程持有多份 profile 的库：每个端点都认 `profile`（query 或 body，profile uid）。没给时只有
/// 一份可用就是它，几份都可用回 409 `profile_required`——与设备信任端点「没点名」的口径一致，不猜默认那份
/// （这些端点有写操作，写错库比多打一个参数贵）。没提供的 uid → 404 `profile_not_served`，那份还没就绪 /
/// 加密 / 出错 → 409 `profile_unavailable`，复习库整个没起 → 409 `srs_unavailable`。按 id 点名的笔记必须
/// 属于点名的那份，别的 profile 的 id 按不存在回 404（engine 路由的 `_requireInTarget`，BUG-4480）。
///
/// 鉴权沿用 admin API（admin_server.dart：`/api/admin/*` 一律要 admin token）。
library;

import 'dart:convert';

import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/srs/srs_ctl_ops.dart';
import 'package:fushi_engine/srs/srs_ctl_routes.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_server/src/server_srs.dart';
import 'package:shelf/shelf.dart' as shelf;

/// 服务端的 [SrsCtlHost]：按 `profile` 取那份被提供的库（口径见库注释）；写完把那份发出去
/// （[ServerSrs.notifyWrite]，与 AnkiConnect / 互联制卡写库后同一条路）。
SrsCtlHost serverSrsCtlHost(ServerSrs? Function() srs) => SrsCtlHost(
  open: (String? profile) async {
    final ServerSrs? s = srs();
    if (s == null) throw _refused(409, 'srs_unavailable');
    final ServerSrsProfile prof;
    if (profile != null) {
      final ServerSrsProfile? hit = s.profile(profile);
      if (hit == null) throw _refused(404, 'profile_not_served');
      prof = hit;
    } else {
      final List<ServerSrsProfile> ready = s.readyProfiles;
      if (ready.length > 1) throw _refused(409, 'profile_required');
      if (ready.isEmpty) throw _refused(409, 'profile_unavailable');
      prof = ready.single;
    }
    final SrsDbStore? store = prof.store;
    if (store == null) throw _refused(409, 'profile_unavailable');
    return SrsCtlTarget(store, profile: prof.uid);
  },
  changed: (SrsCtlTarget target) {
    final String? uid = target.profile;
    if (uid != null) srs()?.notifyWrite(uid);
  },
);

/// 取不到库的拒绝：短码既是 `reason` 也是消息（与 admin_srs.dart 的错误体同形）。
CtlFailure _refused(int status, String reason) =>
    CtlFailure(status, reason, reason);

/// `/api/admin/srs/*` 里复习库内容那一组端点：把请求拼成 [CtlCall] 交给 engine 路由。
class AdminSrsCtl {
  AdminSrsCtl(ServerSrs? Function() srs)
    : routes = srsCtlRoutes(serverSrsCtlHost(srs));

  final List<CtlRoute> routes;

  /// 不是这一组的路径回 null（交回 admin API 继续匹配）。
  Future<shelf.Response?> route(
    String method,
    String path,
    shelf.Request request,
  ) async {
    for (final CtlRoute route in routes) {
      if (route.method != method) continue;
      final Map<String, String>? params = route.match(path);
      if (params == null) continue;
      final Map<String, Object?> body = method == 'GET'
          ? const <String, Object?>{}
          : await _body(request);
      try {
        final Object? result = await route.handler(
          CtlCall(
            method: method,
            path: path,
            params: params,
            query: request.url.queryParameters,
            body: body,
          ),
        );
        return _json(result ?? const <String, Object?>{'ok': true});
      } on CtlFailure catch (failure) {
        return _json(<String, Object?>{
          'error': failure.message ?? failure.code,
          'reason': failure.code,
        }, status: failure.status);
      }
    }
    return null;
  }
}

/// 给 AI 操作目录点名 profile 的参数。
const OpParam _profileParam = OpParam.string(
  kSrsCtlProfileParam,
  description:
      'Uid of a served review profile (from server.srs.status). May be omitted '
      'only while exactly one served profile is ready.',
);

/// 服务端操作目录里的复习库内容操作（`server.srs.decks.list` 等，id = app 的 id 加 `server.` 前缀）。
///
/// 路由是 engine 的同一张表、进程内直接调（不经 admin API 的 HTTP 形状转一道：批量改笔记的撤销载荷按
/// 这次调用的 [CtlCall] 取实际写下的改动，转一道就不是同一个对象了）；描述与撤销也是 engine 那一份。写操作
/// 的撤销载荷里带执行那次作用的 profile，撤销回到同一份。没有可用的 profile 时这些操作报不可用。
({List<CtlRoute> routes, List<OpDescription> descriptions})
buildServerSrsCtlOps(ServerSrs? Function() srs) {
  final SrsCtlHost host = serverSrsCtlHost(srs);
  return (
    routes: srsCtlRoutes(host),
    descriptions: srsCtlOpDescriptions(
      host,
      idPrefix: 'server.',
      availability: () => (srs()?.readyProfiles.isNotEmpty ?? false)
          ? const OpAvailability.available()
          : const OpAvailability.unavailable('srs_unavailable'),
      scopeParams: const <OpParam>[_profileParam],
    ),
  );
}

Future<Map<String, Object?>> _body(shelf.Request request) async {
  final String raw = await request.readAsString();
  if (raw.trim().isEmpty) return const <String, Object?>{};
  final Object? decoded = jsonDecode(raw);
  if (decoded is! Map) {
    throw const FormatException('body must be a JSON object');
  }
  return Map<String, Object?>.from(decoded);
}

shelf.Response _json(Object body, {int status = 200}) => shelf.Response(
  status,
  body: jsonEncode(body),
  headers: const <String, String>{
    'Content-Type': 'application/json; charset=utf-8',
  },
);
