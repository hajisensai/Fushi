// AI 整理库的自动路径（spec docs/specs/2026-10-20-ai-library-organize-design.md §10.2）：
// 「导入后自动 AI 整理」开关（ai.library_organize_auto）真的决定发不发请求；亲手打开即
// 同意（副标题就是完整说明），同意被撤回就不发；只看开关打开之后新入库的条目（打开开关不会把整个库发给 AI）；跑过一次后
// 只看那之后的新条目。
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/collections/library_organize_runner.dart';
import 'package:fushi/src/models/preferences_repository.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late PreferencesRepository prefs;
  late List<String> prompts;

  AiChatClient fakeAi() => AiChatClient(
    client: MockClient((http.Request request) async {
      final Map<String, Object?> body =
          jsonDecode(request.body) as Map<String, Object?>;
      final String user =
          ((body['messages']! as List<Object?>).last!
                  as Map<String, Object?>)['content']!
              as String;
      prompts.add(user);
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
                    if (all.length >= 2)
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

  Future<void> book(String title) async {
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

  Future<void> later() => Future<void>.delayed(const Duration(milliseconds: 5));

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    await prefs.setAiProviders(<AiProviderConfig>[_provider()]);
    await prefs.setAiFeatureAssignments(
      const AiFeatureAssignments().withAssignment(
        AiFeature.libraryOrganize,
        'p1',
      ),
    );
    prompts = <String>[];
    installLibraryOrganizeAutomatic(
      LibraryOrganizeAutoHost(
        db: db,
        prefs: prefs,
        nameLanguage: () => 'ja',
        clientFactory: fakeAi,
      ),
    );
  });

  tearDown(() async {
    installLibraryOrganizeAutomatic(null);
    await db.close();
  });

  test('开关关着：不排队、不发请求', () async {
    await prefs.setLibraryOrganizeConsented(true);
    await book('a');
    scheduleAutomaticLibraryOrganize(CollectionShelfDomain.books);
    expect(debugLibraryOrganizeAutoScheduled, isFalse);
    expect(
      await runAutomaticLibraryOrganize(CollectionShelfDomain.books),
      isNull,
    );
    expect(prompts, isEmpty);
  });

  test('亲手打开即记为同意；同意被撤回（如恢复了别处的偏好）就不发请求', () async {
    await prefs.setLibraryOrganizeAuto(true);
    expect(prefs.libraryOrganizeConsented, isTrue);
    await prefs.setLibraryOrganizeConsented(false);
    await later();
    await book('a');
    await book('b');
    expect(
      await runAutomaticLibraryOrganize(CollectionShelfDomain.books),
      isNull,
    );
    expect(prompts, isEmpty);
  });

  test('只看打开之后新入库的；跑过一次后只看那之后的', () async {
    await book('old-1');
    await book('old-2');
    await later();
    await prefs.setLibraryOrganizeConsented(true);
    await prefs.setLibraryOrganizeAuto(true);
    scheduleAutomaticLibraryOrganize(CollectionShelfDomain.books);
    expect(debugLibraryOrganizeAutoScheduled, isTrue);
    expect(
      await runAutomaticLibraryOrganize(CollectionShelfDomain.books),
      isNull,
      reason: '打开开关前的书不发给 AI',
    );
    await later();
    await book('new-1');
    await book('new-2');
    final LibraryOrganizeResult? first = await runAutomaticLibraryOrganize(
      CollectionShelfDomain.books,
    );
    expect(first, isNotNull);
    expect(first!.status, LibraryOrganizeStatus.done);
    expect(prompts.single, contains('new-1'));
    expect(prompts.single, isNot(contains('old-1')));
    expect(await db.getMediaCollectionByNaturalKey('S', 'playlist'), isNotNull);
    expect(
      await runAutomaticLibraryOrganize(CollectionShelfDomain.books),
      isNull,
      reason: '上次自动整理之后没有新书',
    );
    expect(prompts, hasLength(1));
  });
}
