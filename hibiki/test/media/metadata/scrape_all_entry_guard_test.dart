import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('视频、书籍漫画、游戏库都保留单项入口并提供全部刮削入口', () {
    final String video = File(
      'lib/src/pages/implementations/home_video_page.dart',
    ).readAsStringSync();
    final String books = File(
      'lib/src/pages/implementations/reader_hibiki_history_page.dart',
    ).readAsStringSync();
    final String games = File(
      'lib/src/pages/implementations/games_library_page.dart',
    ).readAsStringSync();

    expect(video, contains('Future<void> _openCoverMatch('));
    expect(video, contains('Future<void> _scrapeAllVideos('));
    expect(video, contains('tooltip: t.scrape_all'));

    expect(books, contains('Future<void> _scrapeEpubCover('));
    expect(books, contains('Future<void> _scrapeAllBooks('));
    expect(books, contains('tooltip: t.scrape_all'));

    expect(games, contains('Future<void> _scrapeGame('));
    expect(games, contains('Future<void> _scrapeAllGames('));
    expect(games, contains('tooltip: t.scrape_all'));
  });

  test('BUG-1307 四域无人值守批处理都接了「唯一精确标题」闸门', () {
    final String video = File(
      'lib/src/pages/implementations/home_video_page.dart',
    ).readAsStringSync();
    final String books = File(
      'lib/src/pages/implementations/reader_hibiki_history_page.dart',
    ).readAsStringSync();
    final String games = File(
      'lib/src/pages/implementations/games_library_page.dart',
    ).readAsStringSync();

    // 视频是唯一开 rescrapeScraped 的域（会覆盖已刮封面，含用户在弹窗里亲手
    // 确认、同样记为 scraped 的那些），必须同时把判据收紧成唯一精确标题；
    // 单靠 cover_scraper_service 的单测测不到这条接线（BUG-1307）。
    expect(video, contains('rescrapeScraped: true'));
    expect(video, contains('requireUniqueExactTitle: true'));

    // 书 / 漫画 / 游戏走共享纯函数判据，且批量恒不覆盖已有封面。
    expect(books, contains('uniqueExactScrapeTitleMatch<BookScrapeCandidate>'));
    expect(games, contains('uniqueExactScrapeTitleMatch<SourceCandidate>'));
    expect(games, contains('replaceExistingCover: false'));
  });
}
