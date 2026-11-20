import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/agent/ai_agent_skills.dart';
import 'package:fushi/src/ai/agent/ai_agent_toolbox.dart';
import 'package:fushi/src/ops/op_catalog_assembly.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_routes.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/ai/agent/agent_session.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_rate_limiter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// AI 助手一场典型会话的请求体度量（docs/agent/ai-token-budget.md）。
///
/// 用**真实操作目录**（全部描述 + 常驻清单 + 技能）、真实 [AgentSession] 与真实
/// [AiChatClient] 拼请求体，假 HTTP 端点按脚本回工具调用，记下每一轮发出去的
/// 请求体——不联网、不花钱。工具结果是按各路由 `toJson` 形状造的样本数据。
///
/// 打印每轮的构成（`TOKEN|` 前缀行）供度量文档引用；断言是防回归门：
/// - 相邻两轮请求按提供商渲染顺序（tools → system → messages）的公共前缀，在工具表
///   没变的轮次必须覆盖到上一轮的全部内容（只追加，不改写）；
/// - describe 之后新工具接在工具表末尾，不插在中间；
/// - 常驻清单里的 id 全在目录里。
class _UnusedRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('构造操作目录时不应访问 ref');
}

/// 真实目录上的工具箱：不看可用性（可用性要读 ref），执行回样本数据。
class _CatalogToolbox implements AgentToolbox, AgentSkillProvider {
  _CatalogToolbox(this.catalog, this.results);

  final OpCatalog catalog;
  final Map<String, Object? Function(Map<String, Object?>)> results;
  final List<AiAgentAppSkill> _skills = buildAiAgentSkills();

  @override
  List<AgentToolSpec> residentTools() => <AgentToolSpec>[
    for (final String id in kAiAgentResidentOps)
      if (catalog[id] case final FushiOp op) agentToolSpecOf(op),
  ];

  @override
  List<AgentSkill> skills() => <AgentSkill>[
    for (final AiAgentAppSkill s in _skills)
      if (s.requiredOps.every((String id) => catalog[id] != null)) s,
  ];

  @override
  List<AgentToolSpec> searchTools(String query, {int limit = 12}) {
    final List<String> terms = query.toLowerCase().split(RegExp(r'\s+'));
    final List<(FushiOp, int)> scored = <(FushiOp, int)>[
      for (final FushiOp op in catalog.ops)
        (
          op,
          terms
              .where(
                (String t) =>
                    op.id.contains(t) || op.summary.toLowerCase().contains(t),
              )
              .length,
        ),
    ]..sort(((FushiOp, int) a, (FushiOp, int) b) => b.$2.compareTo(a.$2));
    return <AgentToolSpec>[
      for (final (FushiOp, int) s in scored.take(limit)) agentToolSpecOf(s.$1),
    ];
  }

  @override
  AgentToolSpec? describeTool(String name) {
    final FushiOp? op = catalog[name];
    return op == null ? null : agentToolSpecOf(op);
  }

  @override
  Future<AgentToolResult> execute(AgentToolInvocation invocation) async {
    final Object? Function(Map<String, Object?>)? make =
        results[invocation.name];
    if (make == null) return const AgentToolResult.error('not_found');
    final FushiOp op = catalog[invocation.name]!;
    return AgentToolResult.ok(
      redactAiAgentResult(make(invocation.arguments)),
      actionId: op.spec.risk == OpRisk.read ? null : '1',
    );
  }

  @override
  Future<AgentUndoResult> undo(String actionId) async =>
      const AgentUndoResult(AgentUndoStatus.notUndoable);
}

class _Host implements AgentHost {
  @override
  Future<bool> confirm(AgentConfirmRequest request) async => true;

  @override
  Future<String?> askChoice(
    String prompt,
    List<AgentChoiceOption> options,
  ) async => options.first.id;
}

/// 样本数据：形状照各路由的 `toJson`（`ctl_library_entries.dart` 等）。
Map<String, Object? Function(Map<String, Object?>)> _sampleResults() =>
    <String, Object? Function(Map<String, Object?>)>{
      'library.collection.list': (_) => <String, Object?>{
        'collections': <Object?>[
          for (int i = 0; i < 40; i++)
            <String, Object?>{
              'id': 100 + i,
              'name': '合集 $i ぼっち・ざ・ろっく！',
              'type': i.isEven ? 'manual' : 'folder',
              'members': 3 + i % 9,
              'manualOrder': i % 5 == 0,
            },
        ],
      },
      'library.item.list': (_) => <String, Object?>{
        'items': <Object?>[
          for (int i = 0; i < 100; i++)
            <String, Object?>{
              'key': 'video:local:${1000 + i}',
              'kind': 'video',
              'title': '[SubsPlease] Sousou no Frieren - ${i + 1} (1080p)',
              'percent': (i * 7) % 100 / 100,
              'positionMs': i * 61000,
              'completed': i % 3 == 0,
              'progress': '${(i * 7) % 100}%',
              'importedAt': 1763000000000 + i * 1000,
            },
        ],
      },
      'video.work.list': (_) => <String, Object?>{
        'works': <Object?>[
          for (int i = 0; i < 30; i++)
            <String, Object?>{
              'id': 'w$i',
              'title': '葬送のフリーレン 第${i + 1}期',
              'identity': 'anidb:${17000 + i}',
              'files': 12,
            },
        ],
      },
      'library.collection.create': (Map<String, Object?> a) =>
          <String, Object?>{'id': 900, 'name': a['name']},
      'library.collection.add': (Map<String, Object?> a) => <String, Object?>{
        'added': (a['keys'] as List<Object?>?)?.length ?? 0,
      },
    };

