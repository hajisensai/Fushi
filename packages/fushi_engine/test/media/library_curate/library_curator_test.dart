// AI 库管家编排器（spec docs/specs/2026-11-18-ai-library-curator-design.md §3 / §5.4 /
// §9）：阶段顺序、取消、单阶段失败不拖垮整趟、自动路径请求上限、没指派 AI 不发请求、
// 增量水位、需确认的操作不执行、整趟撤销往返（撤销后回到原状，再跑一趟不重做）。
//
// 工具箱是假的（每个写操作照真工具箱的形状记进内存库的 ai_agent_actions，撤销按记录
// 回放），库内容是一个内存模型——这里只验编排器自己负责的逻辑；各操作的落库与撤销
// 由它们各自的路由测试覆盖。
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:fushi_engine/media/library_curate/library_curator.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_ai_identity.dart';
import 'package:test/test.dart';

typedef _Handler = Future<Object?> Function(Map<String, Object?> args);
typedef _Payload =
    Map<String, Object?> Function(Map<String, Object?> args, Object? result);
typedef _Undo = Future<void> Function(Map<String, Object?> payload);

class _Op {
  _Op(this.spec, this.handler, this.payload, this.undo);

  final AgentToolSpec spec;
  final _Handler handler;
  final _Payload? payload;
  final _Undo? undo;
}

/// 照 `AiAgentToolbox` 的记账形状：写操作进 ai_agent_actions（会话 id 原样），读操作不记。
class _FakeToolbox implements AgentToolbox {
  _FakeToolbox(this.db);

  final FushiDatabase db;
  final Map<String, _Op> ops = <String, _Op>{};
  final List<String> calls = <String>[];
  final List<String> sessions = <String>[];
  final List<Map<String, Object?>> args = <Map<String, Object?>>[];

  void op(
    String name,
    _Handler handler, {
    AgentToolRisk risk = AgentToolRisk.write,
    _Payload? payload,
    _Undo? undo,
  }) => ops[name] = _Op(
    AgentToolSpec(
      name: name,
      description: name,
      parameters: const <String, Object?>{},
      risk: risk,
      undoable: undo != null,
    ),
    handler,
    payload,
    undo,
  );

  @override
  AgentToolSpec? describeTool(String name) => ops[name]?.spec;

  @override
  List<AgentToolSpec> residentTools() => const <AgentToolSpec>[];

  @override
  List<AgentToolSpec> searchTools(String query, {int limit = 12}) =>
      const <AgentToolSpec>[];

  @override
  Future<AgentToolResult> execute(AgentToolInvocation invocation) async {
    final _Op? op = ops[invocation.name];
    if (op == null) return const AgentToolResult.error('unknown_tool');
    calls.add(invocation.name);
    sessions.add(invocation.sessionId);
    args.add(invocation.arguments);
    final Object? data;
    try {
      data = await op.handler(invocation.arguments);
    } on _Fail catch (f) {
      return AgentToolResult.error(f.code);
    }
    if (op.spec.risk == AgentToolRisk.read) return AgentToolResult.ok(data);
    final int id = await db.insertAiAgentAction(
      AiAgentActionsCompanion.insert(
        sessionId: invocation.sessionId,
        opId: invocation.name,
        argsJson: jsonEncode(invocation.arguments),
        risk: op.spec.risk.name,
        confirmation: 'auto',
        resultCode: 'ok',
        undoPayloadJson: Value<String?>(
          op.payload == null
              ? null
              : jsonEncode(op.payload!(invocation.arguments, data)),
        ),
        createdAt: calls.length,
      ),
    );
    return AgentToolResult.ok(data, actionId: '$id');
  }

  @override
  Future<AgentUndoResult> undo(String actionId) async {
    final AiAgentActionRow? row = await db.getAiAgentAction(
      int.parse(actionId),
    );
    if (row == null || row.undoPayloadJson == null) {
      return const AgentUndoResult(AgentUndoStatus.notUndoable);
    }
    await ops[row.opId]!.undo!(
      Map<String, Object?>.from(jsonDecode(row.undoPayloadJson!) as Map),
    );
    await db.markAiAgentActionUndone(row.id, undoneAt: 1, status: 'done');
    return const AgentUndoResult(AgentUndoStatus.done);
  }
}

