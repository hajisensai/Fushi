import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/media_collection_detail_page.dart';
import 'package:hibiki_core/hibiki_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HibikiDatabase database;
  late int collectionId;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    database = HibikiDatabase.forTesting(NativeDatabase.memory());
    await database.upsertVideoBook(
      const VideoBooksCompanion(
        bookUid: Value<String>('show-e1'),
        title: Value<String>('Show S01E01'),
        videoPath: Value<String>('D:/Show/Show S01E01.mkv'),
      ),
    );
    collectionId = await database.createMediaCollection(
      'Show',
      collectionType: 'playlist',
    );
    await database.addToCollection(
      collectionId,
      MediaKind.video,
      'show-e1',
    );
  });

  tearDown(() => database.close());

  Future<List<VideoBookRow>> loadMembers() async => <VideoBookRow>[
        (await database.getVideoBookByBookUid('show-e1'))!,
      ];

  Widget buildApp() => TranslationProvider(
        child: MaterialApp(
          home: MediaCollectionDetailPage(
            database: database,
            collection: MediaCollectionRow(
              id: collectionId,
              name: 'Show',
              collectionType: 'playlist',
              coverSource: null,
              sortOrder: 0,
              createdAt: 0,
              orderUpdatedAt: 0,
            ),
            loadMembers: loadMembers,
            onOpenEpisode: (_) {},
            onChanged: () {},
          ),
        ),
      );

  Future<void> pumpWide(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
  }

  testWidgets('v69 作品人物在 hero 紧凑展示姓名与角色', (WidgetTester tester) async {
    final int workId = await database.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        collectionId: Value<int?>(collectionId),
        mediaType: 'tv',
        title: 'Show',
        updatedAt: 1,
      ),
    );
    await database.upsertVideoMetadataPeople(<VideoMetadataPeopleCompanion>[
      VideoMetadataPeopleCompanion.insert(
        personKey: 'director',
        name: 'Director Name',
        updatedAt: 1,
      ),
      VideoMetadataPeopleCompanion.insert(
        personKey: 'actor',
        name: 'Actor Name',
        updatedAt: 1,
      ),
      VideoMetadataPeopleCompanion.insert(
        personKey: 'voice',
        name: 'Voice Name',
        updatedAt: 1,
      ),
      VideoMetadataPeopleCompanion.insert(
        personKey: 'writer',
        name: 'Writer Name',
        updatedAt: 1,
      ),
    ]);
    await database
        .upsertVideoMetadataCharacters(<VideoMetadataCharactersCompanion>[
      VideoMetadataCharactersCompanion.insert(
        characterKey: 'hero',
        name: 'Hero',
        updatedAt: 1,
      ),
    ]);
    await database.replaceVideoMetadataCredits(
      workId: workId,
      credits: <VideoMetadataCreditsCompanion>[
        VideoMetadataCreditsCompanion.insert(
          personKey: 'director',
          creditKind: 'director',
          sortOrder: const Value<int>(0),
        ),
        VideoMetadataCreditsCompanion.insert(
          personKey: 'actor',
          characterKey: const Value<String?>('hero'),
          creditKind: 'actor',
          roleName: const Value<String>('Hero'),
          sortOrder: const Value<int>(1),
        ),
        VideoMetadataCreditsCompanion.insert(
          personKey: 'voice',
          characterKey: const Value<String?>('hero'),
          creditKind: 'voice_actor',
          roleName: const Value<String>('Hero'),
          sortOrder: const Value<int>(2),
        ),
        VideoMetadataCreditsCompanion.insert(
          personKey: 'writer',
          creditKind: 'writer',
          sortOrder: const Value<int>(3),
        ),
      ],
    );

    await pumpWide(tester);

    final Finder heroCredits =
        find.byKey(const ValueKey<String>('collection-hero-credits'));
    expect(heroCredits, findsOneWidget);
    expect(
      find.descendant(of: heroCredits, matching: find.text('Director Name')),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: heroCredits, matching: find.text('Actor Name · Hero')),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: heroCredits, matching: find.text('Voice Name · Hero')),
      findsOneWidget,
    );
    expect(find.descendant(of: heroCredits, matching: find.text('Writer Name')),
        findsNothing,
        reason: 'hero 只展示计划要求的导演、演员和声优');
    expect(
      find.descendant(
          of: heroCredits,
          matching: find.byIcon(Icons.movie_creation_outlined)),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: heroCredits, matching: find.byIcon(Icons.person_outline)),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: heroCredits,
          matching: find.byIcon(Icons.record_voice_over_outlined)),
      findsOneWidget,
    );
  });

  testWidgets('无 v69 作品人物时保留旧详情页回退', (WidgetTester tester) async {
    await pumpWide(tester);

    expect(
      find.byKey(const ValueKey<String>('collection-hero-credits')),
      findsNothing,
    );
    expect(find.text('Show'), findsWidgets);
    expect(find.textContaining('已看完'), findsWidgets);
  });

  testWidgets('v69 作品简介与规范分集标题直接回填详情页', (WidgetTester tester) async {
    final int workId = await database.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        collectionId: Value<int?>(collectionId),
        mediaType: 'tv',
        title: '无职转生 ～到了异世界就拿出真本事～',
        originalTitle: const Value<String?>('無職転生'),
        overview: const Value<String?>('一名家里蹲转生到剑与魔法世界后的故事。'),
        year: const Value<int?>(2021),
        rating: const Value<double?>(8.4),
        updatedAt: 1,
      ),
    );
    final int seasonId = await database.upsertVideoMetadataSeason(
      VideoMetadataSeasonsCompanion.insert(
        workId: workId,
        seasonNumber: 1,
        title: const Value<String?>('第 1 季'),
        updatedAt: 1,
      ),
    );
    await database.upsertVideoMetadataEpisode(
      VideoMetadataEpisodesCompanion.insert(
        seasonId: seasonId,
        bookUid: const Value<String?>('show-e1'),
        episodeNumber: 1,
        title: const Value<String?>('无职者的转生'),
        overview: const Value<String?>('鲁迪乌斯开始了新的人生。'),
        updatedAt: 1,
      ),
    );

    await pumpWide(tester);

    expect(find.text('无职转生 ～到了异世界就拿出真本事～'), findsOneWidget);
    expect(find.textContaining('一名家里蹲转生到剑与魔法世界'), findsWidgets);
    expect(find.text('1. 无职者的转生'), findsOneWidget);
    expect(find.text('1. Show S01E01'), findsNothing);
  });
}
