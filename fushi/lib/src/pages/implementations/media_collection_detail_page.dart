import 'dart:async' show Timer, unawaited;
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';

import 'package:path/path.dart' as p;

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/media/collections/collection_asset_reclaim.dart';
import 'package:fushi/src/media/collections/collection_continue.dart';
import 'package:fushi/src/media/collections/collection_one_key_sort.dart'
    show CollectionSortMeta, compareCollectionMembers;
import 'package:fushi/src/media/collections/collection_season_groups.dart';
import 'package:fushi/src/media/media_cover_source.dart';
import 'package:fushi/src/media/source_library/source_library_row.dart';
import 'package:fushi/src/media/video/anilist_client.dart' show AniListMedia;
import 'package:fushi/src/media/video/cover_ui/episode_rename_confirm_dialog.dart';
import 'package:fushi/src/media/video/cover_ui/landscape_cover_image.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_credit_repository.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/media/video/metadata/video_source_metadata_indexer.dart';
import 'package:fushi/src/media/video/stream_video_launch.dart';
import 'package:fushi/src/media/video/scraper/bangumi_client.dart';
import 'package:fushi/src/media/video/scraper/collection_relations_scrape.dart'
    show CollectionRelationType;
import 'package:fushi/src/media/video/scraper/collection_scrape_apply.dart';
import 'package:fushi/src/media/video/scraper/cover_downloader.dart';
import 'package:fushi/src/media/video/scraper/cover_meta_store.dart';
import 'package:fushi/src/media/video/scraper/episode_rename.dart';
import 'package:fushi/src/media/video/scraper/episode_scrape_service.dart';
import 'package:fushi/src/media/video/scraper/scraper_types.dart';
import 'package:fushi/src/media/video/scraper/tmdb_client.dart';
import 'package:fushi/src/media/video/scraper/tmdb_default_key.dart';
import 'package:fushi/src/media/video/video_storage.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_filename_parser.dart';
import 'package:fushi/src/media/video/video_library_overview.dart'
    show formatVideoPosition;
import 'package:fushi/src/pages/implementations/anime_download_dialog.dart';
import 'package:fushi/src/pages/implementations/collection_detail_shared.dart';
import 'package:fushi/src/pages/implementations/collection_relations_section.dart';
import 'package:fushi/src/pages/implementations/collection_split_dialog.dart';
import 'package:fushi/src/pages/implementations/jimaku_batch_dialog.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/utils/components/fushi_reorderable_grid.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:url_launcher/url_launcher.dart';

/// 统一合集 Phase 4：合集详情页（Jellyfin 式）。playlist 合集 = 有序剧集列表：点某集从
/// 该集开始播放（带剧集面板 / 上下集 / 连播，调用方经 playlistCollectionId 打开播放器）；
/// 顶部「播放」按钮据各集进度推导「继续看」位置（[continueMemberIndex]）。可重命名 / 删除
/// 合集（删合集只解链、绝不删条目本身）。
class MediaCollectionDetailPage extends StatefulWidget {
  const MediaCollectionDetailPage({
    required this.database,
    required this.collection,
    required this.loadMembers,
    required this.onOpenEpisode,
    required this.onChanged,
    this.onDeleteMembersMedia,
    super.key,
  });

  final FushiDatabase database;
  final MediaCollectionRow collection;

  /// 解析本合集**有序**成员的 VideoBooks 行（调用方持 repo + collectionId）。
  final Future<List<VideoBookRow>> Function() loadMembers;

  /// 打开某集（调用方用 playlistCollectionId 进播放器带面板）。
  final void Function(VideoBookRow episode) onOpenEpisode;

  /// 改名 / 删除后刷新库页。
  final VoidCallback onChanged;

  /// 「删除合集」时可选连同各集视频本体一起删（默认不删，保持只解链语义）。
  /// 调用方（持 [VideoBookRepository]）注入：按 [VideoBookRow] 删视频 DB 行 +
  /// app 拥有副本（封面/字幕），**保留用户原始视频文件**（导入时只存路径从不复制）。
  /// null = 详情页不提供该选项（确认框不显示复选框），退回纯解链删除。
  final Future<void> Function(List<VideoBookRow> members)? onDeleteMembersMedia;

  @override
  State<MediaCollectionDetailPage> createState() =>
      _MediaCollectionDetailPageState();
}

