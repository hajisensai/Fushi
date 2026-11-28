import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ops/op_catalog_assembly.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_routes.dart';
import 'package:fushi_cli/fushi_cli.dart';

class _UnusedRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('构造操作目录时不应访问 ref');
}

/// 操作目录的线上形态快照：给模型 / MCP 的工具 schema（[FushiOpSpec.modelSchema]）、
/// `/api/admin/ops/describe` 的描述（[FushiOpSpec.toJson]）和全部控制通道路由的
/// `METHOD pattern`。这些是外部契约（外部 MCP 客户端、CLI 脚本、互联客户端），
/// 重构声明方式时必须逐字节不变。
///
/// 有意改动时重写快照：
/// `FUSHI_OP_WIRE_SNAPSHOT_WRITE=1 dart tool/heavy.dart --here -- flutter test test/ops/op_catalog_wire_snapshot_test.dart --no-pub`
const String _snapshotPath = 'test/ops/goldens/op_catalog_wire.json';

String _render() {
  final OpContext context = OpContext(ref: _UnusedRef());
  final List<CtlRoute> routes = buildOpRoutes(context);
  final OpCatalog catalog = buildAppOpCatalog(
    context,
    buildDomainOpRoutes(context),
  );
  final List<FushiOp> ops = catalog.ops.toList()
    ..sort((FushiOp a, FushiOp b) => a.id.compareTo(b.id));
  final Map<String, Object?> snapshot = <String, Object?>{
    'routes': <String>[
      for (final CtlRoute r in routes)
        '${r.method} ${r.pattern}${r.requiresReady ? '' : ' (no-ready)'}',
    ],
    'ops': <String, Object?>{
      for (final FushiOp op in ops)
        op.id: <String, Object?>{
          'describe': op.spec.toJson(),
          'modelSchema': op.spec.modelSchema(),
          'needsConfirmation': op.spec.needsConfirmation,
        },
    },
  };
  return '${const JsonEncoder.withIndent('  ').convert(snapshot)}\n';
}

void main() {
  test('操作目录线上形态（工具 schema / describe / 路由表）逐字节不变', () {
    final String actual = _render();
    final File file = File(_snapshotPath);
    if (Platform.environment['FUSHI_OP_WIRE_SNAPSHOT_WRITE'] == '1') {
      file
        ..createSync(recursive: true)
        ..writeAsStringSync(actual);
      return;
    }
    expect(file.existsSync(), isTrue, reason: '缺快照 $_snapshotPath（见本文件头的重写命令）');
    expect(
      actual,
      file.readAsStringSync().replaceAll('\r\n', '\n'),
      reason: '操作目录的线上形态变了：给模型 / MCP 的 schema、describe 或路由表是外部契约',
    );
  });
}
