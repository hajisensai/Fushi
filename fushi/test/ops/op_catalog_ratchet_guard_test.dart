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

/// 没有描述的路由数上限（spec §4.2 棘轮）：只许减不许增。给路由补了描述就把它
/// 调到新的实际值；新增路由必须同时带描述（否则这个数会涨）。
const int kUndescribedRouteBaseline = 9999;

/// 有意不进操作目录的路由前缀，值写明理由。
const Map<String, String> kRoutePrefixesNotForAi = <String, String>{
  '/api/admin/ai/agent/': 'AI 助手自己的会话 / 操作记录接口：AI 不能调 AI，终端版 AI 用',
};

/// 「装扩展一律先确认」（spec D9，所有者 2026-10-26 拍板）覆盖的操作 id 模式。
final RegExp _extensionInstallOp = RegExp(
  r'^online\.(extension\.(install|update)\w*|repo\.add)$',
);

void main() {
  final OpContext context = OpContext(ref: _UnusedRef());
  final List<CtlRoute> domain = buildDomainOpRoutes(context);
  final OpCatalog catalog = buildAppOpCatalog(context, domain);
  final Set<CtlRoute> described = <CtlRoute>{
    for (final FushiOp op in catalog.ops) op.route,
  };
  final List<CtlRoute> undescribed = <CtlRoute>[
    for (final CtlRoute route in domain)
      if (!described.contains(route) &&
          !kRoutePrefixesNotForAi.keys.any(route.pattern.startsWith))
        route,
  ];

  test('没描述的路由数只许减不许增', () {
    expect(
      undescribed.length,
      lessThanOrEqualTo(kUndescribedRouteBaseline),
      reason:
          '新增了没描述的路由。给它写 OpDescription（op_descriptions_<域>.dart）。\n'
          '${undescribed.map((CtlRoute r) => '${r.method} ${r.pattern}').join('\n')}',
    );
    expect(
      undescribed.length,
      kUndescribedRouteBaseline,
      reason: '描述补上了，把 kUndescribedRouteBaseline 调到 ${undescribed.length}',
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

  test('操作 id 唯一、点分小写、不含 __（AI 线上名把点换成 __）', () {
    final RegExp shape = RegExp(r'^[a-z][a-z0-9]*(\.[a-z][a-z0-9-]*)+$');
    for (final FushiOp op in catalog.ops) {
      expect(shape.hasMatch(op.id), isTrue, reason: op.id);
      expect(op.id.contains('__'), isFalse, reason: op.id);
      expect(op.summary.trim(), isNotEmpty, reason: op.id);
    }
  });

  test('非 read 操作必须可撤销，或标成 irreversible（AI 执行前出确认卡片）', () {
    for (final FushiOp op in catalog.ops) {
      if (op.risk == OpRisk.read) {
        expect(op.undo, isNull, reason: '${op.id}：read 操作不该声明撤销');
        continue;
      }
      expect(
        op.undo != null || op.risk == OpRisk.irreversible,
        isTrue,
        reason: '${op.id}：AI 写操作必须可回滚（fushi/CLAUDE.md §13）',
      );
      if (op.risk == OpRisk.irreversible) {
        expect(op.undo, isNull, reason: '${op.id}：能撤销就该是 write，不是 irreversible');
      }
    }
  });

  test('装扩展一律先确认（D9）', () {
    for (final FushiOp op in catalog.ops) {
      if (_extensionInstallOp.hasMatch(op.id)) {
        expect(
          op.confirm || op.risk == OpRisk.irreversible,
          isTrue,
          reason: '${op.id}：装扩展要用户点确认',
        );
      }
    }
  });

  test('路径参数与模式一致；表态参数真被路由读取', () {
    final String routeSources = <String>[
      for (final FileSystemEntity f in Directory('lib/src/ops').listSync())
        if (f is File &&
            f.path.endsWith('.dart') &&
            f.uri.pathSegments.last.startsWith('ctl_'))
          f.readAsStringSync(),
    ].join('\n');
    for (final FushiOp op in catalog.ops) {
      final Set<String> segments = <String>{
        for (final String seg in op.route.pattern.split('/'))
          if (seg.startsWith(':')) seg.substring(1),
      };
      final Set<String> inPath = <String>{
        for (final OpParam p in op.params)
          if (p.inPath) p.name,
      };
      expect(inPath, segments, reason: '${op.id}：inPath 参数要与 ${op.route.pattern} 的 :段一致');
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
