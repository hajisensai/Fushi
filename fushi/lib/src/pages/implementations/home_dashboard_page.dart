import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:io';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:transparent_image/transparent_image.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:fushi/media.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/media/collections/collection_continue.dart';
import 'package:fushi/src/media/display_title.dart';
import 'package:fushi/src/media/media_cover_source.dart';
import 'package:fushi/src/media/tracking/bangumi_api_client.dart';
import 'package:fushi/src/media/tracking/media_tracking_labels.dart';
import 'package:fushi/src/media/tracking/media_tracking_repository.dart';
import 'package:fushi/src/media/tracking/media_tracking_service.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_repository.dart';
import 'package:fushi/src/media/video/cover_ui/cover_orientation_builder.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi/src/media/video/video_home_layout.dart'
    show VideoCardOrientation;
import 'package:fushi/src/media/video/m3u8_playlist.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/pages/base_module_tab_page.dart';
import 'package:fushi/src/pages/implementations/activity_feed.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart'
    show openLocalVideoBook;
import 'package:fushi/src/pages/implementations/stat_period_detail_sheet.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart';
import 'package:fushi/src/pages/implementations/statistics_center_page.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema_tracking.dart';
import 'package:fushi/src/stats/stat_facts.dart';
import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/remote_cover_image.dart';
import 'package:fushi/src/sync/remote_library_cache.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/components/stat_contribution_heatmap.dart';
import 'package:fushi/src/utils/cover_image.dart';
import 'package:fushi/src/utils/misc/dashboard_remote_merge.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/migration/migration_target_channel.dart';
import 'package:fushi/src/pages/implementations/migration_page.dart';
import 'package:fushi/src/pages/implementations/migration_import_page.dart';
import 'package:fushi/src/migration/migration_importer.dart';

/// 首页仪表盘（阅读向），参考 ReinaManager 首页改造：
///
/// - 区块 1：学习活动热力图（复用 [StatContributionHeatmap]），置顶；带来源筛选
///   （全部/阅读/观看/游戏）、「今日目标」行与点选日明细 sheet。
/// - 区块 2：「继续」——把在读的书与在看的视频合并成横向滑动卡片行（Jellyfin 式：
///   封面 + 底部进度条 + 标题/副标题），分段切换全部/阅读/观看。
/// - 区块 3：Activity 时间轴——把 [ActivityEventRow] 事件流经纯函数
///   [aggregateActivityEvents] 聚合成「按日期分组」的时间线，顶部按类别筛选。
///
/// 分栏（BUG-1073 后）：宽屏（`constraints.maxWidth >= 900`）= 主列（flex 3：学习活动
/// → 继续 → 最近添加）+ 侧列（flex 2：Activity 时间轴），随窗口铺满（旧 1600px
/// 限宽居中已撤——用户实报「首页左右强制的间距」）；窄屏单列堆叠。书与阅读位置走
/// Riverpod provider
/// （响应式）；视频与活动事件在 [initState] 一次性异步载入到本地状态（视频列表天然是
/// Future）。
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
  )?
  openVideoOverride;

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
    this.percent = 0,
    this.progress,
    this.collectionName,
    this.collectionId,
    this.subtitleOverride,
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

  final String title;

  /// 最近活动时刻（epoch 毫秒），仅用于混排排序。
  final int recentMs;

  /// 阅读进度百分比（仅书用，0..100）。
  final int percent;

  /// 封面底部进度条分数（0..1）；null = 无可展示进度不画（单视频无总时长，见
  /// [videoWatchFraction]）。
  final double? progress;

  /// 所属主合集名（显示名规则：非合集上下文标题=合集名、副标题=条目名+状态）；
  /// null = 散卡。本地条目查折叠归属映射，远端条目由 host 直接携带。
  final String? collectionName;

  /// 副标题状态段的覆盖文案（「最近添加」行用「类型 · 相对时间」替代进度状态）；
  /// null = 按 继续区 默认规则（书=「阅读 · x%」/ 视频=「观看」+ 远端设备名）。
  final String? subtitleOverride;
  final MediaItem? book;
  final VideoBookRow? video;

  /// 本地游戏（BUG-1111）。游戏是**本机局域身份**（`galgames.id`），不参与互联
  /// 远端补位——对端没有对应行，拿过来也打不开。
  final GalgameEntry? game;

  /// 互联 host 上的在读书/在看视频（本地无此条目时的远端补位，「继续也走互联」）。
  final RemoteContinueCandidate? remote;
}

/// 每日字数目标编辑对话框。独立 StatefulWidget **自持** controller 生命周期：
/// dispose 跟随路由销毁（弹出动画结束后）。此前「await showDialog 返回即
/// dispose」会在退场动画帧触碰已销毁 controller——保存后本页 setState 让仍在
/// 退场的 TextField 重建 addListener 直接断言崩（widget 测试实测复现）。
/// 保存 pop 解析后的字数（空/非法 → 0 = 关闭目标），取消 pop null。
///
/// BUG-1075：此前只有一个裸 TextField（labelText=每日目标），用户「不知道该填
/// 什么、单位是什么、算不算看视频」。现在补齐三件事（不引入加权系统——那是过度
/// 设计，口径说清即可）：输入框带单位后缀 + 口径 helperText、近 7 日日均参考值、
/// 一排快捷预设 chip。
class _DailyGoalDialog extends StatefulWidget {
  const _DailyGoalDialog({
    required this.initialChars,
    required this.recentDailyAverage,
  });

  /// 当前目标（0 = 未设，输入框留空）。
  final int initialChars;

  /// 近 7 日日均字数（全来源合计，与目标同口径）；<=0 不显示参考行。
  final int recentDailyAverage;

  /// 快捷预设（字/天）：点一下直接填进输入框，省得用户凭空想数字。
  static const List<int> presets = <int>[3000, 5000, 10000, 20000];

  @override
  State<_DailyGoalDialog> createState() => _DailyGoalDialogState();
}

