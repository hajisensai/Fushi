import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/agent/ai_agent_skills.dart';
import 'package:fushi/src/ai/agent/ai_agent_toolbox.dart';
import 'package:fushi/src/ai/mcp/ai_mcp_access.dart';
import 'package:fushi/src/ai/mcp/ai_mcp_tool_host.dart';
import 'package:fushi/src/ai/mcp/ai_mcp_ui.dart';
import 'package:fushi/src/ops/op_catalog_assembly.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_routes.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:material_ui/material_ui.dart';

class _UnusedRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('构造操作目录时不应访问 ref');
}

/// 小目录：可撤销写（与真实 settings.set 同一撤销形态）、不可逆删文件（带表态
/// 参数）、装扩展（write + confirm，带表态参数）、所在模块可被关掉的写
/// （[moduleOn] 为 false 时不可用）。
OpInvoker _invoker(
  Map<String, Object?> store,
  List<String> deleted,
  List<String> installed,
  List<String> renamed,
  bool Function() moduleOn,
) {
  final List<CtlRoute> routes = <CtlRoute>[
    CtlRoute.get(
      '/api/admin/settings/:key',
      (CtlCall call) async => <String, Object?>{
        'value': store[call.params['key']],
      },
    ),
    CtlRoute.put('/api/admin/settings/:key', (CtlCall call) async {
      store[call.params['key']!] = call.body['value'];
      return <String, Object?>{'value': store[call.params['key']]};
    }),
    CtlRoute.post('/api/admin/files/:name/delete', (CtlCall call) async {
      if (call.optBool('confirm') != true) {
        throw const CtlFailure.badRequest('需 confirm');
      }
      deleted.add(call.params['name']!);
      return null;
    }),
    CtlRoute.post('/api/admin/online/extensions/install', (CtlCall call) async {
      if (call.optBool('trustSigner') != true) {
        throw const CtlFailure.badRequest('需 trustSigner');
      }
      installed.add(call.requireString('pkg'));
      return <String, Object?>{'installed': call.requireString('pkg')};
    }),
    CtlRoute.put('/api/admin/video/files/:name', (CtlCall call) async {
      renamed.add('${call.params['name']}->${call.body['title']}');
      return null;
    }),
  ];
  return OpInvoker(
    OpCatalog.build(routes, <OpDescription>[
      const OpDescription(
        id: 'settings.get',
        method: 'GET',
        pattern: '/api/admin/settings/:key',
        summary: 'Read a setting.',
        params: <OpParam>[
          OpParam.string('key', description: 'k', required: true, inPath: true),
        ],
      ),
      OpDescription(
        id: 'settings.set',
        method: 'PUT',
        pattern: '/api/admin/settings/:key',
        summary: 'Set a setting.',
        risk: OpRisk.write,
        params: const <OpParam>[
          OpParam.string('key', description: 'k', required: true, inPath: true),
          OpParam.string('value', description: 'v', required: true),
        ],
        undo: OpUndo(
          capture: (CtlCall call) async => <String, Object?>{
            'key': call.params['key'],
            'old': store[call.params['key']],
          },
          record: (CtlCall call, Map<String, Object?> before, Object? result) =>
              OpUndoRecord(
                payload: <String, Object?>{
                  ...before,
                  'new': call.body['value'],
                },
                before: '${before['old']}',
                after: '${call.body['value']}',
              ),
          revert: (Map<String, Object?> payload) async {
            final String key = payload['key']! as String;
            if (store[key] != payload['new']) {
              return const OpUndoOutcome.superseded();
            }
            store[key] = payload['old'];
            return const OpUndoOutcome.done();
          },
        ),
      ),
      const OpDescription(
        id: 'files.delete',
        method: 'POST',
        pattern: '/api/admin/files/:name/delete',
        summary: 'Delete a file from disk.',
        risk: OpRisk.irreversible,
        params: <OpParam>[
          OpParam.string(
            'name',
            description: 'n',
            required: true,
            inPath: true,
          ),
          OpParam.userGate('confirm', description: 'user confirmed'),
        ],
      ),
      OpDescription(
        id: 'online.extension.install',
        method: 'POST',
        pattern: '/api/admin/online/extensions/install',
        summary: 'Install an extension.',
        risk: OpRisk.write,
        confirm: true,
        params: const <OpParam>[
          OpParam.string('pkg', description: 'package', required: true),
          OpParam.userGate('trustSigner', description: 'user trusts signer'),
        ],
        undo: OpUndo(
          record: (CtlCall call, Map<String, Object?> before, Object? result) =>
              OpUndoRecord(payload: <String, Object?>{'pkg': call.body['pkg']}),
          revert: (Map<String, Object?> payload) async {
            installed.remove(payload['pkg']);
            return const OpUndoOutcome.done();
          },
        ),
      ),
      OpDescription(
        id: 'video.file.rename',
        method: 'PUT',
        pattern: '/api/admin/video/files/:name',
        summary: 'Rename a video file title.',
        risk: OpRisk.write,
        params: const <OpParam>[
          OpParam.string(
            'name',
            description: 'n',
            required: true,
            inPath: true,
          ),
          OpParam.string('title', description: 't', required: true),
        ],
        availability: () => moduleOn()
            ? const OpAvailability.available()
            : const OpAvailability.unavailable(
                'module_disabled',
                'The video module is turned off.',
              ),
      ),
    ]),
  );
}

