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
}
