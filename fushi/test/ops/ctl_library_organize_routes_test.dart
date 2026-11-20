// 控制通道 `library organize` / `organize-history` / `organize-undo`（spec
// docs/specs/2026-10-20-ai-library-organize-design.md §10.1）：没指派提供商拒；界面里
// 没同意过时要 --yes，带了就记为同意；跑完能列出记录、能整次撤销。
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ops/ctl_library_organize_routes.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_library_organize_assistant.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_apply.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_plan.dart';
import 'package:fushi_engine/media/collections/library_organize/library_organize_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

AiProviderConfig _provider() => AiProviderConfig(
  id: 'p1',
  presetId: 'openai',
  name: 'Fake',
  baseUrl: Uri.parse('https://example.invalid/v1'),
  apiKey: 'k',
  model: 'm',
);

/// 假 AI：把收到的全部条目编成一组。
AiChatClient _groupEverything() => AiChatClient(
  client: MockClient((http.Request request) async {
    final Map<String, Object?> body =
        jsonDecode(request.body) as Map<String, Object?>;
    final String user =
        ((body['messages']! as List<Object?>).last!
                as Map<String, Object?>)['content']!
            as String;
    final List<int> all = <int>[
      for (final String line in const LineSplitter().convert(user))
        if (line.startsWith('{"i":'))
          (jsonDecode(line) as Map<String, Object?>)['i']! as int,
    ];
    return http.Response(
      jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{
              'content': jsonEncode(<String, Object?>{
                'groups': <Object?>[
                  <String, Object?>{
                    'members': all,
                    'name': 'S',
                    'originalTitle': 'S',
                    'confidence': 'high',
                  },
                ],
              }),
            },
          },
        ],
      }),
      200,
      headers: <String, String>{'content-type': 'application/json'},
    );
  }),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late PreferencesRepository prefs;
  late List<CtlRoute> routes;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    routes = buildLibraryOrganizeCtlRoutesFor(
      database: () => db,
      prefs: () => prefs,
      nameLanguage: () => 'ja',
      serviceOverride: () => LibraryOrganizeService(
        db: db,
        settings: prefs,
        nameLanguage: 'ja',
        videoTagPrefix: 'Series: ',
        clientFactory: _groupEverything,
      ),
    );
    for (final String title in <String>['a', 'b']) {
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
    }
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

  Future<void> assign() async {
    await prefs.setAiProviders(<AiProviderConfig>[_provider()]);
    await prefs.setAiFeatureAssignments(
      const AiFeatureAssignments().withAssignment(
        AiFeature.libraryOrganize,
        'p1',
      ),
    );
  }

  test('未知 domain 400；没指派提供商拒', () async {
    await expectLater(
      call(
        'POST',
        kLibraryOrganizeCtlRoot,
        body: <String, Object?>{'domain': 'music'},
      ),
      throwsA(isA<CtlFailure>()),
    );
    await expectLater(
      call(
        'POST',
        kLibraryOrganizeCtlRoot,
        body: <String, Object?>{'domain': 'books'},
      ),
      throwsA(isA<CtlFailure>()),
    );
    expect(await db.getAllMediaCollections(), isEmpty);
  });

  test('没同意过要 --yes；带了就记为同意并整理；记录可列出、可整次撤销', () async {
    await assign();
    await expectLater(
      call(
        'POST',
        kLibraryOrganizeCtlRoot,
        body: <String, Object?>{'domain': 'books'},
      ),
      throwsA(isA<CtlFailure>()),
    );
    expect(prefs.libraryOrganizeConsented, isFalse);
    final Map<String, Object?> result =
        (await call(
              'POST',
              kLibraryOrganizeCtlRoot,
              body: <String, Object?>{'domain': 'books', 'yes': true},
            ))!
            as Map<String, Object?>;
    expect(prefs.libraryOrganizeConsented, isTrue);
    expect(result['status'], 'done');
    expect(result['changes'], 1);
    expect(await db.getMediaCollectionByNaturalKey('S', 'playlist'), isNotNull);

    final Map<String, Object?> history =
        (await call('GET', '$kLibraryOrganizeCtlRoot/runs'))!
            as Map<String, Object?>;
    final List<Object?> runs = history['runs']! as List<Object?>;
    expect(runs, hasLength(1));
    final int runId = (runs.single! as Map<String, Object?>)['id']! as int;

    final Map<String, Object?> undo =
        (await call('POST', '$kLibraryOrganizeCtlRoot/runs/$runId/undo'))!
            as Map<String, Object?>;
    expect(undo['undone'], 1);
    expect(await db.getMediaCollectionByNaturalKey('S', 'playlist'), isNull);
  });

  test('待确认建议：列出、接受（以用户身份合并）、拒绝；已处理的 404', () async {
    final int one = await db.createMediaCollection('One');
    final int two = await db.createMediaCollection('Two');
    final int three = await db.createMediaCollection('Three');
    for (final (int id, String key) in <(int, String)>[
      (one, 'a'),
      (two, 'b'),
      (three, 'a'),
    ]) {
      await db.addToCollection(
        id,
        MediaKind.epub,
        (await db.resolveEpubBookUid(key))!,
      );
    }
    final int runId = await db
        .into(db.libraryOrganizeRuns)
        .insert(
          LibraryOrganizeRunsCompanion.insert(
            domain: 'books',
            trigger: 'manual',
            startedAt: 1,
            status: 'done',
          ),
        );
    await recordOrganizeProposals(
      db,
      runId: runId,
      proposals: <OrganizeProposal>[
        OrganizeProposal(
          kind: OrganizeProposalKind.merge,
          targetCollectionId: one,
          sourceCollectionIds: <int>[two],
          confidence: AiOrganizeConfidence.high,
        ),
        OrganizeProposal(
          kind: OrganizeProposalKind.rename,
          targetCollectionId: three,
          newName: 'Third',
          confidence: AiOrganizeConfidence.high,
          reason: 'r',
        ),
      ],
    );
    List<Map<String, Object?>> listOf(Object? r) => <Map<String, Object?>>[
      for (final Object? p
          in (r! as Map<String, Object?>)['proposals']! as List<Object?>)
        p! as Map<String, Object?>,
    ];
    final List<Map<String, Object?>> pending = listOf(
      await call('GET', '$kLibraryOrganizeCtlRoot/proposals'),
    );
    expect(pending, hasLength(2));
    final Map<String, Object?> merge = pending.firstWhere(
      (Map<String, Object?> p) => p['kind'] == 'merge',
    );
    final Map<String, Object?> rename = pending.firstWhere(
      (Map<String, Object?> p) => p['kind'] == 'rename',
    );
    expect(merge['sources'], <String>['Two']);
    expect(rename['newName'], 'Third');

    expect(
      await call(
        'POST',
        '$kLibraryOrganizeCtlRoot/proposals/${merge['id']}/accept',
      ),
      <String, Object?>{'id': merge['id'], 'state': 'accepted'},
    );
    expect(await db.getMediaCollectionById(two), isNull);
    expect(await db.getCollectionItems(one), hasLength(2));
    expect(
      await call(
        'POST',
        '$kLibraryOrganizeCtlRoot/proposals/${rename['id']}/reject',
      ),
      <String, Object?>{'id': rename['id'], 'state': 'rejected'},
    );
    expect((await db.getMediaCollectionById(three))!.name, 'Three');
    expect(
      listOf(await call('GET', '$kLibraryOrganizeCtlRoot/proposals')),
      isEmpty,
    );
    expect(
      listOf(
        await call(
          'GET',
          '$kLibraryOrganizeCtlRoot/proposals',
          body: <String, Object?>{'all': true},
        ),
      ),
      hasLength(2),
    );
    await expectLater(
      call('POST', '$kLibraryOrganizeCtlRoot/proposals/${merge['id']}/accept'),
      throwsA(isA<CtlFailure>()),
    );
  });
}
