import 'dart:convert';

import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/ops/op_context.dart';

/// 各域操作共用的工具：在撤销 / 组合闭包里调别的操作（安装的撤销 = 卸载），以及几种
/// 通用撤销形态与可用性谓词。只拼现有实现，不写业务逻辑（spec §4）。
///
/// 调别的操作有两条路：已迁到 [OpSpec] 的用 [invoke]（按声明对象找，参数照声明校验）；
/// 还在旧路径上的域只能用 [callRoute] / [route]（按 `METHOD pattern` 字符串找，
/// 剩余调用数由 `op_catalog_ratchet_guard_test.dart` 只减不增地卡住）。
class OpDescribeKit {
  /// [routes] 可以后给（[attach]）：[OpSpec] 来路的操作要先拿到 kit 才能构造，
  /// 路由表由它们派生。撤销 / 组合闭包都是执行时才查表。
  OpDescribeKit(this.context, [List<CtlRoute>? routes]) {
    if (routes != null) attach(routes);
  }

  final OpContext context;
  Map<String, CtlRoute> _routes = const <String, CtlRoute>{};
  Map<OpSpec, FushiOp> _ops = Map<OpSpec, FushiOp>.identity();

  /// 装上整张路由表（含 [OpSpec] 派生的路由）。
  void attach(List<CtlRoute> routes) {
    _routes = <String, CtlRoute>{
      for (final CtlRoute route in routes)
        '${route.method} ${route.pattern}': route,
    };
    _ops = Map<OpSpec, FushiOp>.identity()
      ..addAll(<OpSpec, FushiOp>{
        for (final CtlRoute route in routes)
          if (route.op case final FushiOp op) op.decl: op,
      });
  }

  /// 调另一个已迁到 [OpSpec] 的操作（撤销、组合）：按声明对象找；[pathArgs] 代入
  /// `:段`，[body] 照 [target] 的参数表校验（写错参数名立刻抛）。
  Future<Object?> invoke(
    OpSpec target, {
    Map<String, String> pathArgs = const <String, String>{},
    Map<String, Object?> body = const <String, Object?>{},
  }) {
    final FushiOp? op = _ops[target];
    if (op == null) throw StateError('操作 ${target.id} 不在这张路由表里');
    return op.run(OpArgs.direct(target, pathArgs: pathArgs, body: body));
  }

  /// **旧路径**：按 `METHOD pattern` 找现有路由；不存在抛 [StateError]。
  CtlRoute route(String method, String pattern) {
    final CtlRoute? route = _routes['$method $pattern'];
    if (route == null) throw StateError('路由 $method $pattern 不存在');
    if (route.op case final FushiOp op) {
      // 目标已迁到 OpSpec：只许按声明对象调（[invoke]），字符串引用不再新增。
      throw StateError('$method $pattern 已由 OpSpec ${op.id} 声明，改用 kit.invoke');
    }
    return route;
  }

  /// **旧路径**：以 HTTP 等价的方式调一条现有路由（`:name` 段用 [params] 代入）。
  /// 目标已迁到 [OpSpec] 的改用 [invoke]。
  Future<Object?> callRoute(
    String method,
    String pattern, {
    Map<String, String> params = const <String, String>{},
    Map<String, Object?> body = const <String, Object?>{},
  }) {
    final CtlRoute target = route(method, pattern);
    final String path = pattern
        .split('/')
        .map((String seg) {
          if (!seg.startsWith(':')) return seg;
          final String? value = params[seg.substring(1)];
          if (value == null) throw StateError('$pattern 缺路径参数 $seg');
          return Uri.encodeComponent(value);
        })
        .join('/');
    return target.handler(
      CtlCall(method: method, path: path, params: params, body: body),
    );
  }

  /// 通用快照撤销：执行前 [read] 旧值，撤销时 [write] 写回。撤销前再读一次：
  /// 当前值已不是这次执行的结果（[newValue]，之后被手动改过）就报 superseded、
  /// 不覆盖用户的修改（spec §5.3）。[read] / [write] 拿到的是本次调用的路径参数。
  ///
  /// [linked]：这次写入会顺带改掉的其他条目（同一组读写路由，各自的路径参数）。
  /// 执行前一并快照；撤销时本项写回后，把**当前值与快照不同**的联动条目逐个写回
  /// （没被改动、或之后已被手动改回的不碰）。联动条目写回失败报 partial。
  OpUndo snapshotUndo({
    required Future<Object?> Function(Map<String, String> params) read,
    required Future<void> Function(Map<String, String> params, Object? old)
    write,
    required Object? Function(CtlCall call, Object? result) newValue,
    List<Map<String, String>> Function(Map<String, String> params)? linked,
  }) => OpUndo(
    capture: (CtlCall call) async => <String, Object?>{
      'params': call.params,
      'old': await read(call.params),
      if (linked != null)
        'linked': <Map<String, Object?>>[
          for (final Map<String, String> params in linked(call.params))
            <String, Object?>{'params': params, 'old': await read(params)},
        ],
    },
    record: (CtlCall call, Map<String, Object?> before, Object? result) {
      final Object? after = newValue(call, result);
      return OpUndoRecord(
        payload: <String, Object?>{...before, 'new': after},
        before: _display(before['old']),
        after: _display(after),
      );
    },
    revert: (Map<String, Object?> payload) async {
      final Map<String, String> params = _stringMap(payload['params']);
      try {
        if (!sameJson(await read(params), payload['new'])) {
          return const OpUndoOutcome.superseded();
        }
        await write(params, payload['old']);
      } on CtlFailure catch (failure) {
        return OpUndoOutcome.failed(failure.message ?? failure.code);
      }
      final List<String> failed = <String>[];
      for (final Object? snapshot
          in payload['linked'] as List? ?? const <Object?>[]) {
        if (snapshot is! Map) continue;
        final Map<String, String> linkedParams = _stringMap(snapshot['params']);
        try {
          if (sameJson(await read(linkedParams), snapshot['old'])) continue;
          await write(linkedParams, snapshot['old']);
        } on CtlFailure catch (failure) {
          failed.add(
            '${linkedParams.values.join('/')}: '
            '${failure.message ?? failure.code}',
          );
        }
      }
      if (failed.isNotEmpty) return OpUndoOutcome.partial(failed.join('; '));
      return const OpUndoOutcome.done();
    },
  );

