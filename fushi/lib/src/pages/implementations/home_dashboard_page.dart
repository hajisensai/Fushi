import 'dart:io';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'dart:async';
import 'package:fushi_engine/sync/remote_collection_adoption_service.dart';
import 'package:fushi_engine/sync/collection_book_identity_index.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:transparent_image/transparent_image.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:fushi/media.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/media/collections/collection_continue.dart';
import 'package:fushi/src/media/media_cover_source.dart';
import 'package:fushi_engine/media/tracking/bangumi_api_client.dart';
import 'package:fushi/src/media/tracking/media_tracking_labels.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_repository.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi_engine/media/video/m3u8_playlist.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/pages/base_module_tab_page.dart';
import 'package:fushi/src/pages/implementations/home_dashboard_widgets.dart';
import 'package:fushi/src/pages/implementations/home_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/pages/implementations/updates_center_open.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/pages/implementations/updates_dashboard_banner.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart'
    show openLocalVideoBook;
import 'package:fushi/src/pages/implementations/stat_shared.dart';
import 'package:fushi/src/pages/implementations/statistics_center_page.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_tab.dart';
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_common.dart'
    show LeaderboardAvatar;
import 'package:fushi/src/leaderboard/leaderboard_service.dart';
import 'package:fushi_engine/leaderboard/leaderboard_models.dart'
    show LeaderboardSelf;
import 'package:fushi/src/media/video/video_library_overview.dart'
    show formatVideoPosition;
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema_tracking.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi_engine/media/collections/shelf_sort.dart';
import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/remote_cover_image.dart';
import 'package:fushi/src/sync/remote_library_cache.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/cover_image.dart';
import 'package:fushi/src/utils/misc/dashboard_remote_merge.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/migration/migration_target_channel.dart';
import 'package:fushi/src/pages/implementations/migration_page.dart';
import 'package:fushi/src/pages/implementations/migration_import_page.dart';
import 'package:fushi/src/migration/migration_importer.dart';
import 'package:fushi_engine/foundation/engine_notifier.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_common.dart';

/// 首页「继续」区是否收这本书：与书架读完筛选 / hero 计数同一判据
/// [classifyShelfReadStatus]（`EpubBooks.completedAt` 优先于进度）。
///
/// BUG-2918：阅读器落库的位置是末页**首个可见字符**，读到最后一页 position 也
/// 永远 < duration；旧判据只看 `0 < position < duration`，读完（含阅读器自动
/// 写入的 completedAt）的书仍以四舍五入出的 100% 留在「继续」区。
/// [completedBookKeys] 的键是 bookKey（standalone SRT 等无 bookKey 的条目回退
/// mediaIdentifier，查不到即按进度判，与旧行为一致）。
@visibleForTesting
bool isDashboardContinueBook(MediaItem item, Set<String> completedBookKeys) {
  final String bookKey =
      ReaderFushiSource.parseBookKey(item.mediaIdentifier) ??
          item.mediaIdentifier;
  return classifyShelfReadStatus(
        completed: completedBookKeys.contains(bookKey),
        position: item.position,
        duration: item.duration,
      ) ==
      ShelfReadStatus.reading;
}

/// 宽屏首页的封面高度：随内容区宽度放大（宽 × 0.2），夹在 176…260 之间。
///
/// 1024 宽平板约 205、1300 以上（桌面 1440）封顶 260——「继续」最多 10 张
/// 2:3 竖卡在 1440 下正好铺满一行，下方「最近添加」行按 0.82 倍跟随。
@visibleForTesting
double dashboardWideCoverHeight(double contentWidth) =>
    (contentWidth * 0.2).clamp(176.0, 260.0);

/// 「继续」视频卡的进度（[dashboardVideoContinueProgress] 的结果）。
///
/// - [fraction]：封面底部进度条（0..1）；null = 不画。
/// - [episode]：集数角标「第 N 集」（1 起）；null = 不是多集。
/// - [percent]：单视频百分比角标（知道总时长时）。
/// - [positionMs]：前两者都给不出时退回「看到的时间点」角标。
typedef DashboardVideoProgress = ({
  double? fraction,
  int? episode,
  int? percent,
  int? positionMs,
});

/// 首页「继续」视频卡的进度口径（反馈「小说有进度显示，视频缺了进度显示」）。
///
/// 此前只有单行多集播放列表画进度（[videoWatchFraction]：看到第几集），合集里的
/// 某一集与单视频一律不画——`VideoBooks` 不存总时长，算不出百分比。现在：
/// - 单行多集播放列表（[playlistEpisodeCount] ≥ 2）：角标「第 N 集」，进度条仍是
///   集粒度（`currentEpisode / 集数`）；
/// - 合集里的一集（[collectionEpisode] 非空）：角标「第 N 集」，进度条是这一集
///   看到哪（[durationMs] 已知时）；
/// - 单视频：[durationMs] 已知 → 进度条 + 百分比角标，否则角标退回看到的时间点。
///
/// [durationMs] 来自视频规格探测缓存（`VideoFileSpecs`），流媒体 / 没探测过的
/// 文件为 null。纯函数，单测直接覆盖各分支。
@visibleForTesting
DashboardVideoProgress dashboardVideoContinueProgress({
  required bool completed,
  required int positionMs,
  required int? durationMs,
  required int currentEpisode,
  required int playlistEpisodeCount,
  int? collectionEpisode,
  int collectionEpisodeCount = 0,
}) {
  final int? total = durationMs;
  final double? inEpisode = total != null && total > 0 && positionMs > 0
      ? (positionMs / total).clamp(0.0, 1.0)
      : null;
  if (playlistEpisodeCount >= 2) {
    return (
      fraction: videoWatchFraction(
        completed: completed,
        currentEpisode: currentEpisode,
        episodeCount: playlistEpisodeCount,
      ),
      episode: currentEpisode.clamp(0, playlistEpisodeCount - 1) + 1,
      percent: null,
      positionMs: null,
    );
  }
  if (collectionEpisode != null && collectionEpisodeCount >= 2) {
    return (
      fraction: inEpisode,
      episode: collectionEpisode,
      percent: null,
      positionMs: null,
    );
  }
  if (inEpisode != null) {
    return (
      fraction: inEpisode,
      episode: null,
      percent: (inEpisode * 100).round(),
      positionMs: null,
    );
  }
  return (
    fraction: null,
    episode: null,
    percent: null,
    positionMs: positionMs > 0 ? positionMs : null,
  );
}

/// 首页浮动工具栏起始侧的头像胶囊（2026-10 精简：左上角原「首页」标题胶囊换成
/// 头像）。头像来源只有现成的一处——排行榜账户头像（[LeaderboardAvatar]，本
/// Profile 开了排行榜账户时）；没开账户时退回当前 Profile 名的首字圆。点击打开
/// 排行榜（账户页在那里）。
///
/// 排行榜服务只在本 Profile 已开账户时才有 `self`；开了账户但本进程还没联网取过
/// 时补一次 [LeaderboardService.refreshSelf]（反馈中心同款做法），失败静默——头像
/// 退回首字圆即可，不是值得打扰用户的错误。
class _HomeAvatarPill extends ConsumerStatefulWidget {
  const _HomeAvatarPill({required this.onPressed});

  final VoidCallback onPressed;

  @override
  ConsumerState<_HomeAvatarPill> createState() => _HomeAvatarPillState();
}

class _HomeAvatarPillState extends ConsumerState<_HomeAvatarPill> {
  /// 当前 Profile 名（没开排行榜账户时的首字来源）。
  String? _profileName;
  bool _selfRequested = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadProfileName());
  }

  Future<void> _loadProfileName() async {
    try {
      final FushiDatabase db = ref.read(appProvider).database;
      final ProfileRow? row =
          await db.getProfileById(await db.resolveActiveProfileId());
      if (!mounted || row == null) return;
      setState(() => _profileName = row.name);
    } catch (e, st) {
      ErrorLogService.instance.log('HomeAvatarPill.profile', e, st);
    }
  }

  void _maybeRefreshSelf(LeaderboardService service) {
    if (_selfRequested || service.self != null) return;
    if (service.status != LeaderboardStatus.active) return;
    _selfRequested = true;
    unawaited(service.refreshSelf().then((_) {}, onError: (Object _) {}));
  }

  @override
  Widget build(BuildContext context) {
    final LeaderboardService service = ref.watch(leaderboardServiceProvider);
    _maybeRefreshSelf(service);
    final LeaderboardSelf? self = service.self;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String name = self?.account.nickname ?? _profileName ?? '';
    final Color onContainer = Theme.of(context).colorScheme.onPrimaryContainer;
    const double size = 40;
    final Widget avatar = self != null
        ? LeaderboardAvatar(account: self.account, size: size)
        : SizedBox.square(
            dimension: size,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: tokens.surfaces.primaryContainer,
              ),
              child: Center(
                child: name.isEmpty
                    ? FushiIcon(
                        FushiIcons.person,
                        size: 22,
                        color: onContainer,
                      )
                    : Text(
                        String.fromCharCodes(name.runes.take(1)),
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: onContainer,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
              ),
            ),
          );
    final Color container =
        fushiFloatingToolbarPalette(context).container;
    return Semantics(
      key: const ValueKey<String>('home-toolbar-avatar'),
      button: true,
      label: name.isEmpty ? t.leaderboard_title : name,
      excludeSemantics: true,
      child: FushiTooltip(
        message: name.isEmpty ? t.leaderboard_title : name,
        excludeFromSemantics: true,
        child: FushiPressScale(
          child: FushiFloatingPill(
            color: container,
            padding: const EdgeInsets.all(4),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: widget.onPressed,
              child: avatar,
            ),
          ),
        ),
      ),
    );
  }
}

/// 首页仪表盘（阅读向）。2026-10 精简重设计（用户反馈 PDF「1.首页」）：
///
/// - 顶部浮动工具栏：左 = 用户头像（[_HomeAvatarPill]），右 = 更新中心 · 统计中心 ·
///   排行榜 · 反馈（放不下才收进「⋯」）。
/// - 一张主卡：学习头部行（[HomeStudyHeader]：目标环 + 今日字数 + 今日时长，
///   不挂「学习活动」「每日目标」小字，不分四类）在上，「继续」封面行在下——只有
///   封面 + 书进度 / 视频集数角标（[HomeContinueCoverCard]），没有封面才兜底画
///   标题。学习日历（热力图）、最近添加、活动时间轴已删除（统计中心里能看）。
/// - 更新提醒：可关闭的小横幅（[UpdatesDashboardBanner]）。
///
/// 书与阅读位置走 Riverpod provider（响应式）；视频 / 统计等本地聚合在
/// [initState] 一次并发载入，结果按数据库实例做快照（BUG-3034），重建时首帧直接
/// 用快照渲染。
class HomeDashboardPage extends BaseModuleTabPage {
  const HomeDashboardPage({
    super.key,
    required this.videoRepo,
    this.openVideoOverride,
  });

  /// 视频库仓库：仪表盘「继续观看」与视频计数的数据源（[VideoBookRepository.listForShelf]）。
  final VideoBookRepository videoRepo;

  /// 测试缝：打开本地视频播放页的实现覆盖（默认走共享 [openLocalVideoBook] 真实
  /// 路由）。widget 测试无法构建 media_kit 播放页，注入替身即可断言「点继续卡/
  /// 活动条 = 直接续播（带 playlistCollectionId）」的接线；生产恒 null。
  final Future<void> Function(
    BuildContext context,
    VideoBookRepository repo,
    String bookUid,
    int? playlistCollectionId,
  )? openVideoOverride;

  @override
  BaseModuleTabPageState<HomeDashboardPage> createState() =>
      _HomeDashboardPageState();
}

/// 「继续」统一列表的单条：书 / 视频 / 游戏归一到同一结构，按 [recentMs] 倒序混排。
/// [book]/[video]/[game]/[remote] 恰有一个非空（本地书 / 本地视频 / 本地游戏 /
/// 互联 host 条目）。
///
/// BUG-1111：此前这里是 `final bool isVideo`——**二元标志结构上装不下第三种媒体**，
/// 于是「继续」「最近添加」只能由 books + videos 两个来源构造，游戏被永久排除在
/// 首页之外（用户报「首页的继续里面没有游戏」）。改用 [MediaKind]（P5 枚举地基）
/// 后第三种媒体才有位置；新增媒体种类也不再需要动这个结构。
class _ContinueEntry {
  const _ContinueEntry({
    required this.kind,
    required this.title,
    required this.recentMs,
    this.progress,
    this.badgeLabel,
    this.badgeIcon,
    this.collectionName,
    this.collectionId,
    this.book,
    this.video,
    this.game,
    this.remote,
  });

  /// 所属主合集 id（v68 横版选图链按它取合集附加图组）；null = 散卡。
  final int? collectionId;

  /// 本条的媒体种类。书按真实身份区分 [MediaKind.epub] / [MediaKind.srt]
  /// （两者在本区块行为一致，经 [isBook] 归并），不再用一个 bool 硬编码二元。
  final MediaKind kind;

  /// 视频分支（横版封面 / 直接续播）。
  bool get isVideo => kind == MediaKind.video;

  /// 书分支（竖版封面 / openMedia）：EPUB 与 SRT 在本区块完全同行为。
  bool get isBook => kind == MediaKind.epub || kind == MediaKind.srt;

  /// 游戏分支（竖版封面 / 跳游戏 tab）。
  bool get isGame => kind == MediaKind.game;

  /// 本条所属功能模块（首页聚合列表的门控判据）。
  ///
  /// ⚠️ 漫画盖不住 [MediaKind]（见 `module_registry.dart`）：漫画行是
  /// `EpubBooks.format=='manga'` 派生，[kind] 仍是 [MediaKind.epub]。本地书条目
  /// 能从 [MediaItem.mediaSourceIdentifier] 认出漫画身份（`_bookToMediaItem` 给
  /// 漫画行打的就是 [MangaFushiSource.kUniqueKey]），所以这里能按 manga 单独门控。
  ///
  /// 远端补位条目（[remote]）判不出漫画，一律按 [moduleOfMediaKind] 归 books
  /// ——host 侧的漫画本就进不了「继续」（`remoteContinueCandidates` 按
  /// `hasContent` 已把无 EPUB 内容树的漫画/PDF 行滤掉，BUG-1638）。
  ModuleId get module =>
      book?.mediaSourceIdentifier == MangaFushiSource.kUniqueKey
      ? ModuleId.manga
      : moduleOfMediaKind(kind);

  final String title;

  /// 最近活动时刻（epoch 毫秒），仅用于混排排序。
  final int recentMs;

  /// 封面底部进度条分数（0..1）；null = 无可展示进度不画（游戏、远端视频，见
  /// [dashboardVideoContinueProgress]）。
  final double? progress;

  /// 封面右上角进度角标：书 =「42%」，视频 =「第 N 集」/「37%」/ 看到的时间点；
  /// null = 不画（游戏没有完成度）。
  final String? badgeLabel;
  final IconData? badgeIcon;

