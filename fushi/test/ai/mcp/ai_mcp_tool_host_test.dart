import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/agent/ai_agent_skills.dart';
import 'package:fushi/src/ai/agent/ai_agent_toolbox.dart';
import 'package:fushi/src/ai/mcp/ai_mcp_access.dart';
import 'package:fushi/src/ai/mcp/ai_mcp_tool_host.dart';
import 'package:fushi/src/ops/op_catalog_assembly.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_routes.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';

class _UnusedRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('构造操作目录时不应访问 ref');
}

/// 小目录：可撤销写（与真实 settings.set 同一撤销形态）、不可逆删文件（带表态
/// 参数）、装扩展（write + confirm，带表态参数）。
OpInvoker _invoker(
  Map<String, Object?> store,
  List<String> deleted,
  List<String> installed,
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
    ]),
  );
}

const McpCallContext _ctx = McpCallContext(
  sessionId: 's1',
  client: McpClientInfo(name: 'Claude Desktop', version: '1.0'),
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
    late List<AiMcpConfirmRequest> asked;
    late AiMcpConfirmOutcome answer;
    late bool ready;
    late AiMcpToolHost host;
    late AiAgentToolbox toolbox;

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      store = <String, Object?>{'subtitle.size': '20'};
      deleted = <String>[];
      installed = <String>[];
      asked = <AiMcpConfirmRequest>[];
      answer = AiMcpConfirmOutcome.approved;
      ready = true;
      toolbox = AiAgentToolbox(
        invoker: _invoker(store, deleted, installed),
        database: db,
        skills: const <AiAgentAppSkill>[],
        clock: () => DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
      host = AiMcpToolHost(
        toolbox: () => toolbox,
        isReady: () => ready,
        confirm: (AiMcpConfirmRequest request) async {
          asked.add(request);
          return answer;
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
        kAiMcpUndoTool,
      ]);
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

    test('不认识的工具 / 未初始化', () async {
      await expectLater(
        host.callTool('nope__x', const <String, Object?>{}, _ctx),
        throwsA(isA<McpUnknownTool>()),
      );
      ready = false;
      expect(host.listTools, throwsStateError);
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
