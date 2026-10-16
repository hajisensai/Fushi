import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/collections/collection_episode_slot.dart';
import 'package:fushi/src/media/collections/collection_one_key_sort.dart'
    show collectionDetailSortPrefKey, kCollectionDetailManualSortValue;
import 'package:fushi/src/pages/implementations/media_collection_detail_page.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:fushi_engine/ai/web_knowledge.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

class _Settings implements AiSettingsSource {
  _Settings({required this.assigned});

  final bool assigned;

  @override
  AiFeatureAssignments get aiFeatureAssignments => assigned
      ? const AiFeatureAssignments().withAssignment(
          AiFeature.collectionOrder,
          'p1',
        )
      : const AiFeatureAssignments();

  @override
  List<AiProviderConfig> get aiProviders => <AiProviderConfig>[
    AiProviderConfig(
      id: 'p1',
      presetId: 'openai',
      name: 'Fake',
      baseUrl: Uri.parse('https://example.invalid/v1'),
      apiKey: 'k',
      model: 'm',
    ),
  ];

  @override
  List<WebKnowledgeSite> get aiWebKnowledgeSites => const <WebKnowledgeSite>[];
}

/// 视频合集详情页「排序」菜单的「AI 排序」：AI 模块关（调用方传 null）不出现；
/// 没指派提供商点了只引导、不发请求；指派了 → SP 按 AI 落位并真写穿 sortIndex、
/// 偏好切 manual。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late int collectionId;
  late int requests;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    requests = 0;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    collectionId = await db.createMediaCollection(
      'Show',
      collectionType: 'playlist',
    );
    for (final (String uid, String file) in <(String, String)>[
      ('video/e1', '[Grp] Show - 01 [1080p].mkv'),
      ('video/e2', '[Grp] Show - 02 [1080p].mkv'),
      ('video/sp', '[Grp] Show - SP [1080p].mkv'),
    ]) {
      await db.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: Value<String>(uid),
          title: Value<String>(file),
          videoPath: Value<String>('/abs/$file'),
        ),
      );
      await db.addToCollection(collectionId, MediaKind.video, uid);
    }
  });

  tearDown(() => db.close());

  AiChatClient fakeAi() => AiChatClient(
    client: MockClient((http.Request request) async {
      requests++;
      return http.Response(
        jsonEncode(<String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              // 规则序 e1, e2, sp；SP 放到第 1 集之后。
              'message': <String, Object?>{'content': '{"order": [0, 2, 1]}'},
            },
          ],
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    }),
  );

  Future<List<String>> persistedOrder() async => <String>[
    for (final MediaCollectionItemRow it in await db.getCollectionItems(
      collectionId,
    ))
      it.entryKey,
  ];

  Widget buildApp(AiSettingsSource? settings) => TranslationProvider(
    child: MaterialApp(
      home: MediaCollectionDetailPage(
        database: db,
        collection: MediaCollectionRow(
          id: collectionId,
          name: 'Show',
          collectionType: 'playlist',
          coverSource: null,
          sortOrder: 0,
          createdAt: 0,
          orderUpdatedAt: 0,
        ),
        loadEpisodes: () async => <CollectionEpisodeSlot>[
          for (final MediaCollectionItemRow it in await db.getCollectionItems(
            collectionId,
          ))
            if (await db.getVideoBookByBookUid(it.entryKey)
                case final VideoBookRow row)
              CollectionEpisodeSlot.local(row),
        ],
        onOpenEpisode: (VideoBookRow _) {},
        onChanged: () {},
        collectionAiSettings: settings,
        aiClientFactory: fakeAi,
      ),
    ),
  );

  Future<void> openSortMenu(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
  }

  final Finder aiItem = find.byKey(
    const ValueKey<String>('collection_detail_sort_ai'),
  );

  testWidgets('AI 模块关（不传指派来源）：菜单里没有「AI 排序」', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp(null));
    await tester.pumpAndSettle();
    await openSortMenu(tester);
    expect(find.text(t.collection_sort_by_title), findsWidgets);
    expect(aiItem, findsNothing);
  });

  testWidgets('没指派提供商：点了不发请求、顺序不变', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp(_Settings(assigned: false)));
    await tester.pumpAndSettle();
    await openSortMenu(tester);
    expect(aiItem, findsOneWidget);
    await tester.tap(aiItem);
    await tester.pumpAndSettle();
    expect(requests, 0);
    expect(await persistedOrder(), <String>[
      'video/e1',
      'video/e2',
      'video/sp',
    ]);
  });

  testWidgets('指派了提供商：SP 按 AI 落到第 1 集后，真写穿 sortIndex 并切 manual', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(buildApp(_Settings(assigned: true)));
    await tester.pumpAndSettle();
    await openSortMenu(tester);
    await tester.tap(aiItem);
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(await persistedOrder(), <String>[
      'video/e1',
      'video/sp',
      'video/e2',
    ]);
    expect(
      await db.getPref(collectionDetailSortPrefKey(collectionId)),
      kCollectionDetailManualSortValue,
    );
  });
}
