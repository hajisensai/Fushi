import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 统一合集 Phase 6 守卫：锁死「Jellyfin 式统一合集」架构的四条不变量（源码守卫）。
///
/// 书籍 + 视频共用 MediaCollections/MediaCollectionItems 引用表；播放列表 = 合集（本地多
/// 集导入即拆成独立 VideoBooks 行 + 一个 playlist 合集）。撤任一接线即转红，防日后回退到
/// 旧 Series 系统或 playlistJson 整本模型。
void main() {
  final File mergeEngine = File('lib/src/sync/backup_merge_engine.dart');
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
    expect(split, lessThan(migrate), reason: '必须先拆播放列表再迁 series，避免拆出的集重复归组');
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

  test('UI v2 Phase C：合集在两页主区渲染成独占一行的横排行（CollectionShelfRow）', () {
    // 用户拍板：每个合集独占一行、行内横移看相邻集/卷；撤掉回折叠网格卡即转红。
    expect(homeSrc.contains('CollectionShelfRow'), isTrue,
        reason: '视频库合集必须渲染成全宽横排行');
    expect(historySrc.contains('CollectionShelfRow'), isTrue,
        reason: '书架合集必须渲染成全宽横排行');
    // 视频行成员卡点击直接从该集进播放器（带剧集面板），不再必须绕详情页。
    expect(homeSrc.contains('playlistCollectionId: collection.id'), isTrue,
        reason: '视频合集行成员卡必须带 playlistCollectionId 直接换集');
  });

  test('UI v2 Phase E：整理排序页零 series 写路径（合集是唯一分组真相源）', () {
    // 用户拍板砍掉重做：分组/合并/移出/组位置持久化全走 MediaCollections。
    final File reorderPage =
        File('lib/src/pages/implementations/shelf_reorder_page.dart');
    expect(reorderPage.existsSync(), isTrue);
    final String reorderSrc = reorderPage.readAsStringSync();
    for (final String banned in <String>[
      'seriesId',
      'seriesCardId',
      'setSeriesForEntry',
      'splitShelfReorderOrders',
    ]) {
      expect(reorderSrc.contains(banned), isFalse,
          reason: '整理页不得回退 series 模型（含 $banned）');
    }
    expect(reorderSrc.contains('mergeReorderItemsIntoCollection'), isTrue,
        reason: '拖合并共享执行器必须走合集 DB 原语');
    expect(reorderSrc.contains('removeFromCollection'), isTrue,
        reason: '移出必须走 removeFromCollection（空合集自动清理）');
    // 两页整理接线：合集整体位置写 MediaCollections.sortOrder；书架不再拉死掉的
    // Series 表喂整理页。
    expect(historySrc.contains('updateMediaCollectionSortOrder'), isTrue,
        reason: '书架整理落盘必须写合集 sortOrder');
    expect(homeSrc.contains('updateMediaCollectionSortOrder'), isTrue,
        reason: '视频整理落盘必须写合集 sortOrder');
    expect(historySrc.contains('updateSeriesSortOrder'), isFalse,
        reason: '书架不得再写死掉的 Series.sortOrder');
    expect(historySrc.contains('getAllSeries'), isFalse,
        reason: '书架不得再拉 Series 表喂整理页');
    expect(historySrc.contains('groupAndSortShelfEntries'), isFalse,
        reason: '整理页分组必须与主网格同走 groupByCollections');
  });

  test('每集独立视频各自有封面：后台补齐 + playlist 详情页渲染每集缩略图', () {
    // 拆集/迁移拆出的非首集 cover_path 为空 → home_video_page 后台逐集抽帧补齐。
    expect(homeSrc.contains('_maybeBackfillCovers'), isTrue,
        reason: '视频库必须后台给缺封面的各集抽帧补封面（每集独立视频应各有封面）');
    expect(homeSrc.contains('extractVideoCover'), isTrue,
        reason: '补封面走单视频抽帧 extractVideoCover（非整本 playlist 封面）');
    // playlist 合集详情页每集渲染各自封面缩略图（对齐 Jellyfin 剧集列表）。
    final File detail = File(
      'lib/src/pages/implementations/media_collection_detail_page.dart',
    );
    expect(detail.existsSync(), isTrue);
    final String detailSrc = detail.readAsStringSync();
    expect(detailSrc.contains('_episodeThumb'), isTrue,
        reason: 'playlist 详情页剧集行必须带每集封面缩略图');
    expect(detailSrc.contains('Image.file'), isTrue,
        reason: '缩略图用集自身 coverPath 的 Image.file（无封面退占位）');
  });
}
