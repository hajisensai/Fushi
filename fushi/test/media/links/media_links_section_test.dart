import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/links/media_link_entries.dart';
import 'package:fushi/src/media/links/media_links_section.dart';
import 'package:fushi/src/media/links/work_graph_store.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

/// 详情页「同一作品」区块（作品图谱 L0 + L1 建议卡）。
///
/// 钉五件事：
/// ① 只有已确认的连接进「同一作品」行，建议进「可能相关」行；
/// ② 本地存在的条目点了走 onOpen（带端点）；
/// ③ 本地不存在的端点是「未入库」灰卡，点了不走 onOpen；
/// ④ 建议卡「确认」/「不相关」真写穿 DB（确认 → 已确认，不相关 → 墓碑）；
/// ⑤ 表变更（别处写入）后区块自己刷新。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late int animeId;
  const MediaLinkEndpoint book = (kind: MediaLinkKind.book, key: 'novel');

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    // 作品图缓存的去抖计时器在测试里立即到点（不留悬空计时器）。
    WorkGraphStore.debounce = Duration.zero;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    animeId = await db.createMediaCollection('某动画');
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'novel',
        title: '某小说',
        epubPath: '/tmp/novel.epub',
        extractDir: '/tmp/novel',
        chapterCount: 1,
        chaptersJson: '["ch1"]',
        importedAt: 0,
      ),
    );
  });

  tearDown(() async {
    WorkGraphStore.debounce = const Duration(milliseconds: 400);
    await db.close();
  });

  Widget buildApp({void Function(MediaLinkEntry)? onOpen}) =>
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MediaLinksSection(
                database: db,
                self: book,
                onOpen: onOpen ?? (MediaLinkEntry _) {},
              ),
            ),
          ),
        ),
      );

  testWidgets('已确认进「同一作品」，点卡片走 onOpen；未入库是灰卡不可点', (WidgetTester tester) async {
    await db.upsertManualMediaLink(
      relation: MediaLinkRelation.adaptation,
      from: book,
      to: (
        kind: MediaLinkKind.videoCollection,
        key: collectionTagEntryKey(animeId),
      ),
    );
    await db.upsertManualMediaLink(
      relation: MediaLinkRelation.sameWork,
      from: book,
      to: (kind: MediaLinkKind.game, key: 'missing-game'),
    );
    MediaLinkEntry? opened;
    await tester.pumpWidget(buildApp(onOpen: (MediaLinkEntry e) => opened = e));
    await tester.pumpAndSettle();

    expect(find.text('同一作品'), findsWidgets);
    expect(find.text('某动画'), findsOneWidget);
    // 关系与「未入库」不再压在封面上，进封面下的副行（`关系 · 状态`）。
    final Finder animeCard = find.byKey(
      ValueKey<String>(
        'media-link-card-video_collection-${collectionTagEntryKey(animeId)}',
      ),
    );
    final Finder missingCard = find.byKey(
      const ValueKey<String>('media-link-card-game-missing-game'),
    );
    expect(
      find.descendant(of: animeCard, matching: find.text('改编作')),
      findsOneWidget,
      reason: '本条是原作 → 对端副行「改编作」，已入库不带状态',
    );
    expect(
      find.descendant(of: missingCard, matching: find.text('同一作品 · 未入库')),
      findsOneWidget,
      reason: '未入库端点的副行 = 关系 · 未入库',
    );
    expect(
      find.descendant(of: missingCard, matching: find.byType(ColorFiltered)),
      findsOneWidget,
      reason: '未入库是去饱和灰卡',
    );
    expect(
      tester
          .widget<ColorFiltered>(
            find.descendant(
              of: missingCard,
              matching: find.byType(ColorFiltered),
            ),
          )
          .colorFilter,
      mediaLinkMissingCoverFilter,
      reason: '灰卡走保 alpha 的亮度矩阵（BUG-5457）',
    );
    expect(
      find.descendant(of: animeCard, matching: find.byType(ColorFiltered)),
      findsNothing,
      reason: '已入库卡不灰化',
    );
    expect(find.textContaining('未入库'), findsOneWidget);
    expect(find.text('可能相关'), findsNothing);

    await tester.tap(find.text('missing-game'));
    await tester.pumpAndSettle();
    expect(opened, isNull, reason: '未入库灰卡不可点');

    await tester.tap(find.text('某动画'));
    await tester.pumpAndSettle();
    expect(opened?.endpoint.kind, MediaLinkKind.videoCollection);
    expect(opened?.endpoint.key, collectionTagEntryKey(animeId));
  });

  // BUG-5457：封面材质的烘焙纹理四周有给投影留的透明外扩区。混合模式去饱和
  // （BlendMode.saturation）把透明像素涂成滤镜色，灰卡背后多出一整块灰板；亮度
  // 矩阵只改 RGB，透明处仍透明。这里直接读像素：同一棵树，换旧滤镜做对照。
  testWidgets('灰卡滤镜不把透明像素涂成灰板', (WidgetTester tester) async {
    Future<({int cornerAlpha, List<int> centre})> render(
      ColorFilter filter,
    ) async {
      final GlobalKey boundary = GlobalKey();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: RepaintBoundary(
              key: boundary,
              child: ColorFiltered(
                colorFilter: filter,
                child: const SizedBox(
                  width: 40,
                  height: 40,
                  child: Center(
                    child: SizedBox(
                      width: 10,
                      height: 10,
                      child: ColoredBox(color: Color(0xFFFF0000)),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final ByteData bytes = (await tester.runAsync<ByteData?>(() async {
        final RenderRepaintBoundary box =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final ui.Image image = await box.toImage();
        final ByteData? data = await image.toByteData();
        image.dispose();
        return data;
      }))!;
      int at(int x, int y, int channel) =>
          bytes.getUint8((y * 40 + x) * 4 + channel);
      return (
        cornerAlpha: at(1, 1, 3),
        centre: <int>[for (int c = 0; c < 4; c++) at(20, 20, c)],
      );
    }

    final ({int cornerAlpha, List<int> centre}) fixed = await render(
      mediaLinkMissingCoverFilter,
    );
    expect(fixed.cornerAlpha, 0, reason: '透明外扩区仍透明');
    expect(fixed.centre[3], 255);
    expect(fixed.centre[0], fixed.centre[1], reason: '封面本体去饱和成灰');
    expect(fixed.centre[1], fixed.centre[2]);

    final ({int cornerAlpha, List<int> centre}) old = await render(
      const ColorFilter.mode(Colors.grey, BlendMode.saturation),
    );
    expect(old.cornerAlpha, greaterThan(0), reason: '对照：旧滤镜把透明处涂成灰');
  });

  testWidgets('建议卡：确认写成已确认，不相关写墓碑', (WidgetTester tester) async {
    await db.proposeMediaLink(
      relation: MediaLinkRelation.adaptation,
      from: book,
      to: (
        kind: MediaLinkKind.videoCollection,
        key: collectionTagEntryKey(animeId),
      ),
      source: MediaLinkSource.mal,
      confidence: 0.6,
      reason: 'MAL lists the novel as the source',
    );
    await db.proposeMediaLink(
      relation: MediaLinkRelation.sameWork,
      from: book,
      to: (kind: MediaLinkKind.game, key: 'g'),
      source: MediaLinkSource.ai,
      confidence: 0.5,
      reason: 'same title',
    );
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(find.text('可能相关'), findsOneWidget);
    expect(find.text('MAL lists the novel as the source'), findsOneWidget);
    expect(
      find.byKey(
        ValueKey<String>(
          'media-link-card-video_collection-${collectionTagEntryKey(animeId)}',
        ),
      ),
      findsNothing,
      reason: '建议不进「同一作品」行',
    );

    final Finder animeSuggestion = find.byKey(
      ValueKey<String>(
        'media-link-suggestion-video_collection-'
        '${collectionTagEntryKey(animeId)}',
      ),
    );
    await tester.tap(
      find.descendant(
        of: animeSuggestion,
        matching: find.byKey(
          const ValueKey<String>('media-link-suggestion-confirm'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final Finder gameSuggestion = find.byKey(
      const ValueKey<String>('media-link-suggestion-game-g'),
    );
    await tester.tap(
      find.descendant(
        of: gameSuggestion,
        matching: find.byKey(
          const ValueKey<String>('media-link-suggestion-reject'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final List<MediaLinkRow> rows =
        await tester.runAsync(
          () => db.mediaLinksForEndpoint(
            book.kind,
            book.key,
            includeRemoved: true,
          ),
        ) ??
        const <MediaLinkRow>[];
    final MediaLinkRow anime = rows.firstWhere(
      (MediaLinkRow r) => r.toKind == 'video_collection',
    );
    final MediaLinkRow game = rows.firstWhere(
      (MediaLinkRow r) => r.toKind == 'game',
    );
    expect(mediaLinkStateOf(anime), MediaLinkState.confirmed);
    expect(mediaLinkStateOf(game), MediaLinkState.removed);

    // ⑤ 表变更后区块自己刷新：确认的那条进了「同一作品」行，建议行消失。
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        ValueKey<String>(
          'media-link-card-video_collection-${collectionTagEntryKey(animeId)}',
        ),
      ),
      findsOneWidget,
    );
    expect(find.text('可能相关'), findsNothing);
  });
}
