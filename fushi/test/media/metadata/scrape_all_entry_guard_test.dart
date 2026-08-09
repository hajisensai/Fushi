import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('视频单项入口留在库页，全部刮削迁到视频来源页', () {
    final String video = File(
      'lib/src/pages/implementations/home_video_page.dart',
    ).readAsStringSync();
    final String books = File(
      'lib/src/pages/implementations/reader_fushi_history_page.dart',
    ).readAsStringSync();
    final String games = File(
      'lib/src/pages/implementations/games_library_page.dart',
    ).readAsStringSync();
    final String sources = File(
      'lib/src/pages/implementations/media_sources_page.dart',
    ).readAsStringSync();

    expect(video, contains('Future<void> _openCoverMatch('));
    expect(video, isNot(contains('Future<void> _scrapeAllVideos(')));
    expect(video, isNot(contains('tooltip: t.scrape_all')));
    expect(sources, contains("widget.mediaKind == 'video'"));
    expect(sources, contains('tooltip: t.scrape_all'));
    expect(sources.indexOf('tooltip: t.media_source_add'),
        lessThan(sources.indexOf('tooltip: t.scrape_all')));

    expect(books, contains('Future<void> _scrapeEpubCover('));
    expect(books, contains('Future<void> _scrapeAllBooks('));
    expect(books, contains('tooltip: t.scrape_all'));

    expect(games, contains('Future<void> _scrapeGame('));
    expect(games, contains('Future<void> _scrapeAllGames('));
    expect(games, contains('tooltip: t.scrape_all'));
  });

  test('BUG-1325 四域无人值守批处理都接了不覆盖用户选择的闸门', () {
    final String videoActions = File(
      'lib/src/media/video/cover_ui/video_scrape_actions.dart',
    ).readAsStringSync();
    final String books = File(
      'lib/src/pages/implementations/reader_fushi_history_page.dart',
    ).readAsStringSync();
    final String games = File(
      'lib/src/pages/implementations/games_library_page.dart',
    ).readAsStringSync();
    final String service = File(
      'lib/src/media/video/scraper/cover_scraper_service.dart',
    ).readAsStringSync();

    // 视频是唯一开 rescrapeScraped 的域（会覆盖已刮封面）。覆盖判据**不在页面
    // 层**：页面只表达「用户显式要求重刮」，能不能覆盖由 scrapeLibrary 按封面
    // 来源逐本决定。页面若自己再传一个 requireUniqueExactTitle，就是把判据摊成
    // 两处、迟早各说一套（BUG-1325）。
    expect(videoActions, contains('rescrapeScraped: true'));
    expect(
      videoActions.contains('requireUniqueExactTitle'),
      isFalse,
      reason: '覆盖判据必须留在 scrapeLibrary 一层，页面不得重复表达',
    );

    // 覆盖决策的唯一判据来源：按 CoverOrigin 取 batchOverwritePolicy 后穷尽分流。
    expect(service, contains('origin.batchOverwritePolicy'));
    expect(service, contains('CoverOverwritePolicy.never => false'));
    // 用户在弹窗里点「使用」的那条路必须标 userScraped，否则又与自动刮削同形。
    expect(service, contains('origin: CoverOrigin.userScraped'));

    // 书 / 漫画 / 游戏走共享纯函数判据，且批量恒不覆盖已有封面。
    expect(books, contains('uniqueExactScrapeTitleMatch<BookScrapeCandidate>'));
    expect(games, contains('uniqueExactScrapeTitleMatch<SourceCandidate>'));
    expect(games, contains('replaceExistingCover: false'));
  });
}
