import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/scan_scale.dart';

void main() {
  // 唯一枚举点：下面两个投影和扫描规模哨兵共用它。分开各写一遍 listSync 会让
  // 哨兵与判据各扫各的——判据那侧的过滤写坏时哨兵照样绿（假绿形态 ③）。
  List<File> productionDartFiles() => Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((File file) => file.path.endsWith('.dart'))
      .toList();

  List<String> productionFilesContaining(String needle) => productionDartFiles()
      .where((File file) => file.readAsStringSync().contains(needle))
      .map((File file) => file.path.replaceAll('\\', '/'))
      .toList();

  List<String> productionFilesMatching(RegExp pattern) => productionDartFiles()
      .where((File file) => pattern.hasMatch(file.readAsStringSync()))
      .map((File file) => file.path.replaceAll('\\', '/'))
      .toList();

  test('扫描规模哨兵：lib/ 全树确实被枚举到了', () {
    // 本文件的判据全是禁止型（「不得再出现 X」），健康仓库里恒零命中——扫描面塌了
    // 和真的干净在断言层面长得一模一样。哨兵是唯一能把两者分开的东西。
    expectScanScale(
      productionDartFiles().length,
      what: 'lib/ 下的 .dart',
      atLeast: 950,
      measured: 1221,
    );
  });

  final String assembly = File(
    'lib/src/media/video/cover_ui/video_scrape_actions.dart',
  ).readAsStringSync();
  final String home = File(
    'lib/src/pages/implementations/home_video_page.dart',
  ).readAsStringSync();
  final String workDetail = File(
    'lib/src/pages/implementations/video_work_detail_page.dart',
  ).readAsStringSync();
  final String collectionDetail = File(
    'lib/src/pages/implementations/media_collection_detail_page.dart',
  ).readAsStringSync();
  final String videoSettings = File(
    'lib/src/settings/settings_schema_video.dart',
  ).readAsStringSync();

  test('legacy 生产装配只构造本地 sidecar 服务', () {
    expect(assembly, isNot(contains('TmdbClient(')));
    expect(assembly, isNot(contains('tmdbClient:')));
    expect(assembly, isNot(contains('configuredTmdbKey')));
    expect(assembly, isNot(contains('showVideoScrapeAllDialog')));
    expect(assembly, contains('createVideoScraperService'));
    expect(assembly, contains('DatabaseSidecarGeneratedArtifactChecker'));
  });

  test('Home 不再暴露单项或合集 legacy 在线刮削入口', () {
    for (final String retired in <String>[
      'video_scrape_online_match',
      'video_collection_scrape',
      '_openCoverMatch',
      '_openCollectionCoverMatch',
      'showCollectionScrapeDialog',
      'onScrapeCollection:',
      'onEpisodeScrapeInfo:',
    ]) {
      expect(home, isNot(contains(retired)), reason: retired);
    }
  });

  test('合集详情类型不再接受 legacy 刮削回调', () {
    for (final String retired in <String>[
      'onScrapeCollection',
      'onEpisodeScrapeInfo',
    ]) {
      expect(workDetail, isNot(contains(retired)), reason: retired);
    }
    for (final String retired in <String>[
      'this.onScrape',
      'widget.onScrape',
      'onEpisodeScrapeInfo',
      '_CollectionManageAction.scrape',
      '_EpisodeMenuAction.scrapeInfo',
    ]) {
      expect(collectionDetail, isNot(contains(retired)), reason: retired);
    }
  });

  test('无生产调用的合集 legacy 刮削弹窗已删除', () {
    expect(
      File(
        'lib/src/media/video/cover_ui/collection_scrape_dialog.dart',
      ).existsSync(),
      isFalse,
    );
  });

  test('设置页不再暴露 legacy 自动标题刮削开关', () {
    expect(videoSettings, isNot(contains('video.library.auto_scrape')));
    expect(videoSettings, isNot(contains('video_setting_auto_scrape')));
  });

  test('无生产调用的 legacy 在线实现、候选链与弹窗已删除', () {
    for (final String retiredFile in <String>[
      'lib/src/media/video/scraper/tmdb_client.dart',
      'lib/src/media/video/scraper/cover_downloader.dart',
      'lib/src/media/video/scraper/alias_cache.dart',
      'lib/src/media/video/scraper/match_scorer.dart',
      'lib/src/media/video/scraper/collection_scrape_apply.dart',
      'lib/src/media/video/scraper/collection_relations_scrape.dart',
      'lib/src/media/video/scraper/episode_scrape_service.dart',
      'lib/src/media/video/cover_ui/collection_rename_confirm_dialog.dart',
      'lib/src/media/video/cover_ui/cover_match_dialog.dart',
      'lib/src/media/video/cover_ui/scrape_info_dialog.dart',
      'test/media/video/scraper/tmdb_client_test.dart',
      'test/media/video/scraper/tmdb_image_set_test.dart',
      'test/media/video/scraper/cover_downloader_test.dart',
      'test/media/video/scraper/alias_cache_test.dart',
      'test/media/video/scraper/match_scorer_test.dart',
      'test/media/video/scraper/collection_relations_scrape_test.dart',
      'test/media/video/scraper/episode_scrape_service_test.dart',
      'test/media/video/scraper/cover_match_dialog_test.dart',
      'test/media/video/scraper/scrape_info_dialog_test.dart',
    ]) {
      expect(File(retiredFile).existsSync(), isFalse, reason: retiredFile);
    }
    expect(productionFilesContaining('scrapeCollectionRelations('), isEmpty);
    expect(productionFilesContaining('EpisodeScrapeService('), isEmpty);
    expect(productionFilesContaining('TmdbClient('), isEmpty);
    expect(productionFilesContaining('CoverDownloader('), isEmpty);
    expect(productionFilesContaining('AliasCache('), isEmpty);
    expect(productionFilesContaining('MatchScorer('), isEmpty);
    expect(
      productionFilesMatching(RegExp(r'\bScrapeCandidate\s*\(')),
      isEmpty,
    );
  });
}