class _MediaCollectionDetailPageState extends State<MediaCollectionDetailPage>
    with
        CollectionDetailShared<MediaCollectionDetailPage>,
        TickerProviderStateMixin {
  /// 集列表宽卡固定高（16:9 缩略图 + 两行简介刚好放下；列宽随可用宽自适应）。
  static const double _kEpisodeCardHeight = 128;

  /// 集列表切两列的最小可用宽（用户点名 hayase 的宽屏两列形态，TODO-2491）。
  static const double _kEpisodeTwoColumnMinWidth = 900;

  late String _name;
  List<VideoBookRow> _members = const <VideoBookRow>[];
  bool _loading = true;

  /// 分季：video 成员 bookUid → 分组键，**由 videoPath 文件名现场派生**（不落库，
  /// 数据模型见 collection_season_groups.dart）。路径不随重排变化，故只在
  /// [_reload] 重算。
  Map<String, String> _groupKeyByUid = const <String, String>{};

  /// 由 [_members] + [_groupKeyByUid] 派生的分节（季号升序、PV/特典殿后）。
  /// ≥2 节 → 顶部出季 tab；否则整页与单季合集完全一致（不平白加一层 UI）。
  List<CollectionSeasonSection<VideoBookRow>> _sections =
      const <CollectionSeasonSection<VideoBookRow>>[];

  /// 季 tab 控制器：只在 ≥2 节时存在，节数变化（移出成员导致某季清空）时重建。
  TabController? _seasonTabs;
  int _selectedSeason = 0;

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
  Map<String, VideoMetadataEpisodeRow> _canonicalEpisodeByUid =
      const <String, VideoMetadataEpisodeRow>{};
  String? _canonicalCoverPath;
  String? _canonicalCoverRemoteUrl;
  List<VideoMetadataTermRow> _workTerms = const <VideoMetadataTermRow>[];
  List<VideoMetadataExtraRow> _workExtras = const <VideoMetadataExtraRow>[];

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
  void dispose() {
    _backdropRotationTimer?.cancel();
    _seasonTabs?.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final List<VideoBookRow> members = await widget.loadMembers();
    // 刮削资料与合集行一起重取：刮削**经用户确认后可能回写合集名**
    //（`applyCollectionScrape` 的 confirmedTitle），而 widget.collection 是进页时的
    // 快照，只认它会让详情页标题停在旧文件夹名。
    final CollectionScrapeMetaRow? metaRow =
        await widget.database.getCollectionScrapeMeta(widget.collection.id);
    final ScrapeMetadata? decoded = decodeCollectionScrapeMeta(metaRow);
    // 附加图组（v68）：横版背景（轮换序）与标题 logo。
    final List<MediaImageRow> imageRows =
        await widget.database.getMediaImagesForCollection(widget.collection.id);
    VideoMetadataWorkRow? canonicalWork = await widget.database
        .getVideoMetadataWorkByCollection(widget.collection.id);
    if (canonicalWork == null) {
      final Set<int> sourceIds = <int>{
        for (final VideoBookRow member in members)
          if (member.sourceId != null) member.sourceId!,
      };
      final VideoSourceMetadataIndexer indexer =
          VideoSourceMetadataIndexer(widget.database);
      for (final int sourceId in sourceIds) {
        final SourceLibraryRow? source =
            await widget.database.getMediaSourceById(sourceId);
        if (source != null) await indexer.index(source);
      }
      canonicalWork = await widget.database
          .getVideoMetadataWorkByCollection(widget.collection.id);
    }
    final VideoMetadataWorkCredits? workCredits =
        await VideoMetadataCreditRepository(widget.database)
            .forCollection(widget.collection.id);
    final List<VideoMetadataTermRow> workTerms = canonicalWork == null
        ? const <VideoMetadataTermRow>[]
        : await widget.database.getVideoMetadataTermsForWork(canonicalWork.id);
    final Map<String, VideoMetadataEpisodeRow> canonicalEpisodes =
        <String, VideoMetadataEpisodeRow>{};
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
            canonicalEpisodes[uid] = episode;
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
    final List<VideoBookRow> episodeMembers = members
        .where(
            (VideoBookRow member) => !localExtraUids.contains(member.bookUid))
        .toList(growable: false);
    // 集级刮削资料（一集一行、episodeNumber 非空才算集级；见 [_episodeMetaByUid]）。
    final Map<String, VideoScrapeMetaRow> episodeMeta =
        <String, VideoScrapeMetaRow>{};
    for (final VideoBookRow member in members) {
      final VideoScrapeMetaRow? row =
          await widget.database.getVideoScrapeMeta(member.bookUid);
      if (row != null && row.episodeNumber != null) {
        episodeMeta[member.bookUid] = row;
      }
    }
    final MediaCollectionRow? fresh =
        await widget.database.getMediaCollectionById(widget.collection.id);
    if (!mounted) return;
    setState(() {
      _members = episodeMembers;
      _groupKeyByUid = <String, String>{
        for (final VideoBookRow r in episodeMembers)
          r.bookUid: collectionGroupKeyForFilename(r.videoPath),
      };
      _rebuildSections();
      _episodeMetaByUid = episodeMeta;
      _canonicalEpisodeByUid = canonicalEpisodes;
      _workCredits = workCredits;
      _canonicalWork = canonicalWork;
      _workTerms = workTerms;
      _workExtras = workExtras;
      _scrapeMeta = decoded;
      _canonicalCoverPath = canonicalImages
          .where((VideoMetadataImageRow row) =>
              row.kind == VideoMetadataImageKind.cover.name &&
              row.localPath?.isNotEmpty == true)
          .map((VideoMetadataImageRow row) => row.localPath!)
          .firstOrNull;
      _canonicalCoverRemoteUrl = canonicalImages
          .where((VideoMetadataImageRow row) =>
              row.kind == VideoMetadataImageKind.cover.name &&
              row.remoteUrl.isNotEmpty)
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
          .where((VideoMetadataImageRow row) =>
              row.kind == VideoMetadataImageKind.logo.name &&
              row.localPath?.isNotEmpty == true)
          .map((VideoMetadataImageRow row) => row.localPath!)
          .firstOrNull;
      _logoRemoteUrl = canonicalImages
          .where((VideoMetadataImageRow row) =>
              row.kind == VideoMetadataImageKind.logo.name &&
              row.remoteUrl.isNotEmpty)
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
    _syncBackdropRotation();
  }

  /// 让背景轮换定时器跟上当前背景张数：≥2 张且未禁用动效才轮（Jellyfin 详情页
  /// 同款 10 秒节奏）；单张 / 禁动效 / 页面销毁一律停表。setState 由定时器回调
  /// 自己发（只改下标），不重查任何数据。
  void _syncBackdropRotation() {
    _backdropRotationTimer?.cancel();
    _backdropRotationTimer = null;
    if (!mounted || _backdropSources.length < 2) return;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return;
    _backdropRotationTimer =
        Timer.periodic(const Duration(seconds: 10), (Timer _) {
      if (!mounted || _backdropSources.length < 2) return;
      setState(() {
        _heroBackdropIndex = (_heroBackdropIndex + 1) % _backdropSources.length;
      });
    });
  }

  /// 重建分节并让季 tab 控制器跟上节数。**必须在 setState 内调用**（会改
  /// [_sections] / [_seasonTabs] / [_selectedSeason]）。
  void _rebuildSections() {
    _sections = sortCollectionSeasonSections<VideoBookRow>(
      buildCollectionSeasonSections<VideoBookRow>(
        members: _members,
        keyOf: (VideoBookRow r) => _groupKeyByUid[r.bookUid],
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
      final String? uid = _continueUid;
      final int index = uid == null
          ? -1
          : _sections.indexWhere((CollectionSeasonSection<VideoBookRow> s) =>
              s.items.any((VideoBookRow r) => r.bookUid == uid));
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
  CollectionSeasonSection<VideoBookRow>? get _selectedSection => _hasSeasonTabs
      ? _sections[_selectedSeason.clamp(0, _sections.length - 1)]
      : null;

  /// 当前 tab 下应展示的剧集（无 tab 时就是全表）。
  List<VideoBookRow> get _visibleMembers => _selectedSection?.items ?? _members;

  int get _continueIndex => continueMemberIndex(<CollectionMemberProgress>[
        for (final VideoBookRow r in _members)
          CollectionMemberProgress(
            positionMs: r.lastPositionMs,
            completed: r.completedAt != null,
          ),
      ]);

  /// 续播成员的 uid：分季视图里行下标是**节内**下标，与全局 [_continueIndex]
  /// 对不上，高亮统一按 uid 判定（平铺视图两者等价）。
  String? get _continueUid =>
      _members.isEmpty ? null : _members[_continueIndex].bookUid;

  /// 分组键 → tab / 分节标题（`s<N>` → 「第 N 季」；其余 → PV·特典）。
  String _groupLabel(String groupKey) {
    final int? season = seasonNumberOfGroupKey(groupKey);
    return season == null
        ? t.collection_group_extras
        : t.collection_group_season(n: season);
  }

  int get _watchedCount =>
      _members.where((VideoBookRow row) => row.completedAt != null).length;

  /// 展示用集名（TODO-2491）：集级刮削行的 title。集名缺失时集级刮削会把**作品名**
  /// 回填进 title（那不是集名，与 episode_rename.dart 同判据），此时不当集名用。
  /// 无集级资料 → null，调用方回落 [VideoBookRow.title]（文件名现状，零变化）。
  String? _scrapedEpisodeTitle(VideoBookRow row) {
    final String? canonical =
        _canonicalEpisodeByUid[row.bookUid]?.title?.trim();
    if (canonical != null && canonical.isNotEmpty) return canonical;
    final VideoScrapeMetaRow? meta = _episodeMetaByUid[row.bookUid];
    if (meta == null) return null;
    final String title = meta.title.trim();
    if (title.isEmpty) return null;
    if (title == _scrapeMeta?.title) return null;
    return title;
  }

  /// 集卡展示名：优先集级刮削集名，回落条目标题（文件名）。
  String _episodeDisplayTitle(VideoBookRow row) =>
      _scrapedEpisodeTitle(row) ?? row.title;

  /// 集卡**序号**：文件名解析出的真实集号优先，解析不出才回落列表顺位号
  /// （BUG-1544）。缺集 / 只导入了一部分时顺位号必然与真实集号错位——用户看到
  /// 「03」点开却是 E05。集号是文件名里写着的事实，不是列表下标的函数。
  int _episodeDisplayNumber(VideoBookRow row, int index) =>
      parsedEpisodeNumberOf(row.videoPath) ?? index + 1;

  /// 集简介（集级刮削 summary；无 → null 不占位）。
  String? _episodeSummary(VideoBookRow row) {
    final String? summary = (_canonicalEpisodeByUid[row.bookUid]?.overview ??
            _episodeMetaByUid[row.bookUid]?.summary)
        ?.trim();
    return (summary == null || summary.isEmpty) ? null : summary;
  }

  /// hero 背景的**横版**图源（BUG-1298 的数据层根治；v68 支持多张轮换，取当前
  /// 轮换下标那张）。
  ///
  /// hero 是约 2.7:1 的宽幅槽，理应喂横图。刮削若拿到了 TMDB 的横版图组就落在
  /// media_images 里，槽向天然吻合、直接 cover 铺满即可。
  ///
  /// 返回 null = 该源没有横版图（Bangumi / 离线库只有竖版海报，恒为空），此时
  /// 背景回落到海报 + [LandscapeCoverImage] 的模糊垫底。那不是权宜之计，是这些源
  /// 的常态路径。
  ImageProvider? get _heroBackdrop {
    if (_backdropSources.isEmpty) return null;
    final String source =
        _backdropSources[_heroBackdropIndex % _backdropSources.length];
    return _resolveCanonicalImage(source, decodeWidth: 2560);
  }

  /// 标题 logo 图源（v68）；null = 无 logo，hero 标题走纯文字。
  ImageProvider? get _heroLogo => _resolveCanonicalImage(
        _logoPath ?? _logoRemoteUrl,
        decodeWidth: 800,
      );

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
        NetworkImage(source),
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
    final String? collectionCover =
        (_collectionRow ?? widget.collection).coverPath;
    if (collectionCover != null && collectionCover.isNotEmpty) {
      return resolveMediaCoverImage(
        kind: MediaKind.video,
        localPath: collectionCover,
        decodeWidth: 1600,
      );
    }
    if (_canonicalCoverPath case final String canonicalCover
        when canonicalCover.isNotEmpty) {
      return resolveMediaCoverImage(
        kind: MediaKind.video,
        localPath: canonicalCover,
        decodeWidth: 1600,
      );
    }
    if (_canonicalCoverRemoteUrl case final String remoteCover
        when remoteCover.isNotEmpty) {
      return _resolveCanonicalImage(remoteCover, decodeWidth: 1600);
    }
    if (_members.isEmpty) return null;
    final String? continueCover = _members[_continueIndex].coverPath;
    String? fallbackCover =
        continueCover?.isNotEmpty == true ? continueCover : null;
    if (fallbackCover == null) {
      for (final VideoBookRow row in _members) {
        final String? candidate = row.coverPath;
        if (candidate != null && candidate.isNotEmpty) {
          fallbackCover = candidate;
          break;
        }
      }
    }
    return resolveMediaCoverImage(
      kind: MediaKind.video,
      localPath: fallbackCover,
      decodeWidth: 1600,
    );
  }

  /// 把当前 [_members] 顺序一次落盘（sortIndex 全表回写）。库页合集行与播放器
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
        for (final VideoBookRow r in _members)
          (mediaType: MediaKind.video.dbValue, entryKey: r.bookUid),
      ],
    );
    widget.onChanged();
  }

  /// 拖拽精修：FushiReorderableColumn 语义（newIndex 即最终下标，无 SDK
  /// ReorderableListView 的「移除前下标」修正）→ 内存 move → 落盘。
  ///
  /// 分季 tab 下拖的是**本季**列表：下标是节内的，先在节内 move，再把各节按
  /// **落盘序**（[_members] 里各组首次出现的顺序，不是 tab 的展示序）拼回全序，
  /// 避免拖一集顺带把整表按 tab 序重写。
  Future<void> _onReorder(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    final List<VideoBookRow> section = List<VideoBookRow>.of(_visibleMembers);
    final VideoBookRow moved = section.removeAt(oldIndex);
    section.insert(newIndex, moved);
    if (!_hasSeasonTabs) {
      setState(() {
        _members = section;
        _rebuildSections();
      });
      await _persistOrder();
      return;
    }
    final String movedKey =
        _groupKeyByUid[moved.bookUid] ?? kCollectionExtrasGroupKey;
    final List<CollectionSeasonSection<VideoBookRow>> persisted =
        buildCollectionSeasonSections<VideoBookRow>(
      members: _members,
      keyOf: (VideoBookRow r) => _groupKeyByUid[r.bookUid],
    );
    setState(() {
      _members = <VideoBookRow>[
        for (final CollectionSeasonSection<VideoBookRow> s in persisted)
          ...(s.groupKey == movedKey ? section : s.items),
      ];
      _rebuildSections();
    });
    await _persistOrder();
  }

  /// 一键整理（覆盖 95% 场景）：按 [compare] 重排全表并落盘。乱序的手攒播放列表
  /// 一键回名称序 / 加入时序。
  Future<void> _applyOneKeySort(
    int Function(VideoBookRow a, VideoBookRow b) compare,
  ) async {
    final List<VideoBookRow> next = List<VideoBookRow>.of(_members)
      ..sort(compare);
    setState(() {
      _members = next;
      _rebuildSections();
    });
    await _persistOrder();
  }

  /// 「按季排序」：按文件名重排全表（季→集→标题，PV/特典殿后）并落盘。季 tab
  /// **展示**本身是派生的、进页面即生效，本动作只负责把落盘全序也整理成分季连续
  /// （单季合集执行后无可见变化，幂等）。
  Future<void> _sortBySeason() async {
    if (_members.isEmpty) return;
    final CollectionSeasonRegroup<VideoBookRow> regroup =
        regroupMembersBySeason<VideoBookRow>(
      members: _members,
      filenameOf: (VideoBookRow r) => r.videoPath,
      titleOf: (VideoBookRow r) => r.title,
    );
    setState(() {
      _members = regroup.ordered;
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
    CollectionSortMeta metaOf(VideoBookRow r) => (
          title: r.title,
          importedAt: r.importedAt ?? 0,
          key: r.bookUid,
        );
    return buildDetailSortMenu(
      onSortByTitle: () => _applyOneKeySort(
        (VideoBookRow a, VideoBookRow b) =>
            compareCollectionMembers(metaOf(a), metaOf(b), byTitle: true),
      ),
      onSortByImported: () => _applyOneKeySort(
        (VideoBookRow a, VideoBookRow b) =>
            compareCollectionMembers(metaOf(a), metaOf(b), byTitle: false),
      ),
    );
  }

  /// 「为整个合集获取字幕」：把合集绑定到 AniList 系列后逐集经 Jimaku 批量下载字幕并
  /// 持久化（本地集落 DB、远端集落 prefs，见 [JimakuBatchDialog]）。
  Future<void> _fetchCollectionSubtitles() async {
    if (_members.isEmpty) return;
    // 用当前 collection 行（可能已在别处更新 anilistId）作对话框初值。
    final MediaCollectionRow collection =
        await widget.database.getMediaCollectionById(widget.collection.id) ??
            widget.collection;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => JimakuBatchDialog(
        database: widget.database,
        collection: collection,
        members: _members,
      ),
    );
  }

  /// 「刮削分集资料」（TODO-2491）：EpisodeScrapeService 按合集刮削绑定批量拉
  /// 每集集名/简介/放送日期（TMDB 还把剧照落为集封面），toast 报成功/跳过统计。
  /// 前置：合集已刮削（collection_scrape_meta 有行），否则提示先刮合集。
  /// TMDB key 直读偏好表（本页无 Riverpod）：用户自填优先，其次内置 key，与封面
  /// 刮削同一取值规则（resolveTmdbApiKey）。
  Future<void> _scrapeEpisodes() async {
    final CollectionScrapeMetaRow? meta =
        await widget.database.getCollectionScrapeMeta(widget.collection.id);
    if (!mounted) return;
    if (meta == null) {
      FushiToast.show(
        msg: t.collection_episode_scrape_unbound,
        severity: ToastSeverity.info,
      );
      return;
    }
    final String tmdbKey = resolveTmdbApiKey(
      await widget.database.getPref(kVideoScraperTmdbApiKeyPref) ?? '',
    );
    final BangumiClient bangumi = BangumiClient();
    final TmdbClient? tmdb =
        tmdbKey.isEmpty ? null : TmdbClient(apiKey: tmdbKey);
    try {
      final EpisodeScrapeService service = EpisodeScrapeService(
        db: widget.database,
        bangumiClient: bangumi,
        tmdbClient: tmdb,
        coverDownloader: CoverDownloader(),
        coverMetaStore: CoverMetaStore(await VideoStorage.coversDir()),
      );
      final EpisodeScrapeOutcome outcome =
          await service.scrapeCollectionEpisodes(widget.collection.id);
      if (!mounted) return;
      if (outcome.updated == 0 && outcome.errors.isNotEmpty) {
        // 源级失败（网络/无 key/movie 无分集）：如实报错，不装作「0 集成功」。
        FushiToast.show(
          msg: t.collection_episode_scrape_failed(
            error: outcome.errors.values.first,
          ),
          severity: ToastSeverity.error,
        );
        return;
      }
      FushiToast.show(
        msg: t.collection_episode_scrape_result(
          updated: outcome.updated,
          skipped: outcome.unmatched,
        ),
        severity: ToastSeverity.success,
      );
      await _reload();
      widget.onChanged();
    } finally {
      bangumi.close();
      tmdb?.close();
    }
  }

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
        await widget.database
            .updateVideoBookTitle(proposal.bookUid, proposal.newTitle);
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
    final MediaCollectionRow? target =
        await widget.database.getMediaCollectionById(targetCollectionId);
    if (target == null || !mounted) return;
    final VideoBookRepository repo = VideoBookRepository(widget.database);
    Navigator.push<void>(
      context,
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => MediaCollectionDetailPage(
          database: widget.database,
          collection: target,
          loadMembers: () async {
            final List<MediaCollectionItemRow> items =
                await widget.database.getCollectionItems(target.id);
            final List<VideoBookRow> rows = <VideoBookRow>[];
            for (final MediaCollectionItemRow item in items) {
              if (item.mediaType != MediaKind.video.dbValue) continue;
              final VideoBookRow? row = await repo.getByBookUid(item.entryKey);
              if (row != null) rows.add(row);
            }
            return rows;
          },
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

  /// 「相关作品 → 去下载」：预填关系边标题打开番剧下载对话框（搜番段）。
  void _downloadRelation(CollectionRelationRow relation) {
    showDialog<void>(
      context: context,
      builder: (_) => AnimeDownloadDialog(
        showTasks: false,
        initialSearchQuery: relation.title,
      ),
    );
  }

  /// 文件名解出的集号；解不出回落集级刮削行的 episodeNumber（两者都无 → null）。
  int? _episodeNumberOf(VideoBookRow episode) =>
      parseVideoFilename(p.basename(episode.videoPath)).episode ??
      _episodeMetaByUid[episode.bookUid]?.episodeNumber;

  /// 打开下载对话框（TODO-2485）：合集绑了 anilistId → 本地合成 [AniListMedia]
  /// （id + 合集名，零网络）直达选种段并预填集号；未绑定 → 回落预填合集名的
  /// 搜番段。[episodeNumber] null = 不按集过滤。
  void _openDownloadDialog({required int? episodeNumber}) {
    final MediaCollectionRow collection = _collectionRow ?? widget.collection;
    final int? anilistId = collection.anilistId;
    showDialog<void>(
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

  /// 本合集是否绑定 Bangumi 刮削源（「在 Bangumi 打开本集」菜单项的显示门）。
  bool get _boundToBangumi => _scrapeMeta?.source == ScrapeSource.bangumi;

  /// 「在 Bangumi 打开本集」（TODO-2488 降级实现）：Bangumi API v0 **没有**公开的
  /// 章节吐槽接口（全量 spec 零 comment 端点；吐槽只存在于未文档化的私有
  /// next.bgm.tv p1 API），不自建社区功能——降级为外链：经公开无鉴权的
  /// `/v0/episodes` 把集号解析成章节 id，浏览器打开 `bgm.tv/ep/<id>`；解析不到
  /// （集号缺失/源无该集）明示提示并退到条目页；网络失败明示错误、同样退条目页。
  Future<void> _openEpisodeOnBangumi(VideoBookRow episode) async {
    final ScrapeMetadata? meta = _scrapeMeta;
    if (meta == null) return;
    final int? episodeNumber = _episodeNumberOf(episode);
    final BangumiClient bangumi = BangumiClient();
    int? episodeId;
    try {
      if (episodeNumber != null) {
        for (final BangumiEpisodeInfo info
            in await bangumi.fetchSubjectEpisodes(meta.subjectId)) {
          if (info.episodeNumber == episodeNumber) {
            episodeId = info.id;
            break;
          }
        }
        if (episodeId == null) {
          FushiToast.show(
            msg: t.collection_episode_bangumi_not_found,
            severity: ToastSeverity.warning,
          );
        }
      } else {
        // 集号都解析不出（文件名无集号且无集级刮削）：同样明示降级去向，
        // 不静默换成条目页（复核意见）。
        FushiToast.show(
          msg: t.collection_episode_bangumi_not_found,
          severity: ToastSeverity.warning,
        );
      }
    } on ScrapeNetworkException catch (e) {
      FushiToast.show(
        msg: t.collection_episode_bangumi_open_failed(error: e.toString()),
        severity: ToastSeverity.error,
      );
    } finally {
      bangumi.close();
    }
    final String url = episodeId != null
        ? 'https://bgm.tv/ep/$episodeId'
        : 'https://bgm.tv/subject/${meta.subjectId}';
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  /// 「补齐缺集」：按文件名集号找 1..max 的第一个缺口；无内部缺口但刮削话数
  /// 大于 max → 下一集（max+1）。真没有缺集（或一集集号都解不出）→ 提示。
  void _fillMissingEpisodes() {
    final Set<int> present = <int>{
      for (final VideoBookRow member in _members)
        if (parseVideoFilename(p.basename(member.videoPath)).episode
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
  Future<void> _removeEpisode(VideoBookRow ep) async {
    if (!await confirmDetailRemoveMember()) return;
    if (!mounted) return;
    await widget.database.removeFromCollection(
        widget.collection.id, MediaKind.video, ep.bookUid);
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
    final List<CollectionSeasonSection<VideoBookRow>> sections = _sections;
    final CollectionSplitChoice? choice = await showCollectionSplitDialog(
      context: context,
      sections: <CollectionSplitPlanSection>[
        for (final CollectionSeasonSection<VideoBookRow> section in sections)
          CollectionSplitPlanSection(
            defaultName: '$_name ${_groupLabel(section.groupKey)}',
            members: <CollectionSplitMember>[
              for (final VideoBookRow row in section.items)
                CollectionSplitMember(
                  id: row.bookUid,
                  title: _episodeDisplayTitle(row),
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
          edges.add(_localRelationEdge(
            collectionId: newIds[i],
            type: CollectionRelationType.prequel,
            targetCollectionId: newIds[prev],
            title: groups[prev].name,
            sortIndex: edges.length,
          ));
        }
        if (k < seasonIndexes.length - 1) {
          final int next = seasonIndexes[k + 1];
          edges.add(_localRelationEdge(
            collectionId: newIds[i],
            type: CollectionRelationType.sequel,
            targetCollectionId: newIds[next],
            title: groups[next].name,
            sortIndex: edges.length,
          ));
        }
        await widget.database.replaceCollectionRelations(newIds[i], edges);
      }
    });
    if (!choice.keepOriginal) {
      await deleteMediaCollectionWithAssets(
          widget.database, widget.collection.id);
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

  /// 本地拆分产生的关系边（source='local'，subjectId='collection:<目标id>'）。
  CollectionRelationsCompanion _localRelationEdge({
    required int collectionId,
    required CollectionRelationType type,
    required int targetCollectionId,
    required String title,
    required int sortIndex,
  }) {
    return CollectionRelationsCompanion.insert(
      collectionId: collectionId,
      relationType: type.wire,
      sortIndex: Value<int>(sortIndex),
      targetCollectionId: Value<int?>(targetCollectionId),
      source: 'local',
      subjectId: 'collection:$targetCollectionId',
      title: title,
    );
  }

  Future<void> _delete() async {
    // 仅当调用方注入了删本体回调、且合集当前有成员时，才给用户「连同视频一起删」
    // 勾选行；否则退回纯解链删除（老行为，零变化）。确认框统一走 PR-0 的
    // [FushiDestructiveConfirmDialog]（经 [confirmDetailCollectionDelete]）。
    final bool canDeleteMembers =
        widget.onDeleteMembersMedia != null && _members.isNotEmpty;
    final FushiDestructiveConfirmResult? result =
        await confirmDetailCollectionDelete(
      checkboxLabel: canDeleteMembers ? t.delete_collection_also_videos : null,
    );
    if (result == null || !mounted) return;
    // 先删各集视频本体（DB 行 + 封面/字幕副本），再解散容器。删视频会连带清各合集
    // 引用行并自删空合集，故随后的解散多为幂等收尾（写合集级墓碑）。解散必须走
    // [deleteMediaCollectionWithAssets]：裸 deleteMediaCollection 只删 DB 行，合集
    // 自有封面会永久留在磁盘上（BUG-1319）。
    if (result.checked && widget.onDeleteMembersMedia != null) {
      await widget.onDeleteMembersMedia!(List<VideoBookRow>.of(_members));
    }
    await deleteMediaCollectionWithAssets(
        widget.database, widget.collection.id);
    if (!mounted) return;
    widget.onChanged();
    Navigator.of(context).maybePop();
  }

  /// 单集封面缩略图（16:9 槽）：有封面文件则渲染，否则 letterbox 占位图标。
  /// 每集是独立视频行，[VideoBookRow.coverPath] 由导入 / 后台补齐（home_video_page
  /// `_maybeBackfillCovers`）逐集抽帧填充；刮削可把它覆盖成 2:3 竖版海报——
  /// BUG-1299：走 [PortraitCoverImage] 的横槽自适应（横版截帧铺满、竖版海报
  /// 模糊垫底 + contain），不再 `BoxFit.cover` 把海报裁成中间一条。
  Widget _episodeThumb(
    VideoBookRow ep,
    ColorScheme cs, {
    double w = 96,
    double h = 54,
  }) {
    final ImageProvider? cover = resolveMediaCoverImage(
      kind: MediaKind.video,
      localPath: ep.coverPath,
    );
    if (cover != null) {
      return ClipRRect(
        borderRadius: FushiBorderRadius.card,
        child: SizedBox(
          width: w,
          height: h,
          child: PortraitCoverImage(
            image: cover,
            landscapeSlot: true,
            // 抽帧文件损坏 / 读取失败时退回占位，绝不抛。
            errorBuilder: (BuildContext _) => _thumbPlaceholder(w, h, cs),
          ),
        ),
      );
    }
    return _thumbPlaceholder(w, h, cs);
  }

  Widget _thumbPlaceholder(double w, double h, ColorScheme cs) => Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: FushiBorderRadius.card,
        ),
        child: Icon(Icons.movie_outlined, color: cs.onSurfaceVariant, size: 20),
      );

  Widget _buildHero(
    BuildContext context,
    ColorScheme cs,
    FushiDesignTokens tokens,
  ) {
    final Size screen = MediaQuery.sizeOf(context);
    final double height = (screen.height * 0.60).clamp(460.0, 680.0);
    final ImageProvider? cover = _heroCover;
    final VideoBookRow episode = _members[_continueIndex];
    final bool rtl = Directionality.of(context) == TextDirection.rtl;
    // 可读性渐变：压在封面之上、竖版海报前景之下（层序由 [LandscapeCoverImage]
    // 保证，见该组件文档）。无封面时直接铺在底色上，与引入组件前一致。
    final List<Widget> overlays = <Widget>[
      const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: <double>[0, 0.48, 1],
            colors: <Color>[
              Color(0x52000000),
              Color(0x22000000),
              Color(0xE8000000),
            ],
          ),
        ),
      ),
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: rtl ? Alignment.centerRight : Alignment.centerLeft,
            end: rtl ? Alignment.centerLeft : Alignment.centerRight,
            stops: const <double>[0, 0.66, 1],
            colors: const <Color>[
              Color(0xC9000000),
              Color(0x26000000),
              Color(0x7A000000),
            ],
          ),
        ),
      ),
    ];
    final ImageProvider? backdrop = _heroBackdrop;
    return SizedBox(
      key: const ValueKey<String>('video-work-hero-card'),
      width: double.infinity,
      height: height,
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            ColoredBox(color: cs.surfaceContainerHighest),
            // 背景分两条路，取决于**这次刮削的源有没有横版图**：
            // ① 有 backdrop（TMDB）→ 槽向天然吻合，直接 cover 铺满，海报另以独立
            //    2:3 卡片出现在左侧（Jellyfin 式，各就各位）；
            // ② 无 backdrop（Bangumi / 离线库 / 未刮削）→ 只有 2:3 海报或 16:9 抽帧
            //    可用，朝向判定交给 [LandscapeCoverImage]：横图 cover 铺满，竖版海报
            //    模糊垫底 + 靠右完整显示（BUG-1298）。此时不再另放海报卡，否则同一张
            //    图在同一屏出现两次。
            if (backdrop != null) ...<Widget>[
              // v68：多张背景 10 秒轮换（Jellyfin 详情页同款）。外层 key 恒定供
              // 测试定位；内层 key 随轮换下标变化驱动 AnimatedSwitcher 交叉淡入。
              // gaplessPlayback：新图解码完成前保留旧帧，避免轮换瞬间闪底色。
              KeyedSubtree(
                key: const ValueKey<String>('collection-hero-backdrop'),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 700),
                  child: Image(
                    key: ValueKey<int>(_heroBackdropIndex),
                    image: backdrop,
                    fit: BoxFit.cover,
                    alignment: Alignment.center,
                    gaplessPlayback: true,
                    errorBuilder: (_, __, ___) =>
                        ColoredBox(color: cs.surfaceContainerHighest),
                  ),
                ),
              ),
              ...overlays,
            ] else if (cover != null)
              LandscapeCoverImage(
                key: const ValueKey<String>('collection-hero-cover'),
                image: cover,
                overlays: overlays,
                // 竖版海报避让顶部 AppBar 与底部内容区，靠右不压左下标题/播放按钮。
                foregroundPadding: EdgeInsetsDirectional.only(
                  top: tokens.spacing.gap,
                  bottom: tokens.spacing.section,
                  end: tokens.spacing.page,
                ),
                errorBuilder: (BuildContext _) =>
                    ColoredBox(color: cs.surfaceContainerHighest),
              )
            else
              ...overlays,
            Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spacing.page,
                tokens.spacing.section,
                tokens.spacing.page,
                tokens.spacing.section,
              ),
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  final Widget info = ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 680),
                    child: _buildHeroInfo(context, tokens, episode),
                  );
                  // 海报卡只在「有横版背景 + 宽度够」时出现：窄屏放不下 2:3 卡还要
                  // 留 680 给文字，挤压的结果是标题被压成一列竖排字。
                  final bool showPoster = backdrop != null &&
                      cover != null &&
                      constraints.maxWidth >= 900;
                  if (!showPoster) {
                    return Align(
                      alignment: AlignmentDirectional.bottomStart,
                      child: info,
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      _buildHeroPosterCard(cover, height),
                      SizedBox(width: tokens.spacing.section),
                      Expanded(
                        child: Align(
                          alignment: AlignmentDirectional.bottomStart,
                          child: info,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// hero 左侧的竖版海报卡（仅在有横版背景时出现，见 [_buildHero]）。
  ///
  /// 2:3 是海报的**正确槽向**——这才是 BUG-1298 的正解：不是把海报硬塞进宽幅槽再想
  /// 办法补救，而是让宽幅槽拿横图、让海报回到它自己的比例里。
  Widget _buildHeroPosterCard(ImageProvider cover, double heroHeight) {
    final double posterHeight = (heroHeight * 0.78).clamp(280.0, 500.0);
    return ClipRRect(
      borderRadius: FushiBorderRadius.card,
      child: SizedBox(
        key: const ValueKey<String>('collection-hero-poster'),
        height: posterHeight,
        width: posterHeight * 2 / 3,
        child: PortraitCoverImage(image: cover),
      ),
    );
  }

  /// hero 文字区：标题 / 原名 / 元数据行 / 标签 / 简介 / 继续看 / 播放。
  ///
  /// 刮削资料缺失时逐项跳过（不占位、不显示「未知」）：未刮过的合集看到的就是引入
  /// 本功能前的老形态——标题 + 进度 + 播放，逐像素不变（Never break userspace）。
  Widget _buildHeroInfo(
    BuildContext context,
    FushiDesignTokens tokens,
    VideoBookRow episode,
  ) {
    final TextTheme text = Theme.of(context).textTheme;
    final ScrapeMetadata? meta = _scrapeMeta;
    final String? originalTitle =
        _canonicalWork?.originalTitle ?? meta?.originalTitle;
    // 规范作品的简介/题材/人物在 hero 下方有完整、可选择的全宽区块；hero 再放
    // 一份只会形成用户截图中的重复内容。旧 v68 资料没有规范详情宿主时才保留
    // hero 回退，避免老库凭空丢信息。
    final bool useLegacyHeroDetails = _canonicalWork == null;
    final String? summary = useLegacyHeroDetails ? meta?.summary?.trim() : null;
    final String? airDate =
        (_canonicalWork?.premiereDate ?? meta?.airDate)?.trim();
    final List<ScrapeTag> scrapeTags =
        useLegacyHeroDetails ? _heroScrapeTags(meta) : const <ScrapeTag>[];
    final List<VideoMetadataCreditSummary> credits = useLegacyHeroDetails
        ? _heroCredits()
        : const <VideoMetadataCreditSummary>[];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // 放送日期行（hayase 式：小字压在大标题上方）。未刮过没有 → 不占位。
        if (airDate != null && airDate.isNotEmpty) ...<Widget>[
          Text(
            airDate,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.labelMedium?.copyWith(
              color: Colors.white.withValues(alpha: 0.7),
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
          SizedBox(height: tokens.spacing.gap / 2),
        ],
        // v68：有标题 logo 时替代纯文字大标题（Jellyfin `.detailLogo` 同款）。
        // Semantics 保留合集名——logo 是图，读屏与测试都还能按名字找到它；
        // logo 解码失败回落文字标题，绝不留一块空白当标题。
        if (_heroLogo case final ImageProvider logo)
          Semantics(
            label: _name,
            image: true,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 110, maxWidth: 460),
              child: Image(
                key: const ValueKey<String>('collection-hero-logo'),
                image: logo,
                fit: BoxFit.contain,
                alignment: AlignmentDirectional.bottomStart,
                errorBuilder: (_, __, ___) => _buildHeroTitleText(text),
              ),
            ),
          )
        else
          _buildHeroTitleText(text),
        // 原名与合集名相同就不重复占一行（刮削回写后二者常常一致）。
        if (originalTitle != null &&
            originalTitle.isNotEmpty &&
            originalTitle != _name) ...<Widget>[
          SizedBox(height: tokens.spacing.gap / 2),
          Text(
            originalTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.bodyMedium?.copyWith(
              color: Colors.white.withValues(alpha: 0.72),
            ),
          ),
        ],
        SizedBox(height: tokens.spacing.gap),
        // 徽标行（hayase 式）：观看进度恒在（不依赖刮削），话数/评分有刮削资料
        // 才逐项出现（缺的不占位、不写「未知」）。
        _buildHeroBadgeChips(_heroBadgeParts(meta)),
        if (scrapeTags.isNotEmpty) ...<Widget>[
          SizedBox(height: tokens.spacing.gap),
          _buildHeroTagChips(scrapeTags),
        ],
        if (credits.isNotEmpty) ...<Widget>[
          SizedBox(height: tokens.spacing.gap),
          _buildHeroCreditChips(credits),
        ],
        if (summary != null && summary.isNotEmpty) ...<Widget>[
          SizedBox(height: tokens.spacing.card),
          // Flexible + ellipsis：简介长度不可控，hero 高度是钳死的，必须让它先收缩
          // 再截断，否则长简介直接把 Column 撑出 RenderFlex overflow。
          Flexible(
            child: Text(
              summary,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: text.bodyMedium?.copyWith(
                color: Colors.white.withValues(alpha: 0.78),
                height: 1.35,
              ),
            ),
          ),
        ],
        SizedBox(height: tokens.spacing.card),
        Text(
          '${t.collection_continue_progress(n: _continueIndex + 1)}  ·  '
          '${episode.title}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: text.labelLarge?.copyWith(
            color: Colors.white.withValues(alpha: 0.82),
            fontWeight: FontWeight.w700,
          ),
        ),
        SizedBox(height: tokens.spacing.card),
        FilledButton.icon(
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text(t.collection_play),
          onPressed: () => widget.onOpenEpisode(episode),
        ),
      ],
    );
  }

  /// hero 纯文字大标题（无 logo 的常态路径 / logo 解码失败回落共用）。
  Widget _buildHeroTitleText(TextTheme text) {
    return Text(
      _canonicalWork?.title ?? _name,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: text.displaySmall?.copyWith(
        color: Colors.white,
        fontWeight: FontWeight.w700,
        height: 1.08,
      ),
    );
  }

  /// 徽标行内容：`全 12 话` / `★ 8.1` / `1234 人评分` / `已看完 0/12`。
  ///
  /// 逐项存在才出（缺的不留空档、不写「未知」）。观看进度恒在——它不依赖刮削，是
  /// 本页固有信息，未刮过的合集这一行就只剩它，与旧形态一致。年份不进徽标：
  /// 放送日期已单独一行压在标题上方（[_buildHeroInfo]）。
  List<String> _heroBadgeParts(ScrapeMetadata? meta) {
    final List<String> parts = <String>[];
    final int? year = _canonicalWork?.year;
    if (year != null) parts.add('$year');
    final String? status = _canonicalWork?.status;
    if (status != null && status.trim().isNotEmpty) parts.add(status);
    final int episodeCount = meta?.episodeCount ?? _members.length;
    if (episodeCount > 0) {
      parts.add(t.collection_hero_total_episodes(count: episodeCount));
    }
    final double? rating = _canonicalWork?.rating ?? meta?.rating;
    if (rating != null && rating > 0) {
      parts.add('★ ${rating.toStringAsFixed(1)}');
      final int? votes = _canonicalWork?.ratingCount ?? meta?.ratingCount;
      if (votes != null && votes > 0) {
        parts.add(t.video_scrape_rating_votes(count: votes));
      }
    }
    final int? runtime = _canonicalWork?.runtimeMinutes;
    if (runtime != null && runtime > 0) parts.add('$runtime min');
    parts.add(
      t.collection_watched_progress(
        done: _watchedCount,
        total: _members.length,
      ),
    );
    return parts;
  }

  /// 徽标 chips（hayase 式胶囊；与作品标签 chips 同形但语义不同：这排是**数字
  /// 事实**——话数/评分/进度，那排是题材标签）。
  Widget _buildHeroBadgeChips(List<String> parts) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        for (final String part in parts)
          DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.32),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Colors.white.withValues(alpha: 0.28)),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              child: Text(
                part,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.2,
                  color: Colors.white.withValues(alpha: 0.92),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
      ],
    );
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

  /// 作品标签 chips。
  ///
  /// 用 [Wrap] 而不是单行 Row：标签长短不一，钳成一行会让第二个起就被 ellipsis 吃掉。
  /// 取前 6 个已使最坏情况稳定在两行内，配合调用方的 [Flexible] 不会撑爆 hero。
  Widget _buildHeroTagChips(List<ScrapeTag> tags) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        for (final ScrapeTag tag in tags)
          DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              child: Text(
                tag.name,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.2,
                  color: Colors.white.withValues(alpha: 0.88),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
      ],
    );
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
            .where((VideoMetadataCreditSummary credit) =>
                credit.creditKind == kind)
            .take(2),
    ];
  }

  Widget _buildHeroCreditChips(List<VideoMetadataCreditSummary> credits) {
    return SizedBox(
      key: const ValueKey<String>('collection-hero-credits'),
      height: 28,
      child: HorizontalDragScrollable(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: <Widget>[
              for (int index = 0; index < credits.length; index++) ...<Widget>[
                if (index > 0) const SizedBox(width: 6),
                DecoratedBox(
                  key: ValueKey<String>(
                    'collection-hero-credit-${credits[index].creditKind}-$index',
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.32),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.24),
                    ),
                  ),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(
                          _heroCreditIcon(credits[index].creditKind),
                          size: 13,
                          color: Colors.white.withValues(alpha: 0.76),
                        ),
                        const SizedBox(width: 5),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 220),
                          child: Text(
                            credits[index].displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.2,
                              color: Colors.white.withValues(alpha: 0.9),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  IconData _heroCreditIcon(String creditKind) => switch (creditKind) {
        'director' => Icons.movie_creation_outlined,
        'voice_actor' => Icons.record_voice_over_outlined,
        _ => Icons.person_outline,
      };

  Widget _buildWorkDetailsSection(FushiDesignTokens tokens) {
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
        (t.video_work_countries, terms['country']!.join(' · ')),
      if (work?.contentRating?.trim().isNotEmpty == true)
        (t.video_work_content_rating, work!.contentRating!),
      if (identities.isNotEmpty)
        (
          t.video_work_external_ids,
          identities
              .map((VideoMetadataIdentitySummary identity) =>
                  '${identity.provider.toUpperCase()}: ${identity.externalId}')
              .join(' · '),
        ),
    ];
    final String? overview = work?.overview?.trim();
    if ((overview == null || overview.isEmpty) && facts.isEmpty) {
      return Padding(
        key: const ValueKey<String>('video-work-details-pending'),
        padding: EdgeInsets.fromLTRB(
          tokens.spacing.page,
          tokens.spacing.section,
          tokens.spacing.page,
          0,
        ),
        child: FushiCard(
          padding: EdgeInsets.all(tokens.spacing.section),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                t.video_work_details,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              SizedBox(height: tokens.spacing.card),
              Text(
                t.video_work_metadata_pending,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      );
    }
    return Padding(
      key: const ValueKey<String>('video-work-details'),
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.section,
        tokens.spacing.page,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(t.video_work_details,
              style: Theme.of(context).textTheme.titleLarge),
          if (overview != null && overview.isNotEmpty) ...<Widget>[
            SizedBox(height: tokens.spacing.card),
            SelectableText(
              overview,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    height: 1.55,
                  ),
            ),
          ],
          for (final (String label, String value) in facts)
            Padding(
              padding: EdgeInsets.only(top: tokens.spacing.card),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                    width: 116,
                    child: Text(
                      label,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  Expanded(child: SelectableText(value)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCreditsSection(FushiDesignTokens tokens) {
    final List<VideoMetadataCreditSummary> all =
        _workCredits?.credits ?? const <VideoMetadataCreditSummary>[];
    final List<VideoMetadataCreditSummary> voice = all
        .where((VideoMetadataCreditSummary credit) =>
            credit.creditKind == 'voice_actor')
        .toList(growable: false);
    final List<VideoMetadataCreditSummary> crew = all
        .where((VideoMetadataCreditSummary credit) =>
            credit.creditKind != 'voice_actor')
        .toList(growable: false);
    if (voice.isEmpty && crew.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(top: tokens.spacing.section),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (voice.isNotEmpty)
            _buildCreditRail(t.video_work_voice_roles, voice, tokens),
          if (voice.isNotEmpty && crew.isNotEmpty)
            SizedBox(height: tokens.spacing.section),
          if (crew.isNotEmpty)
            _buildCreditRail(t.video_work_cast_crew, crew, tokens),
        ],
      ),
    );
  }

  Widget _buildCreditRail(
    String title,
    List<VideoMetadataCreditSummary> credits,
    FushiDesignTokens tokens,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        SizedBox(height: tokens.spacing.card),
        SizedBox(
          height: 224,
          child: HorizontalDragScrollable(
            child: ListView.separated(
              padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
              scrollDirection: Axis.horizontal,
              itemCount: credits.length,
              separatorBuilder: (_, __) => SizedBox(width: tokens.spacing.card),
              itemBuilder: (BuildContext context, int index) {
                final VideoMetadataCreditSummary credit = credits[index];
                final String? path = credit.person.profilePath;
                final String? url = credit.person.profileUrl;
                final ImageProvider? image =
                    path != null && File(path).existsSync()
                        ? FileImage(File(path))
                        : (url == null ? null : NetworkImage(url));
                return SizedBox(
                  key: ValueKey<String>(
                      'video-work-credit-${credit.person.personKey}-$index'),
                  width: 132,
                  child: FushiCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Expanded(
                          child: image == null
                              ? const ColoredBox(
                                  color: Color(0x1FFFFFFF),
                                  child: Icon(Icons.person_outline, size: 42),
                                )
                              : Image(image: image, fit: BoxFit.cover),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(9, 8, 9, 2),
                          child: Text(
                            credit.person.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(9, 0, 9, 9),
                          child: Text(
                            credit.character?.name ??
                                (credit.roleName.isEmpty
                                    ? credit.creditKind
                                    : credit.roleName),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
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

  Widget _buildExtrasSection(FushiDesignTokens tokens) {
    if (_workExtras.isEmpty) return const SizedBox.shrink();
    final List<VideoMetadataExtraRow> trailers = _workExtras
        .where((VideoMetadataExtraRow extra) =>
            extra.kind == 'trailer' || extra.kind == 'teaser')
        .toList(growable: false);
    final List<VideoMetadataExtraRow> extras = _workExtras
        .where((VideoMetadataExtraRow extra) =>
            extra.kind != 'trailer' && extra.kind != 'teaser')
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
        Padding(
          padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        SizedBox(height: tokens.spacing.card),
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
                              if (thumb != null && File(thumb).existsSync())
                                Image.file(File(thumb), fit: BoxFit.cover)
                              else if (thumb != null)
                                Image.network(thumb, fit: BoxFit.cover)
                              else
                                const ColoredBox(color: Color(0x1FFFFFFF)),
                              const Center(
                                child: CircleAvatar(
                                  child: Icon(Icons.play_arrow_rounded),
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
            builder: (_) => VideoFushiPage.neutralized(
              bookUid: local.bookUid,
              repo: repo,
            ),
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

  Widget _buildEpisodeSection(
    BuildContext context,
    ColorScheme cs,
    FushiDesignTokens tokens,
  ) {
    return Padding(
      padding: EdgeInsets.only(
        top: tokens.spacing.section,
        bottom: tokens.spacing.section,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
            child: Text(
              t.video_episode_list,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
          // 多季合集：季 tab 紧贴标题行、在集列表之上——用户一进详情页就看得见分季。
          if (_hasSeasonTabs) _buildSeasonTabs(context, cs, tokens),
          SizedBox(height: tokens.spacing.rowVertical),
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
            child: _buildEpisodeGrid(cs, tokens),
          ),
        ],
      ),
    );
  }

  /// 季 tab 条（MD3 可滚动 [TabBar]）：多季合集**首屏**就能看见并切季，切换后
  /// 下面的剧集轨与管理列表一起换成该季（分季若只做在默认折叠的管理
  /// 列表里，用户进页面根本看不见）。单季合集不渲染本条（[_hasSeasonTabs] 门）。
  Widget _buildSeasonTabs(
    BuildContext context,
    ColorScheme cs,
    FushiDesignTokens tokens,
  ) {
    return Padding(
      key: const ValueKey<String>('collection-season-tabs'),
      padding: EdgeInsets.only(top: tokens.spacing.gap),
      child: TabBar(
        controller: _seasonTabs,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
        labelColor: cs.primary,
        unselectedLabelColor: cs.onSurfaceVariant,
        indicatorColor: cs.primary,
        dividerColor: Colors.transparent,
        tabs: <Widget>[
          for (final CollectionSeasonSection<VideoBookRow> section in _sections)
            Tab(
              key:
                  ValueKey<String>('collection-season-tab-${section.groupKey}'),
              text: _groupLabel(section.groupKey),
            ),
        ],
      ),
    );
  }

  /// 集列表（hayase 式宽卡网格）：宽度 ≥ [_kEpisodeTwoColumnMinWidth] 两列，
  /// 否则一列。拖拽重排/右键/长按菜单由 [FushiReorderableGrid] 统一接管（鼠标
  /// 按住即拖 + 右键菜单；触摸长按起拖、原地松手出菜单——BUG-778 缩放安全一族）。
  /// 分季时只列本季（[_visibleMembers]），拖拽是节内重排，由 [_onReorder] 拼回
  /// 全序落盘。
  Widget _buildEpisodeGrid(ColorScheme cs, FushiDesignTokens tokens) {
    final List<VideoBookRow> visible = _visibleMembers;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        const double spacing = 12;
        final int columns =
            constraints.maxWidth >= _kEpisodeTwoColumnMinWidth ? 2 : 1;
        final double columnWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return FushiReorderableGrid(
          itemCount: visible.length,
          crossAxisCount: columns,
          childAspectRatio: columnWidth / _kEpisodeCardHeight,
          crossAxisSpacing: spacing,
          mainAxisSpacing: spacing,
          feedbackBorderRadius: FushiBorderRadius.card,
          keyForIndex: (int i) =>
              ValueKey<String>('collection-episode-row-${visible[i].bookUid}'),
          onReorder: _onReorder,
          onActivateItem: (int i) => widget.onOpenEpisode(visible[i]),
          onContextMenu: (int i, Offset globalPosition) =>
              _showEpisodeMenu(visible[i], globalPosition),
          itemBuilder: (BuildContext context, int i) =>
              _buildEpisodeCard(context, visible[i], i, cs, tokens),
        );
      },
    );
  }

  /// 单张集卡：左 16:9 缩略图 + 右「N. 集名」/集简介两行/观看状态，底部进度条。
  ///
  /// 进度条只画**真实事实**：看完 → 满格；`VideoBooks` 不持久化视频总时长
  /// （TODO-1346 同一约束），看了一半算不出百分比——不造假条，改在状态行给
  /// 「看到 mm:ss」（lastPositionMs 是真数据）。
  ///
  /// 纯视觉（手势归 [FushiReorderableGrid]），故整卡 [IgnorePointer]；键盘/手柄
  /// 焦点不走指针，[FushiFocusTarget] 照常可聚焦、Enter 开播。
  Widget _buildEpisodeCard(
    BuildContext context,
    VideoBookRow episode,
    int index,
    ColorScheme cs,
    FushiDesignTokens tokens,
  ) {
    final bool completed = episode.completedAt != null;
    final bool started = episode.lastPositionMs > 0 && !completed;
    final bool isContinue = episode.bookUid == _continueUid;
    final String? summary = _episodeSummary(episode);
    const double pad = 10;
    const double thumbHeight = _kEpisodeCardHeight - pad * 2;
    const double thumbWidth = thumbHeight * 16 / 9;
    final Widget card = IgnorePointer(
      child: Material(
        color: isContinue
            ? cs.primaryContainer.withValues(alpha: 0.35)
            : cs.surfaceContainerLow,
        borderRadius: FushiBorderRadius.card,
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(pad),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _episodeThumb(episode, cs, w: thumbWidth, h: thumbHeight),
                  SizedBox(width: tokens.spacing.rowVertical),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          // BUG-1544：序号跟随文件名解析出的真实集数（缺集时
                          // 不再用顺位号冒充）；解析不出时回退顺位号。
                          '${_episodeDisplayNumber(episode, index)}. '
                          '${_episodeDisplayTitle(episode)}',
                          // BUG-1546：无刮削集名时标题是整条发布文件名（VCB-Studio
                          // 一类动辄 80+ 字符），单行省略后关键的集号/规格全被吃掉，
                          // 用户分不清 PV/特典各条目。放两行再省略；卡高 128 下
                          // 「两行标题 + 两行简介 + 状态行」仍在 Spacer 余量内。
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        // 集简介两行（集级刮削 summary；无则不占位）。
                        if (summary != null) ...<Widget>[
                          SizedBox(height: tokens.spacing.gap / 2),
                          Text(
                            summary,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.3,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                        const Spacer(),
                        Row(
                          children: <Widget>[
                            if (completed)
                              Icon(
                                Icons.check_circle,
                                color: cs.primary,
                                size: 16,
                              )
                            else if (started) ...<Widget>[
                              Icon(
                                Icons.play_circle_outline,
                                color: cs.onSurfaceVariant,
                                size: 16,
                              ),
                              SizedBox(width: tokens.spacing.gap / 2),
                              Text(
                                t.collection_episode_watched_at(
                                  position: formatVideoPosition(
                                    episode.lastPositionMs,
                                  ),
                                ),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (completed)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(
                  value: 1,
                  minHeight: 3,
                  backgroundColor: Colors.transparent,
                  color: cs.primary,
                ),
              ),
          ],
        ),
      ),
    );
    if (FushiFocusRoot.maybeControllerOf(context) == null) return card;
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onOpenEpisode(episode);
            return null;
          },
        ),
      },
      child: FushiFocusTarget(
        id: FushiFocusId('collection-episode-${episode.bookUid}'),
        child: card,
      ),
    );
  }

  /// 集卡上下文菜单（右键 / 触摸长按原地松手）。坐标经 Overlay `globalToLocal`
  /// 消掉 FushiAppUiScale 缩放（BUG-781 同族纪律）。管理能力从旧管理列表的行内
  /// 按钮收进本菜单（拖拽排序仍是直接拖卡）。
  Future<void> _showEpisodeMenu(
    VideoBookRow episode,
    Offset globalPosition,
  ) async {
    final RenderObject? overlay =
        Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox) return;
    final Offset anchor = overlay.globalToLocal(globalPosition);
    final _EpisodeMenuAction? action = await showMenu<_EpisodeMenuAction>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(anchor, anchor),
        Offset.zero & overlay.size,
      ),
      items: <PopupMenuEntry<_EpisodeMenuAction>>[
        PopupMenuItem<_EpisodeMenuAction>(
          value: _EpisodeMenuAction.download,
          child: Row(
            children: <Widget>[
              const Icon(Icons.download_outlined, size: 20),
              const SizedBox(width: 12),
              Text(t.collection_episode_download),
            ],
          ),
        ),
        // 仅 Bangumi 绑定的合集出现（TMDB/未刮削没有对应的公开章节页可开）。
        if (_boundToBangumi)
          PopupMenuItem<_EpisodeMenuAction>(
            value: _EpisodeMenuAction.openBangumi,
            child: Row(
              children: <Widget>[
                const Icon(Icons.open_in_new, size: 20),
                const SizedBox(width: 12),
                Text(t.collection_episode_open_bangumi),
              ],
            ),
          ),
        PopupMenuItem<_EpisodeMenuAction>(
          value: _EpisodeMenuAction.removeFromCollection,
          child: Row(
            children: <Widget>[
              const Icon(Icons.remove_circle_outline, size: 20),
              const SizedBox(width: 12),
              Text(t.collection_remove_member),
            ],
          ),
        ),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case _EpisodeMenuAction.download:
        _openDownloadDialog(episodeNumber: _episodeNumberOf(episode));
      case _EpisodeMenuAction.openBangumi:
        await _openEpisodeOnBangumi(episode);
      case _EpisodeMenuAction.removeFromCollection:
        await _removeEpisode(episode);
      case null:
        break;
    }
  }

  Future<void> _handleManageAction(_CollectionManageAction action) async {
    switch (action) {
      case _CollectionManageAction.sortBySeason:
        await _sortBySeason();
        return;
      case _CollectionManageAction.subtitles:
        await _fetchCollectionSubtitles();
        return;
      case _CollectionManageAction.scrapeEpisodes:
        await _scrapeEpisodes();
        return;
      case _CollectionManageAction.renameEpisodes:
        await _renameEpisodesFromScrape();
        return;
      case _CollectionManageAction.fillMissing:
        _fillMissingEpisodes();
        return;
      case _CollectionManageAction.splitBySeason:
        await _splitBySeason();
        return;
      case _CollectionManageAction.rename:
        await renameDetailCollection();
        return;
      case _CollectionManageAction.tags:
        await editDetailCollectionTags();
        return;
      case _CollectionManageAction.delete:
        await _delete();
        return;
    }
  }

  PopupMenuItem<_CollectionManageAction> _manageMenuItem(
    _CollectionManageAction action,
    IconData icon,
    String label, {
    bool enabled = true,
  }) {
    return PopupMenuItem<_CollectionManageAction>(
      value: action,
      enabled: enabled,
      child: Row(
        children: <Widget>[
          Icon(icon, size: 20),
          const SizedBox(width: 12),
          Text(label),
        ],
      ),
    );
  }

  AppBar _buildAppBar() {
    return AppBar(
      title: Text(
        t.video_work_details,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      actions: <Widget>[
        _buildSortMenu(),
        PopupMenuButton<_CollectionManageAction>(
          icon: const Icon(Icons.more_horiz),
          onSelected: (_CollectionManageAction action) =>
              unawaited(_handleManageAction(action)),
          itemBuilder: (BuildContext context) =>
              <PopupMenuEntry<_CollectionManageAction>>[
            _manageMenuItem(
              _CollectionManageAction.sortBySeason,
              Icons.segment,
              t.collection_sort_by_season,
              enabled: _members.isNotEmpty,
            ),
            _manageMenuItem(
              _CollectionManageAction.subtitles,
              Icons.subtitles_outlined,
              t.video_jimaku_batch_title,
              enabled: _members.isNotEmpty,
            ),
            _manageMenuItem(
              _CollectionManageAction.scrapeEpisodes,
              Icons.movie_filter_outlined,
              t.collection_episode_scrape,
              enabled: _members.isNotEmpty,
            ),
            _manageMenuItem(
              _CollectionManageAction.renameEpisodes,
              Icons.format_list_numbered,
              t.collection_episode_rename,
              enabled: _members.isNotEmpty,
            ),
            _manageMenuItem(
              _CollectionManageAction.fillMissing,
              Icons.playlist_add,
              t.collection_episode_fill_missing,
              enabled: _members.isNotEmpty,
            ),
            _manageMenuItem(
              _CollectionManageAction.splitBySeason,
              Icons.call_split,
              t.collection_split_by_season,
              enabled: _hasSeasonTabs,
            ),
            const PopupMenuDivider(),
            _manageMenuItem(
              _CollectionManageAction.rename,
              Icons.drive_file_rename_outline,
              t.rename_collection,
            ),
            _manageMenuItem(
              _CollectionManageAction.tags,
              Icons.sell_outlined,
              t.tag_label,
            ),
            _manageMenuItem(
              _CollectionManageAction.delete,
              Icons.delete_outline,
              t.delete_collection,
            ),
          ],
        ),
      ],
    );
  }

  Widget _centeredContent(Widget child) {
    return SizedBox(width: double.infinity, child: child);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Scaffold(
      appBar: _buildAppBar(),
      body: _loading
          ? SafeArea(
              child: Center(child: adaptiveIndicator(context: context)),
            )
          : _members.isEmpty
              ? SafeArea(
                  child: FushiPlaceholderMessage(
                    icon: Icons.collections_bookmark_outlined,
                    message: t.collection_empty,
                  ),
                )
              : CustomScrollView(
                  slivers: <Widget>[
                    SliverToBoxAdapter(
                      child: _buildHero(context, cs, tokens),
                    ),
                    SliverToBoxAdapter(
                      child: _centeredContent(buildDetailTagChips()),
                    ),
                    SliverToBoxAdapter(
                      child: _centeredContent(
                        _buildWorkDetailsSection(tokens),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: _centeredContent(_buildCreditsSection(tokens)),
                    ),
                    SliverToBoxAdapter(
                      child: _centeredContent(_buildExtrasSection(tokens)),
                    ),
                    // 相关作品横滚（TODO-2484）：hero 之下、剧集区之上；无关系边
                    // 整块不渲染（区块内部判空）。
                    SliverToBoxAdapter(
                      child: _centeredContent(
                        CollectionRelationsSection(
                          database: widget.database,
                          collectionId: widget.collection.id,
                          onOpenCollection: (int id) =>
                              _openRelatedCollection(id),
                          onDownload: _downloadRelation,
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: _centeredContent(
                        _buildEpisodeSection(context, cs, tokens),
                      ),
                    ),
                    SliverSafeArea(
                      top: false,
                      sliver: SliverToBoxAdapter(
                        child: SizedBox(height: tokens.spacing.page),
                      ),
                    ),
                  ],
                ),
    );
  }
}

/// 集卡上下文菜单动作。
enum _EpisodeMenuAction { download, openBangumi, removeFromCollection }

enum _CollectionManageAction {
  sortBySeason,
  subtitles,
  scrapeEpisodes,
  renameEpisodes,
  fillMissing,
  splitBySeason,
  rename,
  tags,
  delete,
}
