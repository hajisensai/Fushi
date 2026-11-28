// AI 库管家的控制通道（spec docs/specs/2026-11-18-ai-library-curator-design.md §9）：
// run / estimate / status / runs / undo / pending 的形状与门；④ 步宿主操作的撤销回执
// 往返（AI 生效的连接退回写入前、建议删掉）；自动路径默认开、没指派 AI 不调度；
// AI 助手技能 skill.curate_library 已登记。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/agent/ai_agent_skills.dart';
import 'package:fushi/src/media/library_curate/library_curate_auto.dart';
import 'package:fushi/src/media/library_curate/library_curate_link_ops.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ops/ctl_library_curate_routes.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:fushi_engine/media/library_curate/library_curator.dart';
import 'package:fushi_engine/media/links/media_link_inference.dart';

/// 一个操作都没有的工具箱：编排器的每个写阶段都报 unavailable（这里只验路由）。
class _EmptyToolbox implements AgentToolbox {
  @override
  AgentToolSpec? describeTool(String name) => null;

  @override
  Future<AgentToolResult> execute(AgentToolInvocation invocation) async =>
      const AgentToolResult.error('unknown_tool');

  @override
  List<AgentToolSpec> residentTools() => const <AgentToolSpec>[];

  @override
  List<AgentToolSpec> searchTools(String query, {int limit = 12}) =>
      const <AgentToolSpec>[];

