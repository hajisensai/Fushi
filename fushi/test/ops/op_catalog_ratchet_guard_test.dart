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
const int kUndescribedRouteBaseline = 0;

/// 有意不进操作目录的路由前缀，值写明理由。
const Map<String, String> kRoutePrefixesNotForAi = <String, String>{
  '/api/admin/ai/agent/': 'AI 助手自己的会话 / 操作记录接口：AI 不能调 AI，终端版 AI 用',
};

/// 没有任何现有路由能读出任务状态的 longRunning 操作，值写明理由。只许放真没有
/// 状态路由的；能读就该写 taskStatus。
const Map<String, String> kLongRunningWithoutTaskStatus = <String, String>{};

/// 带「地址类」参数（名字像 url / link / endpoint / magnet…）却**不**先确认的操作，
/// 值写明为什么模型给的地址到不了它自己选的主机。其余带地址参数的操作一律
/// `needsConfirmation`：向模型给的任意地址发请求 = 把数据发给已指派 LLM 以外的
/// 第三方（spec §5.2），路径 / query 里能夹带模型看到的任何东西，撤销收不回。
/// 新增操作带地址参数时，先想清楚它会不会去请求那个地址。
const Map<String, String> kAddressParamOpsWithoutConfirmation =
    <String, String>{
      'url.probe':
          '只对 YouTube 地址联网，且只发往 YouTube（youtube_explode 只取 11 位 '
          'videoId 拼 www.youtube.com）；直链 / 网页站不联网'
          '（ctl_url_import_routes_test「直链 / 网页站探测只给种类，不联网」）',
      'online.repo.remove': '只从已存的仓库列表里删一条，不请求它',
      'online.source.get':
          'url 是搜索 / 浏览结果里的作品引用，交给已装扩展（安装时用户已确认，D9）'
          '自己的代码按它自己的站点拼请求；目的主机由扩展决定，不由模型决定',
      'online.source.add': '同 online.source.get：作品引用交给已装扩展',
      'online.source.download': '同 online.source.get：作品引用交给已装扩展',
      'links.list': 'endpoint 是本地条目引用（book:<key> 等），不是网络地址',
      'links.accept': 'endpoint 是本地条目引用，不是网络地址',
      'links.reject': 'endpoint 是本地条目引用，不是网络地址',
      'links.infer': 'endpoint 是本地条目引用，不是网络地址',
      'links.add': 'endpoint / other 是本地条目引用，不是网络地址',
      'links.remove': 'endpoint 是本地条目引用，不是网络地址',
      'web.bookmark.add': '只存书签，不打开；打开要经 web.open（先确认）或用户自己点',
      'web.bookmark.update': '只改书签字段，不打开',
      'web.adblock.allowlist.add': 'host 只进广告拦截白名单文本，不请求它',
      'web.adblock.allowlist.remove': 'host 只从白名单文本里删，不请求它',
    };

/// 「地址类」参数名：模型填的是一个会被请求的位置。
final RegExp _addressParamName = RegExp(
  r'(^|[a-z])(url|uri|link|endpoint|magnet|href|host|address)s?$',
  caseSensitive: false,
);

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
        expect(
          op.undo,
          isNull,
          reason: '${op.id}：能撤销就该是 write，不是 irreversible',
        );
      }
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
          '这些 longRunning 操作没有 taskStatus：用现有状态路由（kit.callRoute）'
          '映射成 OpTaskStatus，结果里任务 id 不在顶层 taskId/jobId 时再写 '
          'taskIdOf（见 lib/src/ops/op_task_status.dart）。确实没有状态路由才进 '
          'kLongRunningWithoutTaskStatus 并写明理由。\n${missing.join('\n')}',
    );
    for (final String id in kLongRunningWithoutTaskStatus.keys) {
      final FushiOp? op = catalog[id];
      expect(op?.longRunning, isTrue, reason: '$id：豁免表里的操作已不存在或不再 longRunning');
      expect(op?.taskStatus, isNull, reason: '$id：已有 taskStatus，从豁免表删掉');
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

  test('带地址参数的操作先确认（模型给的地址 = 不可撤销的出站，spec §5.2）', () {
    final List<String> offenders = <String>[
      for (final FushiOp op in catalog.ops)
        if (!op.spec.needsConfirmation &&
            !kAddressParamOpsWithoutConfirmation.containsKey(op.id))
          for (final OpParam p in op.spec.modelParams)
            if (_addressParamName.hasMatch(p.name)) '${op.id}(${p.name})',
    ];
    expect(
      offenders,
      isEmpty,
      reason:
          '这些操作让模型填一个地址却不先确认。会去请求它的：标 irreversible，'
          '或可撤销写操作加 confirm: true；确实不请求（只存起来 / 只发往固定主机）'
          '的进 kAddressParamOpsWithoutConfirmation 并写明理由。\n'
          '${offenders.join('\n')}',
    );
    for (final String id in kAddressParamOpsWithoutConfirmation.keys) {
      final FushiOp? op = catalog[id];
      expect(op, isNotNull, reason: '$id：豁免表里的操作已不存在');
      expect(
        op!.spec.modelParams.any(
          (OpParam p) => _addressParamName.hasMatch(p.name),
        ),
        isTrue,
        reason: '$id：已没有地址参数，从豁免表删掉',
      );
      expect(op.spec.needsConfirmation, isFalse, reason: '$id：已经先确认了，从豁免表删掉');
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
      expect(
        inPath,
        segments,
        reason: '${op.id}：inPath 参数要与 ${op.route.pattern} 的 :段一致',
      );
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