const McpCallContext _ctx = McpCallContext(
  sessionId: 's1',
  client: McpClientInfo(name: 'Claude Desktop', version: '1.0'),
);

const McpCallContext _otherCtx = McpCallContext(
  sessionId: 's2',
  client: McpClientInfo(name: 'Cursor'),
);

const McpCallContext _anonCtx = McpCallContext(
  sessionId: kMcpAnonymousSessionId,
  client: McpClientInfo.unknown,
);

McpCallContext _cancellable(McpCancellationSource source) => McpCallContext(
  sessionId: 's1',
  client: const McpClientInfo(name: 'Claude Desktop', version: '1.0'),
  cancellation: source,
);

AiMcpConfirmRequest _confirmRequest(McpCancellation cancellation) =>
    AiMcpConfirmRequest(
      client: const McpClientInfo(name: 'Claude Desktop'),
      op: const FushiOpSpec(
        id: 'files.delete',
        summary: 'Delete a file from disk.',
        method: 'POST',
        pattern: '/api/admin/files/:name/delete',
        risk: OpRisk.irreversible,
      ),
      arguments: const <String, Object?>{'name': 'a.mkv'},
      cancellation: cancellation,
    );

Map<String, Object?> _structured(McpToolResult r) =>
    r.toJson()['structuredContent']! as Map<String, Object?>;

