/// 自定义撤销的通用件：各域的操作描述（app 的 `op_descriptions_<域>.dart`、engine 里
/// app 与无头服务端共用的域）拼 [OpUndo] 时用同一份。纯 Dart，不懂任何域语义。
library;

import '../ctl_routes.dart';
import 'fushi_op.dart';

/// 把 [CtlFailure] 变成撤销结论（404 = 对象已不在 → superseded）。
Future<OpUndoOutcome> opUndoGuard(Future<OpUndoOutcome> Function() body) async {
  try {
    return await body();
  } on CtlFailure catch (failure) {
    return failure.status == 404
        ? OpUndoOutcome.superseded(failure.message)
        : OpUndoOutcome.failed(failure.message ?? failure.code);
  }
}

/// 自定义撤销：[capture]（可空）抓前态，[payloadOf] 用前态 + 结果拼载荷，
/// [revert] 自己判 done / superseded / failed（[CtlFailure] 统一兜成结论）。
OpUndo opCustomUndo({
  Future<Map<String, Object?>> Function(CtlCall call)? capture,
  required Map<String, Object?> Function(
    CtlCall call,
    Map<String, Object?> before,
    Object? result,
  )
  payloadOf,
  required Future<OpUndoOutcome> Function(Map<String, Object?> payload) revert,
  String? Function(Map<String, Object?> payload)? describe,
}) => OpUndo(
  capture: capture,
  record: (CtlCall call, Map<String, Object?> before, Object? result) {
    final Map<String, Object?> payload = payloadOf(call, before, result);
    return OpUndoRecord(payload: payload, after: describe?.call(payload));
  },
  revert: (Map<String, Object?> payload) => opUndoGuard(() => revert(payload)),
);

/// 字符串列表（JSON 往返后的 `List<dynamic>` 也认）。
List<String> opUndoStrings(Object? raw) => <String>[
  if (raw is List)
    for (final Object? item in raw)
      if (item != null) '$item',
];
