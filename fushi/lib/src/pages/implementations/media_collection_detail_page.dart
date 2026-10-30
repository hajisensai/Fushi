import 'dart:async' show Completer, Timer, unawaited;
import 'dart:io';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:fushi/src/media/video/disc/disc_session_entry.dart';
import 'package:fushi/src/media/video/disc/disc_session_launcher.dart';
import 'package:fushi/src/media/video/disc/remote_disc_actions.dart';
import 'package:fushi/src/media/video/disc/remote_disc_menu_source.dart';
import 'package:fushi/src/utils/components/fushi_bottom_action_bar.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/library_reorder.dart';
import 'package:fushi/src/media/collections/collection_owned_subscriptions.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:path/path.dart' as p;
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi_engine/media/collections/collection_asset_reclaim.dart';
import 'package:fushi_engine/media/collections/collection_cover.dart'
    show collectionOwnCoverCandidates;
import 'package:fushi/src/media/collections/collection_continue.dart';
import 'package:fushi/src/media/collections/collection_detail_layout.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/media/collections/collection_drag.dart'
    show CollectionAddOutcome, addMediaRefToCollection;
import 'package:fushi/src/media/drag_drop/drop_classification.dart';
import 'package:fushi/src/media/async_file_existence_cache.dart';
import 'package:fushi/src/media/drag_drop/fushi_file_drop_target.dart';
import 'package:fushi/src/media/video/video_import_dialog.dart';
import 'package:fushi/src/media/video/video_duration_pref.dart';
import 'package:fushi/src/media/video/metadata/video_episode_binding_dialog.dart';
import 'package:fushi/src/media/collections/collection_episode_slot.dart';
import 'package:fushi/src/media/media_cover_service.dart';
import 'package:fushi/src/media/collections/collection_ai_order.dart'
    show CollectionAiClientFactory;
import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:fushi/src/media/collections/collection_one_key_sort.dart'
    show CollectionSortMeta, compareCollectionMembers;
import 'package:fushi/src/media/collections/collection_relation.dart';
import 'package:fushi/src/media/collections/collection_scrape_metadata_compat.dart';
import 'package:fushi_engine/media/collections/collection_season_groups.dart';
import 'package:fushi/src/media/media_cover_source.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi/src/media/video/anilist_client.dart' show AniListMedia;
import 'package:fushi/src/media/video/cover_ui/episode_rename_confirm_dialog.dart';
import 'package:fushi/src/media/video/cover_ui/video_specs_panel.dart';
import 'package:fushi/src/media/video/video_specs_service.dart';
import 'package:fushi/src/media/video/metadata/video_country_display.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_credit_repository.dart';
import 'package:fushi/src/media/video/metadata/video_credit_rail.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_source_metadata_indexer.dart';
import 'package:fushi/src/media/video/stream_video_launch.dart';
import 'package:fushi_engine/media/video/video_local_files.dart'
    show localVideoFileCandidates, videoBookHasLocalFiles;
import 'package:fushi/src/media/video/scraper/episode_rename.dart';
import 'package:fushi_engine/media/video/scraper/scraper_types.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_filename_parser.dart';
import 'package:fushi/src/media/library_progress_reset.dart';
import 'package:fushi/src/pages/implementations/library_progress_reset_dialog.dart';
import 'package:fushi/src/pages/implementations/anime_download_dialog.dart';
import 'package:fushi/src/pages/implementations/collection_detail_shared.dart';
import 'package:fushi/src/pages/implementations/media_item_dialog_page.dart'
    show
        DialogActionGroup,
        DialogDangerAction,
        DialogListAction,
        MediaItemDialogFrame,
        showMediaItemActions;
import 'package:fushi/src/pages/implementations/collection_relations_section.dart';
import 'package:fushi/src/pages/implementations/collection_split_dialog.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/subtitle_collection_panel.dart'
    show SubtitleCollectionPanel;
import 'package:fushi/src/pages/implementations/subtitle_workbench_page.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'package:fushi/src/pages/implementations/interconnect_download_tasks_page.dart'
    show openInterconnectDownloadTasksPage;
import 'package:fushi/src/sync/remote_cover_image.dart';
import 'package:fushi/src/sync/remote_download_progress_badge.dart';
import 'package:fushi/src/utils/components/fushi_adaptive_action_strip.dart';
import 'package:fushi/src/utils/components/fushi_reorderable_grid.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/reveal_in_file_manager.dart'
    show currentRevealHost, revealFirstOf;
import 'package:fushi/utils.dart';
import 'package:fushi/src/media/selection/media_selection_controller.dart';
import 'package:fushi/src/media/selection/selection_gestures.dart';
import 'package:fushi/src/media/video/video_watched_marks.dart';
import 'package:fushi/src/sync/remote_video_client.dart'
    show RemoteVideoPlayedMark;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_lock_dialog.dart';
import 'package:fushi/src/asr_host/asr_host.dart' show isAsrSupported;
import 'package:fushi/src/media/video/subtitle/app_video_subtitle_service.dart'
    show
        AppVideoSubtitleService,
        AppVideoSubtitleTarget,
        AppVideoSubtitleTargetNotFound,
        appVideoSubtitleService;
import 'package:fushi/src/media/video/subtitle/video_subtitle_generate_sheet.dart'
    show PrefsRepoVideoSubtitleGeneratePrefs, showVideoSubtitleGenerateSheet;
import 'package:fushi/src/pages/implementations/ai_settings_route.dart'
    show pushAiSettingsPage;
import 'package:fushi/src/media/video/subtitle/remote_video_subtitle_service.dart'
    show
        RemoteVideoSubtitleEpisode,
        RemoteVideoSubtitleTarget,
        appRemoteVideoSubtitleService;
import 'package:fushi/src/media/video/subtitle/remote_video_subtitle_sheet.dart'
    show showRemoteVideoSubtitleSheet;
import 'package:fushi/src/media/links/media_link_entries.dart'
    show MediaLinkEntry;
import 'package:fushi/src/media/links/media_link_inference_host.dart'
    show mediaLinkInferCallback;
import 'package:fushi/src/media/links/media_link_opener.dart'
    show mediaLinkSearchAction, openMediaLinkEntry;
import 'package:fushi/src/media/links/media_links_section.dart'
    show MediaLinksSection;

/// 统一合集 Phase 4：合集详情页（Jellyfin 式）。playlist 合集 = 有序剧集列表：点某集从
/// 该集开始播放（带剧集面板 / 上下集 / 连播，调用方经 playlistCollectionId 打开播放器）；
/// 顶部「播放」按钮据各集进度推导「继续看」位置（[continueMemberIndex]）。可重命名 / 删除
/// 合集（删合集只解链、绝不删条目本身）。
class MediaCollectionDetailPage extends StatefulWidget {
  const MediaCollectionDetailPage({
    required this.database,
    this.videoSpecs,
    required this.collection,
    required this.loadEpisodes,
    required this.onOpenEpisode,
    this.remote,
    required this.onChanged,
    this.onDeleteMembersMedia,
    this.deleteMembersLocalFilesSubtitle,
    this.deleteMembersStatisticsSubtitle,
    this.onRescrapeCollection,
    this.onChooseTmdbOrdering,
    this.onPickOnlineCover,
    this.collectionAiSettings,
    this.aiClientFactory,
    this.discMenuProbe,
    super.key,
  });

  final FushiDatabase database;

  /// 测试注入：判定一张盘在本机能否开菜单。生产为 null，走 [probeLocalDiscMenu]
  /// （读一次 index.bdmv）。
  final Future<DiscMenuUnavailableReason?> Function(DiscRef disc)?
  discMenuProbe;

  /// 「排序」菜单的「AI 排序」用的 AI 指派来源。null = 不显示该项（AI 模块关着，
  /// 调用方按 `isAiModuleEnabled` 求值后传）。构造注入的理由同 [videoSpecs]。
  final AiSettingsSource? collectionAiSettings;

  /// 测试注入假 AI 客户端；生产为 null（默认构造）。
  final CollectionAiClientFactory? aiClientFactory;

  /// 视频规格服务（v95）。**构造注入而不是从 riverpod 取**：本页是普通
  /// StatefulWidget，它的既有 widget 测试没有也不需要 `ProviderScope`，在页内塞
  /// ConsumerWidget 会让那些测试全部抛。null = 不显示规格（测试默认如此）。
  final VideoSpecsService? videoSpecs;
  final MediaCollectionRow collection;

  /// 解析本合集**有序**成员槽（调用方持 repo + collectionId；见
  /// [loadCollectionEpisodeSlots]）。
  ///
  /// 返回的是 [CollectionEpisodeSlot] 而不是 `VideoBookRow`：合集清单是跨端 union，
  /// 互联客户端本地的成员行里必然有「只在 host 上」的集。把它窄化成本地行会让客户端
  /// 把整个合集判空（BUG-1704）。
  final Future<List<CollectionEpisodeSlot>> Function() loadEpisodes;

  /// 打开某集（调用方用 playlistCollectionId 进播放器带面板）。
  final void Function(VideoBookRow episode) onOpenEpisode;

  /// 远端上下文（列远端成员 / 流播 / 取封面）；null = 纯本地视图。
  final CollectionRemoteContext? remote;

  /// 改名 / 删除后刷新库页。
  final VoidCallback onChanged;

  /// 「删除合集」时可选连同各集视频本体一起删（默认不删，保持只解链语义）。
  /// 调用方（持 [VideoBookRepository]）注入：按 [VideoBookRow] 删视频 DB 行 +
  /// app 拥有副本（封面/字幕），**保留用户原始视频文件**（导入时只存路径从不复制）。
  /// null = 详情页不提供该选项（确认框不显示复选框），退回纯解链删除。
  final Future<void> Function(
    List<VideoBookRow> members,
    bool deleteLocalFiles,
    bool deleteStatistics,
  )?
  onDeleteMembersMedia;

  /// 非 null 时，「同时删除其中的视频」勾选下再给一行「同时删除本地文件」二级
  /// 勾选，其状态经 [onDeleteMembersMedia] 的 `deleteLocalFiles` 参数落地。
  /// null = 该合集没有可删的本机原件（如全是远端流），不摆这一行。
  final String? deleteMembersLocalFilesSubtitle;

  /// 非 null 时再给一行「同时删除统计数据」二级勾选（默认不勾、不被记忆），其状态
  /// 经 [onDeleteMembersMedia] 的 `deleteStatistics` 参数落地。null = 该入口不提供。
  final String? deleteMembersStatisticsSubtitle;

  /// 「重新刮削资料与封面」：由库页注入（刮削 controller 的生命周期归 HomePage，
  /// 详情页不自己造）。null = 当前装配拿不到 controller，菜单项整条不渲染。
  final Future<void> Function(MediaCollectionRow collection)?
  onRescrapeCollection;

  /// 「TMDB 集编排」（备选排序，Shoko `PreferredAlternateOrderingID`）：同样由
  /// 库页注入（要刮削 controller 重刮）。null = 菜单项不渲染。
  final Future<void> Function(MediaCollectionRow collection)?
  onChooseTmdbOrdering;

  /// 「在线搜索封面」（BUG-2999）：在资料源里搜作品、取它的封面图，返回下载好的
  /// 临时文件（取消 / 失败返回 null，失败提示由回调自己给）。由库页注入——候选
  /// 搜索要刮削 controller，详情页不自造。null = 菜单项不渲染。
  final Future<File?> Function(String workTitle)? onPickOnlineCover;

  @override
  State<MediaCollectionDetailPage> createState() =>
      _MediaCollectionDetailPageState();
}

