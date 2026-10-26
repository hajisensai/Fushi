/// 操作目录与进程内调用器（spec §3、§4）。
library;

import '../ctl_routes.dart';
import 'fushi_op.dart';

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

  /// 按 `METHOD pattern` 把 [descriptions] 挂到 [routes] 上，再并入 [extra]
  /// （只在进程内有的操作，如 `ui.ask_choice`）。描述对不上任何路由时抛
  /// [StateError]——描述与实现漂移要在测试里炸，不在运行时静默丢工具。
  factory OpCatalog.build(
    List<CtlRoute> routes,
    Iterable<OpDescription> descriptions, {
    Iterable<FushiOp> extra = const <FushiOp>[],
  }) {
    final Map<String, CtlRoute> byKey = <String, CtlRoute>{
      for (final CtlRoute route in routes)
        '${route.method} ${route.pattern}': route,
    };
    final List<FushiOp> ops = <FushiOp>[];
    for (final OpDescription d in descriptions) {
      final CtlRoute? route = byKey[d.routeKey];
      if (route == null) {
        throw StateError('操作 ${d.id} 的路由 ${d.routeKey} 不存在');
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

/// 进程内调用器：AI 助手与 `/api/admin/ops/call` 都经它调路由 handler。
///
/// 参数严格校验（未知参数、类型、枚举、必填一律 400 回给调用方），表态参数按
/// [OpCaller] 处理，然后拼出与 HTTP 等价的 [CtlCall] 直接调 handler——与按钮、
/// `fushi_cli` 走同一个方法。
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
    if (op.route.requiresReady && !_ready()) {
      throw const CtlFailure.conflict('not_ready');
    }
    final CtlCall call = buildCall(
      op,
      args,
      caller: caller,
      grantedGates: grantedGates,
    );
    final OpUndo? undo = captureUndo ? op.undo : null;
    final Map<String, Object?> before = undo?.capture == null
        ? const <String, Object?>{}
        : await undo!.capture!(call);
    final Object? result = await op.route.handler(call);
    return OpInvocation(
      op: op,
      result: result,
      undo: undo?.record(call, before, result),
    );
  }

  /// 校验参数并拼出 [CtlCall]（单独暴露给测试与「确认卡片」预览）。
  CtlCall buildCall(
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
      final Object value = _coerce(param, entry.value!);
      if (param.inPath) {
        pathParams[param.name] = '$value';
      } else if (param.spread && value is Map<String, Object?>) {
        for (final MapEntry<String, Object?> e in value.entries) {
          if (declared.containsKey(e.key)) {
            throw CtlFailure.badRequest('${param.name}.${e.key} 与参数重名');
          }
          body[e.key] = e.value;
        }
      } else {
        body[param.name] = value;
      }
    }
    for (final String gate in grantedGates) {
      final OpParam? param = declared[gate];
      if (param == null || !param.userGate) {
        throw StateError('${op.id} 没有表态参数 $gate');
      }
      body[gate] = true;
    }
    for (final OpParam param in op.params) {
      if (!param.required) continue;
      final bool present = param.inPath
          ? pathParams.containsKey(param.name)
          : body.containsKey(param.name);
      if (!present) throw CtlFailure.badRequest('${param.name} 缺失');
    }
    final String path = op.route.pattern
        .split('/')
        .map((String seg) {
          if (!seg.startsWith(':')) return seg;
          final String name = seg.substring(1);
          final String? value = pathParams[name];
          if (value == null) throw CtlFailure.badRequest('$name 缺失');
          return Uri.encodeComponent(value);
        })
        .join('/');
    return CtlCall(
      method: op.route.method,
      path: path,
      params: pathParams,
      body: body,
    );
  }

  static Object _coerce(OpParam param, Object value) {
    switch (param.type) {
      case OpParamType.string:
        final String text = value is String ? value : '$value';
        final List<String>? allowed = param.enumValues;
        if (allowed != null && !allowed.contains(text)) {
          throw CtlFailure.badRequest(
            '${param.name} 只能是 ${allowed.join(' / ')}',
          );
        }
        return text;
      case OpParamType.integer:
        if (value is int) return value;
        if (value is num && value == value.roundToDouble()) {
          return value.toInt();
        }
        final int? parsed = int.tryParse('$value'.trim());
        if (parsed == null) {
          throw CtlFailure.badRequest('${param.name} 必须是整数');
        }
        return parsed;
      case OpParamType.number:
        if (value is num) return value;
        final num? parsed = num.tryParse('$value'.trim());
        if (parsed == null) {
          throw CtlFailure.badRequest('${param.name} 必须是数字');
        }
        return parsed;
      case OpParamType.boolean:
        if (value is bool) return value;
        switch ('$value'.trim().toLowerCase()) {
          case 'true' || '1' || 'yes' || 'on':
            return true;
          case 'false' || '0' || 'no' || 'off':
            return false;
        }
        throw CtlFailure.badRequest('${param.name} 必须是布尔值');
      case OpParamType.stringList:
        if (value is List) {
          return <String>[for (final Object? item in value) '$item'];
        }
        if (value is String) return <String>[value];
        throw CtlFailure.badRequest('${param.name} 必须是字符串数组');
      case OpParamType.object:
        if (value is Map) return Map<String, Object?>.from(value);
        throw CtlFailure.badRequest('${param.name} 必须是对象');
      case OpParamType.objectList:
        if (value is List && value.every((Object? e) => e is Map)) {
          return <Map<String, Object?>>[
            for (final Object? e in value) Map<String, Object?>.from(e! as Map),
          ];
        }
        throw CtlFailure.badRequest('${param.name} 必须是对象数组');
    }
  }
}
