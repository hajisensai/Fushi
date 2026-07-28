import 'dart:async' show unawaited;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/media/torrent/anime_download_config.dart';
import 'package:hibiki/src/media/torrent/anime_download_matching.dart';
import 'package:hibiki/src/media/torrent/anime_download_plan.dart';
import 'package:hibiki/src/media/torrent/anime_download_service.dart';
import 'package:hibiki/src/media/torrent/anime_download_subscription.dart';
import 'package:hibiki/src/media/torrent/download_network_proxy.dart'
    show kDownloadDiscoveryTimeout;
import 'package:hibiki/src/media/torrent/download_relocate_service.dart';
import 'package:hibiki/src/media/torrent/nyaa_client.dart';
import 'package:hibiki/src/media/torrent/torrent_backend.dart';
import 'package:hibiki/src/media/video/anilist_client.dart';
import 'package:hibiki/src/media/video/jimaku_client.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/jimaku_entry_picker.dart';
import 'package:hibiki/src/pages/implementations/jimaku_subtitle_dialog.dart'
    show jimakuLanguageLabel;
import 'package:hibiki/src/pages/implementations/download_actions.dart';
import 'package:hibiki/src/pages/implementations/downloads_page.dart';
import 'package:hibiki/src/pages/hibiki_page_placeholders.dart';
import 'package:hibiki/utils.dart';

