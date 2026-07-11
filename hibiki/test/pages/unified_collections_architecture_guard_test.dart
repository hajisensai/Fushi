import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 统一合集 Phase 6 守卫：锁死「Jellyfin 式统一合集」架构的四条不变量（源码守卫）。
///
/// 书籍 + 视频共用 MediaCollections/MediaCollectionItems 引用表；播放列表 = 合集（本地多
/// 集导入即拆成独立 VideoBooks 行 + 一个 playlist 合集）。撤任一接线即转红，防日后回退到
/// 旧 Series 系统或 playlistJson 整本模型。
void main() {
  final File mergeEngine =
      File('lib/src/sync/backup_merge_engine.dart');
  final File importDialog =
      File('lib/src/media/video/video_import_dialog.dart');
  final File database =
      File('../packages/hibiki_core/lib/src/database/database.dart');
  final File homeVideo =
      File('lib/src/pages/implementations/home_video_page.dart');
  final File historyPage =
      File('lib/src/pages/implementations/reader_hibiki_history_page.dart');

  late String mergeSrc;
  late String importSrc;
  late String dbSrc;
  late String homeSrc;
  late String historySrc;

  setUpAll(() {
    for (final File f in <File>[
      mergeEngine,
      importDialog,
      database,
      homeVideo,
      historyPage,
    ]) {
      expect(f.existsSync(), isTrue, reason: '缺失 ${f.path}');
    }
    mergeSrc = mergeEngine.readAsStringSync();
    importSrc = importDialog.readAsStringSync();
    dbSrc = database.readAsStringSync();
    homeSrc = homeVideo.readAsStringSync();
    historySrc = historyPage.readAsStringSync();
  });

  test('迁移在 v38 同时拆播放列表 + 迁 series→合集（先拆后迁的顺序）', () {
    final int split = dbSrc.indexOf('await splitPlaylistVideoBooksV38();');
    final int migrate = dbSrc.indexOf('await migrateSeriesToCollectionsV38();');
    expect(split, isNonNegative, reason: 'v38 必须调用 splitPlaylistVideoBooksV38');
    expect(migrate, isNonNegative,
        reason: 'v38 必须调用 migrateSeriesToCollectionsV38');
    expect(split, lessThan(migrate),
        reason: '必须先拆播放列表再迁 series，避免拆出的集重复归组');
  });

  test('备份合并携带 media_collections（Phase 5a：合集随备份存活）', () {
    final int mergeFn = mergeSrc.indexOf('Future<void> merge() async {');
    expect(mergeFn, isNonNegative);
    final int mergeEnd = mergeSrc.indexOf('\n  }', mergeFn);
    expect(mergeEnd, isNonNegative);
    final String body = mergeSrc.substring(mergeFn, mergeEnd);
    expect(body.contains('await _mergeMediaCollections();'), isTrue,
        reason: 'merge() 必须合并 media_collections，否则备份恢复后分组全丢');
    // 自然键幂等 remap（不能按自增 id 直搬）。
    expect(mergeSrc.contains('collection_type'), isTrue);
    expect(mergeSrc.contains('INSERT OR IGNORE INTO media_collection_items'),
        isTrue,
        reason: '成员按复合主键 INSERT OR IGNORE 去重');
  });

  test('视频播放列表导入走 importSplitPlaylist（拆集），不再写整本 playlistJson', () {
    expect(importSrc.contains('importSplitPlaylist('), isTrue,
        reason: '播放列表导入必须拆成独立行 + 合集（单一真相源 importSplitPlaylist）');
    // 导入对话框绝不再往 VideoBooks 写 playlistJson 整本列（拆集后该列恒 NULL）。
    expect(importSrc.contains('playlistJson: Value'), isFalse,
        reason: '拆集模型下导入不得再写 playlistJson 整本列');
  });

  test('库/书架主网格用 groupByCollections 折叠（合集是展示真相源）', () {
    expect(homeSrc.contains('groupByCollections'), isTrue,
        reason: '视频库主网格必须按合集折叠');
    expect(historySrc.contains('groupByCollections'), isTrue,
        reason: '书架主网格必须按合集折叠');
    // 折叠归属来自 getPrimaryCollectionIdByEntry（最小 collectionId），不再靠 seriesId。
    expect(homeSrc.contains('getPrimaryCollectionIdByEntry'), isTrue);
    expect(historySrc.contains('getPrimaryCollectionIdByEntry'), isTrue);
  });
}
