/// 操作目录的通用 HTTP 面：`fushi_cli op ls|describe|call`（spec §3 第 4 点）。
///
/// 只要一条路由有描述，CLI 就自动能用——「补齐」从一次性工作变成结构保证。
library;

import '../ctl_routes.dart';
import 'fushi_op.dart';
import 'op_catalog.dart';

const String kCtlOpsPath = '/api/admin/ops';
const String kCtlOpsDescribePath = '/api/admin/ops/describe/:id';
const String kCtlOpsCallPath = '/api/admin/ops/call';

/// `/ops/call` 结果里撤销记录的 id（`fushi_cli ai undo <id>` / 操作记录页撤销）。
const String kCtlOpsUndoActionIdKey = 'undoActionId';

/// 把一次以用户身份经 `/ops/call` 执行的可撤销操作记进操作记录（与 AI 助手的操作记录同一张表），
/// 返回记录 id。
typedef OpUndoRecorder =
    Future<int> Function(
      FushiOp op,
      Map<String, Object?> args,
      OpUndoRecord undo,
    );

/// 目录的三条路由。[invoker] 现取（app 初始化后才有完整目录）。
///
/// - `GET  /api/admin/ops?q=`：列出当前可用的操作（带 `q` 时按检索排序）。
/// - `GET  /api/admin/ops/describe/:id`：完整描述（含不可用原因）。
/// - `POST /api/admin/ops/call` `{id, args, yes?}`：以用户身份调用；`yes=true`
///   等于用户在终端里把该操作的全部表态参数都敲上了。只在进程内有意义的操作拒绝。
///   给了 [recordUndo] 时，可撤销操作（`op.undo != null`）执行前抓快照、执行后把撤销载荷
///   记进操作记录，结果（Map）里带 [kCtlOpsUndoActionIdKey]——CLI 的写操作与 AI 一样能撤销。
List<CtlRoute> buildOpCatalogRoutes(
  OpInvoker Function() invoker, {
  OpUndoRecorder? recordUndo,
}) => <CtlRoute>[
  CtlRoute.get(kCtlOpsPath, (CtlCall call) async {
    final OpCatalog catalog = invoker().catalog;
    final String? query = call.optString('q');
    final Iterable<FushiOp> ops = query == null
        ? (catalog.available().toList()
            ..sort((FushiOp a, FushiOp b) => a.id.compareTo(b.id)))
        : catalog.search(query, limit: call.optInt('limit') ?? 30);
    return <String, Object?>{
      'ops': <Map<String, Object?>>[
        for (final FushiOp op in ops)
          if (!op.inProcessOnly)
            <String, Object?>{
              'id': op.id,
              'risk': op.risk.name,
              'summary': op.summary,
            },
      ],
    };
  }),
  CtlRoute.get(kCtlOpsDescribePath, (CtlCall call) async {
    final String id = call.params['id'] ?? '';
    final FushiOp? op = invoker().catalog[id];
    if (op == null || op.inProcessOnly) {
      throw CtlFailure.notFound('没有这个操作：$id');
    }
    final OpAvailability availability = op.currentAvailability();
    return <String, Object?>{
      ...op.spec.toJson(),
      'available': availability.isAvailable,
      if (availability.code != null) 'unavailableCode': availability.code,
      if (availability.message != null)
        'unavailableMessage': availability.message,
    };
  }),
  CtlRoute.post(kCtlOpsCallPath, (CtlCall call) async {
    final OpInvoker inv = invoker();
    final String id = call.requireString('id');
    final FushiOp? op = inv.catalog[id];
    if (op == null || op.inProcessOnly) {
      throw CtlFailure.notFound('没有这个操作：$id');
    }
    final Object? rawArgs = call.body['args'];
    if (rawArgs != null && rawArgs is! Map) {
      throw const CtlFailure.badRequest('args 必须是 JSON 对象');
    }
    final Map<String, Object?> args = rawArgs == null
        ? const <String, Object?>{}
        : Map<String, Object?>.from(rawArgs as Map);
    final OpInvocation result = await inv.invoke(
      id,
      args,
      captureUndo: recordUndo != null && op.undo != null,
      grantedGates: call.optBool('yes') == true
          ? <String>{
              for (final OpParam p in op.params.where(
                (OpParam p) => p.userGate,
              ))
                p.name,
            }
          : const <String>{},
    );
    final Object data = result.result ?? const <String, Object?>{'ok': true};
    final OpUndoRecord? undo = result.undo;
    if (undo == null || recordUndo == null) return data;
    final int actionId = await recordUndo(op, args, undo);
    return data is Map
        ? <String, Object?>{
            for (final MapEntry<Object?, Object?> e in data.entries)
              '${e.key}': e.value,
            kCtlOpsUndoActionIdKey: actionId,
          }
        : data;
  }),
];