/// 「番剧下载」选种对话框：搜番（AniList）→ 选种（Nyaa）→ 确认字幕（Jimaku）→
/// 推送 qBittorrent + 落盘 [AnimeDownloadPlan]（完成后由常驻服务自动入库挂合集）。
///
/// 分节渐进式（同 [JimakuSubtitleDialog] 的节奏）：三个阶段互斥展示（搜番结果 /
/// 种子列表 / 确认推送），底部常驻「下载任务」折叠区列出既有计划。所有网络操作
/// 容错降级为空结果 + 节内提示，不崩对话框。
/// 集号输入框该有多宽：**按 label 的真实测量宽度算出**，而不是写死像素。
///
/// BUG-1184：这里先后写死过 72 和 96——`96` 那一版的注释就写着「72 在界面缩放 >1
/// 时装不下 label」，也就是上一次的修法是在同一个错误里换一个更大的数字。可 label
/// 本身是会变的：中文「集数（可选）」是 6 个全角字，英文 `Episode (optional)` 更长，
/// 再乘上界面缩放与系统字号，96 照样装不下——用户截图里它就被裁成了「集数···」。
/// 而且这跟屏幕宽窄无关，**任何窗口宽度下都裁**。
///
/// 所以宽度必须由 label 决定，而不是反过来指望 label 挤进某个常数：用 [TextPainter]
/// 量出它在当前语言/字号/文字缩放下的实际宽度，再加上 [InputDecoration] 的水平内
/// 边距和集号本身要占的输入宽度。
///
/// [rowWidth] 是整行的可用宽度。上限取它的四成——这个框右边还有搜索按钮、左边是
/// 会被挤压的搜索词输入框，某些语言的超长译文不该把搜索词框挤没。上限同样不写死
/// 像素：宽屏上四成足够放下任何译文，窄屏上才真正起到保护作用。
///
/// [rowWidth] 故意做成必填、且不提供「取不到就退回某个保守常数」的默认值——与
/// [narrowAwareAppBarActions] 的 `availableWidth` 同一口径：有默认值就等于给这个
/// bug 留了一条随时能走回去的路，而这个 bug 的历史恰恰是「换一个更大的常数」。
/// 调用点把这一行包进 [LayoutBuilder] 后传 `constraints.maxWidth` 即可。
///
/// [rowWidth] 非有限（`double.infinity`，Row 在无界约束下就是这个值）时**不设上
/// 限**，而不是退回一个像素常数：上限的唯一职责是「别把同一行的邻居挤没」，而无界
/// 行里根本不存在会被挤没的邻居——此时 label 多长就多宽，反倒是唯一不会裁字的解。
double jimakuEpisodeFieldWidth(
  BuildContext context,
  String label, {
  required double rowWidth,
}) {
  // label 未浮起时按 bodyLarge 渲染（浮起后缩到 75%），按较大的那个量才安全。
  final TextStyle labelStyle =
      Theme.of(context).textTheme.bodyLarge ?? const TextStyle(fontSize: 16);
  final TextPainter painter = TextPainter(
    text: TextSpan(text: label, style: labelStyle),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final double labelWidth = painter.width;
  painter.dispose();
  final double cap = (rowWidth.isFinite && rowWidth > 0)
      ? math.max(96.0, rowWidth * 0.4)
      : double.infinity;
  return (labelWidth + kJimakuEpisodeFieldChrome).clamp(96.0, cap);
}

/// [jimakuEpisodeFieldWidth] 里 label 之外要占掉的宽度：`isDense` 的
/// [InputDecoration] 左右内边距各 12，再给集号本身留出约三位数字。
const double kJimakuEpisodeFieldChrome = 24 + 28;

/// 选种结果排序键（一律降序：多的/大的/新的在前）。
enum TorrentSortKey { seeders, size, date }

/// 选种结果排序比较器（一律降序；size/date 缺失值沉底）。纯函数，便于单测。
int compareNyaaTorrents(TorrentSortKey key, NyaaTorrent a, NyaaTorrent b) {
  switch (key) {
    case TorrentSortKey.seeders:
      return b.seeders.compareTo(a.seeders);
    case TorrentSortKey.size:
      return (b.sizeBytes ?? -1).compareTo(a.sizeBytes ?? -1);
    case TorrentSortKey.date:
      final DateTime aDate =
          a.pubDate ?? DateTime.fromMillisecondsSinceEpoch(0);
      final DateTime bDate =
          b.pubDate ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bDate.compareTo(aDate);
  }
}

/// 手动字幕搜索框的标题候选（罗马字优先 → 日文原名 → 英文；去空、去重，保序）。
/// 首项是默认预填（与 Nyaa 查询词同口径），其余供输入框下拉切换。纯函数。
List<String> animeTitleOptions(AniListMedia media) {
  final List<String> out = <String>[];
  for (final String? title in <String?>[
    media.romaji,
    media.native,
    media.english,
  ]) {
    final String q = title?.trim() ?? '';
    if (q.isNotEmpty && !out.contains(q)) out.add(q);
  }
  return out;
}

class AnimeDownloadDialog extends ConsumerStatefulWidget {
  const AnimeDownloadDialog({
    super.key,
    this.embedded = false,
    this.showTasks = true,
    this.tasksOnly = false,
    this.onOpenSettings,
    @visibleForTesting this.debugInitialMedia,
    @visibleForTesting this.debugInitialTorrent,
  });

  /// 内联模式：直接铺在「下载」页里（无对话框外框、无标题栏、无取消按钮），
  /// 用户要求番剧下载直接摊在页面上而非弹窗按钮。默认 false = 独立对话框。
  final bool embedded;

  /// Whether the compact task section is shown under the discovery flow.
  final bool showTasks;

  /// Renders only the full-height task list for the Downloads page task tab.
  final bool tasksOnly;

  /// 「后端未配置」横幅上「去设置」的落点：embedded 下由下载页传入
  /// （切到页内设置面板）；null（独立对话框，如视频页入口）则 push 下载设置页。
  final VoidCallback? onOpenSettings;

  /// 仅测试：初始即选中的番（跳过 AniList 网络搜索直达选种/确认阶段）。
  final AniListMedia? debugInitialMedia;

  /// 仅测试：初始即选中的种子（与 [debugInitialMedia] 联用直达确认推送阶段）。
  final NyaaTorrent? debugInitialTorrent;

  @override
  ConsumerState<AnimeDownloadDialog> createState() =>
      _AnimeDownloadDialogState();
}

class _AnimeDownloadDialogState extends ConsumerState<AnimeDownloadDialog>
    with HibikiPagePlaceholders<AnimeDownloadDialog> {
  final TextEditingController _animeQueryCtrl = TextEditingController();
  final TextEditingController _nyaaQueryCtrl = TextEditingController();
  late final TextEditingController _jimakuKeyCtrl;

  /// 字幕手动搜索：搜索词（选番后预填自动推导标题，可编辑）+ 可选集号，
  /// 供自动搜不到时手改重搜 Jimaku（BUG-896 后续：加手动入口）。
  final TextEditingController _jimakuQueryCtrl = TextEditingController();
  final TextEditingController _jimakuEpisodeCtrl = TextEditingController();

  // ---- 通用下载（粘贴磁力：书/视频/任意）----
  final TextEditingController _magnetCtrl = TextEditingController();
  String _genericKind = AnimeDownloadPlan.kindAuto;
  bool _pushingGeneric = false;

  /// Jimaku key 为空时显示输入行（`onChanged` 直接落偏好）。
  bool _showJimakuKeyField = false;

  // ---- 阶段 1：搜番（AniList）----
  bool _searchingAnime = false;
  bool _searchedAnime = false;

  /// 搜番失败/超时（区分「搜索出错」与「真没结果」，避免超时也显示「无结果」）。
  bool _animeSearchError = false;

  /// 搜番失败的真实错误串（异常 toString），错误态原样展示帮助定位网络问题。
  String? _animeSearchErrorDetail;
  List<AniListMedia> _animeMatches = const <AniListMedia>[];
  AniListMedia? _selectedMedia;

  // ---- 阶段 2：选种（Nyaa）+ 字幕索引（Jimaku）----
  bool _loadingTorrents = false;
  bool _torrentsLoaded = false;

  /// 选种搜索失败/超时（区分出错与真无种子）。
  bool _torrentsError = false;

  /// 选种搜索失败的真实错误串（异常 toString，如 HandshakeException / 超时），
  /// 错误态原样展示：站点被墙 / 代理未配时用户能看出是自己网络的问题。
  String? _torrentsErrorDetail;
  List<NyaaTorrent> _torrents = const <NyaaTorrent>[];
  String _category = '1_0';
  bool _trustedOnly = false;
  TorrentSortKey _torrentSort = TorrentSortKey.seeders;
  List<JimakuEntry> _jimakuEntries = const <JimakuEntry>[];
  JimakuEntry? _selectedJimakuEntry;
  List<JimakuFile> _jimakuFiles = const <JimakuFile>[];
  String? _jimakuPreferredLanguage;
  int? _jimakuSearchEpisode;
  JimakuEpisodeIndex _jimakuIndex =
      JimakuEpisodeIndex.fromFiles(const <JimakuFile>[]);
  bool _jimakuLoaded = false;

  /// Jimaku 字幕搜索状态（区分：搜索中 / 缺 API key / 出错 / 已搜到/无），
  /// 避免「没搜就说无字幕」。
  bool _jimakuLoading = false;
  bool _jimakuNoKey = false;
  bool _jimakuError = false;

  // ---- 阶段 3：确认推送 ----
  NyaaTorrent? _selectedTorrent;
  List<(int?, JimakuFile)> _chosenSubs = const <(int?, JimakuFile)>[];
  bool _includeSubs = true;
  bool _pushing = false;

  // ---- 下载任务折叠区 ----
  List<AnimeDownloadPlan> _plans = const <AnimeDownloadPlan>[];

  @override
  void initState() {
    super.initState();
    final AppModel appModel = ref.read(appProvider);
    _jimakuKeyCtrl = TextEditingController(text: appModel.jimakuApiKey);
    _showJimakuKeyField = appModel.jimakuApiKey.trim().isEmpty;
    // 仅测试：直达指定阶段（绕开 AniList/Nyaa 网络搜索）。
    final AniListMedia? debugMedia = widget.debugInitialMedia;
    if (debugMedia != null) {
      _selectedMedia = debugMedia;
      // 与真实点选路径同口径预填查询词（罗马字），测试直达时行为一致。
      _prefillQueriesFor(debugMedia);
      final NyaaTorrent? debugTorrent = widget.debugInitialTorrent;
      if (debugTorrent != null) {
        _selectedTorrent = debugTorrent;
        _chosenSubs = chooseSubtitlesFor(debugTorrent, _jimakuIndex);
      }
    }
    unawaited(_reloadPlans());
  }

  @override
  void dispose() {
    _animeQueryCtrl.dispose();
    _nyaaQueryCtrl.dispose();
    _jimakuKeyCtrl.dispose();
    _jimakuQueryCtrl.dispose();
    _jimakuEpisodeCtrl.dispose();
    _magnetCtrl.dispose();
    super.dispose();
  }

  /// 下载后端是否就绪（推送按钮禁用条件；浏览选种不禁）。默认（auto）在桌面
  /// 走内置引擎、开箱即用；只有显式外接 qb 且没填地址才算未就绪。
  bool get _backendReady => torrentBackendReady(ref.read(appProvider));

  /// 后端未就绪（推送禁用 + 提示横幅）。
  bool get _qbMissing => !_backendReady;

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------------------------------------------------------- 阶段 1

  Future<void> _searchAnime() async {
    final String query = _animeQueryCtrl.text.trim();
    if (query.isEmpty || _searchingAnime) return;
    setState(() {
      _searchingAnime = true;
      _searchedAnime = false;
      _animeSearchError = false;
      _animeSearchErrorDetail = null;
      _animeMatches = const <AniListMedia>[];
    });
    AniListClient? anilist;
    try {
      anilist = AniListClient(
        client: await ref.read(appProvider).createDownloadHttpClient(),
      );
      final List<AniListMedia> media =
          await anilist.searchAnime(query).timeout(kDownloadDiscoveryTimeout);
      if (!mounted) return;
      setState(() {
        _animeMatches = media;
        _searchedAnime = true;
      });
    } catch (error) {
      // 超时/网络错误：标记失败态（区分「无结果」），UI 给重试 + 真实错误串。
      if (mounted) {
        setState(() {
          _animeSearchError = true;
          _animeSearchErrorDetail = error.toString();
        });
      }
    } finally {
      anilist?.close();
      if (mounted) setState(() => _searchingAnime = false);
    }
  }

  /// 选番后的查询词预填：Nyaa 查询词与手动字幕搜索框都预填罗马字（Jimaku
  /// 条目名多为罗马字，同口径），集号清空；其余标题（日文原名/英文名）在
  /// 输入框下拉里可选，用户可改词/填集号重搜。
  void _prefillQueriesFor(AniListMedia media) {
    final String query = (media.romaji?.trim().isNotEmpty ?? false)
        ? media.romaji!.trim()
        : media.displayTitle;
    _nyaaQueryCtrl.text = query;
    final List<String> titleOptions = _titleOptions(media);
    _jimakuQueryCtrl.text =
        titleOptions.isNotEmpty ? titleOptions.first : media.displayTitle;
    _jimakuEpisodeCtrl.clear();
  }

  /// 点选某番：进入选种阶段，并行拉 Nyaa 种子与 Jimaku 字幕索引。
  /// Jimaku 空结果/无 key 不阻塞选种，只是徽标显示无字幕。
  Future<void> _selectMedia(AniListMedia media) async {
    _prefillQueriesFor(media);
    setState(() {
      _selectedMedia = media;
      _selectedTorrent = null;
      _chosenSubs = const <(int?, JimakuFile)>[];
      _torrents = const <NyaaTorrent>[];
      _torrentsLoaded = false;
      _jimakuEntries = const <JimakuEntry>[];
      _selectedJimakuEntry = null;
      _jimakuFiles = const <JimakuFile>[];
      _jimakuPreferredLanguage = null;
      _jimakuSearchEpisode = null;
      _jimakuIndex = JimakuEpisodeIndex.fromFiles(const <JimakuFile>[]);
      _jimakuLoaded = false;
    });
    await Future.wait(<Future<void>>[
      _fetchTorrents(),
      _fetchJimaku(media),
    ]);
  }

  /// 返回搜番阶段（换番）。
  void _clearSelectedMedia() {
    setState(() {
      _selectedMedia = null;
      _selectedTorrent = null;
      _torrents = const <NyaaTorrent>[];
      _torrentsLoaded = false;
    });
  }

  // ---------------------------------------------------------------- 阶段 2

  /// 按当前查询词/分类/Trusted 过滤搜 Nyaa，结果按 [_torrentSort] 降序。
  Future<void> _fetchTorrents() async {
    final String query = _nyaaQueryCtrl.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _loadingTorrents = true;
      _torrentsLoaded = false;
      _torrentsError = false;
      _torrentsErrorDetail = null;
    });
    NyaaClient? nyaa;
    try {
      nyaa = NyaaClient(
        client: await ref.read(appProvider).createDownloadHttpClient(),
      );
      final List<NyaaTorrent> results = await nyaa
          .search(
            query,
            category: _category,
            filter: _trustedOnly ? '2' : '0',
          )
          .timeout(kDownloadDiscoveryTimeout);
      final List<NyaaTorrent> sorted = List<NyaaTorrent>.of(results)
        ..sort(_compareTorrents);
      if (!mounted) return;
      setState(() {
        _torrents = sorted;
        _torrentsLoaded = true;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _torrentsError = true;
          _torrentsErrorDetail = error.toString();
        });
      }
    } finally {
      nyaa?.close();
      if (mounted) setState(() => _loadingTorrents = false);
    }
  }

  int _compareTorrents(NyaaTorrent a, NyaaTorrent b) =>
      compareNyaaTorrents(_torrentSort, a, b);

  String _torrentSortLabel(TorrentSortKey key) {
    switch (key) {
      case TorrentSortKey.seeders:
        return t.anime_download_sort_seeders;
      case TorrentSortKey.size:
        return t.anime_download_sort_size;
      case TorrentSortKey.date:
        return t.anime_download_sort_date;
    }
  }

  /// 切换排序键：就地重排已加载结果，不重新请求。
  void _selectTorrentSort(TorrentSortKey key) {
    if (_torrentSort == key) return;
    setState(() {
      _torrentSort = key;
      _torrents = List<NyaaTorrent>.of(_torrents)..sort(_compareTorrents);
    });
  }

  /// 自动拉 Jimaku 字幕索引（选番时）：先按 AniList id 搜、空则回退标题文本搜。
  Future<void> _fetchJimaku(AniListMedia media) async {
    await _runJimakuSearch(
      anilistId: media.id,
      queries: _jimakuFallbackQueries(media),
    );
  }

  /// 手动重搜 Jimaku 字幕：用输入框里的搜索词 + 可选集号，**纯文本搜**（不挂 AniList id，
  /// 绕开「条目未挂 id」限制，让用户改词直达）。搜完若已选种子则同步刷新其字幕命中。
  Future<void> _searchJimakuManual() async {
    final String query = _jimakuQueryCtrl.text.trim();
    if (query.isEmpty || _jimakuLoading) return;
    await _runJimakuSearch(
      anilistId: null,
      queries: <String>[query],
      episode: _parseEpisodeInput(_jimakuEpisodeCtrl.text),
    );
  }

  /// Jimaku 搜索核心（自动/手动共用）：searchEntries（先 id 后文本回退）→
  /// 显式保留全部条目供用户选择，默认加载首条 →
  /// listFiles（可按集号过滤）→ 按集索引落 [_jimakuIndex]；已选种子则重算 [_chosenSubs]。
  /// 无 key / 无条目 / 网络失败 → 空索引（徽标显示无字幕），不阻塞选种。用选番 id 做竞态
  /// 守卫：用户换番后旧结果不落到新番上。
  Future<void> _runJimakuSearch({
    required int? anilistId,
    required List<String> queries,
    int? episode,
  }) async {
    final AniListMedia? media = _selectedMedia;
    if (media == null) return;
    final int guardId = media.id;
    final String apiKey = ref.read(appProvider).jimakuApiKey.trim();
    setState(() {
      _jimakuLoading = true;
      _jimakuLoaded = false;
      _jimakuError = false;
      _jimakuNoKey = apiKey.isEmpty;
      _jimakuEntries = const <JimakuEntry>[];
      _selectedJimakuEntry = null;
      _jimakuFiles = const <JimakuFile>[];
      _jimakuIndex = JimakuEpisodeIndex.fromFiles(const <JimakuFile>[]);
      _chosenSubs = const <(int?, JimakuFile)>[];
    });
    // 无 key：不搜（无从搜），提示填 key，不当「无字幕」。
    if (apiKey.isEmpty) {
      if (mounted) {
        setState(() {
          _jimakuLoading = false;
          _jimakuLoaded = true;
        });
      }
      return;
    }
    JimakuClient? jimaku;
    try {
      jimaku = JimakuClient(
        apiKey: apiKey,
        client: await ref.read(appProvider).createDownloadHttpClient(),
      );
      // AniList id 挂靠命中最准，但 Jimaku 大量条目未挂 id（冷门/YouTube 转录番等）——
      // 空结果必须回退按文本搜，否则「其实有字幕」会被误报成「无字幕」（BUG-896）。
      // 回退逻辑收敛在 JimakuClient.searchEntries（与字幕对话框同源）。
      final List<JimakuEntry> entries = await jimaku
          .searchEntries(anilistId: anilistId, queryFallbacks: queries)
          .timeout(kDownloadDiscoveryTimeout);
      final List<JimakuFile> files = entries.isEmpty
          ? const <JimakuFile>[]
          : await jimaku
              .listFiles(entries.first.id, episode: episode)
              .timeout(kDownloadDiscoveryTimeout);
      // 用户可能已换番：结果只落到仍选中的那个番上。
      if (!mounted || _selectedMedia?.id != guardId) return;
      setState(() {
        _jimakuEntries = entries;
        _selectedJimakuEntry = entries.isEmpty ? null : entries.first;
        _jimakuFiles = files;
        _jimakuSearchEpisode = episode;
        _jimakuIndex = JimakuEpisodeIndex.fromFiles(
          files,
          preferredLanguage: _jimakuPreferredLanguage,
        );
        _jimakuLoaded = true;
        // 已选种子则同步刷新其字幕命中（手动重搜后确认阶段的字幕列表实时更新）。
        final NyaaTorrent? torrent = _selectedTorrent;
        if (torrent != null) {
          _chosenSubs = chooseSubtitlesFor(torrent, _jimakuIndex);
        }
      });
    } catch (_) {
      if (mounted && _selectedMedia?.id == guardId) {
        setState(() => _jimakuError = true);
      }
    } finally {
      jimaku?.close();
      if (mounted && _selectedMedia?.id == guardId) {
        setState(() => _jimakuLoading = false);
      }
    }
  }

  Future<void> _selectJimakuEntry(JimakuEntry entry) async {
    if (_selectedJimakuEntry?.id == entry.id || _jimakuLoading) return;
    final AniListMedia? media = _selectedMedia;
    if (media == null) return;
    final String apiKey = ref.read(appProvider).jimakuApiKey.trim();
    if (apiKey.isEmpty) return;
    setState(() {
      _selectedJimakuEntry = entry;
      _jimakuLoading = true;
      _jimakuError = false;
      _jimakuFiles = const <JimakuFile>[];
      _jimakuIndex = JimakuEpisodeIndex.fromFiles(const <JimakuFile>[]);
      _chosenSubs = const <(int?, JimakuFile)>[];
    });
    JimakuClient? jimaku;
    try {
      jimaku = JimakuClient(
        apiKey: apiKey,
        client: await ref.read(appProvider).createDownloadHttpClient(),
      );
      final List<JimakuFile> files = await jimaku
          .listFiles(entry.id, episode: _jimakuSearchEpisode)
          .timeout(kDownloadDiscoveryTimeout);
      if (!mounted || _selectedMedia?.id != media.id) return;
      setState(() {
        _jimakuFiles = files;
        _jimakuIndex = JimakuEpisodeIndex.fromFiles(
          files,
          preferredLanguage: _jimakuPreferredLanguage,
        );
        final NyaaTorrent? torrent = _selectedTorrent;
        if (torrent != null) {
          _chosenSubs = chooseSubtitlesFor(torrent, _jimakuIndex);
        }
      });
    } catch (_) {
      if (mounted && _selectedMedia?.id == media.id) {
        setState(() => _jimakuError = true);
      }
    } finally {
      jimaku?.close();
      if (mounted && _selectedMedia?.id == media.id) {
        setState(() => _jimakuLoading = false);
      }
    }
  }

  void _selectJimakuLanguage(String? language) {
    setState(() {
      _jimakuPreferredLanguage = language;
      _jimakuIndex = JimakuEpisodeIndex.fromFiles(
        _jimakuFiles,
        preferredLanguage: language,
      );
      final NyaaTorrent? torrent = _selectedTorrent;
      if (torrent != null) {
        _chosenSubs = chooseSubtitlesFor(torrent, _jimakuIndex);
      }
    });
  }

  /// 解析集号输入框：空/非法 → null（= 不按集过滤，列全部）。
  int? _parseEpisodeInput(String raw) {
    final String s = raw.trim();
    if (s.isEmpty) return null;
    return int.tryParse(s);
  }

  /// AniList id 搜不到字幕条目时，按标题文本重搜 Jimaku 的回退查询串。
  /// 顺序：日文原名（Jimaku 条目多以日文命名，命中率最高）→ 罗马字 → 英文；
  /// 去空、去重，保序。
  List<String> _jimakuFallbackQueries(AniListMedia media) {
    final List<String> out = <String>[];
    for (final String? title in <String?>[
      media.native,
      media.romaji,
      media.english,
    ]) {
      final String q = title?.trim() ?? '';
      if (q.isNotEmpty && !out.contains(q)) out.add(q);
    }
    return out;
  }

  /// 手动搜索框的标题候选，见顶层 [animeTitleOptions]。
  List<String> _titleOptions(AniListMedia media) => animeTitleOptions(media);

  /// 手动重搜 Jimaku 字幕（用户填了 key / 出错后重试）。
  Future<void> _retryJimaku() async {
    final AniListMedia? media = _selectedMedia;
    if (media != null) await _fetchJimaku(media);
  }

  void _selectCategory(String category) {
    if (_category == category) return;
    setState(() => _category = category);
    unawaited(_fetchTorrents());
  }

  void _toggleTrustedOnly(bool value) {
    setState(() => _trustedOnly = value);
    unawaited(_fetchTorrents());
  }

  // ---------------------------------------------------------------- 阶段 3

  void _selectTorrent(NyaaTorrent torrent) {
    setState(() {
      _selectedTorrent = torrent;
      _chosenSubs = chooseSubtitlesFor(torrent, _jimakuIndex);
      _includeSubs = true;
    });
  }

  void _clearSelectedTorrent() {
    setState(() {
      _selectedTorrent = null;
      _chosenSubs = const <(int?, JimakuFile)>[];
    });
  }

  /// 推送下载：暂存字幕 → 落计划 → 推 qBittorrent（失败回滚计划）→ 催一轮 tick。
  Future<void> _push({bool subscribe = false}) async {
    final AppModel appModel = ref.read(appProvider);
    // null（全新用户没进过设置）→ 默认配置（auto：桌面内置引擎，开箱即用）。
    final QbConnectionConfig config =
        effectiveTorrentConfig(appModel.qbConnectionConfig);
    final NyaaTorrent? torrent = _selectedTorrent;
    final AniListMedia? media = _selectedMedia;
    if (!_backendReady) return;
    if (torrent == null || media == null || _pushing) return;
    final AnimeDownloadPlanStore? store = appModel.animeDownloadPlanStore;
    if (store == null) {
      _snack(t.anime_download_store_unavailable);
      return;
    }
    final String planId = torrent.infoHash.trim().toLowerCase();
    if (planId.isEmpty) {
      // RSS 缺 infoHash：无法与 qb 列表比对，等于计划无法追踪，直接按失败处理。
      _snack(t.anime_download_push_failed);
      return;
    }
    // 首次下载：弹一次「上传/做种」提示（默认关上传、询问是否开启+配限速/时长/
    // 分享率）。仅内置引擎相关（外接 qb 自管上传）；展示后置 flag 不再弹。
    await maybeShowTorrentUploadConsent(context, appModel);
    if (!mounted) return;
    setState(() => _pushing = true);

    // ① 逐条下载选中的字幕到计划暂存目录（单条失败跳过该条）。
    final List<PlanSubtitle> staged = <PlanSubtitle>[];
    if (_includeSubs && _chosenSubs.isNotEmpty) {
      JimakuClient? jimaku;
      try {
        jimaku = JimakuClient(
          apiKey: appModel.jimakuApiKey.trim(),
          client: await appModel.createDownloadHttpClient(),
        );
        final Directory subsDir = store.subsDirFor(planId);
        for (final (int? episode, JimakuFile file) in _chosenSubs) {
          final Uint8List? bytes = await jimaku.downloadFile(file.url);
          if (bytes == null) continue;
          try {
            final File dest = File(p.join(subsDir.path, p.basename(file.name)))
              ..createSync(recursive: true);
            await dest.writeAsBytes(bytes);
            staged.add(PlanSubtitle(
              episode: episode,
              fileName: file.name,
              stagedPath: dest.path,
              language: detectSubtitleLanguage(file.name),
            ));
          } catch (_) {
            // 单条落盘失败跳过，不影响其余字幕与推送。
          }
        }
      } catch (_) {
        // 字幕网络失败时仍允许下载视频；订阅轮询会在代理恢复后再次尝试。
      } finally {
        jimaku?.close();
      }
    }

    // ② 落计划（先写盘再推 qb，推失败回滚删除）。
    final AnimeDownloadPlan plan = AnimeDownloadPlan(
      id: planId,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      seriesTitle: media.displayTitle,
      anilistId: media.id,
      coverUrl: media.coverUrl,
      torrentTitle: torrent.title,
      magnet: torrent.magnet,
      qbCategory: config.category,
      subtitles: staged,
    );
    await store.save(plan);

    // ③ 推种子后端（顺序下载 + 首尾块优先，支持边下边播）。按配置解析后端
    // （默认桌面走内置 libtorrent 引擎；显式外接才走 qb）——与轮询服务同一
    // 选择逻辑，不再硬编码 qb。
    final TorrentBackend backend = appModel.createTorrentBackend(config);
    bool pushed = false;
    try {
      await backend.prepareCategory(config.category);
      pushed = await backend.addTorrent(
        torrent.magnet,
        category: config.category,
        sequential: true,
        firstLastPiecePrio: true,
      );
    } finally {
      backend.close();
    }
    if (!pushed) {
      await store.delete(planId);
      if (mounted) {
        setState(() => _pushing = false);
        _snack(t.anime_download_push_failed);
      }
      return;
    }
    bool subscribed = false;
    if (subscribe) {
      final String? releaseGroup = torrent.releaseGroup?.trim();
      final int? episode = torrent.episode;
      final AnimeDownloadSubscriptionService? subscriptionService =
          appModel.animeDownloadSubscriptionService;
      if (releaseGroup != null &&
          releaseGroup.isNotEmpty &&
          episode != null &&
          !torrent.isBatch &&
          subscriptionService != null) {
        await subscriptionService.subscribe(
          AnimeDownloadSubscription.fromSelection(
            anilistId: media.id,
            seriesTitle: media.displayTitle,
            coverUrl: media.coverUrl,
            nyaaQuery: _nyaaQueryCtrl.text.trim(),
            category: _category,
            trustedOnly: _trustedOnly,
            releaseGroup: releaseGroup,
            resolution: torrent.resolution,
            startAfterEpisode: episode,
            jimakuEntryId: _includeSubs ? _selectedJimakuEntry?.id : null,
            jimakuEntryName: _includeSubs ? _selectedJimakuEntry?.name : null,
            jimakuLanguage: _includeSubs ? _jimakuPreferredLanguage : null,
          ),
        );
        subscribed = true;
      }
    }
    unawaited(appModel.animeDownloadService?.tick());
    if (!mounted) return;
    _snack(
        subscribed ? t.download_subscription_created : t.anime_download_pushed);
    // BUG-1006：embedded（下载页内联）没有对话框可关——无条件 pop 会把宿主
    // 路由（下载 tab 页/整个页面栈）弹掉。独立对话框才 pop；内联模式复位回
    // 搜番初始阶段并刷新任务区（对照 [_pushGeneric] 成功后的节奏）。
    if (!widget.embedded) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _pushing = false;
      _selectedTorrent = null;
      _chosenSubs = const <(int?, JimakuFile)>[];
      _selectedMedia = null;
      _torrents = const <NyaaTorrent>[];
      _torrentsLoaded = false;
    });
    await _reloadPlans();
  }

  // ------------------------------------------------------------ 下载任务区

  Future<void> _reloadPlans() async {
    final AnimeDownloadPlanStore? store =
        ref.read(appProvider).animeDownloadPlanStore;
    if (store == null) return;
    final List<AnimeDownloadPlan> plans = await store.loadAll();
    if (!mounted) return;
    // loadAll 按创建时间升序；展示新的在上。
    setState(() => _plans = plans.reversed.toList(growable: false));
  }

  Future<void> _refreshPlans() async {
    await _reloadPlans();
    unawaited(ref.read(appProvider).animeDownloadService?.tick());
  }

  Future<void> _deletePlan(AnimeDownloadPlan plan) async {
    final AnimeDownloadPlanStore? store =
        ref.read(appProvider).animeDownloadPlanStore;
    if (store == null) return;
    await store.delete(plan.id);
    await _reloadPlans();
  }

  /// TODO-1961-e：改名 / 移动入口。
  ///
  /// 为什么必须在 app 里做：引擎按自己记的路径读盘上传，用户在资源管理器里改名
  /// 之后 app 收不到任何通知，等下一轮轮询时文件已经不见了 —— 那种情况**永远**
  /// 救不回来。走这里则由引擎自己改（做种不断），库路径同步迁移。
  Future<void> _relocatePlan(AnimeDownloadPlan plan) async {
    final AppModel appModel = ref.read(appProvider);
    final QbConnectionConfig config =
        effectiveTorrentConfig(appModel.qbConnectionConfig);
    // 先拿这个种子的当前快照（save_path + 文件列表）：改名要文件下标与旧相对
    // 路径，移动要旧 save_path，都得从后端现问，不能猜。
    final TorrentBackend backend = appModel.createTorrentBackend(config);
    TorrentSnapshot? snapshot;
    List<TorrentFileEntry> files = const <TorrentFileEntry>[];
    try {
      for (final TorrentSnapshot t in await backend.listTorrents(
          category: config.category.isEmpty ? null : config.category)) {
        if (t.hash.toLowerCase() == plan.id.toLowerCase()) {
          snapshot = t;
          break;
        }
      }
      if (snapshot != null) files = await backend.listFiles(snapshot.hash);
    } catch (_) {
      snapshot = null;
    } finally {
      backend.close();
    }
    if (!mounted) return;
    if (snapshot == null || snapshot.savePath.isEmpty) {
      _snack(t.anime_download_relocate_no_files);
      return;
    }

    final _RelocateChoice? choice = await showDialog<_RelocateChoice>(
      context: context,
      builder: (BuildContext context) =>
          _RelocateDialog(snapshot: snapshot!, files: files),
    );
    if (choice == null || !mounted) return;

    final DownloadRelocateService service = appModel.downloadRelocateService;
    final RelocateOutcome outcome = choice.isMove
        ? await service.moveTorrent(
            infoHash: plan.id,
            currentSaveRoot: snapshot.savePath,
            newSaveRoot: choice.value,
          )
        : await service.renameFile(
            infoHash: plan.id,
            fileIndex: choice.fileIndex!,
            currentRelativePath: choice.currentRelativePath!,
            newRelativePath: choice.value,
            saveRoot: snapshot.savePath,
          );
    if (!mounted) return;
    switch (outcome.status) {
      case RelocateStatus.success:
        _snack(t.anime_download_relocate_ok(rows: '${outcome.rowsMigrated}'));
      case RelocateStatus.unchanged:
        break;
      case RelocateStatus.engineFailed:
        _snack(t.anime_download_relocate_engine_failed(
            reason: outcome.error ?? ''));
      case RelocateStatus.libraryFailed:
        _snack(t.anime_download_relocate_library_failed(
            reason: outcome.error ?? ''));
    }
    await _reloadPlans();
  }

  /// 「边下边播」：不等下载完成，立即按计划入库（qb 元数据就绪即可流式播放）。
  Future<void> _playNow(AnimeDownloadPlan plan) async {
    final bool ok =
        await ref.read(appProvider).animeDownloadService?.importNow(plan.id) ??
            false;
    if (!mounted) return;
    _snack(ok ? t.anime_download_play_now_ok : t.anime_download_play_now_fail);
    if (ok) await _reloadPlans();
  }

  // ---------------------------------------------------------------- 渲染

  /// 「去设置」：embedded 由下载页回调切页内设置面板；独立对话框（视频页入口）
  /// push 下载页并直落设置面板——两个入口都能一键走到配置，不再让新用户死路。
  void _openBackendSettings() {
    final VoidCallback? onOpenSettings = widget.onOpenSettings;
    if (onOpenSettings != null) {
      onOpenSettings();
      return;
    }
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (BuildContext context) =>
          const DownloadsPage(initialShowSettings: true),
    ));
  }

  /// qb 未配置提示条（推送按钮禁用，浏览选种不禁）+「去设置」直达按钮。
  Widget _buildQbHintBanner(ThemeData theme) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: isEinkTheme(context)
            ? Border.all(color: theme.colorScheme.outline)
            : null,
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.info_outline,
              size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              t.download_backend_not_configured,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: _openBackendSettings,
            child: Text(t.download_open_settings),
          ),
        ],
      ),
    );
  }

  /// Jimaku key 输入行：仅初始 key 为空时显示，`onChanged` 直接持久化
  /// （与 [JimakuSubtitleDialog] 的 key 落偏好范式一致）。
  Widget _buildJimakuKeyField() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: _jimakuKeyCtrl,
        decoration: InputDecoration(
          labelText: t.video_jimaku_api_key,
          helperText: t.video_jimaku_api_key_hint,
          helperMaxLines: 2,
          isDense: true,
          prefixIcon: const Icon(Icons.vpn_key, size: 18),
        ),
        obscureText: true,
        onChanged: (String value) =>
            unawaited(ref.read(appProvider).setJimakuApiKey(value.trim())),
      ),
    );
  }

  /// 小徽标 chip（分辨率/组名/体积/seeders/字幕覆盖等）。
  Widget _miniChip(
    ThemeData theme,
    String label, {
    IconData? icon,
    Color? background,
    Color? foreground,
  }) {
    final Color fg = foreground ?? theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: background ?? theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
        // eink：底色随 surface 塌缩成背景色，无边即隐形——补 1px 描边。
        border: isEinkTheme(context)
            ? Border.all(color: theme.colorScheme.outline)
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 2),
          ],
          Text(label, style: theme.textTheme.labelSmall?.copyWith(color: fg)),
        ],
      ),
    );
  }

  // ---- 阶段 1：搜番 ----

  Widget _buildAnimeSearchStage(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildGenericMagnetSection(theme),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _animeQueryCtrl,
                decoration: InputDecoration(
                  labelText: t.anime_download_search_hint,
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 18),
                ),
                onSubmitted: (_) => _searchAnime(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _searchingAnime ? null : _searchAnime,
              child: Text(t.anime_download_search),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(child: _buildAnimeResults(theme)),
      ],
    );
  }

  /// 通用下载区（折叠）：粘贴磁力链接 + 选内容类型（自动/视频/书）+ 直接下载，
  /// 不经番剧搜索流程。可下书、视频等任意种子；完成后按类型自动入库
  /// （视频→视频库、epub→阅读库）。
  Widget _buildGenericMagnetSection(ThemeData theme) {
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: theme.colorScheme.surfaceContainerHighest,
      child: ExpansionTile(
        dense: true,
        shape: const Border(),
        collapsedShape: const Border(),
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        leading: const Icon(Icons.link, size: 18),
        title: Text(t.anime_download_generic_title),
        children: <Widget>[
          TextField(
            controller: _magnetCtrl,
            minLines: 1,
            maxLines: 2,
            decoration: InputDecoration(
              labelText: t.anime_download_generic_hint,
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          _buildGenericKindRow(context),
        ],
      ),
    );
  }

  /// 内容类型分段条 + 下载按钮。
  ///
  /// BUG-1184：原本是 `Row(Expanded(SegmentedButton 三段), 下载按钮)`。下载按钮不可
  /// 压缩，分段条拿到的是「剩余宽/3」——360dp 上每段只剩约 48px，`自动/视频/书`
  /// 三个标签全被裁成半个字。这里按**估算宽度**（随文案与文字缩放变化，不写死断点）
  /// 判断放不放得下：放得下维持原来的一行；放不下就让分段条独占一行、按钮换到下一
  /// 行右对齐，两者都保持完整可读。分段条本身走 [HibikiSegmentedStrip]，即使单独
  /// 一行仍不够宽也是横向滚动而非裁字。
  Widget _buildGenericKindRow(BuildContext context) {
    final List<ButtonSegment<String>> segments = <ButtonSegment<String>>[
      ButtonSegment<String>(
        value: AnimeDownloadPlan.kindAuto,
        label: Text(t.anime_download_kind_auto),
      ),
      ButtonSegment<String>(
        value: AnimeDownloadPlan.kindVideo,
        label: Text(t.anime_download_kind_video),
      ),
      ButtonSegment<String>(
        value: AnimeDownloadPlan.kindBook,
        label: Text(t.anime_download_kind_book),
      ),
    ];
    final Widget strip = HibikiSegmentedStrip<String>(
      segments: segments,
      selected: _genericKind,
      onChanged: (String kind) {
        if (_pushingGeneric) return;
        setState(() => _genericKind = kind);
      },
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
    );
    final Widget button = FilledButton.icon(
      onPressed: (!_backendReady || _pushingGeneric) ? null : _pushGeneric,
      icon: const Icon(Icons.download, size: 18),
      label: Text(t.anime_download_generic_download),
    );

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        const double fontSize = 14.0;
        final double textScale = MediaQuery.textScalerOf(context).scale(1);
        final double stripWidth = estimateSegmentedStripWidth(
          segmentLabels: segments
              .map<String?>((ButtonSegment<String> s) =>
                  s.label is Text ? (s.label! as Text).data : null)
              .toList(growable: false),
          fontSize: fontSize,
          textScaleFactor: textScale,
        );
        // 下载按钮：图标 18 + 图标/文字间距与左右内边距合计约 46，再加标签字形宽
        // （与 estimateSegmentedStripWidth 同一套保守的 CJK 倾向估算）。
        final double buttonWidth = 46 +
            t.anime_download_generic_download.length * fontSize * textScale;
        final bool fitsOneRow = constraints.maxWidth.isFinite &&
            stripWidth + 8 + buttonWidth <= constraints.maxWidth;
        if (fitsOneRow) {
          return Row(
            children: <Widget>[
              Expanded(child: strip),
              const SizedBox(width: 8),
              button,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            strip,
            const SizedBox(height: 8),
            Align(alignment: Alignment.centerRight, child: button),
          ],
        );
      },
    );
  }

  /// 通用磁力推送：走共享 [pushGenericMagnet]（首用同意 → 解析 → 落计划 →
  /// 推后端），与独立下载页同一逻辑。
  Future<void> _pushGeneric() async {
    if (_pushingGeneric) return;
    final AppModel appModel = ref.read(appProvider);
    setState(() => _pushingGeneric = true);
    final GenericPushOutcome outcome = await pushGenericMagnet(
      context: context,
      appModel: appModel,
      magnet: _magnetCtrl.text,
      contentKind: _genericKind,
    );
    if (!mounted) return;
    setState(() => _pushingGeneric = false);
    _snack(genericPushMessage(outcome));
    if (outcome == GenericPushOutcome.ok) {
      _magnetCtrl.clear();
      await _reloadPlans();
    }
  }

  /// 出错态：一句提示 + 重试按钮（区分「出错/超时」与「真无结果」）。
  /// [detail] 是真实错误串（异常 toString），原样展示帮助定位（如握手失败 =
  /// 站点被墙）；[offerSettings] 再补一行代理提示 + 「去设置」直达下载设置。
  Widget _buildErrorRetry(
    ThemeData theme,
    String message,
    VoidCallback onRetry, {
    String? detail,
    bool offerSettings = false,
  }) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.cloud_off_outlined,
              size: 40, color: theme.colorScheme.error),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center),
          if (detail != null && detail.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Text(
                detail,
                textAlign: TextAlign.center,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
          if (offerSettings) ...<Widget>[
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Text(
                t.anime_download_search_error_proxy_hint,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(t.anime_download_retry),
              ),
              if (offerSettings) ...<Widget>[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _openBackendSettings,
                  child: Text(t.download_open_settings),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAnimeResults(ThemeData theme) {
    if (_searchingAnime) {
      return buildLoading();
    }
    if (_animeSearchError) {
      return _buildErrorRetry(
        theme,
        t.anime_download_search_failed,
        _searchAnime,
        detail: _animeSearchErrorDetail,
        offerSettings: true,
      );
    }
    if (_searchedAnime && _animeMatches.isEmpty) {
      return Center(child: Text(t.anime_download_no_results));
    }
    if (_animeMatches.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.travel_explore,
              size: 48,
              color: theme.colorScheme.outlineVariant,
            ),
            const SizedBox(height: 8),
            Text(
              t.anime_download_search_start_hint,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      itemCount: _animeMatches.length,
      itemBuilder: (BuildContext context, int i) {
        final AniListMedia media = _animeMatches[i];
        final List<String> parts = <String>[
          if (media.seasonYear != null) '${media.seasonYear}',
          if (media.episodes != null)
            t.anime_download_episode_count(count: media.episodes!),
        ];
        return ListTile(
          dense: true,
          leading: const Icon(Icons.live_tv_outlined),
          title: Text(
            media.displayTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: parts.isEmpty ? null : Text(parts.join(' · ')),
          onTap: () => _selectMedia(media),
        );
      },
    );
  }

  // ---- 阶段 2：选种 ----

  Widget _buildTorrentStage(ThemeData theme) {
    final AniListMedia media = _selectedMedia!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            IconButton(
              tooltip: t.anime_download_back,
              icon: const Icon(Icons.arrow_back, size: 20),
              onPressed: _clearSelectedMedia,
            ),
            Expanded(
              child: Text(
                media.displayTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        TextField(
          controller: _nyaaQueryCtrl,
          decoration: InputDecoration(
            labelText: t.anime_download_nyaa_query,
            isDense: true,
            suffixIcon: IconButton(
              tooltip: t.anime_download_search,
              icon: const Icon(Icons.search, size: 20),
              onPressed: _loadingTorrents ? null : _fetchTorrents,
            ),
          ),
          onSubmitted: (_) => _fetchTorrents(),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            for (final (String id, String label) in <(String, String)>[
              ('1_0', t.anime_download_category_all),
              ('1_4', t.anime_download_category_raw),
              ('1_2', t.anime_download_category_english),
              ('1_3', t.anime_download_category_non_english),
            ])
              ChoiceChip(
                label: Text(label),
                visualDensity: VisualDensity.compact,
                selected: _category == id,
                onSelected:
                    _loadingTorrents ? null : (_) => _selectCategory(id),
              ),
            FilterChip(
              label: Text(t.anime_download_trusted_only),
              visualDensity: VisualDensity.compact,
              selected: _trustedOnly,
              onSelected: _loadingTorrents ? null : _toggleTrustedOnly,
            ),
            PopupMenuButton<TorrentSortKey>(
              tooltip: t.sort_by,
              initialValue: _torrentSort,
              enabled: !_loadingTorrents,
              onSelected: _selectTorrentSort,
              itemBuilder: (BuildContext context) =>
                  <PopupMenuEntry<TorrentSortKey>>[
                for (final TorrentSortKey key in TorrentSortKey.values)
                  PopupMenuItem<TorrentSortKey>(
                    value: key,
                    child: Text(_torrentSortLabel(key)),
                  ),
              ],
              child: Chip(
                avatar: const Icon(Icons.sort, size: 18),
                label: Text('${t.sort_by}: ${_torrentSortLabel(_torrentSort)}'),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(child: _buildTorrentResults(theme)),
      ],
    );
  }

  Widget _buildTorrentResults(ThemeData theme) {
    if (_loadingTorrents) {
      return buildLoading();
    }
    if (_torrentsError) {
      return _buildErrorRetry(
        theme,
        t.anime_download_search_failed,
        _fetchTorrents,
        detail: _torrentsErrorDetail,
        offerSettings: true,
      );
    }
    if (_torrentsLoaded && _torrents.isEmpty) {
      return Center(child: Text(t.anime_download_no_results));
    }
    return ListView.builder(
      itemCount: _torrents.length,
      itemBuilder: (BuildContext context, int i) {
        final NyaaTorrent torrent = _torrents[i];
        return ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          title: Text(
            torrent.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: _torrentChips(theme, torrent),
            ),
          ),
          onTap: () => _selectTorrent(torrent),
        );
      },
    );
  }

  /// 单个种子行的徽标：分辨率/组名/体积/seeders/trusted/合集区间/字幕覆盖。
  List<Widget> _torrentChips(ThemeData theme, NyaaTorrent torrent) {
    final ColorScheme scheme = theme.colorScheme;
    final List<Widget> chips = <Widget>[];
    final String? resolution = torrent.resolution;
    if (resolution != null) chips.add(_miniChip(theme, resolution));
    final String? group = torrent.releaseGroup;
    if (group != null) chips.add(_miniChip(theme, group));
    if (torrent.sizeText.isNotEmpty) {
      chips.add(_miniChip(theme, torrent.sizeText));
    }
    chips.add(_miniChip(theme, '▲${torrent.seeders}',
        background: scheme.secondaryContainer,
        foreground: scheme.onSecondaryContainer));
    if (torrent.trusted) {
      chips.add(_miniChip(theme, t.anime_download_trusted,
          icon: Icons.verified_outlined,
          background: scheme.tertiaryContainer,
          foreground: scheme.onTertiaryContainer));
    }
    if (torrent.isBatch) {
      final (int, int)? range = torrent.episodeRange;
      final String label = range == null
          ? t.anime_download_batch
          : '${range.$1.toString().padLeft(2, '0')}'
              '-${range.$2.toString().padLeft(2, '0')}';
      chips.add(_miniChip(theme, label, icon: Icons.stacked_bar_chart));
    }
    if (_jimakuLoaded) {
      final ({int covered, int? total}) coverage =
          jimakuCoverageFor(torrent, _jimakuIndex);
      if (coverage.covered == 0) {
        chips.add(_miniChip(theme, t.anime_download_no_subs,
            foreground: scheme.outline));
      } else {
        final String label = coverage.total == null
            ? '${t.anime_download_subs_badge} ?'
            : '${t.anime_download_subs_badge} '
                '${coverage.covered}/${coverage.total}';
        chips.add(_miniChip(theme, label,
            icon: Icons.subtitles_outlined,
            background: scheme.primaryContainer,
            foreground: scheme.onPrimaryContainer));
      }
    }
    return chips;
  }

  // ---- 阶段 3：确认推送 ----

  Widget _buildConfirmStage(ThemeData theme) {
    final NyaaTorrent torrent = _selectedTorrent!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            IconButton(
              tooltip: t.anime_download_back,
              icon: const Icon(Icons.arrow_back, size: 20),
              onPressed: _pushing ? null : _clearSelectedTorrent,
            ),
            Expanded(
              child: Text(
                torrent.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        _buildJimakuManualSearch(theme),
        if (_jimakuEntries.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 148),
            child: SingleChildScrollView(
              child: JimakuEntryPicker(
                entries: _jimakuEntries,
                selectedEntryId: _selectedJimakuEntry?.id,
                enabled: !_pushing && !_jimakuLoading,
                onSelected: _selectJimakuEntry,
              ),
            ),
          ),
          const SizedBox(height: 8),
          JimakuLanguagePicker(
            selectedLanguage: _jimakuPreferredLanguage,
            enabled: !_pushing && !_jimakuLoading,
            onSelected: _selectJimakuLanguage,
          ),
        ],
        const SizedBox(height: 4),
        if (_chosenSubs.isNotEmpty)
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(t.anime_download_include_subs),
            value: _includeSubs,
            onChanged: _pushing
                ? null
                : (bool value) => setState(() => _includeSubs = value),
          ),
        Expanded(child: _buildChosenSubsList(theme)),
        const SizedBox(height: 8),
        Builder(
          builder: (BuildContext context) {
            final NyaaTorrent torrent = _selectedTorrent!;
            final String? group = torrent.releaseGroup?.trim();
            final bool canSubscribe = !torrent.isBatch &&
                torrent.episode != null &&
                group != null &&
                group.isNotEmpty &&
                ref.read(appProvider).animeDownloadSubscriptionService != null;
            final Widget progressIcon = _pushing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    OutlinedButton.icon(
                      onPressed: (_qbMissing || _pushing || !canSubscribe)
                          ? null
                          : () => _push(subscribe: true),
                      icon: const Icon(Icons.subscriptions_outlined),
                      label: Text(t.download_subscription_download_and_create),
                    ),
                    FilledButton.icon(
                      onPressed:
                          (_qbMissing || _pushing) ? null : () => _push(),
                      icon: progressIcon,
                      label: Text(t.anime_download_push),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  canSubscribe
                      ? t.download_subscription_choice_hint(
                          group: group,
                          resolution: torrent.resolution ?? '-',
                        )
                      : t.download_subscription_unavailable_hint,
                  textAlign: TextAlign.end,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (canSubscribe && _selectedJimakuEntry != null)
                  Text(
                    '${t.video_jimaku_source}: '
                    '${_selectedJimakuEntry!.name}'
                    '${_jimakuPreferredLanguage == null ? '' : ' · '
                        '${jimakuLanguageLabel(_jimakuPreferredLanguage!)}'}',
                    textAlign: TextAlign.end,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  /// 字幕手动搜索行：可编辑搜索词（预填罗马字，下拉可换日文原名/英文名）+
  /// 集号 + 搜索按钮。自动搜不到或命中错版时，用户改词/填集号重搜 Jimaku
  /// （i18n 复用视频字幕对话框同款 key）。
  Widget _buildJimakuManualSearch(ThemeData theme) {
    // BUG-1184：集号框宽度由 label 实测宽度决定，上限取整行宽的四成——所以需要
    // 先拿到整行可用宽。
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) =>
          _buildJimakuManualSearchRow(theme, constraints.maxWidth),
    );
  }

  Widget _buildJimakuManualSearchRow(ThemeData theme, double rowWidth) {
    final AniListMedia? media = _selectedMedia;
    final List<String> titleOptions =
        media == null ? const <String>[] : _titleOptions(media);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: TextField(
            controller: _jimakuQueryCtrl,
            decoration: InputDecoration(
              labelText: t.video_jimaku_query,
              isDense: true,
              // 标题候选下拉（≥2 个才显示）：罗马字/日文原名/英文名一键切换。
              suffixIcon: titleOptions.length < 2
                  ? null
                  : PopupMenuButton<String>(
                      tooltip: t.video_jimaku_query,
                      icon: const Icon(Icons.arrow_drop_down),
                      onSelected: (String value) =>
                          _jimakuQueryCtrl.text = value,
                      itemBuilder: (BuildContext context) =>
                          <PopupMenuEntry<String>>[
                        for (final String title in titleOptions)
                          PopupMenuItem<String>(
                            value: title,
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
            ),
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _searchJimakuManual(),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: jimakuEpisodeFieldWidth(
            context,
            t.video_jimaku_episode,
            rowWidth: rowWidth,
          ),
          child: TextField(
            controller: _jimakuEpisodeCtrl,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: t.video_jimaku_episode,
              isDense: true,
            ),
            onSubmitted: (_) => _searchJimakuManual(),
          ),
        ),
        IconButton(
          tooltip: t.anime_download_search,
          icon: const Icon(Icons.search, size: 20),
          onPressed: _jimakuLoading ? null : _searchJimakuManual,
        ),
      ],
    );
  }

  Widget _buildChosenSubsList(ThemeData theme) {
    // 字幕状态区分（不再「没搜就说无字幕」）：搜索中 / 缺 key / 出错 / 空。
    if (_jimakuLoading) {
      return buildLoading();
    }
    if (_jimakuNoKey) {
      return Center(
        child: Text(
          t.anime_download_subs_need_key,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
      );
    }
    if (_jimakuError) {
      return _buildErrorRetry(
          theme, t.anime_download_subs_failed, _retryJimaku);
    }
    if (_chosenSubs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              t.anime_download_no_subs,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _retryJimaku,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(t.anime_download_retry),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      itemCount: _chosenSubs.length,
      itemBuilder: (BuildContext context, int i) {
        final (int? episode, JimakuFile file) = _chosenSubs[i];
        final String? language = detectSubtitleLanguage(file.name);
        return ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: SizedBox(
            width: 36,
            child: Text(
              episode == null ? '—' : '#$episode',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelMedium,
            ),
          ),
          title: Text(
            file.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          trailing: language == null
              ? null
              : _miniChip(theme, jimakuLanguageLabel(language)),
        );
      },
    );
  }

  // ---- 下载任务折叠区 ----

  Widget _buildTasksSection(ThemeData theme) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      shape: const Border(),
      collapsedShape: const Border(),
      title: Text(
        '${t.anime_download_tasks} (${_plans.length})',
        style: theme.textTheme.titleSmall,
      ),
      onExpansionChanged: (bool expanded) {
        if (expanded) unawaited(_reloadPlans());
      },
      children: <Widget>[
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 200),
          child: _plans.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    t.anime_download_no_tasks,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: _plans.length,
                  itemBuilder: (BuildContext context, int i) =>
                      _buildPlanRow(theme, _plans[i]),
                ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: _refreshPlans,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(t.anime_download_refresh),
          ),
        ),
      ],
    );
  }

  /// 重试失败的计划：重推同一 magnet 走现有推送路径（prepareCategory +
  /// addTorrent 顺序/首尾块优先），成功后计划复位 downloading（重置计时，
  /// torrent-missing 超时从头算）。addTorrent 报失败但种子已在后端列表
  /// （入库失败类重试的常态——重复添加被后端拒绝）也算在下，交回轮询重走完成流程。
  Future<void> _retryPlan(AnimeDownloadPlan plan) async {
    final AppModel appModel = ref.read(appProvider);
    if (!torrentBackendReady(appModel)) {
      _snack(t.download_backend_not_configured);
      return;
    }
    final AnimeDownloadPlanStore? store = appModel.animeDownloadPlanStore;
    if (store == null) {
      _snack(t.anime_download_store_unavailable);
      return;
    }
    final QbConnectionConfig config =
        effectiveTorrentConfig(appModel.qbConnectionConfig);
    final TorrentBackend backend = appModel.createTorrentBackend(config);
    bool pushed = false;
    try {
      await backend.prepareCategory(config.category);
      pushed = await backend.addTorrent(
        plan.magnet,
        category: config.category,
        sequential: true,
        firstLastPiecePrio: true,
      );
      if (!pushed) {
        final List<TorrentSnapshot> torrents = await backend.listTorrents(
          category: config.category.isEmpty ? null : config.category,
        );
        pushed = torrents.any((TorrentSnapshot t) =>
            t.hash.toLowerCase() == plan.id.toLowerCase());
      }
    } finally {
      backend.close();
    }
    if (!pushed) {
      _snack(t.anime_download_push_failed);
      return;
    }
    await store.save(plan.copyWith(
      status: AnimeDownloadPlan.statusDownloading,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    ));
    unawaited(appModel.animeDownloadService?.tick());
    _snack(t.anime_download_pushed);
    await _reloadPlans();
  }

  /// 单条任务行（[HibikiListItem] compact，自动接焦点系统）。
  ///
  /// - 下载中：轮询服务透传的真实进度（[AnimeDownloadService.downloadProgress]）
  ///   渲染确定进度环 + 行内百分比；进度未知（服务未接/后端未上列表）回退
  ///   不定进度环。eink 一律静态图标（转圈=墨水屏残影）。
  /// - 失败：failReason 直接显示为 subtitle 第二行（error 色，触屏/键盘/手柄
  ///   可读，不再只藏 hover Tooltip）+ trailing 重试按钮。
  Widget _buildPlanRow(ThemeData theme, AnimeDownloadPlan plan) {
    if (plan.status == AnimeDownloadPlan.statusDownloading) {
      final AnimeDownloadService? service =
          ref.read(appProvider).animeDownloadService;
      if (service != null) {
        return ValueListenableBuilder<Map<String, double>>(
          valueListenable: service.downloadProgress,
          builder: (BuildContext context, Map<String, double> progress, _) =>
              _buildPlanRowInner(theme, plan, progress[plan.id]),
        );
      }
    }
    return _buildPlanRowInner(theme, plan, null);
  }

  Widget _buildPlanRowInner(
      ThemeData theme, AnimeDownloadPlan plan, double? progress) {
    final ColorScheme scheme = theme.colorScheme;
    final bool eink = isEinkTheme(context);
    final bool downloading = plan.status == AnimeDownloadPlan.statusDownloading;
    final bool failed = plan.status == AnimeDownloadPlan.statusFailed;
    final Widget statusIcon = switch (plan.status) {
      AnimeDownloadPlan.statusImported =>
        Icon(Icons.check_circle_outline, size: 20, color: scheme.primary),
      AnimeDownloadPlan.statusFailed =>
        Icon(Icons.error_outline, size: 20, color: scheme.error),
      _ => eink
          ? const Icon(Icons.downloading_outlined, size: 20)
          : SizedBox(
              width: 20,
              height: 20,
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  value: progress,
                ),
              ),
            ),
    };
    final String? progressText = (downloading && progress != null)
        ? '${(progress * 100).toStringAsFixed(0)}%'
        : null;
    final String? failReason =
        (failed && (plan.failReason?.isNotEmpty ?? false))
            ? plan.failReason
            : null;
    return HibikiListItem(
      density: HibikiListDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      subtitleMaxLines: 3,
      // BUG-1184：番剧名 + 种子名都很长，而这一行右侧还挂着最多 3 个操作按钮，窄屏
      // 上标题只剩百来像素。行高自由（在可滚动列表里，只有 minHeight 下限），放宽到
      // 两行；种子名同样从死板的单行放宽到两行。
      titleMaxLines: 2,
      leading: statusIcon,
      title: Text(plan.seriesTitle),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            plan.torrentTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          if (progressText != null)
            Text(
              progressText,
              maxLines: 1,
              style: theme.textTheme.bodySmall,
            ),
          if (failReason != null)
            Text(
              failReason,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (downloading)
            HibikiIconButton(
              tooltip: t.anime_download_play_now,
              icon: Icons.play_circle_outline,
              size: 20,
              onTap: () => _playNow(plan),
            ),
          if (failed)
            HibikiIconButton(
              tooltip: t.anime_download_retry,
              icon: Icons.refresh,
              size: 20,
              onTap: () => _retryPlan(plan),
            ),
          HibikiIconButton(
            tooltip: t.anime_download_relocate,
            icon: Icons.drive_file_move_outline,
            size: 20,
            onTap: () => _relocatePlan(plan),
          ),
          HibikiIconButton(
            tooltip: t.anime_download_delete,
            icon: Icons.delete_outline,
            size: 20,
            onTap: () => _deletePlan(plan),
          ),
        ],
      ),
    );
  }

  Widget _buildTasksPage(ThemeData theme) {
    return RefreshIndicator(
      onRefresh: _refreshPlans,
      child: _plans.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(24),
              children: <Widget>[
                const SizedBox(height: 72),
                Icon(
                  Icons.downloading_outlined,
                  size: 48,
                  color: theme.colorScheme.outline,
                ),
                const SizedBox(height: 16),
                Text(
                  t.anime_download_no_tasks,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium,
                ),
              ],
            )
          : ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              itemCount: _plans.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (BuildContext context, int index) =>
                  _buildPlanRow(theme, _plans[index]),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Widget stage;
    if (_selectedMedia == null) {
      stage = _buildAnimeSearchStage(theme);
      if (widget.tasksOnly) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: _buildTasksPage(theme),
        );
      }
    } else if (_selectedTorrent == null) {
      stage = _buildTorrentStage(theme);
    } else {
      stage = _buildConfirmStage(theme);
    }

    // 内联模式：直接铺进「下载」页（Scaffold body 给有界高度，Expanded 分配空间、
    // 各阶段内部 ListView 正常滚动）。无外框、无标题（页头已有）、无取消。
    if (widget.embedded) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (_qbMissing) _buildQbHintBanner(theme),
            if (_showJimakuKeyField) _buildJimakuKeyField(),
            Expanded(child: stage),
            if (widget.showTasks) const SizedBox(height: 4),
            if (widget.showTasks) _buildTasksSection(theme),
          ],
        ),
      );
    }

    // scrollable:false：maxHeight 给整个对话框有界高度，Flexible 正常分配空间、
    // 各阶段内部 ListView 正常滚动（同 JimakuSubtitleDialog 的 BUG-279 不变量）。
    return HibikiDialogFrame(
      maxWidth: 720,
      maxHeightFactor: 0.86,
      scrollable: false,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(t.anime_download_title, style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
          if (_qbMissing) _buildQbHintBanner(theme),
          if (_showJimakuKeyField) _buildJimakuKeyField(),
          Flexible(child: stage),
          if (widget.showTasks) const SizedBox(height: 4),
          if (widget.showTasks) _buildTasksSection(theme),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(t.dialog_cancel),
            ),
          ),
        ],
      ),
    );
  }
}

