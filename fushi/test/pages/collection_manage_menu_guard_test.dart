import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-2791 / BUG-1547：合集管理菜单里的「刮削分集资料」是个死按钮 —— 它硬门
/// 「合集资料已刮削」，未刮时只会弹「请先刮削合集资料」；而已刮时集名/集号本就由
/// 合集刮削管线（`VideoMetadataDatabaseStore.apply` → `_writeLegacyProjection`）
/// 写好了。集级资料统一由合集刮削产出，不再单开入口。
void main() {
  final String page = File(
    'lib/src/pages/implementations/media_collection_detail_page.dart',
  ).readAsStringSync();

  test('合集管理菜单不再有分集刮削入口', () {
    expect(
      page.contains('_CollectionManageAction.scrapeEpisodes'),
      isFalse,
      reason: '菜单枚举与分发都不该再有 scrapeEpisodes 这一支',
    );
    expect(
      page.contains('_scrapeEpisodes('),
      isFalse,
      reason: '独立触发路径要一起删，别留一个没人调的方法',
    );
    expect(
      page.contains('EpisodeScrapeService'),
      isFalse,
      reason: '页面不该再直接驱动分集刮削服务',
    );
  });

  test('分集刮削的 i18n key 全部随入口删除', () {
    // 这三个 key 只服务被删掉的入口；留着就是 17 个语言文件里的死条目。
    for (final String key in <String>[
      'collection_episode_scrape',
      'collection_episode_scrape_unbound',
      'collection_episode_scrape_result',
      'collection_episode_scrape_failed',
    ]) {
      expect(page.contains(key), isFalse, reason: '页面仍引用 $key');
      expect(
        File('lib/i18n/strings.i18n.json')
            .readAsStringSync()
            .contains('"$key"'),
        isFalse,
        reason: 'strings.i18n.json 仍留着 $key',
      );
      expect(
        File('lib/i18n/strings_zh-CN.i18n.json')
            .readAsStringSync()
            .contains('"$key"'),
        isFalse,
        reason: 'strings_zh-CN.i18n.json 仍留着 $key',
      );
    }
  });

  test('其余管理菜单项一个都没被牵连', () {
    // 「补齐缺集」「按刮削重命名各集」不依赖合集级 meta（各有自己的判据），
    // 删分集刮削入口不该顺手动到它们。
    for (final String action in <String>[
      '_CollectionManageAction.sortBySeason',
      '_CollectionManageAction.subtitles',
      '_CollectionManageAction.renameEpisodes',
      '_CollectionManageAction.fillMissing',
      '_CollectionManageAction.splitBySeason',
      '_CollectionManageAction.rename',
      '_CollectionManageAction.tags',
      '_CollectionManageAction.delete',
    ]) {
      expect(page, contains(action));
    }
    expect(page, contains('Future<void> _renameEpisodesFromScrape()'));
    expect(page, contains('void _fillMissingEpisodes()'));
  });
}