/// 典型会话的模型脚本（OpenAI 兼容应答）。模型只 describe 不在常驻清单里的工具
/// （常驻工具每轮都在工具表里，不用 describe）；一轮要 describe 的全是常驻工具时
/// 这一轮不存在。
List<Map<String, Object?>> _script(Set<String> resident) {
  Map<String, Object?> calls(List<(String, Map<String, Object?>)> list) =>
      <String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'finish_reason': 'tool_calls',
            'message': <String, Object?>{
              'role': 'assistant',
              'content': null,
              'tool_calls': <Object?>[
                for (final (String name, Map<String, Object?> args) in list)
                  <String, Object?>{
                    'id': 'call_${name}_${args.hashCode}',
                    'type': 'function',
                    'function': <String, Object?>{
                      'name': name,
                      'arguments': jsonEncode(args),
                    },
                  },
              ],
            },
          },
        ],
        'usage': <String, Object?>{'prompt_tokens': 1, 'completion_tokens': 1},
      };
  final List<String> keys = <String>[
    for (int i = 0; i < 12; i++) 'video:local:${1000 + i}',
  ];
  Map<String, Object?>? describe(List<String> ids) {
    final List<String> needed = <String>[
      for (final String id in ids)
        if (!resident.contains(id)) id,
    ];
    if (needed.isEmpty) return null;
    return calls(<(String, Map<String, Object?>)>[
      for (final String id in needed)
        ('ops__describe', <String, Object?>{'id': id}),
    ]);
  }

  return <Map<String, Object?>>[
    calls(<(String, Map<String, Object?>)>[
      ('ops__search', <String, Object?>{'query': 'organize video collection'}),
    ]),
    ?describe(<String>[
      'library.collection.list',
      'library.item.list',
      'video.work.list',
    ]),
    calls(<(String, Map<String, Object?>)>[
      ('library__collection__list', <String, Object?>{}),
      ('library__item__list', <String, Object?>{'kind': 'video', 'limit': 100}),
    ]),
    calls(<(String, Map<String, Object?>)>[
      ('video__work__list', <String, Object?>{}),
    ]),
    ?describe(<String>['library.collection.create', 'library.collection.add']),
    calls(<(String, Map<String, Object?>)>[
      ('library__collection__create', <String, Object?>{'name': '葬送のフリーレン'}),
    ]),
    calls(<(String, Map<String, Object?>)>[
      ('library__collection__add', <String, Object?>{'id': 900, 'keys': keys}),
    ]),
    <String, Object?>{
      'choices': <Object?>[
        <String, Object?>{
          'finish_reason': 'stop',
          'message': <String, Object?>{
            'role': 'assistant',
            'content': '已新建合集「葬送のフリーレン」并放入 12 集。',
          },
        },
      ],
    },
  ];
}

/// 一份请求体按提供商缓存的渲染顺序拆成段：tools、system、每条消息。
List<String> _segments(Map<String, Object?> body) {
  final List<Object?> messages = body['messages']! as List<Object?>;
  return <String>[
    jsonEncode(body['tools'] ?? const <Object?>[]),
    for (final Object? m in messages) jsonEncode(m),
  ];
}

int _commonPrefix(String a, String b) {
  final int n = a.length < b.length ? a.length : b.length;
  int i = 0;
  while (i < n && a.codeUnitAt(i) == b.codeUnitAt(i)) {
    i++;
  }
  return i;
}