  @override
  Future<AgentUndoResult> undo(String actionId) async =>
      const AgentUndoResult(AgentUndoStatus.notUndoable);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late PreferencesRepository prefs;
  late LibraryCurator curator;
  late List<CtlRoute> routes;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    curator = LibraryCurator(
      db: db,
      toolbox: _EmptyToolbox(),
      store: MemoryLibraryCurateStore(),
      facts: DatabaseLibraryCurateFacts(db),
      ai: () => kLibraryCurateNoAi,
    );
    routes = buildLibraryCurateCtlRoutesFor(
      curator: () => curator,
      database: () => db,
      prefs: () => prefs,
      aiModuleEnabled: () => true,
      linkDeps: (_, _) => (
        deps: LibraryCurateLinkDeps(
          fetchMalSourceMaterial: (String id) async => const <Never>[],
          lookupWikidataAnime: (Iterable<String> ids) async =>
              const <String, Set<String>>{},
        ),
        close: () {},
      ),
    );
  });

  tearDown(() async {
    installLibraryCurateAutomatic(null);
    await db.close();
  });

  Future<Object?> call(
    String method,
    String path, {
    Map<String, Object?> body = const <String, Object?>{},
  }) {
    for (final CtlRoute route in routes) {
      if (route.method != method) continue;
      final Map<String, String>? params = route.match(path);
      if (params == null) continue;
      return route.handler(
        CtlCall(method: method, path: path, params: params, body: body),
      );
    }
    throw StateError('没有路由 $method $path');
  }

  // 用户 2026-11-26：「不要自动开，要问了用户才开」——两条自动路径默认都关，
  // 默认只有手动触发。
  test('偏好：库管家自动路径与 AI 助手自动复查默认关', () {
    expect(prefs.libraryCurateAuto, isFalse);
    expect(prefs.libraryAgentReviewAuto, isFalse);
  });

  test('run → runs / status / undo / pending；没指派 AI 不要求同意', () async {
    expect(prefs.libraryOrganizeConsented, isFalse);
    final Map<String, Object?> run =
        await call('POST', kLibraryCurateCtlRoot) as Map<String, Object?>;
    expect(run['trigger'], 'manual');
    final List<Object?> stages = run['stages']! as List<Object?>;
    expect(stages, hasLength(LibraryCurateStage.values.length));
    expect(<Object?>[
      for (final Object? s in stages)
        if ((s! as Map)['stage'] != 'works') (s as Map)['error'],
    ], everyElement(anyOf('unavailable', 'no_provider')));
    expect(prefs.libraryOrganizeConsented, isFalse);

    final Map<String, Object?> runs =
        await call('GET', '$kLibraryCurateCtlRoot/runs')
            as Map<String, Object?>;
    expect(
      (runs['runs']! as List<Object?>).single,
      isA<Map<Object?, Object?>>(),
    );

    final Map<String, Object?> status =
        await call('GET', '$kLibraryCurateCtlRoot/status')
            as Map<String, Object?>;
    expect(status['running'], isFalse);
    expect((status['last']! as Map)['id'], run['id']);
    expect(status['auto'], isFalse, reason: '自动路径默认关');

    final Map<String, Object?> undo =
        await call('POST', '$kLibraryCurateCtlRoot/runs/${run['id']}/undo')
            as Map<String, Object?>;
    expect(undo['undone'], 0);
    await expectLater(
      call('POST', '$kLibraryCurateCtlRoot/runs/x/undo'),
      throwsA(isA<CtlFailure>()),
    );

    final Map<String, Object?> pending =
        await call('GET', '$kLibraryCurateCtlRoot/pending')
            as Map<String, Object?>;
    expect(pending['organizeProposals'], isEmpty);
    expect(pending['items'], isEmpty);

    final Map<String, Object?> estimate =
        await call('GET', '$kLibraryCurateCtlRoot/estimate')
            as Map<String, Object?>;
    expect(estimate['requests'], 0);
  });

  // BUG-5283：待确认身份队列的「让 AI 重试」。
  test('scrape/retry：参数校验；记一趟只含该阶段、带 target 的运行', () async {
    await expectLater(
      call(
        'POST',
        '$kLibraryCurateCtlRoot/scrape/retry',
        body: const <String, Object?>{'stage': 'video', 'ref': 'x'},
      ),
      throwsA(isA<CtlFailure>()),
    );
    await expectLater(
      call(
        'POST',
        '$kLibraryCurateCtlRoot/scrape/retry',
        body: const <String, Object?>{'stage': 'books'},
      ),
      throwsA(isA<CtlFailure>()),
    );
    final Map<String, Object?> run =
        await call(
              'POST',
              '$kLibraryCurateCtlRoot/scrape/retry',
              body: const <String, Object?>{'stage': 'games', 'ref': 'game:1'},
            )
            as Map<String, Object?>;
    expect(run['trigger'], 'manual');
    expect(run['target'], 'game:1');
    expect(
      <Object?>[
        for (final Object? s in run['stages']! as List<Object?>)
          (s! as Map)['stage'],
      ],
      <Object?>['scrape.games'],
    );
  });

  test('wait=false：后台开跑立即返回运行 id', () async {
    final Map<String, Object?> r =
        await call(
              'POST',
              kLibraryCurateCtlRoot,
              body: const <String, Object?>{'wait': false},
            )
            as Map<String, Object?>;
    expect(r['status'], 'running');
    expect(r['runId'], isA<int>());
    while (curator.isRunning) {
      await Future<void>.delayed(Duration.zero);
    }
    expect((await curator.runs()).single.id, r['runId']);
  });

  test('links/infer 参数校验；links/music 空曲库什么都不写', () async {
    await expectLater(
      call('POST', '$kLibraryCurateCtlRoot/links/infer'),
      throwsA(isA<CtlFailure>()),
    );
    final Map<String, Object?> none =
        await call(
              'POST',
              '$kLibraryCurateCtlRoot/links/infer',
              body: const <String, Object?>{
                'items': <String>['book:nope'],
                'trigger': 'auto',
              },
            )
            as Map<String, Object?>;
    expect(none['writes'], isEmpty);
    expect(none['requests'], 0);
    final Map<String, Object?> music =
        await call('POST', '$kLibraryCurateCtlRoot/links/music')
            as Map<String, Object?>;
    expect(music['writes'], isEmpty);
    expect(
      libraryCurateLinkTrigger('auto'),
      MediaLinkInferenceTrigger.automatic,
    );
    expect(libraryCurateLinkTrigger(null), MediaLinkInferenceTrigger.manual);
  });

  test('撤销回执往返：AI 生效的连接经 JSON 回执撤回到写入前（之前没有 = 删掉）', () async {
    const MediaLinkEndpoint a = (kind: MediaLinkKind.book, key: 'a');
    const MediaLinkEndpoint b = (kind: MediaLinkKind.game, key: 'g');
    final MediaLinkAiWrite? w = await db.applyAiMediaLink(
      relation: MediaLinkRelation.sameWork,
      from: a,
      to: b,
      source: 'ai',
      confidence: 0.95,
    );
    expect(w, isNotNull);
    final LibraryCurateLinkResult result = LibraryCurateLinkResult()
      ..writes.add((id: w!.id, applied: true, previous: w.previous));
    final Map<String, Object?> json = result.toJson();
    expect(json['applied'], 1);
    final List<LibraryCurateLinkWrite> back = <LibraryCurateLinkWrite>[
      for (final Object? raw in json['writes']! as List<Object?>)
        ?libraryCurateLinkWriteFromJson(raw),
    ];
    expect(back.single.id, w.id);
    expect(await revertLibraryCurateLinkWrites(db, back), 1);
    final MediaLinkRow? row = await db.mediaLinkById(w.id);
    expect(row == null || row.deletedAt != null, isTrue);
    // 再撤一次：已经没了，什么都不做。
    expect(await revertLibraryCurateLinkWrites(db, back), 0);
  });

  test('自动路径：开关开着就接管旧自动整理的触发点；没指派任何 AI 不调度', () async {
    installLibraryCurateAutomatic(
      LibraryCurateAutoHost(
        settings: prefs,
        autoOn: () => prefs.libraryCurateAuto,
        aiModuleEnabled: () => true,
        curator: () => curator,
      ),
    );
    expect(libraryCurateAutoOwnsTriggers(), isFalse, reason: '默认关：不接管');
    await prefs.setLibraryCurateAuto(true);
    expect(libraryCurateAutoOwnsTriggers(), isTrue);
    scheduleAutomaticLibraryCurate();
    expect(debugLibraryCurateAutoScheduled, isFalse);
  });

  test('AI 助手技能 skill.curate_library 已登记，依赖库管家两条操作', () {
    final AiAgentAppSkill skill = buildAiAgentSkills().singleWhere(
      (AiAgentAppSkill s) => s.spec.name == 'skill.curate_library',
    );
    expect(skill.requiredOps, <String>[
      'library.curate.estimate',
      'library.curate.run',
    ]);
  });
}
