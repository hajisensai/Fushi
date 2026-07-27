import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:transparent_image/transparent_image.dart';

import 'package:hibiki/media.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/media/collections/collection_continue.dart';
import 'package:hibiki/src/media/display_title.dart';
import 'package:hibiki/src/mining/galgame_library.dart';
import 'package:hibiki/src/mining/galgame_repository.dart';
import 'package:hibiki/src/media/video/m3u8_playlist.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/pages/base_module_tab_page.dart';
import 'package:hibiki/src/pages/implementations/activity_feed.dart';
import 'package:hibiki/src/pages/implementations/home_page.dart';
import 'package:hibiki/src/pages/implementations/home_video_page.dart'
    show openLocalVideoBook;
import 'package:hibiki/src/pages/implementations/stat_shared.dart';
import 'package:hibiki/src/sync/interconnect_sync_backend.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/remote_cover_image.dart';
import 'package:hibiki/src/sync/remote_library_cache.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/utils/components/stat_contribution_heatmap.dart';
import 'package:hibiki/src/utils/misc/dashboard_remote_merge.dart';
import 'package:hibiki_core/hibiki_core.dart';

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
/// → 继续 → 最近添加）+ 侧列（flex 2：Activity 时间轴），整体限宽
/// [_kDashboardMaxWidth] 居中；窄屏单列堆叠。书与阅读位置走 Riverpod provider
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
    this.percent = 0,
    this.progress,
    this.collectionName,
    this.subtitleOverride,
    this.book,
    this.video,
    this.game,
    this.remote,
  });

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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
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
                // 单位 + 口径：目标是「每天多少字」，且计入阅读/视频字幕/游戏文本。
                suffixText: t.stat_goal_unit_chars,
                helperText: t.stat_goal_scope_hint,
                helperMaxLines: 3,
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
          onPressed: () => Navigator.of(context)
              .pop(int.tryParse(_controller.text.trim()) ?? 0),
          child: Text(t.dialog_save),
        ),
      ],
    );
  }
}

/// 仪表盘内容最大宽度（逻辑像素）：超宽屏限宽居中，避免每个区块被拉成大片空白。
const double _kDashboardMaxWidth = 1600;

