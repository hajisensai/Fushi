// AI 管库 v3（docs/specs/2026-11-22-ai-library-agent-design.md §3.2 / §3.3 / §3.5）：
// 宿主路由把整库地图与变更集原样接到引擎；变更集以 AI 身份落库、撤销载荷能把库
// 退回原样；长程技能先进长程模式再读概况。
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ai/agent/ai_agent_library_skill.dart';
import 'package:fushi/src/ops/ctl_library_agent_routes.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:fushi_engine/media/library_agent/library_changeset.dart';

class _SkillContext implements AgentSkillContext {
  final List<String> events = <String>[];
  List<String> longTaskTools = const <String>[];

  @override
  bool get cancelled => false;

  @override
  void beginLongTask({required Iterable<String> tools, int? maxToolCalls}) {
    events.add('beginLongTask');
    longTaskTools = tools.toList();
  }

  @override
  Future<AgentToolResult> call(
    String toolId,
    Map<String, Object?> args, {
    bool userChoseThisStep = false,
  }) async {
    events.add('$toolId ${jsonEncode(args)}');
    return const AgentToolResult.ok(<String, Object?>{'works': 0});
  }

  @override
  Future<String?> askChoice(
    String prompt,
    List<AgentChoiceOption> options,
  ) async => null;
}

void main() {
  late FushiDatabase db;
  late List<CtlRoute> routes;
  bool readonly = false;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    readonly = false;
    routes = buildLibraryAgentCtlRoutesFor(
      database: () => db,
      isReadonly: () => readonly,
    );
  });
  tearDown(() => db.close());

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

  Future<String> book(String title) async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: title,
        title: title,
        epubPath: '/m/$title',
        extractDir: '/m/$title',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1,
        format: const Value<String>('epub'),
      ),
    );
    return (await db.resolveEpubBookUid(title))!;
  }

  Future<Set<String>> members(int collectionId) async => <String>{
    for (final MediaCollectionItemRow i in await db.getCollectionItems(
      collectionId,
    ))
      i.entryKey,
  };

  test('地图：summary 与书架视图走引擎，参数不对报 400', () async {
    final String a = await book('涼宮ハルヒの憂鬱');
    final int c = await db.createMediaCollection('混在一起');
    await db.addToCollection(c, MediaKind.epub, a);

    final Map<String, Object?> summary =
        (await call('GET', '$kLibraryAgentCtlRoot/map'))!
            as Map<String, Object?>;
    expect(summary['view'], 'summary');

    final Map<String, Object?> books =
        (await call(
              'GET',
              '$kLibraryAgentCtlRoot/map',
              body: const <String, Object?>{'view': 'books'},
            ))!
            as Map<String, Object?>;
    expect(jsonEncode(books), contains('C$c'));
    expect(jsonEncode(books), contains('涼宮ハルヒの憂鬱'));

    await expectLater(
      call(
        'GET',
        '$kLibraryAgentCtlRoot/map',
        body: const <String, Object?>{'view': 'nope'},
      ),
      throwsA(isA<CtlFailure>()),
    );
  });

  test('变更集：AI 身份移出用户合集，撤销载荷退回原样；dryRun 与只读', () async {
    final String a = await book('涼宮ハルヒの憂鬱');
    final String b = await book('とある魔術の禁書目録');
    final int c = await db.createMediaCollection('混在一起');
    await db.addToCollectionRaw(c, 'epub', a, userIntent: false);
    await db.addToCollectionRaw(c, 'epub', b, userIntent: false);
    final String originBefore = (await db.getMediaCollectionById(c))!.origin;

    final Map<String, Object?> changes = <String, Object?>{
      'changes': <Object?>[
        <String, Object?>{
          'op': 'move',
          'items': <String>['epub:$b'],
          'to': 'standalone',
          'why': '另一部作品',
        },
      ],
    };

    final Map<String, Object?> dry =
        (await call(
              'POST',
              '$kLibraryAgentCtlRoot/changes',
              body: <String, Object?>{...changes, 'dryRun': true},
            ))!
            as Map<String, Object?>;
    expect(dry['applied'], hasLength(1));
    expect(await members(c), <String>{a, b}, reason: 'dryRun 不写库');

    readonly = true;
    await expectLater(
      call('POST', '$kLibraryAgentCtlRoot/changes', body: changes),
      throwsA(isA<CtlFailure>()),
    );
    readonly = false;

    final Map<String, Object?> done =
        (await call('POST', '$kLibraryAgentCtlRoot/changes', body: changes))!
            as Map<String, Object?>;
    expect(done['skipped'], isEmpty);
    expect(await members(c), <String>{a});
    // AI 身份：被移出的成员不钉、合集来源不变。
    expect((await db.getMediaCollectionById(c))!.origin, originBefore);

    // 操作记录按 JSON 存撤销载荷。
    final Map<String, Object?> undo =
        (jsonDecode(jsonEncode(done['undo'])) as Map<Object?, Object?>)
            .cast<String, Object?>();
    expect(await undoLibraryChangeset(db, undo), greaterThan(0));
    expect(await members(c), <String>{a, b});
  });

  test('长程技能：先进长程模式装工具，再读整库概况，带工作方法', () async {
    final _SkillContext context = _SkillContext();
    final Object? result = await ReorganizeLibrarySkill().run(
      context,
      const <String, Object?>{'focus': '只看漫画'},
    );
    expect(context.events.first, 'beginLongTask');
    expect(
      context.longTaskTools,
      containsAll(<String>['library.map', 'library.changes.apply']),
    );
    expect(context.events[1], 'library.map {"view":"summary"}');
    final Map<Object?, Object?> map = result! as Map<Object?, Object?>;
    expect(map['focus'], '只看漫画');
    expect(map['method'], isNotEmpty);
  });
}