class _DailyGoalDialogState extends State<_DailyGoalDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialChars == 0 ? '' : widget.initialChars.toString(),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 预设 chip → 填入输入框（光标置尾，用户可继续改）。
  void _applyPreset(int chars) {
    final String text = chars.toString();
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return AlertDialog(
      title: Text(t.stat_goal_set),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              controller: _controller,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: t.stat_goal_daily,
                // 单位：目标是「每天多少字」。口径说明行按用户要求删除。
                suffixText: t.stat_goal_unit_chars,
              ),
            ),
            if (widget.recentDailyAverage > 0) ...<Widget>[
              SizedBox(height: tokens.spacing.gap),
              Text(
                t.stat_goal_recent_average(n: widget.recentDailyAverage),
                style: tokens.type.metadata,
              ),
            ],
            SizedBox(height: tokens.spacing.gap + 4),
            Text(t.stat_goal_presets, style: tokens.type.metadata),
            SizedBox(height: tokens.spacing.gap / 2),
            Wrap(
              spacing: tokens.spacing.gap,
              runSpacing: tokens.spacing.gap / 2,
              children: <Widget>[
                for (final int preset in _DailyGoalDialog.presets)
                  ActionChip(
                    label: Text(preset.toString()),
                    onPressed: () => _applyPreset(preset),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(
            context,
          ).pop(int.tryParse(_controller.text.trim()) ?? 0),
          child: Text(t.dialog_save),
        ),
      ],
    );
  }
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
  late final Future<List<BangumiWatchedItem>> _watched = widget.service
      .loadWatchedAnime();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: <Widget>[
          const Icon(Icons.visibility_outlined),
          const SizedBox(width: 12),
          Expanded(child: Text(t.media_tracking_watched_title)),
        ],
      ),
      content: SizedBox(
        width: 640,
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: FutureBuilder<List<BangumiWatchedItem>>(
          future: _watched,
          builder:
              (
                BuildContext context,
                AsyncSnapshot<List<BangumiWatchedItem>> snapshot,
              ) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(
                    child: Text(
                      t.media_tracking_watched_load_failed(
                        error: snapshot.error!,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  );
                }
                final List<BangumiWatchedItem> watched =
                    snapshot.data ?? const <BangumiWatchedItem>[];
                if (watched.isEmpty) {
                  return Center(child: Text(t.media_tracking_watched_empty));
                }
                return ListView.separated(
                  itemCount: watched.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
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
                            ? const Icon(Icons.movie_outlined)
                            : ClipRRect(
                                borderRadius: FushiBorderRadius.chip,
                                child: Image.network(
                                  coverUrl,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) =>
                                      const Icon(Icons.broken_image_outlined),
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
                      trailing: Tooltip(
                        message: t.media_tracking_open_subject,
                        child: const Icon(Icons.open_in_new, size: 18),
                      ),
                      onTap: () =>
                          unawaited(widget.onOpenSubject(item.subject.id)),
                    );
                  },
                );
              },
        ),
      ),
      actions: <Widget>[
        TextButton(
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
  static const int _kActivityPageSize = 24;

  /// 首页主纵向滚动区自己的控制器。走 [FushiScrollController]（全仓唯一那套桌面
  /// 滚轮细化实现），**不再另起一个平行控制器**——两套都拦 pointerScroll，同时在
  /// 场就是两层折扣，而且「粗滚轮阈值 / 倍率 / 要不要动画」会在两处各写一遍。
  final ScrollController _dashboardScrollController = FushiScrollController();

  /// 「继续」横滑行：三类条目统一竖版海报槽（BUG-1299）。视频封面可能是刮削
  /// 落地的 2:3 竖版海报，旧「书竖 5:7 / 视频横 16:9」混排会把海报裁成中间一条；
  /// 现在与视频库主网格同源走 [PortraitCoverImage]——竖图铺满、横版截帧模糊
  /// 垫底，宽度特例随之消灭。行总高 = 封面 + 标题/副标题两行文字块。
  static const double _kContinueCoverHeight = 132;
  static const double _kContinueCoverWidth = 94; // ≈132×5/7 竖版

  /// 「继续」横滑行的总高：封面 + 两行标题 + 一行副标题 + 行间距。
  ///
  /// BUG-1184：原先是死常量 196，配合标题 `maxLines: 1`。书封宽只有 94px，一行
  /// 只显示得到日文书名的五六个字。放宽到两行就必须同步抬高行高，而且这个高度
  /// 本来也该随文字缩放走——旧的 196 在 textScale≥1.5 时连「单行标题 + 副标题」
  /// 都装不下，会直接竖向溢出。
  double _continueRowHeight(BuildContext context, FushiDesignTokens tokens) {
    final double titleLine = textLineHeight(context, tokens.type.listTitle);
    final double metaLine = textLineHeight(context, tokens.type.metadata);
    return _kContinueCoverHeight +
        tokens.spacing.gap / 2 +
        titleLine * 2 +
        tokens.spacing.gap / 4 +
        metaLine +
        kTextBlockSlack;
  }

  /// 「继续」分段筛选：0=全部，1=阅读，2=观看。
  int _continueFilter = 0;

  /// 「学习活动」热力图来源筛选：0=全部，1=阅读，2=观看，3=游戏。
  int _heatmapFilter = 0;

  /// Activity 分类筛选：null=全部，否则 [kActivityRead]/[kActivityWatch]/
  /// [kActivityGame]/[kActivityAdded]（内存里先过滤 events 再聚合）。
  String? _activityFilter;

  /// 活动预取与渲染解耦：数据保留完整，widget 树每次只增加一页。
  int _visibleActivityEntryCount = _kActivityPageSize;

  /// [initState] 异步载入的视频库（继续观看 + 视频计数）。
  List<VideoBookRow> _videos = const <VideoBookRow>[];

  /// v68 附加图组（media_images）按归属分桶：续播区视频横卡的选图链
  /// （合集带字横图 → 无字背景 → 目标集封面）。与视频库同批预取。
  Map<int, List<MediaImageRow>> _mediaImagesByCollection =
      const <int, List<MediaImageRow>>{};
  Map<String, List<MediaImageRow>> _mediaImagesByBookUid =
      const <String, List<MediaImageRow>>{};

  /// [_loadDashboardDataUnsafe] 载入的游戏库整表缓存（P4：日明细「游戏」节 +
  /// 活动时间轴游戏行的显示名反查用；空表 = 库为空或尚未载入）。
  List<GalgameEntry> _games = const <GalgameEntry>[];

  /// [initState] 异步载入的活动事件流（时间轴原始数据，本地 + 远端混排后）。
  List<ActivityEventRow> _activityEvents = const <ActivityEventRow>[];

  /// 本地活动事件（远端到达后与之重混排的基底）。
  List<ActivityEventRow> _localActivityEvents = const <ActivityEventRow>[];

  /// 互联 host 上的「继续」远端补位候选（本地无同 key/uid 的在读书/在看视频）。
  List<RemoteContinueCandidate> _remoteContinue =
      const <RemoteContinueCandidate>[];

  /// 远端封面取图器（互联 client 可用时非空；喂 [RemoteCoverImage]）。
  RemoteCoverFetcher? _remoteCoverFetcher;

  /// 互联 host 设备显示名（配对时存进 [FushiClientUrl.deviceName]；取不到时
  /// 渲染层回退通用「远端」文案）。「标明设备来源」的数据源。
  String? _remoteDeviceName;

  /// 远端活动事件行的 identity 集（这些行 id=0 哨兵且可能与本地行值相等，必须按
  /// 实例识别），供聚合按设备分组 + 打设备标签。
  Set<ActivityEventRow> _remoteActivityRows = Set<ActivityEventRow>.identity();

  /// 上一次远端取数时「显示远端条目」门控的值（对齐视频页 BUG-1182 的
  /// `_remoteGateAtLastLoad`），用于在 prefsRepo 的高频通知里只识别门控翻转。
  bool _remoteGateAtLastLoad = true;

  /// 「显示远端条目」开关落在 prefsRepo（独立 ChangeNotifier），不经 AppModel
  /// 通知、也不在 [_scheduleReload] 的表级信号里——必须显式订阅（[initState] 挂，
  /// [dispose] 解除）才能让翻开关立即生效。
  PreferencesRepository? _prefsRepoForRemoteGate;

  /// 每日字数合计（dateKey → 字数，阅读 + 观看 + 游戏），热力图「全部」档 +
  /// 日明细 sheet 头部合计。今日目标的分子不读这张表——它直接对事实行求和，见
  /// [studyGoalCharsForDay]（BUG-1993：与阅读统计页同一函数、同一学习域口径）。
  Map<String, int> _readingCharsByDay = const <String, int>{};

  /// 每日学习时长合计（dateKey → 毫秒，阅读 + 观看 + 游戏），热力图气泡的第二维度
  /// （用户反馈「点击只显示字数」——字数和时长本就都按日落库，一起外显）。
  Map<String, int> _readingTimeMsByDay = const <String, int>{};

  /// 每日字数/时长按来源拆分（热力图筛选 阅读/观看/游戏 档的数据源）。
  Map<String, int> _readCharsByDay = const <String, int>{};
  Map<String, int> _readTimeMsByDay = const <String, int>{};
  Map<String, int> _watchCharsByDay = const <String, int>{};
  Map<String, int> _watchTimeMsByDay = const <String, int>{};
  Map<String, int> _gameCharsByDay = const <String, int>{};
  Map<String, int> _gameTimeMsByDay = const <String, int>{};

  /// 已加载的统一事实面日行（v92：[StatFacts.daily] 按 mediaKind 分三份；点选日
  /// 明细 sheet 按 dateKey 过滤、今日目标分子按阅读域求和，免重查）。
  List<StatFact> _readingRows = const <StatFact>[];
  List<StatFact> _watchRows = const <StatFact>[];
  List<StatFact> _gameRows = const <StatFact>[];

  /// 完整日面（阅读 + 观看 + 游戏），今日目标 / 近 7 日日均的分子数据源
  /// （BUG-1993：目标口径 = 学习域，与热力图「全部」档同覆盖面；热力图的来源
  /// 筛选档不影响它）。派生 getter，不另存状态。
  Iterable<StatFact> get _dailyRows =>
      _readingRows.followedBy(_watchRows).followedBy(_gameRows);

  /// 合集归属映射（统计页/书架同源，显示名规则「非合集上下文拼合集名」用）：
  /// - [_collectionNamesById]：collectionId → 合集名。
  /// - [_primaryCollectionByEntry]：'<mediaType>|<entryKey>' → 折叠归属主 collectionId。
  /// - [_bookKeyByTitle]：legacy 阅读事实行无身份（mediaKey ''）时经 epub_books
  ///   按 title 反查 bookKey（v92 段自带 mediaKey，优先直用）。
  /// - [_epubUidByBookKey]：v83 起成员表 epub entryKey = `epub_books.uid`，页面
  ///   手里的 bookKey 查归属映射前经此表换算（书架 `_epubUidByKey` 同款口径）。
  Map<int, String> _collectionNamesById = const <int, String>{};
  Map<String, int> _primaryCollectionByEntry = const <String, int>{};
  Map<String, String> _bookKeyByTitle = const <String, String>{};
  Map<String, String> _epubUidByBookKey = const <String, String>{};

  /// epub bookKey → 导入时刻（epoch 毫秒，`EpubBooks.importedAt`），
  /// 「最近添加」行的书侧排序时间源（视频侧用 [VideoBookRow.importedAt]）。
  Map<String, int> _epubImportedAtByKey = const <String, int>{};

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

  /// 库里同名 ≥2 本的 title（BUG-2216：日明细 sheet 身份分组的吸收否决）。
  Set<String> _ambiguousBookTitles = const <String>{};

  @override
  void initState() {
    super.initState();
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
    _trackingRevision =
        ref.read(appProvider).mediaTrackingService.statusRevision
          ..addListener(_scheduleReload);
    // 「显示远端条目」门控翻转（BUG-1182 同款，视频页已修、本页此前漏了）：
    // 翻开 → 立即补拉远端；关掉 → 立即清掉已混排进「继续」/时间轴的远端条目。
    _prefsRepoForRemoteGate = ref.read(appProvider).prefsRepo
      ..addListener(_onPrefsChangedForRemoteGate);
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
  ValueListenable<int>? _trackingRevision;

  /// 游戏库仓储（[initState] 挂监听，[dispose] 解除）。
  GalgameRepository? _galgameRepo;

  /// 表变更后防抖重载（多次连续写只重查一次，避免频繁 setState）。
  void _scheduleReload() {
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      // 「继续」的书侧数据来自缓存 provider（书列表/最近阅读时刻均派生自
      // reader_positions），它们此前只在关书/导入时失效——互联/云同步把更远的
      // 对端进度写回后首页拿不到新值、要重启才生效。表级变更信号（现已含
      // readerPositions）到达时一并失效，让下面的重载 + build 的 ref.watch 读到
      // 新进度。频度由写入端自身的 debounce + 本 400ms 防抖兜住。
      ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
      ref.invalidate(bookLastReadAtProvider);
      unawaited(_loadDashboardData());
    });
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
    final List<VideoBookRow> videos = await widget.videoRepo.listForShelf();
    // v92：学习统计只经统一事实面读取（study_segments + 冻结的 legacy 投影表，
    // 游戏时长来自 galgame_sessions、游戏 hook 字数来自 legacy game 行 + 段），
    // 首页不再自己读六张表各自累加——与阅读/视频/游戏统计页同一份事实。
    final StatFacts facts = await loadStatFacts(db);
    final List<StatFact> reading = facts.dailyBooks.toList(growable: false);
    final List<StatFact> watch = facts.dailyVideos.toList(growable: false);
    final List<StatFact> game = facts.dailyGames.toList(growable: false);
    // 活动流唯一数据源 [StatFacts.activityRows]：legacy activity_events（含仍在写的
    // added 导入事件）∪ v92 段映射行 ∪ galgame_sessions 合成的游玩事件，按时刻倒序
    // 截 200（与旧 getRecentActivityEvents(limit: 200) 对齐）。
    final List<ActivityEventRow> events = facts.activityRows;
    // P4：游戏库整表（日明细/时间轴的游戏显示名反查）。仓储缓存与表恒一致，
    // 未载入过才真查 DB（毫秒级）；load() 会 notify → 本页监听器防抖重载一次
    // 后 isLoaded=true，不再形成回环。
    final GalgameRepository galgameRepo = appModel.galgameRepo;
    final List<GalgameEntry> games = galgameRepo.isLoaded
        ? galgameRepo.games
        : await galgameRepo.load();
    // 合集归属映射（统计页/书架同源）：显示名规则「非合集上下文拼合集名」用。
    final Map<int, String> collectionNamesById = <int, String>{
      for (final MediaCollectionRow c in await db.getAllMediaCollections())
        c.id: c.name,
    };
    final Map<String, int> primaryByEntry = await db
        .getPrimaryCollectionIdByEntry();
    // v68 附加图组：一次全表查询按归属分桶（续播区视频横卡选图链）。
    final Map<int, List<MediaImageRow>> imagesByCollection =
        <int, List<MediaImageRow>>{};
    final Map<String, List<MediaImageRow>> imagesByBookUid =
        <String, List<MediaImageRow>>{};
    for (final MediaImageRow imageRow in await db.getAllMediaImages()) {
      final int? cid = imageRow.collectionId;
      if (cid != null) {
        (imagesByCollection[cid] ??= <MediaImageRow>[]).add(imageRow);
      } else if (imageRow.bookUid case final String uid) {
        (imagesByBookUid[uid] ??= <MediaImageRow>[]).add(imageRow);
      }
    }
    // 组内序：条目在其主折叠合集里的 sortIndex（视频页/书架 _loadShelfMaps 同
    // 口径——一次 getAllCollectionItems 内存分组，只记归属主合集的行）。
    final Map<String, int> memberSortIndex = <String, int>{};
    for (final MediaCollectionItemRow m in await db.getAllCollectionItems()) {
      final String key = '${m.mediaType}|${m.entryKey}';
      if (primaryByEntry[key] == m.collectionId) {
        memberSortIndex[key] = m.sortIndex;
      }
    }
    // legacy 阅读事实行无身份时按 title 反查 bookKey（日明细拼合集前缀，阅读统计
    // 页 _collectionNameForBook 同范式）。书表由事实面加载时顺带取回，同批再取
    // importedAt 喂「最近添加」行（一次查询两用）。
    final List<EpubBookRow> epubRows = facts.epubRows;
    // BUG-2216：同名 ≥2 本的 title 不进反查表（贴给任意一本都是错贴）。
    final Map<String, String> bookKeyByTitle = uniqueBookKeyByTitle(epubRows);
    final Set<String> ambiguousTitles = ambiguousBookTitles(epubRows);
    final Map<String, int> epubImportedAtByKey = <String, int>{
      for (final EpubBookRow r in epubRows) r.bookKey: r.importedAt,
    };
    // v83：成员表 epub entryKey = uid，同批行顺带建 bookKey→uid 换算表（空 uid
    // 异常行不进表，查归属时按 bookKey 原样回退）。
    final Map<String, String> epubUidByBookKey = <String, String>{
      for (final EpubBookRow r in epubRows)
        if (r.uid.isNotEmpty) r.bookKey: r.uid,
    };

    // 每日「读到的字数」按来源拆三份（热力图筛选 全部/阅读/观看/游戏）：书内阅读、
    // 视频字幕字数（看带字幕的视频也是在读字，用户反馈「阅读活动只有书籍，其他的
    // 呢」）、游戏 hook 文本。「全部」= 三者合计。
    // 事实行的 chars / ms 已分列（游戏时长行 chars=0、hook 字数行 ms=0），各自累加
    // 不会双计。
    final Map<String, int> readChars = <String, int>{};
    final Map<String, int> readTimeMs = <String, int>{};
    _accumulateByDay(reading, chars: readChars, timeMs: readTimeMs);
    final Map<String, int> watchChars = <String, int>{};
    final Map<String, int> watchTimeMs = <String, int>{};
    _accumulateByDay(watch, chars: watchChars, timeMs: watchTimeMs);
    final Map<String, int> gameChars = <String, int>{};
    final Map<String, int> gameTimeMs = <String, int>{};
    _accumulateByDay(game, chars: gameChars, timeMs: gameTimeMs);
    final Map<String, int> charsByDay = <String, int>{};
    final Map<String, int> timeMsByDay = <String, int>{};
    for (final Map<String, int> m in <Map<String, int>>[
      readChars,
      watchChars,
      gameChars,
    ]) {
      for (final MapEntry<String, int> e in m.entries) {
        charsByDay[e.key] = (charsByDay[e.key] ?? 0) + e.value;
      }
    }
    for (final Map<String, int> m in <Map<String, int>>[
      readTimeMs,
      watchTimeMs,
      gameTimeMs,
    ]) {
      for (final MapEntry<String, int> e in m.entries) {
        timeMsByDay[e.key] = (timeMsByDay[e.key] ?? 0) + e.value;
      }
    }

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

    // Bangumi 追踪状态（映射 + 待办 + 上次同步结果）。读的是本地库与偏好，不发
    // 网络请求，可以和其它聚合一起进首屏。临时下线期间卡不挂载，状态也不必查。
    final MediaTrackingStatus tracking = kMediaTrackingEnabled
        ? await appModel.mediaTrackingService.loadStatus()
        : MediaTrackingStatus.empty;

    if (!mounted) return;
    setState(() {
      _statWindow = statWindow;
      _ambiguousBookTitles = ambiguousTitles;
      _videos = videos;
      _games = games;
      _tracking = tracking;
      _localActivityEvents = events;
      _activityEvents = events;
      _readingCharsByDay = charsByDay;
      _readingTimeMsByDay = timeMsByDay;
      _readCharsByDay = readChars;
      _readTimeMsByDay = readTimeMs;
      _watchCharsByDay = watchChars;
      _watchTimeMsByDay = watchTimeMs;
      _gameCharsByDay = gameChars;
      _gameTimeMsByDay = gameTimeMs;
      _readingRows = reading;
      _watchRows = watch;
      _gameRows = game;
      _collectionNamesById = collectionNamesById;
      _primaryCollectionByEntry = primaryByEntry;
      _mediaImagesByCollection = imagesByCollection;
      _mediaImagesByBookUid = imagesByBookUid;
      _bookKeyByTitle = bookKeyByTitle;
      _epubUidByBookKey = epubUidByBookKey;
      _epubImportedAtByKey = epubImportedAtByKey;
      _memberSortIndex = memberSortIndex;
      _videoWatchAtByUid = watchAt;
    });
    // 本地渲染先行，互联数据到达后再增量补位（不阻塞首屏）。
    unawaited(_loadRemoteDashboardData());
  }

  /// 把一组事实行按 dateKey 累加进 [chars] / [timeMs] 两张日映射（热力图分档数据源）。
  static void _accumulateByDay(
    List<StatFact> facts, {
    required Map<String, int> chars,
    required Map<String, int> timeMs,
  }) {
    for (final StatFact f in facts) {
      chars[f.dateKey] = (chars[f.dateKey] ?? 0) + f.chars;
      timeMs[f.dateKey] = (timeMs[f.dateKey] ?? 0) + f.ms;
    }
  }

  /// 「继续/活动也走 hibiki 互联」：互联启用且已配对时，从 host 拉取
  /// 书清单（内联阅读进度）/ 视频清单（内联播放断点）/ 最近活动事件，
  /// 把本地没有的在读书、在看视频补进「继续」，活动事件与本地混排进时间轴
  /// （display-only 不落库）。任何失败静默保持纯本地视图（离线/老 host 不致崩）。
  Future<void> _loadRemoteDashboardData() async {
    final AppModel appModel = ref.read(appProvider);
    // 「显示远端条目」门控前移到取数之前（BUG-1182 视频页同款）：此前本页只判
    // 互联开关，关掉开关的用户仍全额付三个远端请求的网络代价、远端条目照混排。
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
      // BUG-1180：首页不在 `_keepAliveTabs` 里，每次切回首页整页重建 → 这三个请求
      // 原本每次都重发；`_scheduleReload` 的 400ms 防抖重载还会再走一遍。改为
      // ① 过共享 TTL 缓存（书/视频清单与书架、视频页同槽，谁先拉到谁受益），
      // ② 三个请求并行而不是串行（原本是三次完整往返首尾相接）。
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
        cache.read<List<RemoteActivityEvent>>(
          sourceId: backend.remoteLibrarySourceId,
          key: RemoteLibraryCacheKeys.activity(200),
          fetch: () => backend.listRemoteActivity(limit: 200),
        ),
      ]);
      final List<RemoteBookInfo> remoteBooks =
          results[0] as List<RemoteBookInfo>;
      final List<RemoteVideoInfo> remoteVideos =
          results[1] as List<RemoteVideoInfo>;
      final List<RemoteActivityEvent> remoteActivity =
          results[2] as List<RemoteActivityEvent>;
      if (!mounted) return;
      final List<MediaItem> books =
          ref.read(fushiBooksProvider(JapaneseLanguage.instance)).valueOrNull ??
          const <MediaItem>[];
      final Set<String> localBookKeys = <String>{
        for (final MediaItem item in books)
          ReaderFushiSource.parseBookKey(item.mediaIdentifier) ??
              item.mediaIdentifier,
      };
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
      final List<ActivityEventRow> remoteRows = remoteActivityAsRows(
        remoteActivity,
      );
      if (!mounted) return;
      setState(() {
        _remoteContinue = continueCandidates;
        _remoteCoverFetcher = remoteCoverFetcherFor(backend);
        _remoteDeviceName = deviceName;
        _remoteActivityRows = Set<ActivityEventRow>.identity()
          ..addAll(remoteRows);
        _activityEvents = mergeActivityEvents(_localActivityEvents, remoteRows);
      });
    } catch (_) {
      // 互联瞬断/超时：保持纯本地视图；下次进入首页自然重试。
    }
  }

  /// 门控关闭时清掉已混排进页面的远端状态（「继续」补位卡 / 时间轴远端行 /
  /// 设备名 / 封面取图器），回到纯本地视图。没有远端状态时不动 UI。
  void _clearRemoteDashboardData() {
    if (!mounted) return;
    final bool hasRemoteState =
        _remoteContinue.isNotEmpty ||
        _remoteActivityRows.isNotEmpty ||
        _remoteDeviceName != null ||
        _remoteCoverFetcher != null;
    if (!hasRemoteState) return;
    setState(() {
      _remoteContinue = const <RemoteContinueCandidate>[];
      _remoteCoverFetcher = null;
      _remoteDeviceName = null;
      _remoteActivityRows = Set<ActivityEventRow>.identity();
      _activityEvents = _localActivityEvents;
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
    final DateTime now = DateTime.now();

    // 活动条封面/点击直达需要「mediaKey → 本地条目」反查映射（渲染层现算，不
    // 落状态；书键兼容 epub bookKey 与 standalone SRT uid 两种身份）。
    final Map<String, MediaItem> booksByKey = <String, MediaItem>{};
    for (final MediaItem item in books) {
      final String? key =
          ReaderFushiSource.parseBookKey(item.mediaIdentifier) ??
          ReaderFushiSource.parseSrtBookUid(item.mediaIdentifier);
      if (key != null) booksByKey[key] = item;
    }
    final Map<String, VideoBookRow> videosByUid = <String, VideoBookRow>{
      for (final VideoBookRow v in _videos) v.bookUid: v,
    };

    final Widget continueCard = _buildContinueSection(
      tokens,
      appModel,
      books,
      lastReadByKey,
      epubUidByKey,
    );
    final Widget heatmapCard = _buildHeatmapCard(tokens);
    final Widget activityCard = _buildActivitySection(
      tokens,
      now,
      appModel,
      booksByKey,
      videosByUid,
    );
    final Widget? recentCard = _buildRecentlyAddedSection(
      tokens,
      appModel,
      books,
      now,
    );
    // Bangumi 同步临时下线（kMediaTrackingEnabled，见 media_tracking_service.dart）。
    // 上线状态下此卡恒显示（未连接时也要显示——「没连上」本身就是用户最需要看到的
    // 那条状态，隐藏它就回到了「看完了没反应」的黑盒）。
    final Widget? trackingCard = kMediaTrackingEnabled
        ? _buildTrackingCard(tokens, appModel, now)
        : null;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide = constraints.maxWidth >= 900;
        final Widget body;
        if (wide) {
          // BUG-1073：宽屏改成「主列 + 侧列」两栏。此前是「热力图通栏 → 继续|活动
          // 两栏 → 最近添加通栏」的三明治：热力图和最近添加各自被拉到 1700px 宽
          // （内容却只有几百 px），继续区一行只 4 张卡右侧全空，活动列又比左列高
          // 出一大截。现在把三个「宽度用不满」的区块（学习活动 / 继续 / 最近添加）
          // 竖着塞进主列，天然长的活动时间轴独占侧列，两列高度也就对齐了。
          //
          // 整页在纵向滚动的 ListView 里，Row 收到的高度约束是无界（h=Infinity）；
          // 用 CrossAxisAlignment.start 让两列各自收敛到内容高度，避免 stretch 被
          // 迫无限高在 layout 阶段崩溃。
          body = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    heatmapCard,
                    SizedBox(height: tokens.spacing.card),
                    continueCard,
                    // 空库不占位（用户反馈「底部很空」的填充提案）。
                    if (recentCard != null) ...<Widget>[
                      SizedBox(height: tokens.spacing.card),
                      recentCard,
                    ],
                  ],
                ),
              ),
              SizedBox(width: tokens.spacing.card),
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (trackingCard != null) ...<Widget>[
                      trackingCard,
                      SizedBox(height: tokens.spacing.card),
                    ],
                    activityCard,
                  ],
                ),
              ),
            ],
          );
        } else {
          body = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              heatmapCard,
              SizedBox(height: tokens.spacing.card),
              continueCard,
              SizedBox(height: tokens.spacing.card),
              if (trackingCard != null) ...<Widget>[
                trackingCard,
                SizedBox(height: tokens.spacing.card),
              ],
              activityCard,
              if (recentCard != null) ...<Widget>[
                SizedBox(height: tokens.spacing.card),
                recentCard,
              ],
            ],
          );
        }
        return ListView(
          controller: _dashboardScrollController,
          padding: EdgeInsets.all(tokens.spacing.card),
          children: <Widget>[
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
      },
    );
  }

  // ── 区块 2：继续（书 + 视频统一列表） ─────────────────────────────────────

  /// 「继续」区块：把在读的书（0<position<duration）与在看的视频
  /// （lastPositionMs>0 且未完成）合并、按最近活动时刻倒序，分段筛选后取前 10 条。
  Widget _buildContinueSection(
    FushiDesignTokens tokens,
    AppModel appModel,
    List<MediaItem> books,
    Map<String, int> lastReadByKey,
    Map<String, String> epubUidByKey,
  ) {
    final List<_ContinueEntry> entries = <_ContinueEntry>[];
    for (final MediaItem item in books) {
      if (item.position > 0 && item.position < item.duration) {
        final String bookKey =
            ReaderFushiSource.parseBookKey(item.mediaIdentifier) ??
            item.mediaIdentifier;
        // v82：位置表键 = uid，bookKey 经换算表转一跳；换算不上（standalone
        // SRT / 书行已删）保持原键查询——与旧行为同样查不到、recent=0。
        final int recent = lastReadByKey[epubUidByKey[bookKey] ?? bookKey] ?? 0;
        final int percent = ((item.position / item.duration) * 100)
            .clamp(0, 100)
            .round();
        entries.add(
          _ContinueEntry(
            kind: _bookMediaKind(item),
            // BUG-1018 (A1)：书名走与书架卡同一 override 通道（编辑对话框改名后
            // 首页「继续」区同步显示新名），不直接读 DB 原名。
            title: ReaderFushiSource.instance.getDisplayTitleFromMediaItem(
              item,
            ),
            recentMs: recent,
            percent: percent,
            progress: percent / 100,
            collectionName: statCollectionName(
              _bookCollectionKey(item),
              _primaryCollectionByEntry,
              _collectionNamesById,
            ),
            book: item,
          ),
        );
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
      final VideoBookRow? resume = _collectionResumeTarget(ce.value);
      if (resume == null) continue;
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
      entries.add(
        _videoContinueEntry(
          resume,
          collectionName: _collectionNamesById[ce.key],
          collectionId: ce.key,
          recentMs: recent,
        ),
      );
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
      entries.add(
        _gameContinueEntry(
          ge.value,
          // 合集名缺失（名字表没这行）→ null，与散卡同渲染，安全降级。
          collectionName: _collectionNamesById[ge.key],
        ),
      );
    }
    // 互联 host 的远端补位（本地无同 key/uid 的在读书/在看视频），与本地条目
    // 按最近活动时刻统一混排（「继续也走互联」）。
    for (final RemoteContinueCandidate c in _remoteContinue) {
      entries.add(
        _ContinueEntry(
          // BUG-1119：此前是 `c.isVideo ? video : epub` 二元降维——远端 SRT 书会被
          // 抹成 epub、第三种媒体装不下（BUG-1111 的漏网消费点）。直读候选种类。
          kind: c.kind,
          title: c.title,
          recentMs: c.recentMs,
          percent: c.percent,
          // 远端书带 host 阅读百分比可画进度条；远端视频无集数/完成信息不画。
          progress: c.isVideo ? null : c.percent / 100,
          collectionName: c.collectionName,
          remote: c,
        ),
      );
    }
    entries.sort(
      (_ContinueEntry a, _ContinueEntry b) => b.recentMs.compareTo(a.recentMs),
    );
    final List<_ContinueEntry> filtered = entries
        .where((_ContinueEntry e) {
          switch (_continueFilter) {
            case 1:
              // BUG-1111：旧实现是 `!e.isVideo`——二元取反，游戏一旦进列表就会被
              // 误算进「阅读」。按种类正面判定。
              return e.isBook;
            case 2:
              return e.isVideo;
            case 3:
              return e.isGame;
            default:
              return true;
          }
        })
        .take(10)
        .toList();

    return _sectionCard(
      tokens,
      title: t.home_continue,
      header: _filterChips<int>(
        tokens: tokens,
        selected: _continueFilter,
        onSelected: (int v) => setState(() => _continueFilter = v),
        options: <(int, String)>[
          (0, t.home_filter_all),
          (1, t.home_filter_read),
          (2, t.home_filter_watch),
          // BUG-1111：与下方热力图筛选同一组档位（复用既有 key，不新增 i18n）。
          (3, t.home_filter_game),
        ],
      ),
      child: filtered.isEmpty
          ? Text(t.home_activity_empty, style: tokens.type.metadata)
          : _continueCardsRow(tokens, appModel, filtered, videoLandscape: true),
    );
  }

  /// 横滑卡片行本体（「继续」与「最近添加」共用）：定高横向 ListView。
  ///
  /// [videoLandscape]：传 true——视频卡朝向随封面自适应（探测到横图走 16:9 横槽，
  /// 只有竖版海报才留竖槽；书/游戏恒竖版，Jellyfin Continue Watching 口径）。
  /// 「继续」与「最近添加」两行同口径（BUG-2005：后者原先恒竖版，16:9 抽帧被塞
  /// 进 94×132 竖槽只能模糊垫底出白条）。行高不变：两种卡封面同高、宽度不同，
  /// 底边天然对齐（video_home_layout 同款几何）。
  Widget _continueCardsRow(
    FushiDesignTokens tokens,
    AppModel appModel,
    List<_ContinueEntry> entries, {
    bool videoLandscape = false,
  }) {
    return SizedBox(
      height: _continueRowHeight(context, tokens),
      // 桌面默认 MaterialScrollBehavior 的 dragDevices 不含鼠标——横排行
      // 用鼠标左右拖会毫无反应。共享件统一放开 mouse/trackpad/stylus 拖动
      // （与合集行 CollectionShelfRow 同款）；触屏行为不变。
      child: HorizontalDragScrollable(
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          physics: desktopAwareScrollPhysics(),
          itemCount: entries.length,
          separatorBuilder: (BuildContext _, int __) =>
              SizedBox(width: tokens.spacing.gap),
          itemBuilder: (BuildContext context, int i) => _buildContinueCard(
            tokens,
            appModel,
            entries[i],
            videoLandscape: videoLandscape,
          ),
        ),
      ),
    );
  }

  /// 区块 4：「最近添加」横滑行（底部通栏，用户反馈「底部很空」的填充提案）：
  /// 本地书（epub importedAt）+ 本地视频（[VideoBookRow.importedAt]）按添加时刻
  /// 倒序混排取前 12，复用继续卡组件（不画进度条，副标题=「类型 · 相对时间」）。
  /// 无可排条目（空库/无时间戳）返回 null 不占位。
  Widget? _buildRecentlyAddedSection(
    FushiDesignTokens tokens,
    AppModel appModel,
    List<MediaItem> books,
    DateTime now,
  ) {
    final List<_ContinueEntry> entries = <_ContinueEntry>[];
    for (final MediaItem item in books) {
      final String? bookKey = ReaderFushiSource.parseBookKey(
        item.mediaIdentifier,
      );
      // standalone SRT 书无 epub 导入时间戳（不在 epub_books），本轮不进最近添加。
      final int addedMs = bookKey == null
          ? 0
          : (_epubImportedAtByKey[bookKey] ?? 0);
      if (addedMs <= 0) continue;
      entries.add(
        _ContinueEntry(
          kind: _bookMediaKind(item),
          // BUG-1018 (A1)：与继续卡同一 override 显示名通道。
          title: ReaderFushiSource.instance.getDisplayTitleFromMediaItem(item),
          recentMs: addedMs,
          collectionName: statCollectionName(
            _bookCollectionKey(item),
            _primaryCollectionByEntry,
            _collectionNamesById,
          ),
          subtitleOverride:
              '${t.home_filter_read} · ${_relativeTimeLabel(addedMs, now)}',
          book: item,
        ),
      );
    }
    for (final VideoBookRow v in _videos) {
      final int addedMs = v.importedAt ?? 0;
      if (addedMs <= 0) continue;
      entries.add(
        _ContinueEntry(
          kind: MediaKind.video,
          title: v.title,
          recentMs: addedMs,
          collectionName: statCollectionName(
            MediaKind.video.compositeKey(v.bookUid),
            _primaryCollectionByEntry,
            _collectionNamesById,
          ),
          subtitleOverride:
              '${t.home_filter_watch} · ${_relativeTimeLabel(addedMs, now)}',
          video: v,
        ),
      );
    }
    // BUG-1111：游戏也进「最近添加」。addedAt 即 `galgames.id` 的微秒时间戳来源
    // （添加时刻），与书的 importedAt / 视频的 importedAt 同量纲，可直接混排。
    for (final GalgameEntry g in _games) {
      final int addedMs = g.addedAt.millisecondsSinceEpoch;
      if (addedMs <= 0) continue;
      entries.add(
        _ContinueEntry(
          kind: MediaKind.game,
          title: g.displayName,
          recentMs: addedMs,
          collectionName: statCollectionName(
            MediaKind.game.compositeKey(g.id),
            _primaryCollectionByEntry,
            _collectionNamesById,
          ),
          subtitleOverride:
              '${t.home_filter_game} · ${_relativeTimeLabel(addedMs, now)}',
          game: g,
        ),
      );
    }
    if (entries.isEmpty) return null;
    entries.sort(
      (_ContinueEntry a, _ContinueEntry b) => b.recentMs.compareTo(a.recentMs),
    );
    final List<_ContinueEntry> top = entries.take(12).toList();
    return _sectionCard(
      tokens,
      title: t.home_recently_added,
      child: _continueCardsRow(tokens, appModel, top, videoLandscape: true),
    );
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
    final String? bookKey = ReaderFushiSource.parseBookKey(
      item.mediaIdentifier,
    );
    if (bookKey != null) {
      return MediaKind.epub.compositeKey(_epubUidByBookKey[bookKey] ?? bookKey);
    }
    final String? srtUid = ReaderFushiSource.parseSrtBookUid(
      item.mediaIdentifier,
    );
    if (srtUid != null) return MediaKind.srt.compositeKey(srtUid);
    // 有意的 miss-key 兜底：entryKey 是完整 hoshi:// 标识而非 bookKey，
    // 查不中合集，安全降级为散卡。
    return MediaKind.epub.compositeKey(item.mediaIdentifier);
  }

  /// 视频行 → 继续卡条目（散卡与合集续播目标共用）：进度到集粒度（VideoBooks
  /// 不持久化总时长，无法算章内百分比——多集按 currentEpisode/集数，单视频未
  /// 看完不画，见 [videoWatchFraction]）；合集成员由渲染层按 [collectionName]
  /// 拼「标题=合集名、副标题=集名 · 观看」。
  _ContinueEntry _videoContinueEntry(
    VideoBookRow v, {
    required String? collectionName,
    int? collectionId,
    required int recentMs,
  }) {
    return _ContinueEntry(
      kind: MediaKind.video,
      title: v.title,
      recentMs: recentMs,
      progress: videoWatchFraction(
        completed: v.completedAt != null,
        currentEpisode: v.currentEpisode,
        episodeCount: playlistEpisodeCount(v.playlistJson),
      ),
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
  /// 已完成集（整季看完）→ null 不出卡（自然滚出继续区）。
  VideoBookRow? _collectionResumeTarget(List<VideoBookRow> members) {
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
    return resume.completedAt != null ? null : resume;
  }

  /// 「继续」单卡（Jellyfin 式横滑卡）：上=封面（底部贴进度条），下=标题一行 +
  /// 灰副标题一行。显示名规则（非合集上下文拼合集名）：合集成员标题=合集名、
  /// 副标题=「条目名 · 状态」；散卡标题=条目名、副标题=状态。状态：书=「阅读 ·
  /// x%」/ 视频=「观看」，远端条目再缀设备名。
  Widget _buildContinueCard(
    FushiDesignTokens tokens,
    AppModel appModel,
    _ContinueEntry entry, {
    bool videoLandscape = false,
  }) {
    // 首页横滑行的视频卡：单行允许横竖混排（用户拍板「继续观看只有一行，混排
    // 不破排版；书架里不可以」）——朝向随**选图链选中的那张图**探测：titleCard /
    // backdrop（天然 16:9）→ 横卡；只有竖版海报 → 自然竖卡，不强制模糊垫底成
    // 16:9。「继续」与「最近添加」两行同口径（BUG-2005）；书 / 游戏恒竖版
    // （BUG-1299 口径不变）。探测与卡内渲染共用同一 provider 键，零额外解码
    // （CoverOrientationBuilder 契约）。
    if (videoLandscape && entry.isVideo) {
      final ImageProvider? probe =
          _continueArtworkProvider(entry) ?? _continueVideoCoverProvider(entry);
      return CoverOrientationBuilder(
        image: probe,
        builder: (BuildContext context, VideoCardOrientation orientation) =>
            _buildContinueCardBody(
              tokens,
              appModel,
              entry,
              landscape: orientation == VideoCardOrientation.landscape,
            ),
      );
    }
    return _buildContinueCardBody(tokens, appModel, entry, landscape: false);
  }

  /// 续播视频卡的朝向探测 provider（与 [_continueCover] 渲染路共用键）：远端走
  /// 互联封面，本地走条目封面；取不到 → null（探测默认竖卡）。
  ImageProvider? _continueVideoCoverProvider(_ContinueEntry entry) {
    final RemoteContinueCandidate? remote = entry.remote;
    if (remote != null) {
      final RemoteCoverFetcher? fetcher = _remoteCoverFetcher;
      final String? url = remote.coverUrl;
      if (url == null || url.isEmpty || fetcher == null) return null;
      return RemoteCoverImage(url, fetcher, cacheKey: remote.id);
    }
    final VideoBookRow? video = entry.video;
    if (video == null) return null;
    return resolveMediaCoverImage(
      kind: MediaKind.video,
      localPath: video.coverPath,
    );
  }

  Widget _buildContinueCardBody(
    FushiDesignTokens tokens,
    AppModel appModel,
    _ContinueEntry entry, {
    required bool landscape,
  }) {
    final double coverWidth = landscape
        ? _kContinueCoverHeight * 16 / 9
        : _kContinueCoverWidth;
    // BUG-1111：游戏没有阅读百分比（无完成度概念），状态段只标类型，不能套用
    // 书的「阅读 · x%」——否则一律显示「阅读 · 0%」。
    String status = switch (entry.kind) {
      MediaKind.video => t.home_filter_watch,
      MediaKind.game => t.home_filter_game,
      MediaKind.epub ||
      MediaKind.srt => '${t.home_filter_read} · ${entry.percent}%',
    };
    if (entry.remote != null) {
      // 标明设备来源：优先 host 设备名（配对时存下），取不到回退通用「远端」。
      status = '$status · ${_remoteDeviceName ?? t.home_remote_source}';
    }
    // 「最近添加」行覆盖状态段（类型 · 相对时间）；继续区恒 null 走上面默认。
    status = entry.subtitleOverride ?? status;
    final String? collectionName = entry.collectionName;
    final String title = collectionName ?? entry.title;
    final String subtitle = collectionName != null
        ? '${entry.title} · $status'
        : status;
    return SizedBox(
      width: coverWidth,
      child: InkWell(
        onTap: () => _openContinueEntry(appModel, entry),
        borderRadius: FushiBorderRadius.card,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ClipRRect(
              borderRadius: FushiBorderRadius.card,
              child: SizedBox(
                width: coverWidth,
                height: _kContinueCoverHeight,
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    _continueCover(
                      tokens,
                      appModel,
                      entry,
                      landscapeSlot: landscape,
                    ),
                    // 进度条贴封面底部（home_video_page 视频卡同款范式）；算不出
                    // 进度（progress==null）时不画。
                    if (entry.progress case final double progress)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: IgnorePointer(
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 3,
                            backgroundColor: Colors.black.withValues(
                              alpha: 0.35,
                            ),
                            color: tokens.surfaces.primary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            SizedBox(height: tokens.spacing.gap / 2),
            Text(
              title,
              // BUG-1184：书封宽只有 94px，单行放不下日文书名（行高已按两行算出，
              // 见 [_continueRowHeight]）。
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: tokens.type.listTitle,
            ),
            SizedBox(height: tokens.spacing.gap / 4),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tokens.type.metadata,
            ),
          ],
        ),
      ),
    );
  }

  /// 「继续」卡封面本体（远端/视频/书三路，与旧列表行同源取图逻辑）。
  Widget _continueCover(
    FushiDesignTokens tokens,
    AppModel appModel,
    _ContinueEntry entry, {
    bool landscapeSlot = false,
  }) {
    if (entry.remote != null) {
      return _remoteCover(tokens, entry, landscapeSlot: landscapeSlot);
    }
    if (entry.isVideo) {
      // v68 横版选图链（Jellyfin preferThumb 口径）：合集/散装的带字横图 →
      // 无字背景 → 目标集封面（剧照天然合槽；竖版海报模糊垫底）。
      final ImageProvider? artwork = landscapeSlot
          ? _continueArtworkProvider(entry)
          : null;
      if (artwork != null) {
        return PortraitCoverImage(
          image: artwork,
          landscapeSlot: true,
          errorBuilder: (BuildContext _) => _coverPlaceholder(
            tokens,
            mediaCoverFallbackIcon(MediaKind.video),
          ),
        );
      }
      return _videoCover(tokens, entry.video!, landscapeSlot: landscapeSlot);
    }
    if (entry.isGame) return _gameCover(tokens, entry.game!);
    return FadeInImage(
      placeholder: MemoryImage(kTransparentImage),
      image: ReaderFushiSource.instance.getDisplayThumbnailFromMediaItem(
        appModel: appModel,
        item: entry.book!,
      ),
      fit: BoxFit.cover,
      imageErrorBuilder: (_, __, ___) =>
          _coverPlaceholder(tokens, Icons.menu_book_outlined),
    );
  }

  /// 远端条目封面：互联 coverUrl + 取图器可用则 [RemoteCoverImage]（按稳定 id
  /// 磁盘缓存），否则占位图标。
  Widget _remoteCover(
    FushiDesignTokens tokens,
    _ContinueEntry entry, {
    bool landscapeSlot = false,
  }) {
    final RemoteContinueCandidate remote = entry.remote!;
    final String? coverUrl = remote.coverUrl;
    final RemoteCoverFetcher? fetcher = _remoteCoverFetcher;
    final IconData icon = entry.isVideo
        ? Icons.movie_outlined
        : Icons.menu_book_outlined;
    if (coverUrl == null || coverUrl.isEmpty || fetcher == null) {
      return _coverPlaceholder(tokens, icon);
    }
    // BUG-1299：远端封面横竖不可知（host 侧可能是截帧也可能是海报），槽向自适应。
    return PortraitCoverImage(
      image: RemoteCoverImage(coverUrl, fetcher, cacheKey: remote.id),
      landscapeSlot: landscapeSlot,
      errorBuilder: (BuildContext _) => _coverPlaceholder(tokens, icon),
    );
  }

  /// v68：续播视频卡的附加图 provider（合集归属查合集图组，散卡查视频图组；
  /// titleCard 优先于 backdrop）。null = 无附加图，回落条目封面。
  ImageProvider? _continueArtworkProvider(_ContinueEntry entry) {
    final List<MediaImageRow>? rows = entry.collectionId != null
        ? _mediaImagesByCollection[entry.collectionId]
        : _mediaImagesByBookUid[entry.video?.bookUid];
    if (rows == null) return null;
    for (final MediaImageKind kind in const <MediaImageKind>[
      MediaImageKind.titleCard,
      MediaImageKind.backdrop,
    ]) {
      for (final MediaImageRow row in rows) {
        if (row.kind == kind.dbValue && row.path.isNotEmpty) {
          return resolveMediaCoverImage(
            kind: MediaKind.video,
            localPath: row.path,
          );
        }
      }
    }
    return null;
  }

  /// 视频封面：来源解析与游戏/剧集列表共用 [resolveMediaCoverImage]。
  /// BUG-1299：封面可能是抽帧（16:9 横）也可能是刮削海报（2:3 竖），渲染交给
  /// [PortraitCoverImage] 做槽向自适应，不再 `BoxFit.cover` 硬裁。
  /// [landscapeSlot] 跟随调用方槽位朝向（继续卡竖版 / 活动条缩略 68×40 横版）。
  Widget _videoCover(
    FushiDesignTokens tokens,
    VideoBookRow video, {
    bool landscapeSlot = false,
    int decodeWidth = kLocalCoverDecodePixelWidth,
  }) {
    return _localCover(
      tokens,
      kind: MediaKind.video,
      path: video.coverPath,
      landscapeSlot: landscapeSlot,
      decodeWidth: decodeWidth,
    );
  }

  /// 游戏封面（BUG-1111 / BUG-1112）：目录扫描 / exe 图标 / 刮削最终都落到
  /// `galgames.coverPath`，显示侧交给统一来源解析器，不在页面重复同步文件探测。
  /// exe 内嵌图标是方图，走 [PortraitCoverImage] 垫底完整显示而非硬裁（BUG-1299）。
  Widget _gameCover(
    FushiDesignTokens tokens,
    GalgameEntry game, {
    bool landscapeSlot = false,
    int decodeWidth = kLocalCoverDecodePixelWidth,
  }) {
    return _localCover(
      tokens,
      kind: MediaKind.game,
      path: game.coverPath,
      landscapeSlot: landscapeSlot,
      decodeWidth: decodeWidth,
    );
  }

  Widget _localCover(
    FushiDesignTokens tokens, {
    required MediaKind kind,
    required String? path,
    bool landscapeSlot = false,
    int decodeWidth = kLocalCoverDecodePixelWidth,
  }) {
    final ImageProvider? provider = resolveMediaCoverImage(
      kind: kind,
      localPath: path,
      decodeWidth: decodeWidth,
    );
    if (provider == null) {
      return _coverPlaceholder(tokens, mediaCoverFallbackIcon(kind));
    }
    return PortraitCoverImage(
      image: provider,
      landscapeSlot: landscapeSlot,
      errorBuilder: (BuildContext _) =>
          _coverPlaceholder(tokens, mediaCoverFallbackIcon(kind)),
    );
  }

  /// 封面占位：中性底色 + 图标。
  Widget _coverPlaceholder(FushiDesignTokens tokens, IconData icon) {
    return DecoratedBox(
      decoration: BoxDecoration(color: tokens.surfaces.card),
      child: Center(child: Icon(icon, color: tokens.type.metadata.color)),
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
    if (entry.remote != null) {
      homeShellTabNotifier.value = entry.isVideo
          ? HomeTab.video
          : HomeTab.books;
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
      homeShellTabNotifier.value = HomeTab.games;
      return;
    }
    final MediaItem item = entry.book!;
    final MediaSource source = item.getMediaSource(appModel: appModel);
    await appModel.openMedia(ref: ref, mediaSource: source, item: item);
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
    )
    open =
        widget.openVideoOverride ??
        (
          BuildContext context,
          VideoBookRepository repo,
          String bookUid,
          int? playlistCollectionId,
        ) => openLocalVideoBook(
          context: context,
          repo: repo,
          bookUid: bookUid,
          playlistCollectionId: playlistCollectionId,
        );
    await open(context, widget.videoRepo, bookUid, playlistCollectionId);
  }

  // ── 区块 3：学习活动热力图 ───────────────────────────────────────────────

  /// 学习活动热力图卡（复用 [StatContributionHeatmap]，按每日字数铺格）：header
  /// 加来源筛选（全部/阅读/观看/游戏），格下加「今日目标」行，点选某日弹当日明细
  /// sheet（用户反馈「点了只有日期和字数，分不清干了什么」三连的解药）。
  Widget _buildHeatmapCard(FushiDesignTokens tokens) {
    final Map<String, int> charsByDay = _heatmapCharsByDay();
    final Map<String, int> timeMsByDay = _heatmapTimeMsByDay();
    final Widget card = _sectionCard(
      tokens,
      title: t.reading_activity,
      // 统计入口的唯一落点（用户定案 2026-09-01：各媒体页头的「xx统计」全部
      // 撤掉，统一从首页热力图卡右上进统计中心总览）。
      header: Row(
        children: <Widget>[
          Expanded(
            child: _filterChips<int>(
              tokens: tokens,
              selected: _heatmapFilter,
              onSelected: (int v) => setState(() => _heatmapFilter = v),
              options: <(int, String)>[
                (0, t.home_filter_all),
                (1, t.home_filter_read),
                (2, t.home_filter_watch),
                (3, t.home_filter_game),
              ],
            ),
          ),
          SizedBox(width: tokens.spacing.gap),
          FushiIconButton(
            tooltip: t.stat_center_title,
            label: t.stat_center_title,
            icon: Icons.bar_chart_outlined,
            onTap: _openStatisticsCenter,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          StatContributionHeatmap(
            valueByDateKey: charsByDay,
            now: DateTime.now(),
            baseColor: tokens.surfaces.primary,
            // BUG-1073 病灶 1 根因：此前用 surfaces.card，与本卡底色
            // surfaces.group 在暗色主题下几乎同色（两个相邻的 surface 容器
            // 色阶）——「没活动的那些周」等于没画，观感是左边一大片死黑。改用
            // 色阶更高的 surfaces.overlay 才和卡底拉开对比，空周照样是
            // GitHub 式浅格子。BUG-1276：黑色/自定义主题仍可能把 surface 色阶
            // 压得过近，因此再用 outlineVariant 描边兜底；即使填充与卡底同色，
            // 53 周空格也不会重新融进背景。
            emptyColor: tokens.surfaces.overlay,
            emptyBorderColor: tokens.surfaces.outline,
            // 气泡 = 日期 · 字数 · 学习时长（时长为 0 的旧数据/纯导入日不显示
            // 时长段），字数与时长都跟随当前来源筛选。
            valueLabel: (String dateKey, int chars) {
              final int timeMs = timeMsByDay[dateKey] ?? 0;
              final String base =
                  '${formatStatHeatmapDay(dateKey)} · ${formatStatChars(chars)}';
              return timeMs > 0 ? '$base · ${formatStatTime(timeMs)}' : base;
            },
            onDaySelected: (String dateKey, int _) =>
                unawaited(_showDayDetailSheet(dateKey)),
          ),
          SizedBox(height: tokens.spacing.gap),
          _buildDailyGoalRow(tokens),
        ],
      ),
    );
    // 热力图是全仪表盘唯一有**天然最大宽度**的区块：网格列数封顶「一年」、格子边长
    // 封顶 maxCell，铺到 [statHeatmapMaxGridWidth]（1110）就到头了。整页 1600 限宽撤
    // 掉后（PR#675），3840 逻辑宽下这张卡被拉到 2244，而网格仍是 1110——右侧空出
    // 1134px，正是 BUG-1073 症状 3 在超宽屏复发。修法不是把整页限宽加回来（用户实报
    // 「首页左右强制的间距」要的就是铺满），而是只给这一块按内容的自然上限封顶，并
    // 左对齐保持与主列其余区块左边缘对齐。1920 及以下主列本就窄于该上限，此处无效果。
    return Align(
      alignment: AlignmentDirectional.centerStart,
      // ListView 给的高度约束无界，heightFactor: 1 让 Align 收敛到内容高度。
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: statHeatmapMaxGridWidth() + 2 * _sectionCardInset(tokens),
        ),
        child: card,
      ),
    );
  }

  /// 当前热力图筛选对应的每日字数映射（0=全部合计，1=阅读，2=观看，3=游戏）。
  Map<String, int> _heatmapCharsByDay() {
    switch (_heatmapFilter) {
      case 1:
        return _readCharsByDay;
      case 2:
        return _watchCharsByDay;
      case 3:
        return _gameCharsByDay;
      default:
        return _readingCharsByDay;
    }
  }

  /// 当前热力图筛选对应的每日时长映射（分档同 [_heatmapCharsByDay]）。
  Map<String, int> _heatmapTimeMsByDay() {
    switch (_heatmapFilter) {
      case 1:
        return _readTimeMsByDay;
      case 2:
        return _watchTimeMsByDay;
      case 3:
        return _gameTimeMsByDay;
      default:
        return _readingTimeMsByDay;
    }
  }

  /// 「今日目标」行：学习域（书 + 视频字幕 + 游戏 hook 文本）今日字数 vs 每日
  /// 字数目标（与阅读统计页目标卡同一持久化 [AppModel.readingGoalDailyChars]、
  /// 同一分子函数 [studyGoalCharsForDay]，不随热力图筛选变）。v92 曾把分子收窄
  /// 成只算阅读域，纯视频/游戏日与上方热力图「全部」档对不上（BUG-1993）。
  /// 目标为 0 → 只留设定入口按钮；否则进度条 + 「X / Y 字」，点击行弹编辑对话框。
  Widget _buildDailyGoalRow(FushiDesignTokens tokens) {
    final int goal = ref.read(appProvider).readingGoalDailyChars;
    if (goal <= 0) {
      // BUG-1073 病灶 2：此前是热力图下方孤零零一个左对齐按钮。改成与已设目标态
      // 同构的一整行（图标 + 标签 + 右侧入口），视觉上属于这张卡。口径说明按用户要求
      // 删除，标签退回「每日目标」本名。
      return Padding(
        padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
        child: Row(
          children: <Widget>[
            Icon(
              Icons.flag_outlined,
              size: 18,
              color: tokens.type.metadata.color,
            ),
            SizedBox(width: tokens.spacing.gap),
            Expanded(
              child: Text(
                t.stat_goal_daily,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: tokens.type.metadata,
              ),
            ),
            SizedBox(width: tokens.spacing.gap),
            TextButton(
              onPressed: () => unawaited(_editDailyGoal()),
              child: Text(t.stat_goal_set),
            ),
          ],
        ),
      );
    }
    // BUG-2219：与本轮加载的聚合同一个窗口（跨午夜由 [_midnightReload] 重拉）。
    final String todayKey = _statWindow.todayKey;
    final int todayChars = studyGoalCharsForDay(_dailyRows, todayKey);
    final double fraction = (todayChars / goal).clamp(0.0, 1.0);
    return InkWell(
      onTap: () => unawaited(_editDailyGoal()),
      borderRadius: FushiBorderRadius.card,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
        child: Row(
          children: <Widget>[
            Text(t.stat_goal, style: tokens.type.metadata),
            SizedBox(width: tokens.spacing.gap),
            Expanded(
              child: ClipRRect(
                borderRadius: tokens.radii.chipRadius,
                child: LinearProgressIndicator(
                  value: fraction,
                  minHeight: 6,
                  backgroundColor: tokens.surfaces.card,
                  color: tokens.surfaces.primary,
                ),
              ),
            ),
            SizedBox(width: tokens.spacing.gap),
            Text(
              t.stat_goal_progress(read: todayChars, goal: goal),
              style: tokens.type.metadata,
            ),
          ],
        ),
      ),
    );
  }

  /// 弹每日字数目标编辑对话框（阅读统计页 _editGoals 的数字输入范式，只编辑每日
  /// 字数；0/清空 = 关闭目标）。写回 [AppModel.setReadingGoalDailyChars] 后
  /// setState 刷新目标行（与统计页读同一偏好，两处天然同步）。取消返回 null 不写。
  Future<void> _editDailyGoal() async {
    final AppModel appModel = ref.read(appProvider);
    final int? saved = await showDialog<int>(
      context: context,
      builder: (BuildContext _) => _DailyGoalDialog(
        initialChars: appModel.readingGoalDailyChars,
        recentDailyAverage: _recentDailyAverageChars(),
      ),
    );
    if (saved == null) return;
    await appModel.setReadingGoalDailyChars(saved < 0 ? 0 : saved);
    if (mounted) setState(() {});
  }

  /// 近 [days] 天（含今天）的日均字数，**与目标同口径**（学习域
  /// [studyGoalCharsForDay]）：给「我该填多少」一个真实参考值（BUG-1075）。
  /// 无数据日按 0 计入分母（真实反映日均，不是活跃日均）。
  int _recentDailyAverageChars({int days = 7}) {
    if (days <= 0) return 0;
    final StatWindow w = _statWindow;
    int total = 0;
    for (final String key in w.lastDayKeys(days)) {
      total += studyGoalCharsForDay(_dailyRows, key);
    }
    return total ~/ days;
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

  /// 点热力图某日 → 时段明细 sheet（阶段 1 统一组件 [showStatPeriodDetailSheet]：
  /// 单日=退化时段，与统计页时段卡同一实现——来源分节 + 合集分组 + 时长倒序 +
  /// 条目跳转）。
  Future<void> _showDayDetailSheet(String dateKey) async {
    final FushiDatabase db = ref.read(appProvider).database;
    final bool deleted = await showStatPeriodDetailSheet(
      context,
      periodLabel: formatStatHeatmapDay(dateKey),
      contains: (String key) => key == dateKey,
      facts: _dailyRows,
      resolvers: StatPeriodDetailResolvers(
        titleOf: _statEntryTitle,
        collectionOf: _statEntryCollection,
        onEntryTap: _openStatEntry,
        onEntryDelete: (StatPeriodEntryTarget t) =>
            deleteStatPeriodEntry(db, t),
        ambiguousTitlesOf: (String kind) => kind == kActivityMediaBook
            ? _ambiguousBookTitles
            : const <String>{},
      ),
    );
    // 删过就重拉首页数据：热力图 / 今日目标 / 时间轴都吃同一份事实面。
    if (deleted && mounted) await _loadDashboardData();
  }

  /// 事实行 → 展示标题（合集名由 sheet 组头承担，这里**不**拼合集前缀）。
  /// 书行过 display-title 门面（改名 override 上屏生效）；游戏行按 galgames.id/
  /// 快照反查库内显示名，已删游戏回落 id；视频/legacy 行原样 title。
  String _statEntryTitle(StatFact f) {
    if (f.isGame) {
      final String name = _gameDisplayTitle(f.title, mediaKey: f.mediaKey);
      return name.isEmpty ? f.mediaKey : name;
    }
    if (f.isBook) {
      final String? bookKey = f.mediaKey.isNotEmpty
          ? f.mediaKey
          : _bookKeyByTitle[f.title];
      if (bookKey == null) return f.title;
      return displayTitleForStatRow(
        rawTitle: f.title,
        bookKeyByTitle: <String, String>{f.title: bookKey},
      );
    }
    return f.title;
  }

  /// 事实行 → 所属合集名（v83 键契约：epub 经 bookKey→uid 换算，video=bookUid，
  /// game=galgames.id）；解析不到返回 null 落「未分组」。
  String? _statEntryCollection(StatFact f) {
    if (f.isBook) {
      final String? bookKey = f.mediaKey.isNotEmpty
          ? f.mediaKey
          : _bookKeyByTitle[f.title];
      if (bookKey == null) return null;
      return statCollectionName(
        MediaKind.epub.compositeKey(_epubUidByBookKey[bookKey] ?? bookKey),
        _primaryCollectionByEntry,
        _collectionNamesById,
      );
    }
    if (f.mediaKey.isEmpty) return null;
    return statCollectionName(
      (f.isVideo ? MediaKind.video : MediaKind.game).compositeKey(f.mediaKey),
      _primaryCollectionByEntry,
      _collectionNamesById,
    );
  }

  /// 明细条目 → 打开对应媒体：视频直达播放、书直达阅读器；游戏与查不到的条目
  /// 切对应 tab（BUG-1111：首页不静默拉起游戏）。判据与 [_openActivityEntry]
  /// 同构，身份来源换成事实行的 mediaKind/mediaKey。
  Future<void> _openStatEntry(String mediaKind, String mediaKey) async {
    final AppModel appModel = ref.read(appProvider);
    if (mediaKey.isNotEmpty) {
      if (mediaKind == kActivityMediaVideo &&
          _videos.any((VideoBookRow v) => v.bookUid == mediaKey)) {
        await _openLocalVideo(mediaKey);
        return;
      }
      if (mediaKind == kActivityMediaBook) {
        final List<MediaItem> books =
            ref
                .read(fushiBooksProvider(JapaneseLanguage.instance))
                .valueOrNull ??
            const <MediaItem>[];
        for (final MediaItem item in books) {
          final String? key =
              ReaderFushiSource.parseBookKey(item.mediaIdentifier) ??
              ReaderFushiSource.parseSrtBookUid(item.mediaIdentifier);
          if (key == mediaKey) {
            final MediaSource source = item.getMediaSource(appModel: appModel);
            await appModel.openMedia(ref: ref, mediaSource: source, item: item);
            return;
          }
        }
      }
    }
    homeShellTabNotifier.value = switch (mediaKind) {
      kActivityMediaBook => HomeTab.books,
      kActivityMediaGame => HomeTab.games,
      _ => HomeTab.video,
    };
  }

  /// 游戏活动标题 → 显示名（P4）：先按 [mediaKey]（galgames.id）精确命中，
  /// 再按「落库时的标题快照 == 库内条目任一已知名」兜底（老事件无 mediaKey），
  /// 最后回落快照原文。查找委托 [displayTitleForGame]。
  String _gameDisplayTitle(String rawTitle, {String? mediaKey}) {
    final GalgameEntry? entry = findGalgameForActivity(
      _games,
      mediaKey: mediaKey,
      title: rawTitle,
    );
    return displayTitleForGame(entry: entry, rawTitle: rawTitle);
  }

  // ── 区块 4：Activity 时间轴 ──────────────────────────────────────────────

  /// Activity 时间轴：顶部分类筛选 → 内存过滤 events → 纯函数聚合 → 按日期分组渲染。
  /// [booksByKey] / [videosByUid] 是「mediaKey → 本地条目」反查映射（封面缩略 +
  /// 点击直达用；查不到回退图标/切 tab）。
  Widget _buildActivitySection(
    FushiDesignTokens tokens,
    DateTime now,
    AppModel appModel,
    Map<String, MediaItem> booksByKey,
    Map<String, VideoBookRow> videosByUid,
  ) {
    final List<ActivityEventRow> filtered = _activityFilter == null
        ? _activityEvents
        : _activityEvents
              .where((ActivityEventRow e) => e.eventType == _activityFilter)
              .toList();
    // 设备来源进聚合：互联对端事件带 host 设备名（identity 识别——远端行 id=0
    // 哨兵且可能与本地行值相等），与本机事件分条展示（「标明设备来源」）。
    final List<ActivityDateGroup> groups = aggregateActivityEvents(
      filtered,
      sourceDeviceOf: (ActivityEventRow e) => _remoteActivityRows.contains(e)
          ? (_remoteDeviceName ?? t.home_remote_source)
          : null,
    );
    final String todayKey = FushiTimeFormat.dayKey(now);
    final String yesterdayKey = FushiTimeFormat.dayKey(
      now.subtract(const Duration(days: 1)),
    );

    return _sectionCard(
      tokens,
      title: t.home_activity,
      header: _filterChips<String?>(
        tokens: tokens,
        selected: _activityFilter,
        onSelected: (String? v) => setState(() {
          _activityFilter = v;
          _visibleActivityEntryCount = _kActivityPageSize;
        }),
        options: <(String?, String)>[
          (null, t.home_filter_all),
          (kActivityRead, t.home_filter_read),
          (kActivityWatch, t.home_filter_watch),
          (kActivityGame, t.home_filter_game),
          (kActivityAdded, t.home_filter_added),
        ],
      ),
      child: groups.isEmpty
          ? Text(t.home_activity_empty, style: tokens.type.metadata)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final ActivityDateGroup g in takeActivityEntries(
                  groups,
                  _visibleActivityEntryCount,
                ))
                  _buildActivityGroup(
                    tokens,
                    g,
                    todayKey,
                    yesterdayKey,
                    now,
                    appModel,
                    booksByKey,
                    videosByUid,
                  ),
                if (groups.fold<int>(
                      0,
                      (int total, ActivityDateGroup group) =>
                          total + group.entries.length,
                    ) >
                    _visibleActivityEntryCount)
                  Align(
                    alignment: AlignmentDirectional.center,
                    child: TextButton.icon(
                      onPressed: () => setState(() {
                        _visibleActivityEntryCount += _kActivityPageSize;
                      }),
                      icon: const Icon(Icons.expand_more),
                      label: Text(t.discovery_load_more),
                    ),
                  ),
              ],
            ),
    );
  }

  /// 单个日期分组：日期头 + 该日的条目。
  Widget _buildActivityGroup(
    FushiDesignTokens tokens,
    ActivityDateGroup group,
    String todayKey,
    String yesterdayKey,
    DateTime now,
    AppModel appModel,
    Map<String, MediaItem> booksByKey,
    Map<String, VideoBookRow> videosByUid,
  ) {
    final String label;
    if (group.dateKey == todayKey) {
      label = t.home_today;
    } else if (group.dateKey == yesterdayKey) {
      label = t.home_yesterday;
    } else {
      label = formatStatHeatmapDay(group.dateKey);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.only(
            top: tokens.spacing.gap,
            bottom: tokens.spacing.gap / 2,
          ),
          child: Text(label, style: tokens.type.sectionLabel),
        ),
        for (final ActivityEntry e in group.entries)
          _buildActivityEntry(
            tokens,
            e,
            now,
            appModel,
            booksByKey,
            videosByUid,
          ),
      ],
    );
  }

  /// 单条活动：前置封面缩略（命中本地条目；否则类型图标）+ 标题（粗）+ 副行
  /// （动作词 · 相对时间 · [时长] · [session 数]）。整行可点：命中本地条目直接
  /// 打开（视频续播/书 openMedia），查不到回退切 tab。
  Widget _buildActivityEntry(
    FushiDesignTokens tokens,
    ActivityEntry entry,
    DateTime now,
    AppModel appModel,
    Map<String, MediaItem> booksByKey,
    Map<String, VideoBookRow> videosByUid,
  ) {
    final List<String> parts = <String>[
      _actionWord(entry.eventType),
      _relativeTimeLabel(entry.latestTimestampMs, now),
      if (entry.totalDurationMs > 0) formatStatTime(entry.totalDurationMs),
      if (entry.sessionCount > 1) t.home_session_count(n: entry.sessionCount),
      // 设备来源（互联对端事件带 host 设备名；本机事件不标）。
      if (entry.sourceDevice case final String device) device,
    ];
    return InkWell(
      onTap: () => unawaited(
        _openActivityEntry(appModel, entry, booksByKey, videosByUid),
      ),
      borderRadius: FushiBorderRadius.card,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _activityLeading(tokens, appModel, entry, booksByKey, videosByUid),
            SizedBox(width: tokens.spacing.gap + 4),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    _activityDisplayTitle(entry),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.type.listTitle,
                  ),
                  SizedBox(height: tokens.spacing.gap / 2),
                  Text(
                    parts.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.type.metadata,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// BUG-1018 (A1)：活动条**渲染时**应用书的 override 书名（编辑对话框改名后时间轴
  /// 同步显示新名）。events 落库仍存 DB 原名（历史数据身份，聚合键不变），只在这里
  /// 按 [ActivityEntry.mediaKey]（书=bookKey / 视频=bookUid）查 override 替换显示。
  /// 命中合集时再拼「合集名 - 名字」（显示名规则：非合集上下文拼合集名；override
  /// 后的名字再拼前缀）。
  String _activityDisplayTitle(ActivityEntry entry) {
    if (entry.mediaType == kActivityMediaBook) {
      final String? bookKey = entry.mediaKey;
      if (bookKey != null && bookKey.isNotEmpty) {
        final String title =
            ReaderFushiSource.instance.overrideTitleForBookKey(bookKey) ??
            entry.title;
        // 书事件的 mediaKey 无类型标记：按 core 跨域映射表
        // [shelfKindsOfActivityMedia] 的既定顺序（epub 键优先，standalone SRT
        // （mediaKey=uid）回退 srt 键）逐一试探；都不中就是散卡。
        // v83：epub 试探键 = uid（mediaKey 的 bookKey 经换算表转一跳；srt 试探
        // 键本就是 uid 值域，原样）。
        String? collectionName;
        for (final MediaKind shelfKind in shelfKindsOfActivityMedia(
          ActivityMediaKind.book,
        )) {
          final String entryKey = shelfKind == MediaKind.epub
              ? (_epubUidByBookKey[bookKey] ?? bookKey)
              : bookKey;
          collectionName = statCollectionName(
            shelfKind.compositeKey(entryKey),
            _primaryCollectionByEntry,
            _collectionNamesById,
          );
          if (collectionName != null) break;
        }
        return collectionName == null ? title : '$collectionName - $title';
      }
      return entry.title;
    }
    if (entry.mediaType == kActivityMediaVideo) {
      final String? uid = entry.mediaKey;
      if (uid != null && uid.isNotEmpty) {
        return collectionQualifiedTitle(
          entryKey: MediaKind.video.compositeKey(uid),
          rawTitle: entry.title,
          primaryByEntry: _primaryCollectionByEntry,
          collectionNamesById: _collectionNamesById,
        );
      }
    }
    // P4：游戏行渲染时应用库内显示名（改名/刮削后时间轴同步显示新名）。events
    // 落库仍存当时标题快照（聚合键身份不变），只在这里按 mediaKey（galgames.id）
    // / 标题快照反查替换显示。
    if (entry.mediaType == kActivityMediaGame) {
      return _gameDisplayTitle(entry.title, mediaKey: entry.mediaKey);
    }
    return entry.title;
  }

  /// 活动条前置视觉：命中本地条目用封面缩略（书与游戏 40×56 竖版 / 视频 68×40
  /// 横版，圆角裁切，与继续卡同源取图），查不到（已删/远端 display-only 行/导入
  /// 无封面）回退原类型图标（用户反馈时间轴只有小图标认不出条目）。
  Widget _activityLeading(
    FushiDesignTokens tokens,
    AppModel appModel,
    ActivityEntry entry,
    Map<String, MediaItem> booksByKey,
    Map<String, VideoBookRow> videosByUid,
  ) {
    final String? key = entry.mediaKey;
    if (entry.mediaType == kActivityMediaGame) {
      // 新事件用 galgames.id；旧启动事件曾写 exePath，attach 事件还可能只有标题。
      // 统一反查器兼容三者，封面和显示名因此命中同一个 GalgameEntry。
      final GalgameEntry? game = findGalgameForActivity(
        _games,
        mediaKey: key,
        title: entry.title,
      );
      if (game != null) {
        return ClipRRect(
          borderRadius: FushiBorderRadius.card,
          child: SizedBox(
            width: 40,
            height: 56,
            child: _gameCover(
              tokens,
              game,
              decodeWidth: kActivityCoverDecodePixelWidth,
            ),
          ),
        );
      }
    } else if (key != null && key.isNotEmpty) {
      if (entry.mediaType == kActivityMediaVideo) {
        final VideoBookRow? video = videosByUid[key];
        if (video != null) {
          return ClipRRect(
            borderRadius: FushiBorderRadius.card,
            child: SizedBox(
              width: 68,
              height: 40,
              // BUG-1299：横版槽，判定方向随槽走（海报垫底、截帧铺满）。
              child: _videoCover(
                tokens,
                video,
                landscapeSlot: true,
                decodeWidth: kActivityCoverDecodePixelWidth,
              ),
            ),
          );
        }
      } else if (entry.mediaType == kActivityMediaBook) {
        final MediaItem? book = booksByKey[key];
        if (book != null) {
          return ClipRRect(
            borderRadius: FushiBorderRadius.card,
            child: SizedBox(
              width: 40,
              height: 56,
              child: FadeInImage(
                placeholder: MemoryImage(kTransparentImage),
                image: resolveMediaCoverImage(
                  kind: _bookMediaKind(book),
                  book: book,
                  appModel: appModel,
                  decodeWidth: kActivityCoverDecodePixelWidth,
                )!,
                fit: BoxFit.cover,
                imageErrorBuilder: (_, __, ___) =>
                    _coverPlaceholder(tokens, Icons.menu_book_outlined),
              ),
            ),
          );
        }
      }
    }
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Icon(
        _activityIcon(entry.eventType),
        size: 20,
        color: tokens.surfaces.primary,
      ),
    );
  }

  /// 点击活动条：命中本地条目**直接打开**——视频=续播（与继续卡同一条
  /// [_openLocalVideo] 路径），书=openMedia；打不开的按**媒体种类**切到对应 tab：
  /// read/book → 书架、game → 游戏、其余 → 视频。
  ///
  /// BUG-1112：游戏条以前没有自己的分支，直接掉进最后的 else → 点一条游戏
  /// 活动会跳到**视频 tab**（与同一页「继续」区游戏卡的行为矛盾）。同口径切到
  /// 游戏 tab：不在首页静默拉起游戏（启动要走位数探测/helper/注入会话）。
  /// 判据只看事件身份，不要求库里还有这行——游戏删了，去游戏 tab 也比去视频 tab 对。
  Future<void> _openActivityEntry(
    AppModel appModel,
    ActivityEntry entry,
    Map<String, MediaItem> booksByKey,
    Map<String, VideoBookRow> videosByUid,
  ) async {
    final String? key = entry.mediaKey;
    if (key != null && key.isNotEmpty) {
      if (entry.mediaType == kActivityMediaVideo &&
          videosByUid.containsKey(key)) {
        await _openLocalVideo(key);
        return;
      }
      if (entry.mediaType == kActivityMediaBook) {
        final MediaItem? book = booksByKey[key];
        if (book != null) {
          final MediaSource source = book.getMediaSource(appModel: appModel);
          await appModel.openMedia(ref: ref, mediaSource: source, item: book);
          return;
        }
      }
    }
    if (entry.eventType == kActivityRead ||
        entry.mediaType == kActivityMediaBook) {
      homeShellTabNotifier.value = HomeTab.books;
    } else if (entry.eventType == kActivityGame ||
        entry.mediaType == kActivityMediaGame) {
      homeShellTabNotifier.value = HomeTab.games;
    } else {
      homeShellTabNotifier.value = HomeTab.video;
    }
  }

  /// 事件类型 → 动作词（i18n）。
  String _actionWord(String eventType) {
    switch (eventType) {
      case kActivityRead:
        return t.home_filter_read;
      case kActivityWatch:
        return t.home_filter_watch;
      case kActivityAdded:
        return t.home_filter_added;
      case kActivityGame:
        return t.home_filter_game;
      default:
        return t.home_filter_all;
    }
  }

  /// 事件类型 → 前置图标。
  IconData _activityIcon(String eventType) {
    switch (eventType) {
      case kActivityRead:
        return Icons.menu_book;
      case kActivityWatch:
        return Icons.movie;
      case kActivityAdded:
        return Icons.add_circle_outline;
      case kActivityGame:
        return Icons.videogame_asset;
      default:
        return Icons.menu_book;
    }
  }

  /// 相对时间结构化结果 → i18n 文案（口径与 Bangumi 同步卡共用，见
  /// [formatActivityRelativeTime]）。
  String _relativeTimeLabel(int timestampMs, DateTime now) =>
      formatActivityRelativeTime(timestampMs, now);

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
              child: FilledButton.tonalIcon(
                onPressed: _openTrackingSettings,
                icon: const Icon(Icons.link),
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
          Tooltip(
            message: t.media_tracking_watched_show,
            child: InkWell(
              onTap: () => unawaited(_showBangumiWatched()),
              borderRadius: FushiBorderRadius.card,
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.person_outline, size: 18, color: scheme.primary),
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
                    Icon(Icons.chevron_right, size: 18, color: scheme.primary),
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
                Icon(Icons.error_outline, size: 18, color: scheme.error),
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
            for (final MediaTrackingUnlinkedItem item in status.unlinked.take(
              _kTrackingUnlinkedLimit,
            ))
              _buildTrackingUnlinkedRow(tokens, item),
            if (status.unlinked.length > _kTrackingUnlinkedLimit)
              TextButton(
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
              FilledButton.tonalIcon(
                onPressed: _trackingSyncBusy ? null : _syncTrackingNow,
                icon: _trackingSyncBusy
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync),
                label: Text(t.media_tracking_sync_now),
              ),
              if (status.automaticMappingMissCount > 0)
                FilledButton.tonalIcon(
                  onPressed: _trackingSyncBusy ? null : _retryTrackingMappings,
                  icon: const Icon(Icons.refresh),
                  label: Text(t.media_tracking_retry_mapping),
                ),
              TextButton.icon(
                onPressed: _openTrackingSettings,
                icon: const Icon(Icons.tune),
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
            Icon(Icons.link_off, size: 18, color: scheme.error),
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
            const Icon(Icons.chevron_right, size: 18),
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
              Icon(Icons.sync_problem_outlined, size: 18, color: scheme.error),
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
            Tooltip(
              message: t.media_tracking_open_subject,
              child: const Icon(Icons.open_in_new, size: 16),
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
    await showDialog<void>(
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
      final MediaTrackingSyncResult result = await ref
          .read(appProvider)
          .mediaTrackingService
          .syncNow(force: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              result.isSuccess
                  ? t.media_tracking_sync_success
                  : t.media_tracking_sync_failed,
            ),
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
          SnackBar(
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
          ..showSnackBar(SnackBar(content: Text(t.media_tracking_sync_failed)));
      }
    } finally {
      if (mounted) setState(() => _trackingSyncBusy = false);
    }
  }

  // ── 共享外壳 ────────────────────────────────────────────────────────────

  /// 统一的分区卡：标题（+ 可选右侧 header 控件）+ 内容，套 group 底色圆角。
  /// [_sectionCard] 的内边距。单独抽出来是因为 [_buildHeatmapCard] 要按「网格自然
  /// 最大宽度 + 两侧内边距」给卡片限宽，两处必须用同一个值。
  double _sectionCardInset(FushiDesignTokens tokens) => tokens.spacing.gap + 4;

  Widget _sectionCard(
    FushiDesignTokens tokens, {
    required String title,
    required Widget child,
    Widget? header,
  }) {
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: tokens.surfaces.group,
        shape: const RoundedRectangleBorder(
          borderRadius: FushiBorderRadius.card,
        ),
      ),
      child: Padding(
        padding: EdgeInsets.all(_sectionCardInset(tokens)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(title, style: tokens.type.sectionLabel),
            if (header != null) ...<Widget>[
              SizedBox(height: tokens.spacing.gap),
              Align(alignment: Alignment.centerLeft, child: header),
            ],
            SizedBox(height: tokens.spacing.gap),
            child,
          ],
        ),
      ),
    );
  }

  /// 泛型筛选 chip 行：[ChoiceChip] 的 [Wrap]（窄屏自动换行，不溢出）。
  Widget _filterChips<T>({
    required FushiDesignTokens tokens,
    required T selected,
    required ValueChanged<T> onSelected,
    required List<(T value, String label)> options,
  }) {
    return Wrap(
      spacing: tokens.spacing.gap,
      runSpacing: tokens.spacing.gap / 2,
      children: <Widget>[
        for (final (T value, String label) in options)
          ChoiceChip(
            label: Text(label),
            selected: selected == value,
            onSelected: (bool isSelected) {
              if (isSelected) onSelected(value);
            },
          ),
      ],
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
    return FushiCard(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(t.migration_readonly_note),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                FilledButton.tonal(
                  onPressed: () => _channel.launchFushi(),
                  child: Text(t.migration_open_fushi),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => MigrationPage(appModel: appModel),
                    ),
                  ),
                  child: Text(t.migration_reexport),
                ),
              ],
            ),
          ],
        ),
      ),
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
    final bool installed = await _channel.isPackageInstalled(
      kHibikiPackageName,
    );
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
      inner = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(t.migration_import_detected),
          const SizedBox(height: 8),
          FilledButton.tonal(
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
      inner = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(t.migration_uninstall_prompt),
          const SizedBox(height: 8),
          FilledButton.tonal(
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
      child: FushiCard(
        child: Padding(padding: const EdgeInsets.all(12), child: inner),
      ),
    );
  }
}
