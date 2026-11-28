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

/// 还在旧路径上的手写路由数（[CtlRoute.op] 为 null：手写 [CtlRoute] + 另写一份
/// [OpDescription]、靠 `METHOD pattern` 字符串配对）。只许减不许增：新操作一律写
/// [OpSpec] 并 `bind`，迁完一个域把这个数调到新的实际值。
///
/// 结构约束（id 形状、read 不带撤销、写操作可撤销或 irreversible、inPath 与模式一致、
/// remoteUrl 参数 / 装扩展必须先确认）在 [FushiOp] 构造时检查，组目录即炸，不在这里。
const int kLegacyRouteBaseline = 471;

/// 有意不进操作目录的路由前缀，值写明理由。
const Map<String, String> kRoutePrefixesNotForAi = <String, String>{
  '/api/admin/ai/agent/': 'AI 助手自己的会话 / 操作记录接口：AI 不能调 AI，终端版 AI 用',
};

/// 没有任何现有路由能读出任务状态的 longRunning 操作，值写明理由。只许放真没有
/// 状态路由的；能读就该写 taskStatus。（这条只管 app 目录：服务端的
/// `server.download.add` 还没有 taskStatus，见 fushi_server 的 admin_ops.dart。）
const Map<String, String> kLongRunningWithoutTaskStatus = <String, String>{};

void main() {
  final OpContext context = OpContext(ref: _UnusedRef());
  final List<CtlRoute> domain = buildDomainOpRoutes(context);
  final OpCatalog catalog = buildAppOpCatalog(context, domain);
  final Set<CtlRoute> described = <CtlRoute>{
    for (final FushiOp op in catalog.ops) op.route,
  };

  test('旧路径的手写路由数只许减不许增（新操作写 OpSpec）', () {
    final List<CtlRoute> legacy = <CtlRoute>[
      for (final CtlRoute route in domain)
        if (route.op == null) route,
    ];
    expect(
      legacy.length,
      lessThanOrEqualTo(kLegacyRouteBaseline),
      reason:
          '新增了手写路由。新操作写 OpSpec（packages/fushi_cli/lib/src/ops/specs/）并 bind。',
    );
    expect(
      legacy.length,
      kLegacyRouteBaseline,
      reason: '又迁走了一批，把 kLegacyRouteBaseline 调到 ${legacy.length}',
    );
  });

  test('旧路径的手写路由都有描述（豁免前缀除外）', () {
    final List<String> undescribed = <String>[
      for (final CtlRoute route in domain)
        if (route.op == null &&
            !described.contains(route) &&
            !kRoutePrefixesNotForAi.keys.any(route.pattern.startsWith))
          '${route.method} ${route.pattern}',
    ];
    expect(
      undescribed,
      isEmpty,
      reason: '给它写 OpSpec（或迁之前在 op_descriptions_<域>.dart 补描述）',
    );
  });

  test('豁免前缀下没有被描述的路由（描述了就不该豁免）', () {
    for (final FushiOp op in catalog.ops) {
      expect(
        kRoutePrefixesNotForAi.keys.any(op.route.pattern.startsWith),
        isFalse,
        reason: op.id,
      );
    }
  });

  test('longRunning 操作必须声明 taskStatus（AI 轮询任务、结束后报告，spec §6.1）', () {
    final List<String> missing = <String>[
      for (final FushiOp op in catalog.ops)
        if (op.longRunning &&
            op.taskStatus == null &&
            !kLongRunningWithoutTaskStatus.containsKey(op.id))
          op.id,
    ];
    expect(
      missing,
      isEmpty,
      reason:
          '这些 longRunning 操作没有 taskStatus：用现有状态路由映射成 OpTaskStatus，'
          '结果里任务 id 不在顶层 taskId/jobId 时再写 taskIdOf（见 '
          'lib/src/ops/op_task_status.dart）。确实没有状态路由才进 '
          'kLongRunningWithoutTaskStatus 并写明理由。\n${missing.join('\n')}',
    );
    for (final String id in kLongRunningWithoutTaskStatus.keys) {
      final FushiOp? op = catalog[id];
      expect(op?.longRunning, isTrue, reason: '$id：豁免表里的操作已不存在或不再 longRunning');
      expect(op?.taskStatus, isNull, reason: '$id：已有 taskStatus，从豁免表删掉');
    }
  });

  test('旧路径：表态参数真被路由读取', () {
    // OpSpec 来路的操作经声明对象读表态参数（OpArgs.boolean(gate)），不在这里查。
    final String routeSources = <String>[
      for (final FileSystemEntity f in Directory('lib/src/ops').listSync())
        if (f is File &&
            f.path.endsWith('.dart') &&
            f.uri.pathSegments.last.startsWith('ctl_'))
          f.readAsStringSync(),
      // 复习的路由本体在 engine（app 的 ctl_srs_routes.dart 只是装配），表态参数的读取点在那里。
      File(
        '../packages/fushi_engine/lib/srs/srs_ctl_routes.dart',
      ).readAsStringSync(),
    ].join('\n');
    for (final FushiOp op in catalog.ops) {
      if (op.route.op != null) continue;
      for (final OpParam gate in op.params.where((OpParam p) => p.userGate)) {
        expect(
          routeSources.contains("'${gate.name}'"),
          isTrue,
          reason: '${op.id}：表态参数 ${gate.name} 在路由源码里找不到读取点',
        );
      }
    }
  });
}
