import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

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

  test('合集渲染形态：书架横排行（CollectionShelfRow）+ 视频封面卡（用户拍板 2026-07-22）', () {
    // 书架维持 Phase C 横排行；视频侧用户拍板恢复封面卡形态（「一进去就是封面，
    // 跟小说那种一样」）：合集渲染成与散卡同尺寸的封面卡并入主网格。互退即转红。
    expect(historySrc.contains('CollectionShelfRow'), isTrue,
        reason: '书架合集必须渲染成全宽横排行');
    expect(homeSrc.contains('_buildCollectionCoverCard'), isTrue,
        reason: '视频库合集必须渲染成封面卡（一合集一封面）');
    expect(homeSrc.contains('CollectionShelfRow('), isFalse,
        reason: '视频库不得回退到全宽横排行（用户拍板封面卡）');
    // 点某集从该集进播放器（带剧集面板/连播）的能力经详情页保留。
    expect(homeSrc.contains('playlistCollectionId: collection.id'), isTrue,
        reason: '视频合集详情页开集必须带 playlistCollectionId 直接换集');
  });

  test('UI v2：整理排序页已按用户拍板整体砍掉——零残留 + 能力不回退', () {
    // 用户：「编辑排序这个页面整个砍掉，做的太烂了」。整理排序页 + 入口按钮全删；
    // 恢复任一残留即转红。
    expect(
        File('lib/src/pages/implementations/shelf_reorder_page.dart')
            .existsSync(),
        isFalse,
        reason: '整理排序页必须保持删除');
    // 共享 2D 拖拽网格当年随整理页删除（零消费者）；现书籍合集详情页重新需要它做
    // 网格内拖排（有消费者），且新实现消缩放（浮层渲染在组件自身 Stack、指针
    // globalToLocal 消祖先 Transform.scale，非 SDK/pub 的 Overlay 平移代理，BUG-778）。
    // 断言按新现实：文件必须存在、含 globalToLocal（消缩放核心），且详情页真在用。
    final File reorderGrid =
        File('lib/src/utils/components/hibiki_reorderable_grid.dart');
    expect(reorderGrid.existsSync(), isTrue,
        reason: '书籍合集详情页网格拖排依赖消缩放 2D 组件 HibikiReorderableGrid');
    expect(reorderGrid.readAsStringSync().contains('globalToLocal'), isTrue,
        reason: '消缩放核心：所有指针坐标必经根 Stack 的 globalToLocal 转本地（消祖先缩放）');
    final String gridPageSrc = File(
      'lib/src/pages/implementations/media_collection_grid_detail_page.dart',
    ).readAsStringSync();
    expect(gridPageSrc.contains('HibikiReorderableGrid'), isTrue,
        reason: '书籍合集详情页必须用消缩放 2D 拖排网格（不得裸用 SDK/pub Reorderable 网格）');
    for (final String banned in <String>[
      'ReorderableListView.builder(',
      'ReorderableListView(',
      'ReorderableGridView',
      'ReorderableDelayedDragStartListener(',
      'ReorderableDragStartListener(',
    ]) {
      expect(gridPageSrc.contains(banned), isFalse,
          reason: 'SDK/pub Reorderable 在 UI 缩放下拖动漂移（BUG-778），详情页不得回潮（$banned）');
    }
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
    // 锚点锁的是**契约**（缩略图取该集自己的 coverPath、无封面退占位），不是某种
    // 具体渲染写法。旧判据 `contains('Image.file')` 把实现写法当契约：BUG-1299 把
    // `_episodeThumb` 从裸 `Image.file(...) + BoxFit.cover` 改成
    // `resolveMediaCoverImage(...)` + `PortraitCoverImage(landscapeSlot: true)`
    // 后（语义等价、仍是文件背书的 ImageProvider），锚点凭空消失、守卫误报红。
    final String thumbBody =
        methodBody(detailSrc, 'Widget _episodeThumb(VideoBookRow ep');
    expect(containsCodeLine(thumbBody, 'ep.coverPath'), isTrue,
        reason: '缩略图必须取该集自身的 coverPath（每集独立视频各有封面），'
            '不得回退成整个合集共用一张封面');
    expect(containsCodeLine(thumbBody, '_thumbPlaceholder('), isTrue,
        reason: '无封面 / 读取失败必须退占位图，不得留空或抛');
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
    // BUG-778：SDK ReorderableListView 的拖拽代理不认祖先 Transform.scale
    // （界面大小缩放下拖动漂移），详情页拖拽必须用自实现的
    // HibikiReorderableColumn（本地坐标消缩放）；裸 SDK 组件回潮即转红。
    expect(videoDetailSrc.contains('HibikiReorderableColumn'), isTrue,
        reason: '视频合集详情页必须支持拖拽排集（消缩放组件，手动排序的唯一形态）');
    // 盯真实使用 token（注释里提及组件名做解释是允许的）。
    for (final String banned in <String>[
      'ReorderableListView.builder(',
      'ReorderableListView(',
      'ReorderableDelayedDragStartListener(',
      'ReorderableDragStartListener(',
    ]) {
      expect(videoDetailSrc.contains(banned), isFalse,
          reason: 'SDK Reorderable 组件在 UI 缩放下拖动漂移（BUG-778），不得回潮（$banned）');
    }
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

  test('多端库联合视图（spec §2.1/§2.4）：远端占位卡混排主网格 + 撤独立远端分区零残留', () {
    final String remotePartSrc = File(
      'lib/src/pages/implementations/reader_history/remote.part.dart',
    ).readAsStringSync();

    // ① 撤独立远端分区：两页主文件与远端 part 都不得再有 _buildRemoteBookSection /
    // _buildRemoteVideoSection（方法定义 + 调用点全删），亦不得残留仅服务于旧分区
    // 的 RemoteVideoSectionHeader widget。恢复任一即转红（回退到独立远端分区）。
    for (final String banned in <String>[
      '_buildRemoteBookSection',
      '_buildRemoteVideoSection',
      'RemoteVideoSectionHeader',
    ]) {
      expect(historySrc.contains(banned), isFalse,
          reason: '书架不得残留独立远端分区接线（$banned）');
      expect(remotePartSrc.contains(banned), isFalse,
          reason: '书架远端 part 不得残留独立远端分区（$banned）');
      expect(homeSrc.contains(banned), isFalse,
          reason: '视频库不得残留独立远端分区接线（$banned）');
    }

    // ② 占位卡混排进主网格：远端卡渲染入口从主散卡路径调用（书=_ShelfBookSlot.remote
    // → _buildRemoteBookCard；视频=_VideoSlot union 混入 _groupVideos → _buildRemoteVideoCard），
    // 且带云角标 ☁。
    expect(historySrc.contains('slot.remote'), isTrue,
        reason: '书架散卡槽须承载远端占位（_ShelfBookSlot.remote）');
    expect(remotePartSrc.contains('_buildRemoteBookCard'), isTrue);
    expect(remotePartSrc.contains('remote_book_cloud_badge'), isTrue,
        reason: '远端书占位卡必须带云角标 ☁');
    expect(homeSrc.contains('_groupVideos(books, remoteVideos'), isTrue,
        reason: '远端视频占位须混入 _groupVideos（union 折叠 + 排序模式统一排序）');
    expect(homeSrc.contains('_buildRemoteVideoCard'), isTrue);
    expect(homeSrc.contains('remote_video_cloud_badge'), isTrue,
        reason: '远端视频占位卡必须带云角标 ☁');

    // ③ 「显示远端条目」开关 + 离线语义门控：两页混排前都读 showRemoteEntries；
    // 远端目录拉取失败（failed）门控占位卡不出现（离线=只剩本地）。
    expect(historySrc.contains('showRemoteEntries'), isTrue,
        reason: '书架混排远端占位前须读「显示远端条目」开关');
    expect(homeSrc.contains('showRemoteEntries'), isTrue,
        reason: '视频库混排远端占位前须读「显示远端条目」开关');
    expect(homeSrc.contains('state.failed'), isTrue,
        reason: '视频库须按远端拉取失败门控（离线不显示远端占位）');
  });

  test('BUG-777：书架 recency 读 reader_positions.updatedAt，假名次不回潮', () {
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
        reason: '关书必须同点失效 recency 映射（BUG-777 刷新语义）');
    // 书架页「最近阅读」排序读同一 recency 映射、没读过退 importedAt；provider
    // 下标假名次（实为导入序）不得回潮。（v49：继续阅读 hero/概览热力图已从书架页
    // 移到新首页 HomeDashboardPage，此处只守卫书架页仍在用的「最近阅读」排序语义。）
    expect(
        historySrc.contains('_lastReadAtByBookKey[bookKey] ?? it.importedAt'),
        isTrue,
        reason: '「最近阅读」= updatedAt，没读过按导入时间融入（与视频页语义镜像）');
    expect(historySrc.contains('payload.seq'), isFalse,
        reason: '列表下标假名次已删（provider 序 = importedAt 倒序，不是访问序）');
  });

  test('多端库联合视图 §2.2/§2.6：云视频占位必经 CloudRemoteVideoClient（不自造清单解析）', () {
    // 云后端分支必须经 CloudRemoteVideoClient（唯一清单解析入口）而非在页面里自己
    // ensureNamespace/读 videos.json/构造 RemoteVideoManifest——把解析散进页面即转红。
    expect(homeSrc.contains('CloudRemoteVideoClient'), isTrue,
        reason: '云视频目录/下载必须经 CloudRemoteVideoClient');
    expect(homeSrc.contains('_resolveCloudRemoteVideoClient'), isTrue,
        reason: '云后端分支：resolveSyncBackend 产物包进 CloudRemoteVideoClient');
    // TODO-2119：清单→RemoteVideoInfo 的适配已从页面搬进 CloudRemoteVideoClient
    // （原 `_cloudManifestToRemoteVideoInfo`）。页面现在只认 RemoteVideoSource 契约，
    // 连 RemoteVideoManifestEntry 这个类型都不该出现——给 RemoteVideoInfo 加字段时
    // 不必再回来改页面，漏改导致「云侧该字段永远为空」的坑就此消失。
    expect(homeSrc.contains('_cloudManifestToRemoteVideoInfo'), isFalse,
        reason: '清单→DTO 适配必须在 CloudRemoteVideoClient 里，不得回流页面');
    expect(homeSrc.contains('RemoteVideoManifestEntry'), isFalse,
        reason: '页面不得再感知清单条目类型（收敛到 CloudRemoteVideoClient）');
    // 页面不得自造清单解析（RemoteVideoManifest.fromJson 只应在 client 里）。
    expect(homeSrc.contains('RemoteVideoManifest.fromJson'), isFalse,
        reason: '页面不得自己解析 videos.json 清单（收敛到 CloudRemoteVideoClient）');
    expect(homeSrc.contains('kSyncVideosManifestName'), isFalse,
        reason: '页面不得直接触碰清单资产名（收敛到 CloudRemoteVideoClient）');
    // 下载统一走 RemoteVideoSource.downloadRemoteVideo：云盘实现内部委托给
    // getRemoteVideo 拉整文件（无 Range 续传），互联走 host live 引擎。页面不再按
    // 后端类型分派下载路径。
    expect(homeSrc.contains('source.downloadRemoteVideo('), isTrue,
        reason: '远端下载必须经 RemoteVideoSource.downloadRemoteVideo 统一入口');
    expect(homeSrc.contains('_registerDownloadedCloudVideo'), isTrue,
        reason: '云视频下载后必须建 VideoBooks 行（勿双重导入）');
    // 两个互斥 nullable client 字段已收成一个 source（TODO-2119）：能力差异由类型
    // 系统表达（source is RemoteVideoClient），不再靠「哪个字段非空」判后端。
    expect(homeSrc.contains('CloudRemoteVideoClient? _cloudRemoteVideoClient;'),
        isFalse,
        reason: '不得恢复「互联 client + 云 client」两个互斥字段（TODO-2119 回归）');
    expect(homeSrc.contains('RemoteVideoSource? _remoteVideoSource;'), isTrue,
        reason: '当前远端视频来源必须是单一真相字段');
  });

  test('多端库联合视图 §2.3 任务10：合集行成员占位归属解析不到 → 散卡降级（不硬造行）', () {
    // 两页都必须按 (name, type) 自然键把远端合集归属解析成本地合集 id，解析不到就
    // continue（散卡降级），绝不硬造本地无 id 的合集行。撤降级守卫即转红。
    for (final String src in <String>[homeSrc, historySrc]) {
      expect(src.contains('_resolveLocalCollectionId('), isTrue,
          reason: '远端合集归属须按 (name, type) 解析本地合集 id');
      expect(src.contains('if (cid == null) continue;'), isTrue,
          reason: '归属解析不到本地合集必须散卡降级（continue），不硬造合集行');
    }
    // 视频侧用 _VideoSlot union 把远端占位与本地成员折进同一合集行。
    expect(homeSrc.contains('_VideoSlot'), isTrue,
        reason: '视频远端占位须经 _VideoSlot union 折进合集行');
    // 书侧远端占位给真实 mediaType（epub），不再用私有 remote-book 伪类型（否则永不折叠）。
    expect(historySrc.contains("mediaType: 'remote-book'"), isFalse,
        reason: '远端书占位须给真实 mediaType（epub）才能与本地成员共键折叠');
  });

  test('BUG-790：视频合集卡集数 = 全部成员数（本地+远端占位同源），全云端合集不再显示「0 集」', () {
    // 根因：旧口径 localCount = group.items.where(local != null).length 只数本地成员，
    // 全为远端剧集的合集明明可见却显示「0 集」，与眼前所见割裂（用户实报）。
    // 封面卡形态下同一口径：集数角标必须喂 group.items.length（memberCount），
    // 回退到「只数本地」即转红。
    final int cardFn = homeSrc.indexOf('Widget _buildCollectionCoverCard(');
    expect(cardFn, isNonNegative, reason: '缺 _buildCollectionCoverCard');
    final int cardEnd = homeSrc.indexOf('\n  /// ', cardFn + 1);
    final String cardSrc =
        homeSrc.substring(cardFn, cardEnd < 0 ? homeSrc.length : cardEnd);

    // ① 集数不得再用「只数本地成员」的过滤式。
    expect(cardSrc.contains('.where((it) => it.payload.local != null).length'),
        isFalse,
        reason: 'BUG-790：不得再用「只数本地」过滤统计合集集数（localCount）');
    expect(RegExp(r'_buildPlaylistBadge\(\s*\w*[Ll]ocal').hasMatch(cardSrc),
        isFalse,
        reason: 'BUG-790：集数角标不得喂 localCount，须与成员总数同源');

    // ② 集数角标必须喂 group.items.length 派生的 memberCount。
    expect(
        cardSrc.contains('final int memberCount = group.items.length;'), isTrue,
        reason: 'BUG-790：memberCount 必须 = group.items.length（本地+远端占位同源）');
    expect(cardSrc.contains('_buildPlaylistBadge(memberCount)'), isTrue,
        reason: 'BUG-790：集数角标必须喂 memberCount');
  });
}
