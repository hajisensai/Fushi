import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/links/media_link_entries.dart';
import 'package:fushi/src/media/links/media_links_section.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

/// 「同一作品」区块下的原作进度卡（作品图谱 L5 §6）：已确认的书 → 视频改编连接才出卡；
/// 编辑框添加对应点真写穿 DB，卡片随表变更刷新。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late int animeId;
  const MediaLinkEndpoint book = (kind: MediaLinkKind.book, key: 'novel');

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    animeId = await db.createMediaCollection('某动画');
  });

  tearDown(() => db.close());

  Future<void> pumpSection(WidgetTester tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MediaLinksSection(
                database: db,
                self: book,
                onOpen: (MediaLinkEntry _) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('没有改编连接不出卡；同作品连接也不出卡', (WidgetTester tester) async {
    await db.upsertManualMediaLink(
      relation: MediaLinkRelation.sameWork,
      from: book,
      to: (kind: MediaLinkKind.game, key: 'g'),
    );
    await pumpSection(tester);
    expect(
      find.byKey(const ValueKey<String>('adaptation-progress-section')),
      findsNothing,
    );
  });

  testWidgets('书 → 动画改编：出卡，编辑框添加对应点写穿 DB', (WidgetTester tester) async {
    await db.upsertManualMediaLink(
      relation: MediaLinkRelation.adaptation,
      from: book,
      to: (
        kind: MediaLinkKind.videoCollection,
        key: collectionTagEntryKey(animeId),
      ),
    );
    await pumpSection(tester);
    expect(
      find.byKey(const ValueKey<String>('adaptation-progress-section')),
      findsOneWidget,
    );
    expect(find.textContaining('还没有对应点'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('adaptation-progress-edit')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('adaptation-anchor-episode')),
      '13',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('adaptation-anchor-number')),
      '4',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('adaptation-anchor-add')),
    );
    await tester.pumpAndSettle();

    final List<AdaptationProgressAnchorRow> rows = await db
        .adaptationProgressAnchorsFor((
          sourceKind: 'book',
          sourceKey: 'novel',
          adaptationKind: 'video_collection',
          adaptationKey: collectionTagEntryKey(animeId),
        ));
    expect(rows.single.episodeNumber, 13);
    expect(rows.single.sourceNumber, 4);
    expect(rows.single.sourceUnit, 'volume');
    expect(
      find.byKey(const ValueKey<String>('adaptation-anchor-13')),
      findsOneWidget,
    );
    expect(find.text('按字幕与原文自动推断：暂未支持。'), findsOneWidget);
  });
}