void main() {
  group('真实操作目录 → MCP 工具清单', () {
    final OpContext context = OpContext(ref: _UnusedRef());
    final OpCatalog catalog = buildAppOpCatalog(
      context,
      buildDomainOpRoutes(context),
    );
    final List<FushiOp> exposed = <FushiOp>[
      for (final FushiOp op in catalog.ops)
        if (mcpExposesOp(op.spec)) op,
    ];

    test('每条可对外的操作都生成一个工具：名字合法、唯一、可逆回目录 id', () {
      expect(exposed.length, greaterThan(200));
      final RegExp wire = RegExp(r'^[a-zA-Z0-9_-]{1,64}$');
      final Set<String> names = <String>{};
      for (final FushiOp op in exposed) {
        final McpTool tool = mcpToolOf(op.spec);
        expect(wire.hasMatch(tool.name), isTrue, reason: tool.name);
        // Claude 系客户端再加 `mcp__fushi__` 前缀，整体仍要在 64 以内。
        expect(
          'mcp__fushi__${tool.name}'.length,
          lessThanOrEqualTo(64),
          reason: tool.name,
        );
        expect(names.add(tool.name), isTrue, reason: '重名：${tool.name}');
        expect(mcpOpIdOf(tool.name), op.id);
        expect(tool.name, isNot(kAiMcpUndoTool));
        expect(tool.description, startsWith(op.summary.trim()));
      }
    });

    test('参数 schema 就是给模型的那份：表态参数一个都不出现', () {
      for (final FushiOp op in exposed) {
        final Map<String, Object?> props =
            mcpToolOf(op.spec).inputSchema['properties']!
                as Map<String, Object?>;
        for (final OpParam gate in op.spec.gateParams) {
          expect(props.containsKey(gate.name), isFalse, reason: op.id);
        }
        expect(props.keys.toSet(), <String>{
          for (final OpParam p in op.spec.modelParams) p.name,
        }, reason: op.id);
      }
    });

    test('风险级沿用描述：需要确认的工具在说明里写明，只读 / 不可逆标在 annotations', () {
      for (final FushiOp op in exposed) {
        final McpTool tool = mcpToolOf(op.spec);
        final Map<String, Object?> hints =
            tool.toJson()['annotations']! as Map<String, Object?>;
        expect(hints['readOnlyHint'], op.risk == OpRisk.read, reason: op.id);
        if (op.spec.needsConfirmation) {
          expect(
            tool.description,
            contains('must approve it in the Fushi app'),
            reason: op.id,
          );
        }
        if (op.risk == OpRisk.irreversible) {
          expect(hints['destructiveHint'], isTrue, reason: op.id);
        }
      }
    });

    test('进程内专有 / 结果含一次性凭据的操作不对外', () {
      for (final FushiOp op in catalog.ops) {
        if (op.inProcessOnly || op.sensitiveResult) {
          expect(mcpExposesOp(op.spec), isFalse, reason: op.id);
        }
      }
    });
  });

  group('AiMcpToolHost', () {
    late FushiDatabase db;
    late Map<String, Object?> store;
    late List<String> deleted;
    late List<String> installed;
    late List<String> renamed;
    late bool moduleOn;
    late List<AiMcpConfirmRequest> asked;
    late AiMcpConfirmOutcome answer;
    late Future<AiMcpConfirmOutcome> Function(AiMcpConfirmRequest)? answerWith;
    late bool ready;
    late AiMcpToolHost host;
    late AiAgentToolbox toolbox;

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      store = <String, Object?>{'subtitle.size': '20'};
      deleted = <String>[];
      installed = <String>[];
      renamed = <String>[];
      moduleOn = true;
      asked = <AiMcpConfirmRequest>[];
      answer = AiMcpConfirmOutcome.approved;
      answerWith = null;
      ready = true;
      toolbox = AiAgentToolbox(
        invoker: _invoker(store, deleted, installed, renamed, () => moduleOn),
        database: db,
        skills: const <AiAgentAppSkill>[],
        clock: () => DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      host = AiMcpToolHost(
        toolbox: () => toolbox,
        isReady: () => ready,
        confirm: (AiMcpConfirmRequest request) async {
          asked.add(request);
          return answerWith?.call(request) ?? answer;
        },
      );
    });

    tearDown(() async {
      toolbox.dispose();
      await db.close();
    });

    test('清单 = 目录工具 + undo_action', () {
      expect(host.listTools().map((McpTool t) => t.name).toList(), <String>[
        'files__delete',
        'online__extension__install',
        'settings__get',
        'settings__set',
        'video__file__rename',
        kAiMcpUndoTool,
      ]);
    });

    test('不可用的操作：清单里没有，按名字硬调也被拒，不执行、不记账', () async {
      moduleOn = false;
      expect(
        host.listTools().map((McpTool t) => t.name),
        isNot(contains('video__file__rename')),
      );
      final McpToolResult viaMcp = await host.callTool(
        'video__file__rename',
        <String, Object?>{'name': 'a.mkv', 'title': 'x'},
        _ctx,
      );
      expect(viaMcp.errorCode, 'rejected');
      expect(viaMcp.errorMessage, startsWith('module_disabled'));
      // 工具箱本身就按同一判据拒：app 内 AI 助手等其它入口也调不动。
      final AgentToolResult direct = await toolbox.execute(
        const AgentToolInvocation(
          sessionId: 'app-session',
          name: 'video.file.rename',
          arguments: <String, Object?>{'name': 'a.mkv', 'title': 'x'},
        ),
      );
      expect(direct.errorCode, 'rejected');
      expect(toolbox.describeTool('video.file.rename'), isNull);
      expect(renamed, isEmpty);
      expect(await db.listAiAgentActions(), isEmpty, reason: '没执行的不进操作记录');

      moduleOn = true;
      final McpToolResult ok = await host.callTool(
        'video__file__rename',
        <String, Object?>{'name': 'a.mkv', 'title': 'x'},
        _ctx,
      );
      expect(ok.isError, isFalse);
      expect(renamed, <String>['a.mkv->x']);
    });

    test('客户端取消：确认期间取消 → 不执行、不记账，结论是 cancelled', () async {
      final McpCancellationSource source = McpCancellationSource();
      final Completer<AiMcpConfirmOutcome> pending =
          Completer<AiMcpConfirmOutcome>();
      answerWith = (AiMcpConfirmRequest request) {
        // 确认框拿到的就是这次调用的取消信号。
        expect(request.cancellation, same(source));
        return pending.future;
      };
      final Future<McpToolResult> call = host.callTool(
        'files__delete',
        <String, Object?>{'name': 'a.mkv'},
        _cancellable(source),
      );
      await pumpEventQueue();
      expect(asked, hasLength(1));
      source.cancel('client timeout');
      pending.complete(AiMcpConfirmOutcome.cancelled);
      expect((await call).errorCode, 'cancelled');
      expect(deleted, isEmpty);
      expect(await db.listAiAgentActions(), isEmpty);
    });

    test('客户端取消与用户同意撞车：取消在先就不执行（重试不做两遍）', () async {
      final McpCancellationSource source = McpCancellationSource();
      answerWith = (AiMcpConfirmRequest request) async {
        source.cancel();
        return AiMcpConfirmOutcome.approved;
      };
      final McpToolResult result = await host.callTool(
        'files__delete',
        <String, Object?>{'name': 'a.mkv'},
        _cancellable(source),
      );
      expect(result.errorCode, 'cancelled');
      expect(deleted, isEmpty);
      expect(await db.listAiAgentActions(), isEmpty);
    });

    test('已取消的调用：不弹确认、可撤销写也不执行', () async {
      final McpCancellationSource source = McpCancellationSource()..cancel();
      final McpToolResult a = await host.callTool(
        'files__delete',
        <String, Object?>{'name': 'a.mkv'},
        _cancellable(source),
      );
      final McpToolResult b = await host.callTool(
        'settings__set',
        <String, Object?>{'key': 'subtitle.size', 'value': '28'},
        _cancellable(source),
      );
      expect((a.errorCode, b.errorCode), ('cancelled', 'cancelled'));
      expect(asked, isEmpty);
      expect(deleted, isEmpty);
      expect(store['subtitle.size'], '20');
      expect(await db.listAiAgentActions(), isEmpty);
    });

    test('可撤销写：直接执行、不弹确认、进操作记录（mcp: 会话）、undo_action 撤回', () async {
      final McpToolResult result = await host.callTool(
        'settings__set',
        <String, Object?>{'key': 'subtitle.size', 'value': '28'},
        _ctx,
      );
      expect(result.isError, isFalse);
      expect(store['subtitle.size'], '28');
      expect(asked, isEmpty);
      final Map<String, Object?> data = _structured(result);
      expect(data['undoable'], isTrue);
      expect((data['before'], data['after']), ('20', '28'));

      final AiAgentActionRow row = (await db.listAiAgentActions()).single;
      expect(row.sessionId, '${kAiMcpSessionPrefix}s1');
      expect(row.opId, 'settings.set');
      expect(row.confirmation, 'auto');
      expect('${row.id}', data['actionId']);

      final McpToolResult undo = await host.callTool(
        kAiMcpUndoTool,
        <String, Object?>{'actionId': data['actionId']},
        _ctx,
      );
      expect(_structured(undo)['status'], 'done');
      expect(store['subtitle.size'], '20');
      expect((await db.getAiAgentAction(row.id))!.undoneAt, isNotNull);
    });

    test('外部写操作在「AI 操作记录」页的撤销路径（toolbox.undo）同样能撤', () async {
      final McpToolResult result = await host.callTool(
        'settings__set',
        <String, Object?>{'key': 'subtitle.size', 'value': '30'},
        _ctx,
      );
      final String actionId = _structured(result)['actionId']! as String;
      // 历史页按行调 AiAgentController.toolbox.undo：同一个目录、同一份撤销载荷。
      final AiAgentToolbox pageToolbox = AiAgentToolbox(
        invoker: toolbox.invoker,
        database: db,
        skills: const <AiAgentAppSkill>[],
      );
      expect((await pageToolbox.undo(actionId)).status, AgentUndoStatus.done);
      expect(store['subtitle.size'], '20');
    });

    test('之后被手动改过：撤销报 superseded，不覆盖用户的修改', () async {
      final McpToolResult result = await host.callTool(
        'settings__set',
        <String, Object?>{'key': 'subtitle.size', 'value': '28'},
        _ctx,
      );
      store['subtitle.size'] = '40';
      final McpToolResult undo = await host.callTool(
        kAiMcpUndoTool,
        <String, Object?>{'actionId': _structured(result)['actionId']},
        _ctx,
      );
      expect(_structured(undo)['status'], 'superseded');
      expect(store['subtitle.size'], '40');
    });

    test('不可逆：先在 app 内确认；拒绝 → 不执行、不记账', () async {
      answer = AiMcpConfirmOutcome.declined;
      final McpToolResult result = await host.callTool(
        'files__delete',
        <String, Object?>{'name': 'a.mkv'},
        _ctx,
      );
      expect(result.isError, isTrue);
      expect(result.errorCode, 'user_declined');
      expect(deleted, isEmpty);
      expect(asked.single.op.id, 'files.delete');
      expect(asked.single.client.label, 'Claude Desktop 1.0');
      expect(asked.single.arguments, <String, Object?>{'name': 'a.mkv'});
      expect(await db.listAiAgentActions(), isEmpty);
    });

    test('不可逆：用户同意 → 运行时注入表态参数执行，记为用户确认、不可撤销', () async {
      final McpToolResult result = await host.callTool(
        'files__delete',
        <String, Object?>{'name': 'a.mkv'},
        _ctx,
      );
      expect(result.isError, isFalse);
      expect(deleted, <String>['a.mkv']);
      final AiAgentActionRow row = (await db.listAiAgentActions()).single;
      expect(row.confirmation, 'user');
      expect(row.undoPayloadJson, isNull);
      expect(_structured(result)['undoable'], isFalse);
    });

    test('超时 / 界面不可用都按拒绝处理', () async {
      for (final (AiMcpConfirmOutcome outcome, String code)
          in <(AiMcpConfirmOutcome, String)>[
            (AiMcpConfirmOutcome.expired, 'confirmation_expired'),
            (AiMcpConfirmOutcome.unavailable, 'confirmation_unavailable'),
          ]) {
        answer = outcome;
        final McpToolResult result = await host.callTool(
          'files__delete',
          <String, Object?>{'name': 'b.mkv'},
          _ctx,
        );
        expect(result.errorCode, code);
      }
      expect(deleted, isEmpty);
    });

    test('装扩展（write + confirm）：同样先确认；同意后执行且可撤销', () async {
      final McpToolResult result = await host.callTool(
        'online__extension__install',
        <String, Object?>{'pkg': 'eu.kanade.x'},
        _ctx,
      );
      expect(asked.single.op.id, 'online.extension.install');
      expect(installed, <String>['eu.kanade.x']);
      final String actionId = _structured(result)['actionId']! as String;
      await host.callTool(kAiMcpUndoTool, <String, Object?>{
        'actionId': actionId,
      }, _ctx);
      expect(installed, isEmpty);
    });

    test('外部调用方自己填表态参数：400，不弹确认、不执行', () async {
      final McpToolResult a = await host.callTool(
        'files__delete',
        <String, Object?>{'name': 'a.mkv', 'confirm': true},
        _ctx,
      );
      final McpToolResult b = await host.callTool(
        'online__extension__install',
        <String, Object?>{'pkg': 'x', 'trustSigner': true},
        _ctx,
      );
      expect(a.errorCode, 'bad_request');
      expect(b.errorCode, 'bad_request');
      expect(asked, isEmpty);
      expect(deleted, isEmpty);
      expect(installed, isEmpty);
    });

    test('参数不合法的需确认操作不打扰用户', () async {
      final McpToolResult result = await host.callTool(
        'online__extension__install',
        const <String, Object?>{},
        _ctx,
      );
      expect(result.errorCode, 'bad_request');
      expect(asked, isEmpty);
    });

    test('undo_action 只撤外部 AI 自己的记录', () async {
      final int inApp = await db.insertAiAgentAction(
        AiAgentActionsCompanion.insert(
          sessionId: 'app-session',
          opId: 'settings.set',
          argsJson: jsonEncode(<String, Object?>{}),
          risk: 'write',
          confirmation: 'auto',
          resultCode: 'ok',
          createdAt: 1,
        ),
      );
      final McpToolResult result = await host.callTool(
        kAiMcpUndoTool,
        <String, Object?>{'actionId': '$inApp'},
        _ctx,
      );
      expect(result.errorCode, 'not_found');
    });

    test('undo_action 只撤这条连接（同一 MCP 会话）自己的记录', () async {
      final McpToolResult mine = await host.callTool(
        'settings__set',
        <String, Object?>{'key': 'subtitle.size', 'value': '28'},
        _ctx,
      );
      final String actionId = _structured(mine)['actionId']! as String;
      for (final McpCallContext other in <McpCallContext>[
        _otherCtx,
        _anonCtx,
      ]) {
        final McpToolResult denied = await host.callTool(
          kAiMcpUndoTool,
          <String, Object?>{'actionId': actionId},
          other,
        );
        expect(denied.errorCode, 'not_found', reason: other.sessionId);
      }
      expect(store['subtitle.size'], '28');
      final McpToolResult undo = await host.callTool(
        kAiMcpUndoTool,
        <String, Object?>{'actionId': actionId},
        _ctx,
      );
      expect(_structured(undo)['status'], 'done');
      expect(store['subtitle.size'], '20');
    });

    test('匿名调用（无会话 / 会话失效）共用 mcp:anonymous：只能撤匿名名下的', () async {
      final McpToolResult anon = await host.callTool(
        'settings__set',
        <String, Object?>{'key': 'subtitle.size', 'value': '30'},
        _anonCtx,
      );
      final AiAgentActionRow row = (await db.listAiAgentActions()).single;
      expect(row.sessionId, '${kAiMcpSessionPrefix}anonymous');
      final String actionId = _structured(anon)['actionId']! as String;
      final McpToolResult denied = await host.callTool(
        kAiMcpUndoTool,
        <String, Object?>{'actionId': actionId},
        _ctx,
      );
      expect(denied.errorCode, 'not_found', reason: '有会话的连接撤不了匿名的');
      final McpToolResult undo = await host.callTool(
        kAiMcpUndoTool,
        <String, Object?>{'actionId': actionId},
        _anonCtx,
      );
      expect(_structured(undo)['status'], 'done');
      expect(store['subtitle.size'], '20');
    });

    test('不认识的工具 / 未初始化', () async {
      await expectLater(
        host.callTool('nope__x', const <String, Object?>{}, _ctx),
        throwsA(isA<McpUnknownTool>()),
      );
      ready = false;
      expect(host.listTools, throwsStateError);
    });
  });

  group('确认排队与取消', () {
    test('排队中被取消：立即以 cancelled 结束，轮到时不弹', () async {
      final Completer<AiMcpConfirmOutcome> first =
          Completer<AiMcpConfirmOutcome>();
      int shown = 0;
      final Future<AiMcpConfirmOutcome> a = enqueueAiMcpConfirmation(
        _confirmRequest(const McpCancellation.never()),
        () {
          shown++;
          return first.future;
        },
      );
      final McpCancellationSource source = McpCancellationSource();
      final Future<AiMcpConfirmOutcome> b = enqueueAiMcpConfirmation(
        _confirmRequest(source),
        () async {
          shown++;
          return AiMcpConfirmOutcome.approved;
        },
      );
      await pumpEventQueue();
      expect(shown, 1);
      source.cancel();
      expect(await b, AiMcpConfirmOutcome.cancelled);
      first.complete(AiMcpConfirmOutcome.declined);
      expect(await a, AiMcpConfirmOutcome.declined);
      await pumpEventQueue();
      expect(shown, 1, reason: '已取消的确认轮到时不再弹');
    });

    testWidgets('已弹出的确认框：客户端取消就关掉，结论 cancelled', (WidgetTester tester) async {
      late BuildContext host;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) {
                host = context;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );
      final McpCancellationSource source = McpCancellationSource();
      const Duration timeout = Duration(seconds: 30);
      AiMcpConfirmOutcome? outcome;
      unawaited(
        showAiMcpConfirmDialog(
          host,
          _confirmRequest(source),
          timeout: timeout,
        ).then((AiMcpConfirmOutcome o) => outcome = o),
      );
      await tester.pumpAndSettle();
      expect(find.text('Delete a file from disk.'), findsOneWidget);

      source.cancel();
      await tester.pumpAndSettle();
      expect(find.text('Delete a file from disk.'), findsNothing);
      expect(outcome, AiMcpConfirmOutcome.cancelled);
      // 走完兜底计时器，别留悬挂的 Timer。
      await tester.pump(timeout + const Duration(seconds: 2));
    });

    testWidgets('被别的路由盖住的确认框：取消时也从栈里摘掉', (WidgetTester tester) async {
      final GlobalKey<NavigatorState> nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          home: const Scaffold(body: SizedBox.expand()),
        ),
      );
      final McpCancellationSource source = McpCancellationSource();
      const Duration timeout = Duration(seconds: 30);
      AiMcpConfirmOutcome? outcome;
      unawaited(
        showAiMcpConfirmDialog(
          nav.currentContext!,
          _confirmRequest(source),
          timeout: timeout,
        ).then((AiMcpConfirmOutcome o) => outcome = o),
      );
      await tester.pumpAndSettle();
      unawaited(
        nav.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('covering page')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      source.cancel();
      await tester.pumpAndSettle();
      expect(outcome, AiMcpConfirmOutcome.cancelled);
      nav.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('Delete a file from disk.'), findsNothing);
      await tester.pump(timeout + const Duration(seconds: 2));
    });
  });

  group('鉴权', () {
    final String hash = hashAiMcpToken('tok');

    test('默认关 / 没令牌 / 令牌不对 / 对', () {
      expect(
        evaluateAiMcpAccess(
          enabled: false,
          storedSha256: hash,
          presentedToken: 'tok',
        ),
        McpAccess.disabled,
      );
      expect(
        evaluateAiMcpAccess(
          enabled: true,
          storedSha256: '',
          presentedToken: 'tok',
        ),
        McpAccess.notPaired,
      );
      for (final String? bad in <String?>[null, '', 'tok2', hash]) {
        expect(
          evaluateAiMcpAccess(
            enabled: true,
            storedSha256: hash,
            presentedToken: bad,
          ),
          McpAccess.unauthorized,
          reason: '$bad',
        );
      }
      expect(
        evaluateAiMcpAccess(
          enabled: true,
          storedSha256: hash,
          presentedToken: 'tok',
        ),
        McpAccess.allowed,
      );
    });

    test('客户端配置片段带 fushi_cli mcp 与令牌环境变量', () {
      final Map<String, Object?> config =
          jsonDecode(
                aiMcpClientConfig(token: 'tok', command: 'C:/x/fushi_cli.exe'),
              )
              as Map<String, Object?>;
      expect(config, <String, Object?>{
        'mcpServers': <String, Object?>{
          'fushi': <String, Object?>{
            'command': 'C:/x/fushi_cli.exe',
            'args': <String>['mcp'],
            'env': <String, Object?>{kMcpTokenEnv: 'tok'},
          },
        },
      });
    });
  });
}
