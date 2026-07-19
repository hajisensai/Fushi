import 'dart:async' show StreamSubscription, unawaited;
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/media/drag_drop/card_drop_registry.dart';
import 'package:hibiki/src/media/drag_drop/drop_classification.dart';
import 'package:hibiki/src/media/drag_drop/drop_decision.dart';
import 'package:hibiki/src/media/drag_drop/hibiki_file_drop_target.dart';
import 'package:hibiki/src/media/video/m3u8_playlist.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_subtitle_attach.dart';
import 'package:hibiki/src/media/video/video_import_dialog.dart';
import 'package:hibiki/src/media/video/video_library_overview.dart';
import 'package:hibiki/src/media/video/video_mpv_config.dart';
import 'package:hibiki/src/media/video/video_shader_downloader.dart';
import 'package:hibiki/src/media/video/video_shader_manager.dart';
import 'package:hibiki/src/media/video/video_shader_tier.dart';
import 'package:hibiki/src/storage/app_paths.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/pages/implementations/anime_download_dialog.dart';
import 'package:hibiki/src/pages/implementations/book_drag_target.dart';
import 'package:hibiki/src/pages/implementations/collections_page.dart';
import 'package:hibiki/src/media/collections/batch_combine.dart';
import 'package:hibiki/src/media/collections/collection_continue.dart';
import 'package:hibiki/src/media/collections/collection_grouping.dart';
import 'package:hibiki/src/media/collections/shelf_sort.dart';
import 'package:hibiki/src/media/collections/collection_shelf_row.dart';
import 'package:hibiki/src/pages/implementations/media_collection_detail_page.dart';
import 'package:hibiki/src/pages/implementations/media_item_dialog_page.dart';
import 'package:hibiki/src/pages/implementations/media_sources_dialog.dart';
import 'package:hibiki/src/pages/implementations/tag_filter_bar.dart';
import 'package:hibiki/src/pages/implementations/tag_filter_sheet.dart';
import 'package:hibiki/src/pages/implementations/tag_picker_page.dart';
import 'package:hibiki/src/pages/implementations/video_hibiki_page.dart';
import 'package:hibiki/src/pages/implementations/video_statistics_page.dart';
import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/remote_download_progress_badge.dart';
import 'package:hibiki/src/sync/interconnect_download_manager.dart';
import 'package:hibiki/src/sync/cloud_remote_video_client.dart';
import 'package:hibiki/src/sync/remote_cover_image.dart';
import 'package:hibiki/src/sync/remote_video_client.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/video_manifest.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki/src/utils/components/batch_tag_dialog_frame.dart';
import 'package:hibiki/src/pages/implementations/stat_shared.dart';
import 'package:hibiki/src/utils/components/stat_contribution_heatmap.dart';
import 'package:hibiki/src/pages/implementations/collection_name_dialog.dart';
import 'package:hibiki/src/media/video/video_filename_parser.dart';
import 'package:hibiki/src/utils/misc/shelf_ordering.dart';
import 'package:path/path.dart' as p;

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
class HomeVideoPage extends ConsumerStatefulWidget {
  const HomeVideoPage({
    required this.repo,
    this.remoteVideoClientLoader,
    this.cloudRemoteVideoClientLoader,
    this.remoteVideoDownloadDestination,
    super.key,
  });

  final VideoBookRepository repo;
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
  ConsumerState<HomeVideoPage> createState() => _HomeVideoPageState();
}

class _HomeVideoPageState extends ConsumerState<HomeVideoPage> {
  Future<List<VideoBookRow>>? _future;
  Future<_RemoteVideoState?>? _remoteFuture;
  RemoteVideoClient? _remoteVideoClient;

  /// BUG-793：视频库 uid 集合监听。列表是一次性 FutureBuilder + 保活 tab，无此
  /// 订阅时非本页发起的导入（外部「用 Hibiki 打开」等直接落库不 _refresh 的路径）
  /// 要等下拉刷新/重启才出现。订阅 videoBooks 表 → 集合一变（插入/删除）就 _refresh。
  StreamSubscription<List<String>>? _videoUidsSub;

  /// 上一次已知的视频 uid 集合，用于对 [_videoUidsSub] 事件去重：仅集合变化才刷新，
  /// 封面自愈 / 进度回写等纯列更新（集合不变）跳过，避免写回→重刷环。null=尚未收到
  /// 首个事件（首事件仅登记基线，不刷——initState 已首载）。
  Set<String>? _knownVideoUids;

  /// 多端库联合视图 §2.2/§2.6：云后端（Google Drive 等）的云视频目录 client。互联
  /// （hibikiServer）与云后端互斥——一台设备只配一种后端，故 [_remoteVideoClient]（互联）
  /// 与本字段（云）至多一个非空，[_downloadRemote] 据此分派下载路径。
  CloudRemoteVideoClient? _cloudRemoteVideoClient;

  /// 视频卡片拖放命中注册表：每张 [CardDropZone] 注册自身几何，拖放时按屏幕坐标
  /// 命中查找目标视频卡（字幕外挂到该视频）。范型=VideoBookRow。
  final CardDropRegistry<VideoBookRow> _cardDropRegistry =
      CardDropRegistry<VideoBookRow>();

  /// 批量选择模式（与书架 tab 对齐）。开启后卡片点击切换勾选、长按/拖放禁用，
  /// 底部弹批量操作栏（打标签 / 删除）。视频书是扁平 bookUid（不像书架有
  /// epub `mediaIdentifier` + `srt_` 双类前缀），故选择集直接用 bookUid 字符串。
  bool _selectionMode = false;
  final Set<String> _selectedUids = <String>{};

  /// 多选态合集整选（块2）：选中合集 id 集，与散卡选中集 [_selectedUids] 并存。
  /// 组合三档判定（块3）与批量解散/删除（块4）都读这两个集。
  final Set<int> _selectedCollectionIds = <int>{};

  /// 当前可见（过滤后）的本地视频列表，供全选 / 反选用。
  List<VideoBookRow> _visibleVideos = const <VideoBookRow>[];

  /// 当前渲染成横排行的合集 id 列表（[_buildLocalVideoSlivers] 每帧写入），供
  /// 全选 / 反选把可见合集纳入整选集。
  List<int> _visibleCollectionIds = const <int>[];

  /// 上一次成功加载的全量列表缓存：_refresh/封面补齐把 [_future] 换新期间用它
  /// 顶住渲染，**不再整页转圈**（旧行为=每抽一张封面/每次从播放器返回都闪一次
  /// 全页 spinner，用户报「一直在刷新」）。仅首载（缓存空）才显示加载圈。
  List<VideoBookRow>? _videosCache;

  /// 统一合集：本会话已尝试后台抽封面的 bookUid（避免每次刷新对同一行重试 ffmpeg）。
  final Set<String> _coverBackfillAttempted = <String>{};

  /// 后台封面补齐进行中标志（防并发重入）。
  bool _backfillingCovers = false;

  /// 排序交互重设计层次 A：当前排序方式（偏好 `video_sort_mode` 持久化，默认
  /// 最近观看，用户拍板）。旧 `ShelfEntries.sortOrder` 手动权重已废弃不再读取。
  ShelfSortMode _sortMode = ShelfSortMode.recent;

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