  static Map<String, String> _stringMap(Object? raw) => <String, String>{
    for (final MapEntry<Object?, Object?> e
        in (raw as Map? ?? const <Object?, Object?>{}).entries)
      '${e.key}': '${e.value}',
  };

  /// [snapshotUndo] 的常见形态：读路由与写路由共用同一组路径参数，值都在应答的
  /// [field] 字段里；写路由把值放进 body 的 [writeField]（默认同 [field]）。
  OpUndo readBackUndo({
    required String readMethod,
    required String readPattern,
    required String writeMethod,
    required String writePattern,
    String field = 'value',
    String? writeField,
    Map<String, Object?> extraWriteBody = const <String, Object?>{},
    List<Map<String, String>> Function(Map<String, String> params)? linked,
  }) => snapshotUndo(
    linked: linked,
    read: (Map<String, String> params) async {
      final Object? current = await callRoute(
        readMethod,
        readPattern,
        params: params,
      );
      return current is Map ? current[field] : null;
    },
    write: (Map<String, String> params, Object? old) async {
      await callRoute(
        writeMethod,
        writePattern,
        params: params,
        body: <String, Object?>{...extraWriteBody, writeField ?? field: old},
      );
    },
    newValue: (CtlCall call, Object? result) =>
        result is Map && result.containsKey(field)
        ? result[field]
        : call.body[writeField ?? field],
  );

  /// 从列表路由（`{listKey: [{idField: …, field: …}]}`）里读一项的一个字段。
  Future<Object?> readListField({
    required String pattern,
    required String listKey,
    required String id,
    required String field,
    String idField = 'id',
    Map<String, String> params = const <String, String>{},
  }) async {
    final Object? listed = await callRoute('GET', pattern, params: params);
    final Object? rows = listed is Map ? listed[listKey] : listed;
    if (rows is! List) return null;
    for (final Object? row in rows) {
      if (row is Map && '${row[idField]}' == id) return row[field];
    }
    throw CtlFailure.notFound('$id 已不存在');
  }

  /// 撤销 = 调一条「反向」路由（安装 ↔ 卸载、启用 ↔ 停用、入队 ↔ 取消）。
  /// [payloadOf] 从执行参数与结果里拼出撤销要的数据（如扩展 id、任务 id），
  /// [inverse] 用它调反向路由。
  OpUndo inverseRouteUndo({
    required Map<String, Object?> Function(CtlCall call, Object? result)
    payloadOf,
    required Future<Object?> Function(Map<String, Object?> payload) inverse,
    String? Function(Map<String, Object?> payload)? describe,
  }) => OpUndo(
    record: (CtlCall call, Map<String, Object?> before, Object? result) {
      final Map<String, Object?> payload = payloadOf(call, result);
      return OpUndoRecord(payload: payload, after: describe?.call(payload));
    },
    revert: (Map<String, Object?> payload) async {
      try {
        await inverse(payload);
        return const OpUndoOutcome.done();
      } on CtlFailure catch (failure) {
        return failure.status == 404
            ? OpUndoOutcome.superseded(failure.message)
            : OpUndoOutcome.failed(failure.message ?? failure.code);
      }
    },
  );

  /// 模块开着（[ModuleId.availableOn] 与合规门由模块自己算）。
  OpAvailability Function() whenModule(ModuleId module) =>
      () => context.appModel.moduleEnabled(module)
      ? const OpAvailability.available()
      : OpAvailability.unavailable('module_disabled', module.name);

  /// 过 iOS 上架合规门（判据只认 [StoreRestrictedCapability]，spec D6）。
  OpAvailability Function() whenStoreAllows(
    StoreRestrictedCapability capability,
  ) =>
      () => capability.isAvailable
      ? const OpAvailability.available()
      : OpAvailability.unavailable('store_restricted', capability.name);

  /// 几个谓词都要过。
  OpAvailability Function() all(List<OpAvailability Function()> predicates) =>
      () {
        for (final OpAvailability Function() p in predicates) {
          final OpAvailability result = p();
          if (!result.isAvailable) return result;
        }
        return const OpAvailability.available();
      };

  static bool sameJson(Object? a, Object? b) =>
      jsonEncode(a) == jsonEncode(b) || '$a' == '$b';

  static String? _display(Object? value) {
    if (value == null) return null;
    final String text = value is String ? value : jsonEncode(value);
    return text.length > 200 ? '${text.substring(0, 200)}…' : text;
  }
}
