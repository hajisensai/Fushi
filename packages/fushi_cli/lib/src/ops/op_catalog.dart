/// 操作目录与进程内调用器（spec §3、§4）。
library;

import '../ctl_routes.dart';
import 'fushi_op.dart';
import 'op_spec.dart';

/// 谁在调用。决定 [OpParam.userGate] 参数从哪来。
enum OpCaller {
  /// 用户自己（`fushi_cli op call`、终端里敲的 flag）：表态参数可以直接给。
  user,

  /// 模型：args 里出现表态参数一律 400——只能由运行时按确认结果注入。
  model,
}

/// 一次调用的结果。
class OpInvocation {
  const OpInvocation({required this.op, required this.result, this.undo});

  final FushiOp op;

  /// handler 的返回值（null 视为 `{"ok": true}`）。
  final Object? result;

  /// 可撤销写操作的撤销载荷；读操作或没要求抓快照时为 null。
  final OpUndoRecord? undo;
}

/// 全部带描述的操作。没描述的路由照旧只给 CLI 用（spec §4.2 棘轮）。
class OpCatalog {
  OpCatalog(Iterable<FushiOp> ops) : _ops = <String, FushiOp>{} {
    for (final FushiOp op in ops) {
      if (_ops.containsKey(op.id)) {
        throw StateError('操作 id 重复：${op.id}');
      }
      _ops[op.id] = op;
    }
  }

  /// 组目录：[routes] 里由 [OpSpec.bind] 派生的路由直接取它的操作（[CtlRoute.op]）；
  /// **旧路径**的 [descriptions] 按 `METHOD pattern` 挂到其余手写路由上；再并入
  /// [extra]（只在进程内有的操作）。旧描述对不上任何手写路由时抛 [StateError]。
  factory OpCatalog.build(
    List<CtlRoute> routes,
    Iterable<OpDescription> descriptions, {
    Iterable<FushiOp> extra = const <FushiOp>[],
  }) {
    final List<FushiOp> ops = <FushiOp>[
      for (final CtlRoute route in routes)
        if (route.op case final FushiOp op) op,
    ];
    final Map<String, CtlRoute> legacy = <String, CtlRoute>{
      for (final CtlRoute route in routes)
        if (route.op == null) '${route.method} ${route.pattern}': route,
    };
    for (final OpDescription d in descriptions) {
      final CtlRoute? route = legacy[d.routeKey];
      if (route == null) {
        throw StateError('操作 ${d.id} 的路由 ${d.routeKey} 不存在（或已由 OpSpec 声明）');
      }
      ops.add(d.bind(route));
    }
    ops.addAll(extra);
    return OpCatalog(ops);
  }

  final Map<String, FushiOp> _ops;

  Iterable<FushiOp> get ops => _ops.values;

  FushiOp? operator [](String id) => _ops[id];

  /// 当前可用的操作（可用性谓词逐个现算）。
  Iterable<FushiOp> available() =>
      _ops.values.where((FushiOp op) => op.currentAvailability().isAvailable);

  /// 按自然语言 / 关键词检索（`ops.search`、`fushi_cli op ls <词>`）。确定性打分：
  /// id 段命中 > 说明命中 > 参数名命中；同分按 id 排序。只返回当前可用的。
  List<FushiOp> search(String query, {int limit = 12}) {
    final List<String> terms = _terms(query);
    if (terms.isEmpty) {
      final List<FushiOp> all = available().toList()
        ..sort((FushiOp a, FushiOp b) => a.id.compareTo(b.id));
      return all.take(limit).toList(growable: false);
    }
    final List<(FushiOp, int)> scored = <(FushiOp, int)>[];
    for (final FushiOp op in available()) {
      final List<String> idParts = op.id.toLowerCase().split(RegExp(r'[._\-]'));
      final String summary = op.summary.toLowerCase();
      int score = 0;
      for (final String term in terms) {
        if (idParts.contains(term)) {
          score += 6;
        } else if (op.id.toLowerCase().contains(term)) {
          score += 4;
        }
        if (summary.contains(term)) score += 3;
        for (final OpParam p in op.params) {
          if (p.name.toLowerCase().contains(term)) score += 1;
        }
      }
      if (score > 0) scored.add((op, score));
    }
    scored.sort(((FushiOp, int) a, (FushiOp, int) b) {
      final int byScore = b.$2.compareTo(a.$2);
      return byScore != 0 ? byScore : a.$1.id.compareTo(b.$1.id);
    });
    return <FushiOp>[for (final (FushiOp op, int _) in scored.take(limit)) op];
  }