  /// 每日观看时长（dateKey → 毫秒之和），驱动顶部概览的观看热力图（GitHub 式）。
  /// 与 [_watchAtByUid] 同批从 watch-stats 全量行聚合（[_loadLibraryMaps]）。
  Map<String, int> _watchMsByDay = const <String, int>{};

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
    // BUG-793：订阅 videoBooks 表，任意导入路径落库后自动刷新库页。
    _videoUidsSub =
        widget.repo.watchVideoBookUids().listen(_onVideoUidsChanged);
    assert(() {
      HomeVideoPage.debugRefreshVideos = _refresh;
      return true;
    }());
  }

  @override
  void dispose() {
    _videoUidsSub?.cancel();
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

  /// 下拉刷新：强制重拉远端视频列表 + 本地列表，await 远端 future 完成后指示器才收起。
  ///
  /// 顶层 tab 保活（[HomePage] 的 `_keepAliveTabs`）后，切回视频 tab 不再隐式重拉远端，
  /// 故给用户一个**显式**强制刷新入口——别的设备新上传的互联视频，不重启 app 也能刷出来。
  /// [_loadRemoteVideos] 内部吞异常返回 `failed:true`，await 不会抛，指示器必定收起
  /// （客户端 [listRemoteVideos] 已用 listTimeout 封顶，host 卡响应也不会无限转圈）。
  /// 显式刷新失败时给一个可见 SnackBar（带原因），避免「看不到远端视频却不知为何」。
  Future<void> _pullToRefresh() async {
    final Future<_RemoteVideoState?> remote = _loadRemoteVideos();
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
    final HibikiDatabase db = appModel.database;
    final ShelfSortMode sortMode =
        ShelfSortMode.fromName(appModel.prefsRepo.videoSortModeName);
    final List<MediaCollectionRow> collections =
        await db.getAllMediaCollections();
    final Map<String, int> primaryMap =
        await db.getPrimaryCollectionIdByEntry();
    // 层次 C：条目在其主折叠合集里的 sortIndex（只记归属合集的行——一条目属多
    // 合集时行内序跟随折叠归属，与 primaryMap 同口径）。
    final Map<String, int> memberSortIndex = <String, int>{};
    for (final MediaCollectionRow c in collections) {
      final List<MediaCollectionItemRow> members =
          await db.getCollectionItems(c.id);
      for (final MediaCollectionItemRow m in members) {
        final String key = '${m.mediaType}|${m.entryKey}';
        if (primaryMap[key] == c.id) memberSortIndex[key] = m.sortIndex;
      }
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
    // 每日观看时长聚合（dateKey → sum watchTimeMs），供顶部观看热力图。同一批
    // watchRows 复用，不再单独查库。
    final Map<String, int> watchMsByDay = <String, int>{};
    for (final VideoWatchStatisticRow r in watchRows) {
      watchMsByDay[r.dateKey] = (watchMsByDay[r.dateKey] ?? 0) + r.watchTimeMs;
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
        _watchMsByDay = watchMsByDay;
      });
    }
  }

  /// 用户切换排序方式：立即重排 + 偏好持久化（跨启动记住）。
  void _setSortMode(ShelfSortMode mode) {
    if (mode == _sortMode) return;
    setState(() => _sortMode = mode);
    unawaited(
      ref.read(appProvider).prefsRepo.setVideoSortModeName(mode.name),
    );
  }

  /// 合集行折叠开关：`setPref` 先同步刷内存缓存，setState 重建即读到新值；
  /// 落库 fire-and-forget（`collapsed_collection_ids`，书架/视频页共用）。
  void _toggleCollectionCollapsed(int collectionId) {
    final PreferencesRepository prefs = ref.read(appProvider).prefsRepo;
    final Set<int> ids = prefs.collapsedCollectionIds;
    if (!ids.remove(collectionId)) ids.add(collectionId);
    unawaited(prefs.setCollapsedCollectionIds(ids));
    setState(() {});
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
    final HibikiClientSyncBackend backend = HibikiClientSyncBackend.instance;
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
    return CloudRemoteVideoClient(backend: backend);
  }

  Future<_RemoteVideoState?> _loadRemoteVideos() async {
    final RemoteVideoClient? client = await _resolveRemoteVideoClient();
    _remoteVideoClient = client;
    if (client != null) {
      // 互联后端：host live 库直接下发 RemoteVideoInfo。
      _cloudRemoteVideoClient = null;
      try {
        final List<RemoteVideoInfo> videos = await client.listRemoteVideos();
        // #6: 远端与本地是同一视频时（同 bookUid）不在混排网格重复展示。
        final List<VideoBookRow> localVideos = await widget.repo.listAll();
        final Set<String> localUids =
            localVideos.map((VideoBookRow r) => r.bookUid).toSet();
        return _RemoteVideoState(
          videos: dedupeRemoteVideos(remote: videos, localBookUids: localUids),
        );
      } catch (e) {
        // spec §2.4 离线语义：拉取失败 → 占位卡不出现（failed 门控），只剩本地库。
        // 原始异常只落 debugPrint 供排查；显式下拉刷新时的用户可见反馈用本地化友好
        // 文案（见 _pullToRefresh），不把 TimeoutException 等开发者文本泄漏进 UI。
        debugPrint('[home-video] remote video list failed: $e');
        return _RemoteVideoState(
          videos: const <RemoteVideoInfo>[],
          failed: true,
        );
      }
    }

    // 云后端（§2.2/§2.6）：读 `__videos__/videos.json` 清单，把云视频条目适配成
    // RemoteVideoInfo 混排进主网格（云角标/排序/散卡降级既有逻辑自动生效）。
    final CloudRemoteVideoClient? cloud =
        await _resolveCloudRemoteVideoClient();
    _cloudRemoteVideoClient = cloud;
    if (cloud == null) return null;
    try {
      // 清单不存在（从未有设备上传）→ listRemoteVideos 返回空表；结构非法
      // （FormatException）向上抛，此处 catch → 本轮云视频不可用（= 只剩本地语义）。
      final List<RemoteVideoManifestEntry> entries =
          await cloud.listRemoteVideos();
      final List<RemoteVideoInfo> videos = <RemoteVideoInfo>[
        for (final RemoteVideoManifestEntry e in entries)
          _cloudManifestToRemoteVideoInfo(e),
      ];
      final List<VideoBookRow> localVideos = await widget.repo.listAll();
      final Set<String> localUids =
          localVideos.map((VideoBookRow r) => r.bookUid).toSet();
      return _RemoteVideoState(
        videos: dedupeRemoteVideos(remote: videos, localBookUids: localUids),
      );
    } catch (e) {
      debugPrint('[home-video] cloud video manifest failed: $e');
      return _RemoteVideoState(
        videos: const <RemoteVideoInfo>[],
        failed: true,
      );
    }
  }

  /// 把云视频清单条目（[RemoteVideoManifestEntry]）适配成主网格占位卡消费的
  /// [RemoteVideoInfo]。云清单只带 uid/title/大小/importedAt/封面资产名——无外挂字幕、
  /// 无远端进度、无合集归属（云视频占位永远散卡，与 §2.3 host 合集归属互不影响），
  /// 故这些字段取缺省。封面走下载时的 [CloudRemoteVideoClient.getRemoteVideoCover]，
  /// 占位阶段用占位图（不预下封面），因此这里不设 coverPath/coverUrl。
  RemoteVideoInfo _cloudManifestToRemoteVideoInfo(RemoteVideoManifestEntry e) {
    return RemoteVideoInfo(
      id: e.uid,
      title: e.title,
      sizeBytes: e.sizeBytes,
      // tags 稳健档：把清单条目的标签 LWW 时钟带进 RemoteVideoInfo，供下载后
      // mergeRemoteVideoTags 按名 max(add) vs max(removed) 解析（删除/改名传播）。
      tagsAddedAt: e.tagsAddedAt,
      tagTombstones: e.tagTombstones,
    );
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
  // 批量打标签 + 删除）；视频 tab 共用同一 [HibikiTagFilterBar]（其 selectionMode /
  // onToggleSelectionMode 入参书架已用、视频此前没传）。这里给视频补上 wiring，
  // 批量操作语义对齐书架（批量打标签 + 批量删除），但因视频书是扁平 bookUid，
  // 选择集与 picker 比书架简单一层（无 epub/srt 双类分支）。

  void _toggleSelectionMode() {
    setState(() {
      _selectionMode = !_selectionMode;
      _selectedUids.clear();
      _selectedCollectionIds.clear();
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedUids.clear();
      _selectedCollectionIds.clear();
    });
  }

  void _toggleSelection(String bookUid) {
    setState(() {
      if (!_selectedUids.remove(bookUid)) {
        _selectedUids.add(bookUid);
      }
    });
  }

  /// 块2：切换整合集选中（合集行头勾选框）。
  void _toggleCollectionSelection(int collectionId) {
    setState(() {
      if (!_selectedCollectionIds.remove(collectionId)) {
        _selectedCollectionIds.add(collectionId);
      }
    });
  }

  /// 一个可见视频是否已折进某合集（= 合集成员，不作散卡单选/全选）。
  bool _isCollectionMember(String bookUid) =>
      _primaryCollectionByEntry.containsKey('video|$bookUid');

  void _selectAllVisible() {
    setState(() {
      // 散卡：只选未折进合集的可见视频（折进的成员由整合集选中，不单独勾）。
      for (final VideoBookRow book in _visibleVideos) {
        if (_isCollectionMember(book.bookUid)) continue;
        _selectedUids.add(book.bookUid);
      }
      _selectedCollectionIds.addAll(_visibleCollectionIds);
    });
  }

  void _invertSelection() {
    setState(() {
      final Set<String> allLoose = <String>{
        for (final VideoBookRow book in _visibleVideos)
          if (!_isCollectionMember(book.bookUid)) book.bookUid,
      };
      final Set<String> invertedLoose = allLoose.difference(_selectedUids);
      _selectedUids
        ..clear()
        ..addAll(invertedLoose);
      final Set<int> allCollections = _visibleCollectionIds.toSet();
      final Set<int> invertedCollections =
          allCollections.difference(_selectedCollectionIds);
      _selectedCollectionIds
        ..clear()
        ..addAll(invertedCollections);
    });
  }

  /// 块4：批量删除区分解散/删媒体。
  /// - 选中合集 → 解散（[HibikiDatabase.deleteMediaCollection]：只解除分组，不删媒体本体）；
  /// - 选中散卡 → 删媒体本体（[VideoBookRepository.deleteVideoBook]，现状语义）；
  /// - 混选 → 确认框文案写明「删 N 个媒体、解散 M 个合集」。
  Future<void> _batchDeleteConfirm() async {
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
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(t.dialog_delete),
        content: Text(message),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.dialog_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              t.dialog_delete,
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final HibikiDatabase db = ref.read(appProvider).database;
    // 先解散选中合集（只删合集容器 + 成员引用行，绝不删媒体本体）。
    final Set<int> toDissolve = Set<int>.of(_selectedCollectionIds);
    int dissolved = 0;
    for (final int id in toDissolve) {
      final int removed = await db.deleteMediaCollection(id);
      if (removed > 0) dissolved++;
    }
    // 再删选中散卡的媒体本体（现状语义）。
    final Set<String> toDelete = Set<String>.of(_selectedUids);
    final List<VideoBookRow> deletedBooks = <VideoBookRow>[];
    for (final String bookUid in toDelete) {
      final VideoBookRow? book = await widget.repo.getByBookUid(bookUid);
      if (book == null) continue;
      await widget.repo.deleteVideoBook(bookUid);
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
    HibikiToast.show(msg: successMsg);
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
  /// 应用到所有选中视频书（经 [HibikiDatabase.addTagToVideoBook] /
  /// [HibikiDatabase.removeTagFromVideoBook]），关闭后刷新映射。
  Future<void> _batchShowTagPicker() async {
    if (_selectedUids.isEmpty) return;
    final List<BookTagRow>? allTags = ref.read(allTagsProvider).valueOrNull;
    if (allTags == null || allTags.isEmpty) {
      HibikiToast.show(msg: t.tag_no_tags_hint);
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

  /// 打开「番剧下载」选种对话框。关闭后刷新列表（完成钩子可能已自动入库新视频，
  /// 「边下边播」也会立即入库）。
  Future<void> _openAnimeDownload() async {
    await showAppDialog<void>(
      context: context,
      builder: (_) => const AnimeDownloadDialog(),
    );
    if (mounted) _refresh();
  }

  /// 打开「管理来源」对话框（视频来源库）。关闭后刷新列表（扫描可能新增视频）。
  Future<void> _openManageSources() async {
    await showAppDialog<void>(
      context: context,
      builder: (_) => const MediaSourcesDialog(mediaKind: 'video'),
    );
    // 管理互联源可能新增/切换/移除远端 host，远端清单需重拉。
    if (mounted) _refresh(remote: true);
  }

  /// 拖放到视频 tab 时的处理：分类文件 → 局部坐标转屏幕坐标命中卡片 → 决策意图。
  ///
  /// [globalPosition] 为 [HibikiFileDropTarget] 透出的 Flutter global/view 坐标，
  /// 可直接交给卡片注册表命中（注册表存的是同一坐标系的屏幕矩形）。
  void _handleVideoDrop(List<String> paths, Offset globalPosition) {
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;

    final DroppedFiles files = classifyDroppedFiles(paths);
    debugPrint(
      '[hibiki-drop] [home-video] classified '
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
        debugPrint('[hibiki-drop] [home-video] intent=needCardTarget');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.drag_drop_need_card_target)),
        );
      case DropIntent.unsupportedSurface:
        debugPrint('[hibiki-drop] [home-video] intent=unsupportedSurface');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.drag_drop_unsupported_on_video)),
        );
      case DropIntent.importNewBook:
      case DropIntent.attachToBookCard:
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
          '[hibiki-drop] [home-video] attachSubtitle outcome=attached '
          'bookUid=${book.bookUid} cues=${result.cueCount}',
        );
        _refresh();
      case SubtitleAttachOutcome.playlistNeedsPlayer:
        message = t.video_subtitle_attach_playlist_hint;
        debugPrint(
          '[hibiki-drop] [home-video] attachSubtitle outcome=playlistNeedsPlayer '
          'bookUid=${book.bookUid}',
        );
      case SubtitleAttachOutcome.unsupported:
        message = t.video_subtitle_import_unsupported;
        debugPrint(
          '[hibiki-drop] [home-video] attachSubtitle outcome=unsupported '
          'bookUid=${book.bookUid}',
        );
      case SubtitleAttachOutcome.copyFailed:
        message = t.video_subtitle_import_failed;
        debugPrint(
          '[hibiki-drop] [home-video] attachSubtitle outcome=copyFailed '
          'bookUid=${book.bookUid}',
        );
      case SubtitleAttachOutcome.emptyCues:
        message = t.video_subtitle_load_failed(label: result.label);
        debugPrint(
          '[hibiki-drop] [home-video] attachSubtitle outcome=emptyCues '
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
    final HibikiDatabase db = ref.read(appProvider).database;
    final List<int> collectionIds = _selectedCollectionIds.toList()..sort();
    final List<ShelfEntryRef> looseRefs = <ShelfEntryRef>[
      for (final String uid in _selectedUids)
        if (shelfSelectionToEntry(uid, ShelfSelectionSurface.video)
            case final ShelfEntryRef ref)
          ref,
    ];
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
    HibikiDatabase db,
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
    HibikiToast.show(msg: t.series_created);
  }

  /// 档2：恰 1 合集 + 若干散卡 → 散卡并入该合集（不弹命名）。
  Future<void> _combineAddToExisting(
    HibikiDatabase db,
    int collectionId,
    List<ShelfEntryRef> refs,
  ) async {
    for (final ShelfEntryRef ref in refs) {
      await db.addToCollection(collectionId, ref.mediaType, ref.entryKey);
    }
    if (!mounted) return;
    _exitSelectionMode();
    await _loadLibraryMaps();
    HibikiToast.show(msg: t.batch_add_to_collection_success(n: refs.length));
  }

  /// 档3：≥2 合集（可带散卡）→ 合并成一个。目标 = 成员最多合集（其名作默认名，
  /// 确认框可改名）；目标吸收其余合集成员（addToCollection）+ 散卡加入，其余合集
  /// deleteMediaCollection 解散（只解除分组，不删媒体本体）。
  Future<void> _combineMergeCollections(
    HibikiDatabase db,
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
        await db.addToCollection(targetId, m.mediaType, m.entryKey);
      }
      await db.deleteMediaCollection(id);
    }
    for (final ShelfEntryRef ref in refs) {
      await db.addToCollection(targetId, ref.mediaType, ref.entryKey);
    }
    await db.renameMediaCollection(targetId, name);
    if (!mounted) return;
    _exitSelectionMode();
    await _loadLibraryMaps();
    HibikiToast.show(msg: t.collection_merged);
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
    await Navigator.push(
      context,
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => VideoHibikiPage.neutralized(
          bookUid: book.bookUid,
          repo: widget.repo,
          playlistCollectionId: playlistCollectionId,
        ),
      ),
    );
    // 从播放器返回后刷新：继续观看 hero / 概览统计 / 卡片观看进度行都依赖
    // lastPositionMs 与 watch-stats，播完不刷会展示陈旧数据（对抗审查确认）。
    if (mounted) _refresh();
  }

  Future<void> _openRemote(RemoteVideoInfo video) async {
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
    final RemoteVideoClient? client = _remoteVideoClient;
    final CloudRemoteVideoClient? cloud = _cloudRemoteVideoClient;
    // #3: 服务不可达 / 未鉴权时给明确提示，不再静默 return（用户点了像没反应）。
    if (client == null && cloud == null) {
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
    // 互联 vs 云后端分派：互联走 host live 下载 + 字幕；云后端（§2.2/§2.6）走
    // CloudRemoteVideoClient.getRemoteVideo 拉整文件，收尾登记时无外挂字幕、封面可选。
    // bookUid 用稳定的远端 video.id（与 dedupeRemoteVideos 去重键一致：upsert 同行不
    // 撞键），故下载好的视频立即出现在列表、并从混排占位区去重隐藏。
    final InterconnectDownloadRunner run = client != null
        ? (File target, {void Function(double progress)? onProgress}) =>
            client.downloadRemoteVideo(video.id, target, onProgress: onProgress)
        : (File target, {void Function(double progress)? onProgress}) =>
            cloud!.getRemoteVideo(video.id, target, onProgress: onProgress);
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
      importedAt: Value(DateTime.now()),
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
      importedAt: Value(DateTime.now()),
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
    final String safeUid = bookUid.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
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
    final String safeUid = video.id.replaceAll(RegExp(r'[\/:*?"<>|]'), '_');
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
    final String safeTitle =
        video.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
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
        quickActions: <DialogQuickAction>[
          DialogQuickAction(
            label: t.tag_label,
            icon: Icons.sell_outlined,
            onPressed: () {
              Navigator.pop(dialogContext);
              _editTags(book);
            },
          ),
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
            label: t.video_import_pick_subtitle,
            icon: Icons.subtitles_outlined,
            onPressed: () {
              Navigator.pop(dialogContext);
              _pickSubtitle(book);
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

  Future<void> _editTags(VideoBookRow book) async {
    await Navigator.push(
      context,
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => TagPickerPage(videoBookUid: book.bookUid),
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
      HibikiToast.show(msg: t.tag_already_on_book(name: tag.name));
      return;
    }

    await ref.read(appProvider).database.addTagToVideoBook(bookUid, tag.id);
    ref.invalidate(videoBookTagMapProvider);
    ref.invalidate(filteredVideoBookUidsProvider);
    if (mounted) {
      HibikiToast.show(msg: t.tag_added_to_video(name: tag.name));
    }
  }

  /// 把标签拖到合集行头 = 给整个合集打标签（`CollectionShelfRow.onTagDropped`）。
  /// `addTagToCollection` 本身幂等（INSERT OR IGNORE），这里先查现有标签给「已存在」
  /// 提示，避免静默无反馈；成功后失效 [filteredCollectionIdsProvider] 让标签过滤下
  /// 合集卡显隐立即刷新（详情页标签行走 FutureBuilder，重进即新）。
  Future<void> _addTagToVideoCollection(
      int collectionId, BookTagRow tag) async {
    final HibikiDatabase db = ref.read(appProvider).database;
    final List<BookTagRow> existing =
        await db.getTagsForCollection(collectionId);
    if (existing.any((BookTagRow t) => t.id == tag.id)) {
      HibikiToast.show(msg: t.tag_already_on_collection(name: tag.name));
      return;
    }
    await db.addTagToCollection(collectionId, tag.id);
    ref.invalidate(filteredCollectionIdsProvider);
    if (mounted) {
      HibikiToast.show(msg: t.tag_added_to_collection(name: tag.name));
    }
  }

  /// 设置封面：选图 → 经共享 [setVideoCoverFromPickedFile]（拷盘 + 驱逐旧缓存 +
  /// 落库）→ 刷新。与书架视频卡的换封面共用同一入口，封面与自动截图同目录。
  Future<void> _pickCover(VideoBookRow book) async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.image,
    );
    final String? pickedPath = result?.files.first.path;
    if (pickedPath == null || !mounted) return;
    await setVideoCoverFromPickedFile(
      repo: widget.repo,
      bookUid: book.bookUid,
      pickedPath: pickedPath,
    );
    if (mounted) _refresh();
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
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(t.video_delete_title),
        content: Text(t.video_delete_confirm(title: book.title)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.dialog_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              t.dialog_delete,
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final String? deletedCoverPath = book.coverPath;
    final String? deletedSubtitlePath = book.subtitleSource;
    final String deletedVideoPath = book.videoPath;
    await widget.repo.deleteVideoBook(book.bookUid);
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
    // DesktopContentLayout + HibikiPageHeader（大标题 + HibikiIconButton），三个
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
      child: HibikiFileDropTarget(
        debugLabel: 'home-video',
        onDrop: _handleVideoDrop,
        child: CardDropScope<VideoBookRow>(
          registry: _cardDropRegistry,
          child: DesktopContentLayout(
            kind: DesktopContentKind.readerShelf,
            child: Column(
              children: <Widget>[
                if (!isCupertinoPlatform(context)) _buildPageHeader(canImport),
                _buildTagFilterBar(allTags),
                Expanded(
                  child: _buildVideoLibraryBody(),
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
          return const Center(child: CircularProgressIndicator());
        }
        final List<VideoBookRow> all = loaded;
        final Set<String>? filter =
            ref.watch(filteredVideoBookUidsProvider).valueOrNull;
        final List<VideoBookRow> books = filter == null
            ? all
            : all
                .where((VideoBookRow b) => filter.contains(b.bookUid))
                .toList();
        // 排序交互重设计：卡片间序在 group 层按当前排序方式做（[_groupVideos]），
        // 这里不再预排散列表（旧 ShelfEntries.sortOrder 死权重已废弃，用户拍板）。
        final List<VideoBookRow> ordered = books;
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
            final List<RemoteVideoInfo> remoteVideos =
                _visibleRemoteVideos(remoteSnap.data, filter);
            // 下拉刷新：保活后切回不再隐式重拉远端，给用户显式强制刷新入口。
            // AlwaysScrollableScrollPhysics 保证内容不足一屏时也能下拉触发。
            // UI v2：散卡网格与合集横排行统一卡宽（用户实报合集卡大一截）——
            // 以 240 为目标宽算响应式列数，两处共用同一实际卡宽。
            return RefreshIndicator(
              onRefresh: _pullToRefresh,
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  final HibikiDesignTokens tokens =
                      HibikiDesignTokens.of(context);
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
                      // 本地库非空恒显示概览（活动热力图）；本地空时仅当存在远端
                      // 续播候选（有断点未看完）才显示——否则「连了远端但没在看任何
                      // 视频」不该凭空冒出一张空概览（也避免挤走远端卡的可点区域）。
                      if (all.isNotEmpty ||
                          _hasRemoteResumeCandidate(remoteVideos))
                        SliverToBoxAdapter(
                          child: _buildOverviewSection(all, remoteVideos),
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

  /// UI v2 Phase B：顶部概览条 =「继续观看 hero」+「观看活动热力图」。
  ///
  /// hero = 有痕迹未看完中最近看过的一条（[computeVideoLibraryOverview]，
  /// watch-stats → importedAt 回退）。右侧不再是「总数/未完成/近7天导入」三格状态
  /// 计数（用户反馈：那是状态非统计），改成 GitHub 式观看时长热力图（[_watchMsByDay]，
  /// 整卡点开完整视频统计页）。宽 ≥720 并排、窄屏纵向堆叠；无 hero 候选时只渲染热力图。
  /// 远端视频 → [RemoteContinueEntry] 投影（completed 由 positionMs/durationMs
  /// 派生，远端无 completed 列）。概览 gate 与 hero 选取共用，单一真值不重复派生。
  List<RemoteContinueEntry> _remoteContinueEntries(
    List<RemoteVideoInfo> remoteVideos,
  ) =>
      <RemoteContinueEntry>[
        for (final RemoteVideoInfo v in remoteVideos)
          RemoteContinueEntry(
            id: v.id,
            positionMs: v.positionMs,
            completed: v.durationMs != null &&
                v.durationMs! > 0 &&
                v.positionMs >= (v.durationMs! * 0.9),
            updatedAtMs: v.positionUpdatedAtMs,
          ),
      ];

  /// 是否存在远端续播候选（有断点未看完）。本地库空时用它 gate 概览显隐。
  bool _hasRemoteResumeCandidate(List<RemoteVideoInfo> remoteVideos) =>
      pickRemoteContinueEntry(_remoteContinueEntries(remoteVideos)) != null;

  Widget _buildOverviewSection(
    List<VideoBookRow> all,
    List<RemoteVideoInfo> remoteVideos,
  ) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final VideoLibraryOverview overview = computeVideoLibraryOverview(
      entries: <VideoOverviewEntry>[
        for (final VideoBookRow r in all)
          VideoOverviewEntry(
            bookUid: r.bookUid,
            title: r.title,
            lastPositionMs: r.lastPositionMs,
            completed: r.completedAt != null,
            importedAt: r.importedAt,
          ),
      ],
      // uid 优先、遗留行按 title 回退，合并成按 uid 键控的单一映射。
      lastWatchedByUid: <String, DateTime>{
        for (final VideoBookRow r in all)
          if ((_watchAtByUid[r.bookUid] ?? _legacyWatchAtByTitle[r.title])
              case final DateTime at)
            r.bookUid: at,
      },
      // BUG-848：合集分组 + 组内序（去 'video|' 前缀投影成 uid 键控），驱动 hero 的
      // Next-Up 选集（看完一集 → 前进下一集）。
      collectionByUid: <String, int>{
        for (final VideoBookRow r in all)
          if (_primaryCollectionByEntry['video|${r.bookUid}']
              case final int cid)
            r.bookUid: cid,
      },
      sortIndexByUid: <String, int>{
        for (final VideoBookRow r in all)
          if (_memberSortIndex['video|${r.bookUid}'] case final int si)
            r.bookUid: si,
      },
      now: DateTime.now(),
    );
    VideoBookRow? hero;
    if (overview.heroUid != null) {
      for (final VideoBookRow r in all) {
        if (r.bookUid == overview.heroUid) {
          hero = r;
          break;
        }
      }
    }
    // #3：远端/互联视频也进「继续观看」。纯流播远端无本地进度行，独立挑候选
    // （[pickRemoteContinueEntry]：有断点未看完、host 端断点时间戳最新），再与本地
    // hero 按时间戳比较——远端更近（或本地无 hero）则 hero 换成远端卡（点击 _openRemote）。
    final RemoteContinueEntry? remoteBest =
        pickRemoteContinueEntry(_remoteContinueEntries(remoteVideos));
    final int? localWatchedMs =
        overview.heroLastWatched?.millisecondsSinceEpoch;
    final bool remoteWins = remoteBest != null &&
        (hero == null ||
            localWatchedMs == null ||
            remoteBest.updatedAtMs > localWatchedMs);
    final Widget stats = _buildWatchHeatmapCard(tokens);
    Widget? heroCard;
    if (remoteWins) {
      final RemoteVideoInfo rv =
          remoteVideos.firstWhere((RemoteVideoInfo v) => v.id == remoteBest.id);
      heroCard = _buildContinueHeroRemote(rv, tokens);
    } else if (hero != null) {
      heroCard = _buildContinueHero(hero, overview, tokens);
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.card,
        tokens.spacing.gap,
        tokens.spacing.card,
        0,
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          if (heroCard == null) return stats;
          final bool wide = constraints.maxWidth >= 720;
          if (wide) {
            // IntrinsicHeight 必须有：本区在 SliverToBoxAdapter 下主轴（竖向）无界，
            // 裸 Row(stretch) 会把无界高度强加给 Expanded 子项 → BoxConstraints
            // forces an infinite height 首帧崩溃（对抗审查确认）。IntrinsicHeight
            // 先按子项固有高度收界，再 stretch 等高。
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(flex: 3, child: heroCard),
                  SizedBox(width: tokens.spacing.gap + 4),
                  Expanded(flex: 2, child: stats),
                ],
              ),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              heroCard,
              SizedBox(height: tokens.spacing.gap),
              stats,
            ],
          );
        },
      ),
    );
  }

  /// 继续观看 hero 卡：封面缩略 + 标题 + 已看至/上次观看 + 播放示意。整卡点击
  /// 续播（带其 primary 合集 → 播放器有剧集面板/上下集）；无独立按钮避免嵌套
  /// 焦点目标（卡本身即手柄/键盘目标）。
  Widget _buildContinueHero(
    VideoBookRow hero,
    VideoLibraryOverview overview,
    HibikiDesignTokens tokens,
  ) {
    final int? collectionId =
        _primaryCollectionByEntry['video|${hero.bookUid}'];
    final DateTime? watched = overview.heroLastWatched;
    final List<String> metadata = <String>[
      t.video_watched_up_to(time: formatVideoPosition(hero.lastPositionMs)),
      if (watched != null)
        t.video_last_watched(date: _formatOverviewDate(watched)),
    ];
    return HibikiCard(
      key: const ValueKey<String>('home_video_continue_hero'),
      focusId: const HibikiFocusId('home-video-continue-hero'),
      onTap: () => _open(hero, playlistCollectionId: collectionId),
      child: Row(
        children: <Widget>[
          ClipRRect(
            borderRadius: HibikiBorderRadius.card,
            child: SizedBox(
              width: 148,
              height: 84,
              child: _buildCover(hero),
            ),
          ),
          SizedBox(width: tokens.spacing.gap + 4),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(t.video_continue_watching,
                    style: tokens.type.sectionLabel),
                SizedBox(height: tokens.spacing.gap / 2),
                Text(
                  hero.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.listTitle,
                ),
                SizedBox(height: tokens.spacing.gap / 2),
                Text(
                  metadata.join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.metadata,
                ),
              ],
            ),
          ),
          SizedBox(width: tokens.spacing.gap),
          Icon(
            Icons.play_circle_filled,
            size: 36,
            color: tokens.surfaces.primary,
          ),
        ],
      ),
    );
  }

  /// 远端「继续观看」hero 卡（#3）：与本地 [_buildContinueHero] 同形态，但封面走
  /// 远端封面 [_buildRemoteVideoCover]、进度取 host 端 [RemoteVideoInfo.positionMs] /
  /// [RemoteVideoInfo.positionUpdatedAtMs]，整卡点击走远端流播 [_openRemote]。
  Widget _buildContinueHeroRemote(
    RemoteVideoInfo video,
    HibikiDesignTokens tokens,
  ) {
    final DateTime? watched = video.positionUpdatedAtMs > 0
        ? DateTime.fromMillisecondsSinceEpoch(video.positionUpdatedAtMs)
        : null;
    final List<String> metadata = <String>[
      t.video_watched_up_to(time: formatVideoPosition(video.positionMs)),
      if (watched != null)
        t.video_last_watched(date: _formatOverviewDate(watched)),
    ];
    return HibikiCard(
      key: ValueKey<String>('home_video_continue_hero_remote_${video.id}'),
      focusId: const HibikiFocusId('home-video-continue-hero'),
      onTap: () => _openRemote(video),
      child: Row(
        children: <Widget>[
          ClipRRect(
            borderRadius: HibikiBorderRadius.card,
            child: SizedBox(
              width: 148,
              height: 84,
              child: _buildRemoteVideoCover(video),
            ),
          ),
          SizedBox(width: tokens.spacing.gap + 4),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(t.video_continue_watching,
                    style: tokens.type.sectionLabel),
                SizedBox(height: tokens.spacing.gap / 2),
                Text(
                  video.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.listTitle,
                ),
                SizedBox(height: tokens.spacing.gap / 2),
                Text(
                  metadata.join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.metadata,
                ),
              ],
            ),
          ),
          SizedBox(width: tokens.spacing.gap),
          Icon(
            Icons.play_circle_filled,
            size: 36,
            color: tokens.surfaces.primary,
          ),
        ],
      ),
    );
  }

  /// 顶部观看活动热力图卡（GitHub 式贡献图）：按每日观看时长 [_watchMsByDay] 铺
  /// 数周方格。可点**标题**打开完整视频统计页；点某天格子弹气泡看当日观看时长；
  /// 数据超首屏时热力图右上出现翻页箭头看更早历史。取代旧的「总数/未完成/近7天
  /// 导入」三格状态计数——那是状态而非统计（用户反馈），热力图直观展示观看活跃度。
  Widget _buildWatchHeatmapCard(HibikiDesignTokens tokens) {
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: tokens.surfaces.group,
        shape: const RoundedRectangleBorder(
          borderRadius: HibikiBorderRadius.card,
        ),
      ),
      child: Padding(
        padding: EdgeInsets.all(tokens.spacing.gap + 4),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _buildStatHeatmapTitle(
              tokens,
              t.video_watch_activity,
              _openStatistics,
            ),
            SizedBox(height: tokens.spacing.gap),
            StatContributionHeatmap(
              valueByDateKey: _watchMsByDay,
              now: DateTime.now(),
              baseColor: tokens.surfaces.primary,
              emptyColor: tokens.surfaces.card,
              valueLabel: (String dateKey, int ms) =>
                  '${formatStatHeatmapDay(dateKey)} · ${formatStatTime(ms)}',
            ),
          ],
        ),
      ),
    );
  }

  /// 热力图卡可点标题：文字 + 尾随小箭头，点击打开对应统计页（取代旧的整卡 onTap，
  /// 好把格子点击让给「查看每日数值」）。
  Widget _buildStatHeatmapTitle(
    HibikiDesignTokens tokens,
    String label,
    VoidCallback onOpen,
  ) {
    return InkWell(
      onTap: onOpen,
      borderRadius: const BorderRadius.all(Radius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(label, style: tokens.type.sectionLabel),
            const SizedBox(width: 2),
            Icon(
              Icons.chevron_right,
              size: 16,
              color: tokens.type.sectionLabel.color,
            ),
          ],
        ),
      ),
    );
  }

  /// 概览用短日期（`M-dd`；跨年补年份）。无 intl 依赖的确定性格式。
  String _formatOverviewDate(DateTime at) {
    final DateTime now = DateTime.now();
    final String dd = at.day.toString().padLeft(2, '0');
    if (at.year == now.year) return '${at.month}-$dd';
    return '${at.year}-${at.month}-$dd';
  }

  /// 本地视频区的 sliver 列表：空库 / 筛选无结果时是占满剩余空间的提示；否则
  /// **分区**（去碎片 spec 2026-07-12，已拍板方案 A+顶部）——合集横排行集中
  /// 渲染在前（[CollectionShelfRow]，区内保持排序模式的组间序），散卡合成
  /// **单一** [SliverGrid] 在后。旧保序交错布局每个合集行都把网格切段产生残行
  /// （一两张卡占一行，用户实报）；分区后残行恒 1 个（网格末行）。
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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
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
      final String key = 'video|${video.id}';
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
    // 块2：记录本帧渲染成横排行的合集 id（供全选/反选把可见合集纳入整选集）。
    // 被标签过滤隐藏的合集不计入可见集，避免全选勾中隐藏合集。
    _visibleCollectionIds = <int>[
      for (final CollectionGroup<_VideoSlot> g in groups)
        if (g.collection != null && collectionVisible(g.collection!.id))
          g.collection!.id,
    ];
    final bool hasCollectionRows = groups.any(
      (CollectionGroup<_VideoSlot> g) =>
          g.collection != null && collectionVisible(g.collection!.id),
    );
    // 零合集：单网格 + 原 EdgeInsets.all 内边距（与旧布局逐像素一致）。
    final EdgeInsetsGeometry gridPadding = hasCollectionRows
        ? EdgeInsets.symmetric(
            horizontal: tokens.spacing.card,
            vertical: tokens.spacing.gap,
          )
        : EdgeInsets.all(tokens.spacing.card);
    final List<Widget> slivers = <Widget>[];
    // 方案A（去碎片）：合集行集中渲染在前（可含远端占位成员），散卡（本地 + 未归属
    // 远端占位）合成单一网格在后，按当前排序模式统一排序（远端进度时间戳/目录序退化）。
    final List<_VideoLooseCard> loose = <_VideoLooseCard>[];
    for (final CollectionGroup<_VideoSlot> group in groups) {
      if (group.collection == null) {
        final _VideoSlot slot = group.coverItem.payload;
        loose.add(_VideoLooseCard(
          sortKey: _groupSortKey(group),
          build: () => _buildVideoSlotCard(slot),
        ));
      } else if (collectionVisible(group.collection!.id)) {
        slivers.add(
          SliverToBoxAdapter(
            child: _buildVideoCollectionRow(group, cardLayout),
          ),
        );
      }
      // 标签过滤隐藏的合集：整行连同成员一并跳过（成员随合集隐藏，符合按合集标签显隐语义）。
    }
    loose.sort((_VideoLooseCard a, _VideoLooseCard b) =>
        compareShelfSortKeys(a.sortKey, b.sortKey, _sortMode));
    if (loose.isNotEmpty) {
      slivers.add(_buildLooseVideoGridSliver(loose, gridPadding, cardLayout));
    }
    return slivers;
  }

  /// 散卡分派：本地卡 [_buildCard] / 远端占位卡 [_buildRemoteVideoCard]（任务10 union）。
  Widget _buildVideoSlotCard(_VideoSlot slot) {
    final VideoBookRow? local = slot.local;
    if (local != null) return _buildCard(local);
    return _buildRemoteVideoCard(slot.remote!);
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
          mediaType: 'video',
          entryKey: book.bookUid,
          importedAt: book.importedAt?.millisecondsSinceEpoch ?? 0,
          payload: _VideoSlot(local: book),
        ),
    ];
    for (int i = 0; i < remoteVideos.length; i++) {
      final RemoteVideoInfo video = remoteVideos[i];
      items.add(CollectionOrderingItem<_VideoSlot>(
        mediaType: 'video',
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

  /// 一个合集的全宽横排行：头（合集名+集数+查看全部→详情页）+ 横向成员卡列表。
  /// 本地成员卡复用 [_buildCard] 并带 playlistCollectionId——点某集**直接从该集**进
  /// 播放器（带剧集面板/上下集/连播）；远端占位成员（任务10 union）走 [_buildRemoteVideoCard]
  /// （流播/下载，无本地集坐标故不带 playlistCollectionId）。初始横滚定位到「继续看」成员。
  Widget _buildVideoCollectionRow(
    CollectionGroup<_VideoSlot> group,
    ({int columns, double cardWidth}) cardLayout,
  ) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final MediaCollectionRow collection = group.collection!;
    final int continueIdx = continueMemberIndex(<CollectionMemberProgress>[
      for (final CollectionOrderingItem<_VideoSlot> it in group.items)
        CollectionMemberProgress(
          // 远端占位无本地播放断点：用远端进度 positionMs、completed 恒 false。
          positionMs: it.payload.local?.lastPositionMs ??
              it.payload.remote?.positionMs ??
              0,
          completed: it.payload.local?.completedAt != null,
        ),
    ]);
    // 行头计数 = 行体实际渲染的成员数（本地 + 远端占位），与 itemCount 同源（BUG-790）。
    // 旧口径只数本地成员，导致「全为未下载远端剧集」的合集行明明有云占位卡却显示「0 集」，
    // 与眼前所见割裂（用户实报）。行头数字必须诚实反映该行看得见的卡片数。
    final int memberCount = group.items.length;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.card,
        tokens.spacing.gap,
        tokens.spacing.card,
        tokens.spacing.gap,
      ),
      child: CollectionShelfRow(
        key: ValueKey<String>('home_video_collection_row_${collection.id}'),
        title: collection.name,
        countLabel: t.video_playlist_episodes(count: memberCount),
        itemCount: memberCount,
        // 与散卡网格 cell 同宽同高（unifiedShelfCardLayout + _videoCardExtent：
        // 16:9 封面 + 标题 + Phase D 观看进度行，随卡宽联动）。
        itemWidth: cardLayout.cardWidth,
        rowHeight: _videoCardExtent(cardLayout.cardWidth),
        initialIndex: continueIdx,
        headerFocusId: HibikiFocusId('home-video-collection-${collection.id}'),
        onOpenDetail: () => _openCollectionDetail(collection),
        collapsed: ref
            .watch(appProvider)
            .prefsRepo
            .collapsedCollectionIds
            .contains(collection.id),
        onToggleCollapsed: () => _toggleCollectionCollapsed(collection.id),
        // 块2：多选态行头挂整选勾选框（选=选中整个合集）；成员卡在多选态不可单独勾。
        selectionCheckbox: _selectionMode
            ? _buildSelectionCheck(
                _selectedCollectionIds.contains(collection.id))
            : null,
        onToggleSelected: _selectionMode
            ? () => _toggleCollectionSelection(collection.id)
            : null,
        // 拖标签到行头 = 给整个合集打标签（与散卡书级拖放一致）。
        onTagDropped: (BookTagRow tag) =>
            _addTagToVideoCollection(collection.id, tag),
        itemBuilder: (BuildContext _, int i) {
          final _VideoSlot slot = group.items[i].payload;
          final VideoBookRow? local = slot.local;
          if (local != null) {
            return _buildCard(
              local,
              playlistCollectionId: collection.id,
              selectable: false,
            );
          }
          return _buildRemoteVideoCard(slot.remote!);
        },
      ),
    );
  }

  /// 多端库联合视图占位卡（spec 2026-07-12 §2.1，撤独立远端分区）：本地视频卡尺寸 +
  /// 远端封面 + 云角标 ☁，混排进视频库主网格散卡区（[_buildLocalVideoSlivers]）。
  /// 短按走现有远端流播 [_openRemote]；右上角下载按钮/进度徽章复用 [_downloadRemote]
  /// （下载委托 InterconnectDownloadManager，切 tab/退页仍推进）。
  Widget _buildRemoteVideoCard(RemoteVideoInfo video) {
    final String safeKey = _safeRemoteKey(video.id);
    // 不再固定 260 宽：和本地 [_buildCard] 一样让卡片填满网格 cell，宽度由
    // 响应式网格决定（TODO-593）。
    return HibikiCard(
      key: ValueKey<String>('remote_video_card_$safeKey'),
      focusId: HibikiFocusId('home-video-remote-$safeKey'),
      padding: EdgeInsets.zero,
      onTap: () => _openRemote(video),
      // 短按仍流式播放（_openRemote）；长按 / 桌面右键弹选项面板，与本地视频
      // 卡长按一致（TODO-768 / BUG-416）。原先远端视频卡无 onLongPress（长按
      // 没反应），现在补齐。
      onLongPress: () => _showRemoteVideoDialog(video),
      onSecondaryTap: () => _showRemoteVideoDialog(video),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                _buildRemoteVideoCover(video),
                Positioned(
                  top: 6,
                  right: 6,
                  child: ref
                          .watch(interconnectDownloadManagerProvider)
                          .isRunning(video.id)
                      ? RemoteDownloadProgressBadge(
                          key: ValueKey<String>(
                              'remote_video_downloading_$safeKey'),
                          progress: ref
                              .watch(interconnectDownloadManagerProvider)
                              .progressFor(video.id),
                          tooltip: t.remote_video_downloading,
                        )
                      : IconButton.filledTonal(
                          key: ValueKey<String>(
                              'remote_video_download_$safeKey'),
                          tooltip: t.remote_video_download,
                          iconSize: 18,
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.download_outlined),
                          onPressed: () => _downloadRemote(video),
                        ),
                ),
                if (video.hasSubtitle)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.62),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.subtitles_outlined,
                        size: 14,
                        color: Colors.white,
                      ),
                    ),
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Text(
              video.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRemoteVideoCover(RemoteVideoInfo video) {
    final String safeKey = _safeRemoteKey(video.id);
    final String? coverPath = video.coverPath;
    if (coverPath != null && File(coverPath).existsSync()) {
      return Image.file(
        File(coverPath),
        key: ValueKey<String>('remote_video_cover_$safeKey'),
        // TODO-616 phase C: 视频封面是 16:9（1.78）源，封面卡槽比它更窄
        // （约 1.3-1.55），BoxFit.cover 会裁掉左右。改用 contain 让整帧完整
        // 显示，上下留少量空带 = 用户要的「完整显示」。
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => _coverPlaceholder(),
      );
    }
    final String? coverUrl = video.coverUrl;
    // TODO-1235（TODO-961 回归）：封面走互联同款钉扎客户端拉取，不再用 Image.network
    // （Flutter 内部 HttpClient 无 badCertificateCallback，https 自签握手必失败）。
    final RemoteCoverFetcher? fetcher =
        remoteCoverFetcherFor(_remoteVideoClient);
    if (coverUrl != null && coverUrl.isNotEmpty && fetcher != null) {
      return Image(
        // BUG-847：按稳定 video.id 磁盘缓存（非易变 coverUrl），冷启动/滚动不重下。
        image: RemoteCoverImage(coverUrl, fetcher, cacheKey: video.id),
        key: ValueKey<String>('remote_video_cover_$safeKey'),
        // TODO-616 phase C: 同上，远端云视频封面也用 contain 完整显示不裁切。
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => _coverPlaceholder(),
      );
    }
    return _coverPlaceholder();
  }

  String _safeRemoteKey(String id) =>
      id.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');

  /// 云角标 ☁ 视觉：半透明黑底胶囊 + 白色云图标（与字幕/集数徽章同款）。多端库
  /// 联合视图占位卡的「远端 / 未下载」标识（spec §2.1）。带稳定 key 供 widget 测试定位。
  Widget _remoteVideoCloudBadge(String safeKey) {
    return Container(
      key: ValueKey<String>('remote_video_cloud_badge_$safeKey'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Icon(Icons.cloud_outlined, size: 13, color: Colors.white),
    );
  }

  /// 页头：与书架/词典统一，用 [HibikiPageHeader] 大标题 + [HibikiIconButton] 动作
  /// （统计 + 导入），保证标题字号与按钮位置三 tab 一致。与书架一致仅在非 Cupertino
  /// 渲染（Cupertino 走平台导航，由 HomePage 外壳承担）。
  Widget _buildPageHeader(bool canImport) {
    return HibikiPageHeader(
      title: t.nav_video,
      actions: <Widget>[
        // 图标顺序与书架完全一致：导入 → 收藏夹 → 统计。书架
        // [reader_hibiki_history_page._buildPageHeader] 把导入按钮放在第一位
        // （buildBookImportButton），收藏夹、统计紧随其后；视频 tab 照此对齐
        // （TODO-162：此前视频把导入放在末尾，与书架不一致）。视频导入仍受
        // [canImport] 门控（仅视频 tab 才有导入入口），这里只调整位置不改门控。
        // 宽窗（非 compact）时四个动作展开成「图标+文字」药丸（用户 mockup：把
        // 「导入视频、媒体库」等按钮可展开时展开）；窄窗自动回落纯图标。
        if (canImport)
          HibikiIconButton(
            tooltip: t.video_import_action,
            label: t.video_import_action,
            icon: Icons.add,
            onTap: _openImport,
          ),
        if (canImport)
          HibikiIconButton(
            tooltip: t.anime_download_title,
            label: t.anime_download_title,
            icon: Icons.travel_explore,
            onTap: _openAnimeDownload,
          ),
        if (canImport)
          HibikiIconButton(
            tooltip: t.media_source_manage_title,
            label: t.media_source_manage_title,
            icon: Icons.folder_copy_outlined,
            onTap: _openManageSources,
          ),
        HibikiIconButton(
          tooltip: t.collections,
          label: t.collections,
          icon: Icons.collections_bookmark_outlined,
          onTap: _openCollections,
        ),
        HibikiIconButton(
          tooltip: t.video_statistics,
          label: t.video_statistics,
          icon: Icons.bar_chart_outlined,
          onTap: _openStatistics,
        ),
      ],
    );
  }

  /// 长按 / 桌面右键远端视频卡：弹与本地视频卡一致的封面背景动作面板
  /// （[MediaItemDialogFrame] 复用，不重写）。播放仍由卡片短按 [_openRemote] 负责。
  ///
  /// 动作：
  /// * 「下载」→ 复用 [_downloadRemote]（与封面下载按钮同一入口，内部已去重）。
  /// * 「信息」→ 弹基本元数据（标题 + 是否含字幕）。
  ///
  /// 删除：远端视频是 host/client 模型（client 不存视频，只从 host 流式播放），
  /// [RemoteVideoClient] / [HibikiClientSyncBackend] 均无 deleteRemoteVideo 能力，
  /// 故不提供删除动作（真实能力边界，非掩盖）。
  void _showRemoteVideoDialog(RemoteVideoInfo video) {
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
      ),
    );
  }

  /// 展示远端视频的基本元数据（标题 + 是否含字幕）。纯信息弹窗。
  void _showRemoteVideoInfo(RemoteVideoInfo video) {
    showAppDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(video.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (video.hasSubtitle) Text(t.remote_video_info_has_subtitle),
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

  /// 标签筛选栏：与书架完全一致——复用 [HibikiTagFilterBar]（内联 chip 点选筛选、
  /// 长按拖拽重排、末尾「管理标签」齿轮 + 「批量选择」动作）。共享
  /// [selectedTagIdsProvider] 与书架联动；批量选择动作经 [onToggleSelectionMode]
  /// 与书架对齐（TODO-063：此前视频 tab 没传，缺了「标签设置旁的选择」）。
  ///
  /// 渲染条件：与书架 [reader_hibiki_history_page._buildTagBar] 一致——**永远渲染
  /// 整栏**（不再「无标签隐藏」），批量选择按钮才能常驻露出（否则空标签库点不到
  /// 批量入口、无法批量删除）。组件内部「管理标签」齿轮仍只在有标签时显示，故无
  /// 标签时整栏只剩「批量选择」按钮。
  Widget _buildTagFilterBar(List<BookTagRow> tags) {
    return HibikiTagFilterBar(
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

  Widget _buildEmpty() {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.movie_outlined, size: 56, color: colors.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            t.video_library_empty,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
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

  /// 连续散视频段落的 [SliverGrid]（TODO-654：随主 [CustomScrollView] 滚动；
  /// 网格 delegate 与远端区一致）。UI v2 Phase C 后合集不再进网格（渲染成全宽
  /// 横排行），本网格只装散视频单卡。
  /// 视频卡总高 = 16:9 封面高（[cardWidth] × 9/16）+ 文字块（标题 2 行 + 观看进度行
  /// + 内边距）。文字块 [_kVideoCardTextBlock] = 83，在 cardWidth=240 时回到旧的固定
  /// 218，向后兼容；卡变窄时封面等比缩，不再出现固定卡高下的封面上下留白。散卡网格
  /// [mainAxisExtent] 与合集横排行 [CollectionShelfRow.rowHeight] 共用此高，保持逐像素同尺寸。
  static double _videoCardExtent(double cardWidth) =>
      cardWidth * 9 / 16 + _kVideoCardTextBlock;

  /// 视频卡封面下方文字块的固定高度（标题 2 行 + 观看进度行 + 内边距）。
  static const double _kVideoCardTextBlock = 83;

  Widget _buildLooseVideoGridSliver(
    List<_VideoLooseCard> loose,
    EdgeInsetsGeometry padding,
    ({int columns, double cardWidth}) cardLayout,
  ) {
    return SliverPadding(
      padding: padding,
      sliver: SliverGrid.builder(
        // FixedCrossAxisCount + 统一卡宽（unifiedShelfCardLayout）：散卡 cell 与
        // 合集横排行成员卡逐像素同尺寸（用户实报合集卡大一截）。卡高随卡宽按
        // 16:9 封面联动（_videoCardExtent），窄卡不再残留固定 218 的封面上下留白。
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cardLayout.columns,
          mainAxisExtent: _videoCardExtent(cardLayout.cardWidth),
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        itemCount: loose.length,
        itemBuilder: (BuildContext context, int i) => loose[i].build(),
      ),
    );
  }

  /// 打开合集详情页（Jellyfin 式）。有序成员从 [HibikiDatabase.getCollectionItems] 解析，
  /// 点某集经 playlistCollectionId 进播放器带剧集面板/上下集/连播；写库后重载库页。
  void _openCollectionDetail(MediaCollectionRow collection) {
    final VideoBookRepository repo = widget.repo;
    final HibikiDatabase db = ref.read(appProvider).database;
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
              if (m.mediaType != 'video') continue;
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
    final HibikiCard hibikiCard = HibikiCard(
      key: ValueKey<String>('home_video_${book.bookUid}'),
      focusId: HibikiFocusId('home-video-${book.bookUid}'),
      padding: EdgeInsets.zero,
      selected: selected,
      // 选择态：点击切换勾选、长按禁用（与书架 _buildBookCard 一致）。成员卡
      // （selectable=false）多选态照常开播、不切换选中。
      onTap: showSelection
          ? () => _toggleSelection(book.bookUid)
          : () => _open(book, playlistCollectionId: playlistCollectionId),
      // 长按 / 桌面右键都弹管理菜单，与书架书卡（_bookCardShell）、远端视频卡
      // （_buildRemoteVideoCard）一致——本地视频卡此前只挂了 onLongPress、漏了
      // onSecondaryTap，故桌面右键本地视频卡无反应（BUG-758）。
      onLongPress: _selectionMode ? null : () => _showVideoMenu(book),
      onSecondaryTap: _selectionMode ? null : () => _showVideoMenu(book),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                _buildCover(book),
                if (tags.isNotEmpty)
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
                    child: _buildSelectionCheck(selected),
                  ),
                if (selected)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withValues(alpha: 0.12),
                        ),
                      ),
                    ),
                  ),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
            child: Text(
              book.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          // UI v2 Phase D：观看进度文字外显（mockup 卡片下的进度/上次观看行）。
          // 只显示可靠数据：已看完 / 已看至 mm:ss（无总时长列，不显示百分比）+
          // 上次观看日期（watch-stats 有该 title 时）；全无痕迹不渲染本行。
          if (_buildCardWatchMeta(book) case final String meta
              when meta.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
              child: Text(
                meta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HibikiDesignTokens.of(context).type.metadata,
              ),
            )
          else
            const SizedBox(height: 4),
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
      child: card,
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

  /// 批量选择勾选标记：选中实心对勾，未选空心圆（与书架 _buildBookCard 一致）。
  Widget _buildSelectionCheck(bool selected) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final Color selectionColor = tokens.surfaces.primary;
    return IgnorePointer(
      child: Container(
        decoration: BoxDecoration(
          color: selected
              ? selectionColor
              : tokens.surfaces.page.withValues(alpha: 0.7),
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? selectionColor : tokens.surfaces.outline,
            width: 1.5,
          ),
        ),
        padding: EdgeInsets.all(tokens.spacing.gap / 4),
        child: Icon(
          Icons.check,
          size: tokens.spacing.gap * 1.75,
          color: selected
              ? Theme.of(context).colorScheme.onPrimary
              : Colors.transparent,
        ),
      ),
    );
  }

  /// 批量操作栏（底部，仅选择态显示）：选中计数 + 全选 / 反选 + 打标签 + 删除。
  /// 与书架 [reader_hibiki_history_page._buildBatchActionBar] 对齐。
  Widget _buildBatchActionBar() {
    final ThemeData theme = Theme.of(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
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
              HibikiIconButton(
                key: const ValueKey<String>('home_video_batch_combine'),
                enabled: canCombine,
                onTap: _batchCombineIntoSeries,
                // 组合成系列用 playlist_add，与页头「收藏夹」入口的
                // collections_bookmark_outlined 区分开（二者语义无关，避免同图标歧义）。
                icon: Icons.playlist_add,
                tooltip: t.combine_into_series,
              ),
              SizedBox(width: tokens.spacing.gap / 2),
              HibikiIconButton(
                // 打标签只作用于散卡媒体（合集无直接标签），故按散卡选中集可用态。
                enabled: _selectedUids.isNotEmpty,
                onTap: _batchShowTagPicker,
                icon: Icons.sell_outlined,
                tooltip: t.tag_label,
              ),
              SizedBox(width: tokens.spacing.gap / 2),
              HibikiIconButton(
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

  /// 播放列表角标：右上角半透明胶囊「▶ N集」，与单视频卡一眼区分（C 需求②）。
  Widget _buildPlaylistBadge(int episodeCount) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.playlist_play, size: 14, color: Colors.white),
          const SizedBox(width: 3),
          Text(
            t.video_playlist_episodes(count: episodeCount),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
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
            child: HibikiTagChip(label: tag.name, color: Color(tag.colorValue)),
          ),
        if (overflow > 0) HibikiTagChip(label: '+$overflow'),
      ],
    );
  }

  Widget _buildCover(VideoBookRow book) {
    final String? cover = book.coverPath;
    if (cover != null && File(cover).existsSync()) {
      return Image.file(
        File(cover),
        // TODO-616 phase C: 本地视频封面同样用 contain（封面卡槽比 16:9 源更窄，
        // cover 会裁左右），完整显示不裁切。
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => _coverPlaceholder(),
      );
    }
    return _coverPlaceholder();
  }

  Widget _coverPlaceholder() {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colors.surfaceContainer,
      child: Center(
        child: Icon(Icons.movie_outlined,
            size: 40, color: colors.onSurfaceVariant),
      ),
    );
  }
}

