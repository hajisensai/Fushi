import 'dart:io';

import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_server/src/admin/admin_ops.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

/// 服务端 `server.*` 操作目录里还用旧写法（[OpDescription] + 转发路由，按
/// `METHOD pattern` 字符串配对）的操作——只许减不许增（架构重构 C1 / C2）。基线逐条
/// 列出操作 id：新操作一律写 [OpSpec] 并 `bind`（那样的操作 [CtlRoute.op] 非空，不在
/// 这张表里），迁走一条就从基线删掉一条。
///
/// 复习库内容那批操作（`server.srs.*` 里走 engine 共用路由的）只在装配方接了复习库时
/// 才进目录，描述在 `fushi_engine` 的 `srs_ctl_ops.dart`，由 app 侧
/// `fushi/test/ops/op_catalog_ratchet_guard_test.dart` 的基线（手写路由逐条 + 每个文件
/// 的 `OpDescription(` 构造处数，含本包的 `admin_ops.dart`）卡住。
///
/// 迁走一批后缩小基线（只会缩小：实际存量超出现有基线时拒绝写）：
/// `FUSHI_OP_LEGACY_SURFACE_WRITE=1 dart test test/admin_ops_legacy_ratchet_test.dart`
const String _baselinePath = 'test/goldens/server_legacy_ops.txt';

void main() {
  test('server.* 目录里旧写法的操作只许减不许增', () {
    final ({List<CtlRoute> routes, List<OpDescription> descriptions}) ops =
        buildServerAdminOps(
          () =>
              (shelf.Request request) async => shelf.Response.notFound(''),
        );
    final OpCatalog catalog = OpCatalog.build(ops.routes, ops.descriptions);
    final List<String> legacy = <String>[
      for (final FushiOp op in catalog.ops)
        if (op.route.op == null) op.id,
    ]..sort();
    final File file = File(_baselinePath);
    final Set<String> baseline = file.existsSync()
        ? file
              .readAsLinesSync()
              .map((String line) => line.trim())
              .where((String line) => line.isNotEmpty)
              .toSet()
        : <String>{};
    final List<String> added = <String>[
      if (file.existsSync())
        for (final String id in legacy)
          if (!baseline.contains(id)) id,
    ];
    expect(
      added,
      isEmpty,
      reason:
          '新增了旧写法的服务端操作。新操作写 OpSpec（packages/fushi_cli/lib/src/ops/'
          'specs/）并 bind；基线不能靠重写放行。\n${added.join('\n')}',
    );
    final String rendered = '${legacy.join('\n')}\n';
    if (Platform.environment['FUSHI_OP_LEGACY_SURFACE_WRITE'] == '1') {
      file
        ..createSync(recursive: true)
        ..writeAsStringSync(rendered);
      return;
    }
    expect(file.existsSync(), isTrue, reason: '缺基线 $_baselinePath（见本文件头的重写命令）');
    expect(
      rendered,
      file.readAsStringSync().replaceAll('\r\n', '\n'),
      reason: '又迁走了一批：按本文件头的命令把基线缩小到现在的实际存量',
    );
  });
}
