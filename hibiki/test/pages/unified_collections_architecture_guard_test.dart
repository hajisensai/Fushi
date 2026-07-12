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

  test('UI v2：整理排序页已按用户拍板整体砍掉——零残留 + 能力不回退', () {
    // 用户：「编辑排序这个页面整个砍掉，做的太烂了」。页面、共享拖拽网格、入口
    // 按钮全删；恢复任一残留即转红。
    expect(
        File('lib/src/pages/implementations/shelf_reorder_page.dart')
            .existsSync(),
        isFalse,
        reason: '整理排序页必须保持删除');
    expect(
        File('lib/src/utils/components/hibiki_reorderable_grid.dart')
            .existsSync(),
        isFalse,
        reason: '2D 拖拽重排网格随页面一起删除（零消费者）');
    for (final String banned in <String>['ShelfReorderPage', 'onOrganize:']) {
      expect(homeSrc.contains(banned), isFalse,
          reason: '视频库不得残留整理页接线（$banned）');
      expect(historySrc.contains(banned), isFalse,
          reason: '书架不得残留整理页接线（$banned）');
    }
    // series 死模型同样不得回潮。
    expect(historySrc.contains('updateSeriesSortOrder'), isFalse);
    expect(historySrc.contains('getAllSeries'), isFalse);
    expect(historySrc.contains('groupAndSortShelfEntries'), isFalse);
    // 能力不回退：合集成员移出改走详情页（书=网格详情页，视频=剧集详情页）。
    final String gridDetailSrc = File(
      'lib/src/pages/implementations/media_collection_grid_detail_page.dart',
    ).readAsStringSync();
    final String videoDetailSrc = File(
      'lib/src/pages/implementations/media_collection_detail_page.dart',
    ).readAsStringSync();
    expect(gridDetailSrc.contains('removeFromCollection'), isTrue,
        reason: '书籍合集详情页必须保留成员移出');
    expect(videoDetailSrc.contains('removeFromCollection'), isTrue,
        reason: '视频合集详情页必须提供逐集移出（整理页删除后的唯一入口）');
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

  test('排序交互重设计：死权重零读取 + 排序菜单 + 成员序单一真相源 + 详情页就地排序', () {
    // 层次 A：旧手动权重（ShelfEntries.sortOrder / MediaCollections.sortOrder）
    // 已废弃（用户拍板，spec 2026-07-12）——两库页不得再读；卡片间序只能由
    // 排序模式（compareShelfSortKeys）推导。恢复任一读取点即转红。
    for (final String banned in <String>[
      'getAllShelfEntries',
      '_videoOrder',
      '_shelfOrder',
      'itemSortOrder',
      'groupSortOrder',
    ]) {
      expect(homeSrc.contains(banned), isFalse,
          reason: '视频库不得再读已废弃的手动权重（$banned）');
      expect(historySrc.contains(banned), isFalse,
          reason: '书架不得再读已废弃的手动权重（$banned）');
    }
    for (final String required in <String>[
      'compareShelfSortKeys',
      'onSortModeChanged',
      // 层次 C：组内序读 MediaCollectionItems.sortIndex（与详情页/播放器
      // getCollectionItems 同源，一处落盘三处同序）。
      'memberSortIndex',
    ]) {
      expect(homeSrc.contains(required), isTrue,
          reason: '视频库必须接线排序模式/成员序真相源（$required）');
      expect(historySrc.contains(required), isTrue,
          reason: '书架必须接线排序模式/成员序真相源（$required）');
    }
    // 层次 B：视频详情页拖拽精修 + 两详情页一键排序，均写穿 reorderCollectionItems。
    final String videoDetailSrc = File(
      'lib/src/pages/implementations/media_collection_detail_page.dart',
    ).readAsStringSync();
    final String gridDetailSrc = File(
      'lib/src/pages/implementations/media_collection_grid_detail_page.dart',
    ).readAsStringSync();
    expect(videoDetailSrc.contains('ReorderableListView'), isTrue,
        reason: '视频合集详情页必须支持拖拽排集（手动排序的唯一形态）');
    expect(videoDetailSrc.contains('reorderCollectionItems'), isTrue,
        reason: '视频详情页排序必须写穿 sortIndex（层次 C 真相源）');
    expect(gridDetailSrc.contains('reorderCollectionItems'), isTrue,
        reason: '书籍合集详情页一键排序必须写穿 sortIndex');
  });

  test('去碎片方案A（已拍板）：合集区集中+散卡单一网格，交错组装不回潮', () {
    // 旧保序交错的 flushLoose 分段组装每个合集行都切碎散卡网格（一两本书占
    // 一行，用户实报）；分区后散卡恒渲染成一个网格。恢复交错即转红。
    expect(homeSrc.contains('flushLoose'), isFalse,
        reason: '视频库不得回到交错分段组装（散卡必须单一网格）');
    expect(historySrc.contains('flushLoose'), isFalse,
        reason: '书架不得回到交错分段组装（散卡必须单一网格）');
  });

  test('BUG-756：书架 recency 读 reader_positions.updatedAt，假名次不回潮', () {
    final String sourceSrc =
        File('lib/src/media/sources/reader_hibiki_source.dart')
            .readAsStringSync();
    // 唯一 recency 真相源（批量 DAO + provider）。
    expect(sourceSrc.contains('bookLastReadAtProvider'), isTrue,
        reason: 'recency 必须有唯一真相源 provider');
    expect(sourceSrc.contains('getAllReaderPositions'), isTrue,
        reason: 'recency 映射必须一次批量查询 reader_positions');
    // 关书与书列表同点失效，否则 hero/「最近阅读」陈旧到重启。方法体终点锚定
    // 下一个 override（`\n  }` 会先撞上参数表的 `}) async {`，不能用）。
    final int exitFn = sourceSrc.indexOf('Future<void> onSourceExit(');
    expect(exitFn, isNonNegative);
    final int exitEnd = sourceSrc.indexOf('onSearchBarTap', exitFn);
    expect(exitEnd, isNonNegative);
    final String exitBody = sourceSrc.substring(exitFn, exitEnd);
    expect(exitBody.contains('ref.invalidate(bookLastReadAtProvider)'), isTrue,
        reason: '关书必须同点失效 recency 映射（BUG-756 刷新语义）');
    // 书架页：hero 按最后阅读时间选书；「最近阅读」读同一映射、没读过退
    // importedAt；provider 下标假名次（实为导入序）不得回潮。
    expect(historySrc.contains('mostRecentlyReadCandidate'), isTrue,
        reason: '继续阅读 hero 必须选最后阅读时间最新的在读书');
    expect(
        historySrc.contains('_lastReadAtByBookKey[bookKey] ?? it.importedAt'),
        isTrue,
        reason: '「最近阅读」= updatedAt，没读过按导入时间融入（与视频页语义镜像）');
    expect(historySrc.contains('payload.seq'), isFalse,
        reason: '列表下标假名次已删（provider 序 = importedAt 倒序，不是访问序）');
  });
}