class _Fail implements Exception {
  const _Fail(this.code);

  final String code;
}

class _FakeFacts implements LibraryCurateFacts {
  final List<int?> organizeSince = <int?>[];
  final List<int?> linksSince = <int?>[];
  Set<String> freshEntries = <String>{'book:1'};
  List<String> endpoints = <String>['book:a', 'book:b', 'game:g'];
  int chunks = 1;

  @override
  Future<Set<String>?> organizeEntriesSince(
    CollectionShelfDomain domain,
    int? sinceMs,
  ) async {
    organizeSince.add(sinceMs);
    return sinceMs == null ? null : freshEntries;
  }

  @override
  Future<int> organizeRequestEstimate(
    CollectionShelfDomain domain,
    Set<String>? only,
  ) async => chunks;

  @override
  Future<List<String>> linkEndpointsSince(int? sinceMs) async {
    linksSince.add(sinceMs);
    return endpoints;
  }

  @override
  Future<bool> musicChangedSince(int? sinceMs) async => true;
}

/// 内存里的「库」：合集成员、连接、作品身份。
class _Library {
  final Set<String> members = <String>{};
  final Set<String> links = <String>{};
  final Map<String, String> identity = <String, String>{};

  String snapshot() => jsonEncode(<String, Object?>{
    'members': members.toList()..sort(),
    'links': links.toList()..sort(),
    'identity': identity,
  });
}