void main() {
  final OpContext context = OpContext(ref: _UnusedRef());
  final OpCatalog catalog = buildAppOpCatalog(
    context,
    buildDomainOpRoutes(context),
  );

  Future<List<Map<String, Object?>>> runSession() async {
    final List<Map<String, Object?>> script = _script(<String>{
      for (final String id in kAiAgentResidentOps)
        if (catalog[id] != null) id,
    });
    final List<Map<String, Object?>> sent = <Map<String, Object?>>[];
    final AiChatClient client = AiChatClient(
      rateLimiter: AiRateLimiter(),
      client: MockClient((http.Request request) async {
        sent.add((jsonDecode(request.body) as Map).cast<String, Object?>());
        return http.Response(
          jsonEncode(script[sent.length - 1]),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(client.close);
    final AgentSession session = AgentSession(
      id: 's',
      llm: AiClientAgentLlm(
        client: client,
        provider: AiProviderConfig(
          id: 'p',
          presetId: kAiCustomPresetId,
          name: 'p',
          baseUrl: Uri.parse('https://example.com/v1'),
          apiKey: 'k',
          model: 'm',
          toolCallingOverride: AiToolCallingOverride.forceOn,
        ),
      ),
      toolbox: _CatalogToolbox(catalog, _sampleResults()),
      host: _Host(),
      clock: () => DateTime.fromMillisecondsSinceEpoch(0),
    );
    await session.send(
      '帮我整理一下视频库，把同一部番的放进一个合集',
      context: const AgentUiContext(scene: 'video', page: 'video_library'),
    );
    expect(sent, hasLength(script.length));
    return sent;
  }

  test('典型会话每轮请求构成（打印 TOKEN| 行）+ 前缀只追加', () async {
    final List<Map<String, Object?>> sent = await runSession();
    final Set<String> meta = <String>{
      'ops__search',
      'ops__describe',
      'ui__ask_choice',
    };
    final Set<String> resident = <String>{
      for (final String id in kAiAgentResidentOps)
        if (catalog[id] != null) agentWireToolName(id),
    };
    // ignore: avoid_print
    print(
      'TOKEN|resident present: ${resident.length}/${kAiAgentResidentOps.length} '
      'missing=${kAiAgentResidentOps.where((String id) => catalog[id] == null).toList()}',
    );
    int total = 0;
    int fixedTotal = 0;
    int prefixTotal = 0;
    for (int r = 0; r < sent.length; r++) {
      final Map<String, Object?> body = sent[r];
      final List<Object?> tools = body['tools']! as List<Object?>;
      final List<Object?> messages = body['messages']! as List<Object?>;
      int metaC = 0, residentC = 0, skillC = 0, loadedC = 0;
      for (final Object? t in tools) {
        final String name =
            ((t! as Map<String, Object?>)['function']!
                    as Map<String, Object?>)['name']!
                as String;
        final int c = jsonEncode(t).length;
        if (meta.contains(name)) {
          metaC += c;
        } else if (resident.contains(name)) {
          residentC += c;
        } else if (name.startsWith('skill__')) {
          skillC += c;
        } else {
          loadedC += c;
        }
      }
      final int systemC = jsonEncode(messages.first).length;
      int userC = 0, callC = 0;
      final Map<String, int> results = <String, int>{};
      for (final Object? m in messages.skip(1)) {
        final Map<String, Object?> msg = m! as Map<String, Object?>;
        final int c = jsonEncode(msg).length;
        switch (msg['role']) {
          case 'tool':
            final String content = msg['content']! as String;
            final RegExpMatch? src = RegExp(
              r'source="([^"]+)"',
            ).firstMatch(content);
            final String k = src?.group(1) ?? '?';
            results[k] = (results[k] ?? 0) + c;
          case 'assistant':
            callC += c;
          default:
            userC += c;
        }
      }
      final int bodyC = utf8.encode(jsonEncode(body)).length;
      final int prefix = r == 0
          ? 0
          : _commonPrefix(
              _segments(sent[r - 1]).join(),
              _segments(body).join(),
            );
      total += bodyC;
      fixedTotal += metaC + residentC + skillC + systemC;
      prefixTotal += prefix;
      // ignore: avoid_print
      print(
        'TOKEN|round ${r + 1}: body=$bodyC B; system=$systemC tools(meta=$metaC '
        'resident=$residentC skills=$skillC loaded=$loadedC) user=$userC '
        'assistantCalls=$callC results=$results; prefixWithPrev=$prefix',
      );
    }
    // ignore: avoid_print
    print(
      'TOKEN|session: rounds=${sent.length} totalBody=$total B '
      'fixed(system+meta+resident+skills)=$fixedTotal '
      'sharedPrefix=$prefixTotal',
    );

    // 防回归：工具表没变的相邻两轮，后一轮的渲染序列以前一轮全部内容开头。
    for (int r = 1; r < sent.length; r++) {
      final List<String> a = _segments(sent[r - 1]);
      final List<String> b = _segments(sent[r]);
      if (a.first != b.first) {
        // 工具表变了（describe 拉进新工具）：旧工具表必须是新工具表的前缀
        // （只追加在末尾），已有工具的 JSON 逐字不变。
        final List<Object?> oldTools = jsonDecode(a.first) as List<Object?>;
        final List<Object?> newTools = jsonDecode(b.first) as List<Object?>;
        expect(
          jsonEncode(newTools.take(oldTools.length).toList()),
          a.first,
          reason: 'round ${r + 1}: describe 的新工具必须接在工具表末尾',
        );
        continue;
      }
      expect(
        b.join().startsWith(a.join()),
        isTrue,
        reason: 'round ${r + 1}: 工具表未变时请求必须只在末尾追加',
      );
    }
  });

  test('常驻清单里的 id 全在操作目录里（写错的 id 会被静默跳过）', () {
    expect(
      <String>[
        for (final String id in kAiAgentResidentOps)
          if (catalog[id] == null) id,
      ],
      isEmpty,
      reason:
          '常驻工具不存在时模型每场都得先 ops__search 再 ops__describe，多一轮请求，'
          'describe 还会改工具表、让前缀缓存整段失效',
    );
  });
}
