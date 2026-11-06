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
import 'package:fushi_engine/ai/ai_provider_config.dart';
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
}