  /// 所属主合集名（显示名规则：非合集上下文显示合集名）；null = 散卡。本地条目
  /// 查折叠归属映射，远端条目由 host 直接携带。
  final String? collectionName;
  final MediaItem? book;
  final VideoBookRow? video;

  /// 本地游戏（BUG-1111）。游戏是**本机局域身份**（`galgames.id`），不参与互联
  /// 远端补位——对端没有对应行，拿过来也打不开。
  final GalgameEntry? game;

  /// 互联 host 上的在读书/在看视频（本地无此条目时的远端补位，「继续也走互联」）。
  final RemoteContinueCandidate? remote;
}

/// 首页本地聚合的一次完整结果（[_HomeDashboardPageState._loadDashboardDataUnsafe]
/// 的产物），按数据库实例缓存在 [_HomeDashboardPageState._snapshots]。
///
/// BUG-3034：首页不在 keep-alive 名单里，每次切回首页都整页重建、`initState`
/// 重跑整批聚合——几百毫秒里各区只能挂骨架。快照让重建的首帧直接用上一轮的结果
/// 渲染（旧数据先上屏），后台照常重拉一轮再替换，体感从「每次都等」变成「瞬开」。
/// 只存本地聚合，远端补位（互联）仍由 [_loadRemoteDashboardData] 增量到达。
class _HomeDashboardSnapshot {
  const _HomeDashboardSnapshot({
    required this.statWindow,
    required this.videos,
    required this.games,
    required this.tracking,
    required this.readingRows,
    required this.watchRows,
    required this.gameRows,
    required this.collectionNamesById,
    required this.primaryCollectionByEntry,
    required this.collectionCoverById,
    required this.epubUidByBookKey,
    required this.epubImportedAtByKey,
    required this.memberSortIndex,
    required this.videoWatchAtByUid,
    required this.videoDurationMsByPath,
  });

  final StatWindow statWindow;
  final List<VideoBookRow> videos;
  final List<GalgameEntry> games;
  final MediaTrackingStatus tracking;
  final List<StatFact> readingRows;
  final List<StatFact> watchRows;
  final List<StatFact> gameRows;
  final Map<int, String> collectionNamesById;
  final Map<String, int> primaryCollectionByEntry;
  final Map<int, String> collectionCoverById;
  final Map<String, String> epubUidByBookKey;
  final Map<String, int> epubImportedAtByKey;
  final Map<String, int> memberSortIndex;
  final Map<String, int> videoWatchAtByUid;
  final Map<String, int> videoDurationMsByPath;
}

class _BangumiWatchedDialog extends StatefulWidget {
  const _BangumiWatchedDialog({
    required this.service,
    required this.onOpenSubject,
  });

  final MediaTrackingService service;
  final Future<void> Function(int subjectId) onOpenSubject;

  @override
  State<_BangumiWatchedDialog> createState() => _BangumiWatchedDialogState();
}

class _BangumiWatchedDialogState extends State<_BangumiWatchedDialog> {
  late final Future<List<BangumiWatchedItem>> _watched =
      widget.service.loadWatchedAnime();

  @override
  Widget build(BuildContext context) {
    return FushiAlertDialog(
      title: Row(
        children: <Widget>[
          const FushiIcon(FushiIcons.visibility),
          const SizedBox(width: 12),
          Expanded(child: Text(t.media_tracking_watched_title)),
        ],
      ),
      content: SizedBox(
        width: 640,
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: FutureBuilder<List<BangumiWatchedItem>>(
          future: _watched,
          builder: (
            BuildContext context,
            AsyncSnapshot<List<BangumiWatchedItem>> snapshot,
          ) {
            // 加载 / 失败 / 空走统一占位件（MD3 中性块 / Apple 大图标灰字），
            // 不再是裸菊花与裸文字。
            if (snapshot.connectionState != ConnectionState.done) {
              return const FushiLoadingView();
            }
            if (snapshot.hasError) {
              return Center(
                child: FushiPlaceholderMessage(
                  icon: FushiIcons.error,
                  message: t.media_tracking_watched_load_failed(
                    error: snapshot.error!,
                  ),
                ),
              );
            }
            final List<BangumiWatchedItem> watched =
                snapshot.data ?? const <BangumiWatchedItem>[];
            if (watched.isEmpty) {
              return Center(
                child: FushiPlaceholderMessage(
                  icon: FushiIcons.visibility,
                  message: t.media_tracking_watched_empty,
                ),
              );
            }
            return ListView.separated(
              itemCount: watched.length,
              separatorBuilder: (_, __) => const FushiDividerControl(height: 1),
              itemBuilder: (BuildContext context, int index) {
                final BangumiWatchedItem item = watched[index];
                final String? coverUrl = item.subject.coverUrl;
                return FushiListItem(
                  padding: EdgeInsets.zero,
                  titleMaxLines: 2,
                  leading: SizedBox(
                    width: 42,
                    height: 56,
                    child: coverUrl == null
                        ? const FushiIcon(FushiIcons.video)
                        : ClipRRect(
                            borderRadius: FushiBorderRadius.chip,
                            child: Image(
                              image: AppHttpImage(coverUrl),
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  const FushiIcon(FushiIcons.brokenImage),
                            ),
                          ),
                  ),
                  title: Text(
                    item.subject.displayName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    t.media_tracking_watched_progress(
                      n: item.episodeProgress,
                    ),
                  ),
                  trailing: FushiTooltip(
                    message: t.media_tracking_open_subject,
                    child: const FushiIcon(FushiIcons.openInNew, size: 18),
                  ),
                  onTap: () => unawaited(widget.onOpenSubject(item.subject.id)),
                );
              },
            );
          },
        ),
      ),
      actions: <Widget>[
        FushiTextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.dialog_close),
        ),
      ],
    );
  }
}

/// Bangumi 同步卡最多列出的已关联条目数（超出的去设置页看全量；首页卡片是状态
/// 概览，不是映射管理器）。有失败的条目由
/// [MediaTrackingStatus.mappingsProblemFirst] 排到最前，不会被这个上限挤掉。
const int _kTrackingMappingLimit = 5;

/// 首页卡最多直接摊开的待手动关联条目数；完整清单在「管理关联」页。
const int _kTrackingUnlinkedLimit = 5;

