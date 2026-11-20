import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/detail/item_scrape_detail.dart';
import 'package:fushi/src/media/detail/media_poster_detail.dart';
import 'package:fushi/src/pages/implementations/book_detail_page.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

/// 书 / 漫画 / 字幕书元数据详情页（2026-11-16 所有者「刮削的还得做个像视频一样的
/// 详情页展示元数据」）：与视频作品详情同一套海报面板。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  const String backdropPath = '/fixtures/book-backdrop.jpg';

  ItemScrapeMetaRow scrapedMeta() => const ItemScrapeMetaRow(
    mediaType: 'epub',
    entryKey: 'uid-1',
    source: 'bangumi',
    subjectId: '42',
    title: '魔女之旅',
    originalTitle: '魔女の旅々',
    summary: '旅人伊蕾娜周游诸国的故事。',
    airDate: '2016-11-15',
    rating: 7.8,
    ratingCount: 1234,
    tagsJson: '[{"name":"奇幻"},{"name":"冒险"},{"name":"轻小说"}]',
    detailUrl: 'https://bgm.tv/subject/42',
    scrapedAt: 1,
  );

  Future<void> pump(
    WidgetTester tester, {
    required ItemScrapeDetail detail,
    BookDetailSnapshot snapshot = const BookDetailSnapshot(
      title: '魔女之旅 1',
      author: '白石定规',
    ),
    Future<void> Function()? onOpen,
    Future<void> Function()? onScrape,
  }) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: BookDetailPage(
            snapshot: () => snapshot,
            loadDetail: () async => detail,
            onOpen: onOpen ?? () async {},
            onScrape: onScrape,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  bool isBackdropImage(Widget w) {
    if (w is! Image) return false;
    final ImageProvider image = w.image;
    if (image is! ResizeImage) return false;
    final ImageProvider inner = image.imageProvider;
    return inner is FileImage && inner.file.path == File(backdropPath).path;
  }

  testWidgets('已刮削：背景图 / 评分 / 类型 / 简介 / 资料行都在海报面板里', (
    WidgetTester tester,
  ) async {
    await pump(
      tester,
      detail: ItemScrapeDetail(meta: scrapedMeta(), backdropPath: backdropPath),
      onScrape: () async {},
    );

    expect(find.byType(MediaPosterDetailHero), findsOneWidget);
    expect(find.byWidgetPredicate(isBackdropImage), findsWidgets);
    expect(find.text('★ 7.8'), findsOneWidget);
    expect(find.text('奇幻'), findsOneWidget);
    expect(find.text('冒险'), findsOneWidget);
    expect(find.text('2016'), findsOneWidget);
    expect(find.text('魔女の旅々'), findsWidgets);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('book-detail-summary')),
        matching: find.textContaining('旅人伊蕾娜'),
      ),
      findsWidgets,
    );
    // 资料行：作者 / 发行日期 / 评分人数 / 来源。
    expect(find.byKey(const ValueKey<String>('book-detail-facts')), findsOne);
    expect(find.text('白石定规'), findsOneWidget);
    expect(find.text('7.8 · 1234 人评分'), findsOneWidget);
    // 来源 + 查看条目外链；已刮削给「重新刮削」，不出未刮削提示。
    expect(
      find.byKey(const ValueKey<String>('book-detail-source-link')),
      findsOneWidget,
    );
    // 次操作是同尺寸 tonal 图标钮（文字进 tooltip），来源写显示名。
    expect(find.byTooltip(t.book_detail_rescrape_action), findsOneWidget);
    expect(
      find.byTooltip('${t.book_detail_source_open} · Bangumi'),
      findsOneWidget,
    );
    expect(find.text('${t.book_detail_source_open} · Bangumi'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('book-detail-unscraped-hint')),
      findsNothing,
    );
  });

  testWidgets('未刮削：照常显示书名 / 作者，给刮削行动点并能回调', (WidgetTester tester) async {
    int scrapes = 0;
    await pump(
      tester,
      detail: ItemScrapeDetail.empty,
      onScrape: () async => scrapes++,
    );

    expect(find.text('魔女之旅 1'), findsWidgets);
    expect(find.text('白石定规'), findsWidgets);
    expect(
      find.byKey(const ValueKey<String>('book-detail-unscraped-hint')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('book-detail-source-link')),
      findsNothing,
    );
    final Finder cta = find.byKey(const ValueKey<String>('book-detail-scrape'));
    expect(cta, findsOneWidget);
    expect(find.byTooltip(t.book_detail_scrape_action), findsOneWidget);
    await tester.tap(cta);
    await tester.pump();
    expect(scrapes, 1);
  });

  testWidgets('刮削不可用（在线服务模块关）：不出刮削按钮与提示', (WidgetTester tester) async {
    await pump(tester, detail: ItemScrapeDetail.empty);
    expect(
      find.byKey(const ValueKey<String>('book-detail-scrape')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('book-detail-unscraped-hint')),
      findsNothing,
    );
  });

  testWidgets('主按钮 = 打开回调；有进度写「继续阅读」', (WidgetTester tester) async {
    int opens = 0;
    await pump(
      tester,
      detail: ItemScrapeDetail.empty,
      snapshot: const BookDetailSnapshot(title: '魔女之旅 1', progress: 0.46),
      onOpen: () async => opens++,
    );

    final Finder open = find.byKey(const ValueKey<String>('book-detail-open'));
    expect(open, findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(MediaPosterDetailHero),
        matching: find.text(t.book_continue_reading),
      ),
      findsWidgets,
    );
    expect(find.text(t.book_read_progress(percent: 46)), findsOneWidget);
    await tester.tap(open);
    await tester.pump();
    expect(opens, 1);
  });

  test('itemScrapeSourceLabel：书 / 游戏源显示品牌名，手动写入不显示', () {
    expect(itemScrapeSourceLabel('bangumi'), 'Bangumi');
    expect(itemScrapeSourceLabel('dlsite'), 'DLsite');
    expect(itemScrapeSourceLabel('bgm'), 'Bangumi');
    expect(itemScrapeSourceLabel('vndb'), 'VNDB');
    expect(itemScrapeSourceLabel('manual'), isNull);
    expect(itemScrapeSourceLabel(''), isNull);
  });
}