/// 视频批量打标签的三态意图：保持不变 / 添加该标签 / 移除该标签。
enum _VideoBatchTagIntent { keep, add, remove }

/// 视频 tab 批量打标签对话框（TODO-063）。对一组选中视频书（扁平 bookUid）逐标签
/// 设三态意图，应用时对每个 bookUid 调 [HibikiDatabase.addTagToVideoBook] /
/// [HibikiDatabase.removeTagFromVideoBook]。与书架的 `_BatchTagPickerDialog` 同语义，
/// 但视频是单一 uid 集合（无 epub `mediaIdentifier` + `srt_` 双类分支），故独立、更简单。
class _VideoBatchTagPickerDialog extends StatefulWidget {
  const _VideoBatchTagPickerDialog({
    required this.allTags,
    required this.selectedUids,
    required this.database,
  });

  final List<BookTagRow> allTags;
  final Set<String> selectedUids;
  final HibikiDatabase database;

  @override
  State<_VideoBatchTagPickerDialog> createState() =>
      _VideoBatchTagPickerDialogState();
}

class _VideoBatchTagPickerDialogState
    extends State<_VideoBatchTagPickerDialog> {
  final Set<int> _addTagIds = <int>{};
  final Set<int> _removeTagIds = <int>{};

  Future<void> _apply() async {
    final HibikiDatabase db = widget.database;

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
      HibikiToast.show(
        msg: t.batch_tag_added_video(
          name: tag.name,
          n: widget.selectedUids.length,
        ),
      );
    }
    for (final int tagId in _removeTagIds) {
      final BookTagRow tag =
          widget.allTags.firstWhere((BookTagRow row) => row.id == tagId);
      HibikiToast.show(
        msg: t.batch_tag_removed_video(
          name: tag.name,
          n: widget.selectedUids.length,
        ),
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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

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

/// 多端库联合视图（spec §2.1）：视频库散卡区一个待渲染单元 = 排序键 + 卡片构造。
/// 本地散卡（[_buildCard]）与远端占位卡（[_buildRemoteVideoCard]）用同一列表按当前
/// 排序模式混排（[compareShelfSortKeys]）。构造用惰性闭包，排序后再取需要的那些。
class _VideoLooseCard {
  const _VideoLooseCard({required this.sortKey, required this.build});

  final ShelfSortKey sortKey;
  final Widget Function() build;
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