class _HomeDashboardPageState
    extends BaseModuleTabPageState<HomeDashboardPage> {
  /// 首页主纵向滚动区自己的控制器。滚轮平滑由根部 `SmoothWheelScrollScope`
  /// 统一处理（BUG-2834），这里不再需要特制控制器。
  final ScrollController _dashboardScrollController = ScrollController();

  /// 浮动工具栏 / 「继续」FAB 的滚动驱动状态（见 [HomeToolbarScrollState]）。
  final HomeToolbarScrollState _toolbarScroll = HomeToolbarScrollState();

  /// 工具栏「更新中心」按钮的未读角标（[initState] 建，[dispose] 释放）。
  HomeUpdateCount? _updateCount;

  /// 本帧「继续」区的主角条目（[_buildContinueSection] 写入，FAB 续开它）；
  /// null = 没有可继续的条目，FAB 不出现。
  _ContinueEntry? _resumeEntry;

  /// 「继续」封面行（2026-10 精简：只有封面，不再挂标题 / 副标题文字块）：书 /
  /// 视频 / 游戏统一 2:3 竖卡、等高等宽（视频优先用作品海报，只有横版截帧时裁进
  /// 竖卡，不再横竖混排）。窄屏封面高
  /// [_kContinueCoverHeight]，宽屏（主列 ≥ [_kWideLayoutMinWidth]）按窗口宽放大
  /// （[dashboardWideCoverHeight]）——行里没有文字了，封面是唯一的信息载体。
  static const double _kContinueCoverHeight = 148;
  /// 宽屏「最近添加」行封面相对「继续」行的缩放：次要信息，比「继续」小一号。
  static const double _kRecentCoverScale = 0.82;
  static const double _kContinueCoverAspect = 2 / 3;
  static const double _kWideLayoutMinWidth = 900;

  /// 视频文件路径 → 容器时长（毫秒，[VideoFileSpecs] 探测缓存，只查在看的
  /// 视频）。`VideoBooks` 不存总时长，单视频 / 合集里的某一集要画「看到哪」的
  /// 进度条只能借这份缓存；查不到（流媒体 / 还没探测过）时角标退回看到的时间点。
  Map<String, int> _videoDurationMsByPath = const <String, int>{};

  /// [initState] 异步载入的视频库（继续观看 + 视频计数）。
  List<VideoBookRow> _videos = const <VideoBookRow>[];

  /// 合集主封面（`MediaCollections.coverPath`，刮削落地的作品海报）：「继续」
  /// 竖卡的视频优先用它，集封面多是横版截帧。
  Map<int, String> _collectionCoverById = const <int, String>{};

  /// [_loadDashboardDataUnsafe] 载入的游戏库整表缓存（P4：日明细「游戏」节 +
  /// 活动时间轴游戏行的显示名反查用；空表 = 库为空或尚未载入）。
  List<GalgameEntry> _games = const <GalgameEntry>[];

  /// 互联 host 上的「继续」远端补位候选（本地无同 key/uid 的在读书/在看视频）。
  List<RemoteContinueCandidate> _remoteContinue =
      const <RemoteContinueCandidate>[];

  /// 远端封面取图器（互联 client 可用时非空；喂 [RemoteCoverImage]）。
  RemoteCoverFetcher? _remoteCoverFetcher;

  /// 互联 host 设备显示名（配对时存进 [FushiClientUrl.deviceName]；取不到时
  /// 渲染层回退通用「远端」文案）。「标明设备来源」的数据源。
  String? _remoteDeviceName;

  /// 上一次远端取数时「显示远端条目」门控的值（对齐视频页 BUG-1182 的
  /// `_remoteGateAtLastLoad`），用于在 prefsRepo 的高频通知里只识别门控翻转。
  bool _remoteGateAtLastLoad = true;

  /// 「显示远端条目」开关落在 prefsRepo（独立 ChangeNotifier），不经 AppModel
  /// 通知、也不在 [_scheduleReload] 的表级信号里——必须显式订阅（[initState] 挂，
  /// [dispose] 解除）才能让翻开关立即生效。
  PreferencesRepository? _prefsRepoForRemoteGate;

  /// 已加载的统一事实面日行（v92：[StatFacts.daily] 按 mediaKind 分三份；今日
  /// 目标分子 / 今日时长 / 近 7 日日均都对它求和，免重查）。
  List<StatFact> _readingRows = const <StatFact>[];
  List<StatFact> _watchRows = const <StatFact>[];
  List<StatFact> _gameRows = const <StatFact>[];

  /// 完整日面（阅读 + 观看 + 游戏），今日目标 / 今日时长 / 近 7 日日均的数据源
  /// （BUG-1993：目标口径 = 学习域）。派生 getter，不另存状态。
  Iterable<StatFact> get _dailyRows =>
      _readingRows.followedBy(_watchRows).followedBy(_gameRows);

  /// 合集归属映射（统计页/书架同源，显示名规则「非合集上下文拼合集名」用）：
  /// - [_collectionNamesById]：collectionId → 合集名。
  /// - [_primaryCollectionByEntry]：'<mediaType>|<entryKey>' → 折叠归属主 collectionId。
  /// - [_epubUidByBookKey]：v83 起成员表 epub entryKey = `epub_books.uid`，页面
  ///   手里的 bookKey 查归属映射前经此表换算（书架 `_epubUidByKey` 同款口径）。
  Map<int, String> _collectionNamesById = const <int, String>{};
  Map<String, int> _primaryCollectionByEntry = const <String, int>{};
  Map<String, String> _epubUidByBookKey = const <String, String>{};

  /// epub bookKey → 导入时刻（epoch 毫秒，`EpubBooks.importedAt`）：宽屏「最近
  /// 添加」封面行的书侧排序时间源（视频用 [VideoBookRow.importedAt]、游戏用
  /// [GalgameEntry.addedAt]）。
  Map<String, int> _epubImportedAtByKey = const <String, int>{};

  /// 本帧「继续」行实际显示的条目（[_buildStudyContinueCard] 写入）：宽屏「最近
  /// 添加」行据此去重，同一部作品不在两行各出一张。
  List<_ContinueEntry> _continueVisible = const <_ContinueEntry>[];

  /// '<mediaType>|<entryKey>' → 条目在其主折叠合集里的组内 sortIndex（只记归属
  /// 主合集的行，书架/视频页同口径）。继续区合集 Next-Up 的组内排序键。
  Map<String, int> _memberSortIndex = const <String, int>{};

  /// 每个视频 bookUid 的最近观看时刻（epoch 毫秒），继续观看排序用。
  Map<String, int> _videoWatchAtByUid = const <String, int>{};

  /// Bangumi 追踪链路的可见状态（[MediaTrackingService.loadStatus]）。
  MediaTrackingStatus _tracking = MediaTrackingStatus.empty;

  /// 「立即同步」按钮的进行中态。
  bool _trackingSyncBusy = false;

  /// 订阅「数据变了」信号（阅读/观看/导入落库）以自动刷新，及其防抖定时器。
  /// 首页不保活、且阅读器是 pushed 路由（读完回来首页不重建 initState），故必须靠
  /// DB 表级变更主动重查，否则「打开一本书读完回来」活动/热力图仍是旧数据。
  StreamSubscription<void>? _dataChangeSub;
  Timer? _reloadDebounce;

  /// **本轮加载时**的统计窗口（今日目标 / 近 7 日日均都用它，BUG-2219：此前目标
  /// 卡在 build 时现算 todayKey，跨午夜后分子对着新的一天、热力图等仍是旧聚合）。
  /// 跨午夜由 [_midnightReload] 触发一次 [_scheduleReload] 整页重拉。
  StatWindow _statWindow = StatWindow(DateTime.now());
  Timer? _midnightReload;

  /// 首次 [_loadDashboardData] 是否已结束（成功或 fail-open 都算）。
  ///
  /// 2026-10 体验优化：此前首帧各区块拿空数据直接渲染，用户先看到一闪
  /// 「暂无活动记录」/ 空热力图，几百毫秒后才换成真实内容，像是数据丢了。
  /// 完成前「继续」/ 学习卡 / 动态区块挂同轮廓骨架（home_dashboard_widgets），
  /// 之后的防抖重载不再回到骨架（旧数据先留着，避免每次写库都闪一下）；有
  /// [_snapshots] 快照时重建首帧直接视为已完成。
  bool _initialLoadDone = false;

  /// 按数据库实例缓存的上一轮本地聚合（BUG-3034，见 [_HomeDashboardSnapshot]）。
  /// [Expando] 随数据库实例回收，换库 / 测试各自建库天然隔离。
  static final Expando<_HomeDashboardSnapshot> _snapshots =
      Expando<_HomeDashboardSnapshot>('home-dashboard-snapshot');

  @override
  void initState() {
    super.initState();
    // 有上一轮快照：首帧直接用它渲染（骨架只在「本进程第一次进首页」出现），
    // 下面的整批重拉照常跑、到达后整体替换。
    final _HomeDashboardSnapshot? snapshot =
        _snapshots[ref.read(appProvider).database];
    if (snapshot != null) {
      _applySnapshot(snapshot);
      _initialLoadDone = true;
    }
    unawaited(_loadDashboardData());
    // 阅读/观看/导入写库 → 表级变更 → 防抖后重查聚合，首页自动刷新（竞态无关：
    // 信号在写入 commit 后才发，重查读到的是已落库数据）。
    _dataChangeSub = ref
        .read(appProvider)
        .database
        .watchDashboardDataChanges()
        .listen((_) => _scheduleReload());
    // P4：游戏改名/刮削（库页写穿 galgames 表后 GalgameRepository.load() 通知）
    // 也要刷新日明细/时间轴的游戏显示名——galgames 表不在
    // watchDashboardDataChanges 的表集里，走仓储 ChangeNotifier 这条既有通道
    // 与视频（videoBooks 表级信号）对齐失效语义。
    _galgameRepo = ref.read(appProvider).galgameRepo
      ..addListener(_scheduleReload);
    // Bangumi 同步状态：outbox 与偏好都不在 watchDashboardDataChanges 的表集里，
    // 由服务层每轮同步结束后自增的 revision 通知（后台自动同步完成也会刷新本卡）。
    _trackingRevision = ref
        .read(appProvider)
        .mediaTrackingService
        .statusRevision
      ..addListener(_scheduleReload);
    // 「显示远端条目」门控翻转（BUG-1182 同款，视频页已修、本页此前漏了）：
    // 翻开 → 立即补拉远端；关掉 → 立即清掉已混排进「继续」/时间轴的远端条目。
    _prefsRepoForRemoteGate = ref.read(appProvider).prefsRepo
      ..addListener(_onPrefsChangedForRemoteGate);
    _updateCount = HomeUpdateCount(ref.read(appProvider).updateFeedService);
  }

  /// prefsRepo 变更回调：只关心「显示远端条目」门控是否翻转，其余偏好变动一概
  /// 忽略——prefsRepo 的通知很频繁，不能每次都重跑远端取数。
  void _onPrefsChangedForRemoteGate() {
    if (!mounted) return;
    final bool gate = ref.read(appProvider).prefsRepo.showRemoteEntries;
    if (gate == _remoteGateAtLastLoad) return;
    unawaited(_loadRemoteDashboardData());
  }

  /// 追踪状态版本号（[initState] 挂监听，[dispose] 解除）。
  EngineValueListenable<int>? _trackingRevision;

  /// 游戏库仓储（[initState] 挂监听，[dispose] 解除）。
  GalgameRepository? _galgameRepo;

  /// 首页 tab 保活（2026-10 切 tab 卡顿）后，切回首页不再整页重挂载；切回时
  /// 只补做隐藏期间被推迟的重载（[_reloadDeferredWhileHidden]），并经共享 TTL
  /// 缓存补一次互联远端（与视频页 BUG-994 同一范式）。
  @override
  HomeTab get shellTab => HomeTab.home;

  @override
  void onTabActivated() {
    if (_reloadDeferredWhileHidden) {
      _reloadDeferredWhileHidden = false;
      _reloadNow();
      return;
    }
    unawaited(_loadRemoteDashboardData(skipIfUnchanged: true));
  }

  /// 首页被 Offstage 藏着时到达的数据变更：只记一笔，不在后台重跑整批聚合。
  ///
  /// 保活之前首页一切走就 dispose，根本不会在别的 tab 上重查；保活之后若照旧
  /// 每次写库都重载，用户在书架 / 阅读器里翻页（readerPositions 写入）就会让
  /// 看不见的首页隔几秒在 UI isolate 上跑一遍全量统计聚合。
  bool _reloadDeferredWhileHidden = false;

  bool get _isVisibleTab => homeShellTabNotifier.value == HomeTab.home;

  /// 最近一次已完成合集收养的远端清单（对象身份，见 [_loadRemoteDashboardData]）。
  List<RemoteBookInfo>? _adoptedRemoteBooks;
  List<RemoteVideoInfo>? _adoptedRemoteVideos;

  /// 最近一次混排上屏的三份远端清单（对象身份）；门控关闭清空远端状态时一并作废。
  List<RemoteBookInfo>? _appliedRemoteBooks;
  List<RemoteVideoInfo>? _appliedRemoteVideos;

  /// 表变更后防抖重载（多次连续写只重查一次，避免频繁 setState）。
  void _scheduleReload() {
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      if (!_isVisibleTab) {
        _reloadDeferredWhileHidden = true;
        return;
      }
      _reloadNow();
    });
  }

  void _reloadNow() {
    // 「继续」的书侧数据来自缓存 provider（书列表/最近阅读时刻均派生自
    // reader_positions），它们此前只在关书/导入时失效——互联/云同步把更远的
    // 对端进度写回后首页拿不到新值、要重启才生效。表级变更信号（现已含
    // readerPositions）到达时一并失效，让下面的重载 + build 的 ref.watch 读到
    // 新进度。频度由写入端自身的 debounce + 本 400ms 防抖兜住。
    ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
    ref.invalidate(bookLastReadAtProvider);
    // BUG-2918：读完标记（EpubBooks.completedAt）变更同样经表级信号到达。
    ref.invalidate(completedEpubBookKeysProvider);
    unawaited(_loadDashboardData());
  }

  @override
  void dispose() {
    _reloadDebounce?.cancel();
    _midnightReload?.cancel();
    unawaited(_dataChangeSub?.cancel());
    _galgameRepo?.removeListener(_scheduleReload);
    _trackingRevision?.removeListener(_scheduleReload);
    _prefsRepoForRemoteGate?.removeListener(_onPrefsChangedForRemoteGate);
    _dashboardScrollController.dispose();
    _toolbarScroll.dispose();
    _updateCount?.dispose();
    super.dispose();
  }

  /// 一次性异步载入视频库 + 统计行 + 活动事件，并派生热力图/时长窗口/最近观看映射。
  ///
  /// 整段包 try/catch fail-open：任一 DB 读抛异常也不会让整页卡在 loading 或抛未捕获
  /// 异常（各区块对空数据都有降级），并补 [ErrorLogService] 使「首页空」这类问题线上
  /// 可诊断（对照 reader/video 侧统计 flush 的同款 fail-open）。
  Future<void> _loadDashboardData() async {
    try {
      await _loadDashboardDataUnsafe();
    } catch (e, stack) {
      ErrorLogService.instance.log('HomeDashboardPage.load', e, stack);
    } finally {
      if (mounted && !_initialLoadDone) {
        setState(() => _initialLoadDone = true);
      }
    }
  }

  /// 到下一个本地午夜整页重拉（每次加载重新排一次；页面已卸载则不动）。
  void _armMidnightReload(DateTime now) {
    _midnightReload?.cancel();
    _midnightReload = Timer(StatWindow.untilNextStatDayBoundary(now), () {
      if (mounted) _scheduleReload();
    });
  }

  Future<void> _loadDashboardDataUnsafe() async {
    final AppModel appModel = ref.read(appProvider);
    final FushiDatabase db = appModel.database;
    final DateTime loadedAt = DateTime.now();
    final StatWindow statWindow = StatWindow(loadedAt);
    _armMidnightReload(loadedAt);
    // 视频书架、统计事实面、合集/附加图四张表互不依赖：一次全部发出，让 Drift
    // 后台执行器流水线化（首页首绘被这串 await 串行 gate）。
    final Future<List<VideoBookRow>> videosF = widget.videoRepo.listForShelf();
    // v92：学习统计只经统一事实面读取（study_segments + 冻结的 legacy 投影表，
    // 游戏时长来自 galgame_sessions、游戏 hook 字数来自 legacy game 行 + 段），
    // 首页不再自己读六张表各自累加——与阅读/视频/游戏统计页同一份事实。
    final Future<StatFacts> factsF = loadStatFacts(db);
    final Future<List<MediaCollectionRow>> collectionsF =
        db.getAllMediaCollections();
    // 折叠归属主合集 + 组内 sortIndex 一次查回，且只查本机库里还在的条目
    // （BUG-3034：原先 getPrimaryCollectionIdByEntry + getAllCollectionItems 两次
    // 全表物化，在线源 / 播放列表合集把成员表撑到八万行时单这两步 640–950 ms）。
    final Future<Map<String, ({int collectionId, int sortIndex})>>
        membershipF = db.getLocalPrimaryCollectionMembership();
    // 游戏库整表（「继续」区在玩的游戏）。仓储缓存与表恒一致，
    // 未载入过才真查 DB（毫秒级）；load() 会 notify → 本页监听器防抖重载一次
    // 后 isLoaded=true，不再形成回环。与其余读并发发出（此前排在整批之后串行）。
    final GalgameRepository galgameRepo = appModel.galgameRepo;
    final Future<List<GalgameEntry>> gamesF = galgameRepo.isLoaded
        ? Future<List<GalgameEntry>>.value(galgameRepo.games)
        : galgameRepo.load();
    // Bangumi 追踪状态（映射 + 待办 + 上次同步结果）。读的是本地库与偏好，不发
    // 网络请求，可以和其它聚合一起进首屏。临时下线期间卡不挂载，状态也不必查。
    final Future<MediaTrackingStatus> trackingF = kMediaTrackingEnabled
        ? appModel.mediaTrackingService.loadStatus()
        : Future<MediaTrackingStatus>.value(MediaTrackingStatus.empty);
    await Future.wait<Object?>(<Future<Object?>>[
      videosF,
      factsF,
      collectionsF,
      membershipF,
      gamesF,
      trackingF,
    ]);
    final List<VideoBookRow> videos = await videosF;
    final StatFacts facts = await factsF;
    final List<StatFact> reading = facts.dailyBooks.toList(growable: false);
    final List<StatFact> watch = facts.dailyVideos.toList(growable: false);
    final List<StatFact> game = facts.dailyGames.toList(growable: false);
    final List<GalgameEntry> games = await gamesF;
    // 合集归属映射（统计页/书架同源）：显示名规则「非合集上下文拼合集名」用。
    final List<MediaCollectionRow> collections = await collectionsF;
    final Map<int, String> collectionNamesById = <int, String>{
      for (final MediaCollectionRow c in collections) c.id: c.name,
    };
    final Map<int, String> collectionCoverById = <int, String>{
      for (final MediaCollectionRow c in collections)
        if (c.coverPath case final String path when path.isNotEmpty)
          c.id: path,
    };
    final Map<String, ({int collectionId, int sortIndex})> membership =
        await membershipF;
    final Map<String, int> primaryByEntry = <String, int>{
      for (final MapEntry<String, ({int collectionId, int sortIndex})> e
          in membership.entries)
        e.key: e.value.collectionId,
    };
    // 组内序：条目在其主折叠合集里的 sortIndex（视频页/书架 _loadShelfMaps 同
    // 口径——只记归属主合集的行；SQL 侧已按主键回查好）。
    final Map<String, int> memberSortIndex = <String, int>{
      for (final MapEntry<String, ({int collectionId, int sortIndex})> e
          in membership.entries)
        e.key: e.value.sortIndex,
    };
    final List<EpubBookMeta> epubRows = facts.epubRows;
    // v83：成员表 epub entryKey = uid，同批行顺带建 bookKey→uid 换算表（空 uid
    // 异常行不进表，查归属时按 bookKey 原样回退）。
    final Map<String, String> epubUidByBookKey = <String, String>{
      for (final EpubBookMeta r in epubRows)
        if (r.uid.isNotEmpty) r.bookKey: r.uid,
    };
    final Map<String, int> epubImportedAtByKey = <String, int>{
      for (final EpubBookMeta r in epubRows) r.bookKey: r.importedAt,
    };

    // 每个视频的最近观看时刻（按 bookUid 取 lastActiveMs 最大值；legacy 无身份行
    // mediaKey '' 跳过）。
    final Map<String, int> watchAt = <String, int>{};
    for (final StatFact w in watch) {
      final String uid = w.mediaKey;
      if (uid.isEmpty) continue;
      if (w.lastActiveMs > (watchAt[uid] ?? 0)) {
        watchAt[uid] = w.lastActiveMs;
      }
    }

    final MediaTrackingStatus tracking = await trackingF;

    // 在看视频的总时长（「继续」卡进度条 / 百分比角标）：只查有断点的本地文件，
    // 一条 IN 查询拿全；探测缓存里没有的（流媒体 / 没探测过）不进表。
    final Map<String, VideoFileSpecRow> specs = await db.videoFileSpecsByPath(
      <String>[
        for (final VideoBookRow v in videos)
          if (v.lastPositionMs > 0 && v.completedAt == null) v.videoPath,
      ],
    );
    final Map<String, int> durationByPath = <String, int>{
      for (final MapEntry<String, VideoFileSpecRow> e in specs.entries)
        if ((e.value.durationMs ?? 0) > 0) e.key: e.value.durationMs!,
    };

    final _HomeDashboardSnapshot snapshot = _HomeDashboardSnapshot(
      statWindow: statWindow,
      videos: videos,
      games: games,
      tracking: tracking,
      readingRows: reading,
      watchRows: watch,
      gameRows: game,
      collectionNamesById: collectionNamesById,
      primaryCollectionByEntry: primaryByEntry,
      collectionCoverById: collectionCoverById,
      epubUidByBookKey: epubUidByBookKey,
      epubImportedAtByKey: epubImportedAtByKey,
      memberSortIndex: memberSortIndex,
      videoWatchAtByUid: watchAt,
      videoDurationMsByPath: durationByPath,
    );
    _snapshots[db] = snapshot;
    if (!mounted) return;
    setState(() => _applySnapshot(snapshot));
    // 本地渲染先行，互联数据到达后再增量补位（不阻塞首屏）。
    unawaited(_loadRemoteDashboardData());
  }

  /// 把一轮聚合结果灌进页面状态（加载完成与重建时从快照恢复共用）。远端补位
  /// 不在快照里，由 [_loadRemoteDashboardData] 增量到达。
  void _applySnapshot(_HomeDashboardSnapshot s) {
    _statWindow = s.statWindow;
    _videos = s.videos;
    _games = s.games;
    _tracking = s.tracking;
    _readingRows = s.readingRows;
    _watchRows = s.watchRows;
    _gameRows = s.gameRows;
    _collectionNamesById = s.collectionNamesById;
    _primaryCollectionByEntry = s.primaryCollectionByEntry;
    _collectionCoverById = s.collectionCoverById;
    _epubUidByBookKey = s.epubUidByBookKey;
    _epubImportedAtByKey = s.epubImportedAtByKey;
    _memberSortIndex = s.memberSortIndex;
    _videoWatchAtByUid = s.videoWatchAtByUid;
    _videoDurationMsByPath = s.videoDurationMsByPath;
  }

  /// 「继续也走 hibiki 互联」：互联启用且已配对时，从 host 拉取书清单（内联
  /// 阅读进度）/ 视频清单（内联播放断点），把本地没有的在读书、在看视频补进
  /// 「继续」（display-only 不落库）。任何失败静默保持纯本地视图（离线/老 host
  /// 不致崩）。2026-10 精简删掉活动时间轴后不再拉远端活动流。
  ///
  /// [skipIfUnchanged]：切回首页（[onTabActivated]）时为 true——两份清单都还是
  /// 上一轮已经混排上屏的同一批对象（TTL 内缓存命中）就到此为止，不再重算
  /// 补位卡、也不 setState 整页重建。本地聚合重载之后的那次补位
  /// 不传：本地数据变了，补位要按新的本地集合重算。
  Future<void> _loadRemoteDashboardData({bool skipIfUnchanged = false}) async {
    final AppModel appModel = ref.read(appProvider);
    // 「显示远端条目」门控前移到取数之前（BUG-1182 视频页同款）：此前本页只判
    // 互联开关，关掉开关的用户仍全额付远端请求的网络代价、远端条目照混排。
    // 门控必须是第一道闸——关着就零远端工作，翻关时顺手清掉已到达的远端状态。
    _remoteGateAtLastLoad = appModel.prefsRepo.showRemoteEntries;
    if (!_remoteGateAtLastLoad) {
      _clearRemoteDashboardData();
      return;
    }
    final SyncRepository syncRepo = SyncRepository(appModel.database);
    // 互联是独立开关（已与云备份后端解耦），未启用/未配对直接跳过。
    if (!await syncRepo.isInterconnectEnabled()) return;
    final InterconnectSyncBackend backend = InterconnectSyncBackend.instance;
    if (!await backend.restoreAuth(syncRepo)) return;
    try {
      // BUG-1180：首页不在 `_keepAliveTabs` 里，每次切回首页整页重建 → 远端请求
      // 原本每次都重发；`_scheduleReload` 的 400ms 防抖重载还会再走一遍。改为
      // ① 过共享 TTL 缓存（书/视频清单与书架、视频页同槽，谁先拉到谁受益），
      // ② 请求并行而不是串行。
      final RemoteLibraryCache cache = ref.read(remoteLibraryCacheProvider);
      final List<Object> results = await Future.wait<Object>(<Future<Object>>[
        // 首页只走互联（上面已 return 掉未启用的情况），来源身份仍从 backend 自己
        // 取而不是写字面量——书/视频两个域与书架、视频页同槽命中，靠的就是双方报出
        // 同一个 id（BUG-1202）。
        cache.read<List<RemoteBookInfo>>(
          sourceId: backend.remoteLibrarySourceId,
          key: RemoteLibraryCacheKeys.books,
          fetch: backend.listRemoteBooks,
        ),
        cache.read<List<RemoteVideoInfo>>(
          sourceId: backend.remoteLibrarySourceId,
          key: RemoteLibraryCacheKeys.videos,
          fetch: backend.listRemoteVideos,
        ),
      ]);
      final List<RemoteBookInfo> remoteBooks =
          results[0] as List<RemoteBookInfo>;
      final List<RemoteVideoInfo> remoteVideos =
          results[1] as List<RemoteVideoInfo>;
      final RemoteCollectionAdoptionService adoption =
          RemoteCollectionAdoptionService(appModel.database);
      // TTL 内缓存回的是同一个清单对象，它的合集收养已经落过库：不再逐条重做
      // （书那边每轮还要全表装载一次身份索引）。保活后切回首页会走这里。
      if (!identical(remoteBooks, _adoptedRemoteBooks)) {
        await adoption.adoptBooks(remoteBooks);
        _adoptedRemoteBooks = remoteBooks;
      }
      if (!identical(remoteVideos, _adoptedRemoteVideos)) {
        for (final RemoteVideoInfo video in remoteVideos) {
          await adoption.adoptVideo(video);
        }
        _adoptedRemoteVideos = remoteVideos;
      }
      if (skipIfUnchanged &&
          identical(remoteBooks, _appliedRemoteBooks) &&
          identical(remoteVideos, _appliedRemoteVideos)) {
        return;
      }
      if (!mounted) return;
      final List<MediaItem> books =
          ref.read(fushiBooksProvider(JapaneseLanguage.instance)).valueOrNull ??
              const <MediaItem>[];
      final Set<String> localBookKeys = <String>{
        for (final MediaItem item in books)
          ReaderFushiSource.parseBookKey(item.mediaIdentifier) ??
              item.mediaIdentifier,
      };
      localBookKeys.addAll(
        (await CollectionBookIdentityIndex.load(appModel.database)).uidByKey.keys,
      );
      if (!mounted) return;
      final Set<String> localVideoUids = <String>{
        for (final VideoBookRow v in _videos) v.bookUid,
      };
      final List<RemoteContinueCandidate> continueCandidates =
          remoteContinueCandidates(
        localBookKeys: localBookKeys,
        localVideoUids: localVideoUids,
        remoteBooks: remoteBooks,
        remoteVideos: remoteVideos,
      );
      // 设备来源标注：配对时存下的 host 设备名（多地址时取第一个启用且有名的）。
      final List<FushiClientUrl> urls = await syncRepo.getFushiClientUrls();
      String? deviceName;
      for (final FushiClientUrl u in urls) {
        final String? name = u.deviceName;
        if (u.enabled && name != null && name.isNotEmpty) {
          deviceName = name;
          break;
        }
      }
      if (!mounted) return;
      setState(() {
        _remoteContinue = continueCandidates;
        _appliedRemoteBooks = remoteBooks;
        _appliedRemoteVideos = remoteVideos;
        _remoteCoverFetcher = remoteCoverFetcherFor(backend);
        _remoteDeviceName = deviceName;
      });
    } catch (_) {
      // 互联瞬断/超时：保持纯本地视图；下次进入首页自然重试。
    }
  }

  /// 门控关闭时清掉已混排进页面的远端状态（「继续」补位卡 / 设备名 / 封面
  /// 取图器），回到纯本地视图。没有远端状态时不动 UI。
  void _clearRemoteDashboardData() {
    if (!mounted) return;
    final bool hasRemoteState = _remoteContinue.isNotEmpty ||
        _remoteDeviceName != null ||
        _remoteCoverFetcher != null;
    if (!hasRemoteState) return;
    _appliedRemoteBooks = null;
    _appliedRemoteVideos = null;
    setState(() {
      _remoteContinue = const <RemoteContinueCandidate>[];
      _remoteCoverFetcher = null;
      _remoteDeviceName = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final AppModel appModel = ref.watch(appProvider);
    final List<MediaItem> books =
        ref.watch(fushiBooksProvider(JapaneseLanguage.instance)).valueOrNull ??
            const <MediaItem>[];
    final Map<String, int> lastReadByKey =
        ref.watch(bookLastReadAtProvider).valueOrNull ?? const <String, int>{};
    // v82：lastReadByKey 的键是书 uid；MediaItem 身份是 bookKey，查前经此表换算。
    final Map<String, String> epubUidByKey =
        ref.watch(epubBookUidByKeyProvider).valueOrNull ??
            const <String, String>{};
    final Set<String> completedBookKeys =
        ref.watch(completedEpubBookKeysProvider).valueOrNull ??
            const <String>{};
    // Bangumi 同步临时下线（kMediaTrackingEnabled，见 media_tracking_service.dart）。
    // 上线状态下此卡恒显示（未连接时也要显示——「没连上」本身就是用户最需要看到的
    // 那条状态，隐藏它就回到了「看完了没反应」的黑盒）。
    // 媒体追踪属 [ModuleId.services]（追踪靠在线服务的凭据跑，同一个开关）：模块
    // 关掉时整卡不挂载——卡内的「去设置」直落 mediaTracking 分类，而那个分类此刻
    // 已被同一个开关从设置页藏掉，留着就是一条通往不存在页面的死路。
    final Widget? trackingCard =
        kMediaTrackingEnabled &&
            appModel.moduleVisibility.isEnabled(ModuleId.services)
        ? _buildTrackingCard(tokens, appModel, DateTime.now())
        : null;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 2026-10 精简（用户反馈「首页砍到只剩有用的」）：原四栏（继续 / 学习活动
        // / 最近添加 / 活动）收成**一张卡**——顶部学习头部行（目标环 + 今日字数 +
        // 今日时长），下面是只有封面的「继续」行。热力图（统计中心能看）、最近
        // 添加、活动时间轴（本机 + 同步同一本书各出一条，重复）全部删掉。宽屏不再
        // 分主列 / 侧列，卡片通栏，封面随宽度放大。
        //
        // 宽屏（桌面 / 平板横屏，用户 2026-10-09：下方空白太多）补两样，手机宽度
        // 不变：① 封面随窗口宽放大（[dashboardWideCoverHeight]）；② 主卡下方加
        // 一行「最近添加」封面（无标题行，每张卡挂「新」角标自解释；与「继续」
        // 已有的作品去重）。不恢复学习日历 / 活动栏 / 标题行 / 筛选。
        final bool wide = constraints.maxWidth >= _kWideLayoutMinWidth;
        final double coverHeight = wide
            ? dashboardWideCoverHeight(constraints.maxWidth)
            : _kContinueCoverHeight;
        final Widget studyCard = _buildStudyContinueCard(
          tokens,
          appModel,
          books,
          lastReadByKey,
          epubUidByKey,
          completedBookKeys,
          coverHeight: coverHeight,
        );
        final Widget? recentCard = wide && _initialLoadDone
            ? _buildRecentlyAddedCard(
                tokens,
                appModel,
                books,
                coverHeight: coverHeight * _kRecentCoverScale,
              )
            : null;
        int entrance = 0;
        final Widget body = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FushiStaggeredEntrance(index: entrance++, child: studyCard),
            if (recentCard != null) ...<Widget>[
              SizedBox(height: tokens.spacing.card),
              FushiStaggeredEntrance(index: entrance++, child: recentCard),
            ],
            if (trackingCard != null) ...<Widget>[
              SizedBox(height: tokens.spacing.card),
              FushiStaggeredEntrance(index: entrance++, child: trackingCard),
            ],
          ],
        );
        // 2026-10 动效重做：仪表盘首屏错峰进场。
        // 2026-10 首页统一浮动工具栏：顶部不再是贴边实体条，栏与「继续」FAB
        // 悬浮在列表之上（Stack），列表顶部让出栏高、底部让出 FAB 与外壳
        // 底栏（Apple 悬浮标签栏经 extendBody 并进 MediaQuery 底部内边距）。
        final double bottomInset = MediaQuery.paddingOf(context).bottom;
        final Widget list = ListView(
            controller: _dashboardScrollController,
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.card,
              kHomeToolbarExtent + tokens.spacing.card,
              tokens.spacing.card,
              tokens.spacing.card + bottomInset + kHomeFabClearance,
            ),
            children: <Widget>[
              // v101 更新提醒：有未读时才占位（横幅自己在 total==0 时收成
              // SizedBox.shrink），没有更新的日子首页不多一块空卡。
              UpdatesDashboardBanner(service: appModel.updateFeedService),
              // 已迁移只读态（Fushi 迁移 P1-4，仅老包生效）：首屏常驻引导。
              if (appModel.isMigrationReadonly) ...<Widget>[
                _MigrationReadonlyBanner(appModel: appModel),
                SizedBox(height: tokens.spacing.card),
              ],
              // Fushi 侧（P2-2/P2-3）：检测到迁移数据 → 导入引导；导入完成且旧包
              // 仍在 → 卸载引导（ACTION_DELETE + 复查）。仅 Android。
              if (!kIsWeb &&
                  Platform.isAndroid &&
                  appModel.packageInfo.packageName !=
                      kHibikiPackageName) ...<Widget>[
                _FushiMigrationBanner(appModel: appModel),
              ],
              body,
            ],
        );
        return FushiEntranceScope(
          // 一个遍历组：Tab 先走顶部浮动栏（几何上在最上方），再进列表，
          // 最后是 FAB。
          child: FocusTraversalGroup(
            child: Stack(
              children: <Widget>[
                NotificationListener<ScrollNotification>(
                  onNotification: _toolbarScroll.handle,
                  child: list,
                ),
                Positioned(
                  top: 0,
                  left: tokens.spacing.card,
                  right: tokens.spacing.card,
                  child: _buildFloatingToolbar(),
                ),
                PositionedDirectional(
                  end: kHomeFabMargin,
                  bottom: kHomeFabMargin + bottomInset,
                  child: _buildResumeFab(appModel),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
  // ── 浮动工具栏 + 「继续」FAB（2026-10 首页统一浮动工具栏） ───────────────────

  /// 顶部浮动工具栏：标题胶囊（页面名）+ 动作按钮组（更新中心 · 统计中心 ·
  /// 排行榜 · 反馈）。首页此前没有页头，这三个入口分散在更新横幅（只在有未读时出现）
  /// 与学习卡标题行尾；收进一条与阅读器 / 视频同款的 M3E 浮动工具栏后，常驻
  /// 可达、滚动时让位。
  Widget _buildFloatingToolbar() {
    final AppModel appModel = ref.read(appProvider);
    final HomeUpdateCount? updateCount = _updateCount;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable?>[_toolbarScroll, updateCount]),
      builder: (BuildContext context, Widget? _) {
        final int unseen = updateCount?.value ?? 0;
        final int feedbackUnseen = watchFeedbackUnseen(ref);
        return HomeFloatingToolbar(
          // 2026-10 精简：左上角原「首页」标题胶囊换成用户头像（排行榜账户头像，
          // 没开账户时退回 Profile 名首字），点开排行榜（账户页在那里）。
          leading: _HomeAvatarPill(onPressed: _openLeaderboard),
          visible: _toolbarScroll.visible,
          actions: <FushiToolbarItem>[
            // 有未读时换成「响铃」字形并把未读数写进 tooltip / 语义标签（共享
            // 工具栏按钮没有角标槽；逐域未读明细仍在下方更新横幅里）。
            FushiToolbarItem(
              key: const ValueKey<String>('home-toolbar-updates'),
              icon: unseen > 0
                  ? FushiIcons.notificationsActive
                  : FushiIcons.notifications,
              label: unseen > 0
                  ? '${t.updates_center_title} ($unseen)'
                  : t.updates_center_title,
              onPressed: () => unawaited(_openUpdates(appModel)),
            ),
            FushiToolbarItem(
              key: const ValueKey<String>('home-toolbar-stats'),
              icon: FushiIcons.barChart,
              label: t.stat_center_title,
              onPressed: _openStatisticsCenter,
            ),
            // 排行榜：统计中心隔壁单独一颗按钮（2026-10-01 从统计中心 tab 抽出）。
            FushiToolbarItem(
              key: const ValueKey<String>('home-toolbar-leaderboard'),
              icon: FushiIcons.trophy,
              label: t.leaderboard_title,
              onPressed: _openLeaderboard,
            ),
            // 反馈：提交问题 / 建议并看处理进度（悬浮球上也有同一个入口）。
            // 开发者有新回复时把条数写进 tooltip / 语义标签（同更新中心的做法）。
            FushiToolbarItem(
              key: const ValueKey<String>('home-toolbar-feedback'),
              icon: FushiIcons.forum,
              label: feedbackUnseen > 0
                  ? '${t.feedback_title} ($feedbackUnseen)'
                  : t.feedback_title,
              onPressed: () => unawaited(openFeedbackCenter(context)),
            ),
          ],
        );
      },
    );
  }

  /// 「继续」FAB：「继续」封面行滚出视野后出现，续开最近一条（与点第一张封面
  /// 同一出口 [_openContinueEntry]）。为什么要 FAB：首页的首要动作就是「接着读 /
  /// 接着看」，M3 用 FAB 承载页面唯一主操作；首屏封面本身就能点，所以只在它
  /// 滚出视野后补位。
  Widget _buildResumeFab(AppModel appModel) {
    final _ContinueEntry? entry = _resumeEntry;
    return ListenableBuilder(
      listenable: _toolbarScroll,
      builder: (BuildContext context, Widget? _) => HomeResumeFab(
        key: const ValueKey<String>('home-resume-fab'),
        visible: entry != null && _toolbarScroll.pastHero,
        icon: entry == null
            ? FushiIcons.play
            : _resumeActionIcon(entry),
        label: entry == null ? t.home_continue : _resumeActionLabel(entry),
        onPressed: () {
          final _ContinueEntry? current = _resumeEntry;
          if (current != null) {
            unawaited(_openContinueEntry(appModel, current));
          }
        },
      ),
    );
  }

  /// 工具栏「更新中心」：打开后回来刷新角标（看过的条目不再算未读）。
  Future<void> _openUpdates(AppModel appModel) async {
    await openUpdatesCenter(context, appModel.updateFeedService);
    await _updateCount?.reload();
  }

  // ── 学习 + 继续（2026-10 精简后首页唯一的主卡） ───────────────────────────

  /// 首页主卡：顶部学习头部行（[HomeStudyHeader]：目标环 + 今日字数 + 今日时长），
  /// 下面是「继续」封面行——在读的书（[isDashboardContinueBook]）、在看的视频
  /// （有断点且未完成 / 合集 Next-Up）、玩过的游戏与互联远端补位按最近活动时刻
  /// 倒序混排取前 10 条。不再有分类筛选（用户反馈「主界面没必要分四类，查看分类
  /// 留给统计中心」），也不再有「继续」标题与条目标题（看封面就知道是什么）。
  Widget _buildStudyContinueCard(
    FushiDesignTokens tokens,
    AppModel appModel,
    List<MediaItem> books,
    Map<String, int> lastReadByKey,
    Map<String, String> epubUidByKey,
    Set<String> completedBookKeys, {
    required double coverHeight,
  }) {
    final List<_ContinueEntry> entries = <_ContinueEntry>[];
    for (final MediaItem item in books) {
      if (isDashboardContinueBook(item, completedBookKeys)) {
        final String bookKey =
            ReaderFushiSource.parseBookKey(item.mediaIdentifier) ??
                item.mediaIdentifier;
        // v82：位置表键 = uid，bookKey 经换算表转一跳；换算不上（standalone
        // SRT / 书行已删）保持原键查询——与旧行为同样查不到、recent=0。
        final int recent = lastReadByKey[epubUidByKey[bookKey] ?? bookKey] ?? 0;
        final int percent =
            ((item.position / item.duration) * 100).clamp(0, 100).round();
        entries.add(_ContinueEntry(
          kind: _bookMediaKind(item),
          // BUG-1018 (A1)：书名走与书架卡同一 override 通道（编辑对话框改名后
          // 首页「继续」区同步显示新名），不直接读 DB 原名。
          title: ReaderFushiSource.instance.getDisplayTitleFromMediaItem(item),
          recentMs: recent,
          progress: percent / 100,
          badgeLabel: '$percent%',
          collectionName: statCollectionName(
            _bookCollectionKey(item),
            _primaryCollectionByEntry,
            _collectionNamesById,
          ),
          book: item,
        ));
      }
    }
    // 视频侧合集感知 Next-Up（用户实报：合集里看完一集，合集不该从「继续」消
    // 失，应推进为下一集）：成员按主折叠合集归组，每个合集在继续区**最多一张
    // 卡**——组内复用视频页 hero 同口径（BUG-848 computeVideoLibraryOverview
    // 的单元逻辑：sortIndex 排序 + [continueMemberIndex] 的 Jellyfin Next-Up
    // 语义）；整组看完/整组没看过不出卡。散卡保持「有断点且未看完」现行为。
    // 单行多集形态（playlistJson/currentEpisode 行内集数）completedAt 按整行，
    // 天然沿用现行为。
    final Map<int, List<VideoBookRow>> videosByCollection =
        <int, List<VideoBookRow>>{};
    final List<VideoBookRow> standaloneVideos = <VideoBookRow>[];
    for (final VideoBookRow v in _videos) {
      final int? cid =
          _primaryCollectionByEntry[MediaKind.video.compositeKey(v.bookUid)];
      if (cid == null) {
        standaloneVideos.add(v);
      } else {
        (videosByCollection[cid] ??= <VideoBookRow>[]).add(v);
      }
    }
    for (final VideoBookRow v in standaloneVideos) {
      if (v.lastPositionMs > 0 && v.completedAt == null) {
        final int recent = _videoWatchAtByUid[v.bookUid] ?? v.importedAt ?? 0;
        entries.add(
          _videoContinueEntry(v, collectionName: null, recentMs: recent),
        );
      }
    }
    for (final MapEntry<int, List<VideoBookRow>> ce
        in videosByCollection.entries) {
      final ({VideoBookRow row, int index, int count})? target =
          _collectionResumeTarget(ce.value);
      if (target == null) continue;
      final VideoBookRow resume = target.row;
      // 单元活跃时刻 = 成员观看时刻最大值（含已完成集——Next-Up 卡按「刚看完
      // 上一集」的时间参与混排），无统计行回退续播目标导入时间。
      int recent = 0;
      for (final VideoBookRow m in ce.value) {
        final int at = _videoWatchAtByUid[m.bookUid] ?? 0;
        if (at > recent) recent = at;
      }
      if (recent == 0) {
        recent = resume.importedAt ?? 0;
      }
      entries.add(_videoContinueEntry(
        resume,
        collectionName: _collectionNamesById[ce.key],
        collectionId: ce.key,
        recentMs: recent,
        // 合集里的第几集（组内 sortIndex 序，1 起）；只有一集的合集不标集数。
        collectionEpisode: target.count >= 2 ? target.index + 1 : null,
        collectionEpisodeCount: target.count,
      ));
    }
    // BUG-1111：在玩的游戏。判据是「玩过」（lastPlayedMs>0）——游戏没有「读完/
    // 看完」这种完成度概念（`galgames` 无 completedAt，时长/次数由
    // `galgame_sessions` 现算），所以不做「未完成」过滤；排序与取前 N 由下面统一
    // 的 recentMs 倒序 + take(10) 兜住，不会淹没书与视频。
    // 合集单元收敛与视频侧 [_collectionResumeTarget] 同口径：**一个合集在继续区
    // 最多一张卡**。卡标题恒取合集名，不收敛的话同合集 N 个游戏会排出 N 张同名
    // 卡，直接把继续区刷屏。游戏无完成度可推进「下一部」（视频那套 Next-Up 依赖
    // completedAt），续玩目标取组内 lastPlayedMs 最大的一部——与该单元的 recentMs
    // 同源，混排位置也就是「这个系列最近一次玩」的时刻。
    final Map<int, GalgameEntry> gameResumeByCollection = <int, GalgameEntry>{};
    for (final GalgameEntry g in _games) {
      if (g.lastPlayedMs <= 0) continue;
      final int? cid =
          _primaryCollectionByEntry[MediaKind.game.compositeKey(g.id)];
      if (cid == null) {
        entries.add(_gameContinueEntry(g, collectionName: null));
        continue;
      }
      final GalgameEntry? best = gameResumeByCollection[cid];
      if (best == null || g.lastPlayedMs > best.lastPlayedMs) {
        gameResumeByCollection[cid] = g;
      }
    }
    for (final MapEntry<int, GalgameEntry> ge
        in gameResumeByCollection.entries) {
      entries.add(_gameContinueEntry(
        ge.value,
        // 合集名缺失（名字表没这行）→ null，与散卡同渲染，安全降级。
        collectionName: _collectionNamesById[ge.key],
      ));
    }
    // 互联 host 的远端补位（本地无同 key/uid 的在读书/在看视频），与本地条目
    // 按最近活动时刻统一混排（「继续也走互联」）。
    for (final RemoteContinueCandidate c in _remoteContinue) {
      entries.add(_ContinueEntry(
        // BUG-1119：此前是 `c.isVideo ? video : epub` 二元降维——远端 SRT 书会被
        // 抹成 epub、第三种媒体装不下（BUG-1111 的漏网消费点）。直读候选种类。
        kind: c.kind,
        title: c.title,
        recentMs: c.recentMs,
        // 远端书带 host 阅读百分比可画进度条；远端视频无集数/完成信息不画。
        progress: c.isVideo ? null : c.percent / 100,
        badgeLabel: c.isVideo ? null : '${c.percent}%',
        collectionName: c.collectionName,
        remote: c,
      ));
    }
    entries.sort(
      (_ContinueEntry a, _ContinueEntry b) => b.recentMs.compareTo(a.recentMs),
    );
    // 模块门控：关掉的模块的条目**先出局再 take(10)**——顺序反过来会出现「过滤后
    // 不足 10 条」（前 10 条恰好全是被关模块的条目时甚至整行空掉）。
    final ModuleVisibility visibility = appModel.moduleVisibility;
    final List<_ContinueEntry> visible = entries
        .where((_ContinueEntry e) => visibility.isEnabled(e.module))
        .take(10)
        .toList();
    _resumeEntry = visible.isEmpty ? null : visible.first;
    _continueVisible = visible;

    // 首载未结束时挂同轮廓骨架，而不是先闪空态再跳成真数据；新用户空库给空态
    // 说明 + 去书架 / 去媒体库的引导按钮（首页不会是一片空白）。
    final Widget continueContent;
    if (visible.isNotEmpty) {
      continueContent = _continueCardsRow(
        tokens,
        appModel,
        visible,
        coverHeight: coverHeight,
        rowKey: 'home-continue-row',
      );
    } else if (!_initialLoadDone) {
      continueContent = HomeContinueRowSkeleton(coverHeight: coverHeight);
    } else {
      continueContent = HomeEmptyState(
        icon: FushiIcons.playCircle,
        message: t.home_continue_empty,
        actions: <Widget>[
          for (final HomeTab tab in const <HomeTab>[
            HomeTab.books,
            HomeTab.video,
          ])
            if (isHomeTabVisible(tab, visibility))
              FushiFilledButton.tonalIcon(
                key: ValueKey<String>('home-empty-go-${tab.name}'),
                onPressed: () => _goToTab(tab),
                icon: FushiIcon(homeNavItemFor(tab).icon),
                label: Text(homeNavItemFor(tab).label),
              ),
        ],
      );
    }
    return _sectionCard(
      tokens,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (_initialLoadDone)
            _buildStudyHeader(tokens)
          else
            const HomeGoalSkeleton(),
          SizedBox(height: tokens.spacing.gap),
          // 数据到达 / 空库 ↔ 有内容切换时交叉淡入 + 尺寸弹簧过渡，不硬跳。
          FushiAnimatedSize(
            duration: fushiMotionDuration(context, FushiMotion.medium),
            curve: FushiMotion.standard,
            alignment: AlignmentDirectional.topStart,
            child: AnimatedSwitcher(
              duration: fushiMotionDuration(context, FushiMotion.medium),
              switchInCurve: FushiMotion.enter,
              switchOutCurve: FushiMotion.exit,
              child: KeyedSubtree(
                key: ValueKey<String>(
                  visible.isNotEmpty
                      ? 'continue'
                      : (_initialLoadDone ? 'empty' : 'loading'),
                ),
                child: continueContent,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 「继续」FAB 的动作文案。
  String _resumeActionLabel(_ContinueEntry entry) => switch (entry.kind) {
        MediaKind.video => t.video_continue_watching,
        MediaKind.epub || MediaKind.srt => t.book_continue_reading,
        // 游戏卡落地是切到游戏库（启动走那边的确认链），文案说「打开」；
        // 不用「继续」——会与分区标题撞成同一个词。
        MediaKind.game => t.collection_open,
      };

  /// 「继续」FAB 的动作图标。
  IconData _resumeActionIcon(_ContinueEntry entry) => switch (entry.kind) {
        MediaKind.video => FushiIcons.play,
        MediaKind.epub || MediaKind.srt => FushiIcons.books,
        MediaKind.game => FushiIcons.games,
      };

  /// 宽屏「最近添加」卡（用户 2026-10-09：桌面 / 平板横屏下方空白太多）。
  ///
  /// 只在宽屏挂（手机宽度布局不变），形态是一行比「继续」小一号的 2:3 封面：
  /// **没有标题行、没有筛选**（用户要求删掉的都不回来），每张卡左上角挂一枚缩小的
  /// 「新」角标自解释（右上角留给竖排书名）。数据源是本页快照里已有的书 / 视频 / 游戏行（不新增查询）：
  /// 书按 `EpubBooks.importedAt`、视频按 `VideoBooks.importedAt`（合集按成员
  /// 最大值收成一张，封面取合集海报）、游戏按 `addedAt` 倒序混排；已在「继续」
  /// 行出现的作品去重；关掉的模块先出局；取前 12。没有可显示的条目 → null
  /// （不出空卡）。
  Widget? _buildRecentlyAddedCard(
    FushiDesignTokens tokens,
    AppModel appModel,
    List<MediaItem> books, {
    required double coverHeight,
  }) {
    final Set<String> shownBooks = <String>{};
    final Set<String> shownVideos = <String>{};
    final Set<int> shownVideoCollections = <int>{};
    final Set<String> shownGames = <String>{};
    for (final _ContinueEntry e in _continueVisible) {
      if (e.remote != null) continue;
      if (e.book != null) shownBooks.add(e.book!.mediaIdentifier);
      if (e.video != null) {
        if (e.collectionId != null) {
          shownVideoCollections.add(e.collectionId!);
        } else {
          shownVideos.add(e.video!.bookUid);
        }
      }
      if (e.game != null) shownGames.add(e.game!.id);
    }

    final String badge = t.home_recent_badge;
    final List<_ContinueEntry> entries = <_ContinueEntry>[];
    for (final MediaItem item in books) {
      if (shownBooks.contains(item.mediaIdentifier)) continue;
      final String? bookKey =
          ReaderFushiSource.parseBookKey(item.mediaIdentifier);
      final int addedAt =
          bookKey == null ? 0 : (_epubImportedAtByKey[bookKey] ?? 0);
      if (addedAt <= 0) continue;
      entries.add(_ContinueEntry(
        kind: _bookMediaKind(item),
        title: ReaderFushiSource.instance.getDisplayTitleFromMediaItem(item),
        recentMs: addedAt,
        badgeLabel: badge,
        book: item,
      ));
    }

    final Map<int, List<VideoBookRow>> videosByCollection =
        <int, List<VideoBookRow>>{};
    for (final VideoBookRow v in _videos) {
      final int? cid =
          _primaryCollectionByEntry[MediaKind.video.compositeKey(v.bookUid)];
      if (cid != null) {
        (videosByCollection[cid] ??= <VideoBookRow>[]).add(v);
        continue;
      }
      final int addedAt = v.importedAt ?? 0;
      if (addedAt <= 0 || shownVideos.contains(v.bookUid)) continue;
      entries.add(_ContinueEntry(
        kind: MediaKind.video,
        title: v.title,
        recentMs: addedAt,
        badgeLabel: badge,
        video: v,
      ));
    }
    for (final MapEntry<int, List<VideoBookRow>> ce
        in videosByCollection.entries) {
      if (shownVideoCollections.contains(ce.key)) continue;
      int addedAt = 0;
      for (final VideoBookRow m in ce.value) {
        final int at = m.importedAt ?? 0;
        if (at > addedAt) addedAt = at;
      }
      if (addedAt <= 0) continue;
      // 点开落到组内第一集（sortIndex 序，缺失沉底）——新加的合集还没看过，从头
      // 开始；播放器按主合集建剧集面板，上下集照常可切。
      final VideoBookRow first = ce.value.reduce(
        (VideoBookRow a, VideoBookRow b) {
          final int ai =
              _memberSortIndex[MediaKind.video.compositeKey(a.bookUid)] ??
                  1 << 30;
          final int bi =
              _memberSortIndex[MediaKind.video.compositeKey(b.bookUid)] ??
                  1 << 30;
          if (ai != bi) return ai < bi ? a : b;
          return a.bookUid.compareTo(b.bookUid) <= 0 ? a : b;
        },
      );
      entries.add(_ContinueEntry(
        kind: MediaKind.video,
        title: first.title,
        recentMs: addedAt,
        badgeLabel: badge,
        collectionName: _collectionNamesById[ce.key],
        collectionId: ce.key,
        video: first,
      ));
    }

    for (final GalgameEntry g in _games) {
      if (shownGames.contains(g.id)) continue;
      entries.add(_ContinueEntry(
        kind: MediaKind.game,
        title: g.displayName,
        recentMs: g.addedAt.millisecondsSinceEpoch,
        badgeLabel: badge,
        game: g,
      ));
    }

    final ModuleVisibility visibility = appModel.moduleVisibility;
    entries.sort(
      (_ContinueEntry a, _ContinueEntry b) => b.recentMs.compareTo(a.recentMs),
    );
    final List<_ContinueEntry> visible = entries
        .where((_ContinueEntry e) => visibility.isEnabled(e.module))
        .take(12)
        .toList();
    if (visible.isEmpty) return null;
    return _sectionCard(
      tokens,
      child: KeyedSubtree(
        key: const ValueKey<String>('home-recent-card'),
        child: _continueCardsRow(
          tokens,
          appModel,
          visible,
          coverHeight: coverHeight,
          rowKey: 'home-recent-row',
          // 「新」挂左上角并缩小：右上角是日文竖排书名的起笔处，会被压住。
          categoryBadge: true,
        ),
      ),
    );
  }

  /// 「继续」封面行：定高横向 ListView，只有封面（2026-10 精简）。
  ///
  /// 整排 2:3 竖卡等高等宽（书 / 视频 / 游戏同一几何），横向滚动。
  Widget _continueCardsRow(
    FushiDesignTokens tokens,
    AppModel appModel,
    List<_ContinueEntry> entries, {
    required double coverHeight,
    required String rowKey,
    bool categoryBadge = false,
  }) {
    // BUG-2002 同款几何：悬停放大是纯绘制变换（以卡中心放大），行视口高度恰等于
    // 卡高时，溢出的上下各 (scale-1)/2 会被 ListView 视口裁成平边。行高留出余量、
    // 卡片自身尺寸不变；不能改用 Clip.none：懒加载 cacheExtent 里已构建的卡会画到
    // 行外。
    final double liftHeadroom = coverHeight * (kFushiHoverLiftScale - 1) / 2;
    final double liftSideRoom =
        coverHeight * _kContinueCoverAspect * (kFushiHoverLiftScale - 1) / 2;
    return SizedBox(
      key: ValueKey<String>(rowKey),
      height: coverHeight + liftHeadroom * 2,
      // 桌面默认 MaterialScrollBehavior 的 dragDevices 不含鼠标——横排行
      // 用鼠标左右拖会毫无反应。共享件统一放开 mouse/trackpad/stylus 拖动
      // （与合集行 CollectionShelfRow 同款）；触屏行为不变。
      child: HorizontalDragScrollable(
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(
            vertical: liftHeadroom,
            horizontal: liftSideRoom,
          ),
          physics: desktopAwareScrollPhysics(),
          itemCount: entries.length,
          separatorBuilder: (BuildContext _, int __) =>
              SizedBox(width: tokens.spacing.gap),
          // 行内卡不再单独错峰：整行已随所在分区一起进场（页级
          // [FushiEntranceScope]），两层叠加的位移在实测里过于花哨。
          itemBuilder: (BuildContext context, int i) => _buildContinueCard(
            tokens,
            appModel,
            entries[i],
            coverHeight: coverHeight,
            categoryBadge: categoryBadge,
          ),
        ),
      ),
    );
  }

  /// 「继续」单卡：[HomeContinueCoverCard]（封面 + 底部进度条 + 右上角进度角标）。
  /// 一行卡片统一 2:3 竖版、等高等宽（书 / 视频 / 游戏同一几何，不再横竖混排）。
  Widget _buildContinueCard(
    FushiDesignTokens tokens,
    AppModel appModel,
    _ContinueEntry entry, {
    required double coverHeight,
    bool categoryBadge = false,
  }) {
    return HomeContinueCoverCard(
      cover: _continueCover(tokens, appModel, entry),
      width: coverHeight * _kContinueCoverAspect,
      height: coverHeight,
      title: _continueDisplayTitle(entry),
      progress: entry.progress,
      badgeLabel: entry.badgeLabel,
      badgeIcon: entry.badgeIcon,
      badgeAtStart: categoryBadge,
      badgeScale: categoryBadge ? 0.85 : 1,
      onTap: () => unawaited(_openContinueEntry(appModel, entry)),
    );
  }

  /// 卡的显示名（读屏标签 / 悬停提示 / 无封面兜底）：合集成员显示合集名（非合集
  /// 上下文拼合集名的老规则），远端条目缀设备名标明来源。
  String _continueDisplayTitle(_ContinueEntry entry) {
    final String title = entry.collectionName ?? entry.title;
    if (entry.remote == null) return title;
    return '$title · ${_remoteDeviceName ?? t.home_remote_source}';
  }

  /// 书 [MediaItem] 的真实媒体种类：standalone SRT 书身份是
  /// `hoshi://srtbook/<uid>`（BUG-1018 A3），其余按 EPUB。两者在「继续/最近添加」
  /// 区块行为一致（[_ContinueEntry.isBook]），但身份不该被抹平成同一个值。
  MediaKind _bookMediaKind(MediaItem item) =>
      ReaderFushiSource.parseSrtBookUid(item.mediaIdentifier) != null
          ? MediaKind.srt
          : MediaKind.epub;

  /// 书 [MediaItem] → 合集归属键：epub 用 uid（v83 成员表键；bookKey 经
  /// [_epubUidByBookKey] 换算，换算不上按 bookKey 回退——与透传成员行同键），
  /// standalone SRT 书身份是 `hoshi://srtbook/<uid>`（BUG-1018 A3）→ 'srt|<uid>'；
  /// 识别不出回退 epub 键（查不中合集，安全降级）。
  String _bookCollectionKey(MediaItem item) {
    final String? bookKey =
        ReaderFushiSource.parseBookKey(item.mediaIdentifier);
    if (bookKey != null) {
      return MediaKind.epub.compositeKey(_epubUidByBookKey[bookKey] ?? bookKey);
    }
    final String? srtUid =
        ReaderFushiSource.parseSrtBookUid(item.mediaIdentifier);
    if (srtUid != null) return MediaKind.srt.compositeKey(srtUid);
    // 有意的 miss-key 兜底：entryKey 是完整 hoshi:// 标识而非 bookKey，
    // 查不中合集，安全降级为散卡。
    return MediaKind.epub.compositeKey(item.mediaIdentifier);
  }

  /// 视频行 → 继续卡条目（散卡与合集续播目标共用），进度见
  /// [dashboardVideoContinueProgress]（反馈「小说有进度显示，视频缺了进度显示」）。
  /// [collectionEpisode] = 合集续播目标在组内是第几集（1 起，单集合集为 null）。
  _ContinueEntry _videoContinueEntry(
    VideoBookRow v, {
    required String? collectionName,
    int? collectionId,
    required int recentMs,
    int? collectionEpisode,
    int collectionEpisodeCount = 0,
  }) {
    final DashboardVideoProgress p = dashboardVideoContinueProgress(
      completed: v.completedAt != null,
      positionMs: v.lastPositionMs,
      durationMs: _videoDurationMsByPath[v.videoPath],
      currentEpisode: v.currentEpisode,
      playlistEpisodeCount: playlistEpisodeCount(v.playlistJson),
      collectionEpisode: collectionEpisode,
      collectionEpisodeCount: collectionEpisodeCount,
    );
    final int? episode = p.episode;
    final int? percent = p.percent;
    final int? positionMs = p.positionMs;
    return _ContinueEntry(
      kind: MediaKind.video,
      title: v.title,
      recentMs: recentMs,
      progress: p.fraction,
      // 角标三选一：多集 →「第 N 集」；单视频知道总时长 →「37%」；都不知道 →
      // 看到的时间点（▶ 12:34）。
      badgeLabel: episode != null
          ? t.home_continue_episode(n: episode)
          : percent != null
              ? '$percent%'
              : (positionMs != null ? formatVideoPosition(positionMs) : null),
      badgeIcon: positionMs != null ? FushiIcons.play : null,
      collectionName: collectionName,
      collectionId: collectionId,
      video: v,
    );
  }

  /// 游戏行 → 继续卡条目（散卡与合集续玩目标共用）：与库页/时间轴同一显示名
  /// 口径（改名/刮削后首页同步）；无完成度概念不画进度条（progress 留 null），
  /// [recentMs] 恒取最近游玩时刻。
  _ContinueEntry _gameContinueEntry(
    GalgameEntry game, {
    required String? collectionName,
  }) {
    return _ContinueEntry(
      kind: MediaKind.game,
      title: game.displayName,
      recentMs: game.lastPlayedMs,
      collectionName: collectionName,
      game: game,
    );
  }

  /// 合集单元的续播目标（**视频页 hero 同口径**，BUG-848
  /// computeVideoLibraryOverview 的单元逻辑）：成员按主合集组内 sortIndex
  /// （缺失沉底）→ bookUid 排序，跑 [continueMemberIndex]（最靠后有痕迹一集；
  /// 它已完成则推进下一集）。整组无痕迹（没看过，不劝人从头开始）或目标仍是
  /// 已完成集（整季看完）→ null 不出卡（自然滚出继续区）。返回续播目标与它在
  /// 组内的序号 / 组大小（「继续」卡的集数角标）。
  ({VideoBookRow row, int index, int count})? _collectionResumeTarget(
    List<VideoBookRow> members,
  ) {
    final List<VideoBookRow> sorted = List<VideoBookRow>.of(members)
      ..sort((VideoBookRow a, VideoBookRow b) {
        final int ai =
            _memberSortIndex[MediaKind.video.compositeKey(a.bookUid)] ??
                1 << 30;
        final int bi =
            _memberSortIndex[MediaKind.video.compositeKey(b.bookUid)] ??
                1 << 30;
        if (ai != bi) return ai.compareTo(bi);
        return a.bookUid.compareTo(b.bookUid);
      });
    final bool anyTrace = sorted.any(
      (VideoBookRow m) => m.completedAt != null || m.lastPositionMs > 0,
    );
    if (!anyTrace) return null;
    final int idx = continueMemberIndex(<CollectionMemberProgress>[
      for (final VideoBookRow m in sorted)
        CollectionMemberProgress(
          positionMs: m.lastPositionMs,
          completed: m.completedAt != null,
          lastPlayedAt: m.lastPlayedAt,
        ),
    ]);
    final VideoBookRow resume = sorted[idx];
    if (resume.completedAt != null) return null;
    return (row: resume, index: idx, count: sorted.length);
  }

  /// 「继续」卡封面本体（远端 / 视频 / 游戏 / 书四路）。封面行不再挂标题文字，
  /// 取不到图的条目一律画「图标 + 条目名」兜底（[_coverPlaceholder]）。
  Widget _continueCover(
    FushiDesignTokens tokens,
    AppModel appModel,
    _ContinueEntry entry,
  ) {
    final String title = _continueDisplayTitle(entry);
    if (entry.remote != null) return _remoteCover(tokens, entry);
    if (entry.isVideo) {
      // 竖卡选图：作品海报（合集主封面）优先；没有竖版海报才用这一集自己的
      // 封面（多是横版截帧），裁进竖卡。
      final String? poster = entry.collectionId == null
          ? null
          : _collectionCoverById[entry.collectionId];
      return _videoCover(
        tokens,
        entry.video!,
        posterPath: poster,
        title: title,
      );
    }
    if (entry.isGame) return _gameCover(tokens, entry.game!, title: title);
    final ImageProvider image =
        ReaderFushiSource.instance.getDisplayThumbnailFromMediaItem(
      appModel: appModel,
      item: entry.book!,
    );
    // 没有封面的书，取图链回的是一张透明占位图（[kTransparentImage]），整卡会是
    // 一块空白——直接画「图标 + 书名」兜底。
    if (image is MemoryImage && identical(image.bytes, kTransparentImage)) {
      return _coverPlaceholder(tokens, FushiIcons.books, title: title);
    }
    return _bookCoverImage(tokens, image, title: title);
  }

  /// 书封面：正常主题 700ms 淡入；eink 下直接出图——淡入是一串灰阶中间帧，
  /// 墨水屏上每帧都是一次局部刷新（残影）。`FadeInImage` 不接受零时长
  /// （TweenSequence 权重断言 > 0），所以不能靠 einkSafeDuration，只能换 widget。
  Widget _bookCoverImage(
    FushiDesignTokens tokens,
    ImageProvider image, {
    required String title,
  }) {
    if (isEinkTheme(context)) {
      return Image(
        image: image,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) =>
            _coverPlaceholder(tokens, FushiIcons.books, title: title),
      );
    }
    return FadeInImage(
      placeholder: MemoryImage(kTransparentImage),
      image: image,
      fit: BoxFit.cover,
      imageErrorBuilder: (_, __, ___) =>
          _coverPlaceholder(tokens, FushiIcons.books, title: title),
    );
  }

  /// 远端条目封面：互联 coverUrl + 取图器可用则 [RemoteCoverImage]（按稳定 id
  /// 磁盘缓存），否则「图标 + 条目名」兜底。
  Widget _remoteCover(FushiDesignTokens tokens, _ContinueEntry entry) {
    final RemoteContinueCandidate remote = entry.remote!;
    final String? coverUrl = remote.coverUrl;
    final RemoteCoverFetcher? fetcher = _remoteCoverFetcher;
    final IconData icon =
        entry.isVideo ? FushiIcons.video : FushiIcons.books;
    final String title = _continueDisplayTitle(entry);
    if (coverUrl == null || coverUrl.isEmpty || fetcher == null) {
      return _coverPlaceholder(tokens, icon, title: title);
    }
    // 远端封面横竖不可知（host 侧可能是截帧也可能是海报）：竖卡，横图裁进去。
    return PortraitCoverImage(
      image: RemoteCoverImage(coverUrl, fetcher, cacheKey: remote.id),
      cropMismatch: true,
      errorBuilder: (BuildContext _) =>
          _coverPlaceholder(tokens, icon, title: title),
    );
  }

  /// 视频封面：来源解析与游戏/剧集列表共用 [resolveMediaCoverImage]。
  /// BUG-1299：封面可能是抽帧（16:9 横）也可能是刮削海报（2:3 竖），渲染交给
  /// [PortraitCoverImage] 做槽向自适应，不再 `BoxFit.cover` 硬裁。
  Widget _videoCover(
    FushiDesignTokens tokens,
    VideoBookRow video, {
    String? posterPath,
    required String title,
  }) {
    return _localCover(
      tokens,
      kind: MediaKind.video,
      path: posterPath ?? video.coverPath,
      title: title,
    );
  }

  /// 游戏封面（BUG-1111 / BUG-1112）：目录扫描 / exe 图标 / 刮削最终都落到
  /// `galgames.coverPath`，显示侧交给统一来源解析器，不在页面重复同步文件探测。
  /// exe 内嵌图标是方图，走 [PortraitCoverImage] 垫底完整显示而非硬裁（BUG-1299）。
  Widget _gameCover(
    FushiDesignTokens tokens,
    GalgameEntry game, {
    required String title,
  }) {
    return _localCover(
      tokens,
      kind: MediaKind.game,
      path: game.coverPath,
      title: title,
    );
  }

  /// 本地视频 / 游戏封面：来源解析共用 [resolveMediaCoverImage]，渲染交给
  /// [PortraitCoverImage]（2:3 竖槽，横图居中裁切）。取不到图 →「图标 + [title]」
  /// 兜底。
  Widget _localCover(
    FushiDesignTokens tokens, {
    required MediaKind kind,
    required String? path,
    required String title,
  }) {
    final ImageProvider? provider = resolveMediaCoverImage(
      kind: kind,
      localPath: path,
      decodeWidth: kLocalCoverDecodePixelWidth,
    );
    if (provider == null) {
      return _coverPlaceholder(
        tokens,
        mediaCoverFallbackIcon(kind),
        title: title,
      );
    }
    // 统一竖卡：竖版海报直接铺满；只有横版截帧时按用户要求裁进竖卡（不走
    // 模糊垫底——首页这一行要整齐的同尺寸海报墙）。
    return PortraitCoverImage(
      image: provider,
      cropMismatch: true,
      errorBuilder: (BuildContext _) => _coverPlaceholder(
        tokens,
        mediaCoverFallbackIcon(kind),
        title: title,
      ),
    );
  }

  /// 封面占位：中性底色 + 图标 + 条目名（eink 下 card 色塌成页面底色，补描边免得
  /// 只剩一枚悬空图标）。「继续」行不再挂标题文字，没有封面的条目只能靠这里的
  /// 名字认出来。
  Widget _coverPlaceholder(
    FushiDesignTokens tokens,
    IconData icon, {
    required String title,
  }) {
    return DecoratedBox(
      key: const ValueKey<String>('home-continue-cover-fallback'),
      decoration: BoxDecoration(
        // Apple：分区卡底与 surfaces.card 同色，占位会整块消失；换中性填充。
        color: isGlassDesign(context)
            ? fushiNeutralBlockColor(context)
            : tokens.surfaces.card,
        border: isEinkTheme(context)
            ? Border.all(color: tokens.surfaces.outline)
            : null,
      ),
      child: Padding(
        padding: EdgeInsets.all(tokens.spacing.gap),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            FushiIcon(icon, color: tokens.type.metadata.color),
            SizedBox(height: tokens.spacing.gap / 2),
            Flexible(
              child: Text(
                title,
                textAlign: TextAlign.center,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: tokens.type.metadata.copyWith(
                  color: tokens.surfaces.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 打开「继续」条目：本地书走 openMedia，本地视频**直接续播**（用户实报点卡
  /// 只跳视频 tab 不打开——旧竖列表残留；改走与视频页 hero 同一条打开路径，合集
  /// 成员带 playlistCollectionId 从合集续播）；远端条目仍切到对应 tab（远端占位
  /// 卡在那里承接播放/下载）。
  Future<void> _openContinueEntry(
    AppModel appModel,
    _ContinueEntry entry,
  ) async {
    // 卡片本身已按 [_ContinueEntry.module] 过滤过（关掉的模块根本没有卡），所以
    // 这里的每条落地路径都在开着的模块内；[_goToTab] 的门只是防御性兜底。
    if (entry.remote != null) {
      _goToTab(entry.isVideo ? HomeTab.video : HomeTab.books);
      return;
    }
    if (entry.isVideo) {
      await _openLocalVideo(entry.video!.bookUid);
      return;
    }
    // BUG-1111：游戏卡点击**切到游戏 tab**，不直接拉起游戏。启动 galgame 要走
    // 位数探测 / helper 确认下载 / 注入会话（`GamesLibraryPage._launchGame`，
    // 数秒且可能弹窗），从首页静默触发是危险的误操作面；库页才是启动入口。
    if (entry.isGame) {
      _goToTab(HomeTab.games);
      return;
    }
    final MediaItem item = entry.book!;
    final MediaSource source = item.getMediaSource(appModel: appModel);
    await appModel.openMedia(ref: ref, mediaSource: source, item: item);
  }

  /// 切到顶层 tab 的**唯一**出口（本页 6 处跨页跳转全走它）：目标 tab 所属模块
  /// 被用户关掉时不切，改给一句可见提示。
  ///
  /// 为什么需要提示而不是「不渲染入口」：首页的活动时间轴与热力图日明细是**历史
  /// 事实流**，行不按模块删（删了等于让用户以为记录丢了），于是「点一条已关模块
  /// 的记录」是真实可达路径。静默不动正是本次要消灭的反模式。
  void _goToTab(HomeTab tab) {
    if (!isHomeTabVisible(tab, ref.read(appProvider).moduleVisibility)) {
      _showModuleHiddenHint();
      return;
    }
    homeShellTabNotifier.value = tab;
  }

  /// 「目标页已被功能模块开关关掉」的可见反馈。
  void _showModuleHiddenHint() {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(FushiSnackBar(content: Text(t.module_disabled_hint)));
  }

  /// 直接续播本地视频：与视频页 hero/卡片同一条共享路由入口 [openLocalVideoBook]
  /// （合集成员带主合集 id → 播放器建剧集面板/上下集/连播；散卡单视频打开）。
  /// 播放页关闭后无需手动刷新——lastPositionMs 落库触发 videoBooks 表级变更，
  /// [_scheduleReload] 自动重查。测试经 [HomeDashboardPage.openVideoOverride] 注入替身。
  Future<void> _openLocalVideo(String bookUid) async {
    final int? playlistCollectionId =
        _primaryCollectionByEntry[MediaKind.video.compositeKey(bookUid)];
    final Future<void> Function(
      BuildContext context,
      VideoBookRepository repo,
      String bookUid,
      int? playlistCollectionId,
    ) open = widget.openVideoOverride ??
        (BuildContext context, VideoBookRepository repo, String bookUid,
                int? playlistCollectionId) =>
            openLocalVideoBook(
              context: context,
              repo: repo,
              bookUid: bookUid,
              playlistCollectionId: playlistCollectionId,
            );
    await open(context, widget.videoRepo, bookUid, playlistCollectionId);
  }

  // ── 学习头部行 / 目标 ────────────────────────────────────────────────────

  /// 学习头部行（[HomeStudyHeader]）：学习域（书 + 视频字幕 + 游戏 hook 文本）
  /// 今日字数 vs 每日字数目标（与阅读统计页目标卡同一持久化
  /// [AppModel.readingGoalDailyChars]、同一分子函数 [studyGoalCharsForDay]，
  /// BUG-1993），右侧今日学习时长（同一份日面行的 ms 合计）。目标为 0 → 旗子环 +
  /// 今日字数 + 「设定目标」按钮；否则进度环 +「X / Y 字」，点整行弹编辑对话框。
  Widget _buildStudyHeader(FushiDesignTokens tokens) {
    final int goal = ref.read(appProvider).readingGoalDailyChars;
    // BUG-2219：与本轮加载的聚合同一个窗口（跨午夜由 [_midnightReload] 重拉）。
    final String todayKey = _statWindow.todayKey;
    final int todayChars = studyGoalCharsForDay(_dailyRows, todayKey);
    int todayMs = 0;
    for (final StatFact f in _dailyRows) {
      if (f.dateKey == todayKey) todayMs += f.ms;
    }
    final bool hasGoal = goal > 0;
    final String todayTime = formatStatTime(todayMs);
    return HomeStudyHeader(
      fraction: hasGoal ? (todayChars / goal).clamp(0.0, 1.0) : null,
      value: hasGoal
          ? t.stat_goal_progress(read: todayChars, goal: goal)
          : formatStatChars(todayChars),
      todayTime: todayTime,
      todayTimeSemanticLabel: '${t.stat_today} · $todayTime',
      onEditGoal: () => unawaited(_editDailyGoal()),
      setGoalLabel: hasGoal ? null : t.stat_goal_set,
    );
  }

  /// 弹目标编辑对话框（2026-10 体验优化：与统计页合并为同一份
  /// [showStatGoalEditDialog]——每日 + 每周 + 预设 + 近 7 日参考）。写回偏好后
  /// setState 刷新目标行（与统计页读同一偏好，多处天然同步）。取消不写。
  Future<void> _editDailyGoal() async {
    // 近 7 日日均吃本页窗口（跨午夜重拉，BUG-2219）。
    final StatWindow w = _statWindow;
    final bool saved = await showStatGoalEditDialog(
      context,
      ref.read(appProvider),
      recentDailyAverage:
          statRecentDailyAverageChars(_dailyRows, w.lastDayKeys(7)),
    );
    if (saved && mounted) setState(() {});
  }

  /// 统计中心入口（唯一入口：各媒体页头的「xx统计」已撤，统一从首页进总览）。
  void _openStatisticsCenter() {
    Navigator.push(
      context,
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => const StatisticsCenterPage(),
      ),
    );
  }

  /// 排行榜入口（统计中心入口旁的独立按钮）。
  void _openLeaderboard() {
    Navigator.push(
      context,
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => const LeaderboardPage(),
      ),
    );
  }

  // ── 区块 4：Activity 时间轴 ──────────────────────────────────────────────

  // ── 区块 5：Bangumi 同步 ─────────────────────────────────────────────────

  /// Bangumi 同步卡：把原本全静默的追踪链路摊成用户可见状态。
  ///
  /// 这条链路每一步失败都不出声——没令牌不建映射、标题匹配不唯一不建映射且 10 分钟
  /// 内不再重试、上报失败只进错误日志并退避最长 6 小时、成功则删 outbox 行不留痕迹。
  /// 于是「看完一部作品」之后没有任何反馈可看。这张卡按链路的三段（连接 → 关联 →
  /// 发送）依次给出当前事实与下一步动作：哪一段断了，卡上就只可能显示那一段的文案。
  Widget _buildTrackingCard(
    FushiDesignTokens tokens,
    AppModel appModel,
    DateTime now,
  ) {
    final MediaTrackingStatus status = _tracking;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    // 第一段：没连令牌 → 后面两段都无从谈起，只给连接入口。
    if (!status.configured) {
      return _sectionCard(
        tokens,
        title: t.media_tracking_card_title,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(t.media_tracking_not_connected, style: tokens.type.metadata),
            SizedBox(height: tokens.spacing.gap),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FushiFilledButton.tonalIcon(
                onPressed: _openTrackingSettings,
                icon: const FushiIcon(FushiIcons.link),
                label: Text(t.media_tracking_connect),
              ),
            ),
          ],
        ),
      );
    }

    final List<String> summary = <String>[
      '${t.media_tracking_last_sync}: '
          '${trackingLastSyncLabel(status, now)}',
      t.media_tracking_linked_count(n: status.mappings.length),
      status.pending > 0
          ? t.media_tracking_pending_count(n: status.pending)
          : t.media_tracking_all_synced,
    ];

    return _sectionCard(
      tokens,
      title: t.media_tracking_card_title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiTooltip(
            message: t.media_tracking_watched_show,
            child: InkWell(
              onTap: () => unawaited(_showBangumiWatched()),
              borderRadius: FushiBorderRadius.card,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  vertical: tokens.spacing.gap / 2,
                ),
                child: Row(
                  children: <Widget>[
                    FushiIcon(
                      FushiIcons.person,
                      size: 18,
                      color: scheme.primary,
                    ),
                    SizedBox(width: tokens.spacing.gap / 2),
                    Expanded(
                      child: Text(
                        status.accountName.isEmpty
                            ? t.media_tracking_account
                            : status.accountName,
                        style: tokens.type.listTitle,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      t.media_tracking_watched_show,
                      style: tokens.type.metadata.copyWith(
                        color: scheme.primary,
                      ),
                    ),
                    SizedBox(width: tokens.spacing.gap / 4),
                    FushiIcon(
                      FushiIcons.chevronRight,
                      size: 18,
                      color: scheme.primary,
                    ),
                  ],
                ),
              ),
            ),
          ),
          SizedBox(height: tokens.spacing.gap / 2),
          Text(summary.join(' · '), style: tokens.type.metadata),

          // 令牌被拒是「已连接」下最容易误判成「没反应」的情形：令牌还在偏好里，
          // isConfigured 仍为 true，但每次同步都在 getMe 就 401 中止。
          if (status.unauthorized) ...<Widget>[
            SizedBox(height: tokens.spacing.gap),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                FushiIcon(FushiIcons.error, size: 18, color: scheme.error),
                SizedBox(width: tokens.spacing.gap / 2),
                Expanded(
                  child: Text(
                    t.media_tracking_unauthorized,
                    style: tokens.type.metadata.copyWith(color: scheme.error),
                  ),
                ),
              ],
            ),
          ],

          SizedBox(height: tokens.spacing.gap),

          // 本地历史与映射是两个独立口径：先明确列出已有进度但仍没关联的条目。
          // 旧文案只在映射表为空时泛泛说“其余需手动关联”，既没写出“哪些”，
          // 又把“零映射”误当成“零历史”。
          if (status.unlinked.isNotEmpty) ...<Widget>[
            Text(
              t.media_tracking_manual_required_count(n: status.unlinked.length),
              style: tokens.type.listTitle.copyWith(color: scheme.error),
            ),
            SizedBox(height: tokens.spacing.gap / 4),
            Text(
              t.media_tracking_manual_required_hint,
              style: tokens.type.metadata,
            ),
            for (final MediaTrackingUnlinkedItem item
                in status.unlinked.take(_kTrackingUnlinkedLimit))
              _buildTrackingUnlinkedRow(tokens, item),
            if (status.unlinked.length > _kTrackingUnlinkedLimit)
              FushiTextButton(
                onPressed: _openTrackingSettings,
                child: Text(
                  t.media_tracking_more_manual_required(
                    n: status.unlinked.length - _kTrackingUnlinkedLimit,
                  ),
                ),
              ),
          ] else if (status.mappings.isEmpty)
            Text(
              t.media_tracking_no_local_history,
              style: tokens.type.metadata,
            ),

          // 已关联条目仍保留作同步诊断；失败原因挂在对应行上并排到最前。
          for (final MediaTrackingMappingRow mapping
              in status.mappingsProblemFirst.take(_kTrackingMappingLimit))
            _buildTrackingMappingRow(
              tokens,
              mapping,
              status.failureByMappingId[mapping.id],
            ),
          for (final String error in status.automaticMappingErrors)
            Text(
              '${t.media_tracking_last_error}: $error',
              style: tokens.type.metadata.copyWith(color: scheme.error),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),

          SizedBox(height: tokens.spacing.gap),
          Wrap(
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap / 2,
            children: <Widget>[
              FushiFilledButton.tonalIcon(
                onPressed: _trackingSyncBusy ? null : _syncTrackingNow,
                icon: _trackingSyncBusy
                    ? const SizedBox.square(
                        dimension: 16,
                        child: FushiCircularProgressIndicator(strokeWidth: 2),
                      )
                    : const FushiIcon(FushiIcons.sync),
                label: Text(t.media_tracking_sync_now),
              ),
              if (status.automaticMappingMissCount > 0)
                FushiFilledButton.tonalIcon(
                  onPressed: _trackingSyncBusy ? null : _retryTrackingMappings,
                  icon: const FushiIcon(FushiIcons.refresh),
                  label: Text(t.media_tracking_retry_mapping),
                ),
              FushiTextButton.icon(
                onPressed: _openTrackingSettings,
                icon: const FushiIcon(FushiIcons.settings),
                label: Text(t.media_tracking_manage_links),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTrackingUnlinkedRow(
    FushiDesignTokens tokens,
    MediaTrackingUnlinkedItem item,
  ) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: _openTrackingSettings,
      borderRadius: FushiBorderRadius.card,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            FushiIcon(FushiIcons.linkOff, size: 18, color: scheme.error),
            SizedBox(width: tokens.spacing.gap / 2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    item.mediaTitle,
                    style: tokens.type.listTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${trackingKindLabel(item.kind.value)} · '
                    '${t.media_tracking_manual_required}',
                    style: tokens.type.metadata.copyWith(color: scheme.error),
                  ),
                ],
              ),
            ),
            SizedBox(width: tokens.spacing.gap / 2),
            const FushiIcon(FushiIcons.chevronRight, size: 18),
          ],
        ),
      ),
    );
  }

  /// 一条已关联条目：本地标题 + 「类别 · Bangumi 条目名 · 进度单位」+（有则）失败
  /// 原因，整行点击在浏览器打开该 Bangumi 条目页。
  ///
  /// 打开 bgm.tv 是「怎么查看这个 bangumi 数据」的落点：远端收藏与进度的真相在
  /// Bangumi，app 内不镜像一份（镜像就得再养一套失效逻辑，且永远可能与远端不符）。
  Widget _buildTrackingMappingRow(
    FushiDesignTokens tokens,
    MediaTrackingMappingRow mapping,
    MediaTrackingFailure? failure,
  ) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => unawaited(_openBangumiSubject(mapping.subjectId)),
      borderRadius: FushiBorderRadius.card,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (failure != null) ...<Widget>[
              FushiIcon(FushiIcons.syncProblem, size: 18, color: scheme.error),
              SizedBox(width: tokens.spacing.gap / 2),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    mapping.mediaTitle,
                    style: tokens.type.listTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    trackingMappingSubtitle(mapping),
                    style: tokens.type.metadata,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  // 退避窗口内也照显：markFailed 最长把重试推到 6 小时后，那段时间
                  // 里发送侧看不到这一行，展示侧不说就等于「零错误」。
                  if (failure != null)
                    Text(
                      '${t.media_tracking_last_error}: ${failure.error}',
                      style: tokens.type.metadata.copyWith(color: scheme.error),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            SizedBox(width: tokens.spacing.gap / 2),
            FushiTooltip(
              message: t.media_tracking_open_subject,
              child: const FushiIcon(FushiIcons.openInNew, size: 16),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openBangumiSubject(int subjectId) async {
    await launchUrl(
      Uri.parse(BangumiApiClient.subjectUrl(subjectId)),
      mode: LaunchMode.externalApplication,
    );
  }

  Future<void> _showBangumiWatched() async {
    await showAppDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => _BangumiWatchedDialog(
        service: ref.read(appProvider).mediaTrackingService,
        onOpenSubject: _openBangumiSubject,
      ),
    );
  }

  void _openTrackingSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            SettingsDetailPage(destination: buildMediaTrackingDestination()),
      ),
    );
  }

  /// 手动同步：结果用 SnackBar 明确回执（成功/失败），再刷新卡片状态。
  /// 服务层的 `statusRevision` 也会触发重载，这里的 await 只为按钮 busy 态收敛。
  Future<void> _syncTrackingNow() async {
    setState(() => _trackingSyncBusy = true);
    try {
      final MediaTrackingSyncResult result =
          await ref.read(appProvider).mediaTrackingService.syncNow(force: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          FushiSnackBar(
            content: Text(result.isSuccess
                ? t.media_tracking_sync_success
                : t.media_tracking_sync_failed),
          ),
        );
    } catch (e, stack) {
      ErrorLogService.instance.log('HomeDashboardPage.syncTracking', e, stack);
    } finally {
      if (mounted) setState(() => _trackingSyncBusy = false);
    }
  }

  /// 自动匹配重试：由服务层清掉对应 miss 退避并重新调用原匹配解析器；结果必须明确
  /// 回显，不能把「按钮被 10 分钟退避挡住」伪装成成功。
  Future<void> _retryTrackingMappings() async {
    setState(() => _trackingSyncBusy = true);
    try {
      final MediaTrackingMappingRetryResult result = await ref
          .read(appProvider)
          .mediaTrackingService
          .retryAutomaticMappings();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          FushiSnackBar(
            content: Text(
              !result.matchedAny
                  ? t.media_tracking_retry_no_match
                  : (result.syncResult?.isSuccess ?? false)
                      ? t.media_tracking_retry_matched
                      : t.media_tracking_sync_failed,
            ),
          ),
        );
    } catch (e, stack) {
      ErrorLogService.instance.log(
        'HomeDashboardPage.retryTrackingMappings',
        e,
        stack,
      );
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            FushiSnackBar(content: Text(t.media_tracking_sync_failed)),
          );
      }
    } finally {
      if (mounted) setState(() => _trackingSyncBusy = false);
    }
  }

  // ── 共享外壳 ────────────────────────────────────────────────────────────

  /// 统一的分区卡：可选标题（+ 可选右侧 header 控件）+ 内容，套 group 底色圆角。
  /// [_sectionCard] 的内边距。
  double _sectionCardInset(FushiDesignTokens tokens) => tokens.spacing.gap + 4;

  Widget _sectionCard(
    FushiDesignTokens tokens, {
    String? title,
    required Widget child,
    Widget? header,
    List<Widget> trailing = const <Widget>[],
  }) {
    // eink：group 面层塌缩成页面底色，分区卡的边界全没了，整页读成一根连续的列；
    // 补 1px 描边（FushiCard 同款）。
    final bool eink = isEinkTheme(context);
    // Apple：内容层是实色——分区卡用 secondarySystemGroupedBackground（不是半透明
    // 的 group 令牌）+ inset grouped 圆角（iOS ≈ 24 / 桌面 12），与 FushiCard 同口径。
    final bool apple = isGlassDesign(context);
    final String? label = title;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: apple
            ? appleColorsOf(context).secondaryGroupedBackground
            : tokens.surfaces.group,
        shape: RoundedRectangleBorder(
          borderRadius: apple
              ? FushiAppleMetrics.of(context).groupBorderRadius
              : FushiBorderRadius.card,
          side: eink
              ? BorderSide(color: tokens.surfaces.outline)
              : BorderSide.none,
        ),
      ),
      child: Padding(
        padding: EdgeInsets.all(_sectionCardInset(tokens)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // 无标题卡（2026-10 精简后的首页主卡）：内容直接顶格，不留标题行。
            if (label != null) ...<Widget>[
              if (trailing.isEmpty)
                Text(label, style: tokens.type.sectionLabel)
              else
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(label, style: tokens.type.sectionLabel),
                    ),
                    for (final Widget w in trailing) ...<Widget>[
                      SizedBox(width: tokens.spacing.gap),
                      w,
                    ],
                  ],
                ),
              if (header != null) ...<Widget>[
                SizedBox(height: tokens.spacing.gap),
                Align(alignment: Alignment.centerLeft, child: header),
              ],
              SizedBox(height: tokens.spacing.gap),
            ],
            child,
          ],
        ),
      ),
    );
  }

}