/// TODO-1961-e：用户在改名/移动对话框里做出的选择。
class _RelocateChoice {
  const _RelocateChoice.move(this.value)
      : isMove = true,
        fileIndex = null,
        currentRelativePath = null;

  const _RelocateChoice.rename({
    required this.value,
    required int this.fileIndex,
    required String this.currentRelativePath,
  }) : isMove = false;

  /// true = 移动整个种子到 [value]（新 save_path）；false = 把某个文件改成 [value]。
  final bool isMove;

  /// 移动 = 目标目录绝对路径；改名 = 种子内新相对路径。
  final String value;

  /// 改名时的文件下标（移动时为 null）。
  final int? fileIndex;

  /// 改名时该文件当前的种子内相对路径（移动时为 null）。
  final String? currentRelativePath;
}

/// 改名 / 移动对话框：上半是「移动整个任务到某目录」，下半是逐文件改名。
///
/// 刻意**不**做成两个入口：用户想的是「整理这个下载」，移动和改名是同一件事的
/// 两个面，放一个弹窗里他一眼能看到自己有哪些文件、现在在哪。
class _RelocateDialog extends StatefulWidget {
  const _RelocateDialog({required this.snapshot, required this.files});

  final TorrentSnapshot snapshot;
  final List<TorrentFileEntry> files;

