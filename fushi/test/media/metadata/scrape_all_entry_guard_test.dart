import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('视频 legacy 在线入口已下线，canonical 全部刮削留在视频来源页；书 / 漫画不再批量刮削', () {
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
    expect(
      sources.indexOf('tooltip: t.media_source_add'),
      lessThan(sources.indexOf('tooltip: t.scrape_all')),
    );

    // 用户定案 2026-10-14：书和漫画不需要「全部刮削」（只有视频和 galgame 需要），
    // 书架页头的批量入口连同实现一起删；单本封面刮削（卡片菜单）保留。
    expect(books, contains('Future<void> _scrapeEpubCover('));
    expect(books, isNot(contains('Future<void> _scrapeAllBooks(')));
    expect(books, isNot(contains('t.scrape_all')));

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

    // 书 / 漫画只剩单本手动刮削，写封面不清用户 override 图。写回在 2026-10-26 抽成了
    // 门面（书架页与 CLI / AI 共用），判据跟着落到门面的「应用」路径上。
    final String facade = File(
      'lib/src/media/metadata/book_metadata_scrape_facade.dart',
    ).readAsStringSync();
    expect(books, contains('BookMetadataScrapeFacade'));
    final int applyStart = facade.indexOf(
      'Future<BookMetadataApplyResult> applyToBook(',
    );
    final int applyEnd = facade.indexOf(
      'Future<BookMetadataState> currentState(',
    );
    expect(applyStart, greaterThanOrEqualTo(0));
    expect(applyEnd, greaterThan(applyStart));
    final String apply = facade.substring(applyStart, applyEnd);
    expect(apply, contains('clearOverrideImage: false'));
    expect(apply, isNot(contains('clearOverrideImage: true')));
    // 游戏批量刮削走共享纯函数判据，恒不覆盖已有封面（书 / 漫画已无批量刮削）。
    expect(games, contains('uniqueExactScrapeTitleMatch<SourceCandidate>'));
    expect(games, contains('replaceExistingCover: false'));
  });
}
