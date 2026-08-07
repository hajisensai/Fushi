import 'dart:async' show StreamSubscription, unawaited;
import 'dart:io';

import 'package:drift/drift.dart' show Value;
// BUG-994：shellTab 覆写用（切回视频 tab 自动重拉远端，监听收口在基类）。
import 'package:fushi/src/pages/base_module_tab_page.dart';
import 'package:fushi/src/pages/implementations/home_page.dart' show HomeTab;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/focus/hibiki_focus_controller.dart';
import 'package:fushi/src/media/collections/collection_asset_reclaim.dart';
import 'package:fushi/src/media/drag_drop/card_drop_registry.dart';
import 'package:fushi/src/media/drag_drop/drop_classification.dart';
import 'package:fushi/src/media/drag_drop/drop_decision.dart';
import 'package:fushi/src/media/drag_drop/hibiki_file_drop_target.dart';
import 'package:fushi/src/media/video/cover_ui/cover_orientation_builder.dart';
import 'package:fushi/src/media/video/cover_ui/landscape_cover_image.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi/src/media/video/video_home_layout.dart';
import 'package:fushi/src/media/video/cover_ui/cover_match_dialog.dart';
import 'package:fushi/src/media/video/cover_ui/scrape_info_dialog.dart';
import 'package:fushi/src/media/metadata/scrape_batch.dart';
import 'package:fushi/src/media/video/scraper/alias_cache.dart';
import 'package:fushi/src/media/video/scraper/anilist_client.dart';
import 'package:fushi/src/media/video/scraper/auto_scrape_service.dart';
import 'package:fushi/src/media/video/scraper/bangumi_client.dart';
import 'package:fushi/src/media/video/scraper/jikan_client.dart';
import 'package:fushi/src/media/video/scraper/cover_meta_store.dart';
import 'package:fushi/src/media/video/scraper/offline_index.dart';
import 'package:fushi/src/media/video/scraper/cover_downloader.dart';
import 'package:fushi/src/media/video/scraper/collection_relations_scrape.dart';
import 'package:fushi/src/media/video/scraper/collection_scrape_apply.dart';
import 'package:fushi/src/media/video/scraper/cover_scraper_service.dart';
import 'package:fushi/src/media/video/scraper/scraper_types.dart';
import 'package:fushi/src/media/video/scraper/tmdb_client.dart';
import 'package:fushi/src/media/video/scraper/tmdb_default_key.dart';
import 'package:fushi/src/media/media_cover_service.dart';
import 'package:fushi/src/media/video/m3u8_playlist.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_subtitle_attach.dart';
import 'package:fushi/src/media/video/video_import_dialog.dart';
import 'package:fushi/src/media/video/video_library_overview.dart';
import 'package:fushi/src/media/video/video_mpv_config.dart';
import 'package:fushi/src/media/video/video_shader_downloader.dart';
import 'package:fushi/src/media/video/video_shader_manager.dart';
import 'package:fushi/src/media/video/video_shader_tier.dart';
import 'package:fushi/src/media/video/video_storage.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/book_drag_target.dart';
import 'package:fushi/src/pages/implementations/collections_page.dart';
import 'package:fushi/src/media/collections/add_to_collection_dialog.dart';
import 'package:fushi/src/media/collections/batch_combine.dart';
import 'package:fushi/src/media/collections/collection_context_dialog.dart';
import 'package:fushi/src/media/collections/collection_continue.dart';
import 'package:fushi/src/media/collections/collection_grouping.dart';
import 'package:fushi/src/media/collections/collection_one_key_sort.dart'
    show sortNewCollectionMembersNaturally;
import 'package:fushi/src/media/collections/shelf_sort.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/media/collections/collection_drag.dart';
import 'package:fushi/src/media/selection/media_selection_controller.dart';
import 'package:fushi/src/media/selection/selection_gestures.dart';
import 'package:fushi/src/media/collections/collection_shelf_row.dart';
import 'package:fushi/src/pages/implementations/jimaku_batch_dialog.dart';
import 'package:fushi/src/pages/implementations/media_collection_detail_page.dart';
import 'package:fushi/src/pages/implementations/media_item_dialog_page.dart';
import 'package:fushi/src/pages/implementations/media_sources_dialog.dart';
import 'package:fushi/src/pages/implementations/tag_filter_bar.dart';
import 'package:fushi/src/pages/implementations/tag_filter_sheet.dart';
import 'package:fushi/src/pages/implementations/tag_picker_page.dart';
import 'package:fushi/src/pages/implementations/video_hibiki_page.dart';
import 'package:fushi/src/pages/implementations/video_statistics_page.dart';
import 'package:fushi/src/sync/deletion_prompt.dart';
import 'package:fushi/src/sync/deletion_propagation.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/manual_sync_ui.dart';
import 'package:fushi/src/sync/remote_download_progress_badge.dart';
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'package:fushi/src/sync/cloud_remote_video_client.dart';
import 'package:fushi/src/sync/remote_cover_image.dart';
import 'package:fushi/src/sync/remote_library_cache.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_progress_banner.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/utils/components/batch_tag_dialog_frame.dart';
import 'package:fushi/src/utils/cover_image.dart';
import 'package:fushi/src/pages/implementations/collection_name_dialog.dart';
import 'package:fushi/src/media/video/video_filename_parser.dart';
import 'package:fushi/src/utils/misc/shelf_ordering.dart';
import 'package:path/path.dart' as p;

/// 顶层 helper：打开本地视频播放页的**共享路由入口**（本页 hero/卡片与首页
/// dashboard 继续卡/活动条同一条路径），统一经 [VideoHibikiPage.neutralized]
/// 在路由层中和全局缩放（video_render_fixes_guard 守卫的接线）。
/// [playlistCollectionId] 非空 = 作为合集一集打开（剧集面板/上下集/连播），
/// null = 散卡单视频。返回的 Future 在播放页关闭后完成（调用方据此刷新）。
Future<void> openLocalVideoBook({
  required BuildContext context,
  required VideoBookRepository repo,
  required String bookUid,
  int? playlistCollectionId,
}) {
  return Navigator.push(
    context,
    adaptivePageRoute<void>(
      context: context,
      builder: (_) => VideoHibikiPage.neutralized(
        bookUid: bookUid,
        repo: repo,
        playlistCollectionId: playlistCollectionId,
      ),
    ),
  );
}

/// 首页「视频」tab 的内容：已导入视频的库（独立于书架的 EPUB/有声书分区）。
///
/// 仅在实验性视频开关开启时由 [HomePage] 装配进底栏（见 home_page.dart 的
/// [HomeTab.video]）。列出 [VideoBookRepository.listAll] 的视频卡片，点开进
/// [VideoHibikiPage] 播放/查词/制卡；顶栏导入按钮（同样受实验开关门控）打开
/// [VideoImportDialog] 新建导入，与书架的视频导入入口共用同一对话框与仓库。
///
/// 标签：视频书与书架（EPUB/SRT）**共用同一套标签系统**（共享 `BookTags` 标签池
/// + `video_book_tag_mappings` 映射）。顶部有标签筛选栏（共享 [selectedTagIdsProvider]，
/// 与书架联动），卡片渲染所挂标签，长按弹菜单（编辑标签 / 设置封面 / 删除）。
class HomeVideoPage extends BaseModuleTabPage {
  const HomeVideoPage({
    required this.repo,
    this.navigation,
    this.remoteVideoClientLoader,
    this.cloudRemoteVideoClientLoader,
    this.remoteVideoDownloadDestination,
    super.key,
  });

  final VideoBookRepository repo;

  /// 库页视图导航条（由 [MediaLibraryShell] 传入，作为页头主内容与动作同一行）。
  /// 本页被独立使用时为 null，页头与此前逐像素一致。
  final Widget? navigation;
  final Future<RemoteVideoClient?> Function()? remoteVideoClientLoader;

  /// 测试钩子（多端库联合视图 §2.2/§2.6）：注入云视频目录 client（[CloudRemoteVideoClient]），
  /// 让「云后端 → 云视频占位卡混排 + 按 uid 下载入库」在 widget 测试可落地。缺省时
  /// 生产路径经 [_resolveCloudRemoteVideoClient]（resolveSyncBackend 产物包进 client）。
  final Future<CloudRemoteVideoClient?> Function()?
      cloudRemoteVideoClientLoader;
  final Future<File> Function(RemoteVideoInfo video)?
      remoteVideoDownloadDestination;

  /// 测试钩子：强制重查本地视频列表（程序化 seed 视频后让其出现在网格）。
  /// 视频页用 initState 一次性 FutureBuilder + IndexedStack 保活，seed 晚于
  /// 首次查询时不会自动重查；仅 debug/profile build 在 initState 注册。
  @visibleForTesting
  static void Function()? debugRefreshVideos;

  @override
  BaseModuleTabPageState<HomeVideoPage> createState() => _HomeVideoPageState();
}

class _HomeVideoPageState extends BaseModuleTabPageState<HomeVideoPage> {
  Future<List<VideoBookRow>>? _future;
  Future<_RemoteVideoState?>? _remoteFuture;

  /// 当前远端视频来源：互联 host live 库 或 云盘目录，**至多一个**（TODO-2119）。
  ///
  /// 此前是 `_remoteVideoClient` + `_cloudRemoteVideoClient` 两个互斥 nullable 字段，
  /// 每条下载/封面/字幕路径都要 `if (cloud != null) ... else ...` 分派，两个字段还可能
  /// 被写得不同步。收成一个之后「谁是当前源」只有一个真相，能力差异改由类型系统表达：
  /// 只有 [RemoteVideoClient]（live）才有流播/字幕/断点，见 [_liveVideoClient]。
  RemoteVideoSource? _remoteVideoSource;

  /// 当前源的 live 能力视图；云盘源在这里是 null。拿不到它的地方**编译期**就调不出
  /// 流播/字幕/断点方法，而不是运行时抛异常。
  RemoteVideoClient? get _remoteVideoClient {
    final RemoteVideoSource? source = _remoteVideoSource;
    return source is RemoteVideoClient ? source : null;
  }

  /// 当前源的云盘视图；互联源在这里是 null。仅用于云盘独有的收尾动作
  /// （下载后按资产名取封面，见 [_registerDownloadedCloudVideo]）。
  CloudRemoteVideoClient? get _cloudRemoteVideoClient {
    final RemoteVideoSource? source = _remoteVideoSource;
    return source is CloudRemoteVideoClient ? source : null;
  }

  /// 远端清单的共享 TTL 缓存（BUG-1180）。与书架 / 首页 dashboard 同一实例
  /// （app 级 provider），切 tab 不再必然重打一轮网络。
  RemoteLibraryCache get _remoteCache => ref.read(remoteLibraryCacheProvider);

  /// BUG-793：视频库 uid 集合监听。列表是一次性 FutureBuilder + 保活 tab，无此
  /// 订阅时非本页发起的导入（外部「用 Hibiki 打开」等直接落库不 _refresh 的路径）
  /// 要等下拉刷新/重启才出现。订阅 videoBooks 表 → 集合一变（插入/删除）就 _refresh。
  StreamSubscription<List<String>>? _videoUidsSub;

  /// 上一次已知的视频 uid 集合，用于对 [_videoUidsSub] 事件去重：仅集合变化才刷新，
  /// 封面自愈 / 进度回写等纯列更新（集合不变）跳过，避免写回→重刷环。null=尚未收到
  /// 首个事件（首事件仅登记基线，不刷——initState 已首载）。
  Set<String>? _knownVideoUids;

  /// 视频卡片拖放命中注册表：每张 [CardDropZone] 注册自身几何，拖放时按屏幕坐标
  /// 命中查找目标视频卡（字幕外挂到该视频）。范型=VideoBookRow。
  final CardDropRegistry<VideoBookRow> _cardDropRegistry =
      CardDropRegistry<VideoBookRow>();

  /// 批量选择模式（与书架 tab 对齐）。开启后卡片点击切换勾选、长按/拖放禁用，
  /// 底部弹批量操作栏（打标签 / 删除）。视频书是扁平 bookUid（不像书架有
  /// epub `mediaIdentifier` + `srt_` 双类前缀），故选择集直接用 bookUid 字符串。
  /// 与书架 tab 共用的多选状态机（[MediaSelectionController]）：模式位、散卡选中集、
  /// 合集整选集、Shift / 长按扫选的锚点全在里面。下面三个 getter 保留旧字段名，
  /// 让本页几十处读取点原样成立。
  final MediaSelectionController _selection = MediaSelectionController();

  bool get _selectionMode => _selection.active;

  Set<String> get _selectedUids => _selection.looseKeys;

  /// 多选态合集整选（块2）：选中合集 id 集，与散卡选中集 [_selectedUids] 并存。
  /// 组合三档判定（块3）与批量解散/删除（块4）都读这两个集。
  Set<int> get _selectedCollectionIds => _selection.collectionIds;

  /// 当前可见（过滤后）的本地视频列表，供全选 / 反选用。
  List<VideoBookRow> _visibleVideos = const <VideoBookRow>[];

  /// 当前渲染成横排行的合集 id 列表（[_buildLocalVideoSlivers] 每帧写入），供
  /// 全选 / 反选把可见合集纳入整选集。
  List<int> _visibleCollectionIds = const <int>[];

  /// 上一次成功加载的全量列表缓存：_refresh/封面补齐把 [_future] 换新期间用它
  /// 顶住渲染，**不再整页转圈**（旧行为=每抽一张封面/每次从播放器返回都闪一次
  /// 全页 spinner，用户报「一直在刷新」）。仅首载（缓存空）才显示加载圈。
  List<VideoBookRow>? _videosCache;

  /// BUG-994：上次成功的远端视频态。自动刷新/重拉（_remoteFuture 换新→waiting、data
  /// 暂为 null）期间沿用，避免远端占位卡整批闪一下（对称本地 [_videosCache]、书架
  /// `_lastRemoteState`）。失败态不覆盖缓存。
  _RemoteVideoState? _lastRemoteState;

  /// 统一合集：本会话已尝试后台抽封面的 bookUid（避免每次刷新对同一行重试 ffmpeg）。
  final Set<String> _coverBackfillAttempted = <String>{};

  /// 条目自动刮削调度器（懒建，随页面 dispose 停）。见 [_maybeAutoScrape]。
  VideoScrapeAutoService? _autoScrape;

  /// 后台封面补齐进行中标志（防并发重入）。
  bool _backfillingCovers = false;

  /// 排序交互重设计层次 A：当前排序方式（偏好 `video_sort_mode` 持久化，默认
  /// 最近观看，用户拍板）。旧 `ShelfEntries.sortOrder` 手动权重已废弃不再读取。
  ShelfSortMode _sortMode = ShelfSortMode.recent;

  /// P5-A：视频库搜索词（原文，匹配时才归一化）。**刻意不持久化**——下次进
  /// 视频库还挂着上次的搜索词只会让人以为库空了（与书架/游戏库页同一决定）。
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  /// 层次 C：`'video|<uid>' → 该条目在其主折叠合集里的 sortIndex`（组内序真相源，
  /// 与详情页/播放器 `getCollectionItems` 同源——详情页拖完库页行立即同序）。
  Map<String, int> _memberSortIndex = const <String, int>{};

  /// 统一合集 Phase 4：视频合集字典（id → 行）+ 条目折叠归属（'video|uid' → 最小
  /// collectionId），与 [_memberSortIndex] 同一次 [_loadLibraryMaps] 预取。
  Map<int, MediaCollectionRow> _collectionsById =
      const <int, MediaCollectionRow>{};
  Map<String, int> _primaryCollectionByEntry = const <String, int>{};

  /// UI v2 Phase B / v39：最近观看时间（watch-stats max(lastModified)），驱动
  /// 「继续观看 hero」排序与「上次观看」外显。v39 起按 bookUid 键控；迁移遗留
  /// NULL-uid 行按 title 回退。与 [_loadLibraryMaps] 同批预取。
  Map<String, DateTime> _watchAtByUid = const <String, DateTime>{};
  Map<String, DateTime> _legacyWatchAtByTitle = const <String, DateTime>{};

  /// TODO-2486：条目刮削年份（uid → 年份；无资料不入映射 = 「未知」桶）与合集
  /// 刮削资料（hero 轮播的 backdrop / 简介 / airDate），与 [_loadLibraryMaps]
  /// 同批预取（批量 DAO，无 N+1）。
  Map<String, int> _airYearByUid = const <String, int>{};

  /// 条目刮削资料整行（uid → 行）：散装单元上 hero 时的简介/放送日期数据源
  /// （v68 hero 收散装）。与 [_airYearByUid] 同一次全表查询派生。
  Map<String, VideoScrapeMetaRow> _videoScrapeMetaByUid =
      const <String, VideoScrapeMetaRow>{};
  Map<int, CollectionScrapeMetaRow> _collectionScrapeMetaById =
      const <int, CollectionScrapeMetaRow>{};

  /// v68 附加图组（media_images）按归属分桶：合集（hero 背景/logo、续播行横卡）
  /// 与散装视频（续播行横卡）。与 [_loadLibraryMaps] 同批预取（一次全表查询）。
  Map<int, List<MediaImageRow>> _mediaImagesByCollection =
      const <int, List<MediaImageRow>>{};
  Map<String, List<MediaImageRow>> _mediaImagesByBookUid =
      const <String, List<MediaImageRow>>{};

  /// TODO-2486：年份 / 看完状态下拉筛选（本地即筛，刻意不持久化——与搜索词同
  /// 一决定：下次进库还挂着上次的筛选只会让人以为库空了）。
  VideoYearFilter _yearFilter = const VideoYearFilter.all();
  VideoWatchStatusFilter _watchStatusFilter = VideoWatchStatusFilter.all;

  /// TODO-2486：hero 轮播控制器 + 当前页。手动切换（滑动/指示条），**无自动
  /// 轮播**（尊重 prefers-reduced-motion 精神）。
  final PageController _heroPageController = PageController();
  int _heroPage = 0;

  /// TODO-2486：横滚行控制器（WheelToHorizontalScroll 滚轮桥需要显式 controller）。
  final ScrollController _continueRowController = ScrollController();
  final ScrollController _recentRowController = ScrollController();

  @override
  void initState() {
    super.initState();
    // TODO-1255：书架展示走 listForShelf（自愈数据根迁移遗弃的封面路径）。
    _future = widget.repo.listForShelf();
    _remoteFuture = _loadRemoteVideos();
    // 首帧就预取分组/排序映射（合集折叠首绘就要 _collectionsById，不能等刷新）。
    _loadLibraryMaps();
    // 统一合集：后台给缺封面的各集补抽封面（拆集/迁移拆出的非首集、每集独立视频应各有封面）。
    _maybeBackfillCovers();
    // 条目自动刮削：进页面补刮还没有资料的本地视频（取代旧页头「批量匹配海报」按钮）。
    unawaited(_maybeAutoScrape());
    // BUG-793：订阅 videoBooks 表，任意导入路径落库后自动刷新库页。
    _videoUidsSub =
        widget.repo.watchVideoBookUids().listen(_onVideoUidsChanged);
    // BUG-1182：「显示远端条目」开关落在 prefsRepo（独立 ChangeNotifier），不经
    // AppModel 通知，本页不会因它重建 → 门控翻转后既不重取也不重渲染。显式订阅。
    // 用 appModelNoUpdate：initState 里读 appModel 会走 ref.watch，触发
    // 「initState 完成前依赖 InheritedWidget」断言。
    // （门控基线已由上面的 _loadRemoteVideos() 首帧取数写入 _remoteGateAtLastLoad。）
    appModelNoUpdate.prefsRepo.addListener(_onPrefsChangedForRemoteGate);
    assert(() {
      HomeVideoPage.debugRefreshVideos = _refresh;
      return true;
    }());
  }

  // BUG-994：顶层 tab 保活后，切回视频 tab 不再隐式重拉远端 → 远端视频要手动
  // 下拉刷新才出来（与书架 BUG-816 同病）。shell tab 信号监听三件套已收口到
  // BaseModuleTabPageState（shellTab / onTabActivated），切回视频 tab 时自动
  // 重拉一次远端视频（_lastRemoteState 缓存顶住 waiting、不闪屏）。
  @override
  HomeTab get shellTab => HomeTab.video;

