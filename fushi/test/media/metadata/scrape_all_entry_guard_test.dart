import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('视频 legacy 在线入口已下线，canonical 全部刮削留在视频来源页', () {
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

    expect(video, isNot(contains('Future<void> _openCoverMatch(')));
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

  test('视频 legacy 服务只采用 sidecar，书与游戏仍保护用户封面', () {
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

    for (final String retired in <String>[
      'TmdbClient',
      'CoverDownloader',
      'AliasCache',
      'ScrapeCandidate',
      'searchCandidates',
      'applyCandidateToBooks',
      'package:http/',
    ]) {
      expect(service, isNot(contains(retired)), reason: retired);
      expect(videoActions, isNot(contains(retired)), reason: retired);
    }
    expect(service, contains('SidecarScanner.scan'));
    expect(service, contains('MediaCoverService.applyCoverFile'));
    expect(service, contains('CoverOrigin.sidecar'));
    expect(service, contains('origin == CoverOrigin.autoFrame'));

    // 书 / 漫画 / 游戏走共享纯函数判据，批量恒不覆盖已有封面。
    expect(books, contains('uniqueExactScrapeTitleMatch<BookScrapeCandidate>'));
    expect(games, contains('uniqueExactScrapeTitleMatch<SourceCandidate>'));
    expect(games, contains('replaceExistingCover: false'));
  });
}