/// 已迁移只读态的首屏常驻引导（Fushi 迁移 P1-4）：数据已导出，引导用户改用
/// Fushi；保留「重新导出」通道（Fushi 校验缺批时回头重传）。
class _MigrationReadonlyBanner extends StatelessWidget {
  const _MigrationReadonlyBanner({required this.appModel});

  final AppModel appModel;

  static const MigrationTargetChannel _channel = MigrationTargetChannel();

  @override
  Widget build(BuildContext context) {
    return FushiInlineNotice(
      message: t.migration_readonly_note,
      actions: <Widget>[
        FushiFilledButton.tonal(
          onPressed: () => _channel.launchFushi(),
          child: Text(t.migration_open_fushi),
        ),
        FushiTextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => MigrationPage(appModel: appModel),
            ),
          ),
          child: Text(t.migration_reexport),
        ),
      ],
    );
  }
}

/// Fushi 侧迁移引导 banner（P2-2/P2-3）：
/// - 未导入且中转目录有数据 → 「检测到 Hibiki 迁移数据 → 导入」；
/// - 已导入且旧包仍安装 → 「卸载旧版」（ACTION_DELETE 弹系统框，回来复查
///   getPackageInfo——用户可能点了取消，绝不乐观标成功）；
/// - 其余情况渲染为空。
class _FushiMigrationBanner extends StatefulWidget {
  const _FushiMigrationBanner({required this.appModel});

