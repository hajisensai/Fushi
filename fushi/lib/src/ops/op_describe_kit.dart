import 'dart:convert';

import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/ops/op_context.dart';

/// 各域写操作描述（`op_descriptions_<域>.dart`）共用的工具：按 `METHOD pattern`
/// 找现有路由、在撤销闭包里调别的路由（安装的撤销 = 卸载路由），以及几种通用
/// 撤销形态与可用性谓词。只拼现有 handler，不写业务逻辑（spec §4）。
class OpDescribeKit {
  OpDescribeKit(this.context, List<CtlRoute> routes)
    : _routes = <String, CtlRoute>{
        for (final CtlRoute route in routes)
          '${route.method} ${route.pattern}': route,
      };

  final OpContext context;
  final Map<String, CtlRoute> _routes;

  /// 现有路由；不存在抛 [StateError]（描述与实现漂移在测试里炸）。
  CtlRoute route(String method, String pattern) {
    final CtlRoute? route = _routes['$method $pattern'];
    if (route == null) throw StateError('路由 $method $pattern 不存在');
    return route;
  }

  /// 以 HTTP 等价的方式调一条现有路由：`:name` 段用 [params] 代入。
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
  OpUndo snapshotUndo({
    required Future<Object?> Function(Map<String, String> params) read,
    required Future<void> Function(Map<String, String> params, Object? old)
    write,
    required Object? Function(CtlCall call, Object? result) newValue,
  }) => OpUndo(
    capture: (CtlCall call) async => <String, Object?>{
      'params': call.params,
      'old': await read(call.params),
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
      final Map<String, String> params = <String, String>{
        for (final MapEntry<Object?, Object?> e
            in (payload['params'] as Map? ?? const <Object?, Object?>{})
                .entries)
          '${e.key}': '${e.value}',
      };
      try {
        if (!sameJson(await read(params), payload['new'])) {
          return const OpUndoOutcome.superseded();
        }
        await write(params, payload['old']);
        return const OpUndoOutcome.done();
      } on CtlFailure catch (failure) {
        return OpUndoOutcome.failed(failure.message ?? failure.code);
      }
    },
  );

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
  }) => snapshotUndo(
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