  @override
  void onTabActivated() {
    setState(() {
      _remoteFuture = _loadRemoteVideos();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _heroPageController.dispose();
    _continueRowController.dispose();
    _recentRowController.dispose();
    _videoUidsSub?.cancel();
    _autoScrape?.dispose();
    appModelNoUpdate.prefsRepo.removeListener(_onPrefsChangedForRemoteGate);
    assert(() {
      HomeVideoPage.debugRefreshVideos = null;
      return true;
    }());
    super.dispose();
  }

  /// BUG-793：视频库 uid 集合变化回调。首个事件仅登记基线（initState 已首载）；
  /// 此后仅当集合真变化（插入/删除）才 _refresh——纯列更新（封面自愈 / 进度回写）
  /// 集合不变故跳过，避免自愈写回→重刷环。
  void _onVideoUidsChanged(List<String> uids) {
    final Set<String> next = uids.toSet();
    if (_knownVideoUids == null) {
      _knownVideoUids = next;
      return;
    }
    if (setEquals(next, _knownVideoUids)) return;
    _knownVideoUids = next;
    if (mounted) _refresh();
    // 集合真变了 = 有新视频入库（任意导入路径）：给新书补刮条目资料。挂在这里而
    // 不是 _refresh 里，因为 _refresh 还被改标签/删除/播放返回等触发，那些不带来
    // 需要刮削的新书。
    unawaited(_maybeAutoScrape());
  }

  /// 刷新库页。默认只刷**本地**（书架列表 + 分组映射 + 封面自愈）；远端互联清单
  /// 不因本地播放/导入/标签变化而改变，故不重拉，避免「看完视频返回→远端卡整片闪空
  /// 重新加载」（远端那层 FutureBuilder 无缓存顶值，future 一换即清空重拉）。
  /// 只有真正改变远端来源的路径（[_openManageSources]）才传 `remote: true` 重拉清单；
  /// 用户主动刷新走下拉 [_pullToRefresh]。
  void _refresh({bool remote = false}) {
    setState(() {
      // TODO-1255：书架展示走 listForShelf（自愈数据根迁移遗弃的封面路径）。
      _future = widget.repo.listForShelf();
      if (remote) _remoteFuture = _loadRemoteVideos();
    });
    _loadLibraryMaps();
    _maybeBackfillCovers();
  }

  /// 下拉刷新 = **手动同步**：先跑一遍云备份 / 互联同步，再强制重拉远端视频列表 + 本地
  /// 列表，await 全程完成后指示器才收起。
  ///
  /// 顶层 tab 保活（[HomePage] 的 `_keepAliveTabs`）后，切回视频 tab 不再隐式重拉远端，
  /// 故给用户一个**显式**强制刷新入口——别的设备新上传的互联视频，不重启 app 也能刷出来。
  ///
  /// 同步排在重读列表**之前**：同步会往本地库里落新视频和观看进度，先刷列表就会漏掉
  /// 本次同步的产物。没配同步后端时 [runManualSyncWithFeedback] 直接返回 notConfigured
  /// 且不弹提示，退化成纯列表刷新——与加同步之前的行为一字不差。
  /// [_loadRemoteVideos] 内部吞异常返回 `failed:true`，await 不会抛，指示器必定收起
  /// （客户端 [listRemoteVideos] 已用 listTimeout 封顶，host 卡响应也不会无限转圈）。
  /// 显式刷新失败时给一个可见 SnackBar（带原因），避免「看不到远端视频却不知为何」。
  Future<void> _pullToRefresh() async {
    await runManualSyncWithFeedback(
      context: context,
      appModel: ref.read(appProvider),
      // 绝大多数用户没配云同步，每次下拉都弹「同步不可用」是纯噪音；已有同步在飞时
      // 用户下拉，数据照样会更新，不必打断。冲突/错误提示仍然照给。
      announceNotConfigured: false,
      announceBusy: false,
    );
    if (!mounted) return;
    // 显式下拉 = 用户要最新的：强制穿透 [RemoteLibraryCache] 的 TTL（BUG-1180）。
    final Future<_RemoteVideoState?> remote = _loadRemoteVideos(
      forceRefresh: true,
    );
    if (mounted) {
      setState(() {
        _future = widget.repo.listForShelf();
        _remoteFuture = remote;
      });
    }
    _loadLibraryMaps();
    _maybeBackfillCovers();
    final _RemoteVideoState? state = await remote;
    if (!mounted) return;
    if (state != null && state.failed) {
      // 只给用户一句本地化、可执行的友好提示；原始异常（TimeoutException /
      // SocketException 等开发者文本）绝不进 UI，只留在下方 debugPrint 供排查。
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.remote_video_list_failed)),
      );
    }
  }

  /// 一次性预取库页排序/分组所需映射：合集字典、折叠归属、组内 sortIndex、
  /// watch-stats 最近观看，外加偏好里的排序方式。
  Future<void> _loadLibraryMaps() async {
    final AppModel appModel = ref.read(appProvider);
    final FushiDatabase db = appModel.database;
    final ShelfSortMode sortMode =
        ShelfSortMode.fromName(appModel.prefsRepo.videoSortModeName);
    final List<MediaCollectionRow> collections =
        await db.getAllMediaCollections();
    final Map<String, int> primaryMap =
        await db.getPrimaryCollectionIdByEntry();
    // 层次 C：条目在其主折叠合集里的 sortIndex（只记归属合集的行——一条目属多
    // 合集时行内序跟随折叠归属，与 primaryMap 同口径）。一次 [getAllCollectionItems]
    // 查全部成员内存分组，替代逐合集 [getCollectionItems] 的 N+1（合集越多越慢，
    // 首屏合集行渲染被它 gate）。判据 `primaryMap[key] == m.collectionId` 与旧
    // 逐合集 `== c.id` 等价（旧循环里 members 的 collectionId 恒为 c.id）。
    final Map<String, int> memberSortIndex = <String, int>{};
    for (final MediaCollectionItemRow m in await db.getAllCollectionItems()) {
      final String key = '${m.mediaType}|${m.entryKey}';
      if (primaryMap[key] == m.collectionId) memberSortIndex[key] = m.sortIndex;
    }
    // UI v2 Phase B / v39：watch-stats 全量行 → 最近观看时间（内存聚合）。
    // v39 新行按 bookUid 键控；迁移遗留 NULL-uid 行按 title 建回退映射。
    final List<VideoWatchStatisticRow> watchRows =
        await db.getAllVideoWatchStatistics();
    final Map<String, DateTime> watchByUid = latestWatchAtByKey(
      <(String, int)>[
        for (final VideoWatchStatisticRow r in watchRows)
          if (r.bookUid case final String uid) (uid, r.lastModified),
      ],
    );
    final Map<String, DateTime> legacyByTitle = latestWatchAtByKey(
      <(String, int)>[
        for (final VideoWatchStatisticRow r in watchRows)
          if (r.bookUid == null) (r.title, r.lastModified),
      ],
    );
    // TODO-2486：刮削资料批量预取——条目 airDate 派生年份（年份筛选）、合集资料
    // （hero 轮播）。批量 DAO 全表一次拉，替代逐本/逐合集查询的 N+1。
    final List<VideoScrapeMetaRow> scrapeRows =
        await db.getAllVideoScrapeMeta();
    final Map<String, int> airYearByUid = <String, int>{
      for (final VideoScrapeMetaRow r in scrapeRows)
        if (videoAirYear(r.airDate) case final int year) r.bookUid: year,
    };
    final Map<String, VideoScrapeMetaRow> scrapeMetaByUid =
        <String, VideoScrapeMetaRow>{
      for (final VideoScrapeMetaRow r in scrapeRows) r.bookUid: r,
    };
    final Map<int, CollectionScrapeMetaRow> collectionMetaById =
        <int, CollectionScrapeMetaRow>{
      for (final CollectionScrapeMetaRow r
          in await db.getAllCollectionScrapeMeta())
        r.collectionId: r,
    };
    // v68 附加图组：一次全表查询按归属分桶（hero 背景/logo、续播行横卡）。
    final Map<int, List<MediaImageRow>> imagesByCollection =
        <int, List<MediaImageRow>>{};
    final Map<String, List<MediaImageRow>> imagesByBookUid =
        <String, List<MediaImageRow>>{};
    for (final MediaImageRow row in await db.getAllMediaImages()) {
      final int? cid = row.collectionId;
      if (cid != null) {
        (imagesByCollection[cid] ??= <MediaImageRow>[]).add(row);
      } else if (row.bookUid case final String uid) {
        (imagesByBookUid[uid] ??= <MediaImageRow>[]).add(row);
      }
    }
    if (mounted) {
      setState(() {
        _sortMode = sortMode;
        _memberSortIndex = memberSortIndex;
        _collectionsById = <int, MediaCollectionRow>{
          for (final MediaCollectionRow c in collections) c.id: c,
        };
        _primaryCollectionByEntry = primaryMap;
        _watchAtByUid = watchByUid;
        _legacyWatchAtByTitle = legacyByTitle;
        _airYearByUid = airYearByUid;
        _videoScrapeMetaByUid = scrapeMetaByUid;
        _collectionScrapeMetaById = collectionMetaById;
        _mediaImagesByCollection = imagesByCollection;
        _mediaImagesByBookUid = imagesByBookUid;
      });
    }
  }

  /// 附加图组里按种类偏好取首张可用图的 provider（文件悬空 = 视作没有）。
  /// 探测与渲染共用 [resizedFileImage] 的解码缓存键，零额外解码。
  ImageProvider? _mediaImageProvider(
    List<MediaImageRow>? rows,
    List<MediaImageKind> preference,
  ) {
    if (rows == null) return null;
    for (final MediaImageKind kind in preference) {
      for (final MediaImageRow row in rows) {
        if (row.kind != kind.dbValue || row.path.isEmpty) continue;
        final File file = File(row.path);
        if (file.existsSync()) return resizedFileImage(file);
      }
    }
    return null;
  }

  /// 用户切换排序方式：立即重排 + 偏好持久化（跨启动记住）。
  void _setSortMode(ShelfSortMode mode) {
    if (mode == _sortMode) return;
    setState(() => _sortMode = mode);
    unawaited(
      ref.read(appProvider).prefsRepo.setVideoSortModeName(mode.name),
    );
  }

  /// 统一合集 Phase 2/6：给「缺封面的本地视频行」后台逐个抽一帧当封面。
  ///
  /// 播放列表拆集导入 / v38 迁移拆出的各集，只有首集在导入时承接了封面，其余各集
  /// `cover_path` 为空——但每集本是**独立视频**，理应各自有封面（对齐 Jellyfin 每集
  /// 缩略图）。ffmpeg 抽帧慢（最长 30s/次），绝不能挡列表加载：列表已就绪后**后台逐个
  /// 补**，每抽好一张 [VideoBookRepository.updateCover] 回写并刷新一次（渐进出现）。
  /// 本会话记 [_coverBackfillAttempted] 避免每次刷新对同一行重试（移动端无 ffmpeg 抽帧
  /// 返 null 时也只试一次）；[_backfillingCovers] 防并发重入。流 URL 行跳过（无本地帧可
  /// 抽，host 元数据封面另走）。
  Future<void> _maybeBackfillCovers() async {
    if (_backfillingCovers) return;
    _backfillingCovers = true;
    try {
      final List<VideoBookRow> rows = await widget.repo.listAll();
      for (final VideoBookRow row in rows) {
        if (!mounted) return;
        if (_coverBackfillAttempted.contains(row.bookUid)) continue;
        final String? cover = row.coverPath;
        if (cover != null && cover.isNotEmpty && File(cover).existsSync()) {
          continue; // 已有封面。
        }
        final String path = row.videoPath;
        if (path.isEmpty ||
            path.startsWith('http://') ||
            path.startsWith('https://')) {
          continue; // 流 URL：无本地帧可抽。
        }
        _coverBackfillAttempted.add(row.bookUid);
        final String? extracted =
            await extractVideoCover(videoPath: path, bookUid: row.bookUid);
        if (extracted == null) continue;
        await widget.repo.updateCover(row.bookUid, extracted);
        if (!mounted) return;
        setState(() => _future = widget.repo.listForShelf());
      }
    } finally {
      _backfillingCovers = false;
    }
  }

  Future<RemoteVideoClient?> _resolveRemoteVideoClient() async {
    final Future<RemoteVideoClient?> Function()? injected =
        widget.remoteVideoClientLoader;
    if (injected != null) return injected();

    final AppModel appModel = ref.read(appProvider);
    final SyncRepository syncRepo = SyncRepository(appModel.database);
    // 互联已从 backendType 解耦成独立开关，可与云备份并存：互联启用且已配对时用它的
    // live 库；未启用则本方法返 null，`_loadRemoteVideos` 回退云视频占位卡。
    if (!await syncRepo.isInterconnectEnabled()) return null;
    final InterconnectSyncBackend backend = InterconnectSyncBackend.instance;
    if (!await backend.restoreAuth(syncRepo)) return null;
    return backend;
  }

  /// 多端库联合视图 §2.2/§2.6 云后端分支：把 `resolveSyncBackend` 的产物（含解混淆
  /// 装饰层）包进 [CloudRemoteVideoClient]，读 `__videos__/videos.json` 目录清单渲染
  /// 云视频占位卡 + 按 uid 下载入库。与书侧 `_resolveRemoteBookClient` 云分支同范式；
  /// 互联后端（hibikiServer）走 [_resolveRemoteVideoClient]，此处只对云盘后端出 client，
  /// 鉴权失败/无后端返 null（不显示云视频占位）。
  Future<CloudRemoteVideoClient?> _resolveCloudRemoteVideoClient() async {
    final Future<CloudRemoteVideoClient?> Function()? injected =
        widget.cloudRemoteVideoClientLoader;
    if (injected != null) return injected();

    final AppModel appModel = ref.read(appProvider);
    final SyncRepository syncRepo = SyncRepository(appModel.database);
    final SyncBackendType type = await syncRepo.getBackendType();
    // 互联后端不在此处理（已由 _resolveRemoteVideoClient 覆盖）。
    if (type == SyncBackendType.hibikiServer) return null;
    final SyncBackend backend = resolveSyncBackend(type);
    if (!await backend.restoreAuth(syncRepo)) return null;
    return CloudRemoteVideoClient(backend: backend, backendType: type);
  }

  /// 是否应该去问远端要视频清单。
  ///
  /// BUG-1182：`showRemoteEntries` 开关此前只在渲染期的 [_visibleRemoteVideos] 生效，
  /// 拉取照发不误——关掉「显示远端条目」的用户仍全额付网络代价，只是结果被丢弃。
  /// 门控前移到取数之前。
  bool get _shouldLoadRemoteVideos =>
      appModelNoUpdate.prefsRepo.showRemoteEntries;

  /// 上一次取数时 [_shouldLoadRemoteVideos] 的值（BUG-1182），用于识别开关翻转。
  bool _remoteGateAtLastLoad = true;

  /// prefsRepo 变更回调：只关心「显示远端条目」门控是否翻转。其余偏好变动一概忽略
  /// ——prefsRepo 的通知很频繁，不能每次都去动远端 future。
  void _onPrefsChangedForRemoteGate() {
    if (!mounted) return;
    final bool gate = _shouldLoadRemoteVideos;
    if (gate == _remoteGateAtLastLoad) return;
    _remoteGateAtLastLoad = gate;
    setState(() {
      _remoteFuture = _loadRemoteVideos();
    });
  }

  Future<_RemoteVideoState?> _loadRemoteVideos({
    bool forceRefresh = false,
  }) async {
    _remoteGateAtLastLoad = _shouldLoadRemoteVideos;
    if (!_shouldLoadRemoteVideos) {
      _remoteVideoSource = null;
      return null;
    }
    // TODO-2119：互联优先、否则回退云盘；两者都是 [RemoteVideoSource]，所以下面
    // 「列清单 → 去重 → 出占位卡」这条主干只写一遍，不再按后端类型分叉。
    final RemoteVideoSource? source = await _resolveRemoteVideoClient() ??
        await _resolveCloudRemoteVideoClient();
    _remoteVideoSource = source;
    if (source == null) return null;
    try {
      // BUG-1180：经共享缓存取清单——切回视频 tab（[onTabActivated]）不再必然打一轮
      // 网络，TTL 内直接复用。缓存只包住「问对端要清单」这一步，下面的本地库查询与
      // 去重仍每次照跑，本地新增/删除的视频立即反映在混排网格里。
      //
      // 槽 = 来源身份 + 域（BUG-1202）。上面那行 `?? ` 让本方法**故意**不知道拿到的
      // 是互联还是云盘，所以来源身份只能由 source 自己申报；靠调用点分辨来源、或靠
      // 「换后端时记得失效」都治不了串味（换云盘后端根本不经过互联的失效信号）。
      final List<RemoteVideoInfo> videos = await _remoteCache.read(
        sourceId: source.remoteLibrarySourceId,
        key: RemoteLibraryCacheKeys.videos,
        forceRefresh: forceRefresh,
        fetch: source.listRemoteVideos,
      );
      // #6: 远端与本地是同一视频时（同 bookUid）不在混排网格重复展示。
      final List<VideoBookRow> localVideos = await widget.repo.listAll();
      final Set<String> localUids =
          localVideos.map((VideoBookRow r) => r.bookUid).toSet();
      return _RemoteVideoState(
        videos: dedupeRemoteVideos(remote: videos, localBookUids: localUids),
      );
    } catch (e) {
      // spec §2.4 离线语义：拉取失败 → 占位卡不出现（failed 门控），只剩本地库。
      // 云盘侧清单结构非法（FormatException）也落这里 → 本轮云视频不可用。
      // 原始异常只落 debugPrint 供排查；显式下拉刷新时的用户可见反馈用本地化友好
      // 文案（见 _pullToRefresh），不把 TimeoutException 等开发者文本泄漏进 UI。
      debugPrint('[home-video] remote video list failed: $e');
      return _RemoteVideoState(
        videos: const <RemoteVideoInfo>[],
        failed: true,
      );
    }
  }

  /// 多端库联合视图（spec §2.1/§2.4/§2.5）：解析可混排进主网格的远端占位视频。
  ///
  /// 门控：① 「显示远端条目」开关关闭 → 空；② 远端目录拉取失败/未配对/无后端
  /// （[state] == null 或 [_RemoteVideoState.failed]）→ 空（离线=只剩本地，占位卡不
  /// 出现）；③ 标签筛选激活（[filter] != null）→ 空（远端视频无本地标签，不参与
  /// 筛选）。其余情况返回去重后的远端视频列表。
  List<RemoteVideoInfo> _visibleRemoteVideos(
    _RemoteVideoState? state,
    Set<String>? filter,
  ) {
    if (!ref.read(appProvider).prefsRepo.showRemoteEntries) {
      return const <RemoteVideoInfo>[];
    }
    if (state == null || state.failed) return const <RemoteVideoInfo>[];
    if (filter != null) return const <RemoteVideoInfo>[];
    return state.videos;
  }

  /// 标签改动（加/删/换书）后刷新：失效共享标签 provider + 重载视频列表。
  void _refreshAfterTagChange() {
    ref.invalidate(videoBookTagMapProvider);
    ref.invalidate(filteredVideoBookUidsProvider);
    ref.invalidate(allTagsProvider);
    _refresh();
  }

  // ── 批量选择（与书架 tab 对齐）────────────────────────────────────
  // 书架 [reader_hibiki_history_page] 早有这套（_selectionMode / _selectedKeys /
  // 批量打标签 + 删除）；视频 tab 共用同一 [FushiTagFilterBar]（其 selectionMode /
  // onToggleSelectionMode 入参书架已用、视频此前没传）。这里给视频补上 wiring，
  // 批量操作语义对齐书架（批量打标签 + 批量删除），但因视频书是扁平 bookUid，
  // 选择集与 picker 比书架简单一层（无 epub/srt 双类分支）。

  void _toggleSelectionMode() {
    setState(_selection.toggleMode);
  }

  void _exitSelectionMode() {
    setState(_selection.exit);
  }

  /// 散卡点击：普通点击切换 + 设锚点，Shift + 点击选中锚点到该卡的可见区间。
  void _toggleSelection(String bookUid) {
    setState(() => _selection.applyTap(
          SelectionSlot.loose(bookUid),
          selectionTapKind(),
        ));
  }

  /// 块2：切换整合集选中（合集行头勾选框）。Shift 同样在合集区内成段。
  void _toggleCollectionSelection(int collectionId) {
    setState(() => _selection.applyTap(
          SelectionSlot.collection(collectionId),
          selectionTapKind(),
        ));
  }

  /// 桌面 Ctrl/⌘/Shift + 点击：直接进入多选并选中该项。
  /// 触屏（含外接键盘）只允许从明确的「选择」入口进入。
  void _enterSelectionWith(SelectionSlot slot) {
    setState(() => _selection.enterWith(slot));
  }

  /// 一个可见视频是否已折进某合集（= 合集成员，不作散卡单选/全选）。
  bool _isCollectionMember(String bookUid) => _primaryCollectionByEntry
      .containsKey(MediaKind.video.compositeKey(bookUid));

  /// 全选 / 反选的候选散卡键：只含未折进合集的可见视频（折进的成员由整合集选中，
  /// 不单独勾）。两处共用同一份资格判据，避免全选与反选口径漂开。
  Set<String> _selectableLooseUids() => <String>{
        for (final VideoBookRow book in _visibleVideos)
          if (!_isCollectionMember(book.bookUid)) book.bookUid,
      };

  void _selectAllVisible() {
    setState(() => _selection.selectAll(
          loose: _selectableLooseUids(),
          collections: _visibleCollectionIds,
        ));
  }

  void _invertSelection() {
    setState(() => _selection.invert(
          loose: _selectableLooseUids(),
          collections: _visibleCollectionIds,
        ));
  }

  /// 批量操作前把选中集收敛到真实存在的条目上，真剔掉了就明说。
  ///
  /// 选中集不随库变化剪枝（见 [MediaSelectionController.retainExisting]），多选态
  /// 期间同步下架 / 别处删除都会留下幽灵键。必须在**任何**批量操作落库前剔干净：
  /// 否则打标签撞外键会把弹窗卡死、组合撞外键会静默失败、确认框里的数字是虚数。
  ///
  /// 返回剔完后是否还有东西可做（全空则调用方直接返回）。
  Future<bool> _pruneStaleSelection() async {
    if (_selection.isEmpty) return false;
    final List<VideoBookRow> books = await widget.repo.listAll();
    final List<MediaCollectionRow> collections =
        await ref.read(appProvider).database.getAllMediaCollections();
    if (!mounted) return false;
    final int dropped = _selection.retainExisting(
      loose: <String>{for (final VideoBookRow b in books) b.bookUid},
      collections: <int>{for (final MediaCollectionRow c in collections) c.id},
    );
    if (dropped == 0) return _selection.isNotEmpty;
    setState(() {});
    FushiToast.show(
      msg: t.batch_selection_stale_skipped(
        n: dropped + _selection.length,
        m: dropped,
      ),
      severity: ToastSeverity.warning,
    );
    return _selection.isNotEmpty;
  }

  /// 块4：批量删除区分解散/删媒体。
  /// - 选中合集 → 解散（[FushiDatabase.deleteMediaCollection]：只解除分组，不删媒体本体）；
  /// - 选中散卡 → 删媒体本体（[VideoBookRepository.deleteVideoBook]，现状语义）；
  /// - 混选 → 确认框文案写明「删 N 个媒体、解散 M 个合集」。
  Future<void> _batchDeleteConfirm() async {
    // 先剔幽灵键再取数：确认框里的 N / M 必须是真会被删的条数。
    if (!await _pruneStaleSelection() || !mounted) return;
    final int mediaCount = _selectedUids.length;
    final int collectionCount = _selectedCollectionIds.length;
    if (mediaCount == 0 && collectionCount == 0) return;
    // 纯删媒体分支用视频专用文案（batch_delete_confirm_video，develop 新增 key）；
    // 混选/纯解散仍走合集区分文案（本分支批量删除语义超集）。
    final String message = collectionCount == 0
        ? t.batch_delete_confirm_video(n: mediaCount)
        : mediaCount == 0
            ? t.batch_dissolve_confirm(m: collectionCount)
            : t.batch_delete_mixed_confirm(n: mediaCount, m: collectionCount);
    // 混选/纯解散不删媒体本体 → 不展示同步删除选项（合集解散走合集传播机制）；
    // 纯删媒体才有意义提供「从所有设备删除」。
    // 不能写成三元表达式：两分支各含 await 时 analyzer 视互为 async gap，
    // 两处 context 都报 use_build_context_synchronously（CI warning 致命）。
    final DeleteScope? scope;
    if (collectionCount == 0) {
      scope = await showDeleteScopeConfirm(context,
          title: t.dialog_delete,
          message: message,
          db: ref.read(appProvider).database);
    } else {
      scope = await showAppDialog<DeleteScope>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: Text(t.dialog_delete),
          content: Text(message),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: Text(t.dialog_cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, DeleteScope.keepLocalOnly),
              child: Text(
                t.dialog_delete,
                style: TextStyle(color: Theme.of(ctx).colorScheme.error),
              ),
            ),
          ],
        ),
      );
    }
    if (scope == null || !mounted) return;

    final FushiDatabase db = ref.read(appProvider).database;
    // 先解散选中合集（只删合集容器 + 成员引用行，绝不删媒体本体）。
    final Set<int> toDissolve = Set<int>.of(_selectedCollectionIds);
    int dissolved = 0;
    for (final int id in toDissolve) {
      final int removed = await deleteMediaCollectionWithAssets(db, id);
      if (removed > 0) dissolved++;
    }
    // 再删选中散卡的媒体本体（现状语义）。
    final Set<String> toDelete = Set<String>.of(_selectedUids);
    final List<VideoBookRow> deletedBooks = <VideoBookRow>[];
    for (final String bookUid in toDelete) {
      final VideoBookRow? book = await widget.repo.getByBookUid(bookUid);
      if (book == null) continue;
      await widget.repo.deleteVideoBook(bookUid, scope: scope);
      deletedBooks.add(book);
    }
    final int deleted = deletedBooks.length;
    if (mounted) {
      _exitSelectionMode();
      _refreshAfterTagChange();
      await _waitForVideoCardsToUnmount();
    }
    for (final VideoBookRow book in deletedBooks) {
      await widget.repo.reclaimDeletedVideoBookAssets(
        deletedBookUid: book.bookUid,
        deletedCoverPath: book.coverPath,
        deletedSubtitlePath: book.subtitleSource,
        deletedVideoPath: book.videoPath,
      );
    }
    if (deleted > 0) {
      await widget.repo.compactAfterVideoDeleteBestEffort();
    }
    if (!mounted) return;
    // 复查 #7：零成功（deleted==0 且 dissolved==0）时兜底文案按「选择构成」诚实分派——
    // 只选散卡（collectionCount==0）说「已删除 0 个」，否则说「已解散 0 个合集」；不再
    // 无条件谎报解散类别（对齐 BUG-439 诚实计数精神）。纯删媒体分支用视频专用文案
    // （batch_delete_success_video，develop 新增 key）。
    final String successMsg = deleted > 0 && dissolved > 0
        ? t.batch_delete_mixed_success(n: deleted, m: dissolved)
        : deleted > 0
            ? t.batch_delete_success_video(n: deleted)
            : collectionCount == 0
                ? t.batch_delete_success_video(n: deleted)
                : t.batch_dissolve_success(m: dissolved);
    FushiToast.show(
      msg: successMsg,
      severity: deleted > 0 || dissolved > 0
          ? ToastSeverity.success
          : ToastSeverity.warning,
    );
  }

  Future<void> _waitForVideoCardsToUnmount() async {
    final Future<List<VideoBookRow>>? future = _future;
    if (future != null) {
      try {
        await future;
      } catch (_) {
        // Refresh failures are surfaced by the FutureBuilder; deletion cleanup
        // stays best-effort and should still run.
      }
    }
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
  }

  /// 批量打标签：弹 [_VideoBatchTagPickerDialog]（每个标签三态：保持/添加/移除），
  /// 应用到所有选中视频书（经 [FushiDatabase.addTagToVideoBook] /
  /// [FushiDatabase.removeTagFromVideoBook]），关闭后刷新映射。
  Future<void> _batchShowTagPicker() async {
    // 幽灵键会让 bookTags 的外键插入抛异常，而弹窗把落库 await 在 loading 态里，
    // 一抛就永远转圈（卡死）。必须在开弹窗前剔干净。
    if (!await _pruneStaleSelection() || !mounted) return;
    if (_selectedUids.isEmpty) return;
    final List<BookTagRow>? allTags = ref.read(allTagsProvider).valueOrNull;
    if (allTags == null || allTags.isEmpty) {
      FushiToast.show(msg: t.tag_no_tags_hint, severity: ToastSeverity.info);
      return;
    }
    await showAppDialog<void>(
      context: context,
      builder: (_) => _VideoBatchTagPickerDialog(
        allTags: allTags,
        selectedUids: Set<String>.of(_selectedUids),
        database: ref.read(appProvider).database,
      ),
    );
    if (!mounted) return;
    _refreshAfterTagChange();
  }

  Future<void> _openImport() async {
    final String? bookUid = await showAppDialog<String>(
      context: context,
      builder: (_) => VideoImportDialog(repo: widget.repo),
    );
    if (bookUid != null) _refresh();
  }

  /// 打开「管理来源」对话框（视频来源库）。关闭后刷新列表（扫描可能新增视频）。
  Future<void> _openManageSources() async {
    await showAppDialog<void>(
      context: context,
      builder: (_) => const MediaSourcesDialog(mediaKind: 'video'),
    );
    // 注意：本对话框管的是**扫描根**（本地目录 / SFTP / FTP 源库），改不了互联对端，
    // 所以这里不做远端缓存失效——换对端的失效由 [remoteLibraryCacheProvider] 订阅
    // `InterconnectSyncBackend.sessionIdentityRevision` 统一处理（BUG-1180）。
    // 这里仍传 remote: true，是因为扫描可能让本地与远端的去重结果变化。
    if (mounted) _refresh(remote: true);
  }

  /// 拖放到视频 tab 时的处理：分类文件 → 局部坐标转屏幕坐标命中卡片 → 决策意图。
  ///
  /// [globalPosition] 为 [FushiFileDropTarget] 透出的 Flutter global/view 坐标，
  /// 可直接交给卡片注册表命中（注册表存的是同一坐标系的屏幕矩形）。
  void _handleVideoDrop(List<String> paths, Offset globalPosition) {
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;

    final DroppedFiles files = classifyDroppedFiles(paths);
    debugPrint(
      '[fushi-drop] [home-video] classified '
      'videos=${files.videos.length} playlists=${files.playlists.length} '
      'subtitles=${files.subtitles.length} books=${files.books.length} '
      'dictionaries=${files.dictionaries.length} unknown=${files.unknown.length} '
      'global=$globalPosition',
    );
    final VideoBookRow? hit = _cardDropRegistry.hitTest(globalPosition);
    final DropIntent intent = decideDropIntent(
      surface: DropSurface.video,
      files: files,
      cardHit: hit != null,
    );
    switch (intent) {
      case DropIntent.importNewVideo:
        _openVideoImportPrefilled(
          videoPath: files.videos.first,
          subtitlePath:
              files.subtitles.isNotEmpty ? files.subtitles.first : null,
        );
      case DropIntent.importNewPlaylist:
        _openPlaylistImportPrefilled(playlistPath: files.playlists.first);
      case DropIntent.importVideoUrl:
        // 拖入网络流 URL → 打开视频导入对话框预填 URL 并自动导入（TODO-1306）。
        _openStreamImportPrefilled(streamUrl: files.urls.first);
      case DropIntent.attachToVideoCard:
        // 字幕拖到具体视频卡：直接挂到那张卡所代表的**现有**视频书（不重新导入）。
        // 旧实现走 _openVideoImportPrefilled→VideoImportDialog._doImport，对已存在
        // 视频重算 singleVideoBookUid 触发同名去重、建 `video/<name> (2)` 重复条目，
        // 字幕没挂到原视频（TODO-079 根因）。
        _attachSubtitleToVideoCard(hit!, files.subtitles.first);
      case DropIntent.needCardTarget:
        debugPrint('[fushi-drop] [home-video] intent=needCardTarget');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.drag_drop_need_card_target)),
        );
      case DropIntent.unsupportedSurface:
        debugPrint('[fushi-drop] [home-video] intent=unsupportedSurface');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.drag_drop_unsupported_on_video)),
        );
      case DropIntent.importNewBook:
      case DropIntent.attachToBookCard:
      // 漫画意图只由 books/manga 表面产出（video 表面不可能命中），列在此处
      // 仅为穷尽 switch。
      case DropIntent.importNewManga:
      case DropIntent.unsupportedMangaArchive:
      case DropIntent.ignore:
        break;
    }
  }

  /// 复用 [VideoImportDialog] 打开方式，预填视频/字幕路径（**新建导入**用）。对话框
  /// 按文件名派生 bookUid，用户确认后保存，关闭后刷新列表。「把字幕挂到已有视频卡」
  /// 不走这里——它会对已存在视频重算 bookUid 触发同名去重建重复条目（TODO-079），
  /// 改走 [_attachSubtitleToVideoCard] 直接对命中卡 bookUid 落库。
  Future<void> _openVideoImportPrefilled({
    required String videoPath,
    String? subtitlePath,
  }) async {
    final String? bookUid = await showAppDialog<String>(
      context: context,
      builder: (_) => VideoImportDialog(
        repo: widget.repo,
        initialVideoPath: videoPath,
        initialSubtitlePath: subtitlePath,
      ),
    );
    if (bookUid != null) _refresh();
  }

  /// 拖入 m3u8/m3u 播放列表：打开 [VideoImportDialog] 并预填 playlist 路径，对话框
  /// 自动解析多集落库（与手动点「播放列表」按钮同一路径），关闭后刷新列表。
  Future<void> _openPlaylistImportPrefilled({
    required String playlistPath,
  }) async {
    final String? bookUid = await showAppDialog<String>(
      context: context,
      builder: (_) => VideoImportDialog(
        repo: widget.repo,
        initialPlaylistPath: playlistPath,
      ),
    );
    if (bookUid != null) _refresh();
  }

  /// 拖入网络流 URL（浏览器地址栏/链接）→ 打开 [VideoImportDialog] 预填 URL，对话框
  /// 可播时自动走 [_importStreamUrl] 导入（进视频书架），关闭后刷新列表（TODO-1306）。
  Future<void> _openStreamImportPrefilled({
    required String streamUrl,
  }) async {
    final String? bookUid = await showAppDialog<String>(
      context: context,
      builder: (_) => VideoImportDialog(
        repo: widget.repo,
        initialStreamUrl: streamUrl,
      ),
    );
    if (bookUid != null) _refresh();
  }

  /// 把拖到某张视频卡上的外挂字幕挂到**那张卡代表的现有视频书**（TODO-079）。
  ///
  /// 经 [attachSubtitleToVideoBook]：拷盘到 `<appDocs>/video_subtitles/` → 解析 cue →
  /// 对命中卡 `book.bookUid` 原子 saveSubtitleSelection（源指针 + cue），下次进播放页
  /// 直接 `loadCues` 命中。不新建视频书、不去重加后缀（修掉旧重复导入路径的 bug）。
  /// 按结果给 SnackBar 反馈；播放列表卡无单一字幕语义，提示进播放页按集挂。
  Future<void> _attachSubtitleToVideoCard(
    VideoBookRow book,
    String subtitlePath,
  ) async {
    final SubtitleAttachResult result = await attachSubtitleToVideoBook(
      repo: widget.repo,
      book: book,
      subtitlePath: subtitlePath,
    );
    if (!mounted) return;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String message;
    switch (result.outcome) {
      case SubtitleAttachOutcome.attached:
        message = t.video_subtitle_attached_to_video(
          title: book.title,
          count: result.cueCount,
        );
        debugPrint(
          '[fushi-drop] [home-video] attachSubtitle outcome=attached '
          'bookUid=${book.bookUid} cues=${result.cueCount}',
        );
        _refresh();
      case SubtitleAttachOutcome.playlistNeedsPlayer:
        message = t.video_subtitle_attach_playlist_hint;
        debugPrint(
          '[fushi-drop] [home-video] attachSubtitle outcome=playlistNeedsPlayer '
          'bookUid=${book.bookUid}',
        );
      case SubtitleAttachOutcome.unsupported:
        message = t.video_subtitle_import_unsupported;
        debugPrint(
          '[fushi-drop] [home-video] attachSubtitle outcome=unsupported '
          'bookUid=${book.bookUid}',
        );
      case SubtitleAttachOutcome.copyFailed:
        message = t.video_subtitle_import_failed;
        debugPrint(
          '[fushi-drop] [home-video] attachSubtitle outcome=copyFailed '
          'bookUid=${book.bookUid}',
        );
      case SubtitleAttachOutcome.emptyCues:
        message = t.video_subtitle_load_failed(label: result.label);
        debugPrint(
          '[fushi-drop] [home-video] attachSubtitle outcome=emptyCues '
          'bookUid=${book.bookUid} label=${result.label}',
        );
    }
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  void _openStatistics() {
    Navigator.push(
      context,
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => const VideoStatisticsPage(),
      ),
    );
  }

  /// 块3：批量「组合」按钮三档自适应（[classifyCombine]）。视频选择键是裸 bookUid，
  /// 经 shelfSelectionToEntry 编成 ('video', uid)：
  /// - 仅散卡 → 命名弹窗新建合集（[_combineCreateNew]）；
  /// - 恰 1 合集 + 若干散卡 → 散卡并入该合集（[_combineAddToExisting]，不弹命名）；
  /// - ≥2 合集（可带散卡）→ 合并成一个（[_combineMergeCollections]，默认名=成员最多合集名）。
  /// 全部走既有 DAO（createMediaCollection / addToCollection / deleteMediaCollection）。
  Future<void> _batchCombineIntoSeries() async {
    // 幽灵键会让 addToCollection 撞外键，且它挂在无人 catch 的路径上——用户只会
    // 看到「点了没反应」，以为合集建好了。先剔干净再分档。
    if (!await _pruneStaleSelection() || !mounted) return;
    final FushiDatabase db = ref.read(appProvider).database;
    final List<int> collectionIds = _selectedCollectionIds.toList()..sort();
    // 成员序按标题自然序落盘，不用 `_selectedUids`（LinkedHashSet）的点选顺序：
    // 框选一整季建出来的合集此前「选集」列表是乱的（BUG-1436）。三档共用同一份
    // 已排好的 refs。
    final Map<String, String> titleByUid = <String, String>{
      for (final VideoBookRow b in _visibleVideos) b.bookUid: b.title,
    };
    final List<ShelfEntryRef> looseRefs = sortNewCollectionMembersNaturally(
      <ShelfEntryRef>[
        for (final String uid in _selectedUids)
          if (shelfSelectionToEntry(uid, ShelfSelectionSurface.video)
              case final ShelfEntryRef ref)
            ref,
      ],
      titleOf: (ShelfEntryRef r) => titleByUid[r.entryKey] ?? r.entryKey,
    );
    final CombineTier tier = classifyCombine(
      collectionCount: collectionIds.length,
      looseCount: looseRefs.length,
    );
    switch (tier) {
      case CombineTier.noop:
        return;
      case CombineTier.createNew:
        await _combineCreateNew(db, looseRefs);
      case CombineTier.addToExisting:
        await _combineAddToExisting(db, collectionIds.single, looseRefs);
      case CombineTier.mergeCollections:
        await _combineMergeCollections(db, collectionIds, looseRefs);
    }
  }

  /// 档1：仅散卡 → 命名弹窗新建合集，逐条 addToCollection。
  Future<void> _combineCreateNew(
    FushiDatabase db,
    List<ShelfEntryRef> refs,
  ) async {
    // TODO-1125 B：预填合集默认名——把选中视频标题经 parseVideoFilename 去集号得系列名，
    // 再取最长公共前缀；推导为空则兜底 t.series_default_name（「新系列」）。
    final Set<String> selectedUids = Set<String>.of(_selectedUids);
    final List<String> memberSeries = <String>[
      for (final VideoBookRow book in _visibleVideos)
        if (selectedUids.contains(book.bookUid))
          parseVideoFilename(book.title).series,
    ];
    final String defaultName = deriveSeriesDefaultName(
      memberSeries,
      fallback: t.series_default_name,
    );
    // TODO-947：把选中的前 4 个视频封面传进命名弹窗，铺成手机文件夹式网格缩略预览。
    final List<Widget> previewCovers = <Widget>[
      for (final VideoBookRow book in _visibleVideos)
        if (selectedUids.contains(book.bookUid)) _buildCover(book),
    ].take(4).toList();
    final String? name = await showCollectionNameDialog(
      context: context,
      title: t.create_series,
      initialName: defaultName,
      previewCovers: previewCovers,
    );
    if (name == null || !mounted) return;
    final int collectionId = await db.createMediaCollection(name);
    for (final ShelfEntryRef ref in refs) {
      await db.addToCollection(collectionId, ref.mediaType, ref.entryKey);
    }
    if (!mounted) return;
    _exitSelectionMode();
    await _loadLibraryMaps();
    FushiToast.show(msg: t.series_created, severity: ToastSeverity.success);
  }

  /// 档2：恰 1 合集 + 若干散卡 → 散卡并入该合集（不弹命名）。
  Future<void> _combineAddToExisting(
    FushiDatabase db,
    int collectionId,
    List<ShelfEntryRef> refs,
  ) async {
    for (final ShelfEntryRef ref in refs) {
      await db.addToCollection(collectionId, ref.mediaType, ref.entryKey);
    }
    if (!mounted) return;
    _exitSelectionMode();
    await _loadLibraryMaps();
    FushiToast.show(
      msg: t.batch_add_to_collection_success(n: refs.length),
      severity: ToastSeverity.success,
    );
  }

  /// 档3：≥2 合集（可带散卡）→ 合并成一个。目标 = 成员最多合集（其名作默认名，
  /// 确认框可改名）；目标吸收其余合集成员（addToCollection）+ 散卡加入，其余合集
  /// deleteMediaCollection 解散（只解除分组，不删媒体本体）。
  Future<void> _combineMergeCollections(
    FushiDatabase db,
    List<int> collectionIds,
    List<ShelfEntryRef> refs,
  ) async {
    final Map<int, List<MediaCollectionItemRow>> itemsById =
        <int, List<MediaCollectionItemRow>>{};
    for (final int id in collectionIds) {
      itemsById[id] = await db.getCollectionItems(id);
    }
    final MergeTargetChoice choice = chooseMergeTarget(
      <({int id, String name, int memberCount})>[
        for (final int id in collectionIds)
          (
            id: id,
            name: _collectionsById[id]?.name ?? '',
            memberCount: itemsById[id]!.length,
          ),
      ],
    );
    if (!mounted) return;
    final String? name = await showCollectionNameDialog(
      context: context,
      title: t.collection_merge_title,
      initialName: choice.defaultName,
    );
    if (name == null || !mounted) return;
    final int targetId = choice.targetId;
    // 复查 #6（TOCTOU）：成员快照上面是在命名确认框「之前」取的，框开着期间若有新成员
    // 同步进源合集，用旧快照迁移会漏掉这些新成员，随后 deleteMediaCollection 把它们连
    // 同源合集一起删掉 → 分组丢失。确认后、迁移前对每个源合集「重取」最新成员再迁移，
    // addToCollection 幂等去重，重复成员无副作用。
    for (final int id in collectionIds) {
      if (id == targetId) continue;
      final List<MediaCollectionItemRow> members =
          await db.getCollectionItems(id);
      for (final MediaCollectionItemRow m in members) {
        // 原样搬家现有成员行：行值可能是对端未知种类，走 raw 版防静默丢成员。
        await db.addToCollectionRaw(targetId, m.mediaType, m.entryKey);
      }
      await deleteMediaCollectionWithAssets(db, id);
    }
    for (final ShelfEntryRef ref in refs) {
      await db.addToCollection(targetId, ref.mediaType, ref.entryKey);
    }
    await db.renameMediaCollection(targetId, name);
    if (!mounted) return;
    _exitSelectionMode();
    await _loadLibraryMaps();
    FushiToast.show(msg: t.collection_merged, severity: ToastSeverity.success);
  }

  /// 打开收藏夹页（书签 + 收藏句子，含视频来源的收藏句子，TODO-047 ③a）。与书架页头
  /// 的收藏夹入口同一 [CollectionsPage]——视频与书架共用一个收藏夹，按来源区分展示。
  void _openCollections() {
    Navigator.push(
      context,
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => const CollectionsPage(),
      ),
    );
  }

  /// [playlistCollectionId] 非空 = 作为某 playlist 合集的一集打开（播放器据此建剧集面板/
  /// 上下集/连播）；null = 独立单视频打开（散视频卡）。
  Future<void> _open(VideoBookRow book, {int? playlistCollectionId}) async {
    await _showAnime4kFirstUsePromptIfNeeded();
    if (!mounted) return;
    // 路由构造走共享顶层入口 [openLocalVideoBook]（dashboard 续播同一条路径）。
    await openLocalVideoBook(
      context: context,
      repo: widget.repo,
      bookUid: book.bookUid,
      playlistCollectionId: playlistCollectionId,
    );
    // 从播放器返回后刷新：继续观看 hero / 概览统计 / 卡片观看进度行都依赖
    // lastPositionMs 与 watch-stats，播完不刷会展示陈旧数据（对抗审查确认）。
    if (mounted) _refresh();
  }

  Future<void> _openRemote(
    RemoteVideoInfo video, {
    List<RemoteVideoInfo>? collectionMembers,
    int startIndex = 0,
  }) async {
    final RemoteVideoClient? client = _remoteVideoClient;
    if (client == null) {
      // #4：云后端视频无 live host、不能流播；短按 = 下载入库（对齐书侧短按=下载语义），
      // 而不是静默 return（占位卡点了像没反应）。仅当存在云 client 时分派；两者都无时
      // _downloadRemote 自身会给「不可达」提示。
      if (_cloudRemoteVideoClient != null) {
        await _downloadRemote(video);
      }
      return;
    }
    // 打开远端播放页后再弹首次着色器提示（而非提示阻塞导航）：远端入口的契约是
    // 「点击立即建立远端流」（home_video_remote_interconnect_test），把一次性的着色器
    // 提示放到 await 导航前会让远端串流请求永远不发出（TODO-026 回归）。提示是纯信息
    // 性的（只置 videoAnime4kPromptShown），叠加在已打开的播放页之上即可，不必先于导航。
    Navigator.push(
      context,
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => VideoHibikiPage.neutralizedRemote(
          info: video,
          repo: widget.repo,
          client: client,
          // 客户端合集播放：合集里点某成员时带上有序远端成员列表 + 起播下标，播放器据此
          // 建剧集列表 + 跨成员自动连播（成员是各自独立 video id，非同 id 换 episodeIndex）。
          remoteCollectionMembers:
              (collectionMembers != null && collectionMembers.length > 1)
                  ? collectionMembers
                  : null,
          initialEpisodeIndex:
              (collectionMembers != null && collectionMembers.length > 1)
                  ? startIndex
                  : null,
        ),
      ),
    );
    await _showAnime4kFirstUsePromptIfNeeded();
  }

  Future<void> _showAnime4kFirstUsePromptIfNeeded() async {
    // 移动端不弹「开启超分(Anime4K)」首次提示（TODO-874）：着色器超分在手机上掉帧、
    // 发热（参见 video_shader_mobile_perf_hint 文案），不该主动劝用户开启；仅桌面端
    // 保留此一次性提示。纯抑制——不置 videoAnime4kPromptShown 标记（零副作用，桌面端
    // 跨平台同步时仍能在桌面首次弹出）。单点拦截即覆盖 _open / _openRemote 两调用点。
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      return;
    }
    final AppModel appModel = ref.read(appProvider);
    if (appModel.prefsRepo.videoAnime4kPromptShown) return;
    await appModel.prefsRepo.setVideoAnime4kPromptShown();
    if (!mounted) return;
    // 首次打开视频的提示：除「知道了」外给一个「一键下载并启用」按钮（用户诉求 4），
    // 点它即下载推荐画质着色器（「中」档 = Anime4K Fast）并启用，不必自己摸进设置。
    final bool? download = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(t.video_shader_first_use_title),
        content: Text(t.video_shader_first_use_body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.dialog_close),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.video_shader_first_use_download),
          ),
        ],
      ),
    );
    if (download == true && mounted) {
      await _downloadAndEnableDefaultShaderTier();
    }
  }

  /// 一键下载并启用「中」档（Anime4K Fast）：下载预设文件到着色器目录，再原子写
  /// mpv 内置缩放开关（开）+ 启用集（中档着色器），即下次打开视频生效。带 SnackBar 反馈。
  ///
  /// 不弹复杂进度对话框（首次提示场景从简）：下载用阻塞 await，开始/结束各一条提示。
  Future<void> _downloadAndEnableDefaultShaderTier() async {
    final AppModel appModel = ref.read(appProvider);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(content: Text(t.video_shader_downloading)));
    const VideoShaderTier tier = VideoShaderTier.medium;
    final Anime4kPreset? preset = shaderTierSpec(tier).preset;
    if (preset == null) return;
    Anime4kDownloadResult? result;
    try {
      result = await downloadAnime4kFiles(preset);
    } catch (_) {
      result = null;
    }
    if (!mounted) return;
    if (result == null || result.downloaded.isEmpty) {
      messenger.showSnackBar(
          SnackBar(content: Text(t.video_shader_download_failed)));
      return;
    }
    // 从目录现有文件按该档叠加顺序过滤出有序启用集。
    final List<String> present = await listShaderFiles();
    final List<String> enabled = orderedEnabledForTier(tier, present.toSet());
    final VideoMpvConfig cfg =
        VideoMpvConfig.decode(appModel.videoMpvConfig).copyWith(
      highQuality: true,
    );
    await appModel.setVideoMpvConfig(VideoMpvConfig.encode(cfg));
    await appModel.setVideoShadersEnabled(encodeEnabledShaders(enabled));
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(
      content: Text(result.allOk
          ? t.video_shader_download_done(count: result.downloaded.length)
          : t.video_shader_download_partial(
              ok: result.downloaded.length, failed: result.failed.length)),
    ));
  }

  Future<void> _downloadRemote(RemoteVideoInfo video) async {
    final RemoteVideoSource? source = _remoteVideoSource;
    // #3: 服务不可达 / 未鉴权时给明确提示，不再静默 return（用户点了像没反应）。
    if (source == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.remote_video_unavailable)),
      );
      return;
    }
    // 根因修复（TODO-819）：下载任务委托给 app 级 InterconnectDownloadManager 而非
    // 本页 State —— 故切 tab / 退页 / 本页 dispose 时下载仍在管理器里推进到底，重进
    // 页面只 ref.watch 订阅渲染进度。manager 自身去重（同 id 在跑则忽略）。
    // #6 续传口径按分支写实：互联走 host live 下载引擎（Range + `.part`，中断留 part
    // 下次可续）；云后端分支（CloudRemoteVideoClient.getRemoteVideo）是整文件重下，失败
    // 清残片、无断点续传。
    final InterconnectDownloadManager manager =
        ref.read(interconnectDownloadManagerProvider);
    if (manager.isRunning(video.id)) return;

    final File dest = await _remoteDownloadDestination(video);
    // TODO-2119：下载本身是所有源的共同能力，不再分派——[RemoteVideoSource] 各自
    // 实现续传口径（互联 host live 引擎 Range + `.part` 可续；云盘整文件重下）。
    // bookUid 用稳定的远端 video.id（与 dedupeRemoteVideos 去重键一致：upsert 同行不
    // 撞键），故下载好的视频立即出现在列表、并从混排占位区去重隐藏。
    Future<void> run(
      File target, {
      void Function(double progress)? onProgress,
    }) =>
        source.downloadRemoteVideo(video.id, target, onProgress: onProgress);
    // 收尾登记仍按源分流：互联要回填外挂字幕 + host 断点，云盘要按资产名取封面、
    // 且没有字幕/进度可回填。这是两种源**真实**的能力差异，不是样板分支。
    final CloudRemoteVideoClient? cloud = _cloudRemoteVideoClient;
    final RemoteVideoClient? client = _remoteVideoClient;
    final InterconnectDownloadComplete onComplete = client != null
        ? (File downloaded) =>
            _registerDownloadedVideo(client, video, downloaded)
        : (File downloaded) =>
            _registerDownloadedCloudVideo(cloud!, video, downloaded);
    try {
      await manager.startVideoDownload(
        id: video.id,
        title: video.title,
        dest: dest,
        run: run,
        onComplete: onComplete,
      );
    } catch (e) {
      debugPrint('[home-video] remote video download failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.remote_video_download_failed)),
      );
      return;
    }
    if (!mounted) return;
    // 刷新列表让新建的 VideoBooks 行立即出现（并把已下载视频从「配对设备」区去重隐藏）。
    _refresh();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(t.remote_video_downloaded)),
    );
  }

  /// 把刚下载到本机的对端视频 [dest] 登记成本地 [VideoBooksCompanion] 行，使其出现在
  /// 视频列表（TODO-820）。bookUid 直接取远端稳定 [RemoteVideoInfo.id]——与
  /// [dedupeRemoteVideos] 的去重键一致，故 upsert 语义下重复下载同一视频只覆盖同一行、
  /// 不产生重复条目，且下载后该视频从「配对设备」区消失、进入本地列表。
  ///
  /// 字幕：host 字幕原语 [RemoteVideoClient.getRemoteVideoSubtitle] 就绪，[video]
  /// 标记 [RemoteVideoInfo.hasSubtitle] 时下载外挂字幕落地、解析成 cue 一并写入，使
  /// 下载来的视频可查词/句导航。封面：host 无封面文件下载原语（仅 coverUrl/coverPath
  /// 元数据），故退回本地抽帧 [extractVideoCover]（桌面 ffmpeg；移动端无则留空占位），
  /// 与本地导入一致。
  Future<void> _registerDownloadedVideo(
    RemoteVideoClient client,
    RemoteVideoInfo video,
    File dest,
  ) async {
    final String bookUid = video.id;
    final ({String? source, String? format, List<AudioCue> cues}) subtitle =
        await _downloadRemoteSubtitleForBook(client, video, bookUid);
    await widget.repo.saveVideoBook(VideoBooksCompanion(
      bookUid: Value(bookUid),
      title: Value(video.title),
      videoPath: Value(dest.path),
      subtitleSource: Value<String?>(subtitle.source),
      subtitleFormat: Value<String?>(subtitle.format),
      embeddedSubtitleTrack: subtitle.source == null
          ? const Value<int?>(0)
          : const Value<int?>(null),
      importedAt: Value(DateTime.now().millisecondsSinceEpoch),
    ));
    if (subtitle.cues.isNotEmpty) {
      await widget.repo.saveCues(bookUid: bookUid, cues: subtitle.cues);
    }
    // tags 稳健档：LWW 合并 host 传来的标签时钟 + 移除墓碑（删除/改名传播、防复活）。
    // host 带 tagsAddedAt/tagTombstones（v2）→ mergeRemoteVideoTags；旧 host 只有 tags
    // 名单 → 合成 addedAt=1 退化为「只增 + 尊重本地移除墓碑」（向后兼容）。
    if (video.tagsAddedAt.isNotEmpty ||
        video.tagTombstones.isNotEmpty ||
        video.tags.isNotEmpty) {
      final Map<String, int> remoteAddedAt = video.tagsAddedAt.isNotEmpty
          ? video.tagsAddedAt
          : <String, int>{
              for (final String name in video.tags)
                if (name.isNotEmpty) name: 1,
            };
      await widget.repo.mergeRemoteVideoTags(
        bookUid,
        remoteAddedAt: remoteAddedAt,
        remoteTombstones: video.tagTombstones,
      );
    }
    // 封面抽帧（extractVideoCover 走 ffmpeg 子进程，最长 30s）是慢的可选增强，绝不能
    // 挡在建行前——否则用户「下载完」要等到抽帧结束才看到视频。这里建行已落库，封面
    // 单独抽好后再 updateCover 回写并刷新一次（extractVideoCover 内部已吞失败返 null，
    // 移动端无 ffmpeg 时留空占位，与本地导入一致）。
    final String? coverPath =
        await extractVideoCover(videoPath: dest.path, bookUid: bookUid);
    if (coverPath != null) {
      await widget.repo.updateCover(bookUid, coverPath);
      if (mounted) _refresh();
    }
  }

  /// 把刚下载到本机的**云后端**视频 [dest] 登记成本地 [VideoBooksCompanion] 行
  /// （多端库联合视图 §2.2/§2.6）。与 [_registerDownloadedVideo] 同一「勿双重导入」语义
  /// （bookUid = 稳定的远端 [RemoteVideoInfo.id]，saveVideoBook 是 upsert），但云清单
  /// 无外挂字幕/标签，故：无字幕（回退内嵌轨 0）、无标签重建；封面先试云端封面资产
  /// （[CloudRemoteVideoClient.getRemoteVideoCover]，可选），无则本地抽帧兜底。
  Future<void> _registerDownloadedCloudVideo(
    CloudRemoteVideoClient cloud,
    RemoteVideoInfo video,
    File dest,
  ) async {
    final String bookUid = video.id;
    await widget.repo.saveVideoBook(VideoBooksCompanion(
      bookUid: Value(bookUid),
      title: Value(video.title),
      videoPath: Value(dest.path),
      // 云视频无外挂字幕：回退内嵌默认轨（与 _registerDownloadedVideo 无字幕分支一致）。
      embeddedSubtitleTrack: const Value<int?>(0),
      importedAt: Value(DateTime.now().millisecondsSinceEpoch),
    ));
    // tags 稳健档：合并云清单携带的标签 LWW 时钟（删除/改名传播、防复活）。空则 no-op。
    if (video.tagsAddedAt.isNotEmpty || video.tagTombstones.isNotEmpty) {
      await widget.repo.mergeRemoteVideoTags(
        bookUid,
        remoteAddedAt: video.tagsAddedAt,
        remoteTombstones: video.tagTombstones,
      );
    }
    // 封面：先试云端封面资产（可选，无封面记录返回 false 不抛）；失败/无则本地抽帧兜底。
    // 与建行解耦（抽帧走 ffmpeg 慢，绝不挡建行落库），抽好后 updateCover 回写并刷新一次。
    bool gotCover = false;
    try {
      final File coverDest = await _cloudCoverDestination(bookUid);
      gotCover = await cloud.getRemoteVideoCover(bookUid, coverDest);
      if (gotCover) {
        await widget.repo.updateCover(bookUid, coverDest.path);
        if (mounted) _refresh();
      }
    } catch (e) {
      debugPrint('[home-video] cloud video cover download failed: $e');
      gotCover = false;
    }
    if (!gotCover) {
      final String? coverPath =
          await extractVideoCover(videoPath: dest.path, bookUid: bookUid);
      if (coverPath != null) {
        await widget.repo.updateCover(bookUid, coverPath);
        if (mounted) _refresh();
      }
    }
  }

  /// 云视频封面下载落点：`<documents>/remote_videos/<safeUid>.cover.jpg`（与视频落点
  /// 同目录，重复下载覆盖同一副本）。
  Future<File> _cloudCoverDestination(String bookUid) async {
    final Directory dir = await AppPaths.remoteVideosDirectory();
    await dir.create(recursive: true);
    final String safeUid = safeWindowsFileName(bookUid);
    return File(p.join(dir.path, '$safeUid.cover.jpg'));
  }

  /// 下载并解析对端外挂字幕（TODO-820）：返回外挂字幕落地路径 / 格式 / 解析出的 cue。
  /// [video] 无可下载文本字幕（[RemoteVideoInfo.hasSubtitle]==false）时返回三者皆空，
  /// 由调用方退回内嵌默认轨。字幕落 `<appDocs>/video_subtitles/`（与本地导入同目录），
  /// 文件名据稳定 bookUid 派生（重复下载覆盖同一副本，不堆垃圾）。
  Future<({String? source, String? format, List<AudioCue> cues})>
      _downloadRemoteSubtitleForBook(
    RemoteVideoClient client,
    RemoteVideoInfo video,
    String bookUid,
  ) async {
    if (!video.hasSubtitle) {
      return (source: null, format: null, cues: const <AudioCue>[]);
    }
    final String ext = _remoteSubtitleExtension(video.subtitleFileName);
    // TODO-935 E0：经唯一入口 [AppPaths] 派生 `<documents>/video_subtitles`。
    final Directory dir = await AppPaths.videoSubtitlesDirectory();
    await dir.create(recursive: true);
    // BUG-1125：旧手写字符集漏了反斜杠（`[\/:*?"<>|]` 只转义了 `/`），id 含 `\`
    // 时字幕会落到与封面（[_cloudCoverDestination] 走全集）不同的目录。统一走
    // 共享 helper 根修。
    final String safeUid = safeWindowsFileName(video.id);
    final File subDest = File(p.join(dir.path, '$safeUid.$ext'));
    await client.getRemoteVideoSubtitle(video.id, subDest);
    final String content = await readTextWithEncoding(subDest);
    final List<AudioCue> cues = parseSubtitleCues(
      content: content,
      format: ext,
      bookUid: bookUid,
    );
    return (source: subDest.path, format: ext, cues: cues);
  }

  /// 从 host 提供的字幕文件名取真实扩展名（保留 `.ass/.ssa/.vtt/.srt` 解析语义）；
  /// 缺失/无扩展名时回退 `srt`（host 文本字幕最常见格式）。纯函数。
  String _remoteSubtitleExtension(String? subtitleFileName) {
    if (subtitleFileName == null || subtitleFileName.isEmpty) return 'srt';
    final String ext =
        p.extension(subtitleFileName).replaceFirst('.', '').toLowerCase();
    return ext.isEmpty ? 'srt' : ext;
  }

  Future<File> _remoteDownloadDestination(RemoteVideoInfo video) async {
    final Future<File> Function(RemoteVideoInfo video)? injected =
        widget.remoteVideoDownloadDestination;
    if (injected != null) return injected(video);
    // TODO-935 E0：经唯一入口 [AppPaths] 派生 `<documents>/remote_videos`。
    final Directory dir = await AppPaths.remoteVideosDirectory();
    await dir.create(recursive: true);
    final String safeTitle = safeWindowsFileName(video.title);
    final String fileName =
        safeTitle.toLowerCase().endsWith('.mp4') ? safeTitle : '$safeTitle.mp4';
    return File(p.join(dir.path, fileName));
  }

  // ── 长按菜单 ──────────────────────────────────────────────────────

  /// 长按视频卡：打开与书架书籍一致的封面背景动作面板。播放仍由卡片点击负责。
  void _showVideoMenu(VideoBookRow book) {
    showAppDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => MediaItemDialogFrame(
        cover: _buildCover(book),
        title: book.title,
        showLaunchAction: false,
        // 统一三库页卡菜单次序：重命名 → 封面/刮削 → 媒体特有 → 加入合集 →
        // 标签 → 删除（与书卡/游戏卡同一约定；「标签」原在首位，移到合集后）。
        quickActions: <DialogQuickAction>[
          DialogQuickAction(
            label: t.video_rename,
            icon: Icons.drive_file_rename_outline,
            onPressed: () {
              Navigator.pop(dialogContext);
              _renameVideo(book);
            },
          ),
          DialogQuickAction(
            label: t.srt_import_pick_cover,
            icon: Icons.image_outlined,
            onPressed: () {
              Navigator.pop(dialogContext);
              _pickCover(book);
            },
          ),
          DialogQuickAction(
            label: t.video_scrape_online_match,
            icon: Icons.image_search,
            onPressed: () {
              Navigator.pop(dialogContext);
              _openCoverMatch(book);
            },
          ),
          DialogQuickAction(
            label: t.video_scrape_info,
            icon: Icons.info_outline,
            onPressed: () {
              Navigator.pop(dialogContext);
              _openScrapeInfo(book);
            },
          ),
          DialogQuickAction(
            label: t.video_import_pick_subtitle,
            icon: Icons.subtitles_outlined,
            onPressed: () {
              Navigator.pop(dialogContext);
              _pickSubtitle(book);
            },
          ),
          DialogQuickAction(
            label: t.add_to_collection,
            icon: Icons.collections_bookmark_outlined,
            onPressed: () {
              Navigator.pop(dialogContext);
              _addToCollection(book);
            },
          ),
          DialogQuickAction(
            label: t.tag_label,
            icon: Icons.sell_outlined,
            onPressed: () {
              Navigator.pop(dialogContext);
              _editTags(book);
            },
          ),
        ],
        dangerActions: <DialogDangerAction>[
          DialogDangerAction(
            label: t.dialog_delete,
            onPressed: () {
              Navigator.pop(dialogContext);
              _confirmDelete(book);
            },
          ),
        ],
      ),
    );
  }

  Future<void> _pickSubtitle(VideoBookRow book) async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['srt', 'vtt', 'ass', 'ssa'],
      allowMultiple: false,
    );
    final String? subtitlePath = result?.files.single.path;
    if (subtitlePath == null || !mounted) return;
    await _attachSubtitleToVideoCard(book, subtitlePath);
  }

  /// 单卡「加入合集」：entryKey 与批量组合三档同一编码——视频选择键就是裸
  /// bookUid（见 [shelfSelectionToEntry] 的 video 分支），落库同走
  /// addToCollection DAO；成功后按 [_combineAddToExisting] 同款
  /// [_loadLibraryMaps] 刷新分组/网格。
  Future<void> _addToCollection(VideoBookRow book) async {
    final bool added = await showAddToCollectionDialog(
      context: context,
      database: ref.read(appProvider).database,
      mediaType: MediaKind.video,
      entryKey: book.bookUid,
    );
    if (!added || !mounted) return;
    await _loadLibraryMaps();
  }

  /// 把视频卡拖到合集封面卡上 = 把该视频加入本合集（`CollectionDropTarget`）。
  ///
  /// 「查成员 → 幂等提示 → 落库 → 失败提示」收口在 [addMediaRefToCollection]
  /// （书架 / 视频库 / 游戏库同一份，且永不抛出——它挂在 `void` 回调上）；
  /// 真写进去了才走 [_loadLibraryMaps] 同款刷新并报成功。
  Future<void> _addMediaToCollection(
      int collectionId, MediaRef mediaRef) async {
    final CollectionAddOutcome outcome = await addMediaRefToCollection(
      database: ref.read(appProvider).database,
      collectionId: collectionId,
      mediaRef: mediaRef,
    );
    if (outcome != CollectionAddOutcome.added || !mounted) return;
    await _loadLibraryMaps();
    FushiToast.show(
      msg: t.batch_add_to_collection_success(n: 1),
      severity: ToastSeverity.success,
    );
  }

  Future<void> _editTags(VideoBookRow book) async {
    await Navigator.push(
      context,
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => TagPickerPage(
          media: MediaRef(kind: MediaKind.video, entryKey: book.bookUid),
        ),
      ),
    );
    if (mounted) _refreshAfterTagChange();
  }

  Future<void> _addTagToVideoBook(String bookUid, BookTagRow tag) async {
    final Map<String, List<BookTagRow>>? existing =
        ref.read(videoBookTagMapProvider).valueOrNull;
    final bool alreadyHas =
        existing?[bookUid]?.any((BookTagRow t) => t.id == tag.id) ?? false;
    if (alreadyHas) {
      FushiToast.show(
        msg: t.tag_already_on_book(name: tag.name),
        severity: ToastSeverity.warning,
      );
      return;
    }

    await ref.read(appProvider).database.addTagToVideoBook(bookUid, tag.id);
    ref.invalidate(videoBookTagMapProvider);
    ref.invalidate(filteredVideoBookUidsProvider);
    if (mounted) {
      FushiToast.show(
        msg: t.tag_added_to_video(name: tag.name),
        severity: ToastSeverity.success,
      );
    }
  }

  /// 把标签拖到合集封面卡 = 给整个合集打标签（[_buildCollectionCoverCard] 外包的
  /// [BookDragTarget]）。
  /// `addTagToCollection` 本身幂等（INSERT OR IGNORE），这里先查现有标签给「已存在」
  /// 提示，避免静默无反馈；成功后失效 [filteredCollectionIdsProvider] 让标签过滤下
  /// 合集卡显隐立即刷新（详情页标签行走 FutureBuilder，重进即新）。
  Future<void> _addTagToVideoCollection(
      int collectionId, BookTagRow tag) async {
    final FushiDatabase db = ref.read(appProvider).database;
    final List<BookTagRow> existing =
        await db.getTagsForCollection(collectionId);
    if (existing.any((BookTagRow t) => t.id == tag.id)) {
      FushiToast.show(
        msg: t.tag_already_on_collection(name: tag.name),
        severity: ToastSeverity.warning,
      );
      return;
    }
    await db.addTagToCollection(collectionId, tag.id);
    ref.invalidate(collectionTagMapProvider);
    ref.invalidate(filteredCollectionIdsProvider);
    if (mounted) {
      FushiToast.show(
        msg: t.tag_added_to_collection(name: tag.name),
        severity: ToastSeverity.success,
      );
    }
  }

  /// 设置封面：统一封面服务（P3）——[MediaCoverService.pickCoverImage] 平台感知
  /// 选图（移动端相册 / 桌面文件对话框），再经 [MediaCoverService.applyVideoCoverManual]
  /// （拷盘 + 双键驱逐旧缓存 + 落库 + 记 manual 保护标记，批量刮削永不覆盖）→ 刷新。
  Future<void> _pickCover(VideoBookRow book) async {
    final File? picked = await MediaCoverService.pickCoverImage();
    if (picked == null || !mounted) return;
    await MediaCoverService.applyVideoCoverManual(
      repo: widget.repo,
      bookUid: book.bookUid,
      pickedPath: picked.path,
    );
    if (mounted) _refresh();
  }

  /// 组装海报刮削依赖：封面目录 + 独立 `video_scraper` 目录（离线库/别名缓存）+
  /// TMDB key（偏好）+ 离线索引（有则装载）。返回初始 service、离线重建工厂、目录。
  Future<
      ({
        CoverScraperService service,
        CoverScraperService Function(OfflineIndex offline) rebuild,
        Directory scraperDir,
      })> _scraperBundle() async {
    final Directory covers = await VideoStorage.coversDir();
    final Directory scraperDir =
        Directory(p.join(covers.parent.path, 'video_scraper'));
    await scraperDir.create(recursive: true);
    // 用户自填 key 优先，其次内置 key（[resolveTmdbApiKey]）。两者皆空才没有 TMDB
    // 源——fresh clone / fork 构建没内置 key 时的正常降级，不是错误。
    final String userTmdbKey = ref
        .read(appProvider)
        .prefsRepo
        .getPref(kVideoScraperTmdbApiKeyPref, defaultValue: '') as String;
    final String tmdbKey = resolveTmdbApiKey(userTmdbKey);
    CoverScraperService make(OfflineIndex? offline) => CoverScraperService(
          repository: widget.repo,
          coverMetaStore: CoverMetaStore(covers),
          aliasCache: AliasCache(scraperDir),
          bangumiClient: BangumiClient(),
          coverDownloader: CoverDownloader(),
          tmdbClient: tmdbKey.isEmpty ? null : TmdbClient(apiKey: tmdbKey),
          // AniList / Jikan 零 key 门槛，恒可用——没有「配了才有」这回事。
          aniListClient: AniListClient(),
          jikanClient: JikanClient(),
          offlineIndex: offline,
          coversDirectory: covers,
        );
    final OfflineIndex? offline =
        await CoverScraperService.loadOfflineIndex(scraperDir);
    return (
      service: make(offline),
      rebuild: (OfflineIndex o) => make(o),
      scraperDir: scraperDir,
    );
  }

  /// 本视频所属合集的全部成员 uid（用于「同时应用到本合集全部 N 集」）；不属任何合集
  /// 时返回仅含自身的单元素列表。
  Future<List<String>> _collectionMemberUids(String bookUid) async {
    final int? collectionId =
        _primaryCollectionByEntry[MediaKind.video.compositeKey(bookUid)];
    if (collectionId == null) return <String>[bookUid];
    final List<MediaCollectionItemRow> items =
        await ref.read(appProvider).database.getCollectionItems(collectionId);
    final List<String> uids = <String>[
      for (final MediaCollectionItemRow m in items)
        if (m.mediaType == MediaKind.video.dbValue) m.entryKey,
    ];
    return uids.isEmpty ? <String>[bookUid] : uids;
  }

  /// 长按菜单「在线匹配海报」：组装 service → 弹单本匹配弹窗（预填解析标题）。
  Future<void> _openCoverMatch(VideoBookRow book) async {
    final ({
      CoverScraperService service,
      CoverScraperService Function(OfflineIndex offline) rebuild,
      Directory scraperDir,
    }) bundle = await _scraperBundle();
    if (!mounted) return;
    final List<String> members = await _collectionMemberUids(book.bookUid);
    if (!mounted) return;
    await showCoverMatchDialog(
      context: context,
      service: bundle.service,
      book: book,
      collectionMemberUids: members,
      onApplied: _refresh,
    );
  }

  /// 页头「全部刮削」：显式重跑整库在线刮削。
  ///
  /// `rescrapeScraped: true` 只解锁「覆盖**自动**刮来的旧封面」这一件事——覆盖
  /// 决策本身全在 [CoverScraperService.scrapeLibrary] 那一层按封面来源做
  /// （BUG-1325）：用户手选的本地图（`manual`）、用户在匹配弹窗里亲手选定的条目
  /// （`userScraped`）、用户自己放的 sidecar 一律**永不覆盖**；来源未知的存量
  /// `scraped` 记录还要再过「唯一归一化精确标题」才允许覆盖。本页不再重复表达
  /// 判据，避免两处各说一套。
  Future<void> _scrapeAllVideos() async {
    final List<VideoBookRow> books = await widget.repo.listAll();
    if (!mounted) return;
    final ({
      CoverScraperService service,
      CoverScraperService Function(OfflineIndex offline) rebuild,
      Directory scraperDir,
    }) bundle = await _scraperBundle();
    if (!mounted) return;
    await showScrapeBatchDialog(
      context: context,
      mediaLabel: t.nav_video,
      itemCount: books.length,
      runner: (ScrapeBatchProgressCallback onProgress) async {
        ScrapeBatchSummary summary = const ScrapeBatchSummary();
        await for (final BatchScrapeProgress progress
            in bundle.service.scrapeLibrary(
          books,
          rescrapeScraped: true,
        )) {
          final ScrapeBatchItemResult result = switch (progress.outcome) {
            ScrapeApplied() => ScrapeBatchItemResult.applied,
            ScrapeNeedsConfirm() => ScrapeBatchItemResult.needsReview,
            ScrapeFailed() => ScrapeBatchItemResult.failed,
            _ => ScrapeBatchItemResult.skipped,
          };
          summary = summary.add(result);
          onProgress(
            ScrapeBatchProgress(
              current: progress.index + 1,
              total: progress.total,
              title: progress.book.title,
              summary: summary,
            ),
          );
        }
        if (mounted) _refresh();
        return summary;
      },
    );
  }

  /// 长按菜单「条目信息」：读本地已刮到的 Bangumi 条目资料并展示（只读，不发网络）。
  /// 「重新刮削」= 删掉该书资料行 + 忘掉本进程的尝试记录，再跑一次自动刮削。
  Future<void> _openScrapeInfo(VideoBookRow book) async {
    final ScrapeMetadata? meta = await widget.repo.scrapeMetadata(book.bookUid);
    if (!mounted) return;
    await showScrapeInfoDialog(
      context: context,
      fallbackTitle: book.title,
      metadata: meta,
      onRescrape: () async {
        await widget.repo.deleteScrapeMetadata(book.bookUid);
        _autoScrape?.forget(book.bookUid);
        await _maybeAutoScrape();
      },
      // 添加/修改 Bangumi 映射：跳到在线匹配弹窗（可搜索或贴条目 ID/URL 改绑）。
      onEditMapping: () => _openCoverMatch(book),
    );
  }

  /// 自动刮削：进视频页 + 每次库变化（新视频入库）后跑一遍，把还没有条目资料的
  /// 本地视频静默补齐（封面 + Bangumi 条目资料）。取代了原页头「批量匹配海报」
  /// 按钮——用户不必再记得点它。
  ///
  /// 受 [AppModel.videoAutoScrape] 总闸门控（默认开，设置页「媒体库」可关）。
  /// 服务自身负责串行/节流/去重与「每本每进程只试一次」，本方法只管喂书单，
  /// 重复调用是廉价的。刮完静默 [_refresh] 让新封面立即出现在网格里。
  Future<void> _maybeAutoScrape() async {
    final VideoScrapeAutoService service =
        _autoScrape ??= VideoScrapeAutoService(
      repository: widget.repo,
      serviceFactory: () async => (await _scraperBundle()).service,
      // 每轮进场读一次总闸：设置里关掉后下一轮立刻停，无需重建服务。
      isEnabled: () => ref.read(appProvider).videoAutoScrape,
    );
    if (service.isRunning) return;
    final List<VideoBookRow> books = await widget.repo.listAll();
    if (!mounted) return;
    final int before = service.attemptedCount;
    await service.sweep(books);
    // 有书真被刮过才重绘：没新刮到东西时避免无谓的整页重查（本方法每次 _refresh
    // 都会被调用，无条件 setState 会形成刷新环）。
    if (mounted && service.attemptedCount != before) {
      setState(() {
        _future = widget.repo.listForShelf();
      });
    }
  }

  /// 重命名视频/播放列表（C 需求③）：弹输入框预填当前标题 → 落库 → 刷新列表。
  /// 空白标题不提交（保持原名）。
  Future<void> _renameVideo(VideoBookRow book) async {
    final TextEditingController controller =
        TextEditingController(text: book.title);
    final String? newTitle = await showAppDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(t.video_rename),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: t.video_rename_hint),
          onSubmitted: (String v) => Navigator.pop(ctx, v),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t.dialog_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text(t.dialog_save),
          ),
        ],
      ),
    );
    controller.dispose();
    final String? trimmed = newTitle?.trim();
    if (trimmed == null || trimmed.isEmpty || trimmed == book.title) return;
    await widget.repo.updateTitle(book.bookUid, trimmed);
    if (mounted) _refresh();
  }

  Future<void> _confirmDelete(VideoBookRow book) async {
    final DeleteScope? scope = await showDeleteScopeConfirm(
      context,
      title: t.video_delete_title,
      message: t.video_delete_confirm(title: book.title),
      db: ref.read(appProvider).database,
    );
    if (scope == null || !mounted) return;
    final String? deletedCoverPath = book.coverPath;
    final String? deletedSubtitlePath = book.subtitleSource;
    final String deletedVideoPath = book.videoPath;
    await widget.repo.deleteVideoBook(book.bookUid, scope: scope);
    if (mounted) {
      _refreshAfterTagChange();
      await _waitForVideoCardsToUnmount();
    }
    await widget.repo.reclaimDeletedVideoBookAssets(
      deletedBookUid: book.bookUid,
      deletedCoverPath: deletedCoverPath,
      deletedSubtitlePath: deletedSubtitlePath,
      deletedVideoPath: deletedVideoPath,
    );
    await widget.repo.compactAfterVideoDeleteBestEffort();
  }

  @override
  Widget build(BuildContext context) {
    // 「视频」tab 已毕业为常驻：导入入口恒放出（原 `kVideoImportEnabled ||
    // experimentalVideoEnabled`，后者已删且恒 true，故门控恒真）。这个 watch
    // **不是**毕业开关残留、不可删：build 路径内 [_visibleRemoteVideos] 用
    // ref.read 读 prefsRepo.showRemoteEntries（另一处 appProvider watch 藏在
    // 合集行嵌套 builder 里，无合集时不执行），AppModel 转发 prefsRepo 的
    // notifyListeners，靠这里的订阅让「显示远端条目」开关切换时占位卡即时增删。
    ref.watch(appProvider);
    const bool canImport = true;
    final List<BookTagRow> allTags =
        ref.watch(allTagsProvider).valueOrNull ?? const <BookTagRow>[];
    // 页头/布局与书架 [reader_hibiki_history_page]、词典 [home_dictionary_page]
    // 统一：不再用自带 Scaffold + adaptiveAppBar（小标题 + 标准 IconButton），改成
    // DesktopContentLayout + FushiPageHeader（大标题 + FushiIconButton），三个
    // 首页 tab 的标题字号与动作按钮位置因此完全一致。外层 Scaffold 由 HomePage 提供。
    // BUG-250: 视频 tab 的批量选择模式（[_selectionMode]）和书架一样活在 tab
    // 内容里、不是独立 route。顶层 HomePage 的 PopScope 对它无感，返回键会直接
    // 退出 App，而不是退出选择模式。这里用嵌套 PopScope 拦截：选择模式开启时
    // canPop=false，返回先退出选择模式（与书架 / 查词 tab 一致）。
    return PopScope(
      canPop: !_selectionMode,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        if (_selectionMode) _exitSelectionMode();
      },
      child: FushiFileDropTarget(
        debugLabel: 'home-video',
        onDrop: _handleVideoDrop,
        child: CardDropScope<VideoBookRow>(
          registry: _cardDropRegistry,
          child: DesktopContentLayout(
            kind: DesktopContentKind.readerShelf,
            child: Column(
              children: <Widget>[
                if (!isCupertinoPlatform(context)) _buildPageHeader(canImport),
                _buildVideoSearchBar(),
                _buildTagFilterBar(allTags),
                // 下拉同步可能跑几十秒，光一个转圈看不出进展；没同步在飞时零高度。
                const SyncProgressBanner(),
                Expanded(
                  // 多选态才接管长按：长按落在卡上 = 起手扫选，不抬手滑动即刷出
                  // 一段区间。非多选态原样透传（长按仍归卡片自身的菜单）。
                  child: SelectionDragArea(
                    enabled: _selectionMode,
                    onDragBegin: (SelectionSlot slot) =>
                        setState(() => _selection.beginRangeDrag(slot)),
                    onDragUpdate: (SelectionSlot slot) =>
                        setState(() => _selection.updateRangeDrag(slot)),
                    onDragEnd: () => setState(_selection.endRangeDrag),
                    child: _buildVideoLibraryBody(),
                  ),
                ),
                if (_selectionMode) _buildBatchActionBar(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVideoLibraryBody() {
    return FutureBuilder<List<VideoBookRow>>(
      future: _future,
      builder: (BuildContext context, AsyncSnapshot<List<VideoBookRow>> snap) {
        if (snap.connectionState == ConnectionState.done && snap.hasData) {
          _videosCache = snap.data;
        }
        final List<VideoBookRow>? loaded =
            snap.connectionState == ConnectionState.done
                ? (snap.data ?? const <VideoBookRow>[])
                : _videosCache;
        if (loaded == null) {
          // 仅首载（无缓存）显示加载圈；后续刷新用旧数据顶住，不闪屏。
          return buildLoading();
        }
        final List<VideoBookRow> all = loaded;
        final Set<String>? filter =
            ref.watch(filteredVideoBookUidsProvider).valueOrNull;
        // BUG-940：合集标签维度。视频成员级过滤须并入——否则「合集打了标签但成员
        // 没打」时成员被剥光、_groupVideos 折叠不出合集组，之后 collectionVisible 也
        // 救不回（无组可留），合集永远筛不出来。
        final Set<int>? collectionFilter =
            ref.watch(filteredCollectionIdsProvider).valueOrNull;
        final List<VideoBookRow> books = filter == null
            ? all
            : all.where((VideoBookRow b) {
                // 成员命中标签、或所属合集命中标签都保留（后者让打了标签的合集其成员
                // 整组存活、折叠出合集组）。
                return keepMemberUnderTagFilter(
                  memberMatched: filter.contains(b.bookUid),
                  primaryCollectionId: _primaryCollectionByEntry[
                      MediaKind.video.compositeKey(b.bookUid)],
                  collectionFilter: collectionFilter,
                );
              }).toList();
        // P5-A：搜索按标题匹配，归一化走与书架/游戏库页同一份
        // [matchesMediaSearch]（全角/片假名/标点折叠），三页搜出的结果口径一致。
        final List<VideoBookRow> searched = _searchQuery.trim().isEmpty
            ? books
            : books
                .where((VideoBookRow b) => matchesMediaSearch(
                      query: _searchQuery,
                      titles: <String>[b.title],
                    ))
                .toList();
        // 排序交互重设计：卡片间序在 group 层按当前排序方式做（[_groupVideos]），
        // 这里不再预排散列表（旧 ShelfEntries.sortOrder 死权重已废弃，用户拍板）。
        // TODO-2486：年份 / 看完状态下拉筛选（本地即筛）。年份由条目刮削 airDate
        // 派生（无资料 = 归「未知」桶，条目不消失）；看完状态按 completedAt /
        // lastPositionMs 三档判。
        final List<VideoBookRow> ordered = <VideoBookRow>[
          for (final VideoBookRow b in searched)
            if (_yearFilter.matches(_airYearByUid[b.bookUid]) &&
                matchesVideoWatchStatus(
                  filter: _watchStatusFilter,
                  completed: b.completedAt != null,
                  lastPositionMs: b.lastPositionMs,
                ))
              b,
        ];
        // 记录当前可见（已过滤）的本地视频，供批量「全选 / 反选」用。
        _visibleVideos = ordered;
        return FutureBuilder<_RemoteVideoState?>(
          future: _remoteFuture,
          builder: (BuildContext context,
              AsyncSnapshot<_RemoteVideoState?> remoteSnap) {
            // 多端库联合视图（spec 2026-07-12 §2.1/§2.4/§2.5，撤独立远端分区）：把
            // 互联「远端有、本地无」的视频混排成主网格占位卡（云角标 + 远端封面，
            // 点击走现有远端流播 [_openRemote] / 下载 [_downloadRemote]）。云端视频本批
            // 不接（其目录 client 由并行批产出）——[_resolveRemoteVideoClient] 只对互联
            // 后端返回 client，故 remoteSnap 天然只含互联视频，不为云视频造假入口。
            // 离线/未配对/拉取失败（state==null 或 failed）→ 占位卡不出现（只剩本地）；
            // 「显示远端条目」开关关闭 / 标签筛选激活时同样不混排（远端视频无本地标签）。
            // BUG-994：自动刷新/重拉期间（future→waiting、data 暂 null）沿用上次成功态，
            // 避免远端占位卡整批闪一下（对称本地 _videosCache）。失败态不覆盖缓存。
            final _RemoteVideoState? snapState = remoteSnap.data;
            if (snapState != null && !snapState.failed) {
              _lastRemoteState = snapState;
            }
            // TODO-2486：远端条目与本地同规则过年份/看完状态筛选（远端无刮削
            // 资料 = 未知年份桶；无完成标记按未完成、进度取 positionMs）。
            final List<RemoteVideoInfo> remoteVideos = <RemoteVideoInfo>[
              for (final RemoteVideoInfo v in _visibleRemoteVideos(
                  snapState ?? _lastRemoteState, filter))
                if (_yearFilter.matches(null) &&
                    matchesVideoWatchStatus(
                      filter: _watchStatusFilter,
                      completed: false,
                      lastPositionMs: v.positionMs,
                    ))
                  v,
            ];
            // 下拉刷新：保活后切回不再隐式重拉远端，给用户显式强制刷新入口。
            // AlwaysScrollableScrollPhysics 保证内容不足一屏时也能下拉触发。
            // UI v2：散卡网格与合集横排行统一卡宽（用户实报合集卡大一截）——
            // 以 240 为目标宽算响应式列数，两处共用同一实际卡宽。
            return RefreshIndicator(
              onRefresh: _pullToRefresh,
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  final FushiDesignTokens tokens =
                      FushiDesignTokens.of(context);
                  // 卡目标宽与书架同源（[readerShelfGridExtentForWidth]）：手机窄屏
                  // （宽<600）用 150 → 至少 2 列，不再「1 列铺满整屏、卡片过大」；宽屏
                  // 按断点收敛列数。此前硬编码 240 使手机可用宽≈380 时 floor 出 1 列。
                  final ({int columns, double cardWidth}) cardLayout =
                      unifiedShelfCardLayout(
                    availableWidth:
                        constraints.maxWidth - tokens.spacing.card * 2,
                    targetWidth:
                        readerShelfGridExtentForWidth(constraints.maxWidth),
                  );
                  return CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: <Widget>[
                      // UI v2 Phase B：顶部「继续观看 hero + 媒体库概览」条（用户拍板：
                      // mockup 顶排的收藏筛选换成统计）。空库隐藏；统计按未过滤全量
                      // [all] 描述整库，不随标签筛选变。
                      // BUG-995：只看互联远端视频（无本地视频）时也要显示概览+继续观看，
                      // 故门控与数据都并入 remoteVideos（否则整块消失=用户实报「远端的没有」）。
                      if (all.isNotEmpty || remoteVideos.isNotEmpty)
                        SliverToBoxAdapter(
                          child: _buildOverviewSection(
                            all,
                            remoteVideos,
                            ordered,
                            constraints.maxWidth,
                            cardLayout,
                          ),
                        ),
                      ..._buildLocalVideoSlivers(
                          all, ordered, remoteVideos, cardLayout),
                    ],
                  );
                },
              ),
            );
          },
        );
      },
    );
  }

  /// TODO-2486（hayase 式改版）：顶部区 = 全宽 backdrop hero 轮播（最近在看的
  /// 前 5 个合集，无在看回落最近添加）+「继续观看」/「最近添加」横滚行。
  ///
  /// hero 取**未过滤**全量 [all]（「最近在看」不受筛选条影响）；两条横滚行取
  /// 过滤后 [filtered] + [remoteVideos]（筛选条对行与墙同时生效，口径一致）。
  /// 远端占位（BUG-995 血缘）：远端进度条目照常进「继续观看」行，只看互联远端
  /// 视频（无本地视频）时也有续播入口。三块全空时整段隐藏。
  Widget _buildOverviewSection(
    List<VideoBookRow> all,
    List<RemoteVideoInfo> remoteVideos,
    List<VideoBookRow> filtered,
    double availableWidth,
    ({int columns, double cardWidth}) cardLayout,
  ) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double coverHeight =
        videoCoverHeightForPortraitWidth(cardLayout.cardWidth);
    final Widget? hero = _buildHeroCarousel(
      all,
      availableWidth - tokens.spacing.card * 2,
    );
    final Widget? continueRow =
        _buildContinueRow(filtered, remoteVideos, coverHeight);
    final Widget? recentRow = _buildRecentlyAddedRow(filtered, coverHeight);
    if (hero == null && continueRow == null && recentRow == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.card,
        tokens.spacing.gap,
        tokens.spacing.card,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (hero != null) hero,
          if (continueRow != null) continueRow,
          if (recentRow != null) recentRow,
        ],
      ),
    );
  }

  /// hero 轮播数据：本地条目按主折叠归属聚成**合集单元**，无归属且**在看**的
  /// 成为**散装单元**（v68：此前散装被整体排除，用户最后看的是散装时置顶就不是
  /// 「上一个观看的」），两类同池按最近观看倒序选前 5（[selectVideoHeroUnits]
  /// 纯函数，测试同源）。「最近添加」回落池维持合集粒度——散装不占回落位，零
  /// 观看库的 hero 形态与从前完全一致。远端条目本地无行不进 hero（远端进度条目
  /// 走「继续观看」行）。
  List<_VideoHeroItem> _heroItems(List<VideoBookRow> all) {
    final Map<int, List<VideoBookRow>> membersByCollection =
        <int, List<VideoBookRow>>{};
    final List<VideoBookRow> standaloneBooks = <VideoBookRow>[];
    for (final VideoBookRow book in all) {
      final int? cid =
          _primaryCollectionByEntry[MediaKind.video.compositeKey(book.bookUid)];
      if (cid == null || !_collectionsById.containsKey(cid)) {
        standaloneBooks.add(book);
        continue;
      }
      membersByCollection.putIfAbsent(cid, () => <VideoBookRow>[]).add(book);
    }
    final List<VideoHeroCandidate<_VideoHeroItem>> candidates =
        <VideoHeroCandidate<_VideoHeroItem>>[];
    for (final VideoBookRow book in standaloneBooks) {
      // 散装只在「在看」（有断点且未看完）时进候选：用户诉求是「置顶 = 上一个
      // 观看的」，进在看池混排即可满足；**不进**「最近添加」回落池——否则单
      // 文件库刚导入一个视频顶上就平白多一块大图，且与下方墙卡同屏重复。
      if (book.lastPositionMs <= 0 || book.completedAt != null) continue;
      final DateTime? at =
          _watchAtByUid[book.bookUid] ?? _legacyWatchAtByTitle[book.title];
      candidates.add(VideoHeroCandidate<_VideoHeroItem>(
        unit: _VideoHeroItem.standalone(book),
        lastWatchedAt: at,
        latestImportedAt: 0,
        hasUnfinishedTrace: true,
      ));
    }
    membersByCollection.forEach((int cid, List<VideoBookRow> members) {
      // 组内序与合集详情/播放器同源（memberSortIndex）。
      members.sort((VideoBookRow a, VideoBookRow b) {
        final int ia =
            _memberSortIndex[MediaKind.video.compositeKey(a.bookUid)] ??
                1 << 30;
        final int ib =
            _memberSortIndex[MediaKind.video.compositeKey(b.bookUid)] ??
                1 << 30;
        return ia.compareTo(ib);
      });
      DateTime? lastWatched;
      int latestImported = 0;
      int completed = 0;
      bool hasTrace = false;
      for (final VideoBookRow m in members) {
        final DateTime? at =
            _watchAtByUid[m.bookUid] ?? _legacyWatchAtByTitle[m.title];
        if (at != null && (lastWatched == null || at.isAfter(lastWatched))) {
          lastWatched = at;
        }
        final int imported = m.importedAt ?? 0;
        if (imported > latestImported) latestImported = imported;
        if (m.completedAt != null) completed++;
        if (m.completedAt != null || m.lastPositionMs > 0) hasTrace = true;
      }
      candidates.add(VideoHeroCandidate<_VideoHeroItem>(
        unit: _VideoHeroItem.collection(
          collection: _collectionsById[cid]!,
          members: members,
          meta: _collectionScrapeMetaById[cid],
        ),
        lastWatchedAt: lastWatched,
        latestImportedAt: latestImported,
        hasUnfinishedTrace: hasTrace && completed < members.length,
      ));
    });
    return selectVideoHeroUnits<_VideoHeroItem>(candidates);
  }

  /// 全宽 backdrop hero 轮播。手动切换（滑动 + 右下指示条点击），**禁自动轮播**
  /// （尊重 prefers-reduced-motion 精神）。无候选合集（零合集库）返回 null 整块
  /// 隐藏。桌面鼠标拖拽翻页经共享 [HorizontalDragScrollable] 放开；滚轮不桥——
  /// hero 占满整宽，滚轮语义留给页面纵滚。
  Widget? _buildHeroCarousel(List<VideoBookRow> all, double availableWidth) {
    final List<_VideoHeroItem> items = _heroItems(all);
    if (items.isEmpty) return null;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double height = videoHeroHeightForWidth(availableWidth);
    final int page = _heroPage.clamp(0, items.length - 1);
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.spacing.gap),
      child: ClipRRect(
        borderRadius: FushiBorderRadius.card,
        child: SizedBox(
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              HorizontalDragScrollable(
                child: PageView.builder(
                  key: const ValueKey<String>('home_video_hero_carousel'),
                  controller: _heroPageController,
                  onPageChanged: (int i) => setState(() => _heroPage = i),
                  itemCount: items.length,
                  itemBuilder: (BuildContext context, int i) =>
                      _buildHeroPage(items[i]),
                ),
              ),
              // 右下轮播指示条（当前页拉长高亮；点击直达）。
              if (items.length > 1)
                Positioned(
                  right: 16,
                  bottom: 12,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      for (int i = 0; i < items.length; i++)
                        GestureDetector(
                          onTap: () => _heroPageController.animateToPage(
                            i,
                            duration: const Duration(milliseconds: 240),
                            curve: Curves.easeOutCubic,
                          ),
                          child: Container(
                            key: ValueKey<String>('home_video_hero_dot_$i'),
                            width: i == page ? 18 : 8,
                            height: 4,
                            margin: const EdgeInsets.only(left: 4),
                            decoration: BoxDecoration(
                              color: i == page
                                  ? Colors.white
                                  : Colors.white.withValues(alpha: 0.4),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// hero 单页：backdrop（media_images 横图优先 → 封面回落，
  /// [LandscapeCoverImage] 朝向分流：竖版海报模糊垫底 + contain 前景）+ 左下
  /// 资料列（季节/年份 · 标题/logo · 已看 N 集 · 简介两行）+ 续播
  /// FilledButton /「详情」按钮分工。合集页背景整面点击 = 进合集详情（与
  /// 「详情」同路）；散装页（v68 起可进 hero）背景点击 = 直接续播（散装没有
  /// 详情页，「详情」按钮也不出现）。渐变 scrim 走 overlays 注入（层序由组件
  /// 保证：盖模糊垫底、不压清晰海报前景，BUG-1298 血缘）。
  Widget _buildHeroPage(_VideoHeroItem item) {
    final ThemeData theme = Theme.of(context);
    final MediaCollectionRow? collection = item.collection;
    final VideoBookRow? standalone = item.standalone;
    // v68：横版背景/logo 走 media_images（合集归属 / 散装电影的 bookUid 归属）。
    // 背景无横图回落封面（成员借用链 / 散装自身封面），LandscapeCoverImage 垫底。
    final List<MediaImageRow>? images = collection != null
        ? _mediaImagesByCollection[collection.id]
        : _mediaImagesByBookUid[standalone!.bookUid];
    final ImageProvider? background = _mediaImageProvider(
          images,
          const <MediaImageKind>[MediaImageKind.backdrop],
        ) ??
        (collection != null
            ? _collectionMembersCoverProvider(item.members)
            : _localCoverProvider(standalone!));
    final ImageProvider? logo = _mediaImageProvider(
      images,
      const <MediaImageKind>[MediaImageKind.logo],
    );
    final String title = collection?.name ?? standalone!.title;
    int completedCount = 0;
    final List<CollectionMemberProgress> progresses =
        <CollectionMemberProgress>[
      for (final VideoBookRow m in item.members)
        CollectionMemberProgress(
          positionMs: m.lastPositionMs,
          completed: m.completedAt != null,
        ),
    ];
    for (final VideoBookRow m in item.members) {
      if (m.completedAt != null) completedCount++;
    }
    final int continueEp = item.members.isEmpty
        ? 1
        : continueMemberIndex(progresses).clamp(0, item.members.length - 1) + 1;
    // 资料：合集读合集刮削行；散装读条目刮削行（电影的作品级资料就在这）。
    final VideoScrapeMetaRow? standaloneMeta =
        standalone == null ? null : _videoScrapeMetaByUid[standalone.bookUid];
    final String? airLabel =
        _heroAirLabel(item.meta?.airDate ?? standaloneMeta?.airDate);
    final String? summary =
        (item.meta?.summary ?? standaloneMeta?.summary)?.trim();
    // 散装的主按钮语义：有断点 =「继续观看」，全新 =「播放」；合集恒
    // 「继续看·第 N 集」。背景整面点击与主按钮同路。
    final VoidCallback? primaryAction = _selectionMode
        ? null
        : (collection != null
            ? () => _openHeroContinue(item)
            : () => unawaited(_open(standalone!)));
    final TextStyle? titleStyle = theme.textTheme.headlineSmall?.copyWith(
      color: Colors.white,
      fontWeight: FontWeight.w800,
    );
    final Widget backgroundWidget = background == null
        ? ColoredBox(color: theme.colorScheme.surfaceContainer)
        : LandscapeCoverImage(
            image: background,
            overlays: const <Widget>[
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: <Color>[
                      Color(0xCC000000),
                      Color(0x66000000),
                      Color(0x1A000000),
                    ],
                    stops: <double>[0.0, 0.55, 1.0],
                  ),
                ),
              ),
            ],
            foregroundPadding: const EdgeInsetsDirectional.only(end: 24),
            errorBuilder: (BuildContext _) =>
                ColoredBox(color: theme.colorScheme.surfaceContainer),
          );
    return Stack(
      key: ValueKey<String>('home_video_hero_page_${item.pageKey}'),
      fit: StackFit.expand,
      children: <Widget>[
        GestureDetector(
          // 多选纪律（PR#664 复核）：多选态下 hero 不导航（进详情会把批量操作
          // 中途弹走页面）；按钮同门控（onPressed=null 渲染禁用态，见下）。
          // 合集页背景点击进详情；散装页无详情页，与主按钮同路直接开播。
          onTap: _selectionMode
              ? null
              : (collection != null
                  ? () => _openCollectionDetail(collection)
                  : primaryAction),
          child: backgroundWidget,
        ),
        // 资料列自身不拦背景点击（按钮仍各自可点）。
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (airLabel != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    airLabel,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: Colors.white.withValues(alpha: 0.8),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              // v68：有标题 logo 用图（Jellyfin 式），语义/回落仍是标题文字。
              if (logo != null)
                Semantics(
                  label: title,
                  image: true,
                  child: ConstrainedBox(
                    constraints:
                        const BoxConstraints(maxHeight: 76, maxWidth: 360),
                    child: Image(
                      key: ValueKey<String>(
                          'home_video_hero_logo_${item.pageKey}'),
                      image: logo,
                      fit: BoxFit.contain,
                      alignment: AlignmentDirectional.bottomStart,
                      errorBuilder: (_, __, ___) => Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: titleStyle,
                      ),
                    ),
                  ),
                )
              else
                ShelfTitleOverflowTooltip(
                  title: title,
                  style: titleStyle,
                  maxLines: 2,
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle,
                  ),
                ),
              // 「已看 N 集」是合集语义；散装单条目不显示（没有集的概念）。
              if (collection != null) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  t.video_hero_episodes_watched(n: completedCount),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.white.withValues(alpha: 0.82),
                  ),
                ),
              ],
              if (summary != null && summary.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    summary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  FilledButton.icon(
                    // 合集页 key 沿用 '<id>'（既有 widget 测试锁它）；散装页
                    // 走 pageKey（'b<uid>'），两个 key 空间不撞。
                    key: ValueKey<String>(collection != null
                        ? 'home_video_hero_continue_${collection.id}'
                        : 'home_video_hero_continue_${item.pageKey}'),
                    onPressed: primaryAction,
                    icon: const Icon(Icons.play_arrow),
                    label: Text(collection != null
                        ? t.collection_continue_progress(n: continueEp)
                        : (standalone!.lastPositionMs > 0
                            ? t.video_continue_watching
                            : t.collection_play)),
                  ),
                  if (collection != null) ...<Widget>[
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      key: ValueKey<String>(
                          'home_video_hero_detail_${collection.id}'),
                      onPressed: _selectionMode
                          ? null
                          : () => _openCollectionDetail(collection),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: BorderSide(
                          color: Colors.white.withValues(alpha: 0.5),
                        ),
                      ),
                      icon: const Icon(Icons.info_outline),
                      label: Text(t.video_hero_detail_view),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 季节/年份行：`2024 · 春`；无月份只显年份；无刮削年份返回 null（整行隐藏）。
  /// 季度对齐番剧习惯（1-3 冬 / 4-6 春 / 7-9 夏 / 10-12 秋）。
  /// 入参收成裸 airDate 字符串：合集页给合集刮削行的、散装页给条目刮削行的，
  /// 同一个格式同一个解析。
  String? _heroAirLabel(String? airDate) {
    final int? year = videoAirYear(airDate);
    if (year == null) return null;
    final String? season = switch (videoAirSeasonQuarter(airDate)) {
      1 => t.video_air_season_winter,
      2 => t.video_air_season_spring,
      3 => t.video_air_season_summer,
      4 => t.video_air_season_autumn,
      _ => null,
    };
    return season == null ? '$year' : '$year · $season';
  }

  /// 「继续看·第 N 集」落地：Next-Up 纯函数选集（[continueMemberIndex]，与合集
  /// 卡进度行同源）→ 共享路由入口带合集上下文开播（剧集面板/上下集/连播）。
  /// 只服务合集单元；散装单元的主按钮直接 `_open(book)`（见 [_buildHeroPage]）。
  void _openHeroContinue(_VideoHeroItem item) {
    final MediaCollectionRow? collection = item.collection;
    if (collection == null || item.members.isEmpty) return;
    final List<CollectionMemberProgress> progresses =
        <CollectionMemberProgress>[
      for (final VideoBookRow m in item.members)
        CollectionMemberProgress(
          positionMs: m.lastPositionMs,
          completed: m.completedAt != null,
        ),
    ];
    final int index =
        continueMemberIndex(progresses).clamp(0, item.members.length - 1);
    unawaited(_open(
      item.members[index],
      playlistCollectionId: collection.id,
    ));
  }

  /// hero / 行卡成员封面回落链：首个有本地封面的成员（组内序），全缺返回 null。
  ImageProvider? _collectionMembersCoverProvider(List<VideoBookRow> members) {
    for (final VideoBookRow m in members) {
      final ImageProvider? provider = _localCoverProvider(m);
      if (provider != null) return provider;
    }
    return null;
  }

  /// 「继续观看」横滚行：有进度未看完的条目/合集（本地散卡 + 合集 + 远端进度
  /// 条目），按最近观看倒序取前 15。全无候选返回 null 整行隐藏。
  Widget? _buildContinueRow(
    List<VideoBookRow> filtered,
    List<RemoteVideoInfo> remoteVideos,
    double coverHeight,
  ) {
    final Map<int, List<VideoBookRow>> membersByCollection =
        <int, List<VideoBookRow>>{};
    final List<VideoBookRow> looseLocal = <VideoBookRow>[];
    for (final VideoBookRow book in filtered) {
      final int? cid =
          _primaryCollectionByEntry[MediaKind.video.compositeKey(book.bookUid)];
      if (cid != null && _collectionsById.containsKey(cid)) {
        membersByCollection.putIfAbsent(cid, () => <VideoBookRow>[]).add(book);
      } else {
        looseLocal.add(book);
      }
    }
    final List<_VideoRowItem> items = <_VideoRowItem>[];
    membersByCollection.forEach((int cid, List<VideoBookRow> members) {
      members.sort((VideoBookRow a, VideoBookRow b) {
        final int ia =
            _memberSortIndex[MediaKind.video.compositeKey(a.bookUid)] ??
                1 << 30;
        final int ib =
            _memberSortIndex[MediaKind.video.compositeKey(b.bookUid)] ??
                1 << 30;
        return ia.compareTo(ib);
      });
      int completed = 0;
      bool hasTrace = false;
      DateTime? lastWatched;
      for (final VideoBookRow m in members) {
        if (m.completedAt != null) completed++;
        if (m.completedAt != null || m.lastPositionMs > 0) hasTrace = true;
        final DateTime? at =
            _watchAtByUid[m.bookUid] ?? _legacyWatchAtByTitle[m.title];
        if (at != null && (lastWatched == null || at.isAfter(lastWatched))) {
          lastWatched = at;
        }
      }
      // 与合集卡进度行同口径：有痕迹且未整套看完才算「在看」。
      if (!hasTrace || completed >= members.length) return;
      final MediaCollectionRow collection = _collectionsById[cid]!;
      items.add(_VideoRowItem(
        recentMs: lastWatched?.millisecondsSinceEpoch ?? 0,
        build: () => _buildContinueCollectionCard(
          collection,
          members,
          coverHeight,
          completed,
        ),
      ));
    });
    for (final VideoBookRow book in looseLocal) {
      if (book.completedAt != null || book.lastPositionMs <= 0) continue;
      final DateTime? at =
          _watchAtByUid[book.bookUid] ?? _legacyWatchAtByTitle[book.title];
      items.add(_VideoRowItem(
        recentMs: at?.millisecondsSinceEpoch ?? 0,
        build: () => _buildContinueEntryCard(book, coverHeight),
      ));
    }
    for (final RemoteVideoInfo video in remoteVideos) {
      if (video.positionMs <= 0) continue;
      items.add(_VideoRowItem(
        recentMs: video.positionUpdatedAtMs,
        build: () => _buildContinueRemoteCard(video, coverHeight),
      ));
    }
    if (items.isEmpty) return null;
    items.sort(
        (_VideoRowItem a, _VideoRowItem b) => b.recentMs.compareTo(a.recentMs));
    return _buildHorizontalCardRow(
      title: t.video_continue_watching,
      controller: _continueRowController,
      coverHeight: coverHeight,
      items: items.take(15).toList(),
    );
  }

  /// 「最近添加」横滚行：入库 [kVideoRecentlyAddedWindow]（14 天）内的本地条目
  /// 按入库时刻倒序取前 15，「新」角标。远端占位无入库时刻，不进本行。
  Widget? _buildRecentlyAddedRow(
    List<VideoBookRow> filtered,
    double coverHeight,
  ) {
    final DateTime now = DateTime.now();
    final List<VideoBookRow> recent = <VideoBookRow>[
      for (final VideoBookRow b in filtered)
        if (isVideoRecentlyAdded(importedAt: b.importedAt, now: now)) b,
    ]..sort((VideoBookRow a, VideoBookRow b) =>
        (b.importedAt ?? 0).compareTo(a.importedAt ?? 0));
    if (recent.isEmpty) return null;
    return _buildHorizontalCardRow(
      title: t.home_recently_added,
      controller: _recentRowController,
      coverHeight: coverHeight,
      items: <_VideoRowItem>[
        for (final VideoBookRow book in recent.take(15))
          _VideoRowItem(
            recentMs: book.importedAt ?? 0,
            build: () => _buildRecentlyAddedCard(book, coverHeight),
          ),
      ],
    );
  }

  /// 横滚行骨架：区块标题 + 定高横向 ListView。桌面滚轮经共享
  /// [WheelToHorizontalScroll] 桥成横滚（BUG-1214 同款）、鼠标拖拽经
  /// [HorizontalDragScrollable] 放开；触屏行为不变。
  Widget _buildHorizontalCardRow({
    required String title,
    required ScrollController controller,
    required double coverHeight,
    required List<_VideoRowItem> items,
  }) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.spacing.gap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
            child: Text(title, style: tokens.type.sectionLabel),
          ),
          SizedBox(
            height: coverHeight + _videoCardTextBlock(context),
            child: WheelToHorizontalScroll(
              controller: controller,
              child: HorizontalDragScrollable(
                child: ListView.separated(
                  controller: controller,
                  scrollDirection: Axis.horizontal,
                  physics: desktopAwareScrollPhysics(),
                  itemCount: items.length,
                  separatorBuilder: (BuildContext _, int __) =>
                      SizedBox(width: tokens.spacing.gap),
                  itemBuilder: (BuildContext context, int i) =>
                      items[i].build(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 横滚行通用卡：高度统一、宽度随封面朝向（竖 2:3 / 横 16:9，
  /// [CoverOrientationBuilder] 探测与卡内封面共用同一 provider 键，零额外解码）。
  /// 底边进度条、集数/「新」/云角标，两行标题 + 溢出 Tooltip（TODO-2490 同款）。
  ///
  Widget _buildRowMediaCard({
    required Key cardKey,
    required FushiFocusId focusId,
    required ImageProvider? cover,
    required String title,
    required double coverHeight,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    double? progressFraction,
    int? episodeCount,
    bool newBadge = false,
    bool cloudBadge = false,
  }) {
    final TextStyle? titleStyle = Theme.of(context).textTheme.bodyMedium;
    Widget buildCard(BuildContext context, VideoCardOrientation orientation) {
      final double width = videoCardWidthForOrientation(
        orientation: orientation,
        coverHeight: coverHeight,
      );
      return SizedBox(
        width: width,
        child: FushiCard(
          key: cardKey,
          focusId: focusId,
          padding: EdgeInsets.zero,
          // 多选纪律（PR#664 复核）：横滚行是墙内容的**快捷镜像，不参与勾选**
          // ——勾选一律走墙卡/合集卡（行卡不在 setVisibleOrder 的可见序里，
          // 参与勾选会打乱 Shift 区间语义）。进入多选态后行卡点击不得再触发
          // 播放/流播（误触会把批量操作中途弹进播放器），长按/右键置 null
          // 让位祖先 SelectionDragArea 扫选，与墙卡同一纪律。
          onTap: _selectionMode ? null : onTap,
          onLongPress: _selectionMode ? null : onLongPress,
          onSecondaryTap: _selectionMode ? null : onLongPress,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SizedBox(
                height: coverHeight,
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    if (cover == null)
                      ShelfCoverPlaceholder(
                        icon: Icons.movie_outlined,
                        backgroundColor:
                            Theme.of(context).colorScheme.surfaceContainer,
                      )
                    else
                      PortraitCoverImage(
                        image: cover,
                        landscapeSlot:
                            orientation == VideoCardOrientation.landscape,
                        errorBuilder: (BuildContext _) => ShelfCoverPlaceholder(
                          icon: Icons.movie_outlined,
                          backgroundColor:
                              Theme.of(context).colorScheme.surfaceContainer,
                        ),
                      ),
                    if (episodeCount != null && episodeCount >= 2)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: _buildPlaylistBadge(episodeCount),
                      ),
                    if (newBadge)
                      Positioned(
                        top: 6,
                        left: 6,
                        child: CoverBadge(
                          icon: Icons.fiber_new_outlined,
                          label: t.video_recently_added_badge,
                        ),
                      ),
                    if (cloudBadge)
                      const Positioned(
                        bottom: 6,
                        right: 6,
                        child: CoverBadge(icon: Icons.cloud_outlined),
                      ),
                    // 底边进度条（YouTube 式），与墙卡同款视觉。
                    if (progressFraction != null)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: IgnorePointer(
                          child: LinearProgressIndicator(
                            value: progressFraction,
                            minHeight: 3,
                            backgroundColor:
                                Colors.black.withValues(alpha: 0.35),
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: ShelfTitleOverflowTooltip(
                      title: title,
                      style: titleStyle,
                      maxLines: 2,
                      child: Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: titleStyle,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return CoverOrientationBuilder(image: cover, builder: buildCard);
  }

  /// 继续观看行·本地散卡：点击直接续播；多集显集数角标 + 按集进度条（单视频无
  /// 总时长列，不造百分比 → 不画进度条，与墙卡同一诚实口径）。
  /// v68 选图链 titleCard → backdrop（散装电影刮削图组）→ 自身封面；卡朝向随
  /// 选中那张图探测（用户拍板：续播行单行、横竖混排无排版问题——有横图出横卡，
  /// 只有竖版海报就自然出竖卡，不强制垫底成 16:9）。
  Widget _buildContinueEntryCard(VideoBookRow book, double coverHeight) {
    final int episodeCount = playlistEpisodeCount(book.playlistJson);
    return _buildRowMediaCard(
      cardKey: ValueKey<String>('home_video_continue_${book.bookUid}'),
      focusId: FushiFocusId('home-video-continue-${book.bookUid}'),
      cover: _mediaImageProvider(
            _mediaImagesByBookUid[book.bookUid],
            const <MediaImageKind>[
              MediaImageKind.titleCard,
              MediaImageKind.backdrop,
            ],
          ) ??
          _localCoverProvider(book),
      title: book.title,
      coverHeight: coverHeight,
      onTap: () => _open(book),
      onLongPress: () => _showVideoMenu(book),
      progressFraction: videoWatchFraction(
        completed: book.completedAt != null,
        currentEpisode: book.currentEpisode,
        episodeCount: episodeCount,
      ),
      episodeCount: episodeCount,
    );
  }

  /// 继续观看行·合集卡：点击续播 Next-Up 一集（带合集上下文）；进度条 = 已看完
  /// 成员 / 总数；集数角标 = 成员数。
  Widget _buildContinueCollectionCard(
    MediaCollectionRow collection,
    List<VideoBookRow> members,
    double coverHeight,
    int completedCount,
  ) {
    return _buildRowMediaCard(
      cardKey:
          ValueKey<String>('home_video_continue_collection_${collection.id}'),
      focusId: FushiFocusId('home-video-continue-collection-${collection.id}'),
      // v68 选图链（Jellyfin preferThumb 口径）：带字横图 → 无字背景 →
      // 成员封面借用链；卡朝向随选中那张图探测（混排语义，见散卡注释）。
      cover: _mediaImageProvider(
            _mediaImagesByCollection[collection.id],
            const <MediaImageKind>[
              MediaImageKind.titleCard,
              MediaImageKind.backdrop,
            ],
          ) ??
          _collectionRowCoverProvider(collection, members),
      title: collection.name,
      coverHeight: coverHeight,
      onTap: () {
        if (members.isEmpty) return;
        final List<CollectionMemberProgress> progresses =
            <CollectionMemberProgress>[
          for (final VideoBookRow m in members)
            CollectionMemberProgress(
              positionMs: m.lastPositionMs,
              completed: m.completedAt != null,
            ),
        ];
        final int index =
            continueMemberIndex(progresses).clamp(0, members.length - 1);
        unawaited(_open(members[index], playlistCollectionId: collection.id));
      },
      onLongPress: () => _showCollectionContextMenu(collection),
      progressFraction:
          members.isEmpty ? null : completedCount / members.length,
      episodeCount: members.length,
    );
  }

  /// 继续观看行·远端占位卡：点击流播（BUG-995 血缘——只看远端也有续播入口）；
  /// 云角标；远端无完成口径，不画进度条。
  Widget _buildContinueRemoteCard(RemoteVideoInfo video, double coverHeight) {
    final String safeKey = _safeRemoteKey(video.id);
    return _buildRowMediaCard(
      cardKey: ValueKey<String>('home_video_continue_remote_$safeKey'),
      focusId: FushiFocusId('home-video-continue-remote-$safeKey'),
      cover: _remoteCoverProvider(video),
      title: video.title,
      coverHeight: coverHeight,
      onTap: () => _openRemote(video),
      onLongPress: () => _showRemoteVideoDialog(video),
      episodeCount: video.isPlaylist ? video.episodes.length : null,
      cloudBadge: true,
    );
  }

  /// 最近添加行卡：「新」角标；点击带主合集上下文开播。
  Widget _buildRecentlyAddedCard(VideoBookRow book, double coverHeight) {
    final int? cid =
        _primaryCollectionByEntry[MediaKind.video.compositeKey(book.bookUid)];
    return _buildRowMediaCard(
      cardKey: ValueKey<String>('home_video_recent_${book.bookUid}'),
      focusId: FushiFocusId('home-video-recent-${book.bookUid}'),
      cover: _localCoverProvider(book),
      title: book.title,
      coverHeight: coverHeight,
      onTap: () => _open(book, playlistCollectionId: cid),
      onLongPress: () => _showVideoMenu(book),
      episodeCount: playlistEpisodeCount(book.playlistJson),
      newBadge: true,
    );
  }

  /// 合集行卡封面 provider：自有封面优先 → 成员借用链（与墙卡同序）。
  ImageProvider? _collectionRowCoverProvider(
    MediaCollectionRow collection,
    List<VideoBookRow> members,
  ) {
    final String? own = collection.coverPath;
    if (own != null && own.isNotEmpty && File(own).existsSync()) {
      return resizedFileImage(File(own));
    }
    return _collectionMembersCoverProvider(members);
  }

  /// 概览用短日期（跨年补年份）。UI 巡检 PR-4：走 [MaterialLocalizations] 随
  /// locale 本地化（此前手拼 `M-dd`，任何 locale 都是同一种破折号格式）。
  String _formatOverviewDate(DateTime at) {
    final MaterialLocalizations localizations =
        MaterialLocalizations.of(context);
    if (at.year == DateTime.now().year) {
      return localizations.formatShortMonthDay(at);
    }
    return localizations.formatShortDate(at);
  }

  /// 本地视频区的 sliver 列表：空库 / 筛选无结果时是占满剩余空间的提示；否则
  /// **单一网格**（用户拍板 2026-07-22 恢复封面形态：「一进去就是封面，跟小说
  /// 那种一样，一眼认出是哪部」）——合集渲染成与散卡同尺寸的**封面卡**
  /// （[_buildCollectionCoverCard]），与散卡（本地 + 未归属远端占位）合成同一个
  /// [SliverGrid]：合集卡在前（保持排序模式的组间序）、散卡在后。替代旧
  /// 「合集横排行 slivers + 散卡网格」两段式（全宽横排行一屏只装下一两个合集，
  /// 认不出是哪部）。分区序（合集区恒在散卡之上）沿袭去碎片方案 A 拍板。
  List<Widget> _buildLocalVideoSlivers(
    List<VideoBookRow> all,
    List<VideoBookRow> books,
    List<RemoteVideoInfo> remoteVideos,
    ({int columns, double cardWidth}) cardLayout,
  ) {
    // 空态/筛选空态须把远端占位一并纳入判断：仅本地空但有远端占位时仍要渲染网格。
    if (all.isEmpty && remoteVideos.isEmpty) {
      return <Widget>[
        SliverFillRemaining(hasScrollBody: false, child: _buildEmpty()),
      ];
    }
    if (books.isEmpty && remoteVideos.isEmpty) {
      return <Widget>[
        SliverFillRemaining(hasScrollBody: false, child: _buildFilteredEmpty()),
      ];
    }
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 多端库联合视图 §2.3 任务10：把「远端有本地无」视频的**主合集归属**（host 下发的
    // RemoteVideoInfo.collection）注入折叠映射，使远端占位卡折进对应本地合集行。远端合集
    // 本地无 id——按 (name, type) 对本地合集表解析（[_resolveLocalCollectionId]），解析不到
    // = 散卡降级（不硬造合集行）。云视频占位 collection 恒 null（散卡）。局部拷贝页级
    // 映射后注入，避免污染跨帧共享的 _primaryCollectionByEntry / _memberSortIndex。
    final Map<String, int> primaryByEntry =
        Map<String, int>.of(_primaryCollectionByEntry);
    final Map<String, int> memberSortIndex =
        Map<String, int>.of(_memberSortIndex);
    for (final RemoteVideoInfo video in remoteVideos) {
      final RemoteCollectionMembership? membership = video.collection;
      if (membership == null) continue;
      final int? cid = _resolveLocalCollectionId(
        membership.collectionName,
        membership.collectionType,
      );
      if (cid == null) continue; // 归属解析不到本地合集 → 散卡降级
      final String key = MediaKind.video.compositeKey(video.id);
      primaryByEntry[key] = cid;
      memberSortIndex[key] = membership.sortIndex;
    }
    final List<CollectionGroup<_VideoSlot>> groups =
        _groupVideos(books, remoteVideos, primaryByEntry, memberSortIndex);
    // 合集标签过滤：含【全部】选中标签的合集 id（null = 无选中标签，不过滤）。
    // 合集卡（及其成员）按此显隐；散卡由 filteredVideoBookUidsProvider 另行过滤。
    final Set<int>? collectionFilter =
        ref.watch(filteredCollectionIdsProvider).valueOrNull;
    bool collectionVisible(int collectionId) =>
        collectionFilter == null || collectionFilter.contains(collectionId);
    // 块2：记录本帧渲染成封面卡的合集 id（供全选/反选把可见合集纳入整选集）。
    // 被标签过滤隐藏的合集不计入可见集，避免全选勾中隐藏合集。
    _visibleCollectionIds = <int>[
      for (final CollectionGroup<_VideoSlot> g in groups)
        if (g.collection != null && collectionVisible(g.collection!.id))
          g.collection!.id,
    ];
    // 合集卡在前（保持排序模式的组间序）、散卡（本地 + 未归属远端占位）在后，
    // 全部并入同一个网格（cell 逐像素同尺寸）。
    final List<CollectionGroup<_VideoSlot>> collectionGroups =
        <CollectionGroup<_VideoSlot>>[];
    final List<_VideoLooseCard> loose = <_VideoLooseCard>[];
    for (final CollectionGroup<_VideoSlot> group in groups) {
      if (group.collection == null) {
        final _VideoSlot slot = group.coverItem.payload;
        loose.add(_VideoLooseCard(
          sortKey: _groupSortKey(group),
          entry: _VideoWallEntry(
            cover: _videoSlotCoverProvider(slot),
            build: (VideoCardOrientation orientation) =>
                _buildVideoSlotCard(slot, orientation: orientation),
          ),
          selectionKey: slot.local?.bookUid,
        ));
      } else if (collectionVisible(group.collection!.id)) {
        collectionGroups.add(group);
      }
      // 标签过滤隐藏的合集：整卡连同成员一并跳过（成员随合集隐藏，符合按合集标签显隐语义）。
    }
    loose.sort((_VideoLooseCard a, _VideoLooseCard b) =>
        compareShelfSortKeys(a.sortKey, b.sortKey, _sortMode));
    // Shift 区间选 / 长按扫选的顺序真值：取排序**之后**的散卡序，与用户屏幕上的
    // 排列逐项一致（排序 / 搜索 / 标签筛选都已作用其上）。顺序一变，控制器自动
    // 清锚点，Shift 不会选中一片没看见的条目。
    _selection.setVisibleOrder(
      loose: <String>[
        for (final _VideoLooseCard card in loose)
          if (card.selectionKey != null) card.selectionKey!,
      ],
      collections: _visibleCollectionIds,
    );
    final List<_VideoWallEntry> cells = <_VideoWallEntry>[
      for (final CollectionGroup<_VideoSlot> group in collectionGroups)
        _VideoWallEntry(
          cover: _collectionCoverProvider(group),
          build: (VideoCardOrientation orientation) =>
              _buildCollectionCoverCard(group, orientation: orientation),
        ),
      for (final _VideoLooseCard card in loose) card.entry,
    ];
    if (cells.isEmpty) return const <Widget>[];
    return <Widget>[
      _buildVideoWallSliver(
        cells,
        EdgeInsets.all(tokens.spacing.card),
        cardLayout,
      ),
    ];
  }

  /// 散卡分派：本地卡 [_buildCard] / 远端占位卡 [_buildRemoteVideoCard]（任务10 union）。
  Widget _buildVideoSlotCard(
    _VideoSlot slot, {
    VideoCardOrientation orientation = VideoCardOrientation.portrait,
  }) {
    final VideoBookRow? local = slot.local;
    if (local != null) return _buildCard(local, orientation: orientation);
    return _buildRemoteVideoCard(slot.remote!, orientation: orientation);
  }

  /// 墙格朝向探测封面 provider（与卡内封面同键共享解码）。
  ImageProvider? _videoSlotCoverProvider(_VideoSlot slot) {
    final VideoBookRow? local = slot.local;
    if (local != null) return _localCoverProvider(local);
    return _remoteCoverProvider(slot.remote!);
  }

  /// 本地卡朝向探测/渲染共用封面 provider（缺失/悬空路径 = null → 占位 + 恒竖卡）。
  ImageProvider? _localCoverProvider(VideoBookRow book) {
    final String? cover = book.coverPath;
    if (cover == null || cover.isEmpty || !File(cover).existsSync()) {
      return null;
    }
    return resizedFileImage(File(cover));
  }

  /// 远端占位卡封面 provider（本地缓存文件 → 钉扎客户端 URL；两者皆无 = null）。
  ImageProvider? _remoteCoverProvider(RemoteVideoInfo video) {
    final String? coverPath = video.coverPath;
    if (coverPath != null && File(coverPath).existsSync()) {
      return FileImage(File(coverPath));
    }
    final String? coverUrl = video.coverUrl;
    final RemoteCoverFetcher? fetcher =
        remoteCoverFetcherFor(_remoteVideoClient);
    if (coverUrl != null && coverUrl.isNotEmpty && fetcher != null) {
      return RemoteCoverImage(coverUrl, fetcher, cacheKey: video.id);
    }
    return null;
  }

  /// 合集卡朝向探测封面 provider：借用链与 [_buildCollectionCover] 同序（自有
  /// → 本地成员 → 远端成员）。
  ImageProvider? _collectionCoverProvider(CollectionGroup<_VideoSlot> group) {
    final String? own = group.collection?.coverPath;
    if (own != null && own.isNotEmpty && File(own).existsSync()) {
      return resizedFileImage(File(own));
    }
    for (final CollectionOrderingItem<_VideoSlot> it in group.items) {
      final VideoBookRow? local = it.payload.local;
      if (local == null) continue;
      final ImageProvider? provider = _localCoverProvider(local);
      if (provider != null) return provider;
    }
    for (final CollectionOrderingItem<_VideoSlot> it in group.items) {
      final RemoteVideoInfo? remote = it.payload.remote;
      if (remote == null) continue;
      final ImageProvider? provider = _remoteCoverProvider(remote);
      if (provider != null) return provider;
    }
    return null;
  }

  /// 按 (name, collectionType) 自然键把远端合集归属解析成本地合集 id（折叠归属同「最小
  /// collectionId」规则，多个同键取最小）；本地无此合集则返 null（散卡降级，不硬造行）。
  int? _resolveLocalCollectionId(String name, String type) {
    int? best;
    for (final MediaCollectionRow c in _collectionsById.values) {
      if (c.name == name && c.collectionType == type) {
        if (best == null || c.id < best) best = c.id;
      }
    }
    return best;
  }

  /// 过滤后视频（本地 + 远端占位 union）→ 合集折叠 + 按当前排序方式排 group。远端占位
  /// 用 `-1-index` 编码 importedAt（全为负，稳定排在本地条目之后、组内保持目录序）。
  List<CollectionGroup<_VideoSlot>> _groupVideos(
    List<VideoBookRow> books,
    List<RemoteVideoInfo> remoteVideos,
    Map<String, int> primaryByEntry,
    Map<String, int> memberSortIndex,
  ) {
    final List<CollectionOrderingItem<_VideoSlot>> items =
        <CollectionOrderingItem<_VideoSlot>>[
      for (final VideoBookRow book in books)
        CollectionOrderingItem<_VideoSlot>(
          mediaType: MediaKind.video,
          entryKey: book.bookUid,
          importedAt: book.importedAt ?? 0,
          payload: _VideoSlot(local: book),
        ),
    ];
    for (int i = 0; i < remoteVideos.length; i++) {
      final RemoteVideoInfo video = remoteVideos[i];
      items.add(CollectionOrderingItem<_VideoSlot>(
        mediaType: MediaKind.video,
        entryKey: video.id,
        importedAt: -1 - i,
        payload: _VideoSlot(remote: video),
      ));
    }
    final List<CollectionGroup<_VideoSlot>> groups =
        groupByCollections<_VideoSlot>(
      items: items,
      primaryCollectionIdByEntry: primaryByEntry,
      collectionsById: _collectionsById,
      memberSortIndex: memberSortIndex,
    );
    groups.sort(
      (CollectionGroup<_VideoSlot> a, CollectionGroup<_VideoSlot> b) =>
          compareShelfSortKeys(_groupSortKey(a), _groupSortKey(b), _sortMode),
    );
    return groups;
  }

  /// 组级排序键：散卡取条目自身；合集行取成员聚合（recent/imported 取成员 max、
  /// title 取合集名）。本地 recentScore = watch-stats 最近观看毫秒（v39 uid 键控，遗留
  /// NULL-uid 行按 title 回退），无观看记录退 importedAt；远端占位 recentScore = 远端进度
  /// 时间戳（无则退目录序编码 it.importedAt），稳定排在本地条目之后。
  ShelfSortKey _groupSortKey(CollectionGroup<_VideoSlot> group) {
    int recentOf(CollectionOrderingItem<_VideoSlot> it) {
      final VideoBookRow? local = it.payload.local;
      if (local != null) {
        return (_watchAtByUid[local.bookUid] ??
                    _legacyWatchAtByTitle[local.title])
                ?.millisecondsSinceEpoch ??
            it.importedAt;
      }
      final RemoteVideoInfo remote = it.payload.remote!;
      return remote.positionUpdatedAtMs > 0
          ? remote.positionUpdatedAtMs
          : it.importedAt;
    }

    String titleOf(_VideoSlot s) => s.local?.title ?? s.remote!.title;
    String tieOf(_VideoSlot s) =>
        s.local != null ? s.local!.bookUid : 'remote:${s.remote!.id}';
    final MediaCollectionRow? collection = group.collection;
    if (collection == null) {
      final CollectionOrderingItem<_VideoSlot> it = group.coverItem;
      return ShelfSortKey(
        recentScore: recentOf(it),
        title: titleOf(it.payload),
        importedAt: it.importedAt,
        tieKey: tieOf(it.payload),
      );
    }
    int recent = 0;
    int imported = 0;
    for (final CollectionOrderingItem<_VideoSlot> it in group.items) {
      final int rs = recentOf(it);
      if (rs > recent) recent = rs;
      if (it.importedAt > imported) imported = it.importedAt;
    }
    return ShelfSortKey(
      recentScore: recent,
      title: collection.name,
      importedAt: imported,
      tieKey: 'c${collection.id}',
    );
  }

  /// 合集封面卡（用户拍板 2026-07-22 恢复封面形态：「文字合集替换成一个封面」）。
  /// 几何与散卡逐像素同规格（unifiedShelfCardLayout 卡宽 × [_videoCardExtent]
  /// cell 高：2:3 竖版海报封面 + 标题 footer + 进度行），并入主网格。
  ///
  /// 原横排行的能力全数搬进整卡（Never break userspace）：
  /// - 点击 = 进合集详情页（原「查看全部」，点某集从详情页进播放器带连播上下文）；
  /// - focusId 沿用 `home-video-collection-<id>`（手柄/键盘映射不变）；
  /// - 多选态整卡勾选 = 选中整个合集（[_selectedCollectionIds]）；
  /// - 拖标签到卡 = 给合集打标签（[BookDragTarget]，与散卡书级拖放一致）；
  /// - 计数含远端占位成员（与详情所见同源，BUG-790 口径）；含远端占位时右上云角标。
  ///
  /// 折叠偏好（`collapsed_collection_ids`）视频侧退役：封面卡无成员行可折叠；
  /// 书架横排行照旧读写该偏好，pref 本身不动。
  Widget _buildCollectionCoverCard(
    CollectionGroup<_VideoSlot> group, {
    VideoCardOrientation orientation = VideoCardOrientation.portrait,
  }) {
    final MediaCollectionRow collection = group.collection!;
    final List<BookTagRow> tags =
        ref.watch(collectionTagMapProvider).valueOrNull?[collection.id] ??
            const <BookTagRow>[];
    final int memberCount = group.items.length;
    final bool hasRemoteMember = group.items.any(
        (CollectionOrderingItem<_VideoSlot> it) => it.payload.remote != null);
    final bool selected =
        _selectionMode && _selectedCollectionIds.contains(collection.id);
    final FushiCard card = FushiCard(
      key: ValueKey<String>('home_video_collection_card_${collection.id}'),
      focusId: FushiFocusId('home-video-collection-${collection.id}'),
      padding: EdgeInsets.zero,
      selected: selected,
      // 多选态整卡点击 = 整选合集；平时点击 = 进详情（原「查看全部」）。
      onTap: () {
        if (_selectionMode) {
          _toggleCollectionSelection(collection.id);
          return;
        }
        // 桌面 Ctrl/⌘（macOS）/ Shift + 点击 = 直接进多选并整选该合集。
        if (selectionEntryModifierPressed(context)) {
          _enterSelectionWith(SelectionSlot.collection(collection.id));
          return;
        }
        _openCollectionDetail(collection);
      },
      // 未进入选择态时，触屏与桌面长按都保留合集上下文菜单；只有显式进入选择态
      // 后才禁用菜单，让整卡点击/扫选负责勾选。
      onLongPress:
          _selectionMode ? null : () => _showCollectionContextMenu(collection),
      onSecondaryTap:
          _selectionMode ? null : () => _showCollectionContextMenu(collection),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AspectRatio(
            // TODO-2486 朝向自适应：竖版 2:3 海报 / 横版 16:9（封面朝向由墙格
            // CoverOrientationBuilder 探测注入），与散卡同分流。
            aspectRatio:
                orientation == VideoCardOrientation.landscape ? 16 / 9 : 2 / 3,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                _buildCollectionCover(
                  group,
                  landscapeSlot: orientation == VideoCardOrientation.landscape,
                ),
                // 合集标签 chip 列（左上，与散卡标签层同形）；多选态让位勾选框。
                if (tags.isNotEmpty && !_selectionMode)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: _buildTagLabels(tags),
                  ),
                // 含远端占位成员 → 右下云角标（与散卡云角标同位；右上让位给
                // 集数角标，TODO-2486 设计稿拍板）。
                if (hasRemoteMember)
                  Positioned(
                    bottom: 6,
                    right: 6,
                    child: CoverBadge(
                      key: ValueKey<String>(
                          'home_video_collection_cloud_${collection.id}'),
                      icon: Icons.cloud_outlined,
                      iconSize: 13,
                    ),
                  ),
                // 右上 playlist 图标 + 成员数（本地 + 远端占位，与详情所见同源，
                // BUG-790 口径：数字必须诚实反映合集实际成员数）。
                Positioned(
                  top: 6,
                  right: 6,
                  child: _buildPlaylistBadge(memberCount),
                ),
                if (_selectionMode)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: ShelfSelectionCheck(selected: selected),
                  ),
                if (selected)
                  const Positioned.fill(child: ShelfSelectedOverlay()),
              ],
            ),
          ),
          // footer：合集名 + 进度行（结构与散卡 [_buildCard] 同骨架）。
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
                  // TODO-2490：两行仍放不下时，桌面悬停显示完整合集名。
                  child: ShelfTitleOverflowTooltip(
                    title: collection.name,
                    style: Theme.of(context).textTheme.bodyMedium,
                    maxLines: 2,
                    child: Text(
                      collection.name,
                      // BUG-1184：与同网格的散卡标题同规格（两行）。
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ),
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                    child: Text(
                      _collectionProgressLabel(group),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: FushiDesignTokens.of(context).type.metadata,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    // 长按扫选身份标记：合集区自成一段区间，扫选可在合集之间连选。
    final SelectionSlot slot = SelectionSlot.collection(collection.id);
    // 选择态下禁用标签拖放命中（与散卡一致：避免选卡时误触拖标签）。
    if (_selectionMode) return SelectionSlotTarget(slot: slot, child: card);
    // 视频合集是封面卡（不是 CollectionShelfRow 行头——`unified_collections_
    // architecture_guard_test` 明令禁止视频页回退用行式布局），故接收端直接包在
    // 卡上：拖视频卡落到合集封面 = 加入该合集。
    return SelectionSlotTarget(
      slot: slot,
      child: CollectionDropTarget(
        onMediaDropped: (MediaRef mediaRef) =>
            _addMediaToCollection(collection.id, mediaRef),
        child: BookDragTarget(
          bookId: 'collection:${collection.id}',
          onTagDropped: (BookTagRow tag) =>
              _addTagToVideoCollection(collection.id, tag),
          child: card,
        ),
      ),
    );
  }

  /// 合集卡封面：**合集自有封面**（`MediaCollections.coverPath`，schema v61）优先 →
  /// 首个有本地封面的成员 → 首个远端成员封面（互联/云 fetch 路径）→ 无封面占位
  /// （与散卡同款 surfaceContainer + movie 图标）。成员段组内序优先，故默认就是
  /// [CollectionGroup.coverItem]（首成员）的封面，成员缺封面时向后借。
  ///
  /// 自有封面列 NULL（老库全部合集、从没换过封面的合集）→ 直接落到成员借用链，
  /// 与 v61 之前逐像素相同（Never break userspace）。文件不存在也回落，不出破图：
  /// overwrite 模式备份恢复会把源机的绝对路径原样带过来（备份不打包 `video_covers/`），
  /// 那种悬空路径必须表现得像「没设过封面」。
  Widget _buildCollectionCover(
    CollectionGroup<_VideoSlot> group, {
    bool landscapeSlot = false,
  }) {
    final String? own = group.collection?.coverPath;
    if (own != null && own.isNotEmpty && File(own).existsSync()) {
      return PortraitCoverImage(
        image: resizedFileImage(File(own)),
        landscapeSlot: landscapeSlot,
        errorBuilder: (BuildContext _) => ShelfCoverPlaceholder(
          icon: Icons.movie_outlined,
          backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
        ),
      );
    }
    for (final CollectionOrderingItem<_VideoSlot> it in group.items) {
      final VideoBookRow? local = it.payload.local;
      if (local == null) continue;
      final String? cover = local.coverPath;
      if (cover != null && cover.isNotEmpty && File(cover).existsSync()) {
        // 朝向自适应槽位：不合槽封面由 [PortraitCoverImage] 用「模糊同图垫底 +
        // contain 前景」填充；解码上限与旧 cacheWidth 同源（resizedFileImage 默认 720）。
        return PortraitCoverImage(
          image: resizedFileImage(File(cover)),
          landscapeSlot: landscapeSlot,
          errorBuilder: (BuildContext _) => ShelfCoverPlaceholder(
            icon: Icons.movie_outlined,
            backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
          ),
        );
      }
    }
    for (final CollectionOrderingItem<_VideoSlot> it in group.items) {
      final RemoteVideoInfo? remote = it.payload.remote;
      if (remote == null) continue;
      final bool hasCover =
          (remote.coverPath != null && File(remote.coverPath!).existsSync()) ||
              (remote.coverUrl != null && remote.coverUrl!.isNotEmpty);
      if (hasCover) {
        return _buildRemoteVideoCover(
          remote,
          poster: true,
          landscapeSlot: landscapeSlot,
        );
      }
    }
    return ShelfCoverPlaceholder(
      icon: Icons.movie_outlined,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
    );
  }

  /// 合集卡进度行：有观看痕迹且未整套看完 → 「继续看 第n集」（[continueMemberIndex]
  /// 纯函数，与旧横排行初始横滚定位同源）；否则 → 「已看完 x/N」（x = completedAt
  /// 非空的本地成员数；远端占位无本地完成态，只计入 N）。
  String _collectionProgressLabel(CollectionGroup<_VideoSlot> group) {
    final int total = group.items.length;
    int completed = 0;
    bool hasTrace = false;
    final List<CollectionMemberProgress> progresses =
        <CollectionMemberProgress>[
      for (final CollectionOrderingItem<_VideoSlot> it in group.items)
        CollectionMemberProgress(
          // 远端占位无本地播放断点：用远端进度 positionMs、completed 恒 false。
          positionMs: it.payload.local?.lastPositionMs ??
              it.payload.remote?.positionMs ??
              0,
          completed: it.payload.local?.completedAt != null,
        ),
    ];
    for (final CollectionMemberProgress p in progresses) {
      if (p.completed) completed++;
      if (p.completed || (p.positionMs ?? 0) > 0) hasTrace = true;
    }
    if (hasTrace && completed < total) {
      return t.collection_continue_progress(
        n: continueMemberIndex(progresses) + 1,
      );
    }
    return t.collection_watched_progress(done: completed, total: total);
  }

  /// 多端库联合视图占位卡（spec 2026-07-12 §2.1，撤独立远端分区）：本地视频卡尺寸 +
  /// 远端封面 + 云角标 ☁，混排进视频库主网格散卡区（[_buildLocalVideoSlivers]）。
  /// 短按走现有远端流播 [_openRemote]；右上角下载按钮/进度徽章复用 [_downloadRemote]
  /// （下载委托 InterconnectDownloadManager，切 tab/退页仍推进）。
  Widget _buildRemoteVideoCard(
    RemoteVideoInfo video, {
    List<RemoteVideoInfo>? collectionMembers,
    int memberIndex = 0,
    VideoCardOrientation orientation = VideoCardOrientation.portrait,
  }) {
    final String safeKey = _safeRemoteKey(video.id);
    // 不再固定 260 宽：和本地 [_buildCard] 一样让卡片填满网格 cell，宽度由
    // 响应式网格决定（TODO-593）。
    return FushiCard(
      key: ValueKey<String>('remote_video_card_$safeKey'),
      focusId: FushiFocusId('home-video-remote-$safeKey'),
      padding: EdgeInsets.zero,
      // 合集行内点远端成员：带合集成员上下文进播放器（连播）；散卡区无上下文（单视频）。
      onTap: () => _openRemote(video,
          collectionMembers: collectionMembers, startIndex: memberIndex),
      // 短按仍流式播放（_openRemote）；长按 / 桌面右键弹选项面板，与本地视频
      // 卡长按一致（TODO-768 / BUG-416）。原先远端视频卡无 onLongPress（长按
      // 没反应），现在补齐。
      //
      // 多选态压制，与本地散卡 / 合集卡同一纪律：远端占位卡不可单独勾选，但它
      // 此前**漏了这道门控**，多选态长按它会弹选项面板，而不是被祖先
      // [SelectionDragArea] 接走起手扫选——正好证伪了那一层「多选态下卡片长按
      // 本就置 null」的前提。
      onLongPress: _selectionMode ? null : () => _showRemoteVideoDialog(video),
      onSecondaryTap:
          _selectionMode ? null : () => _showRemoteVideoDialog(video),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // BUG-926：与本地卡同因——封面从 Expanded 改为固定 AspectRatio，标题浮动
          // 高度不再反灌封面区。TODO-2486 朝向自适应：竖版 2:3 / 横版 16:9，
          // 不合槽封面由 [PortraitCoverImage] 模糊垫底填充。
          AspectRatio(
            aspectRatio:
                orientation == VideoCardOrientation.landscape ? 16 / 9 : 2 / 3,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                _buildRemoteVideoCover(
                  video,
                  poster: true,
                  landscapeSlot: orientation == VideoCardOrientation.landscape,
                ),
                // UI 巡检 PR-4：撤掉封面内嵌下载 IconButton——它是卡内嵌套焦点目标
                // （违反 hero 卡「无独立按钮」纪律，见 [_buildContinueHero]），且热区
                // <48dp。下载动作收敛到长按 / 右键面板（[_showRemoteVideoDialog] 的
                // 「下载」快捷动作，云视频短按卡片本体即下载）。下载进行中仍在原位
                // 显示纯展示的进度徽章（非交互，无焦点问题）。
                if (ref
                    .watch(interconnectDownloadManagerProvider)
                    .isRunning(video.id))
                  Positioned(
                    top: 6,
                    right: 6,
                    child: RemoteDownloadProgressBadge(
                      key:
                          ValueKey<String>('remote_video_downloading_$safeKey'),
                      progress: ref
                          .watch(interconnectDownloadManagerProvider)
                          .progressFor(video.id),
                      tooltip: t.remote_video_downloading,
                    ),
                  ),
                // 字幕角标收敛到共享 [CoverBadge]（UI 巡检 PR-4，PR-0 组件）。
                if (video.hasSubtitle)
                  const Positioned(
                    top: 6,
                    left: 6,
                    child: CoverBadge(icon: Icons.subtitles_outlined),
                  ),
                // TODO-885: 远端播放列表集数角标（与本地卡同款，左下避开右上字幕/下载）。
                if (video.isPlaylist)
                  Positioned(
                    bottom: 6,
                    left: 6,
                    child: _buildPlaylistBadge(video.episodes.length),
                  ),
                // 多端库联合视图云角标 ☁（spec §2.1）：占位卡「远端/未下载」标识，
                // 叠右下角（右上=下载/进度、左上=字幕、左下=集数，互不遮挡）。
                Positioned(
                  bottom: 6,
                  right: 6,
                  child: _remoteVideoCloudBadge(safeKey),
                ),
              ],
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  // TODO-2490：两行仍放不下时，桌面悬停显示完整标题。
                  child: ShelfTitleOverflowTooltip(
                    title: video.title,
                    style: Theme.of(context).textTheme.bodyMedium,
                    maxLines: 2,
                    child: Text(
                      video.title,
                      // BUG-1184：远端视频占位卡与本地散卡同规格（两行）。
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// [poster] = true：主网格 2:3 竖版槽位，走 [PortraitCoverImage]（横版截帧模糊
  /// 垫底 + contain 前景）；false：对话框等 16:9 语境保持原 contain + 衬底渲染。
  Widget _buildRemoteVideoCover(
    RemoteVideoInfo video, {
    bool poster = false,
    bool landscapeSlot = false,
  }) {
    final String safeKey = _safeRemoteKey(video.id);
    final Key coverKey = ValueKey<String>('remote_video_cover_$safeKey');
    final String? coverPath = video.coverPath;
    if (coverPath != null && File(coverPath).existsSync()) {
      // TODO-616 phase C / BUG-926 后注释更新（UI 巡检 PR-4）：非 poster 槽位保留
      // contain 让非 16:9 源完整显示不裁切，露出的空带由 [_coverBacking] 垫
      // surfaceContainer 衬底（不再透出卡片底色的突兀白/黑边）。
      if (poster) {
        return PortraitCoverImage(
          image: FileImage(File(coverPath)),
          landscapeSlot: landscapeSlot,
          imageKey: coverKey,
          errorBuilder: (BuildContext _) => ShelfCoverPlaceholder(
            icon: Icons.movie_outlined,
            backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
          ),
        );
      }
      return _coverBacking(
        Image.file(
          File(coverPath),
          key: coverKey,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => ShelfCoverPlaceholder(
            icon: Icons.movie_outlined,
            backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
          ),
        ),
      );
    }
    final String? coverUrl = video.coverUrl;
    // TODO-1235（TODO-961 回归）：封面走互联同款钉扎客户端拉取，不再用 Image.network
    // （Flutter 内部 HttpClient 无 badCertificateCallback，https 自签握手必失败）。
    final RemoteCoverFetcher? fetcher =
        remoteCoverFetcherFor(_remoteVideoClient);
    if (coverUrl != null && coverUrl.isNotEmpty && fetcher != null) {
      // BUG-847：按稳定 video.id 磁盘缓存（非易变 coverUrl），冷启动/滚动不重下。
      final RemoteCoverImage remoteImage =
          RemoteCoverImage(coverUrl, fetcher, cacheKey: video.id);
      if (poster) {
        return PortraitCoverImage(
          image: remoteImage,
          landscapeSlot: landscapeSlot,
          imageKey: coverKey,
          errorBuilder: (BuildContext _) => ShelfCoverPlaceholder(
            icon: Icons.movie_outlined,
            backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
          ),
        );
      }
      return _coverBacking(
        Image(
          image: remoteImage,
          key: coverKey,
          // 非 16:9 源 contain 完整显示，同上衬底。
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => ShelfCoverPlaceholder(
            icon: Icons.movie_outlined,
            backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
          ),
        ),
      );
    }
    return ShelfCoverPlaceholder(
      icon: Icons.movie_outlined,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
    );
  }

  /// 封面衬底（UI 巡检 PR-4）：contain 的非 16:9 封面在 16:9 槽位里露出的空带
  /// 垫 surfaceContainer（与共享 [ShelfCoverPlaceholder] 占位同色），本地 / 远端卡共用。
  Widget _coverBacking(Widget cover) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: cover,
    );
  }

  String _safeRemoteKey(String id) =>
      id.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');

  /// 云角标 ☁：共享 [CoverBadge]（UI 巡检 PR-4 收敛，与字幕/集数徽章同款视觉）。
  /// 多端库联合视图占位卡的「远端 / 未下载」标识（spec §2.1）。带稳定 key 供
  /// widget 测试定位。
  Widget _remoteVideoCloudBadge(String safeKey) {
    return CoverBadge(
      key: ValueKey<String>('remote_video_cloud_badge_$safeKey'),
      icon: Icons.cloud_outlined,
      iconSize: 13,
    );
  }

  /// 页头：与书架/词典统一，用 [FushiPageHeader] 大标题 + [FushiIconButton] 动作
  /// （统计 + 导入），保证标题字号与按钮位置三 tab 一致。与书架一致仅在非 Cupertino
  /// 渲染（Cupertino 走平台导航，由 HomePage 外壳承担）。
  Widget _buildPageHeader(bool canImport) {
    final List<Widget> actions = <Widget>[
      // 图标顺序与书架完全一致：导入 → 收藏夹 → 统计。书架
      // [reader_hibiki_history_page._buildPageHeader] 把导入按钮放在第一位
      // （buildBookImportButton），收藏夹、统计紧随其后；视频 tab 照此对齐
      // （TODO-162：此前视频把导入放在末尾，与书架不一致）。视频导入仍受
      // [canImport] 门控（仅视频 tab 才有导入入口），这里只调整位置不改门控。
      // 宽窗（非 compact）时四个动作展开成「图标+文字」药丸（用户 mockup：把
      // 「导入视频、媒体库」等按钮可展开时展开）；窄窗自动回落纯图标。
      if (canImport)
        FushiIconButton(
          tooltip: t.video_import_action,
          label: t.video_import_action,
          icon: Icons.add,
          onTap: _openImport,
        ),
      FushiIconButton(
        tooltip: t.scrape_all,
        label: t.scrape_all,
        icon: Icons.manage_search_outlined,
        onTap: _scrapeAllVideos,
      ),
      // 「番剧下载」不再占页头：它是下载子系统的入口，在「下载」页
      // （downloads_page）里有完整入口，视频库页头只留库管理动作。
      // 「管理来源」在库页导航壳里已是一等视图（[MediaSourcesPage]），页头再放一个
      // 按钮就是同一件事的两个入口。只有本页被独立使用（无导航条）时才保留按钮。
      if (canImport && widget.navigation == null)
        FushiIconButton(
          tooltip: t.media_source_manage_title,
          label: t.media_source_manage_title,
          icon: Icons.folder_copy_outlined,
          onTap: _openManageSources,
        ),
      FushiIconButton(
        tooltip: t.collections,
        label: t.collections,
        icon: Icons.collections_bookmark_outlined,
        onTap: _openCollections,
      ),
      FushiIconButton(
        tooltip: t.video_statistics,
        label: t.video_statistics,
        icon: Icons.bar_chart_outlined,
        onTap: _openStatistics,
      ),
      // 自动刮削仍会在进页面 / 新视频入库时后台跑（[_maybeAutoScrape]）；上面的
      // 「全部刮削」是用户明确要求的手动重跑入口，单本纠错仍在长按菜单的
      // 「在线匹配封面」。
      // 「刷新」按钮已删：下拉刷新（[_pullToRefresh]）仍是手动同步入口，页头不再
      // 为它单占一格。
    ];
    final Widget? navigation = widget.navigation;
    if (navigation != null) {
      return FushiPageHeader.customTitle(
        title: navigation,
        actions: actions,
      );
    }
    return FushiPageHeader(
      title: t.nav_video,
      actions: actions,
    );
  }

  /// 长按 / 桌面右键远端视频卡：弹与本地视频卡一致的封面背景动作面板
  /// （[MediaItemDialogFrame] 复用，不重写）。播放仍由卡片短按 [_openRemote] 负责。
  ///
  /// 动作：
  /// * 「下载」→ 复用 [_downloadRemote]（与封面下载按钮同一入口，内部已去重）。
  /// * 「信息」→ 弹基本元数据（标题 + 是否含字幕）。
  /// * 「删除」→ 仅互联后端（[InterconnectSyncBackend]，有 deleteRemoteVideo）才显示；
  ///   云盘后端（[CloudRemoteVideoClient]）无此能力，按类型门控隐藏，与远端书卡
  ///   [_showRemoteBookDialog] 同一纪律。
  ///
  /// 注：此处曾注明「均无 deleteRemoteVideo 能力，故不提供删除动作」——该能力现已补齐
  /// （host `VideoDeletionHost` + `DELETE /api/library/videos/<id>` + client 方法四层）。
  void _showRemoteVideoDialog(RemoteVideoInfo video) {
    final RemoteVideoClient? client = _remoteVideoClient;
    final bool canDelete = client is InterconnectSyncBackend;
    showAppDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => MediaItemDialogFrame(
        cover: _buildRemoteVideoCover(video),
        title: video.title,
        showLaunchAction: false,
        quickActions: <DialogQuickAction>[
          DialogQuickAction(
            label: t.remote_video_download,
            icon: Icons.download_outlined,
            onPressed: () {
              Navigator.pop(dialogContext);
              _downloadRemote(video);
            },
          ),
          DialogQuickAction(
            label: t.remote_video_info,
            icon: Icons.info_outline,
            onPressed: () {
              Navigator.pop(dialogContext);
              _showRemoteVideoInfo(video);
            },
          ),
        ],
        dangerActions: <DialogDangerAction>[
          if (canDelete)
            DialogDangerAction(
              label: t.dialog_delete,
              onPressed: () {
                Navigator.pop(dialogContext);
                _confirmDeleteRemoteVideo(video, client);
              },
            ),
        ],
      ),
    );
  }

  /// 删除互联对端 host 上的远端视频，删完强制刷新远端列表。
  ///
  /// 删的是 host 库里的条目 + host app 自己拥有的封面/字幕缓存与上传副本；host 用户
  /// **自己导入的原始视频文件不删**（见 `AppModelLibraryHostService.deleteVideo`）。
  ///
  /// 三种结果各有可见反馈——静默失败正是远端书删除的老毛病（只写日志、用户以为删了）：
  /// * 成功 → 列表里消失（强制刷新绕过 [RemoteLibraryCache] TTL）；
  /// * host 版本过旧不支持（404/405）→ 提示升级对端；
  /// * 其它失败（网络 / host 500）→ 提示失败。
  Future<void> _confirmDeleteRemoteVideo(
    RemoteVideoInfo video,
    InterconnectSyncBackend backend,
  ) async {
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(video.title),
        content: Text(t.sync_compare_delete_confirm(name: video.title)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(t.dialog_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(t.dialog_delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    bool supported = true;
    bool failed = false;
    try {
      supported = await backend.deleteRemoteVideo(video.id);
    } catch (e, stack) {
      failed = true;
      ErrorLogService.instance.log('HomeVideoPage.deleteRemoteVideo', e, stack);
    }
    if (!mounted) return;
    if (failed) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.remote_delete_failed)),
      );
    } else if (!supported) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.remote_delete_unsupported)),
      );
    }
    // 删成功才需要重取清单；失败时列表本就没变。forceRefresh 绕过远端库缓存 TTL，
    // 否则刚删掉的视频会在 TTL 内继续显示成幽灵卡片。
    if (!failed && supported) {
      setState(() {
        _remoteFuture = _loadRemoteVideos(forceRefresh: true);
      });
    }
  }

  /// 展示远端视频的基本元数据（标题 + 大小 + 字幕有无）。纯信息弹窗。
  ///
  /// UI 巡检 PR-4：此前只有「含字幕」一条且无字幕时正文整块为空（弹窗只剩标题，
  /// 像坏了）。补文件大小行（host 清单带 sizeBytes 时），字幕改为显式两态。
  void _showRemoteVideoInfo(RemoteVideoInfo video) {
    final int? sizeBytes = video.sizeBytes;
    showAppDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(video.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (sizeBytes != null && sizeBytes > 0)
              Text(
                t.remote_video_info_size(
                  size: formatRemoteVideoSize(sizeBytes),
                ),
              ),
            Text(
              video.hasSubtitle
                  ? t.remote_video_info_has_subtitle
                  : t.remote_video_info_no_subtitle,
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(t.dialog_close),
          ),
        ],
      ),
    );
  }

  /// 标签筛选栏：与书架完全一致——复用 [FushiTagFilterBar]（内联 chip 点选筛选、
  /// 长按拖拽重排、末尾「管理标签」齿轮 + 「批量选择」动作）。共享
  /// [selectedTagIdsProvider] 与书架联动；批量选择动作经 [onToggleSelectionMode]
  /// 与书架对齐（TODO-063：此前视频 tab 没传，缺了「标签设置旁的选择」）。
  ///
  /// 渲染条件：与书架 [reader_hibiki_history_page._buildTagBar] 一致——**永远渲染
  /// 整栏**（不再「无标签隐藏」），批量选择按钮才能常驻露出（否则空标签库点不到
  /// 批量入口、无法批量删除）。组件内部「管理标签」齿轮仍只在有标签时显示，故无
  /// 标签时整栏只剩「批量选择」按钮。
  /// P5-A 视频库搜索框。形态与书架/游戏库页一致（三个库页搜索长一个样），
  /// 搜索词只影响本次会话、不落库。
  Widget _buildVideoSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: SizedBox(
              height: 40,
              child: TextField(
                key: const ValueKey<String>('video_search_field'),
                controller: _searchController,
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  hintText: t.library_search,
                  border: const OutlineInputBorder(),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  suffixIcon: _searchQuery.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _searchQuery = '');
                          },
                        ),
                ),
                onChanged: (String value) =>
                    setState(() => _searchQuery = value),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _buildYearFilterButton(),
          const SizedBox(width: 8),
          _buildWatchStatusFilterButton(),
        ],
      ),
    );
  }

  /// TODO-2486：年份下拉筛选。年份列表由条目刮削 airDate 派生（去重倒序）；
  /// 含「未知」桶——无刮削资料的条目在年份筛选下归未知、不消失。
  Widget _buildYearFilterButton() {
    final List<int> years = _airYearByUid.values.toSet().toList()
      ..sort((int a, int b) => b.compareTo(a));
    final String label = _yearFilter.isAll
        ? t.video_filter_year
        : (_yearFilter.unknownOnly
            ? t.video_filter_year_unknown
            : '${_yearFilter.year}');
    return PopupMenuButton<VideoYearFilter>(
      key: const ValueKey<String>('home_video_filter_year'),
      tooltip: t.video_filter_year,
      initialValue: _yearFilter,
      onSelected: (VideoYearFilter value) =>
          setState(() => _yearFilter = value),
      itemBuilder: (BuildContext context) => <PopupMenuEntry<VideoYearFilter>>[
        PopupMenuItem<VideoYearFilter>(
          value: const VideoYearFilter.all(),
          child: Text(t.home_filter_all),
        ),
        for (final int year in years)
          PopupMenuItem<VideoYearFilter>(
            value: VideoYearFilter.year(year),
            child: Text('$year'),
          ),
        PopupMenuItem<VideoYearFilter>(
          value: const VideoYearFilter.unknown(),
          child: Text(t.video_filter_year_unknown),
        ),
      ],
      child: _filterDropdownChip(label: label, active: !_yearFilter.isAll),
    );
  }

  /// TODO-2486：看完状态下拉筛选（全部 / 未看 / 在看 / 已看完）。
  Widget _buildWatchStatusFilterButton() {
    final String label = _watchStatusFilter == VideoWatchStatusFilter.all
        ? t.video_filter_watch_status
        : _watchStatusFilterLabel(_watchStatusFilter);
    return PopupMenuButton<VideoWatchStatusFilter>(
      key: const ValueKey<String>('home_video_filter_watch_status'),
      tooltip: t.video_filter_watch_status,
      initialValue: _watchStatusFilter,
      onSelected: (VideoWatchStatusFilter value) =>
          setState(() => _watchStatusFilter = value),
      itemBuilder: (BuildContext context) =>
          <PopupMenuEntry<VideoWatchStatusFilter>>[
        for (final VideoWatchStatusFilter filter
            in VideoWatchStatusFilter.values)
          PopupMenuItem<VideoWatchStatusFilter>(
            value: filter,
            child: Text(filter == VideoWatchStatusFilter.all
                ? t.home_filter_all
                : _watchStatusFilterLabel(filter)),
          ),
      ],
      child: _filterDropdownChip(
        label: label,
        active: _watchStatusFilter != VideoWatchStatusFilter.all,
      ),
    );
  }

  String _watchStatusFilterLabel(VideoWatchStatusFilter filter) =>
      switch (filter) {
        VideoWatchStatusFilter.all => t.video_filter_watch_status,
        VideoWatchStatusFilter.unwatched =>
          t.video_filter_watch_status_unwatched,
        VideoWatchStatusFilter.watching => t.video_filter_watch_status_watching,
        VideoWatchStatusFilter.completed =>
          t.video_filter_watch_status_completed,
      };

  /// 下拉筛选 chip 视觉（激活态描主色），与搜索框同高。
  Widget _filterDropdownChip({required String label, required bool active}) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color foreground = active ? colors.primary : colors.onSurfaceVariant;
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border.all(color: active ? colors.primary : colors.outline),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            label,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: foreground),
          ),
          Icon(Icons.arrow_drop_down, size: 18, color: foreground),
        ],
      ),
    );
  }

  Widget _buildTagFilterBar(List<BookTagRow> tags) {
    return FushiTagFilterBar(
      tags: tags,
      onToggleFilter: _toggleFilter,
      onReorder: _reorderTags,
      selectionMode: _selectionMode,
      onToggleSelectionMode: _toggleSelectionMode,
      // 排序交互重设计层次 A：「排序方式」菜单（原「整理」按钮位置；整理页已删）。
      // 分组管理走批量「组合成合集」+ 合集详情页（改名/删除/移出成员/拖拽排集）。
      sortMode: _sortMode,
      sortModeLabel: _sortModeLabel,
      onSortModeChanged: _setSortMode,
      onTagsChanged: () => ref.invalidate(videoBookTagMapProvider),
    );
  }

  String _sortModeLabel(ShelfSortMode mode) => switch (mode) {
        ShelfSortMode.recent => t.sort_recent_watched,
        ShelfSortMode.title => t.sort_title,
        ShelfSortMode.imported => t.sort_imported,
      };

  void _toggleFilter(int tagId) {
    final Set<int> next = Set<int>.from(ref.read(selectedTagIdsProvider));
    if (next.contains(tagId)) {
      next.remove(tagId);
    } else {
      next.add(tagId);
    }
    ref.read(selectedTagIdsProvider.notifier).state = next;
  }

  Future<void> _reorderTags(int oldIndex, int newIndex) async {
    final List<BookTagRow>? tags = ref.read(allTagsProvider).valueOrNull;
    if (tags == null) return;
    final List<BookTagRow> reordered = List<BookTagRow>.from(tags);
    final BookTagRow item = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, item);
    final List<int> orderedIds = reordered.map((BookTagRow t) => t.id).toList();
    await ref.read(appProvider).database.reorderTags(orderedIds);
    ref.invalidate(allTagsProvider);
  }

  /// 空库占位（UI 巡检 PR-4）：收敛到共享 [FushiPlaceholderMessage] 骨架并补
  /// 「导入视频」CTA——此前只有图标 + 一句话，新用户没有下一步动作入口。
  Widget _buildEmpty() {
    return FushiPlaceholderMessage(
      icon: Icons.movie_outlined,
      message: t.video_library_empty,
      action: FilledButton.tonalIcon(
        key: const ValueKey<String>('home_video_empty_import'),
        onPressed: () => unawaited(_openImport()),
        icon: const Icon(Icons.add),
        label: Text(t.video_import_action),
      ),
    );
  }

  Widget _buildFilteredEmpty() {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.filter_list_off, size: 56, color: colors.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            t.tag_no_books_for_filter,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// 封面下方文字块的实际高度：两行标题 + 一行观看进度 + 上下内边距，随文字缩放走。
  ///
  /// BUG-1184：此前是死常量 [_kVideoCardTextBlock]（52），配合标题 `maxLines: 1`。
  /// 视频名（尤其日文剧名带季数/话数）单行 ellipsis 在窄屏卡上只剩几个字——卡宽在
  /// 360dp 手机上只有约 154px。放宽到两行就必须同步抬高文字块，否则两行标题会顶掉
  /// 进度行并溢出。这里按真实行高算，而不是再猜一个常量：大字号下文字块自动变高，
  /// 不会像固定值那样在 textScale≥1.2 时把进度行切掉一半。
  ///
  /// 与 BUG-943（旧值 83 → 52，消除卡底常驻空白）不冲突：那次收敛掉的是「为两行
  /// 标题预留、但绝大多数卡用不到」的最坏情况余量，代价是长标题永远显示不全。现在
  /// 高度按需算出（默认字号实测约 74，仍小于当年的 83），长标题真的用得上第二行。
  static double _videoCardTextBlock(BuildContext context) {
    final double titleLine = textLineHeight(
      context,
      Theme.of(context).textTheme.bodyMedium ?? const TextStyle(fontSize: 14),
    );
    final double metaLine =
        textLineHeight(context, FushiDesignTokens.of(context).type.metadata);
    // 标题 padding 6(top)+2(bottom)，进度行 padding 0(top)+6(bottom)。
    return titleLine * 2 + 8 + metaLine + 6 + kTextBlockSlack;
  }

  /// 媒体库墙 sliver（TODO-2486，随主 [CustomScrollView] 滚动）：**行高固定**
  /// （封面高 + 文字块）、竖横混排流式换行（Wrap）。卡宽随封面朝向（竖 2:3 /
  /// 横 16:9，[CoverOrientationBuilder] 探测），封面底边天然对齐；合集卡在前、
  /// 散卡在后的分区序不变（[cells] 已按此序拼好）。竖卡宽 = unifiedShelfCardLayout
  /// 目标卡宽，与旧网格同宽感受；朝向未知（无封面/解码前）默认竖卡。
  Widget _buildVideoWallSliver(
    List<_VideoWallEntry> cells,
    EdgeInsetsGeometry padding,
    ({int columns, double cardWidth}) cardLayout,
  ) {
    final double coverHeight =
        videoCoverHeightForPortraitWidth(cardLayout.cardWidth);
    final double cellHeight = coverHeight + _videoCardTextBlock(context);
    return SliverPadding(
      padding: padding,
      sliver: SliverToBoxAdapter(
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: <Widget>[
            for (final _VideoWallEntry cell in cells)
              CoverOrientationBuilder(
                image: cell.cover,
                builder:
                    (BuildContext context, VideoCardOrientation orientation) =>
                        SizedBox(
                  width: videoCardWidthForOrientation(
                    orientation: orientation,
                    coverHeight: coverHeight,
                  ),
                  height: cellHeight,
                  child: cell.build(orientation),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 合集封面卡长按/右键菜单（统一三库页合集菜单）：打开/重命名/标签/删除，动作
  /// 语义与合集详情页 AppBar 同源；删除支持「连同视频一起删」勾选（与详情页
  /// `onDeleteMembersMedia` 同一删除纪律）。
  Future<void> _showCollectionContextMenu(MediaCollectionRow collection) {
    final VideoBookRepository repo = widget.repo;
    final FushiDatabase db = ref.read(appProvider).database;
    return showCollectionContextDialog(
      context: context,
      db: db,
      collection: collection,
      onOpenDetail: () => _openCollectionDetail(collection),
      onChanged: () {
        ref.invalidate(collectionTagMapProvider);
        ref.invalidate(filteredCollectionIdsProvider);
        _refresh();
      },
      onDeleteMembersMedia: (List<MediaCollectionItemRow> members) async {
        bool anyVideo = false;
        for (final MediaCollectionItemRow m in members) {
          // 视频合集理论上只含 video 成员；混入的未知/跨域成员跳过不误删。
          if (MediaKind.tryParse(m.mediaType) != MediaKind.video) continue;
          await repo.deleteVideoBookAndReclaimAssets(
            m.entryKey,
            compactDatabase: false,
          );
          anyVideo = true;
        }
        if (anyVideo) {
          await repo.compactAfterVideoDeleteBestEffort();
        }
      },
      deleteMembersCheckboxLabel: t.delete_collection_also_videos,
      // 视频合集特有项（与合集详情页 AppBar 能力对齐）：整合集刮削封面 / 批量
      // 拉字幕。对话框负责先关自身，这里不 pop。
      extraListActions: <DialogListAction>[
        DialogListAction(
          label: t.video_scrape_online_match,
          icon: Icons.image_search,
          onPressed: () => _openCollectionCoverMatch(collection),
        ),
        DialogListAction(
          label: t.video_jimaku_batch_title,
          icon: Icons.subtitles_outlined,
          onPressed: () => _openCollectionSubtitles(collection),
        ),
      ],
    );
  }

  /// 合集右键「在线匹配封面」：换的是**合集自己的封面**（`MediaCollections.coverPath`，
  /// schema v61），一个成员都不动（BUG-1211）。
  ///
  /// 旧行为是把选中的封面 + Bangumi 条目资料一次性刷进合集全部成员，用户明确否决：
  /// 「匹配的是合集的封面，谁说应用到本机里面的视频了」。现在弹窗从合集入口打开时
  /// 不再出「同时应用到本合集全部 N 集」勾选，「使用」只下载一张图落进
  /// `<video_covers>/collections/<id>.jpg` 并写合集那一列。
  ///
  /// 本地成员仍要找一个当**搜索种子**（用它的文件路径解析番名预填搜索框）；找不到
  /// 就没有可预填的片名，给可见提示而不是静默返回——菜单已自行关闭，静默 return 在
  /// 用户看来就是「点了没反应」（同 BUG-1081 的判据）。
  ///
  /// 不做菜单项置灰：能不能刮取决于「有没有**解析得出**的本地成员」，那要
  /// `getCollectionItems` + 逐 uid 查 repo 才知道，为每次右键都付这份 IO 不划算；
  /// 用扩展名式的近似预判去置灰则会撒谎（灰的其实能用 / 亮的其实不能用）。
  Future<void> _openCollectionCoverMatch(MediaCollectionRow collection) async {
    final FushiDatabase db = ref.read(appProvider).database;
    final List<MediaCollectionItemRow> items =
        await db.getCollectionItems(collection.id);
    final List<String> uids = <String>[
      for (final MediaCollectionItemRow m in items)
        if (m.mediaType == MediaKind.video.dbValue) m.entryKey,
    ];
    VideoBookRow? seed;
    for (final String uid in uids) {
      seed = await widget.repo.getByBookUid(uid);
      if (seed != null) break;
    }
    if (!mounted) return;
    if (seed == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.video_collection_no_local_member)),
      );
      return;
    }
    final ({
      CoverScraperService service,
      CoverScraperService Function(OfflineIndex offline) rebuild,
      Directory scraperDir,
    }) bundle = await _scraperBundle();
    if (!mounted) return;
    await showCoverMatchDialog(
      context: context,
      service: bundle.service,
      book: seed,
      // 合集入口下弹窗不读成员表（不出「应用到全部」勾选）；只传种子自身，让
      // 「误传整表 → 又被当成批量目标」这条路在类型/数据两层都不存在。
      collectionMemberUids: <String>[seed.bookUid],
      onApplied: _refresh,
      collection: CoverMatchCollectionTarget(
        id: collection.id,
        name: collection.name,
        applyScrape: (
          CollectionScrapeResult result, {
          required String? confirmedTitle,
        }) async {
          await applyCollectionScrape(
            db,
            collection.id,
            result,
            confirmedTitle: confirmedTitle,
          );
          // TODO-2484：同一次刮削顺带拉「相关作品」。fire-and-forget——弹窗
          // 主流程（封面+资料）已落库成功，关系区块是增量数据，拉取失败只记
          // 日志、下次重刮补齐，不把弹窗关闭卡在第二轮网络请求上。
          unawaited(_scrapeCollectionRelations(db, collection.id));
        },
      ),
    );
  }

  /// 合集刮削后的「相关作品」拉取（TODO-2484）。独立函数：applyScrape 闭包只管
  /// 触发；失败（含逐源错误）统一进 ErrorLogService，不上 UI。
  Future<void> _scrapeCollectionRelations(
    FushiDatabase db,
    int collectionId,
  ) async {
    // 用户自填 key 优先，其次内置 key（resolveTmdbApiKey）——与封面刮削同一
    // 取值规则；读裸偏好会让只靠内置 key 的用户 TMDB 关系路静默失效。
    final String tmdbKey = resolveTmdbApiKey(ref
        .read(appProvider)
        .prefsRepo
        .getPref(kVideoScraperTmdbApiKeyPref, defaultValue: '') as String);
    final BangumiClient bangumi = BangumiClient();
    final TmdbClient? tmdb =
        tmdbKey.isEmpty ? null : TmdbClient(apiKey: tmdbKey);
    try {
      final CollectionRelationsScrapeReport report =
          await scrapeCollectionRelations(
        db: db,
        collectionId: collectionId,
        bangumi: bangumi,
        tmdb: tmdb,
      );
      for (final MapEntry<String, String> entry
          in report.sourceErrors.entries) {
        ErrorLogService.instance.log(
          'CollectionRelations.${entry.key}',
          entry.value,
        );
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('CollectionRelations', e, stack);
    } finally {
      bangumi.close();
      tmdb?.close();
    }
  }

  /// 合集右键「为合集获取字幕」：与合集详情页 AppBar 同一 [JimakuBatchDialog]
  /// （绑定 AniList 系列 → 逐集拉最佳字幕）。collection 行重取一次拿最新
  /// anilistId 快照作对话框初值；无本地视频成员时无从拉取，给可见提示而不是静默返回
  /// （理由同 [_openCollectionCoverMatch]）。
  Future<void> _openCollectionSubtitles(MediaCollectionRow collection) async {
    final FushiDatabase db = ref.read(appProvider).database;
    final List<MediaCollectionItemRow> items =
        await db.getCollectionItems(collection.id);
    final List<VideoBookRow> members = <VideoBookRow>[];
    for (final MediaCollectionItemRow m in items) {
      if (m.mediaType != MediaKind.video.dbValue) continue;
      final VideoBookRow? row = await widget.repo.getByBookUid(m.entryKey);
      if (row != null) members.add(row);
    }
    final MediaCollectionRow fresh =
        await db.getMediaCollectionById(collection.id) ?? collection;
    if (!mounted) return;
    if (members.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.video_collection_no_local_member)),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) => JimakuBatchDialog(
        database: db,
        collection: fresh,
        members: members,
      ),
    );
  }

  /// 打开合集详情页（Jellyfin 式）。有序成员从 [FushiDatabase.getCollectionItems] 解析，
  /// 点某集经 playlistCollectionId 进播放器带剧集面板/上下集/连播；写库后重载库页。
  void _openCollectionDetail(MediaCollectionRow collection) {
    final VideoBookRepository repo = widget.repo;
    final FushiDatabase db = ref.read(appProvider).database;
    Navigator.push<void>(
      context,
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => MediaCollectionDetailPage(
          database: db,
          collection: collection,
          loadMembers: () async {
            final List<MediaCollectionItemRow> members =
                await repo.getCollectionItems(collection.id);
            final List<VideoBookRow> rows = <VideoBookRow>[];
            for (final MediaCollectionItemRow m in members) {
              if (m.mediaType != MediaKind.video.dbValue) continue;
              final VideoBookRow? r = await repo.getByBookUid(m.entryKey);
              if (r != null) rows.add(r);
            }
            return rows;
          },
          onOpenEpisode: (VideoBookRow ep) =>
              _open(ep, playlistCollectionId: collection.id),
          onChanged: _refresh,
          // 「连同视频一起删」：逐集删视频 DB 行 + app 拥有副本（封面/字幕），保留用户
          // 原始视频文件；逐集不 VACUUM，循环后一次性 compact（避免逐集 VACUUM）。
          // 复用批量删除同一纪律（_batchDeleteConfirm）。
          onDeleteMembersMedia: (List<VideoBookRow> members) async {
            for (final VideoBookRow ep in members) {
              await repo.deleteVideoBookAndReclaimAssets(
                ep.bookUid,
                compactDatabase: false,
              );
            }
            if (members.isNotEmpty) {
              await repo.compactAfterVideoDeleteBestEffort();
            }
          },
        ),
      ),
    );
  }

  /// 单视频卡。[playlistCollectionId] 非空 = 卡在合集横排行里（UI v2 Phase C），
  /// 点击直接从该集进播放器并带剧集面板/上下集/连播。
  ///
  /// [selectable]（默认 true）= 该卡在多选态可单独勾选。块2：合集横排行里的成员卡
  /// 传 false——多选态不画勾选框、不可单独勾（整合集由行头勾选框选中），点击照常开播。
  Widget _buildCard(
    VideoBookRow book, {
    int? playlistCollectionId,
    bool selectable = true,
    VideoCardOrientation orientation = VideoCardOrientation.portrait,
  }) {
    final List<BookTagRow> tags =
        ref.watch(videoBookTagMapProvider).valueOrNull?[book.bookUid] ??
            const <BookTagRow>[];
    final int episodeCount = playlistEpisodeCount(book.playlistJson);
    // TODO-1346：视频观看进度分数（null=无可展示进度 → 不画进度条）。
    final double? watchFrac = videoWatchFraction(
      completed: book.completedAt != null,
      currentEpisode: book.currentEpisode,
      episodeCount: episodeCount,
    );
    // 块2：只有可单独勾选的卡才在多选态显示勾选框/高亮/切换选中。
    final bool showSelection = _selectionMode && selectable;
    final bool selected = showSelection && _selectedUids.contains(book.bookUid);
    final SelectionSlot slot = SelectionSlot.loose(book.bookUid);
    void handleTap() {
      if (showSelection) {
        _toggleSelection(book.bookUid);
        return;
      }
      // 桌面 Ctrl/⌘（macOS）/ Shift + 点击 = 不经工具栏直接进多选并选中该卡。
      if (selectable &&
          !_selectionMode &&
          selectionEntryModifierPressed(context)) {
        _enterSelectionWith(slot);
        return;
      }
      _open(book, playlistCollectionId: playlistCollectionId);
    }

    final FushiCard hibikiCard = FushiCard(
      key: ValueKey<String>('home_video_${book.bookUid}'),
      focusId: FushiFocusId('home-video-${book.bookUid}'),
      padding: EdgeInsets.zero,
      selected: selected,
      // 选择态：点击切换勾选、长按交给祖先的扫选接管区（与书架 _bookCardShell 一致）。
      // 成员卡（selectable=false）多选态照常开播、不切换选中。
      onTap: handleTap,
      // 长按 / 桌面右键都弹管理菜单，与书架书卡（_bookCardShell）、远端视频卡
      // （_buildRemoteVideoCard）一致——本地视频卡此前只挂了 onLongPress、漏了
      // onSecondaryTap，故桌面右键本地视频卡无反应（BUG-758）。
      // 未进入选择态时，触屏与桌面长按都保留管理菜单；显式进入选择态后才摘掉
      // 卡片长按识别器，让祖先 SelectionDragArea 接管扫选。
      onLongPress: _selectionMode ? null : () => _showVideoMenu(book),
      onSecondaryTap: _selectionMode ? null : () => _showVideoMenu(book),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // BUG-926：封面此前用 Expanded 吃掉「cell 高 − 下方文字块实际高度」的剩余，
          // 而文字块高度随标题行数 / 有无观看进度浮动（≤_kVideoCardTextBlock），文字
          // 不足时多出的空间灌进封面区，contain 封面上下留空隙（标题短或无进度时才
          // 现，故「时有时无」）。改为固定 AspectRatio：封面比例恒定，与标题长短彻底
          // 解耦。TODO-2486 朝向自适应：竖版 2:3 海报 / 横版 16:9（朝向由墙格
          // CoverOrientationBuilder 探测注入），不合槽封面由 [PortraitCoverImage]
          // 模糊垫底填充，无黑边/变形。
          AspectRatio(
            aspectRatio:
                orientation == VideoCardOrientation.landscape ? 16 / 9 : 2 / 3,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                _buildCover(
                  book,
                  poster: true,
                  landscapeSlot: orientation == VideoCardOrientation.landscape,
                ),
                // UI 巡检 PR-4：多选态勾选框占左上角（同为 top:6,left:6），标签层
                // 让位隐藏——此前两层同角重叠，勾选框压在标签 chip 上两者都花。
                if (tags.isNotEmpty && !showSelection)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: _buildTagLabels(tags),
                  ),
                // 播放列表角标（≥2 集才算播放列表）：右上角「▶ N」徽标，与单视频
                // 一眼区分（C 需求②）。
                if (episodeCount >= 2)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: _buildPlaylistBadge(episodeCount),
                  ),
                if (showSelection)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: ShelfSelectionCheck(selected: selected),
                  ),
                if (selected)
                  const Positioned.fill(child: ShelfSelectedOverlay()),
                // TODO-1346：观看进度条（贴封面底部，YouTube 式）。多集按「看到第几集」，
                // 单视频仅已看完满格；无可展示进度（watchFrac==null）时不画。
                if (watchFrac != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: IgnorePointer(
                      child: LinearProgressIndicator(
                        value: watchFrac,
                        minHeight: 3,
                        backgroundColor: Colors.black.withValues(alpha: 0.35),
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // 文字块占封面下方剩余固定高度（cell 高 − 2:3 封面 = _kVideoCardTextBlock）。
          // 标题单行 ellipsis 内收；进度行用 Flexible 让位，浮动高度不反灌进封面区
          // （BUG-926 血缘）、大字号倍率下也不溢出。无进度时仅剩常规内边距、无显眼空块
          // （BUG-943：单行标题无进度卡曾常驻约 50px 空白）。
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
                  // TODO-2490：两行仍放不下时，桌面悬停显示完整标题；触屏长按
                  // 菜单（MediaItemDialogFrame 标题不限行）看全名。
                  child: ShelfTitleOverflowTooltip(
                    title: book.title,
                    style: Theme.of(context).textTheme.bodyMedium,
                    maxLines: 2,
                    child: Text(
                      book.title,
                      // BUG-1184：窄屏卡宽只有约 154px，单行放不下一个日文剧名。
                      // 文字块高度已按两行标题算出（[_videoCardTextBlock]）。
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ),
                // UI v2 Phase D：观看进度文字外显（mockup 卡片下的进度/上次观看行）。
                // 只显示可靠数据：已看完 / 已看至 mm:ss（无总时长列，不显示百分比）+
                // 上次观看日期（watch-stats 有该 title 时）；全无痕迹不渲染本行。
                if (_buildCardWatchMeta(book) case final String meta
                    when meta.isNotEmpty)
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                      child: Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: FushiDesignTokens.of(context).type.metadata,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    // 选择态下禁用标签拖放命中（避免选卡时误触拖标签）。
    final Widget card = _selectionMode
        ? hibikiCard
        : BookDragTarget(
            bookId: book.bookUid,
            onTagDropped: (BookTagRow tag) =>
                _addTagToVideoBook(book.bookUid, tag),
            child: hibikiCard,
          );
    return CardDropZone<VideoBookRow>(
      meta: book,
      // 拖卡进合集：拖拽源包在标签 drop target 外（这张卡既能被拖走、也能接住
      // 落下的标签，泛型不同互不干扰）；多选态不建拖拽源。
      child: MediaCardDraggable(
        mediaRef: MediaRef(kind: MediaKind.video, entryKey: book.bookUid),
        label: book.title,
        enabled: !_selectionMode,
        // 长按扫选靠命中测试反查「手指下面是哪一格」。仅可单独勾选的散卡贴标记：
        // 合集成员卡（selectable=false）不可单独勾，扫过去应当无事发生。
        child: selectable
            ? SelectionSlotTarget(
                slot: SelectionSlot.loose(book.bookUid),
                child: card,
              )
            : card,
      ),
    );
  }

  /// 视频卡观看进度文字行：`已看完` / `已看至 m:ss`（+ `上次观看 M-dd`）。
  /// 无任何观看痕迹返回空串（调用方不渲染该行）。
  String _buildCardWatchMeta(VideoBookRow book) {
    final DateTime? watched =
        _watchAtByUid[book.bookUid] ?? _legacyWatchAtByTitle[book.title];
    final List<String> parts = <String>[
      if (book.completedAt != null)
        t.video_stat_completed
      else if (book.lastPositionMs > 0)
        t.video_watched_up_to(time: formatVideoPosition(book.lastPositionMs)),
      if (watched != null)
        t.video_last_watched(date: _formatOverviewDate(watched)),
    ];
    return parts.join(' · ');
  }

  /// 批量操作栏（底部，仅选择态显示）：选中计数 + 全选 / 反选 + 打标签 + 删除。
  /// 与书架 [reader_hibiki_history_page._buildBatchActionBar] 对齐。
  Widget _buildBatchActionBar() {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 块2/3/4：计数与按钮可用态涵盖散卡选中集 + 合集选中集。
    final int selectedCount =
        _selectedUids.length + _selectedCollectionIds.length;
    final bool hasSelection =
        _selectedUids.isNotEmpty || _selectedCollectionIds.isNotEmpty;
    // 复查 #5：组合按钮 noop 档（0 合集 0 散卡 / 仅 1 合集且无散卡）不再当启用态死按钮，
    // 只在真能组合（新建 / 并入 / 合并）时才可点，与 [_batchCombineIntoSeries] 同判据。
    final bool canCombine = classifyCombine(
          collectionCount: _selectedCollectionIds.length,
          looseCount: _selectedUids.length,
        ) !=
        CombineTier.noop;
    return Material(
      elevation: 6,
      color: theme.colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: tokens.spacing.card - tokens.spacing.gap / 2,
            vertical: tokens.spacing.gap,
          ),
          child: Row(
            children: <Widget>[
              Text(
                t.batch_selected_count(n: selectedCount),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(width: tokens.spacing.gap),
              TextButton(
                onPressed: _selectAllVisible,
                child: Text(t.batch_select_all),
              ),
              TextButton(
                onPressed: _invertSelection,
                child: Text(t.batch_invert_selection),
              ),
              const Spacer(),
              FushiIconButton(
                key: const ValueKey<String>('home_video_batch_combine'),
                enabled: canCombine,
                onTap: _batchCombineIntoSeries,
                // 组合成系列用 playlist_add，与页头「收藏夹」入口的
                // collections_bookmark_outlined 区分开（二者语义无关，避免同图标歧义）。
                icon: Icons.playlist_add,
                tooltip: t.combine_into_series,
              ),
              SizedBox(width: tokens.spacing.gap / 2),
              FushiIconButton(
                // 打标签只作用于散卡媒体（合集无直接标签），故按散卡选中集可用态。
                enabled: _selectedUids.isNotEmpty,
                onTap: _batchShowTagPicker,
                icon: Icons.sell_outlined,
                tooltip: t.tag_label,
              ),
              SizedBox(width: tokens.spacing.gap / 2),
              FushiIconButton(
                key: const ValueKey<String>('home_video_batch_delete'),
                enabled: hasSelection,
                onTap: _batchDeleteConfirm,
                icon: Icons.delete_outline,
                tooltip: t.dialog_delete,
                enabledColor: theme.colorScheme.error,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 播放列表角标：半透明胶囊「▶ N集」，与单视频卡一眼区分（C 需求②）。
  /// UI 巡检 PR-4：收敛到共享 [CoverBadge]（PR-0 组件，黑@0.6 圆角10 白图标）。
  Widget _buildPlaylistBadge(int episodeCount) {
    return CoverBadge(
      icon: Icons.playlist_play,
      label: t.video_playlist_episodes(count: episodeCount),
    );
  }

  /// 卡片标签层：最多显示前 3 个 chip，超出折叠成「+N」（与书架卡风格一致）。
  Widget _buildTagLabels(List<BookTagRow> tags) {
    const int maxVisible = 3;
    final List<BookTagRow> visible = tags.take(maxVisible).toList();
    final int overflow = tags.length - visible.length;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final BookTagRow tag in visible)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: FushiTagChip(label: tag.name, color: Color(tag.colorValue)),
          ),
        if (overflow > 0) FushiTagChip(label: '+$overflow'),
      ],
    );
  }

  /// [poster] = true：主网格 / 继续观看 hero 的 2:3 竖版槽位（BUG-1299 起 hero
  /// 也走此路径），走 [PortraitCoverImage]（横版截帧模糊垫底 + contain 前景）；
  /// false：长按菜单等 16:9 语境保持原渲染。
  Widget _buildCover(
    VideoBookRow book, {
    bool poster = false,
    bool landscapeSlot = false,
  }) {
    final String? cover = book.coverPath;
    // 保留同步 existsSync 短路：对已知不存在的封面直接占位，避免对缺失文件发起
    // 无谓的异步解码（真机少一次失败 IO；widget 测试里也不会因缺失文件挂在解码上）。
    // 单卡一次 stat 成本极小；首屏真正的开销是解码尺寸（下方 cacheWidth 降采样）
    // 与 _repairMovedCoverPaths 的全库 stat（已改异步）。
    if (cover == null || cover.isEmpty || !File(cover).existsSync()) {
      return ShelfCoverPlaceholder(
        icon: Icons.movie_outlined,
        backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
      );
    }
    if (poster) {
      // 解码上限与下方 cacheWidth 同源（resizedFileImage 默认 720，BUG-959）。
      return PortraitCoverImage(
        image: resizedFileImage(File(cover)),
        landscapeSlot: landscapeSlot,
        errorBuilder: (BuildContext _) => ShelfCoverPlaceholder(
          icon: Icons.movie_outlined,
          backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
        ),
      );
    }
    // TODO-616 phase C / BUG-926 后注释更新（UI 巡检 PR-4）：非 poster 槽位保留
    // contain 为非 16:9 源完整显示，空带走 [_coverBacking] 的 surfaceContainer 衬底。
    return _coverBacking(
      Image.file(
        File(cover),
        fit: BoxFit.contain,
        // BUG-959: 按物理像素上限解码，避免视频原生分辨率(1080p/4K)整帧撑爆 ImageCache。
        cacheWidth: kLocalCoverDecodePixelWidth,
        errorBuilder: (_, __, ___) => ShelfCoverPlaceholder(
          icon: Icons.movie_outlined,
          backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
        ),
      ),
    );
  }
}

/// 远端视频信息弹窗的文件大小格式化（UI 巡检 PR-4）：1024 进制 B/KB/MB/GB，
/// 保留 1 位小数（B 档不带小数）。委托 [FushiByteFormat]（G4 收敛），纯函数，
/// 测试同源。
String formatRemoteVideoSize(int bytes) => FushiByteFormat.bytes(bytes);

/// 视频批量打标签的三态意图：保持不变 / 添加该标签 / 移除该标签。
enum _VideoBatchTagIntent { keep, add, remove }

/// 视频 tab 批量打标签对话框（TODO-063）。对一组选中视频书（扁平 bookUid）逐标签
/// 设三态意图，应用时对每个 bookUid 调 [FushiDatabase.addTagToVideoBook] /
/// [FushiDatabase.removeTagFromVideoBook]。与书架的 `_BatchTagPickerDialog` 同语义，
/// 但视频是单一 uid 集合（无 epub `mediaIdentifier` + `srt_` 双类分支），故独立、更简单。
class _VideoBatchTagPickerDialog extends StatefulWidget {
  const _VideoBatchTagPickerDialog({
    required this.allTags,
    required this.selectedUids,
    required this.database,
  });

  final List<BookTagRow> allTags;
  final Set<String> selectedUids;
  final FushiDatabase database;

  @override
  State<_VideoBatchTagPickerDialog> createState() =>
      _VideoBatchTagPickerDialogState();
}

class _VideoBatchTagPickerDialogState
    extends State<_VideoBatchTagPickerDialog> {
  final Set<int> _addTagIds = <int>{};
  final Set<int> _removeTagIds = <int>{};

  Future<void> _apply() async {
    final FushiDatabase db = widget.database;

    for (final int tagId in _addTagIds) {
      for (final String bookUid in widget.selectedUids) {
        await db.addTagToVideoBook(bookUid, tagId);
      }
    }
    for (final int tagId in _removeTagIds) {
      for (final String bookUid in widget.selectedUids) {
        await db.removeTagFromVideoBook(bookUid, tagId);
      }
    }

    if (!mounted) return;
    for (final int tagId in _addTagIds) {
      final BookTagRow tag =
          widget.allTags.firstWhere((BookTagRow row) => row.id == tagId);
      FushiToast.show(
        msg: t.batch_tag_added_video(
          name: tag.name,
          n: widget.selectedUids.length,
        ),
        severity: ToastSeverity.success,
      );
    }
    for (final int tagId in _removeTagIds) {
      final BookTagRow tag =
          widget.allTags.firstWhere((BookTagRow row) => row.id == tagId);
      FushiToast.show(
        msg: t.batch_tag_removed_video(
          name: tag.name,
          n: widget.selectedUids.length,
        ),
        severity: ToastSeverity.success,
      );
    }
    Navigator.pop(context);
  }

  void _setTagIntent(BookTagRow tag, _VideoBatchTagIntent intent) {
    setState(() {
      _addTagIds.remove(tag.id);
      _removeTagIds.remove(tag.id);
      switch (intent) {
        case _VideoBatchTagIntent.keep:
          break;
        case _VideoBatchTagIntent.add:
          _addTagIds.add(tag.id);
        case _VideoBatchTagIntent.remove:
          _removeTagIds.add(tag.id);
      }
    });
  }

  _VideoBatchTagIntent _tagIntent(BookTagRow tag) {
    if (_addTagIds.contains(tag.id)) return _VideoBatchTagIntent.add;
    if (_removeTagIds.contains(tag.id)) return _VideoBatchTagIntent.remove;
    return _VideoBatchTagIntent.keep;
  }

  @override
  Widget build(BuildContext context) {
    // 对话框 chrome（520 宽 / 取消·应用底栏）与书架批量打标签弹窗共用
    // [BatchTagPickerDialogFrame]；此处只注入视频侧的三态标签行与 apply 落库回调。
    return BatchTagPickerDialogFrame(
      canApply: _addTagIds.isNotEmpty || _removeTagIds.isNotEmpty,
      onApply: _apply,
      body: ListView.builder(
        shrinkWrap: true,
        itemCount: widget.allTags.length,
        itemBuilder: (BuildContext _, int i) {
          final BookTagRow tag = widget.allTags[i];
          return _VideoBatchTagIntentRow(
            tag: tag,
            selected: _tagIntent(tag),
            onChanged: (_VideoBatchTagIntent intent) =>
                _setTagIntent(tag, intent),
          );
        },
      ),
    );
  }
}

/// 单行：标签名 + 三态 segmented（保持 / 添加 / 移除）。Material 图标统一（视频
/// tab 无需 Cupertino 分支）。
class _VideoBatchTagIntentRow extends StatelessWidget {
  const _VideoBatchTagIntentRow({
    required this.tag,
    required this.selected,
    required this.onChanged,
  });

  final BookTagRow tag;
  final _VideoBatchTagIntent selected;
  final ValueChanged<_VideoBatchTagIntent> onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color tagColor = Color(tag.colorValue);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);

    return AdaptiveSettingsRow(
      title: tag.name,
      icon: Icons.sell_outlined,
      controlBelow: true,
      trailing: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            DecoratedBox(
              decoration: BoxDecoration(
                color: tagColor,
                shape: BoxShape.circle,
              ),
              child: const SizedBox(width: 12, height: 12),
            ),
            SizedBox(width: tokens.spacing.gap + tokens.spacing.gap / 2),
            Flexible(
              child: adaptiveSegmentedButton<_VideoBatchTagIntent>(
                context: context,
                segments: <ButtonSegment<_VideoBatchTagIntent>>[
                  ButtonSegment<_VideoBatchTagIntent>(
                    value: _VideoBatchTagIntent.keep,
                    tooltip: t.batch_tag_keep,
                    icon: const Icon(Icons.horizontal_rule_outlined, size: 16),
                  ),
                  ButtonSegment<_VideoBatchTagIntent>(
                    value: _VideoBatchTagIntent.add,
                    tooltip: t.batch_tag_add,
                    icon: const Icon(Icons.add, size: 16),
                  ),
                  ButtonSegment<_VideoBatchTagIntent>(
                    value: _VideoBatchTagIntent.remove,
                    tooltip: t.batch_tag_remove,
                    icon: Icon(
                      Icons.remove,
                      size: 16,
                      color: selected == _VideoBatchTagIntent.remove
                          ? theme.colorScheme.error
                          : null,
                    ),
                  ),
                ],
                selected: <_VideoBatchTagIntent>{selected},
                onSelectionChanged: (Set<_VideoBatchTagIntent> values) {
                  if (values.isNotEmpty) onChanged(values.first);
                },
                style: kSettingsSegmentedStyle,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 多端库联合视图（spec §2.1）：视频库散卡区一个待渲染单元 = 排序键 + 墙格。
/// 本地散卡（[_buildCard]）与远端占位卡（[_buildRemoteVideoCard]）用同一列表按当前
/// 排序模式混排（[compareShelfSortKeys]）。构造用惰性闭包，排序后再取需要的那些。
class _VideoLooseCard {
  const _VideoLooseCard({
    required this.sortKey,
    required this.entry,
    required this.selectionKey,
  });

  final ShelfSortKey sortKey;

  /// 墙格（封面 provider + 按朝向构造卡片，TODO-2486）。
  final _VideoWallEntry entry;

  /// 该散卡的多选键（= `bookUid`）。远端占位卡不可多选，为 null——排序后按此
  /// 抽出「可见散卡顺序」喂给 [MediaSelectionController]，故顺序与屏幕一致。
  final String? selectionKey;
}

/// 媒体库墙一格（TODO-2486）：封面 provider（朝向探测用，与卡内封面同键共享
/// 解码）+ 按朝向构造卡片。
class _VideoWallEntry {
  const _VideoWallEntry({required this.cover, required this.build});

  final ImageProvider? cover;
  final Widget Function(VideoCardOrientation orientation) build;
}

/// 横滚行一项（TODO-2486）：最近时刻（排序键）+ 惰性构造。
class _VideoRowItem {
  const _VideoRowItem({required this.recentMs, required this.build});

  final int recentMs;
  final Widget Function() build;
}

/// hero 轮播一页（TODO-2486）：合集 + 组内有序成员 + 刮削资料（可空 = 无
/// backdrop/简介，回落成员封面、对应行隐藏）。
/// hero 轮播单页数据：合集单元（成员 + 合集刮削资料）或散装单视频单元，
/// 二者恰一非空（v68：散装此前进不了 hero，用户最后看的是散装时置顶就不是
/// 「上一个观看的」——现在两类同池按最近观看排序）。
class _VideoHeroItem {
  const _VideoHeroItem.collection({
    required MediaCollectionRow this.collection,
    required this.members,
    this.meta,
  }) : standalone = null;

  const _VideoHeroItem.standalone(VideoBookRow this.standalone)
      : collection = null,
        members = const <VideoBookRow>[],
        meta = null;

  final MediaCollectionRow? collection;
  final List<VideoBookRow> members;
  final CollectionScrapeMetaRow? meta;

  /// 散装单视频（电影/单集条目）。
  final VideoBookRow? standalone;

  /// 轮播页稳定 key（合集 `c<id>` / 散装 `b<uid>`，两个 id 空间不撞）。
  String get pageKey {
    final MediaCollectionRow? c = collection;
    return c != null ? 'c${c.id}' : 'b${standalone!.bookUid}';
  }
}

/// 视频库分组 union 载荷（多端库联合视图 §2.3 任务10）：本地视频行 [local] 或
/// 「远端有本地无」占位 [remote]，二者恰一非空。让 [groupByCollections] 把本地成员与
/// 远端占位成员折进同一合集行（远端占位归属由 host 合集下发 + 本地自然键解析注入）。
class _VideoSlot {
  const _VideoSlot({this.local, this.remote})
      : assert(local != null || remote != null);

  final VideoBookRow? local;
  final RemoteVideoInfo? remote;
}

class _RemoteVideoState {
  const _RemoteVideoState({
    required this.videos,
    this.failed = false,
  });

  final List<RemoteVideoInfo> videos;

  /// 远端目录拉取失败（离线/未配对/后端不可达/host 响应超时）：占位卡不渲染
  /// （spec §2.4）。初次静默加载走离线语义不打扰用户；**显式下拉刷新**失败时
  /// [_pullToRefresh] 据此弹一句本地化友好提示（不再「看不到远端视频还不知为何」）。
  final bool failed;
}