  final AppModel appModel;

  @override
  State<_FushiMigrationBanner> createState() => _FushiMigrationBannerState();
}

class _FushiMigrationBannerState extends State<_FushiMigrationBanner>
    with WidgetsBindingObserver {
  static const MigrationTargetChannel _channel = MigrationTargetChannel();
  static const MigrationImporter _importer = MigrationImporter();

  bool _hasTransferData = false;
  bool _legacyInstalled = false;

  /// 是否持有「所有文件访问权限」。决定 [_legacyInstalled] 能不能当兜底入口用：
  /// 只有**没**权限时「读不到中转数据」才是不可信的答案。
  bool _storageGranted = true;

  bool get _importDone =>
      widget.appModel.prefsRepo.getPref(kMigrationImportDonePrefKey) == true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统卸载确认框回来（resumed）时复查旧包是否真被卸了。
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final Directory dir = await migrationTransferDir();
    // **只做存在性检查**，绝不在这里调 scan()：banner 只需要知道「要不要显示
    // 入口」，而 scan 会把中转目录全量算一遍 SHA-256（11GB 库＝CPU 满载数分钟）。
    // 这个方法在 initState 和每次回前台都跑，用 scan 等于让手机一直在发烫。
    // 归档到底能不能信，由导入页在用户真的要导时去校验。
    final bool hasData = _importer.hasTransferData(dir);
    final bool installed =
        await _channel.isPackageInstalled(kHibikiPackageName);
    final bool granted = await _channel.hasAllFilesAccess();
    if (!mounted) return;
    setState(() {
      _hasTransferData = hasData;
      _legacyInstalled = installed;
      _storageGranted = granted;
    });
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    Widget? inner;
    // 「老包还装着」只能在**没有存储权限时**当兜底入口，不能单独成立。
    //
    // 要兜的死路是：缺「所有文件访问权限」时 existsSync 直接返回 false（不抛
    // 异常，兜不住），入口一藏用户就再也走不到那个能授权的页面 → 无法授权 →
    // 死锁。那种情况下「读不到数据」是个不可信的答案，宁可多显示一次入口。
    //
    // 但**有**权限时它就是可信的：导入成功后中转目录已被整个删掉，此时老包大
    // 概率还没卸（卸载提示正是下面那条分支要做的事），若仍拿它当入口，用户会
    // 在数据早已导完、无事可做的情况下一直被问「检测到迁移数据，现在导入？」。
    if (!_importDone &&
        (_hasTransferData || (_legacyInstalled && !_storageGranted))) {
      inner = FushiInlineNotice(
        message: t.migration_import_detected,
        actions: <Widget>[
          FushiFilledButton.tonal(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => MigrationImportPage(appModel: widget.appModel),
              ),
            ),
            child: Text(t.migration_import_entry),
          ),
        ],
      );
    } else if (_importDone && _legacyInstalled) {
      inner = FushiInlineNotice(
        message: t.migration_uninstall_prompt,
        actions: <Widget>[
          FushiFilledButton.tonal(
            onPressed: () async {
              await _channel.requestUninstall(kHibikiPackageName);
              // resumed 回调会复查；这里再主动刷一次兜底。
              await _refresh();
            },
            child: Text(t.migration_uninstall_button),
          ),
        ],
      );
    }
    if (inner == null) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.spacing.card),
      child: inner,
    );
  }
}