  static List<String> _terms(String query) => query
      .toLowerCase()
      .split(RegExp(r'[\s,，、;；/._\-]+'))
      .where((String t) => t.length >= 2)
      .toList(growable: false);
}

//// 进程内调用器：AI 助手与 `/api/admin/ops/call` 都经它调操作。
///
/// 参数严格校验（未知参数、类型、枚举、必填一律 400 回给调用方），表态参数按
/// [OpCaller] 处理，再经与 HTTP 直连同一个 [OpArgs.parse] 得到 [OpArgs] 直接调
/// 实现——与按钮、`fushi_cli` 走同一个方法。
class OpInvoker {
  OpInvoker(this.catalog, {bool Function()? ready})
    : _ready = ready ?? _alwaysReady;

  final OpCatalog catalog;
  final bool Function() _ready;

  static bool _alwaysReady() => true;

  /// 调用 [id]。
  ///
  /// [grantedGates]：运行时替用户注入的表态参数（AI 运行时在确认后传入，或可逆
  /// 操作直接传入全部）。[captureUndo]：可撤销操作执行前抓快照、执行后返回撤销
  /// 载荷。
  Future<OpInvocation> invoke(
    String id,
    Map<String, Object?> args, {
    OpCaller caller = OpCaller.user,
    Set<String> grantedGates = const <String>{},
    bool captureUndo = false,
  }) async {
    final FushiOp? op = catalog[id];
    if (op == null) throw CtlFailure.notFound('没有这个操作：$id');
    final OpAvailability availability = op.currentAvailability();
    if (!availability.isAvailable) {
      throw CtlFailure.rejected(
        '${availability.code}'
        '${availability.message == null ? '' : ': ${availability.message}'}',
      );
    }
    if (op.decl.requiresReady && !_ready()) {
      throw const CtlFailure.conflict('not_ready');
    }
    final OpArgs call = buildCall(
      op,
      args,
      caller: caller,
      grantedGates: grantedGates,
    );
    final OpUndo? undo = captureUndo ? op.undo : null;
    final Map<String, Object?> before = undo?.capture == null
        ? const <String, Object?>{}
        : await undo!.capture!(call);
    final Object? result = await op.run(call);
    return OpInvocation(
      op: op,
      result: result,
      undo: undo?.record(call, before, result),
    );
  }

  /// 校验参数并拼出 [OpArgs]（单独暴露给测试与「确认卡片」预览）。
  ///
  /// 这里只做进程内调用独有的两件事——表态参数由谁给（模型不许给）、对象参数铺进
  /// body 顶层——然后交给 [OpArgs.parse]（拒绝未知参数），转换与校验只在那里。
  OpArgs buildCall(
    FushiOp op,
    Map<String, Object?> args, {
    OpCaller caller = OpCaller.user,
    Set<String> grantedGates = const <String>{},
  }) {
    final Map<String, OpParam> declared = <String, OpParam>{
      for (final OpParam p in op.params) p.name: p,
    };
    final Map<String, String> pathParams = <String, String>{};
    final Map<String, Object?> body = <String, Object?>{};
    for (final MapEntry<String, Object?> entry in args.entries) {
      final OpParam? param = declared[entry.key];
      if (param == null || (param.userGate && caller == OpCaller.model)) {
        throw CtlFailure.badRequest('未知参数：${entry.key}');
      }
      if (entry.value == null) continue;
      if (param.inPath) {
        pathParams[param.name] = '${coerceOpParam(param, entry.value!)}';
      } else if (param.spread) {
        final Object value = coerceOpParam(param, entry.value!);
        for (final MapEntry<String, Object?> e
            in (value as Map<String, Object?>).entries) {
          if (declared.containsKey(e.key)) {
            throw CtlFailure.badRequest('${param.name}.${e.key} 与参数重名');
          }
          body[e.key] = e.value;
        }
      } else {
        // 旧路径的 handler 直接读 body：放转换后的值（与 [OpArgs.values] 同一份）。
        body[param.name] = coerceOpParam(param, entry.value!);
      }
    }
    for (final String gate in grantedGates) {
      final OpParam? param = declared[gate];
      if (param == null || !param.userGate) {
        throw StateError('${op.id} 没有表态参数 $gate');
      }
      body[gate] = true;
    }
    for (final String name in op.decl.pathSegmentNames) {
      if (!pathParams.containsKey(name)) {
        throw CtlFailure.badRequest('$name 缺失');
      }
    }
    return OpArgs.parse(
      op.decl,
      CtlCall(
        method: op.decl.method,
        path: op.decl.fillPath(pathParams),
        params: pathParams,
        body: body,
        fromModel: caller == OpCaller.model,
      ),
      unknown: OpUnknownParams.reject,
    );
  }
}
