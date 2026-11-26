import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/links/media_link_entries.dart';
import 'package:fushi/src/media/links/media_links_section.dart';
import 'package:fushi/src/media/links/work_graph_store.dart';
import 'package:fushi/src/media/links/work_plans.dart';
import 'package:fushi/src/media/links/work_kinds_badge.dart';
import 'package:fushi/src/pages/implementations/work_network_page.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import 'work_links_test_seed.dart';

/// 「同一作品」区块列整部作品（AI 库管家 spec §4.3）+ 卡片角标。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;

  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    WorkGraphStore.debounce = Duration.zero;
  });

  tearDown(() async {
    WorkGraphStore.debounce = const Duration(milliseconds: 400);
    await db.close();
  });

  Widget buildSection(MediaLinkEndpoint self) => TranslationProvider(
    child: MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: MediaLinksSection(
            database: db,
            self: self,
            onOpen: (MediaLinkEntry _) {},
          ),
        ),
      ),
    ),
  );

  Finder card(String key) =>
      find.byKey(ValueKey<String>('media-link-card-$key'));

  testWidgets('从动画看：小说三卷折成一张合集卡、漫画另一组、OP 进附属组，带关系网入口', (
    WidgetTester tester,
  ) async {
    final WorkLinksSeed seed = (await tester.runAsync(
      () => WorkLinksSeed.create(db),
    ))!;
    await tester.pumpWidget(buildSection(seed.anime));
    await tester.pumpAndSettle();

    final String series = 'series-${seed.novelSeriesId}';
    expect(card(series), findsOneWidget);
    expect(
      find.descendant(of: card(series), matching: find.text('某小说系列')),
      findsOneWidget,
      reason: '合集卡取合集名',
    );
    expect(
      find.descendant(of: card(series), matching: find.text('原作')),
      findsOneWidget,
      reason: '第 1 卷直接连到本条目（原作）',
    );
    for (final String vol in <String>['某小说 1', '某小说 2', '某小说 3']) {
      expect(find.text(vol), findsNothing, reason: '各卷不铺成单卡');
    }
    expect(card('book-m1'), findsOneWidget);
    expect(card('music_track-t1'), findsOneWidget);
    expect(find.text('小说'), findsOneWidget);
    expect(find.text('漫画'), findsOneWidget);
    expect(find.text('主题曲 · 原声 · 配音'), findsOneWidget);
    expect(
      card('video_collection-${collectionTagEntryKey(seed.animeId)}'),
      findsNothing,
      reason: '本条目自己不列出',
    );
    expect(
      find.byKey(const ValueKey<String>('media-link-network')),
      findsOneWidget,
    );
    expect(find.text('可能相关'), findsOneWidget, reason: '建议照旧可确认 / 否决');
  });

  testWidgets('从第 2 卷看：所在合集不重复列出，动画与漫画照列', (WidgetTester tester) async {
    final WorkLinksSeed seed = (await tester.runAsync(
      () => WorkLinksSeed.create(db),
    ))!;
    await tester.pumpWidget(buildSection(WorkLinksSeed.vol2));
    await tester.pumpAndSettle();

    expect(card('series-${seed.novelSeriesId}'), findsNothing);
    expect(
      card('video_collection-${collectionTagEntryKey(seed.animeId)}'),
      findsOneWidget,
    );
    expect(card('book-m1'), findsOneWidget);
    expect(
      find.descendant(
        of: card('video_collection-${collectionTagEntryKey(seed.animeId)}'),
        matching: find.text('视频合集'),
      ),
      findsOneWidget,
      reason: '不直接相连的成员副行取种类名',
    );
  });

  testWidgets('AI 直接生效的连接标「AI」并能一键移除（写墓碑）', (WidgetTester tester) async {
    const MediaLinkEndpoint book = (kind: MediaLinkKind.book, key: 'novel');
    await tester.runAsync(() async {
      await WorkLinksSeed.insertBook(db, 'novel', '某小说', uid: 'un');
      await db.applyAiMediaLink(
        relation: MediaLinkRelation.sameWork,
        from: book,
        to: (kind: MediaLinkKind.game, key: 'g'),
        source: MediaLinkSource.ai,
      );
    });
    await tester.pumpWidget(buildSection(book));
    await tester.pumpAndSettle();

    expect(card('game-g'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('media-link-ai-badge')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('media-link-ai-remove')),
    );
    await tester.pumpAndSettle();

    final MediaLinkRow row = (await tester.runAsync(
      () => db.mediaLinksForEndpoint(book.kind, book.key, includeRemoved: true),
    ))!.single;
    expect(mediaLinkStateOf(row), MediaLinkState.removed);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(card('game-g'), findsNothing);
  });

  testWidgets('误点「移除 AI 关联」后点提示条的撤销，原样恢复 AI 连接（反馈 bkrkQrYhnX）', (
    WidgetTester tester,
  ) async {
    const MediaLinkEndpoint book = (kind: MediaLinkKind.book, key: 'novel');
    await tester.runAsync(() async {
      await WorkLinksSeed.insertBook(db, 'novel', '某小说', uid: 'un');
      await db.applyAiMediaLink(
        relation: MediaLinkRelation.sameWork,
        from: book,
        to: (kind: MediaLinkKind.game, key: 'g'),
        source: MediaLinkSource.ai,
      );
    });
    await tester.pumpWidget(buildSection(book));
    await tester.pumpAndSettle();
    expect(card('game-g'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('media-link-ai-remove')),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.media_link_removed), findsOneWidget);
    final Finder undo = find.byKey(
      const ValueKey<String>('media-link-removed-undo'),
    );
    expect(undo, findsOneWidget, reason: '移除提示条必须带撤销');

    await tester.tap(undo);
    await tester.pumpAndSettle();
    final MediaLinkRow row = (await tester.runAsync(
      () => db.mediaLinksForEndpoint(book.kind, book.key, includeRemoved: true),
    ))!.single;
    expect(row.deletedAt, isNull, reason: '撤销清掉否决墓碑');
    expect(mediaLinkIsAiEffective(row), isTrue, reason: '恢复成 AI 生效，而不是用户确认');
    await tester.pump();
    await tester.pumpAndSettle();
    expect(card('game-g'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('media-link-ai-badge')),
      findsOneWidget,
    );
  });

  testWidgets('用户确认过的连接不标 AI', (WidgetTester tester) async {
    const MediaLinkEndpoint book = (kind: MediaLinkKind.book, key: 'novel');
    await tester.runAsync(() async {
      await WorkLinksSeed.insertBook(db, 'novel', '某小说', uid: 'un');
      await db.upsertManualMediaLink(
        relation: MediaLinkRelation.sameWork,
        from: book,
        to: (kind: MediaLinkKind.game, key: 'g'),
      );
    });
    await tester.pumpWidget(buildSection(book));
    await tester.pumpAndSettle();
    expect(card('game-g'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('media-link-ai-badge')),
      findsNothing,
    );
  });

  testWidgets('关系网入口推入关系网页', (WidgetTester tester) async {
    final WorkLinksSeed seed = (await tester.runAsync(
      () => WorkLinksSeed.create(db),
    ))!;
    await tester.pumpWidget(buildSection(seed.anime));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('media-link-network')));
    await tester.pumpAndSettle();
    expect(find.byType(WorkNetworkPage), findsOneWidget);
  });

  group('卡片角标', () {
    Widget buildBadge(Widget overlay) => TranslationProvider(
      child: MaterialApp(
        home: Scaffold(body: Center(child: overlay)),
      ),
    );

    const Widget cardBody = SizedBox(width: 120, height: 180);

    testWidgets('作品里有别的种类 → 出角标，tooltip / 语义列出种类，点了带本条目端点', (
      WidgetTester tester,
    ) async {
      await tester.runAsync(() => WorkLinksSeed.create(db));
      final List<MediaLinkEndpoint> opened = <MediaLinkEndpoint>[];
      await tester.pumpWidget(
        buildBadge(
          WorkKindsBadgeOverlay.entry(
            database: db,
            endpoint: WorkLinksSeed.vol2,
            onPressed: opened.add,
            child: cardBody,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('work-kinds-badge')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('另有：漫画 · 动画'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('work-kinds-badge')));
      expect(opened, <MediaLinkEndpoint>[WorkLinksSeed.vol2]);
    });

    testWidgets('系列合集卡：合集成员之外有别的种类才出；点了给合集代表卷', (WidgetTester tester) async {
      final WorkLinksSeed seed = (await tester.runAsync(
        () => WorkLinksSeed.create(db),
      ))!;
      final List<MediaLinkEndpoint> opened = <MediaLinkEndpoint>[];
      await tester.pumpWidget(
        buildBadge(
          WorkKindsBadgeOverlay.collection(
            database: db,
            collectionId: seed.novelSeriesId,
            onPressed: opened.add,
            child: cardBody,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('work-kinds-badge')));
      expect(opened, <MediaLinkEndpoint>[WorkLinksSeed.vol1]);
    });

    testWidgets('不是系列合集的视频合集：按合集端点本身算，点了给合集端点', (WidgetTester tester) async {
      final WorkLinksSeed seed = (await tester.runAsync(
        () => WorkLinksSeed.create(db),
      ))!;
      final List<MediaLinkEndpoint> opened = <MediaLinkEndpoint>[];
      await tester.pumpWidget(
        buildBadge(
          WorkKindsBadgeOverlay.collection(
            database: db,
            collectionId: seed.animeId,
            onPressed: opened.add,
            child: cardBody,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('另有：小说 · 漫画'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('work-kinds-badge')));
      expect(opened, <MediaLinkEndpoint>[seed.anime]);
    });

    testWidgets('只有同种媒体 / 多选态 → 不出角标', (WidgetTester tester) async {
      await tester.runAsync(() async {
        await WorkLinksSeed.insertBook(db, 'a', 'A', uid: 'ua');
        await WorkLinksSeed.insertBook(db, 'b', 'B', uid: 'ub');
        await db.upsertManualMediaLink(
          relation: MediaLinkRelation.sameWork,
          from: (kind: MediaLinkKind.book, key: 'a'),
          to: (kind: MediaLinkKind.book, key: 'b'),
        );
        await WorkLinksSeed.create(db);
      });
      await tester.pumpWidget(
        buildBadge(
          Column(
            children: <Widget>[
              WorkKindsBadgeOverlay.entry(
                database: db,
                endpoint: (kind: MediaLinkKind.book, key: 'a'),
                onPressed: (_) {},
                child: cardBody,
              ),
              WorkKindsBadgeOverlay.entry(
                database: db,
                endpoint: WorkLinksSeed.vol2,
                enabled: false,
                onPressed: (_) {},
                child: cardBody,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('work-kinds-badge')),
        findsNothing,
      );
    });
  });
}