  @override
  State<_RelocateDialog> createState() => _RelocateDialogState();
}

class _RelocateDialogState extends State<_RelocateDialog> {
  /// 逐文件的改名输入框（key = 文件下标），初值 = 当前种子内相对路径。
  late final Map<int, TextEditingController> _controllers =
      <int, TextEditingController>{
    for (final TorrentFileEntry f in widget.files)
      f.index: TextEditingController(text: f.name),
  };

  @override
  void dispose() {
    for (final TextEditingController c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDestination() async {
    final String? picked = await FilePicker.platform.getDirectoryPath(
      dialogTitle: t.anime_download_relocate_pick_folder,
    );
    if (picked == null || picked.trim().isEmpty || !mounted) return;
    Navigator.pop(context, _RelocateChoice.move(picked.trim()));
  }

  void _submitRename(TorrentFileEntry file) {
    final String next = _controllers[file.index]?.text.trim() ?? '';
    if (next.isEmpty) return;
    Navigator.pop(
      context,
      _RelocateChoice.rename(
        value: next,
        fileIndex: file.index,
        currentRelativePath: file.name,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return AlertDialog(
      title: Text(t.anime_download_relocate),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // 为什么必须在 app 里改名，而不是去资源管理器 —— 说清楚，否则用户
              // 改完再来问「怎么做种断了」。
              Text(
                t.anime_download_relocate_hint,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
              const SizedBox(height: 16),
              Text(t.anime_download_relocate_move_title,
                  style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              Text(widget.snapshot.savePath, style: theme.textTheme.bodySmall),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  onPressed: _pickDestination,
                  icon: const Icon(Icons.folder_open_outlined, size: 18),
                  label: Text(t.anime_download_relocate_pick_folder),
                ),
              ),
              if (widget.files.isNotEmpty) ...<Widget>[
                const Divider(height: 28),
                Text(t.anime_download_relocate_rename_title,
                    style: theme.textTheme.titleSmall),
                const SizedBox(height: 6),
                for (final TorrentFileEntry file in widget.files)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: TextField(
                            controller: _controllers[file.index],
                            decoration: const InputDecoration(
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                            onSubmitted: (_) => _submitRename(file),
                          ),
                        ),
                        const SizedBox(width: 8),
                        HibikiIconButton(
                          tooltip: t.anime_download_relocate_rename_title,
                          icon: Icons.drive_file_rename_outline,
                          size: 20,
                          onTap: () => _submitRename(file),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.dialog_cancel),
        ),
      ],
    );
  }
}
