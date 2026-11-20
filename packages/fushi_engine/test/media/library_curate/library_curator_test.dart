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
import 'package:fushi_engine/ai/ai_media_identity_assistant.dart';
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

  List<LibraryCurateBookUnit> bookUnits = <LibraryCurateBookUnit>[];
  List<LibraryCurateGameUnit> gameUnits = <LibraryCurateGameUnit>[];

  @override
  Future<List<LibraryCurateBookUnit>> bookScrapeUnits(int? sinceMs) async =>
      bookUnits;

  @override
  Future<List<LibraryCurateGameUnit>> gameScrapeUnits(int? sinceMs) async =>
      gameUnits;
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
  late List<AiMediaIdentityQuery> mediaAsked;
  late AiVideoIdentityDecision? Function(AiMediaIdentityQuery q) mediaAnswer;
  late bool mediaAssigned;

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
    mediaDecider: () => mediaAssigned
        ? (AiMediaIdentityQuery q) async {
            mediaAsked.add(q);
            return mediaAnswer(q);
          }
        : null,
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
    mediaAsked = <AiMediaIdentityQuery>[];
    mediaAnswer = (AiMediaIdentityQuery q) => null;
    mediaAssigned = true;

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
            for (final Object? e in a['items']! as List)
              if (library.links.add('$e~work')) '$e~work',
          ];
          return <String, Object?>{
            'applied': written.length,
            'suggested': 0,
            'requests': (a['items']! as List).length,
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

  group('视频摆放纠正阶段', () {
    late List<Map<String, Object?>> findings;
    late Set<String> split;

    setUp(() {
      split = <String>{};
      findings = <Map<String, Object?>>[
        <String, Object?>{
          'kind': 'feature_in_specials',
          'work': 'collection:1',
          'uid': 'm1',
          'title': 'Beta Movie',
          'episodeMinutes': 24,
        },
        <String, Object?>{
          'kind': 'features_only_work',
          'work': 'collection:2',
          'uid': 'm2',
          'title': 'Gamma',
        },
      ];
      toolbox
        ..op(
          LibraryCurateOps.videoLibraryAudit,
          (_) async => <String, Object?>{
            'findings': <Object?>[
              for (final Map<String, Object?> f in findings)
                if (!split.contains(f['uid'])) f,
            ],
          },
          risk: AgentToolRisk.read,
        )
        ..op(
          LibraryCurateOps.videoWorkRegroup,
          (Map<String, Object?> a) async {
            split.addAll((a['items']! as List).cast<String>());
            return <String, Object?>{
              'moved': <Object?>[
                for (final Object? uid in a['items']! as List)
                  <String, Object?>{'uid': uid, 'to': 'book:$uid'},
              ],
              'skipped': <Object?>[],
            };
          },
          payload: (Map<String, Object?> a, Object? r) => <String, Object?>{
            'items': a['items'],
          },
          undo: (Map<String, Object?> p) async =>
              split.removeAll((p['items']! as List).cast<String>()),
        );
    });

    LibraryCurateStageResult stageOf(LibraryCurateRun run) =>
        run.stages.firstWhere(
          (LibraryCurateStageResult s) =>
              s.stage == LibraryCurateStage.videoStructure,
        );

    test('个别错放的拆出来并按电影认领；拆不了的进待确认', () async {
      final LibraryCurateRun run = await curator().run(
        trigger: LibraryCurateTrigger.manual,
      );
      final LibraryCurateStageResult stage = stageOf(run);
      expect(stage.status, LibraryCurateStageStatus.done);
      // 拆出 + 认领各算一处改动。候选里只有一部电影形态的（anidb:3），标题强匹配。
      expect(stage.changes, 2);
      expect(stage.requests, 0);
      expect(split, <String>{'m1'});
      expect(library.identity['book:m1'], 'anidb:3');
      final int regroupAt = toolbox.calls.indexOf(
        LibraryCurateOps.videoWorkRegroup,
      );
      expect(toolbox.args[regroupAt], <String, Object?>{
        'items': <String>['m1'],
        'to': 'standalone',
      });
      expect(
        toolbox.args[toolbox.calls.lastIndexOf(
          LibraryCurateOps.videoWorkIdentify,
          toolbox.calls.indexOf(LibraryCurateOps.videoWorkList),
        )],
        containsPair('type', 'movie'),
      );
      expect(
        <String>[
          for (final LibraryCuratePendingItem p in run.pendingItems)
            if (p.stage == LibraryCurateStage.videoStructure)
              '${p.kind}/${p.title}/${p.ref}/${p.reason}',
        ],
        <String>['structure_pending/Gamma/collection:2/features_only_work'],
      );
      // 排在 ③ 认身份之前。
      expect(
        regroupAt,
        lessThan(toolbox.calls.indexOf(LibraryCurateOps.videoWorkList)),
      );
    });

    test('认身份的 AI 没指派：只拆、不搜资料源，拆出来的留待确认', () async {
      ai = (organize: true, videoIdentify: false, mediaLinks: true);
      final LibraryCurateRun run = await curator().run(
        trigger: LibraryCurateTrigger.manual,
      );
      final LibraryCurateStageResult stage = stageOf(run);
      expect(stage.changes, 1);
      expect(stage.note, 'rules_only');
      expect(split, <String>{'m1'});
      expect(
        toolbox.calls,
        isNot(contains(LibraryCurateOps.videoWorkCandidates)),
      );
      expect(
        run.pendingItems.map((LibraryCuratePendingItem p) => p.reason),
        containsAll(<String>['needs_identify', 'features_only_work']),
      );
    });

    test('整趟撤销后不再自动把同一个文件拆出来', () async {
      final LibraryCurator c = curator();
      final LibraryCurateRun run = await c.run(
        trigger: LibraryCurateTrigger.manual,
      );
      await c.undoRun(run.id);
      expect(split, isEmpty);
      expect(library.identity.containsKey('book:m1'), isFalse);
      await c.run(trigger: LibraryCurateTrigger.manual);
      expect(split, isEmpty);
    });
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
        if (a.containsKey('items')) ...a['items']! as List,
    ];
    expect(firstEndpoints, <String>['book:a', 'book:b']);
    // 音乐那一步的 AI 也没额度：只跑声纹 / 本地标题。
    expect(toolbox.args.last['useAi'], isFalse);
    expect((await store.load()).watermarks.containsKey('links'), isFalse);

    toolbox.args.clear();
    await c.run(trigger: LibraryCurateTrigger.auto);
    final List<Object?> secondEndpoints = <Object?>[
      for (final Map<String, Object?> a in toolbox.args)
        if (a.containsKey('items')) ...a['items']! as List,
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

  group('书 / 游戏刮削阶段', () {
    /// 书的候选（按查询词）与游戏的候选（按游戏 id）。
    late Map<String, List<Map<String, Object?>>> bookFound;
    late Map<String, List<Map<String, Object?>>> gameFound;

    /// 书上「用户设过」的字段（假路由的 onlyEmpty 据此过滤）。
    late Map<String, Set<String>> userSet;

    /// 写回的结果：书键 → 字段 → 候选 id；游戏 id → 候选。
    late Map<String, Map<String, String>> bookWrites;
    late Map<String, String> gameWrites;
    late List<Map<String, Object?>> applyArgs;

    Map<String, Object?> book(
      String id,
      String title, {
      String? author = 'Author',
      String source = 'bangumi',
    }) => <String, Object?>{
      'source': source,
      'id': id,
      'title': title,
      'author': ?author,
      'coverUrl': 'https://x/$id.jpg',
    };

    Map<String, Object?> game(String id, String name) => <String, Object?>{
      'id': id,
      'source': id.split(':').first,
      'externalId': id.split(':').last,
      'name': name,
    };

    LibraryCurateBookVolume vol(
      String key,
      String title, {
      String? author,
      bool missingCover = true,
      String? isbn,
    }) => LibraryCurateBookVolume(
      bookKey: key,
      title: title,
      author: author,
      isbn: isbn,
      missingCover: missingCover,
      fileNameTitle: looksLikeFileNameTitle(title),
    );

    LibraryCurateBookUnit single(LibraryCurateBookVolume v) =>
        LibraryCurateBookUnit(
          id: v.shelfKey,
          title: v.title,
          volumes: <LibraryCurateBookVolume>[v],
        );

    setUp(() {
      ai = (organize: false, videoIdentify: true, mediaLinks: false);
      bookFound = <String, List<Map<String, Object?>>>{};
      gameFound = <String, List<Map<String, Object?>>>{};
      userSet = <String, Set<String>>{};
      bookWrites = <String, Map<String, String>>{};
      gameWrites = <String, String>{};
      applyArgs = <Map<String, Object?>>[];
      // 只看这两个阶段：其余阶段的操作一律不可用（跳过）。
      toolbox.ops.clear();
      toolbox
        ..op(
          LibraryCurateOps.bookScrapeSearch,
          (Map<String, Object?> a) async => <String, Object?>{
            'candidates': bookFound['${a['query']}'] ?? const <Object?>[],
          },
          risk: AgentToolRisk.read,
        )
        ..op(
          LibraryCurateOps.bookScrapeApply,
          (Map<String, Object?> a) async {
            applyArgs.add(a);
            final String key = '${a['key']}';
            final List<String> fields = <String>[
              for (final Object? f in a['fields']! as List)
                if (!(a['onlyEmpty'] == true &&
                    (userSet[key]?.contains('$f') ?? false)))
                  '$f',
            ];
            if (fields.isEmpty) throw const _Fail('rejected');
            final Map<String, String> w = bookWrites.putIfAbsent(
              key,
              () => <String, String>{},
            );
            for (final String f in fields) {
              w[f] = '${a['id']}';
            }
            return <String, Object?>{'key': key, 'applied': fields};
          },
          payload: (Map<String, Object?> a, Object? r) => <String, Object?>{
            'key': a['key'],
            'fields': (r! as Map)['applied'],
          },
          undo: (Map<String, Object?> p) async {
            final Map<String, String>? w = bookWrites['${p['key']}'];
            for (final Object? f in p['fields']! as List) {
              w?.remove('$f');
            }
            if (w != null && w.isEmpty) bookWrites.remove('${p['key']}');
          },
        )
        ..op(
          LibraryCurateOps.gameScrapeSearch,
          (Map<String, Object?> a) async => <String, Object?>{
            'candidates': gameFound['${a['id']}'] ?? const <Object?>[],
          },
          risk: AgentToolRisk.read,
        )
        ..op(
          LibraryCurateOps.gameScrapeApply,
          (Map<String, Object?> a) async {
            applyArgs.add(a);
            gameWrites['${a['id']}'] = '${a['candidate']}';
            return <String, Object?>{'ok': true};
          },
          payload: (Map<String, Object?> a, Object? r) => <String, Object?>{
            'id': a['id'],
          },
          undo: (Map<String, Object?> p) async => gameWrites.remove(p['id']),
        );
    });

    LibraryCurateStageResult stageOf(
      LibraryCurateRun run,
      LibraryCurateStage stage,
    ) =>
        run.stages.firstWhere((LibraryCurateStageResult s) => s.stage == stage);

    test('唯一候选且标题一致：不问 AI 直接写回，只写空缺字段，游戏带 keepCover', () async {
      facts.bookUnits = <LibraryCurateBookUnit>[
        single(vol('k1', 'Alpha Book')),
        // 作者已有（用户的）：只补封面。
        single(vol('k2', 'Beta Book', author: 'Mine')),
      ];
      bookFound['Alpha Book'] = <Map<String, Object?>>[book('1', 'Alpha Book')];
      bookFound['Beta Book'] = <Map<String, Object?>>[book('2', 'Beta Book')];
      facts.gameUnits = const <LibraryCurateGameUnit>[
        LibraryCurateGameUnit(id: 'g1', title: 'Clannad'),
      ];
      // 同一款游戏在两个源各一条 + 一条不相干的：每个源至多一条一致 → 认第一条。
      gameFound['g1'] = <Map<String, Object?>>[
        game('vndb:v4', 'CLANNAD'),
        game('bgm:51', 'Clannad'),
        game('vndb:v5', 'Clannad Side Stories'),
      ];
      final LibraryCurateRun run = await curator().run(
        trigger: LibraryCurateTrigger.manual,
      );
      expect(mediaAsked, isEmpty);
      expect(bookWrites, <String, Map<String, String>>{
        'book:k1': <String, String>{'cover': '1', 'author': '1'},
        'book:k2': <String, String>{'cover': '2'},
      });
      expect(
        applyArgs.where((Map<String, Object?> a) => a.containsKey('key')),
        everyElement(containsPair('onlyEmpty', true)),
      );
      expect(gameWrites, <String, String>{'g1': 'vndb:v4'});
      expect(applyArgs.last['keepCover'], isTrue);
      expect(stageOf(run, LibraryCurateStage.scrapeBooks).changes, 2);
      expect(
        stageOf(run, LibraryCurateStage.scrapeGames).status,
        LibraryCurateStageStatus.done,
      );
    });

    test('多候选、没指派 AI：一个 AI 请求都不发，留待确认（结果与 pending 里看得到）', () async {
      ai = kLibraryCurateNoAi;
      facts.bookUnits = <LibraryCurateBookUnit>[single(vol('k1', 'Gamma'))];
      bookFound['Gamma'] = <Map<String, Object?>>[
        book('1', 'Gamma'),
        book('2', 'Gamma 2'),
      ];
      facts.gameUnits = const <LibraryCurateGameUnit>[
        LibraryCurateGameUnit(id: 'g1', title: 'Delta'),
      ];
      gameFound['g1'] = <Map<String, Object?>>[
        game('vndb:v1', 'Delta One'),
        game('vndb:v2', 'Delta Two'),
      ];
      final LibraryCurateRun run = await curator().run(
        trigger: LibraryCurateTrigger.manual,
      );
      expect(mediaAsked, isEmpty);
      expect(bookWrites, isEmpty);
      expect(gameWrites, isEmpty);
      expect(
        run.pendingItems.map(
          (LibraryCuratePendingItem p) => '${p.kind}|${p.ref}|${p.reason}',
        ),
        containsAll(<String>[
          'book_scrape_pending|book:k1|ambiguous',
          'game_scrape_pending|game:g1|ambiguous',
        ]),
      );
      expect(stageOf(run, LibraryCurateStage.scrapeBooks).pending, 1);
      expect(stageOf(run, LibraryCurateStage.scrapeGames).pending, 1);
    });

    test('多候选：AI 高置信写回，低置信留待确认', () async {
      facts.bookUnits = <LibraryCurateBookUnit>[
        single(vol('k1', 'Eta')),
        single(vol('k2', 'Theta')),
      ];
      bookFound['Eta'] = <Map<String, Object?>>[
        book('1', 'Eta (novel)'),
        book('2', 'Eta (manga)'),
      ];
      bookFound['Theta'] = <Map<String, Object?>>[
        book('3', 'Theta I'),
        book('4', 'Theta II'),
      ];
      mediaAnswer = (AiMediaIdentityQuery q) => q.localTitles.single == 'Eta'
          ? const AiVideoIdentityDecision(key: 'bangumi:1', confidence: 0.95)
          : const AiVideoIdentityDecision(key: 'bangumi:3', confidence: 0.6);
      final LibraryCurateRun run = await curator().run(
        trigger: LibraryCurateTrigger.manual,
      );
      expect(mediaAsked, hasLength(2));
      expect(mediaAsked.first.candidates.map((c) => c.key), <String>[
        'bangumi:1',
        'bangumi:2',
      ]);
      expect(bookWrites.keys, <String>['book:k1']);
      expect(
        run.pendingItems.singleWhere(
          (LibraryCuratePendingItem p) => p.kind == 'book_scrape_pending',
        ),
        isA<LibraryCuratePendingItem>()
            .having((p) => p.ref, 'ref', 'book:k2')
            .having((p) => p.reason, 'reason', 'low_confidence'),
      );
      expect(stageOf(run, LibraryCurateStage.scrapeBooks).requests, 2);
    });

    test('用户设过的字段（override 显示名 / 封面）不覆盖：全被滤掉时算没东西写，不算失败', () async {
      facts.bookUnits = <LibraryCurateBookUnit>[
        single(vol('k1', '[Circle] Iota.epub')),
      ];
      bookFound['[Circle] Iota.epub'] = <Map<String, Object?>>[
        book('1', 'Iota'),
        book('2', 'Iota 2'),
      ];
      userSet['book:k1'] = <String>{'cover', 'title', 'author'};
      mediaAnswer = (_) =>
          const AiVideoIdentityDecision(key: 'bangumi:1', confidence: 0.99);
      final LibraryCurateRun run = await curator().run(
        trigger: LibraryCurateTrigger.manual,
      );
      // 请求了三个空缺字段（文件名书名 → 也请求写显示名），路由按用户值全部滤掉。
      expect(applyArgs.single['fields'], <String>['cover', 'author', 'title']);
      expect(bookWrites, isEmpty);
      final LibraryCurateStageResult s = stageOf(
        run,
        LibraryCurateStage.scrapeBooks,
      );
      expect(s.status, LibraryCurateStageStatus.done);
      expect(s.changes, 0);
    });

    test('系列按合集名只查一次、只问一次 AI；各卷按卷名各自取封面', () async {
      facts.bookUnits = <LibraryCurateBookUnit>[
        LibraryCurateBookUnit(
          id: 'collection:7',
          title: 'Kappa',
          isSeries: true,
          volumes: <LibraryCurateBookVolume>[
            vol('v1', 'Kappa 1'),
            vol('v2', 'Kappa 2'),
          ],
        ),
      ];
      bookFound['Kappa'] = <Map<String, Object?>>[
        book('10', 'Kappa', author: 'Series Author'),
        book('11', 'Kappa Gaiden'),
      ];
      bookFound['Kappa 1'] = <Map<String, Object?>>[
        book('21', 'Kappa 1', author: null),
      ];
      // 第 2 卷按卷名查不到唯一一致的：只补作者（来自系列候选）。
      bookFound['Kappa 2'] = <Map<String, Object?>>[];
      mediaAnswer = (_) =>
          const AiVideoIdentityDecision(key: 'bangumi:10', confidence: 0.9);
      await curator().run(trigger: LibraryCurateTrigger.manual);
      expect(mediaAsked, hasLength(1));
      expect(mediaAsked.single.volumeCount, 2);
      expect(bookWrites, <String, Map<String, String>>{
        'book:v1': <String, String>{'cover': '21'},
        'book:v2': <String, String>{'author': '10'},
      });
    });

    test('整趟撤销后下一趟（手动全量）不再写回同一本书 / 同一款游戏', () async {
      facts.bookUnits = <LibraryCurateBookUnit>[single(vol('k1', 'Lambda'))];
      bookFound['Lambda'] = <Map<String, Object?>>[book('1', 'Lambda')];
      facts.gameUnits = const <LibraryCurateGameUnit>[
        LibraryCurateGameUnit(id: 'g1', title: 'Mu'),
      ];
      gameFound['g1'] = <Map<String, Object?>>[game('bgm:1', 'Mu')];
      final LibraryCurator c = curator();
      final LibraryCurateRun run = await c.run(
        trigger: LibraryCurateTrigger.manual,
      );
      expect(bookWrites, isNotEmpty);
      expect(gameWrites, isNotEmpty);
      final LibraryCurateUndoResult undone = await c.undoRun(run.id);
      expect(undone.undone, 2);
      expect(bookWrites, isEmpty);
      expect(gameWrites, isEmpty);
      expect(
        (await store.load()).suppressed,
        containsAll(<String>['scrape.books:book:k1', 'scrape.games:g1']),
      );
      applyArgs.clear();
      await c.run(trigger: LibraryCurateTrigger.manual, full: true);
      expect(applyArgs, isEmpty);
      expect(bookWrites, isEmpty);
      expect(gameWrites, isEmpty);
    });

    test('自动路径：AI 请求受单趟上限，超了的留到下一趟；单元数也有上限', () async {
      facts.bookUnits = <LibraryCurateBookUnit>[
        for (final String t in <String>['Nu', 'Xi', 'Omicron'])
          single(vol(t, t)),
      ];
      for (final String t in <String>['Nu', 'Xi', 'Omicron']) {
        bookFound[t] = <Map<String, Object?>>[book('$t-a', t), book('$t-b', t)];
      }
      mediaAnswer = (AiMediaIdentityQuery q) => AiVideoIdentityDecision(
        key: 'bangumi:${q.localTitles.single}-a',
        confidence: 0.99,
      );
      final LibraryCurator c = curator(
        limits: const LibraryCurateLimits(autoMaxRequests: 2),
      );
      final LibraryCurateRun first = await c.run(
        trigger: LibraryCurateTrigger.auto,
      );
      final LibraryCurateStageResult s = stageOf(
        first,
        LibraryCurateStage.scrapeBooks,
      );
      expect(s.status, LibraryCurateStageStatus.partial);
      expect(s.error, 'request_cap');
      expect(mediaAsked, hasLength(2));
      expect(bookWrites.keys, <String>['book:Nu', 'book:Xi']);
      expect(
        (await store.load()).watermarks.containsKey('scrape.books'),
        false,
      );

      mediaAsked.clear();
      await c.run(trigger: LibraryCurateTrigger.auto);
      // 下一趟只处理剩下的那本（已写回的不再查）。
      expect(
        mediaAsked.map((AiMediaIdentityQuery q) => q.localTitles.single),
        <String>['Omicron'],
      );

      final LibraryCurator capped = curator(
        limits: const LibraryCurateLimits(autoMaxGameUnits: 1),
      );
      facts.gameUnits = const <LibraryCurateGameUnit>[
        LibraryCurateGameUnit(id: 'a', title: 'A'),
        LibraryCurateGameUnit(id: 'b', title: 'B'),
      ];
      gameFound['a'] = <Map<String, Object?>>[game('bgm:1', 'A')];
      gameFound['b'] = <Map<String, Object?>>[game('bgm:2', 'B')];
      final LibraryCurateRun g = await capped.run(
        trigger: LibraryCurateTrigger.auto,
      );
      expect(gameWrites, <String, String>{'a': 'bgm:1'});
      expect(
        stageOf(g, LibraryCurateStage.scrapeGames).status,
        LibraryCurateStageStatus.partial,
      );
    });

    test('费用预估把书 / 游戏单元算进去（没指派 AI 时请求为 0）', () async {
      facts.bookUnits = <LibraryCurateBookUnit>[single(vol('k1', 'Pi'))];
      facts.gameUnits = const <LibraryCurateGameUnit>[
        LibraryCurateGameUnit(id: 'g1', title: 'Rho'),
        LibraryCurateGameUnit(id: 'g2', title: 'Sigma'),
      ];
      final LibraryCurateEstimate e = await curator().estimate();
      expect(e.itemsByStage[LibraryCurateStage.scrapeBooks], 1);
      expect(e.requestsByStage[LibraryCurateStage.scrapeBooks], 1);
      expect(e.itemsByStage[LibraryCurateStage.scrapeGames], 2);
      expect(e.requestsByStage[LibraryCurateStage.scrapeGames], 2);
      mediaAssigned = false;
      final LibraryCurateEstimate none = await curator().estimate();
      expect(none.requestsByStage[LibraryCurateStage.scrapeGames], isNull);
      expect(none.itemsByStage[LibraryCurateStage.scrapeGames], 2);
    });

    test('按 ISBN 精确查到唯一一条：标题不一致也认', () async {
      facts.bookUnits = <LibraryCurateBookUnit>[
        single(vol('k1', 'scan_0001.pdf', isbn: '9784000000000')),
      ];
      bookFound['9784000000000'] = <Map<String, Object?>>[
        book('9784000000000', 'Real Title', source: 'openbd'),
      ];
      await curator().run(trigger: LibraryCurateTrigger.manual);
      expect(applyArgs.single['source'], 'openbd');
      expect(applyArgs.single['fields'], <String>['cover', 'author', 'title']);
    });
  });

  test('书名是文件名的判据', () {
    expect(looksLikeFileNameTitle('Some Book.epub'), isTrue);
    expect(looksLikeFileNameTitle('[作者] 書名 01'), isTrue);
    expect(looksLikeFileNameTitle('【xx】タイトル'), isTrue);
    expect(looksLikeFileNameTitle('普通の書名'), isFalse);
    expect(looksLikeFileNameTitle('Re:Zero 1'), isFalse);
  });

  test('游戏候选规则：同名每个源至多一条才认', () {
    final Map<String, Object?>? pick = pickStrongGameCandidate(
      'Air',
      <Map<String, Object?>>[
        <String, Object?>{'id': 'vndb:1', 'source': 'vndb', 'name': 'AIR'},
        <String, Object?>{'id': 'vndb:2', 'source': 'vndb', 'name': 'Air'},
      ],
    );
    expect(pick, isNull);
  });
}