class _HomeDashboardPageState
    extends BaseModuleTabPageState<HomeDashboardPage> {
  /// 「继续」横滑行：卡片封面等高，书竖版 5:7 / 视频横版 16:9 由宽度区分（同一行
  /// 混排不同宽度，Jellyfin 式）。行总高 = 封面 + 标题/副标题两行文字块。
  static const double _kContinueCoverHeight = 132;
  static const double _kContinueBookCoverWidth = 94; // ≈132×5/7 竖版
  static const double _kContinueVideoCoverWidth = 234; // ≈132×16/9 横版

  /// 「继续」横滑行的总高：封面 + 两行标题 + 一行副标题 + 行间距。
  ///
  /// BUG-1184：原先是死常量 196，配合标题 `maxLines: 1`。书封宽只有 94px，一行
  /// 只显示得到日文书名的五六个字。放宽到两行就必须同步抬高行高，而且这个高度
  /// 本来也该随文字缩放走——旧的 196 在 textScale≥1.5 时连「单行标题 + 副标题」
  /// 都装不下，会直接竖向溢出。
  double _continueRowHeight(BuildContext context, HibikiDesignTokens tokens) {
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

  /// [initState] 异步载入的视频库（继续观看 + 视频计数）。
  List<VideoBookRow> _videos = const <VideoBookRow>[];

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

  /// 互联 host 设备显示名（配对时存进 [HibikiClientUrl.deviceName]；取不到时
  /// 渲染层回退通用「远端」文案）。「标明设备来源」的数据源。
  String? _remoteDeviceName;

  /// 远端活动事件行的 identity 集（这些行 id=0 哨兵且可能与本地行值相等，必须按
  /// 实例识别），供聚合按设备分组 + 打设备标签。
  Set<ActivityEventRow> _remoteActivityRows = Set<ActivityEventRow>.identity();

  /// 每日字数合计（dateKey → 字数，阅读 + 观看 + 游戏），热力图「全部」档 +
  /// 今日目标行的分子（目标固定按全来源合计，不随热力图筛选变）。
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

  /// 已加载的原始统计行（点选日明细 sheet 按 dateKey 过滤，免重查）。
  List<ReadingStatisticRow> _readingRows = const <ReadingStatisticRow>[];
  List<VideoWatchStatisticRow> _watchRows = const <VideoWatchStatisticRow>[];

  /// 合集归属映射（统计页/书架同源，显示名规则「非合集上下文拼合集名」用）：
  /// - [_collectionNamesById]：collectionId → 合集名。
  /// - [_primaryCollectionByEntry]：'<mediaType>|<entryKey>' → 折叠归属主 collectionId。
  /// - [_bookKeyByTitle]：reading_statistics 行只存 title，经 epub_books 反查 bookKey。
  Map<int, String> _collectionNamesById = const <int, String>{};
  Map<String, int> _primaryCollectionByEntry = const <String, int>{};
  Map<String, String> _bookKeyByTitle = const <String, String>{};

  /// epub bookKey → 导入时刻（epoch 毫秒，`EpubBooks.importedAt`），
  /// 「最近添加」行的书侧排序时间源（视频侧用 [VideoBookRow.importedAt]）。
  Map<String, int> _epubImportedAtByKey = const <String, int>{};

  /// '<mediaType>|<entryKey>' → 条目在其主折叠合集里的组内 sortIndex（只记归属
  /// 主合集的行，书架/视频页同口径）。继续区合集 Next-Up 的组内排序键。
  Map<String, int> _memberSortIndex = const <String, int>{};

  /// 每个视频 bookUid 的最近观看时刻（epoch 毫秒），继续观看排序用。
  Map<String, int> _videoWatchAtByUid = const <String, int>{};

  /// 订阅「数据变了」信号（阅读/观看/导入落库）以自动刷新，及其防抖定时器。
  /// 首页不保活、且阅读器是 pushed 路由（读完回来首页不重建 initState），故必须靠
  /// DB 表级变更主动重查，否则「打开一本书读完回来」活动/热力图仍是旧数据。
  StreamSubscription<void>? _dataChangeSub;
  Timer? _reloadDebounce;

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
  }

  /// 游戏库仓储（[initState] 挂监听，[dispose] 解除）。
  GalgameRepository? _galgameRepo;

  /// 表变更后防抖重载（多次连续写只重查一次，避免频繁 setState）。
  void _scheduleReload() {
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) unawaited(_loadDashboardData());
    });
  }

  @override
  void dispose() {
    _reloadDebounce?.cancel();
    unawaited(_dataChangeSub?.cancel());
    _galgameRepo?.removeListener(_scheduleReload);
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

  Future<void> _loadDashboardDataUnsafe() async {
    final AppModel appModel = ref.read(appProvider);
    final HibikiDatabase db = appModel.database;
    final List<VideoBookRow> videos = await widget.videoRepo.listForShelf();
    final List<ActivityEventRow> events =
        await db.getRecentActivityEvents(limit: 200);
    final List<ReadingStatisticRow> reading =
        await db.getAllReadingStatistics();
    final List<VideoWatchStatisticRow> watch =
        await db.getAllVideoWatchStatistics();
    // 游戏活动日聚合（activity_events 的 game 事件，热力图「游戏」档数据源）。
    final List<(String, int, int)> gameDaily =
        await db.getActivityDailyTotals(kActivityGame);
    // P4：游戏库整表（日明细/时间轴的游戏显示名反查）。仓储缓存与表恒一致，
    // 未载入过才真查 DB（毫秒级）；load() 会 notify → 本页监听器防抖重载一次
    // 后 isLoaded=true，不再形成回环。
    final GalgameRepository galgameRepo = appModel.galgameRepo;
    final List<GalgameEntry> games =
        galgameRepo.isLoaded ? galgameRepo.games : await galgameRepo.load();
    // 合集归属映射（统计页/书架同源）：显示名规则「非合集上下文拼合集名」用。
    final Map<int, String> collectionNamesById = <int, String>{
      for (final MediaCollectionRow c in await db.getAllMediaCollections())
        c.id: c.name,
    };
    final Map<String, int> primaryByEntry =
        await db.getPrimaryCollectionIdByEntry();
    // 组内序：条目在其主折叠合集里的 sortIndex（视频页/书架 _loadShelfMaps 同
    // 口径——一次 getAllCollectionItems 内存分组，只记归属主合集的行）。
    final Map<String, int> memberSortIndex = <String, int>{};
    for (final MediaCollectionItemRow m in await db.getAllCollectionItems()) {
      final String key = '${m.mediaType}|${m.entryKey}';
      if (primaryByEntry[key] == m.collectionId) {
        memberSortIndex[key] = m.sortIndex;
      }
    }
    // reading_statistics 行只存 title：日明细拼合集前缀需经 epub_books 反查 bookKey
    // （阅读统计页 _collectionNameForBook 同范式）。同批顺带取 importedAt 喂
    // 「最近添加」行（一次查询两用）。
    final List<EpubBookRow> epubRows = await db.getAllEpubBooks();
    final Map<String, String> bookKeyByTitle = <String, String>{
      for (final EpubBookRow r in epubRows) r.title: r.bookKey,
    };
    final Map<String, int> epubImportedAtByKey = <String, int>{
      for (final EpubBookRow r in epubRows) r.bookKey: r.importedAt,
    };

    // 每日「读到的字数」按来源拆三份（热力图筛选 全部/阅读/观看/游戏）：书内阅读、
    // 视频字幕字数（看带字幕的视频也是在读字，用户反馈「阅读活动只有书籍，其他的
    // 呢」）、游戏 hook 文本。「全部」= 三者合计。
    final Map<String, int> readChars = <String, int>{};
    final Map<String, int> readTimeMs = <String, int>{};
    for (final ReadingStatisticRow r in reading) {
      readChars[r.dateKey] = (readChars[r.dateKey] ?? 0) + r.charactersRead;
      readTimeMs[r.dateKey] = (readTimeMs[r.dateKey] ?? 0) + r.readingTimeMs;
    }
    final Map<String, int> watchChars = <String, int>{};
    final Map<String, int> watchTimeMs = <String, int>{};
    for (final VideoWatchStatisticRow w in watch) {
      watchChars[w.dateKey] = (watchChars[w.dateKey] ?? 0) + w.subtitleChars;
      watchTimeMs[w.dateKey] = (watchTimeMs[w.dateKey] ?? 0) + w.watchTimeMs;
    }
    final Map<String, int> gameChars = <String, int>{};
    final Map<String, int> gameTimeMs = <String, int>{};
    for (final (String dateKey, int charsDelta, int durationMs) in gameDaily) {
      gameChars[dateKey] = (gameChars[dateKey] ?? 0) + charsDelta;
      gameTimeMs[dateKey] = (gameTimeMs[dateKey] ?? 0) + durationMs;
    }
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

    // 每个视频的最近观看时刻（按 bookUid 取 lastModified 最大值）。
    final Map<String, int> watchAt = <String, int>{};
    for (final VideoWatchStatisticRow w in watch) {
      if (w.bookUid case final String uid) {
        if (w.lastModified > (watchAt[uid] ?? 0)) {
          watchAt[uid] = w.lastModified;
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _videos = videos;
      _games = games;
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
      _collectionNamesById = collectionNamesById;
      _primaryCollectionByEntry = primaryByEntry;
      _bookKeyByTitle = bookKeyByTitle;
      _epubImportedAtByKey = epubImportedAtByKey;
      _memberSortIndex = memberSortIndex;
      _videoWatchAtByUid = watchAt;
    });
    // 本地渲染先行，互联数据到达后再增量补位（不阻塞首屏）。
    unawaited(_loadRemoteDashboardData());
  }

  /// 「继续/活动也走 hibiki 互联」：互联启用且已配对时，从 host 拉取
  /// 书清单（内联阅读进度）/ 视频清单（内联播放断点）/ 最近活动事件，
  /// 把本地没有的在读书、在看视频补进「继续」，活动事件与本地混排进时间轴
  /// （display-only 不落库）。任何失败静默保持纯本地视图（离线/老 host 不致崩）。
  Future<void> _loadRemoteDashboardData() async {
    final AppModel appModel = ref.read(appProvider);
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
        cache.read<List<RemoteBookInfo>>(
          key: RemoteLibraryCacheKeys.books,
          fetch: backend.listRemoteBooks,
        ),
        cache.read<List<RemoteVideoInfo>>(
          key: RemoteLibraryCacheKeys.videos,
          fetch: backend.listRemoteVideos,
        ),
        cache.read<List<RemoteActivityEvent>>(
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
      final List<MediaItem> books = ref
              .read(hibikiBooksProvider(JapaneseLanguage.instance))
              .valueOrNull ??
          const <MediaItem>[];
      final Set<String> localBookKeys = <String>{
        for (final MediaItem item in books)
          ReaderHibikiSource.parseBookKey(item.mediaIdentifier) ??
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
      final List<HibikiClientUrl> urls = await syncRepo.getHibikiClientUrls();
      String? deviceName;
      for (final HibikiClientUrl u in urls) {
        final String? name = u.deviceName;
        if (u.enabled && name != null && name.isNotEmpty) {
          deviceName = name;
          break;
        }
      }
      final List<ActivityEventRow> remoteRows =
          remoteActivityAsRows(remoteActivity);
      if (!mounted) return;
      setState(() {
        _remoteContinue = continueCandidates;
        _remoteCoverFetcher = remoteCoverFetcherFor(backend);
        _remoteDeviceName = deviceName;
        _remoteActivityRows = Set<ActivityEventRow>.identity()
          ..addAll(remoteRows);
        _activityEvents = mergeActivityEvents(
          _localActivityEvents,
          remoteRows,
        );
      });
    } catch (_) {
      // 互联瞬断/超时：保持纯本地视图；下次进入首页自然重试。
    }
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final AppModel appModel = ref.watch(appProvider);
    final List<MediaItem> books =
        ref.watch(hibikiBooksProvider(JapaneseLanguage.instance)).valueOrNull ??
            const <MediaItem>[];
    final Map<String, int> lastReadByKey =
        ref.watch(bookLastReadAtProvider).valueOrNull ?? const <String, int>{};
    final DateTime now = DateTime.now();

    // 活动条封面/点击直达需要「mediaKey → 本地条目」反查映射（渲染层现算，不
    // 落状态；书键兼容 epub bookKey 与 standalone SRT uid 两种身份）。
    final Map<String, MediaItem> booksByKey = <String, MediaItem>{};
    for (final MediaItem item in books) {
      final String? key =
          ReaderHibikiSource.parseBookKey(item.mediaIdentifier) ??
              ReaderHibikiSource.parseSrtBookUid(item.mediaIdentifier);
      if (key != null) booksByKey[key] = item;
    }
    final Map<String, VideoBookRow> videosByUid = <String, VideoBookRow>{
      for (final VideoBookRow v in _videos) v.bookUid: v,
    };

    final Widget continueCard =
        _buildContinueSection(tokens, appModel, books, lastReadByKey);
    final Widget heatmapCard = _buildHeatmapCard(tokens);
    final Widget activityCard =
        _buildActivitySection(tokens, now, appModel, booksByKey, videosByUid);
    final Widget? recentCard =
        _buildRecentlyAddedSection(tokens, appModel, books, now);

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
              Expanded(flex: 2, child: activityCard),
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
              activityCard,
              if (recentCard != null) ...<Widget>[
                SizedBox(height: tokens.spacing.card),
                recentCard,
              ],
            ],
          );
        }
        return ListView(
          padding: EdgeInsets.all(tokens.spacing.card),
          children: <Widget>[
            // 超宽屏（4K/带鱼屏）限宽居中：再宽下去只是把每个区块拉稀，不增信息量。
            // heightFactor: 1 让 Align 在 ListView 的无界高度里收敛到内容高度。
            Align(
              alignment: Alignment.topCenter,
              heightFactor: 1,
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(maxWidth: _kDashboardMaxWidth),
                child: body,
              ),
            ),
          ],
        );
      },
    );
  }

  // ── 区块 2：继续（书 + 视频统一列表） ─────────────────────────────────────

  /// 「继续」区块：把在读的书（0<position<duration）与在看的视频
  /// （lastPositionMs>0 且未完成）合并、按最近活动时刻倒序，分段筛选后取前 10 条。
  Widget _buildContinueSection(
    HibikiDesignTokens tokens,
    AppModel appModel,
    List<MediaItem> books,
    Map<String, int> lastReadByKey,
  ) {
    final List<_ContinueEntry> entries = <_ContinueEntry>[];
    for (final MediaItem item in books) {
      if (item.position > 0 && item.position < item.duration) {
        final String bookKey =
            ReaderHibikiSource.parseBookKey(item.mediaIdentifier) ??
                item.mediaIdentifier;
        final int recent = lastReadByKey[bookKey] ?? 0;
        final int percent =
            ((item.position / item.duration) * 100).clamp(0, 100).round();
        entries.add(_ContinueEntry(
          kind: _bookMediaKind(item),
          // BUG-1018 (A1)：书名走与书架卡同一 override 通道（编辑对话框改名后
          // 首页「继续」区同步显示新名），不直接读 DB 原名。
          title: ReaderHibikiSource.instance.getDisplayTitleFromMediaItem(item),
          recentMs: recent,
          percent: percent,
          progress: percent / 100,
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
      entries.add(_videoContinueEntry(
        resume,
        collectionName: _collectionNamesById[ce.key],
        recentMs: recent,
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
        percent: c.percent,
        // 远端书带 host 阅读百分比可画进度条；远端视频无集数/完成信息不画。
        progress: c.isVideo ? null : c.percent / 100,
        collectionName: c.collectionName,
        remote: c,
      ));
    }
    entries.sort((_ContinueEntry a, _ContinueEntry b) =>
        b.recentMs.compareTo(a.recentMs));
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
          : _continueCardsRow(tokens, appModel, filtered),
    );
  }

  /// 横滑卡片行本体（「继续」与「最近添加」共用）：定高横向 ListView。
  Widget _continueCardsRow(
    HibikiDesignTokens tokens,
    AppModel appModel,
    List<_ContinueEntry> entries,
  ) {
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
          itemBuilder: (BuildContext context, int i) =>
              _buildContinueCard(tokens, appModel, entries[i]),
        ),
      ),
    );
  }

  /// 区块 4：「最近添加」横滑行（底部通栏，用户反馈「底部很空」的填充提案）：
  /// 本地书（epub importedAt）+ 本地视频（[VideoBookRow.importedAt]）按添加时刻
  /// 倒序混排取前 12，复用继续卡组件（不画进度条，副标题=「类型 · 相对时间」）。
  /// 无可排条目（空库/无时间戳）返回 null 不占位。
  Widget? _buildRecentlyAddedSection(
    HibikiDesignTokens tokens,
    AppModel appModel,
    List<MediaItem> books,
    DateTime now,
  ) {
    final List<_ContinueEntry> entries = <_ContinueEntry>[];
    for (final MediaItem item in books) {
      final String? bookKey =
          ReaderHibikiSource.parseBookKey(item.mediaIdentifier);
      // standalone SRT 书无 epub 导入时间戳（不在 epub_books），本轮不进最近添加。
      final int addedMs =
          bookKey == null ? 0 : (_epubImportedAtByKey[bookKey] ?? 0);
      if (addedMs <= 0) continue;
      entries.add(_ContinueEntry(
        kind: _bookMediaKind(item),
        // BUG-1018 (A1)：与继续卡同一 override 显示名通道。
        title: ReaderHibikiSource.instance.getDisplayTitleFromMediaItem(item),
        recentMs: addedMs,
        collectionName: statCollectionName(
          _bookCollectionKey(item),
          _primaryCollectionByEntry,
          _collectionNamesById,
        ),
        subtitleOverride:
            '${t.home_filter_read} · ${_relativeTimeLabel(addedMs, now)}',
        book: item,
      ));
    }
    for (final VideoBookRow v in _videos) {
      final int addedMs = v.importedAt ?? 0;
      if (addedMs <= 0) continue;
      entries.add(_ContinueEntry(
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
      ));
    }
    // BUG-1111：游戏也进「最近添加」。addedAt 即 `galgames.id` 的微秒时间戳来源
    // （添加时刻），与书的 importedAt / 视频的 importedAt 同量纲，可直接混排。
    for (final GalgameEntry g in _games) {
      final int addedMs = g.addedAt.millisecondsSinceEpoch;
      if (addedMs <= 0) continue;
      entries.add(_ContinueEntry(
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
      ));
    }
    if (entries.isEmpty) return null;
    entries.sort((_ContinueEntry a, _ContinueEntry b) =>
        b.recentMs.compareTo(a.recentMs));
    final List<_ContinueEntry> top = entries.take(12).toList();
    return _sectionCard(
      tokens,
      title: t.home_recently_added,
      child: _continueCardsRow(tokens, appModel, top),
    );
  }

  /// 书 [MediaItem] 的真实媒体种类：standalone SRT 书身份是
  /// `hoshi://srtbook/<uid>`（BUG-1018 A3），其余按 EPUB。两者在「继续/最近添加」
  /// 区块行为一致（[_ContinueEntry.isBook]），但身份不该被抹平成同一个值。
  MediaKind _bookMediaKind(MediaItem item) =>
      ReaderHibikiSource.parseSrtBookUid(item.mediaIdentifier) != null
          ? MediaKind.srt
          : MediaKind.epub;

  /// 书 [MediaItem] → 合集归属键：epub 用 bookKey（'epub|<bookKey>'），standalone
  /// SRT 书身份是 `hoshi://srtbook/<uid>`（BUG-1018 A3）→ 'srt|<uid>'；识别不出
  /// 回退 epub 键（查不中合集，安全降级）。
  String _bookCollectionKey(MediaItem item) {
    final String? bookKey =
        ReaderHibikiSource.parseBookKey(item.mediaIdentifier);
    if (bookKey != null) return MediaKind.epub.compositeKey(bookKey);
    final String? srtUid =
        ReaderHibikiSource.parseSrtBookUid(item.mediaIdentifier);
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
    HibikiDesignTokens tokens,
    AppModel appModel,
    _ContinueEntry entry,
  ) {
    // 视频是横版 16:9，书与游戏都是竖版封面（galgame 封面同为竖版海报）。
    final double coverWidth =
        entry.isVideo ? _kContinueVideoCoverWidth : _kContinueBookCoverWidth;
    // BUG-1111：游戏没有阅读百分比（无完成度概念），状态段只标类型，不能套用
    // 书的「阅读 · x%」——否则一律显示「阅读 · 0%」。
    String status = switch (entry.kind) {
      MediaKind.video => t.home_filter_watch,
      MediaKind.game => t.home_filter_game,
      MediaKind.epub ||
      MediaKind.srt =>
        '${t.home_filter_read} · ${entry.percent}%',
    };
    if (entry.remote != null) {
      // 标明设备来源：优先 host 设备名（配对时存下），取不到回退通用「远端」。
      status = '$status · ${_remoteDeviceName ?? t.home_remote_source}';
    }
    // 「最近添加」行覆盖状态段（类型 · 相对时间）；继续区恒 null 走上面默认。
    status = entry.subtitleOverride ?? status;
    final String? collectionName = entry.collectionName;
    final String title = collectionName ?? entry.title;
    final String subtitle =
        collectionName != null ? '${entry.title} · $status' : status;
    return SizedBox(
      width: coverWidth,
      child: InkWell(
        onTap: () => _openContinueEntry(appModel, entry),
        borderRadius: HibikiBorderRadius.card,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ClipRRect(
              borderRadius: HibikiBorderRadius.card,
              child: SizedBox(
                width: coverWidth,
                height: _kContinueCoverHeight,
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    _continueCover(tokens, appModel, entry),
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
                            backgroundColor:
                                Colors.black.withValues(alpha: 0.35),
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
    HibikiDesignTokens tokens,
    AppModel appModel,
    _ContinueEntry entry,
  ) {
    if (entry.remote != null) return _remoteCover(tokens, entry);
    if (entry.isVideo) return _videoCover(tokens, entry.video!);
    if (entry.isGame) return _gameCover(tokens, entry.game!);
    return FadeInImage(
      placeholder: MemoryImage(kTransparentImage),
      image: ReaderHibikiSource.instance.getDisplayThumbnailFromMediaItem(
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
  Widget _remoteCover(HibikiDesignTokens tokens, _ContinueEntry entry) {
    final RemoteContinueCandidate remote = entry.remote!;
    final String? coverUrl = remote.coverUrl;
    final RemoteCoverFetcher? fetcher = _remoteCoverFetcher;
    final IconData icon =
        entry.isVideo ? Icons.movie_outlined : Icons.menu_book_outlined;
    if (coverUrl == null || coverUrl.isEmpty || fetcher == null) {
      return _coverPlaceholder(tokens, icon);
    }
    return Image(
      image: RemoteCoverImage(coverUrl, fetcher, cacheKey: remote.id),
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => _coverPlaceholder(tokens, icon),
    );
  }

  /// 视频封面：coverPath 存在则 [Image.file]，否则占位图标。
  Widget _videoCover(HibikiDesignTokens tokens, VideoBookRow video) {
    final String? path = video.coverPath;
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      return Image.file(
        File(path),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) =>
            _coverPlaceholder(tokens, Icons.movie_outlined),
      );
    }
    return _coverPlaceholder(tokens, Icons.movie_outlined);
  }

  /// 游戏封面（BUG-1111 / BUG-1112）：`galgames.coverPath` 存在则 [Image.file]，
  /// 否则占位图标。与 [_videoCover] 同一形态——封面是本机文件路径（目录扫描 /
  /// exe 内嵌图标 / 刮削下载三种来源都落成本地文件），不走网络取图。
  Widget _gameCover(HibikiDesignTokens tokens, GalgameEntry game) {
    final String? path = game.coverPath;
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      return Image.file(
        File(path),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) =>
            _coverPlaceholder(tokens, Icons.videogame_asset_outlined),
      );
    }
    return _coverPlaceholder(tokens, Icons.videogame_asset_outlined);
  }

  /// 封面占位：中性底色 + 图标。
  Widget _coverPlaceholder(HibikiDesignTokens tokens, IconData icon) {
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
      homeShellTabNotifier.value =
          entry.isVideo ? HomeTab.video : HomeTab.books;
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

  // ── 区块 3：学习活动热力图 ───────────────────────────────────────────────

  /// 学习活动热力图卡（复用 [StatContributionHeatmap]，按每日字数铺格）：header
  /// 加来源筛选（全部/阅读/观看/游戏），格下加「今日目标」行，点选某日弹当日明细
  /// sheet（用户反馈「点了只有日期和字数，分不清干了什么」三连的解药）。
  Widget _buildHeatmapCard(HibikiDesignTokens tokens) {
    final Map<String, int> charsByDay = _heatmapCharsByDay();
    final Map<String, int> timeMsByDay = _heatmapTimeMsByDay();
    return _sectionCard(
      tokens,
      title: t.reading_activity,
      header: _filterChips<int>(
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
            // GitHub 式浅格子。
            emptyColor: tokens.surfaces.overlay,
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

  /// 「今日目标」行：全来源合计今日字数 vs 每日字数目标（与阅读统计页同一持久化
  /// [AppModel.readingGoalDailyChars]，不随热力图筛选变）。目标为 0 → 只留设定
  /// 入口按钮；否则进度条 + 「X / Y 字」，点击行弹编辑对话框。
  Widget _buildDailyGoalRow(HibikiDesignTokens tokens) {
    final int goal = ref.read(appProvider).readingGoalDailyChars;
    if (goal <= 0) {
      // BUG-1073 病灶 2：此前是热力图下方孤零零一个左对齐按钮。改成与已设目标态
      // 同构的一整行（图标 + 标签 + 口径说明 + 右侧入口），视觉上属于这张卡。
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
                t.stat_goal_scope_hint,
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
    final String todayKey = HibikiTimeFormat.dayKey(DateTime.now());
    final int todayChars = _readingCharsByDay[todayKey] ?? 0;
    final double fraction = (todayChars / goal).clamp(0.0, 1.0);
    return InkWell(
      onTap: () => unawaited(_editDailyGoal()),
      borderRadius: HibikiBorderRadius.card,
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

  /// 近 [days] 天（含今天）的日均字数，**与目标同口径**（全来源合计
  /// [_readingCharsByDay]）：给「我该填多少」一个真实参考值（BUG-1075）。
  /// 无数据日按 0 计入分母（真实反映日均，不是活跃日均）。
  int _recentDailyAverageChars({int days = 7}) {
    if (days <= 0) return 0;
    final DateTime today = DateTime.now();
    int total = 0;
    for (int i = 0; i < days; i++) {
      final String key =
          HibikiTimeFormat.dayKey(today.subtract(Duration(days: i)));
      total += _readingCharsByDay[key] ?? 0;
    }
    return total ~/ days;
  }

  /// 点热力图某日 → 当日明细 sheet：头部=日期+当日合计（全来源），内容按
  /// 阅读/观看/游戏分节列出每条目的字数+时长（空节不显示）。阅读/观看直接过滤
  /// 已加载统计行，游戏按日按标题现查 DB 聚合。
  Future<void> _showDayDetailSheet(String dateKey) async {
    final HibikiDatabase db = ref.read(appProvider).database;
    final List<(String, int, int)> gameRows =
        await db.getActivityTitleTotalsForDay(kActivityGame, dateKey);
    if (!mounted) return;
    final List<({String title, int chars, int timeMs})> reading =
        _readingDayRows(dateKey);
    final List<({String title, int chars, int timeMs})> watch =
        _watchDayRows(dateKey);
    // P4：游戏节的 title 是 activity_events 落库时的标题快照（聚合键，恒 raw），
    // 上屏前按库内条目反查显示名（用户改名后明细跟着变；查不到原样显示快照）。
    final List<({String title, int chars, int timeMs})> game =
        <({String title, int chars, int timeMs})>[
      for (final (String title, int chars, int timeMs) in gameRows)
        (title: _gameDisplayTitle(title), chars: chars, timeMs: timeMs),
    ];
    await adaptiveModalSheet<void>(
      context: context,
      builder: (BuildContext sheetContext) =>
          _buildDayDetailSheet(sheetContext, dateKey, reading, watch, game),
    );
  }

  /// 明细「阅读」节：reading_statistics 当日行按 title 聚合。显示名拼合集前缀
  /// （title→bookKey 反查，阅读统计页 _collectionNameForBook 同范式）；DB 行
  /// 仍按原 title 聚合，不动历史数据身份。
  List<({String title, int chars, int timeMs})> _readingDayRows(
    String dateKey,
  ) {
    final Map<String, ({int chars, int timeMs})> byTitle =
        <String, ({int chars, int timeMs})>{};
    for (final ReadingStatisticRow r in _readingRows) {
      if (r.dateKey != dateKey) continue;
      final ({int chars, int timeMs}) prev =
          byTitle[r.title] ?? (chars: 0, timeMs: 0);
      byTitle[r.title] = (
        chars: prev.chars + r.charactersRead,
        timeMs: prev.timeMs + r.readingTimeMs,
      );
    }
    return <({String title, int chars, int timeMs})>[
      for (final MapEntry<String, ({int chars, int timeMs})> e
          in byTitle.entries)
        (
          title: _readingStatDisplayTitle(e.key),
          chars: e.value.chars,
          timeMs: e.value.timeMs,
        ),
    ];
  }

  /// 阅读统计行 title → 显示名：先过 display-title 门面（P4：改名 override 应用
  /// 到明细行；统计行 title 是聚合键恒 raw，仅上屏时替换），命中合集再拼
  /// 「合集名 - 名字」；反查不到 bookKey（视频字幕书/已删书等）原样返回。
  String _readingStatDisplayTitle(String title) {
    final String display = displayTitleForStatRow(
      rawTitle: title,
      bookKeyByTitle: _bookKeyByTitle,
    );
    final String? bookKey = _bookKeyByTitle[title];
    if (bookKey == null) return display;
    return collectionQualifiedTitle(
      entryKey: MediaKind.epub.compositeKey(bookKey),
      rawTitle: display,
      primaryByEntry: _primaryCollectionByEntry,
      collectionNamesById: _collectionNamesById,
    );
  }

  /// 游戏活动标题 → 显示名（P4）：先按 [mediaKey]（galgames.id）精确命中，
  /// 再按「落库时的标题快照 == 库内条目任一已知名」兜底（老事件无 mediaKey），
  /// 最后回落快照原文。查找委托 [displayTitleForGame]。
  /// 按 `galgames.id` 反查本页已加载的游戏；找不到返回 null（已删除条目的历史
  /// 活动行仍会渲染，只是没有封面/新名可用）。
  GalgameEntry? _gameById(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final GalgameEntry g in _games) {
      if (g.id == id) return g;
    }
    return null;
  }

  String _gameDisplayTitle(String rawTitle, {String? mediaKey}) {
    GalgameEntry? entry = _gameById(mediaKey);
    if (entry == null) {
      for (final GalgameEntry g in _games) {
        if (g.name == rawTitle ||
            g.displayName == rawTitle ||
            g.metadata.name == rawTitle ||
            g.metadata.nameCn == rawTitle) {
          entry = g;
          break;
        }
      }
    }
    return displayTitleForGame(entry: entry, rawTitle: rawTitle);
  }

  /// 明细「观看」节：video_watch_statistics 当日行按 title 聚合；行自带 bookUid
  /// （任取一条非空）可直接拼合集前缀。
  List<({String title, int chars, int timeMs})> _watchDayRows(String dateKey) {
    final Map<String, ({int chars, int timeMs, String? uid})> byTitle =
        <String, ({int chars, int timeMs, String? uid})>{};
    for (final VideoWatchStatisticRow w in _watchRows) {
      if (w.dateKey != dateKey) continue;
      final ({int chars, int timeMs, String? uid}) prev =
          byTitle[w.title] ?? (chars: 0, timeMs: 0, uid: null);
      byTitle[w.title] = (
        chars: prev.chars + w.subtitleChars,
        timeMs: prev.timeMs + w.watchTimeMs,
        uid: prev.uid ?? w.bookUid,
      );
    }
    return <({String title, int chars, int timeMs})>[
      for (final MapEntry<String, ({int chars, int timeMs, String? uid})> e
          in byTitle.entries)
        (
          title: e.value.uid == null
              ? e.key
              : collectionQualifiedTitle(
                  entryKey: MediaKind.video.compositeKey(e.value.uid!),
                  rawTitle: e.key,
                  primaryByEntry: _primaryCollectionByEntry,
                  collectionNamesById: _collectionNamesById,
                ),
          chars: e.value.chars,
          timeMs: e.value.timeMs,
        ),
    ];
  }

  /// 当日明细 sheet 本体：日期头 + 合计行 + 三节（阅读/观看/游戏）。
  Widget _buildDayDetailSheet(
    BuildContext context,
    String dateKey,
    List<({String title, int chars, int timeMs})> reading,
    List<({String title, int chars, int timeMs})> watch,
    List<({String title, int chars, int timeMs})> game,
  ) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final int totalChars = _readingCharsByDay[dateKey] ?? 0;
    final int totalMs = _readingTimeMsByDay[dateKey] ?? 0;
    final String summary = totalMs > 0
        ? '${formatStatChars(totalChars)} · ${formatStatTime(totalMs)}'
        : formatStatChars(totalChars);
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(tokens.spacing.card),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              formatStatHeatmapDay(dateKey),
              style: tokens.type.sectionLabel,
            ),
            SizedBox(height: tokens.spacing.gap / 2),
            Text(summary, style: tokens.type.metadata),
            ..._dayDetailSection(
                tokens, t.home_filter_read, Icons.menu_book, reading),
            ..._dayDetailSection(
                tokens, t.home_filter_watch, Icons.movie, watch),
            ..._dayDetailSection(
                tokens, t.home_filter_game, Icons.videogame_asset, game),
          ],
        ),
      ),
    );
  }

  /// 明细 sheet 的一节：节标题 + 每行「图标 + 显示名 + 字数 · 时长」；空节不渲染。
  List<Widget> _dayDetailSection(
    HibikiDesignTokens tokens,
    String label,
    IconData icon,
    List<({String title, int chars, int timeMs})> rows,
  ) {
    if (rows.isEmpty) return const <Widget>[];
    return <Widget>[
      SizedBox(height: tokens.spacing.gap + 4),
      Text(label, style: tokens.type.sectionLabel),
      SizedBox(height: tokens.spacing.gap / 2),
      for (final ({String title, int chars, int timeMs}) row in rows)
        Padding(
          padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
          child: Row(
            children: <Widget>[
              Icon(icon, size: 18, color: tokens.surfaces.primary),
              SizedBox(width: tokens.spacing.gap),
              Expanded(
                child: Text(
                  row.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.listTitle,
                ),
              ),
              SizedBox(width: tokens.spacing.gap),
              Text(
                row.timeMs > 0
                    ? '${formatStatChars(row.chars)} · ${formatStatTime(row.timeMs)}'
                    : formatStatChars(row.chars),
                style: tokens.type.metadata,
              ),
            ],
          ),
        ),
    ];
  }

  // ── 区块 4：Activity 时间轴 ──────────────────────────────────────────────

  /// Activity 时间轴：顶部分类筛选 → 内存过滤 events → 纯函数聚合 → 按日期分组渲染。
  /// [booksByKey] / [videosByUid] 是「mediaKey → 本地条目」反查映射（封面缩略 +
  /// 点击直达用；查不到回退图标/切 tab）。
  Widget _buildActivitySection(
    HibikiDesignTokens tokens,
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
    final String todayKey = HibikiTimeFormat.dayKey(now);
    final String yesterdayKey =
        HibikiTimeFormat.dayKey(now.subtract(const Duration(days: 1)));

    return _sectionCard(
      tokens,
      title: t.home_activity,
      header: _filterChips<String?>(
        tokens: tokens,
        selected: _activityFilter,
        onSelected: (String? v) => setState(() => _activityFilter = v),
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
                for (final ActivityDateGroup g in groups)
                  _buildActivityGroup(tokens, g, todayKey, yesterdayKey, now,
                      appModel, booksByKey, videosByUid),
              ],
            ),
    );
  }

  /// 单个日期分组：日期头 + 该日的条目。
  Widget _buildActivityGroup(
    HibikiDesignTokens tokens,
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
              tokens, e, now, appModel, booksByKey, videosByUid),
      ],
    );
  }

  /// 单条活动：前置封面缩略（命中本地条目；否则类型图标）+ 标题（粗）+ 副行
  /// （动作词 · 相对时间 · [时长] · [session 数]）。整行可点：命中本地条目直接
  /// 打开（视频续播/书 openMedia），查不到回退切 tab。
  Widget _buildActivityEntry(
    HibikiDesignTokens tokens,
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
          _openActivityEntry(appModel, entry, booksByKey, videosByUid)),
      borderRadius: HibikiBorderRadius.card,
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
            ReaderHibikiSource.instance.overrideTitleForBookKey(bookKey) ??
                entry.title;
        // 书事件的 mediaKey 无类型标记：按 core 跨域映射表
        // [shelfKindsOfActivityMedia] 的既定顺序（epub 键优先，standalone SRT
        // （mediaKey=uid）回退 srt 键）逐一试探；都不中就是散卡。
        String? collectionName;
        for (final MediaKind shelfKind
            in shelfKindsOfActivityMedia(ActivityMediaKind.book)) {
          collectionName = statCollectionName(
            shelfKind.compositeKey(bookKey),
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
    HibikiDesignTokens tokens,
    AppModel appModel,
    ActivityEntry entry,
    Map<String, MediaItem> booksByKey,
    Map<String, VideoBookRow> videosByUid,
  ) {
    final String? key = entry.mediaKey;
    if (key != null && key.isNotEmpty) {
      if (entry.mediaType == kActivityMediaVideo) {
        final VideoBookRow? video = videosByUid[key];
        if (video != null) {
          return ClipRRect(
            borderRadius: HibikiBorderRadius.card,
            child: SizedBox(
              width: 68,
              height: 40,
              child: _videoCover(tokens, video),
            ),
          );
        }
      } else if (entry.mediaType == kActivityMediaGame) {
        // BUG-1112：游戏此前被硬编码进「回退图标」分支，时间轴上只有一个小图标，
        // 而书与视频都有封面（用户报「活动里面没有封面」）。游戏封面就在
        // `galgames.coverPath`（本机文件），按 mediaKey = galgames.id 反查即可。
        final GalgameEntry? game = _gameById(key);
        if (game != null) {
          return ClipRRect(
            borderRadius: HibikiBorderRadius.card,
            child: SizedBox(
              width: 40,
              height: 56,
              child: _gameCover(tokens, game),
            ),
          );
        }
      } else if (entry.mediaType == kActivityMediaBook) {
        final MediaItem? book = booksByKey[key];
        if (book != null) {
          return ClipRRect(
            borderRadius: HibikiBorderRadius.card,
            child: SizedBox(
              width: 40,
              height: 56,
              child: FadeInImage(
                placeholder: MemoryImage(kTransparentImage),
                image: ReaderHibikiSource.instance
                    .getDisplayThumbnailFromMediaItem(
                  appModel: appModel,
                  item: book,
                ),
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

  /// 相对时间结构化结果 → i18n 文案。
  String _relativeTimeLabel(int timestampMs, DateTime now) {
    final ActivityRelativeTime rel = activityRelativeTime(timestampMs, now);
    switch (rel.unit) {
      case ActivityRelativeUnit.justNow:
        return t.activity_just_now;
      case ActivityRelativeUnit.minutesAgo:
        return t.activity_minutes_ago(n: rel.value);
      case ActivityRelativeUnit.hoursAgo:
        return t.activity_hours_ago(n: rel.value);
      case ActivityRelativeUnit.daysAgo:
        return t.activity_days_ago(n: rel.value);
    }
  }

  // ── 共享外壳 ────────────────────────────────────────────────────────────

  /// 统一的分区卡：标题（+ 可选右侧 header 控件）+ 内容，套 group 底色圆角。
  Widget _sectionCard(
    HibikiDesignTokens tokens, {
    required String title,
    required Widget child,
    Widget? header,
  }) {
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
    required HibikiDesignTokens tokens,
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