void main() {
  late FushiDatabase db;
  late _FakeToolbox toolbox;
  late _FakeFacts facts;
  late _Library library;
  late MemoryLibraryCurateStore store;
  late LibraryCurateAiAvailability ai;
  late int now;
  late List<AiVideoIdentityQuery> asked;

  LibraryCurator curator({
    LibraryCurateLimits limits = const LibraryCurateLimits(),
  }) => LibraryCurator(
    db: db,
    toolbox: toolbox,
    store: store,
    facts: facts,
    ai: () => ai,
    limits: limits,
    clock: () => DateTime.fromMillisecondsSinceEpoch(now += 1000),
    videoDecider: () => (AiVideoIdentityQuery q) async {
      asked.add(q);
      return AiVideoIdentityDecision(key: 'anidb:2', confidence: 0.99);
    },
  );

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    toolbox = _FakeToolbox(db);
    facts = _FakeFacts();
    library = _Library();
    store = MemoryLibraryCurateStore();
    ai = (organize: true, videoIdentify: true, mediaLinks: true);
    now = 1000000;
    asked = <AiVideoIdentityQuery>[];

    toolbox
      ..op(
        LibraryCurateOps.organizeRun,
        (Map<String, Object?> a) async {
          final String m = 'S:${a['domain']}';
          final bool added = library.members.add(m);
          return <String, Object?>{
            'status': a['rulesOnly'] == true ? 'noProvider' : 'done',
            'runId': 7,
            'changes': added ? 1 : 0,
            'proposals': 0,
            'requests': a['rulesOnly'] == true ? 0 : 1,
          };
        },
        payload: (Map<String, Object?> a, Object? r) => <String, Object?>{
          'member': 'S:${a['domain']}',
          'added': (r! as Map)['changes'] == 1,
        },
        undo: (Map<String, Object?> p) async {
          if (p['added'] == true) library.members.remove(p['member']);
        },
      )
      ..op(
        LibraryCurateOps.videoWorkList,
        (_) async => <String, Object?>{
          'works': <Object?>[
            <String, Object?>{'id': 'w1', 'title': 'Alpha', 'members': 12},
            <String, Object?>{'id': 'w2', 'title': 'Beta', 'members': 1},
          ],
        },
        risk: AgentToolRisk.read,
      )
      ..op(
        LibraryCurateOps.videoWorkCandidates,
        (Map<String, Object?> a) async => <String, Object?>{
          'candidates': a['id'] == 'w1'
              ? <Object?>[
                  <String, Object?>{
                    'identity': 'anidb:1',
                    'provider': 'anidb',
                    'externalId': '1',
                    'title': 'Alpha',
                    'mediaKind': 'tv',
                  },
                ]
              : <Object?>[
                  <String, Object?>{
                    'identity': 'anidb:2',
                    'provider': 'anidb',
                    'externalId': '2',
                    'title': 'Beta TV',
                    'mediaKind': 'tv',
                  },
                  <String, Object?>{
                    'identity': 'anidb:3',
                    'provider': 'anidb',
                    'externalId': '3',
                    'title': 'Beta Movie',
                    'mediaKind': 'movie',
                  },
                ],
        },
        risk: AgentToolRisk.read,
      )
      ..op(
        LibraryCurateOps.videoWorkIdentify,
        (Map<String, Object?> a) async {
          library.identity['${a['id']}'] =
              '${a['provider']}:${a['externalId']}';
          return <String, Object?>{'ok': true};
        },
        payload: (Map<String, Object?> a, Object? r) => <String, Object?>{
          'id': a['id'],
        },
        undo: (Map<String, Object?> p) async =>
            library.identity.remove(p['id']),
      )
      ..op(
        LibraryCurateOps.linksInfer,
        (Map<String, Object?> a) async {
          final List<String> written = <String>[
            for (final Object? e in a['endpoints']! as List)
              if (library.links.add('$e~work')) '$e~work',
          ];
          return <String, Object?>{
            'applied': written.length,
            'suggested': 0,
            'requests': (a['endpoints']! as List).length,
            'failed': <Object?>[],
            'writes': written,
          };
        },
        payload: (Map<String, Object?> a, Object? r) => <String, Object?>{
          'writes': (r! as Map)['writes'],
        },
        undo: (Map<String, Object?> p) async {
          for (final Object? w in p['writes']! as List) {
            library.links.remove('$w');
          }
        },
      )
      ..op(
        LibraryCurateOps.linksMusic,
        (Map<String, Object?> a) async {
          final bool added = library.links.add('album~work');
          return <String, Object?>{
            'applied': added ? 1 : 0,
            'suggested': 0,
            'requests': a['useAi'] == true ? 1 : 0,
          };
        },
        payload: (Map<String, Object?> a, Object? r) => <String, Object?>{
          'added': (r! as Map)['applied'] == 1,
        },
        undo: (Map<String, Object?> p) async {
          if (p['added'] == true) library.links.remove('album~work');
        },
      );
  });

  tearDown(() => db.close());

  test('阶段按设计稿 §3 的顺序跑，写操作全记在 curator:<runId> 会话下', () async {
    final LibraryCurateRun run = await curator().run(
      trigger: LibraryCurateTrigger.manual,
    );
    expect(run.status, LibraryCurateRunStatus.done);
    expect(toolbox.calls, <String>[
      LibraryCurateOps.organizeRun,
      LibraryCurateOps.organizeRun,
      LibraryCurateOps.organizeRun,
      LibraryCurateOps.organizeRun,
      LibraryCurateOps.videoWorkList,
      LibraryCurateOps.videoWorkCandidates,
      LibraryCurateOps.videoWorkIdentify,
      LibraryCurateOps.videoWorkCandidates,
      LibraryCurateOps.videoWorkIdentify,
      LibraryCurateOps.linksInfer,
      LibraryCurateOps.linksMusic,
    ]);
    expect(
      <Object?>[
        for (final Map<String, Object?> a in toolbox.args)
          if (a.containsKey('domain')) a['domain'],
      ],
      <String>['books', 'manga', 'video', 'games'],
    );
    final List<AiAgentActionRow> rows = await db.listAiAgentActions();
    expect(rows, hasLength(8));
    expect(rows.map((AiAgentActionRow r) => r.sessionId).toSet(), <String>{
      'curator:${run.id}',
    });
    // 单候选 + 标题强匹配直接认领（不问 AI）；多候选交 AI 选（选了 anidb:2）。
    expect(library.identity, <String, String>{
      'w1': 'anidb:1',
      'w2': 'anidb:2',
    });
    expect(asked, hasLength(1));
    expect(
      asked.single.candidates.map((AiVideoIdentityCandidate c) => c.key),
      <String>['anidb:2', 'anidb:3'],
    );
    expect(
      run.stages.map((LibraryCurateStageResult s) => s.stage),
      LibraryCurateStage.values,
    );
    expect(run.stages.last.note, isNotNull); // 作品层：分量数。
  });

  test('取消：之后的阶段一律 cancelled，不再调任何操作', () async {
    int organizeCalls = 0;
    final LibraryCurateRun run = await curator().run(
      trigger: LibraryCurateTrigger.manual,
      isCancelled: () => toolbox.calls.where((String c) {
        return c == LibraryCurateOps.organizeRun;
      }).isNotEmpty,
      onProgress: (LibraryCurateStage s, int i, int total) {
        if (s == LibraryCurateStage.organizeBooks) organizeCalls++;
      },
    );
    expect(organizeCalls, 1);
    expect(toolbox.calls, <String>[LibraryCurateOps.organizeRun]);
    expect(run.status, LibraryCurateRunStatus.cancelled);
    expect(
      run.stages.skip(1).map((LibraryCurateStageResult s) => s.status).toSet(),
      <LibraryCurateStageStatus>{LibraryCurateStageStatus.cancelled},
    );
  });

  test('单阶段失败只记下失败码，后面的阶段照跑；水位只推进做完的阶段', () async {
    final _Op books = toolbox.ops[LibraryCurateOps.organizeRun]!;
    toolbox.op(
      LibraryCurateOps.organizeRun,
      (Map<String, Object?> a) async {
        if (a['domain'] == 'books') throw const _Fail('network');
        return books.handler(a);
      },
      payload: books.payload,
      undo: books.undo,
    );
    final LibraryCurateRun run = await curator().run(
      trigger: LibraryCurateTrigger.manual,
    );
    expect(run.status, LibraryCurateRunStatus.partial);
    final LibraryCurateStageResult first = run.stages.first;
    expect(first.status, LibraryCurateStageStatus.failed);
    expect(first.error, 'network');
    expect(toolbox.calls, contains(LibraryCurateOps.linksMusic));
    final LibraryCurateState state = await store.load();
    expect(state.watermarks.containsKey('organize.books'), isFalse);
    expect(state.watermarks['organize.manga'], run.startedAt);
    expect(state.watermarks['links'], run.startedAt);
  });

  test('增量水位：首趟全量（since = null），下一趟从上一趟的开始时刻起', () async {
    final LibraryCurateRun first = await curator().run(
      trigger: LibraryCurateTrigger.auto,
    );
    await curator().run(trigger: LibraryCurateTrigger.auto);
    expect(facts.organizeSince.take(4), everyElement(isNull));
    expect(facts.organizeSince.skip(4), everyElement(first.startedAt));
    expect(facts.linksSince, <int?>[null, first.startedAt]);
    // 第二趟按水位只给新条目。
    final Map<String, Object?> lastOrganize = toolbox.args.lastWhere(
      (Map<String, Object?> a) => a['domain'] == 'games',
    );
    expect(lastOrganize['entryKeys'], <String>['book:1']);
    expect(lastOrganize['trigger'], 'auto');
  });

  test('没给任何一步指派 AI：一个 AI 请求都不发，规则 / 本地部分照跑', () async {
    ai = kLibraryCurateNoAi;
    final LibraryCurateRun run = await curator().run(
      trigger: LibraryCurateTrigger.manual,
    );
    expect(asked, isEmpty);
    expect(
      toolbox.args
          .where((Map<String, Object?> a) => a.containsKey('domain'))
          .map((Map<String, Object?> a) => a['rulesOnly']),
      everyElement(isTrue),
    );
    expect(toolbox.calls, isNot(contains(LibraryCurateOps.videoWorkList)));
    expect(toolbox.calls, isNot(contains(LibraryCurateOps.linksInfer)));
    expect(toolbox.args.last['useAi'], isFalse);
    expect(run.requests, 0);
    final Map<LibraryCurateStage, LibraryCurateStageResult> byStage =
        <LibraryCurateStage, LibraryCurateStageResult>{
          for (final LibraryCurateStageResult s in run.stages) s.stage: s,
        };
    expect(byStage[LibraryCurateStage.scrape]!.error, 'no_provider');
    expect(byStage[LibraryCurateStage.links]!.error, 'no_provider');
    expect(
      byStage[LibraryCurateStage.organizeBooks]!.status,
      LibraryCurateStageStatus.partial,
    );
  });

  test('自动路径单趟请求上限：超了的部分只跑不花钱的，下一趟接着做、不重做已处理的', () async {
    facts.endpoints = <String>['book:a', 'book:b', 'book:c', 'game:g'];
    // 四个整理域各 1 次 + 一次 AI 消歧 = 5，剩 2 次只够两个端点。
    final LibraryCurator c = curator(
      limits: const LibraryCurateLimits(autoMaxRequests: 7, linkBatchSize: 2),
    );
    final LibraryCurateRun first = await c.run(
      trigger: LibraryCurateTrigger.auto,
    );
    final LibraryCurateStageResult links = first.stages.firstWhere(
      (LibraryCurateStageResult s) => s.stage == LibraryCurateStage.links,
    );
    expect(links.status, LibraryCurateStageStatus.partial);
    expect(links.error, 'request_cap');
    expect(first.requests, lessThanOrEqualTo(7));
    final List<Object?> firstEndpoints = <Object?>[
      for (final Map<String, Object?> a in toolbox.args)
        if (a.containsKey('endpoints')) ...a['endpoints']! as List,
    ];
    expect(firstEndpoints, <String>['book:a', 'book:b']);
    // 音乐那一步的 AI 也没额度：只跑声纹 / 本地标题。
    expect(toolbox.args.last['useAi'], isFalse);
    expect((await store.load()).watermarks.containsKey('links'), isFalse);

    toolbox.args.clear();
    await c.run(trigger: LibraryCurateTrigger.auto);
    final List<Object?> secondEndpoints = <Object?>[
      for (final Map<String, Object?> a in toolbox.args)
        if (a.containsKey('endpoints')) ...a['endpoints']! as List,
    ];
    expect(secondEndpoints, <String>['book:c', 'game:g']);
  });

  test('需要用户确认的操作在编排里不执行，收进待确认', () async {
    final _Op identify = toolbox.ops[LibraryCurateOps.videoWorkIdentify]!;
    toolbox.op(
      LibraryCurateOps.videoWorkIdentify,
      identify.handler,
      risk: AgentToolRisk.irreversible,
    );
    final LibraryCurateRun run = await curator().run(
      trigger: LibraryCurateTrigger.manual,
    );
    expect(toolbox.calls, isNot(contains(LibraryCurateOps.videoWorkIdentify)));
    expect(library.identity, isEmpty);
    expect(
      run.pendingItems.map((LibraryCuratePendingItem p) => p.kind),
      everyElement('needs_confirmation'),
    );
    expect(run.pendingItems, hasLength(2));
  });

  test('整趟撤销往返：倒序撤回到原状；再跑一趟不把撤掉的认领 / 连接做回来', () async {
    final String before = library.snapshot();
    final LibraryCurator c = curator();
    final LibraryCurateRun run = await c.run(
      trigger: LibraryCurateTrigger.manual,
    );
    expect(library.snapshot(), isNot(before));

    final List<String> undoOrder = <String>[];
    for (final MapEntry<String, _Op> e in toolbox.ops.entries.toList()) {
      final _Op op = e.value;
      if (op.undo == null) continue;
      toolbox.op(
        e.key,
        op.handler,
        risk: op.spec.risk,
        payload: op.payload,
        undo: (Map<String, Object?> p) async {
          undoOrder.add(e.key);
          await op.undo!(p);
        },
      );
    }
    final LibraryCurateUndoResult undone = await c.undoRun(run.id);
    expect(undone.undone, 8);
    expect(undone.failed, 0);
    expect(library.snapshot(), before);
    // 写入的逆序：音乐 → 连接 → 认领 → 合集。
    expect(undoOrder, <String>[
      LibraryCurateOps.linksMusic,
      LibraryCurateOps.linksInfer,
      LibraryCurateOps.videoWorkIdentify,
      LibraryCurateOps.videoWorkIdentify,
      LibraryCurateOps.organizeRun,
      LibraryCurateOps.organizeRun,
      LibraryCurateOps.organizeRun,
      LibraryCurateOps.organizeRun,
    ]);
    final LibraryCurateState state = await store.load();
    expect(state.runById(run.id)!.undoneAt, isNotNull);
    expect(
      state.suppressed,
      containsAll(<String>[
        'scrape:w1',
        'scrape:w2',
        'links:book:a',
        'links:game:g',
      ]),
    );

    // 再跑一趟（手动、全量）：撤掉的认领与推断入口不再碰。
    toolbox.calls.clear();
    await c.run(trigger: LibraryCurateTrigger.manual, full: true);
    expect(toolbox.calls, isNot(contains(LibraryCurateOps.videoWorkIdentify)));
    expect(toolbox.calls, isNot(contains(LibraryCurateOps.linksInfer)));
    expect(library.identity, isEmpty);

    // 第二次撤销同一趟：没有可撤的了。
    final LibraryCurateUndoResult again = await c.undoRun(run.id);
    expect(again.undone, 0);
  });

  test('同一时刻只跑一趟', () async {
    final LibraryCurator c = curator();
    final Future<LibraryCurateRun> first = c.run(
      trigger: LibraryCurateTrigger.manual,
    );
    expect(c.isRunning, isTrue);
    await expectLater(
      c.run(trigger: LibraryCurateTrigger.auto),
      throwsA(isA<LibraryCurateBusy>()),
    );
    await first;
    expect(c.isRunning, isFalse);
  });

  test('费用预估：只数指派了 AI 的步骤', () async {
    facts.chunks = 2;
    final LibraryCurateEstimate all = await curator().estimate();
    expect(all.requestsByStage[LibraryCurateStage.organizeBooks], 2);
    expect(all.requestsByStage[LibraryCurateStage.scrape], 2);
    expect(all.requestsByStage[LibraryCurateStage.links], 3);
    ai = kLibraryCurateNoAi;
    final LibraryCurateEstimate none = await curator().estimate();
    expect(none.requests, 0);
    expect(none.items, greaterThan(0));
  });

  test('状态 JSON 往返', () {
    final LibraryCurateState s = LibraryCurateState()
      ..watermarks['links'] = 5
      ..progress['links'] = <String>{'book:a'}
      ..suppressed.add('scrape:w1');
    s.upsertRun(
      LibraryCurateRun(
        id: 9,
        trigger: LibraryCurateTrigger.auto,
        startedAt: 9,
        stages: <LibraryCurateStageResult>[
          const LibraryCurateStageResult(
            stage: LibraryCurateStage.links,
            status: LibraryCurateStageStatus.partial,
            changes: 2,
            error: 'request_cap',
          ),
        ],
      ),
    );
    // 进程半路被杀：停在 running 的记录读回来算失败。
    expect(
      LibraryCurateState.decode(s.encode()).runs.single.status,
      LibraryCurateRunStatus.failed,
    );
    s.runs.single.status = LibraryCurateRunStatus.partial;
    final LibraryCurateState back = LibraryCurateState.decode(s.encode());
    expect(back.encode(), s.encode());
    expect(LibraryCurateState.decode('not json').runs, isEmpty);
  });
}