class _MediaCollectionDetailPageState extends State<MediaCollectionDetailPage>
    with
        CollectionDetailShared<MediaCollectionDetailPage>,
        LibraryReorderHost<MediaCollectionDetailPage>,
        TickerProviderStateMixin {
  late String _name;

  /// 封面 / 海报 / 附加图缩略图的「文件在不在」异步记忆表（BUG-3756）：合集海报常落在
  /// 网络盘（rclone / SMB 挂载）上，build 里同步 stat 一次就能冻结 UI 与同 isolate 的
  /// 互联 host 数秒。build 只读这张表，没见过的路径后台 async 探测、落定后重建。
  late final AsyncFileExistenceCache _coverExists = AsyncFileExistenceCache(
    onChanged: () {
      if (mounted) setState(() {});
    },
  );

  /// 本合集**有序**成员槽（本地行 + 只在对端的远端占位）——本页唯一的成员真相源。
  List<CollectionEpisodeSlot> _slots = const <CollectionEpisodeSlot>[];
  bool _loading = true;

  /// 成员里的**本地行**子集，保持落盘序。写本地库的管理动作（批量字幕 / 改集名 /
  /// 补缺集 / 删本体 / 拆分标题）一律取它——远端槽在本机没有可写的行。
  List<VideoBookRow> get _members => <VideoBookRow>[
    for (final CollectionEpisodeSlot slot in _slots)
      if (slot.local case final VideoBookRow row) row,
  ];

  /// 原盘入口（BD/DVD 原盘交互改造第 5 项）：本合集背后的盘根（按盘号 / 目录名
  /// 排序）。原盘入口由本页自己提供，不再靠调用方记得传回调——此前「相关作品」
  /// 进来的那条路径就因为没传而看不到原盘按钮。
  List<DiscRef> _discs = const <DiscRef>[];

  /// 原盘成员只在对端（互联 host）上（远端原盘第二期：能流式就开菜单）。
  bool _hasRemoteDisc = false;

  /// 远端原盘探测得到的盘源（能流式开菜单时非 null）。
  RemoteDiscMenuSource? _remoteDiscSource;

  /// 这台 host 能被遥控着在它那边打开原盘菜单（「在 PC 上打开」）。
  bool _hostCanOpenDisc = false;

  /// 第一条远端原盘成员（探测 / 遥控用它的 id 指认这张盘）。
  RemoteVideoInfo? get _firstRemoteDiscMember {
    for (final CollectionEpisodeSlot slot in _slots) {
      if (slot.local == null && isRemoteDiscMember(slot.remote)) {
        return slot.remote;
      }
    }
    return null;
  }

  /// 主按钮那张盘（最近看过的那张）在本机开不开得了菜单；null = 能开 / 未探测。
  DiscMenuUnavailableReason? _discUnavailable;

  /// 成员里只在对端的那些（按序），供远端连播列表与起播下标换算。
  List<RemoteVideoInfo> get _remoteMembers => <RemoteVideoInfo>[
    for (final CollectionEpisodeSlot slot in _slots)
      if (slot.remote case final RemoteVideoInfo info) info,
  ];

  /// 分季：成员 [CollectionEpisodeSlot.entryKey] → 分组键，**由文件名现场派生**
  /// （不落库，数据模型见 collection_season_groups.dart）。远端槽没有本地路径，用
  /// host 下发的标题（host 端标题默认即文件名）。键不随重排变化，故只在 [_reload] 重算。
  Map<String, String> _groupKeyByEntry = const <String, String>{};

  /// 由 [_slots] + [_groupKeyByEntry] 派生的分节（季号升序、PV/特典殿后）。
  /// ≥2 节 → 顶部出季 tab；否则整页与单季合集完全一致（不平白加一层 UI）。
  List<CollectionSeasonSection<CollectionEpisodeSlot>> _sections =
      const <CollectionSeasonSection<CollectionEpisodeSlot>>[];

  /// 季 tab 控制器：只在 ≥2 节时存在，节数变化（移出成员导致某季清空）时重建。
  TabController? _seasonTabs;
  int _selectedSeason = 0;

  /// 集多选（批量标记已看 / 未看）。只用散格（键 = [CollectionEpisodeSlot.entryKey]），
  /// 与库页多选同一个状态机：Shift 区间选、全选、可见性约束都现成。
  final MediaSelectionController _selection = MediaSelectionController();

  /// 初始选季只做一次（落在续播那一季，见 [_rebuildSections]）。之后一律尊重
  /// 用户手选的 tab —— 重排 / 移出成员不得把他弹回别的季。
  bool _seasonSelectionInitialized = false;

  /// 合集行的**当前**快照（DB 才是真相源）。
  ///
  /// `widget.collection` 是进页那一刻的副本：刮削会改写它的 `name` 与 `coverPath`，
  /// 只认进页副本会让详情页停在旧文件夹名 + 旧封面。首帧为 null（还没读到），此时
  /// 回落 `widget.collection` —— 与本改动前逐帧相同。
  MediaCollectionRow? _collectionRow;

  /// 合集级刮削资料（简介/评分/放送/标签，schema v64）；未刮过为 null —— 此时 hero
  /// 回落到「只有标题 + 进度」的旧形态，与本功能引入前一致（BUG-1310）。
  ScrapeMetadata? _scrapeMeta;

  /// 横版背景图源组（本地路径优先，安全目录无法落盘时回落规范表远程 URL）。
  /// 多张时 hero 每 10 秒交叉淡入轮换（Jellyfin 式）。
  List<String> _backdropSources = const <String>[];

  /// 标题 logo 本地路径（透明底 PNG）；有则 hero 用 logo 图替代纯文字标题。
  String? _logoPath;
  String? _logoRemoteUrl;

  /// 背景轮换下标与定时器（单张 / 禁用动效时不启）。
  int _heroBackdropIndex = 0;
  Timer? _backdropRotationTimer;

  /// 集级刮削资料（TODO-2491）：bookUid → `video_scrape_meta` 行，**只含
  /// `episodeNumber` 非空**（真·集级）的行。旧作品级行（v54~v64 把整部简介写进
  /// 每个文件）不进这里——集名/集简介上卡只认集级资料，其余回落文件名现状。
  Map<String, VideoScrapeMetaRow> _episodeMetaByUid =
      const <String, VideoScrapeMetaRow>{};

  /// v77 作品级人物关系；无规范资料时为 null，hero 保持既有 v68 投影形态。
  VideoMetadataWorkCredits? _workCredits;
  VideoMetadataWorkRow? _canonicalWork;

  /// 成员文件 → 绑到它的规范分集行（按季、集有序）。v110 起一文件可绑多集
  /// （AniDB 一文件多集），列表首条是主集；单集文件恒为一条。
  Map<String, List<VideoMetadataEpisodeRow>> _canonicalEpisodesByUid =
      const <String, List<VideoMetadataEpisodeRow>>{};
  String? _canonicalCoverPath;
  String? _canonicalCoverRemoteUrl;

  /// 本合集的附加图组（v68 `media_images`）快照：hero 封面自有层的原盘竖版盘面图
  /// 从这里取（[collectionOwnCoverCandidates]）。
  List<MediaImageRow> _mediaImages = const <MediaImageRow>[];
  List<VideoMetadataTermRow> _workTerms = const <VideoMetadataTermRow>[];
  List<VideoMetadataExtraRow> _workExtras = const <VideoMetadataExtraRow>[];

  /// 播放器记下的各集真实片长（bookUid → 毫秒，BUG-3491，见 video_duration_pref.dart）。
  Map<String, int> _knownDurationsMs = const <String, int>{};

  /// 本页**派出去的播放**还没回来：从播放页返回（本页路由重新成为栈顶）时据此
  /// 重读成员进度（BUG-3491）。
  ///
  /// 本页的进度是 [_reload] 一次读出的快照，此前只在 initState 读一次——看完一集
  /// 返回，集卡、续播高亮、hero「继续看」都还是进页那一刻的数据，要退出详情页
  /// 重进才更新。等不了 `Navigator.push` 的 Future：播放页里换集是
  /// `pushReplacement` / `removeRoute`，第一集被换走时那个 Future 就完成了，用户
  /// 其实还在看第二集。只有「本页路由重新变成栈顶」才是真的回来了。
  bool _awaitingPlaybackReturn = false;

  /// 排序模式（集卡菜单「排序」进入）：触屏按住集卡即拖，见 [LibraryReorderHost]。
  bool _reordering = false;

  void _startReorder() {
    if (mounted) setState(() => _reordering = true);
  }

  void _endReorder() => setState(() => _reordering = false);

  @override
  VoidCallback? get libraryReorderEntry => _startReorder;

  /// 上一次看到的本页路由是否在栈顶（判「被盖住 → 又露出来」的边沿）。
  bool _routeWasCurrent = true;

  /// 本机成员里**从配对设备下载来的副本**（同一个 id 仍在对端清单里）的
  /// entryKey。只有它们给「删除本机副本」：删掉后合集成员行留着，这一集退回
  /// 远端集（反馈 _sZllpFQWm / BUG-3698：iPad 上找不到删下载副本的地方）。用户
  /// 自己导入的本机原件不在其中，不会被这条动作误删。
  Set<String> _peerCopyKeys = const <String>{};

  /// 重算 [_peerCopyKeys]。在 [_reload] 画完之后后台跑、不挡首帧：
  /// [loadCollectionEpisodeSlots] 在全员本地时刻意不问远端清单，这里只在库页
  /// 注入了「删除本机副本」时才问一次（共享远端库缓存，TTL 内不打网络）；拉不到
  /// 清单就当没有副本——宁可不给入口，也不把本机原件当副本删。
  Future<void> _refreshPeerCopyKeys(List<VideoBookRow> members) async {
    final CollectionRemoteContext? remote = widget.remote;
    Set<String> keys = const <String>{};
    if (remote != null &&
        remote.deleteLocalCopy != null &&
        members.isNotEmpty) {
      try {
        final Set<String> remoteIds = <String>{
          for (final RemoteVideoInfo info in await remote.loadRemoteVideos())
            info.id,
        };
        keys = <String>{
          for (final VideoBookRow member in members)
            if (remoteIds.contains(member.bookUid)) member.bookUid,
        };
      } catch (_) {
        keys = const <String>{};
      }
    }
    if (!mounted) return;
    if (setEquals(keys, _peerCopyKeys)) return;
    setState(() => _peerCopyKeys = keys);
  }

  @override
  FushiDatabase get detailDatabase => widget.database;
  @override
  MediaCollectionRow get detailCollection => widget.collection;
  @override
  String get detailName => _name;
  @override
  set detailName(String value) => _name = value;
  @override
  VoidCallback get detailOnChanged => widget.onChanged;

  @override
  void initState() {
    super.initState();
    _name = widget.collection.name;
    _reload();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // ModalRoute.of 依赖路由的 isCurrent：上面压了播放页 / 播放页退回来都会
    // 通知到这里。
    final bool current = ModalRoute.of(context)?.isCurrent ?? true;
    final bool returned = current && !_routeWasCurrent;
    _routeWasCurrent = current;
    if (returned && _awaitingPlaybackReturn) {
      _awaitingPlaybackReturn = false;
      unawaited(_reload());
    }
  }

  @override
  void dispose() {
    _coverExists.dispose();
    _backdropRotationTimer?.cancel();
    _seasonTabs?.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final List<CollectionEpisodeSlot> slots = await widget.loadEpisodes();
    // 下面这一整段刮削 / 元数据解析全是**本地库**的事（sourceId 索引、集级刮削行、
    // 附加图），远端槽在本机没有行可查，故按本地子集跑，与远端支持引入前逐字节相同。
    final List<VideoBookRow> members = <VideoBookRow>[
      for (final CollectionEpisodeSlot slot in slots)
        if (slot.local case final VideoBookRow row) row,
    ];
    // 刮削资料与合集行一起重取：刮削**经用户确认后可能回写合集名**
    //（旧刮削流程的用户确认改名），而 widget.collection 是进页时的
    // 快照，只认它会让详情页标题停在旧文件夹名。
    final CollectionScrapeMetaRow? metaRow = await widget.database
        .getCollectionScrapeMeta(widget.collection.id);
    final ScrapeMetadata? decoded = decodeCollectionScrapeMeta(metaRow);
    // 附加图组（v68）：横版背景（轮换序）与标题 logo。
    final List<MediaImageRow> imageRows = await widget.database
        .getMediaImagesForCollection(widget.collection.id);
    final VideoMetadataWorkRow? canonicalWork = await widget.database
        .resolveVideoMetadataWorkForCollection(widget.collection.id);
    // 没有规范作品行：兜底给成员所在来源建一次本地索引。**不在这里同步等**——
    // 索引一个来源要规划全来源的作品、逐部 stat NFO，曾经每打开一次详情页就在
    // 转场期间把整个来源重扫一遍（打开慢、转场掉帧）。改成先把已有数据画出来，
    // 转场结束后在后台做、本会话每个来源只做一次，建出作品行再刷新一次。
    if (canonicalWork == null) {
      _scheduleSourceIndexing(<int>{
        for (final VideoBookRow member in members)
          if (member.sourceId != null) member.sourceId!,
      });
    }
    final VideoMetadataWorkCredits? workCredits =
        await VideoMetadataCreditRepository(
          widget.database,
        ).forCollection(widget.collection.id);
    final List<VideoMetadataTermRow> workTerms = canonicalWork == null
        ? const <VideoMetadataTermRow>[]
        : await widget.database.getVideoMetadataTermsForWork(canonicalWork.id);
    final Map<String, List<VideoMetadataEpisodeRow>> canonicalEpisodes =
        <String, List<VideoMetadataEpisodeRow>>{};
    final List<VideoMetadataImageRow> canonicalImages = canonicalWork == null
        ? const <VideoMetadataImageRow>[]
        : await widget.database.getVideoMetadataImages(
            workId: canonicalWork.id,
          );
    if (canonicalWork != null) {
      for (final VideoMetadataSeasonRow season
          in await widget.database.getVideoMetadataSeasons(canonicalWork.id)) {
        for (final VideoMetadataEpisodeRow episode
            in await widget.database.getVideoMetadataEpisodes(season.id)) {
          if (episode.bookUid case final String uid) {
            (canonicalEpisodes[uid] ??= <VideoMetadataEpisodeRow>[]).add(
              episode,
            );
          }
        }
      }
    }
    final List<VideoMetadataExtraRow> workExtras = canonicalWork == null
        ? const <VideoMetadataExtraRow>[]
        : await widget.database.getVideoMetadataExtras(canonicalWork.id);
    final Set<String> localExtraUids = <String>{
      for (final VideoMetadataExtraRow extra in workExtras)
        if (extra.bookUid != null) extra.bookUid!,
    };
    // 花絮/特典（canonical extras）不进集列表——它们在 [_buildExtrasSection] 单列。
    final List<CollectionEpisodeSlot> episodeSlots = slots
        .where(
          (CollectionEpisodeSlot slot) =>
              !localExtraUids.contains(slot.entryKey),
        )
        .toList(growable: false);
    // 集级刮削资料（一集一行、episodeNumber 非空才算集级；见 [_episodeMetaByUid]）。
    // 合集没有自己的作品行时（成员按 AniDB 作品拆成了各自的电影作品），成员自己
    // 的作品级投影（episodeNumber 为空）也拿来当卡片标题 / 简介——那就是这部
    // 电影的资料。
    // 一次批量取完（曾经逐集一次往返，长篇几百集就是几百次查询）。
    final Map<String, VideoScrapeMetaRow> allMeta = await widget.database
        .getVideoScrapeMetaForBooks(
          members.map((VideoBookRow member) => member.bookUid),
        );
    final Map<String, VideoScrapeMetaRow> episodeMeta =
        <String, VideoScrapeMetaRow>{
          for (final MapEntry<String, VideoScrapeMetaRow> entry
              in allMeta.entries)
            if (entry.value.episodeNumber != null || canonicalWork == null)
              entry.key: entry.value,
        };
    final MediaCollectionRow? fresh = await widget.database
        .getMediaCollectionById(widget.collection.id);
    final Map<String, int> knownDurations = await loadKnownVideoDurationsMs(
      widget.database,
    );
    final List<DiscRef> discs = collectDiscRefs(members);
    final bool remoteDisc =
        discs.isEmpty &&
        slots.any(
          (CollectionEpisodeSlot slot) =>
              slot.local == null && isRemoteDiscMember(slot.remote),
        );
    if (!mounted) return;
    setState(() {
      _discs = discs;
      _hasRemoteDisc = remoteDisc;
      _knownDurationsMs = knownDurations;
      _slots = episodeSlots;
      _groupKeyByEntry = <String, String>{
        for (final CollectionEpisodeSlot slot in episodeSlots)
          slot.entryKey: collectionGroupKeyForFilename(slot.filename),
      };
      _rebuildSections();
      _episodeMetaByUid = episodeMeta;
      _canonicalEpisodesByUid = canonicalEpisodes;
      _workCredits = workCredits;
      _canonicalWork = canonicalWork;
      _workTerms = workTerms;
      _workExtras = workExtras;
      _scrapeMeta = decoded;
      _mediaImages = imageRows;
      _canonicalCoverPath = canonicalImages
          .where(
            (VideoMetadataImageRow row) =>
                row.kind == VideoMetadataImageKind.cover.name &&
                row.localPath?.isNotEmpty == true,
          )
          .map((VideoMetadataImageRow row) => row.localPath!)
          .firstOrNull;
      _canonicalCoverRemoteUrl = canonicalImages
          .where(
            (VideoMetadataImageRow row) =>
                row.kind == VideoMetadataImageKind.cover.name &&
                row.remoteUrl.isNotEmpty,
          )
          .map((VideoMetadataImageRow row) => row.remoteUrl)
          .firstOrNull;
      _backdropSources = <String>{
        for (final VideoMetadataImageRow row in canonicalImages)
          if (row.kind == VideoMetadataImageKind.backdrop.name &&
              row.localPath?.isNotEmpty == true)
            row.localPath!,
        for (final MediaImageRow row in imageRows)
          if (row.kind == MediaImageKind.backdrop.dbValue) row.path,
        for (final VideoMetadataImageRow row in canonicalImages)
          if (row.kind == VideoMetadataImageKind.backdrop.name &&
              row.remoteUrl.isNotEmpty)
            row.remoteUrl,
      }.toList(growable: false);
      _logoPath = canonicalImages
          .where(
            (VideoMetadataImageRow row) =>
                row.kind == VideoMetadataImageKind.logo.name &&
                row.localPath?.isNotEmpty == true,
          )
          .map((VideoMetadataImageRow row) => row.localPath!)
          .firstOrNull;
      _logoRemoteUrl = canonicalImages
          .where(
            (VideoMetadataImageRow row) =>
                row.kind == VideoMetadataImageKind.logo.name &&
                row.remoteUrl.isNotEmpty,
          )
          .map((VideoMetadataImageRow row) => row.remoteUrl)
          .firstOrNull;
      for (final MediaImageRow row in imageRows) {
        if (_logoPath == null &&
            row.kind == MediaImageKind.logo.dbValue &&
            row.path.isNotEmpty) {
          _logoPath = row.path;
          break;
        }
      }
      _heroBackdropIndex = 0;
      if (fresh != null) {
        _collectionRow = fresh;
        _name = fresh.name;
      }
      _loading = false;
    });
    unawaited(_refreshPeerCopyKeys(members));
    unawaited(_probeDiscMenu());
    _syncBackdropRotation();
  }

  /// 探测主按钮那张盘能不能开菜单（只读一次 index.bdmv，不启动 Java）。远端盘
  /// （第二期）向 host 签发一次盘目录共享、读共享里的 index.bdmv：能流式就开菜单，
  /// 不能时给出确切原因（对端版本过低 / DVD 文件夹形态 / 移动端 BD-J / 连不上）。
  Future<void> _probeDiscMenu() async {
    if (_hasRemoteDisc) {
      await _probeRemoteDiscMenu();
      return;
    }
    final DiscRef? disc = preferredDisc(_discs);
    final DiscMenuUnavailableReason? reason = disc == null
        ? null
        : await (widget.discMenuProbe ?? probeLocalDiscMenu)(disc);
    if (!mounted) return;
    if (reason != _discUnavailable) setState(() => _discUnavailable = reason);
  }

  Future<void> _probeRemoteDiscMenu() async {
    final RemoteDiscActions? actions = widget.remote?.discActions;
    final RemoteVideoInfo? member = _firstRemoteDiscMember;
    if (actions == null || member == null) {
      if (!mounted) return;
      setState(() {
        _remoteDiscSource = null;
        _discUnavailable = DiscMenuUnavailableReason.remote;
      });
      return;
    }
    final Future<bool> Function()? hostCheck = actions.hostCanOpenDisc;
    if (hostCheck != null) {
      unawaited(
        hostCheck().then((bool can) {
          if (mounted && can != _hostCanOpenDisc) {
            setState(() => _hostCanOpenDisc = can);
          }
        }, onError: (Object _) {}),
      );
    }
    final RemoteDiscProbe probe = await probeRemoteDiscMenu(
      actions: actions,
      videoId: member.id,
      title: _name,
      platform: currentDiscMenuPlatform(),
      bdjComponentInstallable: currentBdjComponentInstallable(),
      downloadToDevice: _downloadRemoteDiscToDevice,
    );
    if (!mounted) return;
    setState(() {
      _remoteDiscSource = probe.source;
      _discUnavailable = probe.unavailable;
    });
  }

  /// 流式会话缓冲提示里的「下载到本机」：与「下载远端集」同一入口（原盘成员按盘
  /// 整体下载，见库页 `_prepareRemoteDiscDownloads`）。
  Future<void> _downloadRemoteDiscToDevice() async {
    final Future<void> Function(MediaCollectionRow, List<RemoteVideoInfo>)?
    download = widget.remote?.downloadMembers;
    if (download == null) return;
    await download(_collectionRow ?? widget.collection, <RemoteVideoInfo>[
      for (final RemoteVideoInfo info in _remoteMembers)
        if (isRemoteDiscMember(info)) info,
    ]);
  }

  void _openRemoteDisc(RemoteDiscMenuSource source) {
    unawaited(
      openRemoteDiscSession(
        context: context,
        repo: VideoBookRepository(widget.database),
        source: source,
        cover: _heroCover,
      ),
    );
  }

  /// 「在 PC 上打开」：遥控 host 在它那边进原盘会话（复用视频遥控通道）。
  Future<void> _openRemoteDiscOnHost() async {
    final Future<void> Function(String videoId)? open =
        widget.remote?.discActions?.openOnHost;
    final RemoteVideoInfo? member = _firstRemoteDiscMember;
    if (open == null || member == null) return;
    try {
      await open(member.id);
      FushiToast.show(msg: t.video_disc_open_on_host_sent);
    } catch (error, stack) {
      ErrorLogService.instance.log('VideoDiscMenu.openOnHost', error, stack);
      FushiToast.show(
        msg: t.video_disc_open_on_host_failed,
        severity: ToastSeverity.warning,
      );
    }
  }

  bool get _isDiscEntry => _discs.isNotEmpty || _hasRemoteDisc;

  /// 「原盘默认进入菜单」设置；没有 [ProviderScope]（部分 widget 测试）时取默认开。
  bool get _discOpenMenuByDefault => discOpenMenuByDefaultOf(context);

  DiscPrimaryKind get _discPrimaryKind => resolveDiscPrimaryKind(
    hasDisc: _isDiscEntry,
    openMenuByDefault: _discOpenMenuByDefault,
    unavailable: _discUnavailable,
  );

  void _openDisc(DiscRef disc) {
    // 播放页回来时重读进度（见 [_awaitingPlaybackReturn]）。
    _awaitingPlaybackReturn = true;
    unawaited(
      openDiscSession(
        context: context,
        repo: VideoBookRepository(widget.database),
        book: disc.book,
        collectionId: widget.collection.id,
        cover: _heroCover,
      ),
    );
  }

  /// 多盘：选一张再进它的菜单。所选那张开不了菜单时说明原因，不静默降级。
  Future<void> _chooseDisc() async {
    final DiscRef? disc = await showDiscPicker(
      context: context,
      discs: _discs,
      selected: preferredDisc(_discs),
    );
    if (disc == null || !mounted) return;
    final DiscMenuUnavailableReason? reason =
        await (widget.discMenuProbe ?? probeLocalDiscMenu)(disc);
    if (!mounted) return;
    if (reason != null) {
      FushiToast.show(
        msg: discMenuUnavailableText(reason),
        severity: ToastSeverity.warning,
      );
      return;
    }
    _openDisc(disc);
  }

  /// 主按钮的动作：原盘可开菜单时「播放原盘」（最近看过的那张），否则普通播放。
  void _onPrimaryPlay(CollectionEpisodeSlot episode) {
    final DiscRef? disc = preferredDisc(_discs);
    if (_discPrimaryKind == DiscPrimaryKind.playDisc && disc != null) {
      _openDisc(disc);
      return;
    }
    final RemoteDiscMenuSource? remote = _remoteDiscSource;
    if (_discPrimaryKind == DiscPrimaryKind.playDisc && remote != null) {
      _openRemoteDisc(remote);
      return;
    }
    _openSlot(episode);
  }

  /// 原盘作品 hero 的次按钮：主按钮是「播放原盘」时给「继续观看 xx:xx」/「直接播放
  /// 正片」；多盘再给「选盘」。主按钮退回普通播放（设置关 / 开不了菜单）但菜单仍可开
  /// 时，菜单入口留在次按钮。
  List<Widget> _discSecondaryActions(CollectionEpisodeSlot episode) {
    if (!_isDiscEntry) return const <Widget>[];
    final bool discPrimary = _discPrimaryKind == DiscPrimaryKind.playDisc;
    final DiscRef? disc = preferredDisc(_discs);
    return <Widget>[
      if (discPrimary)
        _isEpisodeStarted(episode)
            ? MediaDetailSecondaryButton(
                buttonKey: const ValueKey<String>('collection-disc-continue'),
                icon: FushiIcons.history,
                label: t.video_disc_continue_at(
                  time: formatDiscResumePosition(episode.positionMs),
                ),
                onPressed: () => _openSlot(episode),
              )
            : MediaDetailSecondaryButton(
                buttonKey: const ValueKey<String>('collection-disc-main-title'),
                icon: FushiIcons.playCircle,
                label: t.video_disc_play_main_title,
                onPressed: () => _openSlot(episode),
              )
      else if (_discUnavailable == null && disc != null)
        MediaDetailSecondaryButton(
          buttonKey: const ValueKey<String>('collection-disc-open-menu'),
          icon: FushiIcons.toc,
          label: t.video_disc_play,
          onPressed: () => _openDisc(disc),
        )
      else if (_discUnavailable == null && _remoteDiscSource != null)
        MediaDetailSecondaryButton(
          buttonKey: const ValueKey<String>('collection-disc-open-menu'),
          icon: FushiIcons.toc,
          label: t.video_disc_play,
          onPressed: () => _openRemoteDisc(_remoteDiscSource!),
        ),
      if (_hasRemoteDisc && _hostCanOpenDisc)
        MediaDetailSecondaryButton(
          buttonKey: const ValueKey<String>('collection-disc-open-on-host'),
          icon: FushiIcons.cast,
          label: t.video_disc_open_on_host,
          onPressed: () => unawaited(_openRemoteDiscOnHost()),
        ),
      if (_discs.length > 1 && _discUnavailable == null)
        MediaDetailSecondaryButton(
          buttonKey: const ValueKey<String>('collection-disc-choose'),
          icon: FushiIcons.swap,
          label: t.video_disc_choose_disc,
          onPressed: () => unawaited(_chooseDisc()),
        ),
    ];
  }

  /// 本会话里已经在详情页兜底索引过的来源 id，按数据库实例分（见
  /// [_scheduleSourceIndexing]）。
  static final Expando<Set<int>> _sourcesIndexedThisSession =
      Expando<Set<int>>();

  /// 后台兜底索引 [sourceIds] 里本会话还没索引过的来源：等路由转场结束再做（不和
  /// 转场动画抢主 isolate），建出规范作品行后重载一次。
  void _scheduleSourceIndexing(Set<int> sourceIds) {
    final Set<int> done = _sourcesIndexedThisSession[widget.database] ??=
        <int>{};
    final List<int> pending = <int>[
      for (final int id in sourceIds)
        if (!done.contains(id)) id,
    ];
    if (pending.isEmpty) return;
    done.addAll(pending);
    unawaited(() async {
      await _routeTransitionSettled();
      if (!mounted) return;
      final VideoSourceMetadataIndexer indexer = VideoSourceMetadataIndexer(
        widget.database,
      );
      bool changed = false;
      for (final int sourceId in pending) {
        final SourceLibraryRow? source = await widget.database
            .getMediaSourceById(sourceId);
        if (source != null && await indexer.index(source)) changed = true;
      }
      if (!mounted) return;
      final VideoMetadataWorkRow? work = await widget.database
          .resolveVideoMetadataWorkForCollection(widget.collection.id);
      if (mounted && (changed || work != null) && _canonicalWork == null) {
        await _reload();
      }
    }());
  }

  /// 本页路由的进场转场结束（已结束 / 没有转场时立即完成）。
  Future<void> _routeTransitionSettled() {
    final Animation<double>? animation = ModalRoute.of(context)?.animation;
    if (animation == null || animation.status == AnimationStatus.completed) {
      return Future<void>.value();
    }
    final Completer<void> done = Completer<void>();
    void listener(AnimationStatus status) {
      if (status == AnimationStatus.forward ||
          status == AnimationStatus.reverse) {
        return;
      }
      animation.removeStatusListener(listener);
      if (!done.isCompleted) done.complete();
    }

    animation.addStatusListener(listener);
    return done.future;
  }

  /// 让背景轮换定时器跟上当前背景张数：≥2 张且未禁用动效才轮（Jellyfin 详情页
  /// 同款 10 秒节奏）；单张 / 禁动效 / 页面销毁一律停表。setState 由定时器回调
  /// 自己发（只改下标），不重查任何数据。
  void _syncBackdropRotation() {
    _backdropRotationTimer?.cancel();
    _backdropRotationTimer = null;
    if (!mounted || _backdropSources.length < 2) return;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return;
    _backdropRotationTimer = Timer.periodic(const Duration(seconds: 10), (
      Timer _,
    ) {
      if (!mounted || _backdropSources.length < 2) return;
      setState(() {
        _heroBackdropIndex = (_heroBackdropIndex + 1) % _backdropSources.length;
      });
    });
  }

  /// 重建分节并让季 tab 控制器跟上节数。**必须在 setState 内调用**（会改
  /// [_sections] / [_seasonTabs] / [_selectedSeason]）。
  void _rebuildSections() {
    _sections = sortCollectionSeasonSections<CollectionEpisodeSlot>(
      buildCollectionSeasonSections<CollectionEpisodeSlot>(
        members: _slots,
        keyOf: (CollectionEpisodeSlot slot) => _groupKeyByEntry[slot.entryKey],
      ),
    );
    final int count = _sections.length;
    // 单季（含纯电影 / 全 PV）退化：销毁控制器、不渲染 tab 条，整页回到原样。
    if (count < 2) {
      _seasonTabs?.removeListener(_onSeasonTabChanged);
      _seasonTabs?.dispose();
      _seasonTabs = null;
      _selectedSeason = 0;
      return;
    }
    // 首次进页面停在**续播那一季**：顶部大图讲的是全局续播集，tab 若固定停在第
    // 1 季，看第二季的用户一进来就是「大图第二季 / 列表第一季」两套内容。
    if (!_seasonSelectionInitialized) {
      _seasonSelectionInitialized = true;
      final String? key = _continueKey;
      final int index = key == null
          ? -1
          : _sections.indexWhere(
              (CollectionSeasonSection<CollectionEpisodeSlot> s) => s.items.any(
                (CollectionEpisodeSlot slot) => slot.entryKey == key,
              ),
            );
      if (index >= 0) _selectedSeason = index;
    }
    _selectedSeason = _selectedSeason.clamp(0, count - 1);
    if (_seasonTabs?.length == count) {
      if (_seasonTabs!.index != _selectedSeason) {
        _seasonTabs!.index = _selectedSeason;
      }
      return;
    }
    _seasonTabs?.removeListener(_onSeasonTabChanged);
    _seasonTabs?.dispose();
    _seasonTabs = TabController(
      length: count,
      initialIndex: _selectedSeason,
      vsync: this,
    )..addListener(_onSeasonTabChanged);
  }

  void _onSeasonTabChanged() {
    final TabController? tabs = _seasonTabs;
    // indexIsChanging 期间是动画中间态；只认落定值，避免滑动过程中反复重建列表。
    if (tabs == null || tabs.indexIsChanging || tabs.index == _selectedSeason) {
      return;
    }
    setState(() => _selectedSeason = tabs.index);
  }

  bool get _hasSeasonTabs => _sections.length >= 2;

  /// 当前选中的季（无 tab 时为 null）。
  CollectionSeasonSection<CollectionEpisodeSlot>? get _selectedSection =>
      _hasSeasonTabs
      ? _sections[_selectedSeason.clamp(0, _sections.length - 1)]
      : null;

  /// 当前 tab 下应展示的剧集（无 tab 时就是全表）。
  List<CollectionEpisodeSlot> get _visibleSlots =>
      _selectedSection?.items ?? _slots;

  /// 续播下标按**全部**成员算：互联客户端上「本机看到第 3 集、第 4 集还在 host」时
  /// 续播就该指向那一集——远端进度的真相源是 host 下发的断点，与首页「继续观看」同口径。
  int get _continueIndex => continueMemberIndex(<CollectionMemberProgress>[
    for (final CollectionEpisodeSlot slot in _slots) _slotProgress(slot),
  ]);

  /// 一集的续播输入。片长只认**精确值**（播放器记下的 / host 下发的）：拿它判
  /// 「已打勾的集是不是重看到一半」（BUG-3491），刮削的整分钟片长误差太大不用。
  CollectionMemberProgress _slotProgress(CollectionEpisodeSlot slot) =>
      CollectionMemberProgress(
        positionMs: slot.positionMs,
        completed: slot.completed,
        lastPlayedAt: slot.lastPlayedAtMs,
        durationMs: _exactDurationMs(slot),
      );

  int? _exactDurationMs(CollectionEpisodeSlot slot) =>
      _knownDurationsMs[slot.entryKey] ?? slot.remote?.durationMs;

  /// 续播成员的键：分季视图里行下标是**节内**下标，与全局 [_continueIndex]
  /// 对不上，高亮统一按成员键判定（平铺视图两者等价）。
  String? get _continueKey =>
      _slots.isEmpty ? null : _slots[_continueIndex].entryKey;

  /// 分组键 → tab / 分节标题（`s<N>` → 「第 N 季」；其余 → PV·特典）。
  String _groupLabel(String groupKey) {
    final int? season = seasonNumberOfGroupKey(groupKey);
    return season == null
        ? t.collection_group_extras
        : t.collection_group_season(n: season);
  }

  /// 「已看完 x/N」：手动标记看完，或进度到片尾区（BUG-3491：播放不再自动打勾，
  /// 看到片尾的集在计数上等同看完）。
  int get _watchedCount => _slots
      .where(
        (CollectionEpisodeSlot slot) => _slotProgress(slot).countsAsWatched,
      )
      .length;

  /// 展示用集名（TODO-2491）：集级刮削行的 title。集名缺失时集级刮削会把**作品名**
  /// 回填进 title（那不是集名，与 episode_rename.dart 同判据），此时不当集名用。
  /// 无集级资料 → null，调用方回落 [VideoBookRow.title]（文件名现状，零变化）。
  String? _scrapedEpisodeTitle(CollectionEpisodeSlot slot) {
    // 一文件多集：各集集名用「 / 」并列（Shoko 的 01-02 合集文件同样两集都列）。
    final String canonical = <String>[
      for (final VideoMetadataEpisodeRow episode
          in _canonicalEpisodesByUid[slot.entryKey] ??
              const <VideoMetadataEpisodeRow>[])
        if (episode.title?.trim() case final String title when title.isNotEmpty)
          title,
    ].join(' / ');
    if (canonical.isNotEmpty) return canonical;
    final VideoScrapeMetaRow? meta = _episodeMetaByUid[slot.entryKey];
    if (meta == null) return null;
    final String title = meta.title.trim();
    if (title.isEmpty) return null;
    if (title == _scrapeMeta?.title) return null;
    return title;
  }

  /// 集卡展示名：优先集级刮削集名，回落条目标题（文件名）。远端集本机没有刮削行，
  /// 恒走 host 下发的标题。
  String _episodeDisplayTitle(CollectionEpisodeSlot slot) =>
      _scrapedEpisodeTitle(slot) ?? slot.title;

  /// 集卡**序号**：文件名解析出的真实集号优先，解析不出才回落列表顺位号
  /// （BUG-1544）。缺集 / 只导入了一部分时顺位号必然与真实集号错位——用户看到
  /// 「03」点开却是 E05。集号是文件名里写着的事实，不是列表下标的函数。
  int _episodeDisplayNumber(CollectionEpisodeSlot slot, int index) =>
      _episodeNumbers[slot.entryKey] ?? index + 1;

  /// [_slots] 整批解析出的集号（entryKey → 集号），按 [_slots] 的**对象身份**
  /// 缓存：`_slots` 每次变更都是整体替换成新列表，所以 identical 即可当缓存键，
  /// 四个赋值点都不必记得手动失效。
  ///
  /// 整批（而非逐个文件名）解析是 BUG-2369 的要求：不补零的目录里逐个解析会
  /// 1..9 全解不出、10.. 解得出，一半集卡掉回顺位号，序号与真实集号错位。
  List<CollectionEpisodeSlot>? _episodeNumbersSlots;
  Map<String, int> _episodeNumbersCache = const <String, int>{};

  Map<String, int> get _episodeNumbers {
    if (identical(_episodeNumbersSlots, _slots)) return _episodeNumbersCache;
    final List<int?> numbers = parsedEpisodeNumbersOf(<String>[
      for (final CollectionEpisodeSlot slot in _slots) slot.filename,
    ]);
    _episodeNumbersCache = <String, int>{
      for (int i = 0; i < _slots.length; i++)
        if (numbers[i] != null) _slots[i].entryKey: numbers[i]!,
    };
    _episodeNumbersSlots = _slots;
    return _episodeNumbersCache;
  }

  /// 绑定文件的 AniDB 原生集号（刮削时经 ED2K 哈希识别写进分集行，Shoko 式两套
  /// 编号并存）；没有身份 → null 不占位。
  String? _episodeIdentityLabel(CollectionEpisodeSlot slot) {
    final String epno = <String>[
      for (final VideoMetadataEpisodeRow episode
          in _canonicalEpisodesByUid[slot.entryKey] ??
              const <VideoMetadataEpisodeRow>[])
        if (episode.anidbEpisodeNumber?.trim() case final String number
            when number.isNotEmpty)
          number,
    ].join(' / ');
    if (epno.isEmpty) return null;
    return t.collection_episode_anidb_number(number: epno);
  }

  /// 集简介（集级刮削 summary；无 → null 不占位）。
  String? _episodeSummary(CollectionEpisodeSlot slot) {
    final String? summary =
        (_canonicalEpisodesByUid[slot.entryKey]?.firstOrNull?.overview ??
                _episodeMetaByUid[slot.entryKey]?.summary)
            ?.trim();
    return (summary == null || summary.isEmpty) ? null : summary;
  }

  /// 集卡元信息：播出日 · 时长（规范分集行有才出，缺的逐项跳过）。
  List<String> _episodeMeta(CollectionEpisodeSlot slot) {
    final VideoMetadataEpisodeRow? episode =
        _canonicalEpisodesByUid[slot.entryKey]?.firstOrNull;
    final String? airDate = episode?.airDate?.trim();
    final int? runtime = episode?.runtimeMinutes;
    return <String>[
      if (airDate != null && airDate.isNotEmpty) airDate,
      if (runtime != null && runtime > 0) t.video_runtime_minutes(n: runtime),
    ];
  }

  /// 集卡观看进度 0..1：只在**知道总时长**时给（播放器记下的精确片长 / host 下发
  /// 的远端时长 / 规范分集的整分钟片长），算不出就返回 null——集卡只显示
  /// 「看到 mm:ss」，不造假条、不写百分比。看完的集有断点也给（BUG-3491：
  /// 一律保留时间进度 + 百分比 + 进度条）。
  double? _episodeProgress(CollectionEpisodeSlot slot) {
    if (slot.positionMs <= 0) return null;
    final int? runtime =
        _canonicalEpisodesByUid[slot.entryKey]?.firstOrNull?.runtimeMinutes;
    final int? totalMs =
        _exactDurationMs(slot) ??
        (runtime != null && runtime > 0 ? runtime * 60000 : null);
    if (totalMs == null || totalMs <= 0) return null;
    return (slot.positionMs / totalMs).clamp(0.0, 1.0);
  }

  /// hero 背景的**横版**图源（BUG-1298 的数据层根治；v68 支持多张轮换，取当前
  /// 轮换下标那张）。
  ///
  /// hero 是约 2.7:1 的宽幅槽，理应喂横图。刮削若拿到了 TMDB 的横版图组就落在
  /// media_images 里，槽向天然吻合、直接 cover 铺满即可。
  ///
  /// 返回 null = 该源没有横版图（离线库只有竖版海报时恒为空），此时
  /// 背景回落到海报的模糊垫底（见 [CollectionDetailHero]）。那不是权宜之计，是这些源
  /// 的常态路径。
  ImageProvider? get _heroBackdrop {
    if (_backdropSources.isEmpty) return null;
    final String source =
        _backdropSources[_heroBackdropIndex % _backdropSources.length];
    return _resolveCanonicalImage(source, decodeWidth: 2560);
  }

  /// 标题 logo 图源（v68）；null = 无 logo，hero 标题走纯文字。
  ImageProvider? get _heroLogo =>
      _resolveCanonicalImage(_logoPath ?? _logoRemoteUrl, decodeWidth: 800);

  ImageProvider? _resolveCanonicalImage(
    String? source, {
    required int decodeWidth,
  }) {
    if (source == null || source.isEmpty) return null;
    final Uri? uri = Uri.tryParse(source);
    if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
      return ResizeImage.resizeIfNeeded(
        decodeWidth,
        null,
        AppCachedHttpImage(source),
      );
    }
    return resolveMediaCoverImage(
      kind: MediaKind.video,
      localPath: source,
      decodeWidth: decodeWidth,
    );
  }

  ImageProvider? get _heroCover {
    // 读 DB 快照而非进页副本：刮削刚写进去的新封面必须立刻生效（见 [_collectionRow]）。
    // 每一级本地路径都要文件真实存在才算数，与库页合集卡
    // （`home_video_page.dart` 的 `_buildCollectionCover`）同一条判据：剧集目录
    // 搬家、备份恢复带来的悬空路径必须表现得像「没设过封面」，落到刮削封面 /
    // 成员封面，而不是返回一张必坏的 FileImage 把后面的回退全挡掉。
    //
    // 存在性读 [_coverExists]（零同步 IO，BUG-3756）；某一级还在探测时整条链停在
    // [kPendingCoverImage]，不先闪成后面的回退封面。
    // 自有层（自有封面 → 原盘竖版盘面图）的优先级只在
    // [collectionOwnCoverCandidates] 写一次。
    for (final String ownCoverPath in collectionOwnCoverCandidates(
      _collectionRow ?? widget.collection,
      _mediaImages,
    )) {
      switch (_coverExists.lookupOptional(ownCoverPath)) {
        case null:
          return kPendingCoverImage;
        case true:
          return resolveMediaCoverImage(
            kind: MediaKind.video,
            localPath: ownCoverPath,
            decodeWidth: 1600,
          );
        case false:
          break;
      }
    }
    switch (_coverExists.lookupOptional(_canonicalCoverPath)) {
      case null:
        return kPendingCoverImage;
      case true:
        return resolveMediaCoverImage(
          kind: MediaKind.video,
          localPath: _canonicalCoverPath,
          decodeWidth: 1600,
        );
      case false:
        break;
    }
    if (_canonicalCoverRemoteUrl case final String remoteCover
        when remoteCover.isNotEmpty) {
      return _resolveCanonicalImage(remoteCover, decodeWidth: 1600);
    }
    if (_members.isEmpty) return null;
    for (final String? candidate in <String?>[
      _members[_continueIndex].coverPath,
      for (final VideoBookRow row in _members) row.coverPath,
    ]) {
      switch (_coverExists.lookupOptional(candidate)) {
        case null:
          return kPendingCoverImage;
        case true:
          return resolveMediaCoverImage(
            kind: MediaKind.video,
            localPath: candidate,
            decodeWidth: 1600,
          );
        case false:
          continue;
      }
    }
    return null;
  }

  /// 把当前 [_slots] 顺序一次落盘（sortIndex 全表回写）。库页合集行与播放器
  /// 换集读同一 `getCollectionItems`，落盘即三处同序（层次 C 单一真相源）。
  ///
  /// 本页只渲染 video 成员（调用方 `loadMembers` 按 mediaType 过滤），而一个合集**可以**
  /// 同时含非 video 成员，所以这里传的是**子集**——这是 `reorderCollectionItems` 的合法
  /// 用法：不可见成员留在原槽位、全表写成致密序，由 DAO 保证（BUG-1194 的不变量归属在
  /// DAO，不是各调用方自觉；页面不再自己做保序合并）。
  Future<void> _persistOrder() async {
    await widget.database.reorderCollectionItems(
      widget.collection.id,
      <CollectionMemberKey>[
        // 远端槽同样进落盘序：它们在本地 `media_collection_items` 里**本来就有行**
        // （合集清单是跨端 union），漏掉它们等于让本地全序与显示序错开，且下一轮合集
        // 同步会把这个错序传回对端。
        for (final CollectionEpisodeSlot slot in _slots)
          (mediaType: MediaKind.video.dbValue, entryKey: slot.entryKey),
      ],
    );
    widget.onChanged();
  }

  /// 拖拽精修：FushiReorderableColumn 语义（newIndex 即最终下标，无 SDK
  /// ReorderableListView 的「移除前下标」修正）→ 内存 move → 落盘。
  ///
  /// 分季 tab 下拖的是**本季**列表：下标是节内的，先在节内 move，再把各节按
  /// **落盘序**（[_slots] 里各组首次出现的顺序，不是 tab 的展示序）拼回全序，
  /// 避免拖一集顺带把整表按 tab 序重写。
  Future<void> _onReorder(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    final List<CollectionEpisodeSlot> section = List<CollectionEpisodeSlot>.of(
      _visibleSlots,
    );
    final CollectionEpisodeSlot moved = section.removeAt(oldIndex);
    section.insert(newIndex, moved);
    if (!_hasSeasonTabs) {
      setState(() {
        _slots = section;
        _rebuildSections();
      });
      await _persistOrder();
      return;
    }
    final String movedKey =
        _groupKeyByEntry[moved.entryKey] ?? kCollectionExtrasGroupKey;
    final List<CollectionSeasonSection<CollectionEpisodeSlot>> persisted =
        buildCollectionSeasonSections<CollectionEpisodeSlot>(
          members: _slots,
          keyOf: (CollectionEpisodeSlot slot) =>
              _groupKeyByEntry[slot.entryKey],
        );
    setState(() {
      _slots = <CollectionEpisodeSlot>[
        for (final CollectionSeasonSection<CollectionEpisodeSlot> s
            in persisted)
          ...(s.groupKey == movedKey ? section : s.items),
      ];
      _rebuildSections();
    });
    await _persistOrder();
  }

  /// 一键整理（覆盖 95% 场景）：按 [compare] 重排全表并落盘。乱序的手攒播放列表
  /// 一键回名称序 / 加入时序。
  Future<void> _applyOneKeySort(
    int Function(CollectionEpisodeSlot a, CollectionEpisodeSlot b) compare,
  ) async {
    final List<CollectionEpisodeSlot> next = List<CollectionEpisodeSlot>.of(
      _slots,
    )..sort(compare);
    setState(() {
      _slots = next;
      _rebuildSections();
    });
    await _persistOrder();
  }

  /// 「按季排序」：按文件名重排全表（季→集→标题，PV/特典殿后）并落盘。季 tab
  /// **展示**本身是派生的、进页面即生效，本动作只负责把落盘全序也整理成分季连续
  /// （单季合集执行后无可见变化，幂等）。
  /// 当前合集行：`_collectionRow` 是 [_reload] 重取的最新快照，
  /// `widget.collection` 只是进页那一刻的副本（刮削会改写 name / coverPath）。
  MediaCollectionRow get _collection => _collectionRow ?? widget.collection;

  /// AppBar「设置封面」：选图 → 落 `video_covers/collections/<id>.jpg` → 写
  /// `media_collections.cover_path`。与库页合集右键同一条
  /// [MediaCoverService.applyCollectionCover]，不另开落盘路径。
  Future<void> _setCover() async {
    final File? picked = await MediaCoverService.pickCoverImage();
    if (picked == null) return;
    await _applyCoverFile(picked);
  }

  /// AppBar「在线搜索封面」：回调给出临时文件后与本地选图走同一条落盘。
  Future<void> _setCoverOnline() async {
    final File? picked = await widget.onPickOnlineCover?.call(_collection.name);
    if (picked == null || !mounted) return;
    await _applyCoverFile(picked);
  }

  Future<void> _applyCoverFile(File picked) async {
    try {
      await MediaCoverService.applyCollectionCover(
        database: widget.database,
        collectionId: widget.collection.id,
        pickedPath: picked.path,
      );
    } on Object catch (e, stack) {
      ErrorLogService.instance.log('collectionDetail.setCover', e, stack);
      if (!mounted) return;
      FushiToast.show(
        msg: t.collection_cover_failed,
        severity: ToastSeverity.error,
      );
      return;
    }
    if (!mounted) return;
    await _reload();
    widget.onChanged();
    FushiToast.show(
      msg: t.collection_cover_updated,
      severity: ToastSeverity.success,
    );
  }

  /// AppBar「恢复默认封面」：清 `coverPath` + 回收那张图（与删合集共用同一套误删
  /// 护栏，见 [clearCollectionOwnCover]），封面回落成员借用链 / canonical 海报。
  Future<void> _resetCover() async {
    await clearCollectionOwnCover(widget.database, widget.collection.id);
    if (!mounted) return;
    await _reload();
    widget.onChanged();
  }

  Future<void> _sortBySeason() async {
    if (_slots.isEmpty) return;
    final CollectionSeasonRegroup<CollectionEpisodeSlot> regroup =
        regroupMembersBySeason<CollectionEpisodeSlot>(
          members: _slots,
          filenameOf: (CollectionEpisodeSlot slot) => slot.filename,
          titleOf: (CollectionEpisodeSlot slot) => slot.title,
        );
    setState(() {
      _slots = regroup.ordered;
      _rebuildSections();
    });
    await _persistOrder();
  }

  /// AppBar「排序」菜单：按名称（natural，卷1<卷2<卷10）/ 按导入时间（旧→新 =
  /// 原始加入时序）一键重排。菜单外壳共享 [buildDetailSortMenu]。
  ///
  /// 比较规则走共享的 [compareCollectionMembers]（与库页合集右键菜单、书架网格
  /// 详情页同一份）。本页成员已是内存里的 [VideoBookRow]，标题 / 导入时刻直接取，
  /// 不必像另两处那样现查四表——收口的是**规则**，不是取数路径。
  ///
  /// 顺带修掉本页原先「按名称」缺平局兜底的问题：`List.sort` 不是稳定排序，同名
  /// 条目（同一集的两个来源 / 都还没刮到标题）此前每次整理都可能换个顺序，而顺序
  /// 是要落盘的，看起来就像列表自己在动。
  Widget _buildSortMenu() {
    CollectionSortMeta metaOf(CollectionEpisodeSlot slot) => (
      title: slot.title,
      importedAt: slot.importedAt ?? 0,
      key: slot.entryKey,
    );
    return buildDetailSortMenu(
      onSortByTitle: () => _applyOneKeySort(
        (CollectionEpisodeSlot a, CollectionEpisodeSlot b) =>
            compareCollectionMembers(metaOf(a), metaOf(b), byTitle: true),
      ),
      onSortByImported: () => _applyOneKeySort(
        (CollectionEpisodeSlot a, CollectionEpisodeSlot b) =>
            compareCollectionMembers(metaOf(a), metaOf(b), byTitle: false),
      ),
      onSortByAi: switch (widget.collectionAiSettings) {
        final AiSettingsSource settings => () => _sortWithAi(settings),
        null => null,
      },
    );
  }

  /// 「AI 排序」：SP / OVA / 特别篇等没有集号的成员交 AI 定位后整表落盘，再重取
  /// 成员槽（顺序真相在 sortIndex，不在页内另排一份）。
  Future<void> _sortWithAi(AiSettingsSource settings) async {
    final bool persisted = await runDetailAiSort(
      settings: settings,
      clientFactory: widget.aiClientFactory,
    );
    if (persisted && mounted) await _reload();
  }

  /// 「为整个合集获取字幕」：全屏字幕工作台（合集作用域）——绑定 AniList 系列后经
  /// 统一来源逐集批量下载并持久化（本地集落 DB、远端集落 prefs，见
  /// [SubtitleCollectionPanel]）。
  Future<void> _fetchCollectionSubtitles() async {
    if (_members.isEmpty) return;
    // 用当前 collection 行（可能已在别处更新 anilistId / 字幕配置）作初值。
    final MediaCollectionRow collection =
        await widget.database.getMediaCollectionById(widget.collection.id) ??
        widget.collection;
    final String saveDir = (await AppPaths.videoSubtitlesDirectory()).path;
    if (!mounted) return;
    await SubtitleWorkbenchPage.open(
      context,
      host: AppSubtitleWorkbenchHost(
        ProviderScope.containerOf(context, listen: false).read(appProvider),
      ),
      saveDirectory: saveDir,
      collection: SubtitleCollectionSpec(
        collection: collection,
        members: _members,
      ),
      initialScope: SubtitleWorkbenchScope.collection,
    );
  }

  /// 「整季生成日语字幕」：取合集全部视频成员（已有 `.ja.srt` 的由管线跳过），一部
  /// 作品一张专名表，面板里显示每集进度与跳过原因。编排在 [AppVideoSubtitleService]
  /// （与视频页单集、桌面 CLI 同一个服务）。
  Future<void> _generateSeasonJaSubtitles() async {
    final AppModel appModel = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(appProvider);
    // 成员全在对端：整季交给放视频的 host 跑（逐集 videoId 任务，host 侧同一作品键
    // 共用一张专名表）；本机有成员时在本机跑，只在对端的集列为跳过。
    if (_members.isEmpty && _remoteMembers.isNotEmpty) {
      await _generateRemoteSeasonJaSubtitles(appModel);
      return;
    }
    final AppVideoSubtitleService service = appVideoSubtitleService(appModel);
    final AppVideoSubtitleTarget target;
    try {
      target = await service.resolveCollection(widget.collection.id);
    } on AppVideoSubtitleTargetNotFound {
      // 合集在这期间被删掉了（与视频页单集入口同一处理）。
      if (!mounted) return;
      FushiToast.show(
        msg: t.video_subtitle_ai_no_local_episodes,
        severity: ToastSeverity.error,
      );
      return;
    }
    if (!mounted) return;
    await showVideoSubtitleGenerateSheet(
      context: context,
      service: service,
      target: target,
      prefs: PrefsRepoVideoSubtitleGeneratePrefs(appModel.prefsRepo),
      openAiSettings: pushAiSettingsPage,
    );
  }

  Future<void> _generateRemoteSeasonJaSubtitles(AppModel appModel) async {
    bool hasJapanese(RemoteVideoInfo m) =>
        m.subtitleFileName?.toLowerCase().endsWith('.ja.srt') ?? false;
    await showRemoteVideoSubtitleSheet(
      context: context,
      service: appRemoteVideoSubtitleService(appModel),
      target: RemoteVideoSubtitleTarget(
        title: _canonicalWork?.title ?? _name,
        wholeSeason: true,
        episodes: <RemoteVideoSubtitleEpisode>[
          for (final RemoteVideoInfo m in _remoteMembers)
            if (!hasJapanese(m))
              RemoteVideoSubtitleEpisode(videoId: m.id, title: m.title),
        ],
        skippedExisting: <String>[
          for (final RemoteVideoInfo m in _remoteMembers)
            if (hasJapanese(m)) m.title,
        ],
      ),
      prefs: PrefsRepoVideoSubtitleGeneratePrefs(appModel.prefsRepo),
    );
  }

  // 「刮削分集资料」独立入口已删（TODO-2791）：它硬门「合集已刮削」，而合集刮削
  // 管线（VideoMetadataDatabaseStore.apply → _writeLegacyProjection）本就会把集名/
  // 集号投影进 video_scrape_meta，所以这个入口在未刮时只会弹「请先刮削合集资料」、
  // 在已刮时做重复工作 —— 是个死按钮。集级资料统一由合集刮削产出。

  /// 「按刮削重命名各集」（TODO-2491）：dryRun 拿旧名→新名对照表 → 勾选确认
  /// 弹窗 → 对勾选子集逐条写穿 `video_books.title`（与库页手动重命名同一落库
  /// 口）。空对照直接提示无可改（未刮集级资料 / 名字已一致）。
  Future<void> _renameEpisodesFromScrape() async {
    final List<EpisodeRenameProposal> proposals =
        await renameCollectionEpisodes(
          db: widget.database,
          collectionId: widget.collection.id,
          dryRun: true,
        );
    if (!mounted) return;
    if (proposals.isEmpty) {
      FushiToast.show(
        msg: t.collection_episode_rename_empty,
        severity: ToastSeverity.info,
      );
      return;
    }
    final List<EpisodeRenameProposal>? chosen =
        await showEpisodeRenameConfirmDialog(
          context: context,
          proposals: proposals,
        );
    if (chosen == null || chosen.isEmpty || !mounted) return;
    // 逐条落库、逐条计数：单条失败不打断批次也**不静默**——用户必须分得清
    // 「全改完」和「改了一半」（复核意见：部分失败不得报成功数=勾选数）。
    int renamed = 0;
    Object? firstError;
    for (final EpisodeRenameProposal proposal in chosen) {
      try {
        await widget.database.updateVideoBookTitle(
          proposal.bookUid,
          proposal.newTitle,
        );
        renamed++;
      } catch (e) {
        firstError ??= e;
      }
    }
    if (!mounted) return;
    if (firstError != null) {
      FushiToast.show(
        msg: t.collection_episode_rename_partial(
          n: renamed,
          m: chosen.length - renamed,
        ),
        severity: ToastSeverity.warning,
      );
    } else {
      FushiToast.show(
        msg: t.collection_episode_rename_apply(n: renamed),
        severity: ToastSeverity.success,
      );
    }
    await _reload();
    widget.onChanged();
  }

  /// 打开「相关作品」里已绑定的本地合集详情（airing_calendar 同范式：本页只有
  /// database，成员解析与进播放器都自包含，不依赖调用方注入新回调——两个既有
  /// 调用方零改动）。onChanged 透传：相关合集里的改动同样该刷新库页。
  Future<void> _openRelatedCollection(int targetCollectionId) async {
    final MediaCollectionRow? target = await widget.database
        .getMediaCollectionById(targetCollectionId);
    if (target == null || !mounted) return;
    final VideoBookRepository repo = VideoBookRepository(widget.database);
    Navigator.push<void>(
      context,
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => MediaCollectionDetailPage(
          database: widget.database,
          collection: target,
          loadEpisodes: () => loadCollectionEpisodeSlots(
            repository: repo,
            collectionId: target.id,
            loadRemoteVideos: widget.remote?.loadRemoteVideos,
          ),
          // 远端上下文原样传下去：相关作品也可能是「只在对端」的那一部。
          remote: widget.remote,
          collectionAiSettings: widget.collectionAiSettings,
          aiClientFactory: widget.aiClientFactory,
          onOpenEpisode: (VideoBookRow episode) {
            Navigator.push<void>(
              context,
              adaptivePageRoute<void>(
                context: context,
                builder: (_) => VideoFushiPage.neutralized(
                  bookUid: episode.bookUid,
                  repo: repo,
                  playlistCollectionId: target.id,
                ),
              ),
            );
          },
          onChanged: widget.onChanged,
        ),
      ),
    );
  }

  /// 把视频文件拖进本合集详情页 = 导入并**直接**归入本合集。
  ///
  /// 此前拖放只在视频库首页生效，导完还得回头手动「加入合集」。这里逐个处理：
  /// 同一物理文件已在库（[VideoBookRepository.findByVideoPath]）就复用那一行，
  /// 不再弹导入框、也不派生第二身份；未入库的走与首页同一个 [VideoImportDialog]
  /// 预填导入（字幕配对口径同首页：单视频取第一条字幕、多视频按文件名主干配）。
  /// 某一条取消只跳过该条。归入合集走共享的 [addMediaRefToCollection]（查重提示
  /// + 失败提示都在它里面，永不抛）。
  ///
  /// 只收视频文件：文件夹 / 播放列表 / 种子在首页各有去处，合集页里没有「归入
  /// 本合集」的明确语义，给可见提示而不是静默。
  Future<void> _handleCollectionFileDrop(
    List<String> paths,
    Offset globalPosition,
  ) async {
    // 目录判定先 async 做完再交给同步的分类器（BUG-3756：拖进来的常是网络盘上的
    // 文件，同步 stat 冷目录要数秒、冻结 UI isolate）。
    // 各路径并发判（一次往返，不逐个串行等网络盘）。
    final List<bool> isDirectory = await Future.wait(<Future<bool>>[
      for (final String path in paths) FileSystemEntity.isDirectory(path),
    ]);
    final Set<String> directories = <String>{
      for (int i = 0; i < paths.length; i++)
        if (isDirectory[i]) paths[i],
    };
    if (!mounted) return;
    final DroppedFiles files = classifyDroppedFiles(
      paths,
      isDirectory: directories.contains,
    );
    debugPrint(
      '[fushi-drop] [collection-detail] videos=${files.videos.length} '
      'subtitles=${files.subtitles.length} collection=${widget.collection.id}',
    );
    if (files.videos.isEmpty) {
      FushiToast.show(
        msg: t.drag_drop_unsupported_on_collection,
        severity: ToastSeverity.warning,
      );
      return;
    }
    final VideoBookRepository repo = VideoBookRepository(widget.database);
    int added = 0;
    for (final String video in files.videos) {
      if (!mounted) return;
      String? bookUid = (await repo.findByVideoPath(video))?.bookUid;
      if (bookUid == null) {
        if (!mounted) return;
        final String? subtitle = files.videos.length == 1
            ? (files.subtitles.isNotEmpty ? files.subtitles.first : null)
            : subtitleForVideoByStem(video, files.subtitles);
        bookUid = await showAppDialog<String>(
          context: context,
          builder: (_) => VideoImportDialog(
            repo: repo,
            initialVideoPath: video,
            initialSubtitlePath: subtitle,
          ),
        );
      }
      if (bookUid == null) continue;
      final CollectionAddOutcome outcome = await addMediaRefToCollection(
        database: widget.database,
        collectionId: widget.collection.id,
        mediaRef: MediaRef(kind: MediaKind.video, entryKey: bookUid),
      );
      if (outcome == CollectionAddOutcome.added) added++;
    }
    if (added == 0 || !mounted) return;
    await _reload();
    widget.onChanged();
    FushiToast.show(
      msg: t.batch_add_to_collection_success(n: added),
      severity: ToastSeverity.success,
    );
  }

  /// 「相关作品 → 去下载」：预填关系边标题打开番剧下载对话框（搜番段）。
  void _downloadRelation(CollectionRelationRow relation) {
    showAppDialog<void>(
      context: context,
      builder: (_) => AnimeDownloadDialog(
        showTasks: false,
        initialSearchQuery: relation.title,
      ),
    );
  }

  /// 下载入口此刻是否该渲染：「功能模块 › 下载」开着，且本平台有下载中心
  /// （iOS 按 App Store 合规恒无，见 `store_compliance.dart`）。
  ///
  /// 判据问 [ModuleVisibility] 而不是直接判平台：本页的三个下载入口（集菜单
  /// 「下载」、相关作品「去下载」、管理菜单「补齐缺集」）打开的都是番剧下载对话框，
  /// 而它属于下载中心——模块关掉时那个页面本身已不可达，入口留着就是一个点了会把
  /// 用户推进一条不存在流程的按钮。同域的 `home_page.dart` 早就按「页面不可达时
  /// 入口就不该渲染」处理（`_downloadsReachable`），这里补齐。
  ///
  /// 🔴 **容器缺席要容忍，不能让整页 build 抛**：本页有 8 个 widget 测试把它直接
  /// 挂在 `MaterialApp` 下、**不带 `ProviderScope`**（它此前的功能没有一处在 build
  /// 路径上需要 Riverpod——第一次用到容器是「打开字幕工作台」那个方法体里）。裸调
  /// `ProviderScope.containerOf` 会把「一个入口该不该显示」变成整页崩溃的理由，
  /// 三个 suite 共 14 条用例当场全红。缺席只可能发生在测试里：三个生产装配点
  /// （本页推相关合集、`video_work_detail_page`、路由表）全都在 `runApp` 的
  /// [UncontrolledProviderScope] 之内，所以缺席时回落 `true`（= 改动前的行为）
  /// 既不影响合规，也让那些不关心下载入口的用例继续测它们本来要测的东西。
  bool get _downloadsAvailable {
    final ProviderContainer? container = _maybeProviderContainer();
    if (container == null) return true;
    return container
        .read(appProvider)
        .moduleVisibility
        .isEnabled(ModuleId.browse);
  }

  /// 宽屏版式：true = 海报横幅（与竖屏同形，fanart 横幅在顶、清楚露出），false =
  /// 两栏。用户在右上角切换，跨作品记住（偏好 `video_detail_poster_layout`）。
  /// 没有 [ProviderScope]（部分 widget 测试）时恒为两栏。
  bool get _posterLayout =>
      _posterLayoutOverride ??
      (_maybeProviderContainer()
              ?.read(appProvider)
              .prefsRepo
              .videoDetailPosterLayout ??
          false);
  bool? _posterLayoutOverride;

  Future<void> _togglePosterLayout() async {
    final bool next = !_posterLayout;
    setState(() => _posterLayoutOverride = next);
    await _maybeProviderContainer()
        ?.read(appProvider)
        .prefsRepo
        .setVideoDetailPosterLayout(next);
  }

  /// 本页所在树上的 Riverpod 容器；没有 [ProviderScope] 时返回 null。
  ///
  /// 用 `getElementForInheritedWidgetOfExactType` 而不是 `dependOnInherited...`：
  /// 与 `containerOf(listen: false)` 同语义——只取一次值，不为它注册重建依赖。
  ProviderContainer? _maybeProviderContainer() {
    final InheritedElement? element = context
        .getElementForInheritedWidgetOfExactType<UncontrolledProviderScope>();
    final Widget? widget = element?.widget;
    return widget is UncontrolledProviderScope ? widget.container : null;
  }

  /// 文件名解出的集号；解不出回落集级刮削行的 episodeNumber（两者都无 → null）。
  int? _episodeNumberOf(CollectionEpisodeSlot slot) =>
      parseVideoFilename(p.basename(slot.filename)).episode ??
      _episodeMetaByUid[slot.entryKey]?.episodeNumber;

  /// 打开下载对话框（TODO-2485）：合集绑了 anilistId → 本地合成 [AniListMedia]
  /// （id + 合集名，零网络）直达选种段并预填集号；未绑定 → 回落预填合集名的
  /// 搜番段。[episodeNumber] null = 不按集过滤。
  void _openDownloadDialog({required int? episodeNumber}) {
    final MediaCollectionRow collection = _collectionRow ?? widget.collection;
    final int? anilistId = collection.anilistId;
    showAppDialog<void>(
      context: context,
      builder: (_) => AnimeDownloadDialog(
        showTasks: false,
        initialMedia: anilistId == null
            ? null
            : AniListMedia(id: anilistId, romaji: collection.name),
        initialEpisode: anilistId == null ? null : episodeNumber,
        initialSearchQuery: anilistId == null ? collection.name : null,
      ),
    );
  }

  /// 「补齐缺集」：按文件名集号找 1..max 的第一个缺口；无内部缺口但刮削话数
  /// 大于 max → 下一集（max+1）。真没有缺集（或一集集号都解不出）→ 提示。
  void _fillMissingEpisodes() {
    // 集号取全部成员（含只在 host 上的集）：客户端上「第 5 集在对端」不是缺集，
    // 只按本地行算会把已经有的集报成缺口、去下载一份重复的。
    final Set<int> present = <int>{
      for (final CollectionEpisodeSlot slot in _slots)
        if (parseVideoFilename(p.basename(slot.filename)).episode
            case final int episode)
          episode,
    };
    int? firstMissing;
    if (present.isNotEmpty) {
      final int maxEpisode = present.reduce((int a, int b) => a > b ? a : b);
      for (int i = 1; i <= maxEpisode; i++) {
        if (!present.contains(i)) {
          firstMissing = i;
          break;
        }
      }
      final int episodeCount = _scrapeMeta?.episodeCount ?? 0;
      if (firstMissing == null && episodeCount > maxEpisode) {
        firstMissing = maxEpisode + 1;
      }
    }
    if (firstMissing == null) {
      FushiToast.show(
        msg: t.collection_episode_no_missing,
        severity: ToastSeverity.info,
      );
      return;
    }
    _openDownloadDialog(episodeNumber: firstMissing);
  }

  /// 逐集「移出合集」（整理排序页删除后本页是视频侧唯一移出入口）：确认 →
  /// [FushiDatabase.removeFromCollection]（空合集自动删）→ 重载；合集被清空则
  /// 退回上层。条目本身绝不删除。
  Future<void> _removeEpisode(CollectionEpisodeSlot slot) async {
    if (!await confirmDetailRemoveMember()) return;
    if (!mounted) return;
    // 成员键即 `media_collection_items.entry_key`——远端集在本地同样有成员行，移出
    // 它是合法且会经合集同步传播到对端的操作（与库页移出语义一致）。
    await widget.database.removeFromCollection(
      widget.collection.id,
      MediaKind.video,
      slot.entryKey,
    );
    if (!mounted) return;
    widget.onChanged();
    FushiToast.show(
      msg: t.collection_member_removed,
      severity: ToastSeverity.success,
    );
    final bool emptied =
        await widget.database.getMediaCollectionById(widget.collection.id) ==
        null;
    if (!mounted) return;
    if (emptied) {
      Navigator.of(context).maybePop();
      return;
    }
    await _reload();
  }

  /// 「按季拆分合集」（TODO-2489）：多季合集逐季建新合集、成员按季加入映射，
  /// 新合集间自动写前传/续作关系链；原合集按勾选保留（成员不动，作全系列入口）
  /// 或删除。
  ///
  /// 一个事务包住「建合集 + 成员映射 + 关系链」——无半拆状态；且天然可重入
  ///（createMediaCollection 撞 (name, type) 复用、addToCollection INSERT OR
  /// IGNORE、replaceCollectionRelations 整体替换）。「保留原合集 = 成员不动」而
  /// 非「变空壳」：removeFromCollection* 清空即自动删合集，空壳在数据模型上不存
  /// 在；成员本就允许多归属，拆分只是**新增**每季的归属映射，不动原映射。删除
  /// 原合集在事务外走 deleteMediaCollectionWithAssets（含文件 IO，语义与
  /// 「删除合集」菜单一致：只解链 + 回收合集自有封面，绝不删条目）。
  Future<void> _splitBySeason() async {
    if (!_hasSeasonTabs) return;
    final List<CollectionSeasonSection<CollectionEpisodeSlot>> sections =
        _sections;
    final CollectionSplitChoice? choice = await showCollectionSplitDialog(
      context: context,
      sections: <CollectionSplitPlanSection>[
        for (final CollectionSeasonSection<CollectionEpisodeSlot> section
            in sections)
          CollectionSplitPlanSection(
            defaultName: '$_name ${_groupLabel(section.groupKey)}',
            members: <CollectionSplitMember>[
              // 远端槽照样进拆分：新合集的成员键就是它在 items 表里的 entryKey，
              // 漏掉它们等于拆分时把对端那几集的归属丢了。
              for (final CollectionEpisodeSlot slot in section.items)
                CollectionSplitMember(
                  id: slot.entryKey,
                  title: _episodeDisplayTitle(slot),
                ),
            ],
            isSeason: seasonNumberOfGroupKey(section.groupKey) != null,
          ),
      ],
    );
    if (choice == null || !mounted || choice.groups.isEmpty) return;
    // 手动移动后组与 sections 不再一一对应（可能空掉/新增），一律按 choice 落盘。
    final List<CollectionSplitGroupChoice> groups = choice.groups;
    final List<int> newIds = <int>[];
    await widget.database.transaction(() async {
      for (final CollectionSplitGroupChoice group in groups) {
        final int id = await widget.database.createMediaCollection(
          group.name,
          collectionType: 'playlist',
        );
        for (final String uid in group.memberIds) {
          await widget.database.addToCollection(id, MediaKind.video, uid);
        }
        newIds.add(id);
      }
      // 前传/续作链：只连真实季（extras 组无先后语义，不入链）。source 用
      // 'local'（本地拆分产生的边，非刮削源），subjectId 用 'collection:<目标id>'
      // ——与唯一键 (collectionId, source, subjectId) 天然兼容且稳定可重入。
      final List<int> seasonIndexes = <int>[
        for (int i = 0; i < groups.length; i++)
          if (groups[i].isSeason) i,
      ];
      for (int k = 0; k < seasonIndexes.length; k++) {
        final int i = seasonIndexes[k];
        final List<CollectionRelationsCompanion> edges =
            <CollectionRelationsCompanion>[];
        if (k > 0) {
          final int prev = seasonIndexes[k - 1];
          edges.add(
            createLocalCollectionRelation(
              collectionId: newIds[i],
              type: CollectionRelationType.prequel,
              targetCollectionId: newIds[prev],
              title: groups[prev].name,
              sortIndex: edges.length,
            ),
          );
        }
        if (k < seasonIndexes.length - 1) {
          final int next = seasonIndexes[k + 1];
          edges.add(
            createLocalCollectionRelation(
              collectionId: newIds[i],
              type: CollectionRelationType.sequel,
              targetCollectionId: newIds[next],
              title: groups[next].name,
              sortIndex: edges.length,
            ),
          );
        }
        await widget.database.replaceCollectionRelations(newIds[i], edges);
      }
    });
    if (!choice.keepOriginal) {
      await deleteMediaCollectionWithAssets(
        widget.database,
        widget.collection.id,
      );
    }
    if (!mounted) return;
    widget.onChanged();
    FushiToast.show(
      msg: t.collection_split_done(n: newIds.length),
      severity: ToastSeverity.success,
    );
    if (!choice.keepOriginal) {
      Navigator.of(context).maybePop();
      return;
    }
    await _reload();
  }

  Future<void> _delete() async {
    // 仅当调用方注入了删本体回调、且合集当前有成员时，才给用户「连同视频一起删」
    // 勾选行；否则退回纯解链删除（老行为，零变化）。确认框统一走 PR-0 的
    // [FushiDestructiveConfirmDialog]（经 [confirmDetailCollectionDelete]）。
    final bool canDeleteMembers =
        widget.onDeleteMembersMedia != null && _members.isNotEmpty;
    final CollectionOwnedSubscriptions subscriptions =
        await CollectionOwnedSubscriptions.load(widget.database, <int>[
          widget.collection.id,
        ]);
    if (!mounted) return;
    final FushiDestructiveConfirmResult? result =
        await confirmDetailCollectionDelete(
          checkboxLabel: canDeleteMembers
              ? t.delete_collection_also_videos
              : null,
          // 成员全是远端流时不摆「同时删除本地文件」——盘上没有文件可删，摆了就是
          // 一个兑现不了的开关（与单删 / 批删同一纪律）。
          localFilesSubtitle:
              canDeleteMembers && _members.any(videoBookHasLocalFiles)
              ? widget.deleteMembersLocalFilesSubtitle
              : null,
          statisticsSubtitle: canDeleteMembers
              ? widget.deleteMembersStatisticsSubtitle
              : null,
          deleteSubscriptionsLabel: subscriptions.deleteLabel,
        );
    if (result == null || !mounted) return;
    // 订阅先于合集删：合集一没，后台下一轮轮询就可能按身份把它重建出来。
    if (result.deleteSubscriptions) {
      await subscriptions.delete(widget.database);
    }
    // 先删各集视频本体（DB 行 + 封面/字幕副本），再解散容器。删视频会连带清各合集
    // 引用行并自删空合集，故随后的解散多为幂等收尾（写合集级墓碑）。解散必须走
    // [deleteMediaCollectionWithAssets]：裸 deleteMediaCollection 只删 DB 行，合集
    // 自有封面会永久留在磁盘上（BUG-1319）。
    if (result.checked && widget.onDeleteMembersMedia != null) {
      await widget.onDeleteMembersMedia!(
        List<VideoBookRow>.of(_members),
        result.deleteLocalFiles,
        result.deleteStatistics,
      );
    }
    await deleteMediaCollectionWithAssets(
      widget.database,
      widget.collection.id,
    );
    if (!mounted) return;
    widget.onChanged();
    Navigator.of(context).maybePop();
  }

  /// 集缩略图 provider：本地行走既有封面链；远端集先认 host 已同步下来的本地封面
  /// 文件，再回落带鉴权的远端 URL（与库页远端占位卡同一条链），都没有 → null。
  ImageProvider? _episodeCover(CollectionEpisodeSlot slot) {
    final String? localPath = slot.coverPath;
    if (localPath != null && localPath.isNotEmpty) {
      return resolveMediaCoverImage(
        kind: MediaKind.video,
        localPath: localPath,
      );
    }
    final RemoteVideoInfo? remote = slot.remote;
    if (remote == null) return null;
    final String? cachedPath = remote.coverPath;
    switch (_coverExists.lookupOptional(cachedPath)) {
      case null:
        return kPendingCoverImage;
      case true:
        return FileImage(File(cachedPath!));
      case false:
        break;
    }
    final String? url = remote.coverUrl;
    final RemoteCoverFetcher? fetcher = widget.remote?.coverFetcher;
    if (url != null && url.isNotEmpty && fetcher != null) {
      return RemoteCoverImage(url, fetcher, cacheKey: remote.id);
    }
    return null;
  }

  /// 打开一个成员槽：本地行走 [MediaCollectionDetailPage.onOpenEpisode]；只在对端的
  /// 走 [MediaCollectionDetailPage.onOpenRemoteEpisode]，并带上本合集**全部**远端成员
  /// 与起播下标，播放器据此建剧集列表 + 跨成员连播。没注入远端回调则不动作。
  void _openSlot(CollectionEpisodeSlot slot) {
    // 播放页回来时重读进度（见 [_awaitingPlaybackReturn]）。
    _awaitingPlaybackReturn = true;
    final VideoBookRow? local = slot.local;
    if (local != null) {
      widget.onOpenEpisode(local);
      return;
    }
    final RemoteVideoInfo? remote = slot.remote;
    final CollectionRemoteContext? context = widget.remote;
    if (remote == null || context == null) return;
    final List<RemoteVideoInfo> members = _remoteMembers;
    context.openEpisode(remote, members, members.indexOf(remote));
  }

  /// 这一集看过没有：有播放位置且没看完。重看到一半的已打勾集同样是「继续观看」
  /// （BUG-3491）。
  bool _isEpisodeStarted(CollectionEpisodeSlot episode) =>
      episode.positionMs > 0 && !_slotProgress(episode).isFinished;

  /// 右下角「继续 / 开始观看」悬浮按钮：与 hero 主按钮同一集。
  Widget? _buildResumeFab() {
    if (_slots.isEmpty) return null;
    final CollectionEpisodeSlot episode = _slots[_continueIndex];
    final bool discPrimary = _discPrimaryKind == DiscPrimaryKind.playDisc;
    return MediaDetailResumeFab(
      buttonKey: const ValueKey<String>('collection-resume-fab'),
      watching: true,
      started: _isEpisodeStarted(episode),
      itemLabel: _episodeDisplayTitle(episode),
      labelOverride: discPrimary ? t.video_disc_play : null,
      icon: discPrimary ? FushiIcons.toc : null,
      onPressed: () => _onPrimaryPlay(episode),
    );
  }

  /// 详情页 hero：数据求值留在本页（背景轮换 / 元信息 chip / 标签 / 人物 / 续播集 /
  /// 主操作），视觉交给共享的 [CollectionDetailHero]（与媒体服务器详情页同一套）。
  ///
  /// 刮削资料缺失时逐项跳过（不占位、不显示「未知」）：未刮过的合集看到的就是
  /// 标题 + 进度 + 播放（Never break userspace）。
  Widget _buildHero() {
    final CollectionEpisodeSlot episode = _slots[_continueIndex];
    final ScrapeMetadata? meta = _scrapeMeta;
    final String? originalTitle =
        _canonicalWork?.originalTitle ?? meta?.originalTitle;
    // 规范作品的标签 / 人物在下方有完整区块（人物表横滑、作品资料卡）；hero 再放
    // 一份只会形成重复内容。旧 v68 资料没有规范详情宿主时才保留 hero 回退，
    // 避免老库凭空丢信息。简介只在 hero 里展示一份（可展开、可选中划词）。
    final bool useLegacyHeroDetails = _canonicalWork == null;
    final bool started = _isEpisodeStarted(episode);
    final bool discPrimary = _discPrimaryKind == DiscPrimaryKind.playDisc;
    final DiscMenuUnavailableReason? discUnavailable = _isDiscEntry
        ? _discUnavailable
        : null;
    final DiscRef? disc = preferredDisc(_discs);
    return CollectionDetailHero(
      backdrop: _heroBackdrop,
      backdropIndex: _heroBackdropIndex,
      cover: _heroCover,
      coverMaterial: ShelfCoverMaterial.glossyPoster,
      logo: _heroLogo,
      title: _canonicalWork?.title ?? _name,
      // 读屏与测试按合集名找 logo。
      semanticsName: _name,
      // 原名与合集名相同就不重复占一行（刮削回写后二者常常一致）。
      originalTitle: originalTitle == _name ? null : originalTitle,
      airDate: _canonicalWork?.premiereDate ?? meta?.airDate,
      // 元信息 chip 行：观看进度恒在（不依赖刮削），年份/话数/评分/时长有刮削资料
      // 才逐项出现（缺的不占位、不写「未知」）。
      chips: _heroChips(meta),
      tagNames: useLegacyHeroDetails
          ? <String>[
              for (final ScrapeTag tag in _heroScrapeTags(meta)) tag.name,
            ]
          : const <String>[],
      credits: useLegacyHeroDetails
          ? <CollectionHeroCredit>[
              for (final VideoMetadataCreditSummary credit in _heroCredits())
                CollectionHeroCredit(
                  kind: credit.creditKind,
                  name: credit.displayName,
                ),
            ]
          : const <CollectionHeroCredit>[],
      summary: useLegacyHeroDetails ? meta?.summary : _canonicalWork?.overview,
      // 原盘开不了菜单时，这一行写明原因（主按钮退回普通播放）；多盘时写主按钮
      // 开的是哪一张。
      continueLabel: discUnavailable != null
          ? discMenuUnavailableText(discUnavailable)
          : discPrimary && _discs.length > 1 && disc != null
          ? '${t.video_disc_play}  ·  ${disc.label}'
          : '${t.collection_continue_progress(n: _continueIndex + 1)}  ·  '
                '${_episodeDisplayTitle(episode)}',
      // 续播行已写明是哪一集，按钮只给动作：有进度「继续观看」、没看过「开始观看」。
      playLabel: discPrimary
          ? t.video_disc_play
          : MediaDetailResumeFab.labelFor(watching: true, started: started),
      playIcon: discPrimary ? FushiIcons.toc : null,
      playButtonKey: const ValueKey<String>('collection-hero-play'),
      onPlay: () => _onPrimaryPlay(episode),
      // hero 不再挂「⋯」：它只是右上角管理菜单的子集，左右两处同样的按钮
      // （BUG-3190）。完整管理只在右上角；hero 只留主操作与两个次按钮。
      secondaryActions: _heroSecondaryActions(),
      // 用户自建标签（可增删）压在简介下面；与作品题材标签是两条正交轴。
      footer: buildDetailTagChips(),
    );
  }

  /// 主按钮旁的 tonal 次按钮：都是本页已有的能力（标签编辑 / 补齐缺集），不新造
  /// 数据逻辑。
  List<Widget> _heroSecondaryActions() {
    return <Widget>[
      if (_slots.isNotEmpty) ..._discSecondaryActions(_slots[_continueIndex]),
      MediaDetailSecondaryButton(
        buttonKey: const ValueKey<String>('collection-hero-tags'),
        icon: FushiIcons.tag,
        label: t.tag_label,
        onPressed: () => unawaited(editDetailCollectionTags()),
      ),
      // 作品级下载入口：不限集号直接搜本作品的资源（此前只能长按某一集再从
      // 「下载本集」进去，且进去是被限定在那一集的）。与补齐缺集同门。
      if (_downloadsAvailable)
        MediaDetailSecondaryButton(
          buttonKey: const ValueKey<String>('collection-hero-download'),
          icon: FushiIcons.search,
          label: t.video_discovery_resource_search,
          onPressed: () => _openDownloadDialog(episodeNumber: null),
        ),
      // 「补齐缺集」打开番剧下载对话框，与另外两个下载入口同门（见
      // [_downloadsAvailable]）。
      if (_downloadsAvailable)
        MediaDetailSecondaryButton(
          buttonKey: const ValueKey<String>('collection-hero-fill-missing'),
          icon: FushiIcons.download,
          label: t.collection_episode_fill_missing,
          onPressed: _slots.isEmpty ? null : _fillMissingEpisodes,
        ),
    ];
  }

  /// 元信息 chip：`2023` / `全 12 话` / `★ 8.1` / `1234 人评分` / `24 分钟` /
  /// `已看完 0/12`。
  ///
  /// 逐项存在才出（缺的不留空档、不写「未知」）。观看进度恒在——它不依赖刮削，是
  /// 本页固有信息，未刮过的合集这一行就只剩它。放送日期不进 chip：它单独一行
  /// 压在标题上方（[CollectionDetailHero.airDate]）。
  List<MediaDetailChip> _heroChips(ScrapeMetadata? meta) {
    final int? year = _canonicalWork?.year;
    final String? status = _canonicalWork?.status?.trim();
    final int episodeCount = meta?.episodeCount ?? _slots.length;
    final double? rating = _canonicalWork?.rating ?? meta?.rating;
    final int? votes = _canonicalWork?.ratingCount ?? meta?.ratingCount;
    final int? runtime = _canonicalWork?.runtimeMinutes;
    final bool allWatched = _slots.isNotEmpty && _watchedCount == _slots.length;
    return <MediaDetailChip>[
      if (year != null) MediaDetailChip('$year', icon: FushiIcons.calendar),
      if (status != null && status.isNotEmpty)
        MediaDetailChip(status, tone: MediaDetailChipTone.secondary),
      if (episodeCount > 0)
        MediaDetailChip(
          t.collection_hero_total_episodes(count: episodeCount),
          icon: FushiIcons.video,
        ),
      if (rating != null && rating > 0) ...<MediaDetailChip>[
        MediaDetailChip(
          '★ ${rating.toStringAsFixed(1)}',
          tone: MediaDetailChipTone.primary,
        ),
        if (votes != null && votes > 0)
          MediaDetailChip(t.video_scrape_rating_votes(count: votes)),
      ],
      if (runtime != null && runtime > 0)
        MediaDetailChip(
          t.video_runtime_minutes(n: runtime),
          icon: FushiIcons.timer,
        ),
      MediaDetailChip(
        t.collection_watched_progress(
          done: _watchedCount,
          total: _slots.length,
        ),
        icon: FushiIcons.success,
        tone: allWatched
            ? MediaDetailChipTone.tertiary
            : MediaDetailChipTone.neutral,
      ),
    ];
  }

  /// hero 展示的**作品标签**（题材/类型，来自刮削源，按热度降序取前 6）。
  ///
  /// 与合集自己的**用户标签**（`buildDetailTagChips`，hero 下方那排）是两条正交轴：
  /// 这里是「这部作品是什么题材」（源给的，只读），那里是「我把它归到哪些自建分类」
  /// （用户建的，可增删）。两者都该有，不互相取代。
  List<ScrapeTag> _heroScrapeTags(ScrapeMetadata? meta) {
    final List<ScrapeTag> tags = meta?.tags ?? const <ScrapeTag>[];
    return tags.take(6).toList();
  }

  /// 人物关系在固定高 hero 内只占一条横向轨道；各类最多两项，既能让导演、演员、
  /// 声优都露出，又不会因完整 cast 列表挤掉简介和播放按钮。
  List<VideoMetadataCreditSummary> _heroCredits() {
    final List<VideoMetadataCreditSummary> credits =
        _workCredits?.credits ?? const <VideoMetadataCreditSummary>[];
    return <VideoMetadataCreditSummary>[
      for (final String kind in const <String>[
        'director',
        'actor',
        'voice_actor',
      ])
        ...credits
            .where(
              (VideoMetadataCreditSummary credit) => credit.creditKind == kind,
            )
            .take(2),
    ];
  }

  /// 作品资料区：事实行在本页求值，视觉交给共享 [CollectionWorkDetailsSection]。
  Widget _buildWorkDetailsSection() {
    final VideoMetadataWorkRow? work = _canonicalWork;
    final Map<String, List<String>> terms = <String, List<String>>{};
    for (final VideoMetadataTermRow term in _workTerms) {
      terms.putIfAbsent(term.kind, () => <String>[]).add(term.name);
    }
    final List<VideoMetadataIdentitySummary> identities =
        _workCredits?.identities ?? const <VideoMetadataIdentitySummary>[];
    final List<(String, String)> facts = <(String, String)>[
      if (terms['genre']?.isNotEmpty == true)
        (t.video_work_genres, terms['genre']!.join(' · ')),
      if (terms['keyword']?.isNotEmpty == true)
        (t.video_work_keywords, terms['keyword']!.join(' · ')),
      if (terms['studio']?.isNotEmpty == true)
        (t.video_work_studios, terms['studio']!.join(' · ')),
      if (terms['country']?.isNotEmpty == true)
        (
          t.video_work_countries,
          formatVideoCountriesForDisplay(terms['country']!).join(' · '),
        ),
      if (work?.contentRating?.trim().isNotEmpty == true)
        (t.video_work_content_rating, work!.contentRating!),
      if (identities.isNotEmpty)
        (
          t.video_work_external_ids,
          identities
              .map(
                (VideoMetadataIdentitySummary identity) =>
                    '${identity.provider.toUpperCase()}: ${identity.externalId}',
              )
              .join(' · '),
        ),
    ];
    // 简介已在 hero 里展示（可展开、可选中）；这里只拿它判空——有简介就不是
    // 「资料待补」。
    return CollectionWorkDetailsSection(
      overview: work?.overview ?? _scrapeMeta?.summary,
      showOverview: false,
      facts: facts,
      pendingText: t.video_work_metadata_pending,
    );
  }

  Widget _buildCreditsSection(FushiDesignTokens tokens) {
    final List<VideoMetadataCreditSummary> all =
        _workCredits?.credits ?? const <VideoMetadataCreditSummary>[];
    final List<VideoMetadataCreditSummary> voice = all
        .where(
          (VideoMetadataCreditSummary credit) =>
              credit.creditKind == 'voice_actor',
        )
        .toList(growable: false);
    final List<VideoMetadataCreditSummary> crew = all
        .where(
          (VideoMetadataCreditSummary credit) =>
              credit.creditKind != 'voice_actor',
        )
        .toList(growable: false);
    if (voice.isEmpty && crew.isEmpty) return const SizedBox.shrink();
    // 人物表横滑（圆形头像卡）：区块标题自带上间距，两条之间不再另垫。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (voice.isNotEmpty)
          _buildCreditRail(t.video_work_voice_roles, voice, tokens),
        if (crew.isNotEmpty)
          _buildCreditRail(t.video_work_cast_crew, crew, tokens),
      ],
    );
  }

  Widget _buildCreditRail(
    String title,
    List<VideoMetadataCreditSummary> credits,
    FushiDesignTokens tokens,
  ) => VideoCreditRail(title: title, credits: credits, tokens: tokens);

  Widget _buildExtrasSection(FushiDesignTokens tokens) {
    if (_workExtras.isEmpty) return const SizedBox.shrink();
    final List<VideoMetadataExtraRow> trailers = _workExtras
        .where(
          (VideoMetadataExtraRow extra) =>
              extra.kind == 'trailer' || extra.kind == 'teaser',
        )
        .toList(growable: false);
    final List<VideoMetadataExtraRow> extras = _workExtras
        .where(
          (VideoMetadataExtraRow extra) =>
              extra.kind != 'trailer' && extra.kind != 'teaser',
        )
        .toList(growable: false);
    return Padding(
      padding: EdgeInsets.only(top: tokens.spacing.section),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (trailers.isNotEmpty)
            _buildExtraRail(t.video_work_trailers, trailers, tokens),
          if (trailers.isNotEmpty && extras.isNotEmpty)
            SizedBox(height: tokens.spacing.section),
          if (extras.isNotEmpty)
            _buildExtraRail(t.video_work_extras, extras, tokens),
        ],
      ),
    );
  }

  Widget _buildExtraRail(
    String title,
    List<VideoMetadataExtraRow> extras,
    FushiDesignTokens tokens,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        MediaDetailSectionHeader(
          title,
          count: extras.length,
          padding: EdgeInsets.fromLTRB(
            tokens.spacing.page,
            0,
            tokens.spacing.page,
            tokens.spacing.card,
          ),
        ),
        SizedBox(
          height: 210,
          child: HorizontalDragScrollable(
            child: ListView.separated(
              padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
              scrollDirection: Axis.horizontal,
              itemCount: extras.length,
              separatorBuilder: (_, __) => SizedBox(width: tokens.spacing.card),
              itemBuilder: (BuildContext context, int index) {
                final VideoMetadataExtraRow extra = extras[index];
                final String? thumb = extra.thumbnailPath ?? extra.thumbnailUrl;
                return SizedBox(
                  width: 300,
                  child: FushiCard(
                    padding: EdgeInsets.zero,
                    onTap: () => unawaited(_openWorkExtra(extra)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Expanded(
                          child: Stack(
                            fit: StackFit.expand,
                            children: <Widget>[
                              // 存在性读异步记忆表（BUG-3756）；还在探测时先画底色块。
                              if (thumb != null &&
                                  _coverExists.lookup(thumb) == null)
                                const ColoredBox(color: Color(0x1FFFFFFF))
                              else if (thumb != null &&
                                  _coverExists.lookup(thumb)!)
                                Image.file(
                                  File(thumb),
                                  fit: BoxFit.cover,
                                  // BUG-2496：坏缩略图解码失败退回底色块，不当致命错误。
                                  errorBuilder: (_, Object error, __) {
                                    ErrorLogService.instance.logDiagnostic(
                                      'MediaCollectionDetailPage.extra.coverDecode',
                                      '$thumb: $error',
                                    );
                                    return const ColoredBox(
                                      color: Color(0x1FFFFFFF),
                                    );
                                  },
                                )
                              else if (thumb != null)
                                Image(
                                  image: AppCachedHttpImage(thumb),
                                  fit: BoxFit.cover,
                                )
                              else
                                const ColoredBox(color: Color(0x1FFFFFFF)),
                              const Center(
                                child: CircleAvatar(
                                  child: FushiIcon(FushiIcons.play),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(10),
                          child: Text(
                            extra.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _openWorkExtra(VideoMetadataExtraRow extra) async {
    final String? bookUid = extra.bookUid;
    if (bookUid != null) {
      final VideoBookRepository repo = VideoBookRepository(widget.database);
      final VideoBookRow? local = await repo.getByBookUid(bookUid);
      if (local != null && mounted) {
        await Navigator.push<void>(
          context,
          adaptivePageRoute<void>(
            context: context,
            builder: (_) =>
                VideoFushiPage.neutralized(bookUid: local.bookUid, repo: repo),
          ),
        );
        return;
      }
    }
    final String? url = extra.remoteUrl;
    if (url == null) return;
    try {
      final launch = await buildOnlineVideoExtraLaunch(
        id: extra.extraKey,
        title: extra.title,
        url: url,
      );
      if (!mounted) return;
      final VideoBookRepository repo = VideoBookRepository(widget.database);
      await Navigator.push<void>(
        context,
        adaptivePageRoute<void>(
          context: context,
          builder: (_) => VideoFushiPage.neutralizedRemote(
            info: launch.info,
            repo: repo,
            client: launch.client,
          ),
        ),
      );
    } on Object {
      if (mounted) FushiToast.show(msg: t.video_load_failed_generic);
    }
  }

  Widget _buildEpisodeSection(FushiDesignTokens tokens) {
    return Padding(
      padding: EdgeInsets.only(
        top: tokens.spacing.section,
        bottom: tokens.spacing.section,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          CollectionSectionTitle(
            t.video_episode_list,
            count: _visibleSlots.length,
          ),
          // 多季合集：季分段（浮动胶囊）紧贴标题行、在集列表之上——用户一进详情页
          // 就看得见分季。
          if (_hasSeasonTabs) _buildSeasonTabs(),
          // 多选入口：选集后批量标记已看 / 未看（底栏见 [_buildSelectionBar]）。
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
              child: FushiTextButton(
                key: const ValueKey<String>('collection-select-toggle'),
                onPressed: _toggleSelecting,
                child: Text(
                  _selecting ? t.dialog_cancel : t.collection_select_episodes,
                ),
              ),
            ),
          ),
          SizedBox(height: tokens.spacing.card),
          // hayase 式宽列表卡（TODO-2491 用户拍板）：每集一张横向卡（16:9 缩略图 +
          // 「N. 集名」+ 集简介 + 观看进度），**默认全量可见、不再折叠**；宽屏两列。
          // 旧的横滚剧集轨已移除：列表默认展开后轨道与列表讲同一份内容（轨道无简介/
          // 进度，信息严格少于列表），续播定位由 hero 播放按钮 + 列表续播卡高亮承载，
          // 两处并存只剩重复。轨道组件保留给播放器内剧集面板（video_episode_panel）。
          Padding(
            // key 带当前季：换季时整段列表重建，不复用上一季的拖拽 State。
            key: ValueKey<String>(
              'episode-list'
              '${_selectedSection == null ? '' : '-${_selectedSection!.groupKey}'}',
            ),
            padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
            child: _buildEpisodeGrid(),
          ),
        ],
      ),
    );
  }

  /// 季分段（M3E 浮动胶囊）：多季合集**首屏**就能看见并切季，切换后
  /// 下面的剧集轨与管理列表一起换成该季（分季若只做在默认折叠的管理
  /// 列表里，用户进页面根本看不见）。单季合集不渲染本条（[_hasSeasonTabs] 门）。
  Widget _buildSeasonTabs() {
    return CollectionSeasonTabBar(
      controller: _seasonTabs!,
      labels: <String>[
        for (final CollectionSeasonSection<CollectionEpisodeSlot> section
            in _sections)
          _groupLabel(section.groupKey),
      ],
      tabKeys: <Key>[
        for (final CollectionSeasonSection<CollectionEpisodeSlot> section
            in _sections)
          ValueKey<String>('collection-season-tab-${section.groupKey}'),
      ],
    );
  }

  /// 集列表（hayase 式宽卡网格）：宽度 ≥ [kCollectionEpisodeTwoColumnMinWidth] 两列，
  /// 否则一列。拖拽重排/右键/长按菜单由 [FushiReorderableGrid] 统一接管（鼠标
  /// 按住即拖 + 右键菜单；触摸长按与库页卡片同一时机直接出菜单，菜单「排序」进入
  /// 排序模式后按住即拖——BUG-778 缩放安全一族）。
  /// 分季时只列本季（[_visibleMembers]），拖拽是节内重排，由 [_onReorder] 拼回
  /// 全序落盘。
  Widget _buildEpisodeGrid() {
    final List<CollectionEpisodeSlot> visible = _visibleSlots;
    // 区间选 / 全选按可见顺序（本季）；顺序变了锚点作废，底栏计数补一帧。
    if (_selection.setVisibleOrder(
          loose: <String>[
            for (final CollectionEpisodeSlot s in visible) s.entryKey,
          ],
          collections: const <int>[],
        ) &&
        _selecting) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        const double spacing = 12;
        final int columns = collectionEpisodeColumns(constraints.maxWidth);
        final double columnWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return FushiReorderableGrid(
          itemCount: visible.length,
          crossAxisCount: columns,
          childAspectRatio: columnWidth / kCollectionEpisodeCardHeight,
          crossAxisSpacing: spacing,
          mainAxisSpacing: spacing,
          feedbackBorderRadius: FushiBorderRadius.card,
          reordering: _reordering,
          keyForIndex: (int i) =>
              ValueKey<String>('collection-episode-row-${visible[i].entryKey}'),
          // 多选态不重排（拖动只会误操作）；点击 = 勾选 / 取消勾选。
          onReorder: _selecting ? (int from, int to) {} : _onReorder,
          onActivateItem: (int i) {
            if (_selecting) {
              _tapSelect(visible[i]);
              return;
            }
            // 桌面 Ctrl（macOS ⌘）/ Shift 点击直接进多选并选中该集。
            if (selectionEntryModifierPressed(context)) {
              setState(
                () => _selection.enterWith(
                  SelectionSlot.loose(visible[i].entryKey),
                ),
              );
              return;
            }
            _openSlot(visible[i]);
          },
          onContextMenu: (int i, Offset globalPosition) =>
              _showEpisodeMenu(visible[i], globalPosition),
          // 2026-10 动效重做：集卡首屏错峰进场（窗口在页级
          // [FushiEntranceScope]，换季时重开）。只包装卡，不改网格几何。
          itemBuilder: (BuildContext context, int i) => FushiStaggeredEntrance(
            index: i,
            child: _selecting
                ? _withSelectionOverlay(
                    _buildEpisodeCard(context, visible[i], i),
                    selected: _selection.isSelected(
                      SelectionSlot.loose(visible[i].entryKey),
                    ),
                  )
                : _buildEpisodeCard(context, visible[i], i),
          ),
        );
      },
    );
  }

  /// 单张集卡：序号 / 集名 / 集简介 / 观看状态 / 规格摘要在本页求值，视觉交给
  /// 共享 [CollectionEpisodeCard]（hayase 式宽卡，整卡 IgnorePointer——手势归
  /// [FushiReorderableGrid]）；键盘/手柄焦点不走指针，[FushiFocusTarget] 照常可
  /// 聚焦、Enter 开播。
  Widget _buildEpisodeCard(
    BuildContext context,
    CollectionEpisodeSlot episode,
    int index,
  ) {
    Widget buildCard(Widget? downloadBadge) => CollectionEpisodeCard(
      thumb: collectionEpisodeThumb(context, _episodeCover(episode)),
      // BUG-1544：序号跟随文件名解析出的真实集数（缺集时不再用顺位号冒充）；
      // 解析不出时回退顺位号。
      number: '${_episodeDisplayNumber(episode, index)}',
      title: _episodeDisplayTitle(episode),
      identityLabel: _episodeIdentityLabel(episode),
      summary: _episodeSummary(episode),
      // 播出日 · 时长（规范分集资料有才出）。
      meta: _episodeMeta(episode),
      completed: episode.completed,
      positionMs: episode.positionMs,
      progress: _episodeProgress(episode),
      isContinue: episode.entryKey == _continueKey,
      // 云角标 = 这一集只在对端（与库页远端占位卡同一枚角标）。
      isRemote: episode.isRemote,
      downloadBadge: downloadBadge,
      // v95：该集的规格摘要（`1080p · HDR10 · HEVC`），挤在状态行右端。
      trailingStatus: VideoSpecsInlineLine(
        service: widget.videoSpecs,
        filePath: episode.local?.videoPath,
      ),
    );
    // 远端集 + 库页注入了下载管理器 → 集卡跟着该集任务快照重绘（进度环 / 失败
    // 角标）。任务键 = 远端集 id = entryKey，与库页远端占位卡同一张表；管理器是
    // ChangeNotifier，用 ListenableBuilder 订阅而不是把本页改成 Consumer（既有
    // 测试不挂 ProviderScope）。
    final InterconnectDownloadManager? downloads = widget.remote?.downloads;
    final Widget card = downloads == null || !episode.isRemote
        ? buildCard(null)
        : ListenableBuilder(
            listenable: downloads,
            builder: (BuildContext context, Widget? _) => buildCard(
              _episodeDownloadBadge(downloads.taskFor(episode.entryKey)),
            ),
          );
    if (FushiFocusRoot.maybeControllerOf(context) == null) return card;
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _openSlot(episode);
            return null;
          },
        ),
      },
      child: FushiFocusTarget(
        id: FushiFocusId('collection-episode-${episode.entryKey}'),
        child: card,
      ),
    );
  }

  /// 某远端集的下载态角标：进行中 → 进度环；失败 → 失败角标（tooltip 带真实错误
  /// 文本）；无任务 / 已完成 → null（集卡照旧画云角标）。与库页远端占位卡
  /// `_remoteDownloadBadge` 同一套徽章、同一套 key 前缀，测试同一把 finder。
  Widget? _episodeDownloadBadge(InterconnectDownloadTask? task) {
    if (task == null) return null;
    switch (task.status) {
      case InterconnectDownloadStatus.running:
        return RemoteDownloadProgressBadge(
          key: ValueKey<String>('collection_episode_downloading_${task.id}'),
          progress: task.progress,
          receivedBytes: task.receivedBytes,
          totalBytes: task.totalBytes,
          tooltip: t.remote_video_downloading,
        );
      case InterconnectDownloadStatus.failed:
        return RemoteDownloadFailedBadge(
          key: ValueKey<String>(
            'collection_episode_download_failed_${task.id}',
          ),
          tooltip: task.error == null || task.error!.isEmpty
              ? t.remote_video_download_failed
              : '${t.remote_video_download_failed}: ${task.error}',
        );
      case InterconnectDownloadStatus.paused:
      case InterconnectDownloadStatus.completed:
        return null;
    }
  }

  /// 集卡上下文菜单（右键 / 触摸长按）。管理能力从旧管理列表的行内
  /// 按钮收进本菜单（拖拽排序仍是直接拖卡）。
  ///
  /// 容器走 [showMediaItemActions]，与库页卡片同一套：右键在指针处弹右键菜单
  /// （锚点由 [FushiReorderableGrid] 在同步派发期间经 `activeContextMenuAnchor`
  /// 给出），触摸长按弹抽屉 / 对话框。此前一律 `showFushiMenu` 小菜单，右键与长按
  /// 长得一样。菜单必须在第一个 await 之前弹出，才读得到锚点。
  Future<void> _showEpisodeMenu(
    CollectionEpisodeSlot episode,
    Offset globalPosition,
  ) async {
    // 这一集在本机已有原始文件（流媒体 / 远端行的 videoPath 是 URL，不算）：下载
    // 本集对它没有意义，换成「打开文件位置」。纯函数判据，不吃 IO。
    final VideoBookRow? local = episode.local;
    final bool hasLocalFiles = local != null && videoBookHasLocalFiles(local);
    // 互联下载的管理动作（反馈 _sZllpFQWm / BUG-3698）：与发起下载的「下载远端集」
    // 同一处、对同一集，任何平台都可达——不依赖「浏览 → 下载」，也不问商店合规门
    // （互联下载不是受限能力）。
    final InterconnectDownloadManager? downloads = widget.remote?.downloads;
    final String? taskId = episode.isRemote && downloads != null
        ? downloads.taskFor(episode.entryKey)?.id
        : null;
    final bool canDownloadToDevice =
        episode.remote != null &&
        widget.remote?.downloadMembers != null &&
        taskId == null;
    final bool canDeleteLocalCopy =
        local != null &&
        widget.remote?.deleteLocalCopy != null &&
        _peerCopyKeys.contains(local.bookUid);
    final _EpisodeMenuAction? action =
        await showMediaItemActions<_EpisodeMenuAction>(
          context: context,
          builder: (BuildContext menuContext) {
            void pick(_EpisodeMenuAction value) =>
                Navigator.pop(menuContext, value);
            return MediaItemDialogFrame(
              title: _episodeDisplayTitle(episode),
              showLaunchAction: false,
              listActions: <DialogListAction>[
                if (canDownloadToDevice)
                  DialogListAction(
                    label: t.remote_video_download,
                    icon: FushiIcons.cloudDownload,
                    group: DialogActionGroup.content,
                    onPressed: () => pick(_EpisodeMenuAction.downloadToDevice),
                  ),
                if (taskId != null && downloads!.canPause(taskId))
                  DialogListAction(
                    label: t.download_task_pause,
                    icon: FushiIcons.pause,
                    group: DialogActionGroup.content,
                    onPressed: () => pick(_EpisodeMenuAction.pauseDownload),
                  ),
                if (taskId != null && downloads!.canRestart(taskId))
                  DialogListAction(
                    label: t.download_task_resume,
                    icon: FushiIcons.play,
                    group: DialogActionGroup.content,
                    onPressed: () => pick(_EpisodeMenuAction.resumeDownload),
                  ),
                if (taskId != null && downloads!.canCancel(taskId))
                  DialogListAction(
                    label: t.interconnect_download_cancel,
                    icon: FushiIcons.close,
                    group: DialogActionGroup.content,
                    onPressed: () => pick(_EpisodeMenuAction.cancelDownload),
                  ),
                if (_downloadsAvailable && !hasLocalFiles)
                  DialogListAction(
                    label: t.collection_episode_download,
                    icon: FushiIcons.download,
                    group: DialogActionGroup.content,
                    onPressed: () => pick(_EpisodeMenuAction.download),
                  ),
                // 「打开文件位置」：与视频库卡同一条动作、同一份文案；移动端没有文件管理器
                // 契约（[currentRevealHost] 为 null），整条不出。
                if (hasLocalFiles && currentRevealHost() != null)
                  DialogListAction(
                    label: t.media_file_location_open,
                    icon: FushiIcons.folderOpen,
                    group: DialogActionGroup.organize,
                    onPressed: () => pick(_EpisodeMenuAction.openFileLocation),
                  ),
                // 标记已看 / 未看：本地集写库，媒体服务器的远端集同步到服务器；其它远端
                // 源没有这个协议（[CollectionRemoteContext.playedMark] 为 null）就不出。
                if (_canMarkWatched(episode)) ...<DialogListAction>[
                  DialogListAction(
                    label: episode.completed
                        ? t.video_mark_unwatched
                        : t.video_mark_watched,
                    icon: episode.completed
                        ? FushiIcons.visibilityOff
                        : FushiIcons.check,
                    group: DialogActionGroup.progress,
                    onPressed: () => pick(
                      episode.completed
                          ? _EpisodeMenuAction.markUnwatched
                          : _EpisodeMenuAction.markWatched,
                    ),
                  ),
                  DialogListAction(
                    label: t.video_mark_watched_through,
                    icon: FushiIcons.checklist,
                    group: DialogActionGroup.progress,
                    onPressed: () =>
                        pick(_EpisodeMenuAction.markWatchedThrough),
                  ),
                ],
                DialogListAction(
                  label: t.collection_select_episodes,
                  icon: FushiIcons.selectAll,
                  group: DialogActionGroup.organize,
                  onPressed: () => pick(_EpisodeMenuAction.select),
                ),
                // v95：完整技术规格（音轨/字幕轨在集卡上放不下，只能进弹窗）。
                // 仅本地文件有——远端占位集探不了。
                if (episode.local != null && widget.videoSpecs != null)
                  DialogListAction(
                    label: t.video_specs_title,
                    icon: FushiIcons.info,
                    group: DialogActionGroup.content,
                    onPressed: () => pick(_EpisodeMenuAction.mediaInfo),
                  ),
                // 「清除观看进度」：只对本地行且确有观看痕迹的集出现（远端占位集的进度
                // 归 host，本地没得清）。用户误点开下一集又退出后，「继续看」会被钉在那一集
                // （BUG-1542 的最近播放锚点），这条动作让它回到上一集看完后的下一集。
                if (episode.local case final VideoBookRow local
                    when videoBookHasWatchTrace(local))
                  DialogListAction(
                    label: t.video_watch_progress_clear,
                    icon: FushiIcons.restart,
                    group: DialogActionGroup.progress,
                    onPressed: () =>
                        pick(_EpisodeMenuAction.clearWatchProgress),
                  ),
                // 集级 UserVerified（Shoko）：把这个文件钉到规范作品的某一季某一集，之后
                // 每次刮削都保留。只对本地文件、且合集已刮出剧集作品时出现。
                if (episode.local != null && _canonicalWork?.mediaType == 'tv')
                  DialogListAction(
                    label: t.collection_episode_link_manual,
                    icon: FushiIcons.pin,
                    group: DialogActionGroup.organize,
                    onPressed: () => pick(_EpisodeMenuAction.pinEpisode),
                  ),
                DialogListAction(
                  label: t.collection_remove_member,
                  icon: FushiIcons.linkOff,
                  group: DialogActionGroup.organize,
                  onPressed: () =>
                      pick(_EpisodeMenuAction.removeFromCollection),
                ),
              ],
              dangerActions: <DialogDangerAction>[
                if (canDeleteLocalCopy)
                  DialogDangerAction(
                    label: t.collection_episode_local_copy_delete,
                    icon: FushiIcons.delete,
                    onPressed: () => pick(_EpisodeMenuAction.deleteLocalCopy),
                  ),
              ],
            );
          },
        );
    if (!mounted) return;
    switch (action) {
      case _EpisodeMenuAction.downloadToDevice:
        await widget.remote?.downloadMembers?.call(
          _collection,
          <RemoteVideoInfo>[episode.remote!],
        );
        if (mounted) await _reload();
      case _EpisodeMenuAction.pauseDownload:
        downloads?.pause(taskId!);
      case _EpisodeMenuAction.resumeDownload:
        await downloads?.resume(taskId!);
        if (mounted) await _reload();
      case _EpisodeMenuAction.cancelDownload:
        await downloads?.cancel(taskId!);
      case _EpisodeMenuAction.deleteLocalCopy:
        final bool deleted =
            await widget.remote?.deleteLocalCopy?.call(local!) ?? false;
        if (!deleted || !mounted) return;
        widget.onChanged();
        await _reload();
      case _EpisodeMenuAction.markWatched:
        await _markEpisodes(<CollectionEpisodeSlot>[episode], watched: true);
      case _EpisodeMenuAction.markUnwatched:
        await _markEpisodes(<CollectionEpisodeSlot>[episode], watched: false);
      case _EpisodeMenuAction.markWatchedThrough:
        await _markEpisodes(
          itemsThrough(
            _visibleSlots,
            _visibleSlots.indexOf(episode),
          ).where(_canMarkWatched).toList(),
          watched: true,
        );
      case _EpisodeMenuAction.select:
        setState(
          () => _selection.enterWith(SelectionSlot.loose(episode.entryKey)),
        );
      case _EpisodeMenuAction.download:
        _openDownloadDialog(episodeNumber: _episodeNumberOf(episode));
      case _EpisodeMenuAction.openFileLocation:
        await _openEpisodeFileLocation(episode);
      case _EpisodeMenuAction.mediaInfo:
        await _showEpisodeMediaInfo(episode);
      case _EpisodeMenuAction.clearWatchProgress:
        await _clearEpisodeWatchProgress(episode);
      case _EpisodeMenuAction.pinEpisode:
        await _pinEpisodeBinding(episode);
      case _EpisodeMenuAction.removeFromCollection:
        await _removeEpisode(episode);
      case null:
        break;
    }
  }

  /// 这一集能不能手动标记：本地行总是可以；纯远端集要来源支持（媒体服务器）。
  bool _canMarkWatched(CollectionEpisodeSlot episode) =>
      episode.local != null || widget.remote?.playedMark != null;

  /// 批量标记已看 / 未看，一次 [setVideosWatched]：本地行（含本地入库的媒体服务器
  /// 条目，顺带回写服务器）写库并盖同步戳；纯远端集与本地集在当前来源上的镜像经
  /// 来源的「已播放」协议标到服务器（同一条目只发一次）。之后重读本页与库页；
  /// 服务器失败只提示条数，并如实区分「本地已更新」与「什么都没改」。
  Future<void> _markEpisodes(
    List<CollectionEpisodeSlot> episodes, {
    required bool watched,
  }) async {
    if (episodes.isEmpty) return;
    final RemoteVideoPlayedMark? marker = widget.remote?.playedMark;
    final List<String> localUids = <String>[
      for (final CollectionEpisodeSlot e in episodes)
        if (e.local != null) e.local!.bookUid,
    ];
    final List<String> remoteIds = <String>[
      for (final CollectionEpisodeSlot e in episodes)
        if (e.local == null && e.remote != null)
          e.remote!.id
        else if (marker != null && e.remoteMirror != null)
          e.remoteMirror!.id,
    ];
    final WatchedMarkResult result;
    try {
      result = await setVideosWatched(
        db: widget.database,
        watched: watched,
        localUids: localUids,
        remoteIds: remoteIds,
        remoteMarker: marker,
      );
    } catch (e, stack) {
      // 服务器失败在 setVideosWatched 内部计数；走到这里的是本地写库失败。
      ErrorLogService.instance.log('CollectionDetail.markWatched', e, stack);
      FushiToast.show(msg: t.video_mark_failed, severity: ToastSeverity.error);
      return;
    }
    if (remoteIds.isNotEmpty || result.remoteChanged > 0) {
      widget.remote?.onPlayedMarked?.call();
    }
    if (!mounted) return;
    widget.onChanged();
    await _reload();
    if (!mounted) return;
    FushiToast.show(
      msg: watchedMarkFeedback(result, watched: watched),
      severity: result.hasFailures
          ? ToastSeverity.error
          : ToastSeverity.success,
    );
  }

  bool get _selecting => _selection.active;

  void _exitSelection() => setState(_selection.exit);

  void _toggleSelecting() => setState(_selection.toggleMode);

  void _tapSelect(CollectionEpisodeSlot episode) => setState(
    () => _selection.applyTap(
      SelectionSlot.loose(episode.entryKey),
      selectionTapKind(),
    ),
  );

  void _selectAllInSeason() => setState(
    () => _selection.selectAll(
      loose: <String>[
        for (final CollectionEpisodeSlot s in _visibleSlots) s.entryKey,
      ],
      collections: const <int>[],
    ),
  );

  Future<void> _markSelected({required bool watched}) async {
    final Set<String> keys = _selection.looseKeys;
    final List<CollectionEpisodeSlot> targets = <CollectionEpisodeSlot>[
      for (final CollectionEpisodeSlot s in _visibleSlots)
        if (keys.contains(s.entryKey) && _canMarkWatched(s)) s,
    ];
    setState(_selection.exit);
    await _markEpisodes(targets, watched: watched);
  }

  /// 多选态底栏：已选数 + 全选本季 + 标记已看 / 未看 + 取消。走共享底部动作条
  /// （MD3 贴底 surfaceContainer 条 / Apple 悬浮玻璃面）；按钮放进可换行的 Wrap，
  /// 窄屏放不下一行时折到下一行。
  Widget? _buildSelectionBar() {
    if (!_selecting) return null;
    return FushiBottomActionBar(
      message: Text(
        t.collection_selected_count(n: _selection.length),
        key: const ValueKey<String>('collection-selection-count'),
      ),
      leading: Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          FushiTextButton(
            onPressed: _selectAllInSeason,
            child: Text(t.collection_select_all_in_season),
          ),
          FushiTextButton(
            key: const ValueKey<String>('collection-selection-unwatched'),
            onPressed: _selection.isEmpty
                ? null
                : () => unawaited(_markSelected(watched: false)),
            child: Text(t.video_mark_unwatched),
          ),
          FushiFilledButton(
            key: const ValueKey<String>('collection-selection-watched'),
            onPressed: _selection.isEmpty
                ? null
                : () => unawaited(_markSelected(watched: true)),
            child: Text(t.video_mark_watched),
          ),
          FushiTextButton(
            onPressed: _exitSelection,
            child: Text(t.dialog_cancel),
          ),
        ],
      ),
    );
  }

  /// 多选态集卡的选中描边 + 右上角勾选标。整层 IgnorePointer：手势仍归网格。
  Widget _withSelectionOverlay(Widget card, {required bool selected}) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Stack(
      children: <Widget>[
        card,
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: FushiBorderRadius.card,
                border: selected
                    ? Border.all(color: scheme.primary, width: 2)
                    : null,
                color: selected ? scheme.primary.withValues(alpha: 0.08) : null,
              ),
            ),
          ),
        ),
        Positioned(
          top: 8,
          right: 8,
          child: IgnorePointer(
            child: FushiIcon(
              selected ? FushiIcons.check : FushiIcons.radioUnchecked,
              size: 22,
              color: selected ? scheme.primary : scheme.outline,
            ),
          ),
        ),
      ],
    );
  }

  /// 在系统文件管理器里定位并选中这一集的原始文件。候选表与视频库卡同源
  /// （[localVideoFileCandidates]：`videoPath` 在前、播放列表各集在后），首选被外部
  /// 删掉时顺延；全都打不开才提示。
  Future<void> _openEpisodeFileLocation(CollectionEpisodeSlot episode) async {
    final VideoBookRow? local = episode.local;
    if (local == null) return;
    final bool revealed = await revealFirstOf(
      localVideoFileCandidates(
        videoPath: local.videoPath,
        playlistJson: local.playlistJson,
      ),
    );
    if (revealed || !mounted) return;
    FushiToast.show(
      msg: t.media_file_location_failed,
      severity: ToastSeverity.error,
    );
  }

  /// 手动指定这个文件对应的季集（Shoko UserVerified）：写覆盖表并立刻改绑分集行，
  /// 重载后集卡的集名 / AniDB 角标跟着新行走。
  Future<void> _pinEpisodeBinding(CollectionEpisodeSlot episode) async {
    final VideoBookRow? local = episode.local;
    final VideoMetadataWorkRow? work = _canonicalWork;
    if (local == null || work == null) return;
    final bool changed = await pinVideoEpisodeBinding(
      context: context,
      database: widget.database,
      workId: work.id,
      bookUid: local.bookUid,
    );
    if (!changed || !mounted) return;
    widget.onChanged();
    await _reload();
  }

  /// 清除某一集的观看进度（行级四列 + 互联 LWW 镜像键，见
  /// [VideoBookRepository.clearWatchProgress]），然后重查成员槽：集卡「已看到」
  /// 徽标 / 完成勾、头部「继续看」目标都从成员进度现场推导，重载即刷新。
  Future<void> _clearEpisodeWatchProgress(CollectionEpisodeSlot episode) async {
    final VideoBookRow? local = episode.local;
    if (local == null) return;
    // 与视频库卡菜单同一确认框 / 同一落地（可选撤最近一次会话或清全部统计）。
    final StudyRecordResetScope? records = await showLibraryProgressResetDialog(
      context,
      title: t.video_watch_progress_clear,
      message: t.library_progress_reset_video_message,
      itemTitle: local.title,
    );
    if (records == null || !mounted) return;
    try {
      await resetVideoWatchState(
        db: widget.database,
        repo: VideoBookRepository(widget.database),
        bookUid: local.bookUid,
        title: local.title,
        records: records,
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('CollectionDetail.clearWatch', e, stack);
      if (!mounted) return;
      FushiToast.show(
        msg: t.library_progress_reset_failed,
        severity: ToastSeverity.error,
      );
      await _reload();
      return;
    }
    if (!mounted) return;
    widget.onChanged();
    FushiToast.show(
      msg: t.video_watch_progress_cleared,
      severity: ToastSeverity.success,
    );
    await _reload();
  }

  /// 某一集的完整技术规格弹窗。
  ///
  /// 规格是**文件级**事实，所以入口挂在集上而不是作品上——同一合集里各集的分辨率、
  /// 音轨完全可以不同，作品级摆一份规格是在骗人。
  Future<void> _showEpisodeMediaInfo(CollectionEpisodeSlot episode) async {
    final String? path = episode.local?.videoPath;
    if (path == null || path.isEmpty) return;
    await showAppDialog<void>(
      context: context,
      builder: (BuildContext context) => FushiAlertDialog(
        title: Text(_episodeDisplayTitle(episode)),
        content: SingleChildScrollView(
          child: VideoSpecsPanel(
            service: widget.videoSpecs,
            filePath: path,
            showTitle: false,
          ),
        ),
        actions: <Widget>[
          FushiTextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(t.dialog_close),
          ),
        ],
      ),
    );
  }

  Future<void> _handleManageAction(_CollectionManageAction action) async {
    switch (action) {
      case _CollectionManageAction.setCover:
        await _setCover();
        return;
      case _CollectionManageAction.setCoverOnline:
        await _setCoverOnline();
        return;
      case _CollectionManageAction.resetCover:
        await _resetCover();
        return;
      case _CollectionManageAction.rescrape:
        await widget.onRescrapeCollection?.call(_collection);
        if (mounted) await _reload();
        return;
      case _CollectionManageAction.tmdbOrdering:
        await widget.onChooseTmdbOrdering?.call(_collection);
        if (mounted) await _reload();
        return;
      case _CollectionManageAction.sortBySeason:
        await _sortBySeason();
        return;
      case _CollectionManageAction.subtitles:
        await _fetchCollectionSubtitles();
        return;
      case _CollectionManageAction.generateJaSubtitles:
        await _generateSeasonJaSubtitles();
        return;
      case _CollectionManageAction.renameEpisodes:
        await _renameEpisodesFromScrape();
        return;
      case _CollectionManageAction.downloadRemote:
        // 批下载在 app 级管理器里跑到底；这里只等它排完，回来重载让新落地的
        // 本地行替换远端占位。
        await widget.remote?.downloadMembers?.call(_collection, _remoteMembers);
        if (mounted) await _reload();
        return;
      case _CollectionManageAction.interconnectDownloadTasks:
        await openInterconnectDownloadTasksPage(context);
        if (mounted) await _reload();
        return;
      case _CollectionManageAction.scrapeOnHost:
        await widget.remote?.scrapeOnHost?.call(_collection);
        if (mounted) await _reload();
        return;
      case _CollectionManageAction.scrapeForHost:
        await widget.remote?.scrapeForHost?.call(_collection);
        if (mounted) await _reload();
        return;
      case _CollectionManageAction.tmdbOrderingOnHost:
        await widget.remote?.chooseTmdbOrderingOnHost?.call(_collection);
        if (mounted) await _reload();
        return;
      case _CollectionManageAction.splitBySeason:
        await _splitBySeason();
        return;
      case _CollectionManageAction.lockFields:
        await _editLockedFields();
        return;
      case _CollectionManageAction.rename:
        await renameDetailCollection();
        return;
      case _CollectionManageAction.delete:
        await _delete();
        return;
    }
  }

  /// 字段锁：勾中的字段下次刮削保留当前值。作品行还没刮出来时菜单项本身就是灰的
  /// （见 [_buildAppBar]），所以这里只需处理「点开后行没了」的竞态。
  Future<void> _editLockedFields() async {
    final VideoMetadataWorkRow? work = _canonicalWork;
    if (work == null) return;
    final bool saved = await editVideoMetadataLockedFields(
      context: context,
      database: widget.database,
      workId: work.id,
    );
    if (!saved || !mounted) return;
    FushiToast.show(msg: t.video_work_locked_fields_saved);
    await _reload();
  }

  PreferredSizeWidget _buildAppBar() {
    return FushiAppBar(
      title: Text(
        t.video_work_details,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      actions: <Widget>[
        // 宽屏才有两种版式可切（窄屏本来就是海报横幅）。
        if (MediaDetailLayout.isTwoPane(
          context,
          MediaQuery.sizeOf(context).width,
        ))
          FushiIconButtonControl(
            key: const ValueKey<String>('collection-detail-layout-toggle'),
            tooltip: _posterLayout
                ? t.video_detail_layout_two_pane
                : t.video_detail_layout_poster,
            icon: FushiIcon(
              _posterLayout ? FushiIcons.viewColumn : FushiIcons.viewAgenda,
            ),
            onPressed: () => unawaited(_togglePosterLayout()),
          ),
        _buildSortMenu(),
        // 管理动作默认全部平铺，页头放不下才从最低优先级起收进「⋯」
        // （用户 2026-10-06「默认展开，空间不足才收起」）。保底宽度扣掉返回钮、标题
        // 与前面的布局切换 / 排序钮。
        FushiAdaptiveActionStrip(
          key: const ValueKey<String>('collection-detail-manage-actions'),
          moreKey: const ValueKey<String>('collection-detail-manage-more'),
          reservedWidth:
              FushiAdaptiveActionStrip.titleBarReservedWidth + 48 * 2,
          actions: _manageActions(),
        ),
      ],
    );
  }

  /// 合集管理动作（优先级 = 顺序，最后一个最低，放不下先收进「⋯」）。
  List<FushiAdaptiveAction> _manageActions() {
    FushiAdaptiveAction action(
      _CollectionManageAction a,
      IconData icon,
      String label, {
      bool enabled = true,
      bool dividerBefore = false,
    }) => FushiAdaptiveAction(
      icon: icon,
      label: label,
      onPressed: enabled ? () => unawaited(_handleManageAction(a)) : null,
      foldedDividerBefore: dividerBefore,
    );
    return <FushiAdaptiveAction>[
      action(
        _CollectionManageAction.setCover,
        FushiIcons.image,
        t.collection_cover_set,
      ),
      if (widget.onPickOnlineCover != null)
        action(
          _CollectionManageAction.setCoverOnline,
          FushiIcons.imageSearch,
          t.video_cover_online_search,
        ),
      if (_collection.coverPath?.isNotEmpty ?? false)
        action(
          _CollectionManageAction.resetCover,
          FushiIcons.undo,
          t.collection_cover_reset,
        ),
      // 重刮入口只在库页注入了 controller 时存在（详情页不自造 controller）。
      if (widget.onRescrapeCollection != null)
        action(
          _CollectionManageAction.rescrape,
          FushiIcons.refresh,
          t.collection_rescrape,
        ),
      // TMDB 备选排序只对已刮出剧集作品行的合集有意义。
      if (widget.onChooseTmdbOrdering != null)
        action(
          _CollectionManageAction.tmdbOrdering,
          FushiIcons.sort,
          t.collection_tmdb_ordering,
          enabled: _canonicalWork?.mediaType == 'tv',
        ),
      action(
        _CollectionManageAction.sortBySeason,
        FushiIcons.filterList,
        t.collection_sort_by_season,
        enabled: _slots.isNotEmpty,
        dividerBefore: true,
      ),
      action(
        _CollectionManageAction.subtitles,
        FushiIcons.subtitles,
        t.video_jimaku_batch_title,
        enabled: _members.isNotEmpty,
      ),
      // 整季生成日语字幕（ASR + 可选 AI 校对）：要本机视频文件与本机 ONNX 运行时；
      // 只在对端的集由面板列出跳过原因，不在这里藏入口。
      // 只在对端的合集交给 host 跑（不需要本机 ASR）。
      if (isAsrSupported || widget.remote != null)
        action(
          _CollectionManageAction.generateJaSubtitles,
          FushiIcons.ai,
          t.video_subtitle_ai_season_title,
          enabled: _members.isNotEmpty || _remoteMembers.isNotEmpty,
        ),
      action(
        _CollectionManageAction.renameEpisodes,
        FushiIcons.edit,
        t.collection_episode_rename,
        enabled: _members.isNotEmpty,
      ),
      // 「补齐缺集」与「标签」是 hero 上常驻的次按钮，这里不再重复
      // （BUG-3190：右上角与左侧按钮重复）。
      // 合集整体下载（#6）：把只在对端的成员整批拉到本机。与「补齐缺集」
      // （torrent 下载中心）是两条不同的路，入口分开、文案分开。
      if (widget.remote?.downloadMembers != null)
        action(
          _CollectionManageAction.downloadRemote,
          FushiIcons.cloudDownload,
          t.remote_collection_download_members,
          enabled: _remoteMembers.isNotEmpty,
        ),
      // 互联下载任务（暂停 / 继续 / 取消）：「下载远端集」发起的整批任务在这里能停
      // （反馈 _sZllpFQWm：iOS 没有「浏览 → 下载」，此前点了就停不下来）。
      if (widget.remote?.downloads != null)
        action(
          _CollectionManageAction.interconnectDownloadTasks,
          FushiIcons.download,
          t.interconnect_download_tasks_title,
        ),
      // 互联刮削（7a / 7b）。
      if (widget.remote?.scrapeOnHost != null)
        action(
          _CollectionManageAction.scrapeOnHost,
          FushiIcons.cloudSync,
          t.remote_collection_scrape_on_host,
        ),
      if (widget.remote?.scrapeForHost != null)
        action(
          _CollectionManageAction.scrapeForHost,
          FushiIcons.cloudUpload,
          t.remote_collection_scrape_push_to_host,
        ),
      if (widget.remote?.chooseTmdbOrderingOnHost != null)
        action(
          _CollectionManageAction.tmdbOrderingOnHost,
          FushiIcons.sort,
          t.remote_collection_tmdb_ordering_on_host,
        ),
      action(
        _CollectionManageAction.splitBySeason,
        FushiIcons.swap,
        t.collection_split_by_season,
        enabled: _hasSeasonTabs,
      ),
      action(
        _CollectionManageAction.lockFields,
        FushiIcons.lock,
        t.video_work_locked_fields,
        enabled: _canonicalWork != null,
        dividerBefore: true,
      ),
      action(
        _CollectionManageAction.rename,
        FushiIcons.rename,
        t.rename_collection,
      ),
      action(
        _CollectionManageAction.delete,
        FushiIcons.delete,
        t.delete_collection,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Widget body;
    if (_loading) {
      body = const MediaDetailSkeleton();
    } else if (_slots.isEmpty) {
      body = SafeArea(
        child: FushiPlaceholderMessage(
          icon: FushiIcons.collection,
          message: t.collection_empty,
        ),
      );
    } else {
      final ImageProvider? backdrop = _heroBackdrop;
      // 2026-10 动效重做：成员集卡的进场窗口。replayKey 带当前季——换季整段集列表
      // 重建，新一季也有一次错峰进场；窗口外（数据刷新、拖拽重排）挂载的卡瞬间
      // 出现。
      //
      // M3E 详情布局：宽屏两栏（左 hero 信息独立滚动 = sticky，右选集 / 人物 /
      // 附件 / 相关作品 / 作品资料），窄屏单列 hero 在顶。两栏时大背景由布局画在
      // 整页后面，与 hero 同一判据（fanart 优先、没有就拿封面模糊垫底）。
      body = FushiEntranceScope(
        replayKey: _selectedSection?.groupKey,
        child: MediaDetailLayout(
          backdrop: collectionHeroBackdropImage(
            backdrop: backdrop,
            cover: _heroCover,
          ),
          backdropKey: _heroBackdropIndex,
          backdropBlur: collectionHeroBackdropBlur(backdrop: backdrop),
          // 海报横幅版式：宽屏也走单列（hero 连同 fanart 横幅在顶），与竖屏同形。
          twoPaneMinWidth: _posterLayout
              ? double.infinity
              : kMediaDetailTwoPaneMinWidth,
          bottomPadding: tokens.spacing.page,
          fab: _buildResumeFab(),
          header: _buildHero(),
          slivers: <Widget>[
            SliverToBoxAdapter(child: _buildEpisodeSection(tokens)),
            SliverToBoxAdapter(child: _buildCreditsSection(tokens)),
            SliverToBoxAdapter(child: _buildExtrasSection(tokens)),
            // 相关作品横滚（TODO-2484）：无关系边整块不渲染（区块内部判空）。
            SliverToBoxAdapter(
              child: CollectionRelationsSection(
                database: widget.database,
                collectionId: widget.collection.id,
                onOpenCollection: (int id) => _openRelatedCollection(id),
                onDownload: _downloadsAvailable ? _downloadRelation : null,
              ),
            ),
            // 跨模块「同一作品」（作品图谱 media_links）：原作 / 改编 / 游戏…
            SliverToBoxAdapter(
              child: Consumer(
                builder: (BuildContext context, WidgetRef ref, Widget? _) {
                  final MediaLinkEndpoint self = (
                    kind: MediaLinkKind.videoCollection,
                    key: collectionTagEntryKey(widget.collection.id),
                  );
                  return MediaLinksSection(
                    database: widget.database,
                    self: self,
                    onOpen: (MediaLinkEntry e) => openMediaLinkEntry(
                      context: context,
                      ref: ref,
                      entry: e,
                    ),
                    onInfer: mediaLinkInferCallback(ref: ref, self: self),
                    searchActionFor: (MediaLinkKind k) => mediaLinkSearchAction(
                      context: context,
                      ref: ref,
                      kind: k,
                    ),
                  );
                },
              ),
            ),
            SliverToBoxAdapter(child: _buildWorkDetailsSection()),
          ],
        ),
      );
    }
    final Widget page = Scaffold(
      // 背景铺满到窗口顶端，浮动顶栏只是几颗胶囊（不画整宽底带）；正文 / 骨架 /
      // 空态各自按 MediaQuery 顶部 padding 让位（[MediaDetailLayout] /
      // [MediaDetailSkeleton] / SafeArea）。
      extendBodyBehindAppBar: true,
      appBar: _buildAppBar(),
      bottomNavigationBar: _buildSelectionBar(),
      // 加载骨架 → 正文 / 空态交叉淡入（时长走动效令牌，墨水屏 / 减弱动效归零）。
      body: PopScope(
        canPop: !_reordering,
        onPopInvokedWithResult: (bool didPop, Object? _) {
          if (!didPop && _reordering) _endReorder();
        },
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: AnimatedSwitcher(
                duration: context.fushiMotion.effectsDefault.duration,
                child: KeyedSubtree(
                  key: ValueKey<String>(
                    _loading
                        ? 'loading'
                        : (_slots.isEmpty ? 'empty' : 'content'),
                  ),
                  child: body,
                ),
              ),
            ),
            LibraryReorderBar.overlay(
              context: context,
              visible: _reordering,
              onDone: _endReorder,
            ),
          ],
        ),
      ),
    );
    // 整页（含空合集占位）都是拖放落点：把视频文件拖进来即导入并归入本合集。
    // 本页是独立路由，被播放页 / 对话框盖住时由 FushiFileDropTarget 的
    // ModalRoute 门挡掉；移动端透传 child。
    return FushiFileDropTarget(
      debugLabel: 'collection-detail',
      onDrop: _handleCollectionFileDrop,
      child: page,
    );
  }
}

/// 集卡上下文菜单动作。
enum _EpisodeMenuAction {
  downloadToDevice,
  pauseDownload,
  resumeDownload,
  cancelDownload,
  deleteLocalCopy,
  markWatched,
  markUnwatched,
  markWatchedThrough,
  select,
  download,
  openFileLocation,
  mediaInfo,
  clearWatchProgress,
  pinEpisode,
  removeFromCollection,
}

enum _CollectionManageAction {
  setCover,
  setCoverOnline,
  resetCover,
  rescrape,
  tmdbOrdering,
  tmdbOrderingOnHost,
  sortBySeason,
  subtitles,
  generateJaSubtitles,
  renameEpisodes,
  downloadRemote,
  interconnectDownloadTasks,
  scrapeOnHost,
  scrapeForHost,
  splitBySeason,
  lockFields,
  rename,
  delete,
}
