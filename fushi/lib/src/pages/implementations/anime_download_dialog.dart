import 'dart:async' show unawaited;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/media/torrent/anime_download_config.dart';
import 'package:fushi/src/media/torrent/anime_download_matching.dart';
import 'package:fushi/src/media/torrent/anime_download_plan.dart';
import 'package:fushi/src/media/torrent/anime_download_service.dart';
import 'package:fushi/src/media/torrent/anime_download_subscription.dart';
import 'package:fushi/src/media/torrent/download_network_proxy.dart'
    show kDownloadDiscoveryTimeout;
import 'package:fushi/src/media/torrent/download_relocate_service.dart';
import 'package:fushi/src/media/torrent/nyaa_client.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:fushi/src/media/torrent/torrent_task_display.dart';
import 'package:fushi/src/media/video/anilist_client.dart';
import 'package:fushi/src/media/video/jimaku_client.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/jimaku_api_key_field.dart';
import 'package:fushi/src/pages/implementations/jimaku_entry_picker.dart';
import 'package:fushi/src/pages/implementations/download_actions.dart';
import 'package:fushi/src/pages/implementations/downloads_page.dart';
import 'package:fushi/src/pages/implementations/torrent_detail_dialog.dart';
import 'package:fushi/src/pages/fushi_page_placeholders.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';

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

class _TorrentSearchSnapshot {
  const _TorrentSearchSnapshot({
    required this.generation,
    required this.query,
    required this.category,
    required this.trustedOnly,
  });

  final int generation;
  final String query;
  final String category;
  final bool trustedOnly;
}

class AnimeDownloadDialog extends ConsumerStatefulWidget {
  const AnimeDownloadDialog({
    super.key,
    this.embedded = false,
    this.showTasks = true,
    this.tasksOnly = false,
    this.onOpenSettings,
    this.initialSearchQuery,
    this.initialMedia,
    this.initialEpisode,
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

  /// 初始搜番词（TODO-2485/2484 UI）：非空时预填搜索框并自动发起一次 AniList
  /// 搜索（合集详情页「去下载」等入口预填标题直达）。null = 既有入口行为零变化。
  final String? initialSearchQuery;

  /// 初始即选中的番（TODO-2485）：合集已绑定 anilistId 时由详情页本地合成
  /// （id + 合集名，零网络）直达选种段——与 [debugInitialMedia] 不同，本参数走
  /// **真实** [_selectMedia] 路径（预填查询词 + 并行拉 Nyaa/Jimaku）。
  final AniListMedia? initialMedia;

  /// 与 [initialMedia] 联用的预填集号：写进 Jimaku 集号框（字幕按集过滤）。
  /// null = 不过滤（整季）。
  final int? initialEpisode;

  /// 仅测试：初始即选中的番（跳过 AniList 网络搜索直达选种/确认阶段）。
  final AniListMedia? debugInitialMedia;

  /// 仅测试：初始即选中的种子（与 [debugInitialMedia] 联用直达确认推送阶段）。
  final NyaaTorrent? debugInitialTorrent;

  @override
  ConsumerState<AnimeDownloadDialog> createState() =>
      _AnimeDownloadDialogState();
}

class _AnimeDownloadDialogState extends ConsumerState<AnimeDownloadDialog>
    with FushiPagePlaceholders<AnimeDownloadDialog> {
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

  /// 最近一次真正发起字幕搜索时的输入框条件（见 [_currentJimakuSearchInput]）。
  /// 与当前输入框不一致 = 用户改了番剧名/集号但还没搜，搜索按钮据此强调。
  String _appliedJimakuSearch = '';

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
  int _torrentRequestGeneration = 0;
  NyaaClient? _activeNyaaClient;
  _TorrentSearchSnapshot? _appliedTorrentSearch;
  String _category = '1_0';
  bool _trustedOnly = false;
  TorrentSortKey _torrentSort = TorrentSortKey.seeders;
  List<JimakuEntry> _jimakuEntries = const <JimakuEntry>[];
  JimakuEntry? _selectedJimakuEntry;

  /// 用户在 [JimakuEntryPicker] 里**手动**选中过的条目 id（自动选首条不写这里）。
  ///
  /// 「用户手选过」= 他不认可自动选的那条。重搜（换番剧名/改集号）后必须优先沿用
  /// 它，而不是无条件重置成 `entries.first` 把用户的选择静默冲掉。按 id 匹配而非
  /// 下标——重搜的结果集顺序和长度都会变，下标是错的身份。换番（[_selectMedia]）
  /// 才清空：那是另一部番，旧手选没有意义。
  int? _userPickedJimakuEntryId;
  List<JimakuFile> _jimakuFiles = const <JimakuFile>[];
  String? _jimakuPreferredLanguage;
  int? _jimakuSearchEpisode;
  JimakuEpisodeIndex _jimakuIndex = JimakuEpisodeIndex.fromFiles(
    const <JimakuFile>[],
  );
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
    // 语言预选沿用设置页的默认字幕语言（此前恒为「全部」，与字幕对话框的语言记忆
    // 各行其是）。用户在本对话框里改选仍只影响本次。
    _jimakuPreferredLanguage = appModel.jimakuDefaultLanguageOrNull;
    // 仅测试：直达指定阶段（绕开 AniList/Nyaa 网络搜索）。
    final AniListMedia? debugMedia = widget.debugInitialMedia;
    if (debugMedia != null) {
      _selectedMedia = debugMedia;
      // 与真实点选路径同口径预填查询词（罗马字），测试直达时行为一致。
      _prefillQueriesFor(debugMedia);
      final NyaaTorrent? debugTorrent = widget.debugInitialTorrent;
      if (debugTorrent != null) {
        _selectedTorrent = debugTorrent;
        _chosenSubs = _chooseSubsFor(debugTorrent);
      }
    }
    // 初始上下文（合集详情页入口，TODO-2485）。二选一：有 initialMedia（合集已
    // 绑 anilistId）→ post-frame 走真实 _selectMedia 直达选种段；否则有初始搜番
    // 词 → 预填并自动搜一次。都 post-frame：两条路径里的 setState 不能在
    // initState 同步触发。
    final AniListMedia? seedMedia = widget.initialMedia;
    final String? seedQuery = widget.initialSearchQuery?.trim();
    if (_selectedMedia == null && seedMedia != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(
            _selectMedia(seedMedia, presetEpisode: widget.initialEpisode),
          );
        }
      });
    } else if (_selectedMedia == null &&
        seedQuery != null &&
        seedQuery.isNotEmpty) {
      _animeQueryCtrl.text = seedQuery;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_searchAnime());
      });
    }
    unawaited(_reloadPlans());
  }

  @override
  void dispose() {
    _torrentRequestGeneration++;
    _activeNyaaClient?.close();
    _activeNyaaClient = null;
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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
    // 预填即将由选番自动搜使用，视作「已应用」，搜索按钮不该一进来就报待生效。
    _appliedJimakuSearch = _currentJimakuSearchInput();
  }

  /// 输入框当前的字幕搜索条件（查询词 + 集号）。与 [_appliedJimakuSearch] 比对，
  /// 得出「输入框改了但还没搜」。
  String _currentJimakuSearchInput() =>
      '${_jimakuQueryCtrl.text.trim()}|${_jimakuEpisodeCtrl.text.trim()}';

  /// 点选某番：进入选种阶段，并行拉 Nyaa 种子与 Jimaku 字幕索引。
  /// Jimaku 空结果/无 key 不阻塞选种，只是徽标显示无字幕。
  Future<void> _selectMedia(AniListMedia media, {int? presetEpisode}) async {
    _prefillQueriesFor(media);
    // 预填集号（「下载本集」/「补齐缺集」入口）：写进 Jimaku 集号框（按集过滤
    // 字幕），并视作已应用——预填即将被本次自动搜索使用。
    if (presetEpisode != null) {
      _jimakuEpisodeCtrl.text = '$presetEpisode';
      _appliedJimakuSearch = _currentJimakuSearchInput();
    }
    setState(() {
      _selectedMedia = media;
      _selectedTorrent = null;
      _chosenSubs = const <(int?, JimakuFile)>[];
      _torrents = const <NyaaTorrent>[];
      _torrentsLoaded = false;
      _jimakuEntries = const <JimakuEntry>[];
      _selectedJimakuEntry = null;
      // 换番：旧番的手选条目对新番没有意义，清掉。
      _userPickedJimakuEntryId = null;
      _jimakuFiles = const <JimakuFile>[];
      _jimakuPreferredLanguage = null;
      _jimakuSearchEpisode = null;
      _jimakuIndex = JimakuEpisodeIndex.fromFiles(const <JimakuFile>[]);
      _jimakuLoaded = false;
    });
    await Future.wait(<Future<void>>[_fetchTorrents(), _fetchJimaku(media)]);
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
    final _TorrentSearchSnapshot request = _TorrentSearchSnapshot(
      generation: ++_torrentRequestGeneration,
      query: query,
      category: _category,
      trustedOnly: _trustedOnly,
    );
    _activeNyaaClient?.close();
    _activeNyaaClient = null;
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
      if (!mounted || request.generation != _torrentRequestGeneration) {
        return;
      }
      _activeNyaaClient = nyaa;
      final List<NyaaTorrent> results = await nyaa
          .search(
            request.query,
            category: request.category,
            filter: request.trustedOnly ? '2' : '0',
          )
          .timeout(kDownloadDiscoveryTimeout);
      final List<NyaaTorrent> sorted = List<NyaaTorrent>.of(results)
        ..sort(_compareTorrents);
      if (!mounted || request.generation != _torrentRequestGeneration) return;
      setState(() {
        _torrents = sorted;
        _torrentsLoaded = true;
        _appliedTorrentSearch = request;
      });
    } catch (error) {
      if (mounted && request.generation == _torrentRequestGeneration) {
        setState(() {
          _torrentsError = true;
          _torrentsErrorDetail = error.toString();
        });
      }
    } finally {
      nyaa?.close();
      if (identical(_activeNyaaClient, nyaa)) _activeNyaaClient = null;
      if (mounted && request.generation == _torrentRequestGeneration) {
        setState(() => _loadingTorrents = false);
      }
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
  /// 集号框非空（「下载本集」/「补齐缺集」经 [_selectMedia] 的 presetEpisode
  /// 预填）则按集过滤；常规选番路径 [_prefillQueriesFor] 刚清空过它 → null =
  /// 旧行为不过滤，零变化。
  Future<void> _fetchJimaku(AniListMedia media) async {
    await _runJimakuSearch(
      anilistId: media.id,
      queries: _jimakuFallbackQueries(media),
      episode: _parseEpisodeInput(_jimakuEpisodeCtrl.text),
    );
  }

  /// 手动重搜 Jimaku 字幕：用输入框里的搜索词 + 可选集号，**纯文本搜**（不挂 AniList id，
  /// 绕开「条目未挂 id」限制，让用户改词直达）。搜完若已选种子则同步刷新其字幕命中。
  Future<void> _searchJimakuManual() async {
    final String query = _jimakuQueryCtrl.text.trim();
    if (query.isEmpty || _jimakuLoading) return;
    setState(() => _appliedJimakuSearch = _currentJimakuSearchInput());
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
      // 用户手选过某条目 → 他不认可自动选的那条。新结果里还有它就沿用（按 id
      // 匹配，不是按下标——重搜的结果集顺序/长度都会变），只有它彻底不在新结果里
      // 才回退首条。此前无条件重置成 `entries.first`，换个番剧名重搜就把用户的
      // 手选静默冲掉。必须在 listFiles 之前定下目标，否则拉的是首条的文件。
      final JimakuEntry? target = _resolveJimakuEntryFor(
        entries,
        torrent: _selectedTorrent,
      );
      final List<JimakuFile> files = target == null
          ? const <JimakuFile>[]
          : await jimaku
              .listFiles(target.id, episode: episode)
              .timeout(kDownloadDiscoveryTimeout);
      // 用户可能已换番：结果只落到仍选中的那个番上。
      if (!mounted || _selectedMedia?.id != guardId) return;
      setState(() {
        _jimakuEntries = entries;
        _selectedJimakuEntry = target;
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
          _chosenSubs = _chooseSubsFor(torrent);
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

  /// 挑选随下载暂存的字幕清单。**所有调用点都必须走这里**，别直接调
  /// [chooseSubtitlesFor]：整季包的条数上界要用当前选中番的应有集数
  /// （[AniListMedia.episodes]）收敛，徽标（[_jimakuCoverageFor]）与确认页列表
  /// 必须喂同一个值，否则「列表说 24 条、点进去 12 条」。
  List<(int?, JimakuFile)> _chooseSubsFor(NyaaTorrent torrent) =>
      chooseSubtitlesFor(
        torrent,
        _jimakuIndex,
        seriesEpisodeCount: _selectedMedia?.episodes,
      );

  /// 整季包的字幕集号**未经核对**——不能画成「有字幕」的确定态。
  ///
  /// 整季包（[TorrentEpisodeScopeKind.season]）标题只写季号/`Complete`，不写集号
  /// 区间，所以本层只能拿字幕侧的集号去配视频侧的集号（落位层
  /// `pairSubtitlesToVideos` 要求集号严格相等）。这里有一整类静默错配：
  /// S2 整季包内的视频文件名是 01-12，而 Jimaku 条目按**绝对集号**编到 13-24，
  /// 或自动选中的首条根本是别的季 → 集号照样「相等」，配上的却是错季字幕，
  /// UI 还显示「有字幕」。改前 season 类一条不给，所以这是从「没有」变成
  /// 「错的且看起来对」，必须显式降级成不确定态。
  ///
  /// 「或自动选中的首条根本是别的季」这一支现在**能测出来了**（第二个判据）：
  /// 当前加载的条目季号与本行种子的季号冲突时，同样退成不确定态。选番阶段还没
  /// 选种，无从在选中前替换条目，但至少不把它画成「字幕齐了」。
  /// range / single 类的集号来自种子标题自身，不属第一个判据。
  bool _subtitleEpisodesUnverified(NyaaTorrent torrent) {
    final List<(int?, JimakuFile)> subs = _chooseSubsFor(torrent);
    if (subs.isEmpty) return false;
    final JimakuEntry? entry = _selectedJimakuEntry;
    if (entry != null &&
        jimakuEntrySeasonConflicts(
          entry: entry,
          torrentSeason: torrent.season,
          anilistId: _selectedMedia?.id,
        )) {
      return true;
    }
    return torrentEpisodeScope(torrent).kind ==
            TorrentEpisodeScopeKind.season &&
        subs.any(((int?, JimakuFile) e) => e.$1 != null);
  }

  /// 字幕覆盖度徽标，与 [_chooseSubsFor] 同源（同一 `seriesEpisodeCount`）。
  ({int covered, int? total}) _jimakuCoverageFor(NyaaTorrent torrent) =>
      jimakuCoverageFor(
        torrent,
        _jimakuIndex,
        seriesEpisodeCount: _selectedMedia?.episodes,
      );

  /// 重搜/选种后该选中哪条字幕来源。纯查找，不改 state；决策收敛在纯函数
  /// [resolveJimakuEntry]（用户手选优先 → 首条季号不冲突的 → 都冲突则 null）。
  ///
  /// [torrent] 已选中时才有包的季号可比；选番阶段还没选种（null）→ 季号校验
  /// 天然是 no-op，行为与改前完全一致（回退首条）。
  JimakuEntry? _resolveJimakuEntryFor(
    List<JimakuEntry> entries, {
    NyaaTorrent? torrent,
  }) =>
      resolveJimakuEntry(
        entries,
        userPickedEntryId: _userPickedJimakuEntryId,
        torrentSeason: torrent?.season,
        anilistId: _selectedMedia?.id,
      );

  /// 自动选中被季号校验拦下：没手选过、有候选条目，但没有一条季号对得上 [torrent]。
  /// 纯派生（不另存 state，避免与 [_selectedJimakuEntry] 漂开）。
  bool _jimakuSeasonBlockedFor(NyaaTorrent torrent) =>
      _jimakuLoaded &&
      _jimakuEntries.isNotEmpty &&
      _resolveJimakuEntryFor(_jimakuEntries, torrent: torrent) == null;

  Future<void> _selectJimakuEntry(JimakuEntry entry) async {
    if (_selectedJimakuEntry?.id == entry.id || _jimakuLoading) return;
    // 记下「用户手选过这一条」，供重搜时优先沿用、并让季号校验对它放行
    // （见 [resolveJimakuEntry]）。**只有这条路径**能置位。
    _userPickedJimakuEntryId = entry.id;
    await _loadJimakuFilesFor(entry);
  }

  /// 切到条目 [entry] 并拉它的文件列表 → 重建索引 → 刷新已选种子的字幕命中。
  /// 手选（[_selectJimakuEntry]）与选种后的季号复核（[_selectTorrent]）共用。
  Future<void> _loadJimakuFilesFor(JimakuEntry entry) async {
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
          _chosenSubs = _chooseSubsFor(torrent);
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
        _chosenSubs = _chooseSubsFor(torrent);
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
    // 选中种子这一刻才知道包的季号 → 复核自动选中的字幕条目。选番阶段
    // （[_runJimakuSearch]）手上还没有种子，只能无条件取首条；那条首条可能
    // 是别的季，落位层的「集号严格相等」拦不住 S1 条目 × S2 包（集号照样相等）。
    final JimakuEntry? previous = _selectedJimakuEntry;
    final JimakuEntry? target = _resolveJimakuEntryFor(
      _jimakuEntries,
      torrent: torrent,
    );
    final bool switched = target?.id != previous?.id;
    setState(() {
      _selectedTorrent = torrent;
      if (switched) {
        // 旧条目的文件/索引属于错季条目，先清干净再按新目标重建。
        _selectedJimakuEntry = target;
        _jimakuFiles = const <JimakuFile>[];
        _jimakuIndex = JimakuEpisodeIndex.fromFiles(const <JimakuFile>[]);
      }
      _chosenSubs = _chooseSubsFor(torrent);
      _includeSubs = true;
    });
    if (switched && target != null && !_jimakuLoading) {
      unawaited(_loadJimakuFilesFor(target));
    }
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
    final QbConnectionConfig config = effectiveTorrentConfig(
      appModel.qbConnectionConfig,
    );
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

    // ① 字幕**不在这一刻下载**（BUG-1206）。此刻手上只有 Nyaa 标题，包里到底
    // 有哪些文件要等种子 add 之后引擎给元数据才知道；照标题猜集号会把绝对编号
    // 条目的字幕配到错季上，还看起来「配好了」。这里只把**意图**（取哪个
    // Jimaku 条目、优先什么语言）记进计划，真正的反查交给完成钩子
    // （`AnimeDownloadService._resolveSubtitles` → `JimakuPlanSubtitleResolver`），
    // 那时按包内真实视频文件名对位，集号与条数都是事实而非猜测。
    final JimakuEntry? subsEntry = _includeSubs ? _selectedJimakuEntry : null;

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
      jimakuEntryId: subsEntry?.id,
      jimakuEntryName: subsEntry?.name,
      jimakuLanguage: subsEntry == null ? null : _jimakuPreferredLanguage,
      subtitleStatus: subsEntry == null
          ? AnimeDownloadPlan.subtitleNone
          : AnimeDownloadPlan.subtitlePending,
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
    // 说清字幕的时序：选了条目就必然还没下，别让用户以为「推送时字幕已经拿好」。
    final String pushedMessage =
        subscribed ? t.download_subscription_created : t.anime_download_pushed;
    _snack(
      subsEntry == null
          ? pushedMessage
          : '$pushedMessage · ${t.anime_download_subs_deferred}',
    );
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
    final AppModel appModel = ref.read(appProvider);
    final AnimeDownloadPlanStore? store = appModel.animeDownloadPlanStore;
    if (store == null) return;
    final AnimeDownloadService? service = appModel.animeDownloadService;
    if (service == null) {
      await store.delete(plan.id);
    } else {
      await service.deletePlan(plan.id);
    }
    await _reloadPlans();
  }

  /// TODO-1961-e：改名 / 移动入口。
  ///
  /// 为什么必须在 app 里做：引擎按自己记的路径读盘上传，用户在资源管理器里改名
  /// 之后 app 收不到任何通知，等下一轮轮询时文件已经不见了 —— 那种情况**永远**
  /// 救不回来。走这里则由引擎自己改（做种不断），库路径同步迁移。
  Future<void> _relocatePlan(AnimeDownloadPlan plan) async {
    final AppModel appModel = ref.read(appProvider);
    final QbConnectionConfig config = effectiveTorrentConfig(
      appModel.qbConnectionConfig,
    );
    // 先拿这个种子的当前快照（save_path + 文件列表）：改名要文件下标与旧相对
    // 路径，移动要旧 save_path，都得从后端现问，不能猜。
    final TorrentBackend backend = appModel.createTorrentBackend(config);
    TorrentSnapshot? snapshot;
    List<TorrentFileEntry> files = const <TorrentFileEntry>[];
    try {
      for (final TorrentSnapshot t in await backend.listTorrents(
        category: config.category.isEmpty ? null : config.category,
      )) {
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
        _snack(
          t.anime_download_relocate_engine_failed(reason: outcome.error ?? ''),
        );
      case RelocateStatus.libraryFailed:
        _snack(
          t.anime_download_relocate_library_failed(reason: outcome.error ?? ''),
        );
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
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            const DownloadsPage(initialShowSettings: true),
      ),
    );
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
          Icon(
            Icons.info_outline,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              t.download_backend_not_configured,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
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

  /// Jimaku key 输入行：仅初始 key 为空时显示，`onChanged` 直接持久化。
  /// 输入框本体是三处共用的 [JimakuApiKeyField]（权威配置入口在设置 → 视频 → 字幕）。
  Widget _buildJimakuKeyField() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: JimakuApiKeyField(
        controller: _jimakuKeyCtrl,
        dense: true,
        showKeyIcon: true,
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
  /// 行右对齐，两者都保持完整可读。分段条本身走 [FushiSegmentedStrip]，即使单独
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
    final Widget strip = FushiSegmentedStrip<String>(
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
              .map<String?>(
                (ButtonSegment<String> s) =>
                    s.label is Text ? (s.label! as Text).data : null,
              )
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
          Icon(
            Icons.cloud_off_outlined,
            size: 40,
            color: theme.colorScheme.error,
          ),
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
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
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
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
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

  /// 真正的 0 条结果：服务已正常响应，因此不是网络错误；把这次实际采用的
  /// 查询词与筛选条件直接摆出来，用户能判断是标题别名、分类还是 Trusted
  /// 过滤过严，而不是只看到一句没有行动信息的「无结果」。
  Widget _buildNoResults(
    ThemeData theme, {
    required String query,
    required String filters,
  }) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.search_off_outlined,
              size: 40,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 8),
            Text(t.anime_download_no_results, textAlign: TextAlign.center),
            const SizedBox(height: 4),
            Text(
              t.anime_download_no_results_detail(
                query: query,
                filters: filters,
              ),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
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
      return _buildNoResults(
        theme,
        query: _animeQueryCtrl.text.trim(),
        filters: 'AniList · ANIME',
      );
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
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
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
              onPressed: _fetchTorrents,
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
                onSelected: (_) => _selectCategory(id),
              ),
            FilterChip(
              label: Text(t.anime_download_trusted_only),
              visualDensity: VisualDensity.compact,
              selected: _trustedOnly,
              onSelected: _toggleTrustedOnly,
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
      final _TorrentSearchSnapshot applied = _appliedTorrentSearch!;
      final String categoryLabel = switch (applied.category) {
        '1_4' => t.anime_download_category_raw,
        '1_2' => t.anime_download_category_english,
        '1_3' => t.anime_download_category_non_english,
        _ => t.anime_download_category_all,
      };
      return _buildNoResults(
        theme,
        query: applied.query,
        filters:
            '$categoryLabel · ${applied.trustedOnly ? t.anime_download_trusted_only : t.anime_download_unfiltered}',
      );
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
    chips.add(
      _miniChip(
        theme,
        '▲${torrent.seeders}',
        background: scheme.secondaryContainer,
        foreground: scheme.onSecondaryContainer,
      ),
    );
    if (torrent.trusted) {
      chips.add(
        _miniChip(
          theme,
          t.anime_download_trusted,
          icon: Icons.verified_outlined,
          background: scheme.tertiaryContainer,
          foreground: scheme.onTertiaryContainer,
        ),
      );
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
      final ({int covered, int? total}) coverage = _jimakuCoverageFor(torrent);
      if (coverage.covered == 0) {
        chips.add(
          _miniChip(
            theme,
            t.anime_download_no_subs,
            foreground: scheme.outline,
          ),
        );
      } else {
        // 应有集数未知（整季包 / 剧场版）→ 只报实际能给出的条数，不报 `?`：
        // 徽标数必须与确认页字幕列表条数一致，否则「列表说有、点进去说无」。
        final String count = coverage.total == null
            ? '${coverage.covered}'
            : '${coverage.covered}/${coverage.total}';
        // 整季包的集号未经核对（见 [_subtitleEpisodesUnverified]）→ 加 `~`
        // 并退成中性配色，不画成「字幕齐了」的确定态。
        final bool unverified = _subtitleEpisodesUnverified(torrent);
        chips.add(
          _miniChip(
            theme,
            '${t.anime_download_subs_badge} ${unverified ? '~' : ''}$count',
            icon: Icons.subtitles_outlined,
            background: unverified
                ? scheme.surfaceContainerHighest
                : scheme.primaryContainer,
            foreground: unverified
                ? scheme.onSurfaceVariant
                : scheme.onPrimaryContainer,
          ),
        );
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
        // BUG-1309：中段（手动搜索 → 条目选择器 → 语言 → 开关 → 字幕列表）是
        // **一个**可滚动区，不是两块互相抢高度的弹性块。此前条目选择器按自然高度
        // 排（上限 148），字幕列表拿剩下的 `Expanded`；`JimakuEntryPicker` 换成整宽
        // 卡片后剩余高度掉到 62px，说明行折行就直接 RenderFlex 溢出，列表被压成
        // 0 高度——用户在「确认推送」这一步反而看不到要下哪些字幕。收进单一滚动区
        // 后没有任何一块会被压成 0，底部按钮组仍然贴底。
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _buildJimakuManualSearch(theme),
                if (_jimakuEntries.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  // BUG-1309：不再套 `ConstrainedBox(maxHeight: 148)` + 内层滚动。
                  // 那个 148 的窗口本来只是为了给下面的字幕列表腾高度；中段整体可滚
                  // 之后它就成了纯负担——嵌套滚动，而且第二条起的卡片被 ClipRect 切掉
                  // 一半，连点都点不中（命中测试落在 RenderClipRect 上）。
                  JimakuEntryPicker(
                    entries: _jimakuEntries,
                    selectedEntryId: _selectedJimakuEntry?.id,
                    enabled: !_pushing && !_jimakuLoading,
                    onSelected: _selectJimakuEntry,
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
                  // BUG-1425：这是一个「设置开关」，不是候选行/字幕行/任务行——
                  // 本文件的 reviewed 豁免通篇只讲内容行，从没覆盖过开关。走共享
                  // MD3 开关行（与 games_library_page 同款收口）。
                  AdaptiveSettingsSwitchRow(
                    title: t.anime_download_include_subs,
                    value: _includeSubs,
                    onChanged: _pushing
                        ? null
                        : (bool value) => setState(() => _includeSubs = value),
                  ),
                _buildChosenSubsList(theme),
              ],
            ),
          ),
        ),
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
              // 选中即重搜——只改输入框文本不搜，用户看到的是「番剧名换了、下面
              // 的字幕来源纹丝不动」，会误判成功能坏了（BUG-1190）。
              suffixIcon: titleOptions.length < 2
                  ? null
                  : PopupMenuButton<String>(
                      tooltip: t.video_jimaku_query,
                      icon: const Icon(Icons.arrow_drop_down),
                      onSelected: (String value) {
                        _jimakuQueryCtrl.text = value;
                        unawaited(_searchJimakuManual());
                      },
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
        // 输入框改了但没搜时按钮转强调色：手改番剧名/集号后「下面没变」不是坏了，
        // 是还没触发搜索——把这件事显式画出来（BUG-1190）。
        ListenableBuilder(
          listenable: Listenable.merge(<Listenable>[
            _jimakuQueryCtrl,
            _jimakuEpisodeCtrl,
          ]),
          builder: (BuildContext context, Widget? child) {
            final bool dirty = _jimakuQueryCtrl.text.trim().isNotEmpty &&
                _currentJimakuSearchInput() != _appliedJimakuSearch;
            return IconButton(
              tooltip: t.anime_download_search,
              icon: const Icon(Icons.search, size: 20),
              color: dirty ? theme.colorScheme.primary : null,
              onPressed: _jimakuLoading ? null : _searchJimakuManual,
            );
          },
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
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      );
    }
    if (_jimakuError) {
      return _buildErrorRetry(
        theme,
        t.anime_download_subs_failed,
        _retryJimaku,
      );
    }
    if (_chosenSubs.isEmpty) {
      // 季号校验拦下自动选中时**必然**落到这条空态分支（没条目 ⇒ 没文件 ⇒
      // 没字幕）。不能只说「无字幕」——那是静默：候选条目就在上面的 picker 里，
      // 只是没有一条季号对得上这个包。用与「集号未核对」同一排版的提示行说清
      // 原因，用户手选任意一条即可放行（手选不受本校验拦截）。
      final NyaaTorrent? blockedTorrent = _selectedTorrent;
      final bool seasonBlocked =
          blockedTorrent != null && _jimakuSeasonBlockedFor(blockedTorrent);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (seasonBlocked)
            _buildSubsHintRow(
              theme,
              Icons.help_outline,
              t.anime_download_subs_season_mismatch(
                season: blockedTorrent.season ?? 1,
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    t.anime_download_no_subs,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _retryJimaku,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: Text(t.anime_download_retry),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }
    // 这份列表是**预览**（按种子标题猜的），不是最终会下的清单：真正配哪些
    // 字幕要等种子 add 之后按包内真实文件名反查（BUG-1206）。所以恒显示一行
    // 时序说明；整季包再叠一行「集号未核对」（PR#515 的不确定态表达仍然准确
    // ——选种这一刻确实没核对，根治只保证错配不会真的落到磁盘上）。
    final NyaaTorrent? torrent = _selectedTorrent;
    final bool unverified =
        torrent != null && _subtitleEpisodesUnverified(torrent);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _buildSubsHintRow(
          theme,
          Icons.schedule,
          t.anime_download_subs_deferred,
        ),
        if (unverified)
          _buildSubsHintRow(
            theme,
            Icons.help_outline,
            t.anime_download_subs_episodes_unverified,
          ),
        _buildChosenSubsListView(theme),
      ],
    );
  }

  /// 字幕列表上方的说明行（时序 / 未核对共用同一排版）。
  Widget _buildSubsHintRow(ThemeData theme, IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChosenSubsListView(ThemeData theme) {
    // BUG-1309：由确认阶段中段那一个 `SingleChildScrollView` 统一滚动，本列表只
    // 按内容撑高（否则嵌套两层滚动，且高度不足时条目根本不构建 → 用户看不见）。
    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
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
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
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
    final QbConnectionConfig config = effectiveTorrentConfig(
      appModel.qbConnectionConfig,
    );
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
        pushed = torrents.any(
          (TorrentSnapshot t) => t.hash.toLowerCase() == plan.id.toLowerCase(),
        );
      }
    } finally {
      backend.close();
    }
    if (!pushed) {
      _snack(t.anime_download_push_failed);
      return;
    }
    await store.save(
      plan.copyWith(
        status: AnimeDownloadPlan.statusDownloading,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    unawaited(appModel.animeDownloadService?.tick());
    _snack(t.anime_download_pushed);
    await _reloadPlans();
  }

  /// TODO-2481：当前后端是否支持暂停/恢复。探测 = `is TorrentPauseBackend`
  /// + 运行时能力位（内置引擎老 DLL 缺原语时类型过了也点不动）。对话框
  /// 生命周期内缓存一次 —— 只在任务行确实处于下载中时才会走到这里，此时
  /// 轮询服务本就每 tick 建同款后端，探测不会额外拉起会话。
  bool? _pauseCapableCache;

  bool get _pauseCapable {
    final bool? cached = _pauseCapableCache;
    if (cached != null) return cached;
    if (!_backendReady) return false;
    final AppModel appModel = ref.read(appProvider);
    final TorrentBackend backend = appModel.createTorrentBackend(
      effectiveTorrentConfig(appModel.qbConnectionConfig),
    );
    bool capable = false;
    try {
      capable = backend is TorrentPauseBackend && backend.pauseControlAvailable;
    } finally {
      backend.close();
    }
    _pauseCapableCache = capable;
    return capable;
  }

  /// TODO-2481：暂停/恢复单个任务；成功即踢一轮 tick 刷新快照与状态文本。
  Future<void> _togglePausePlan(
    AnimeDownloadPlan plan, {
    required bool pause,
  }) async {
    final AppModel appModel = ref.read(appProvider);
    if (!torrentBackendReady(appModel)) {
      _snack(t.download_backend_not_configured);
      return;
    }
    final TorrentBackend backend = appModel.createTorrentBackend(
      effectiveTorrentConfig(appModel.qbConnectionConfig),
    );
    bool ok = false;
    try {
      if (backend is TorrentPauseBackend) {
        ok = pause
            ? await backend.pauseTorrent(plan.id)
            : await backend.resumeTorrent(plan.id);
      }
    } finally {
      backend.close();
    }
    if (!ok) {
      _snack(t.download_task_toggle_failed);
      return;
    }
    unawaited(appModel.animeDownloadService?.tick());
  }

  /// TODO-2481：显示状态 → i18n 文案；unknown 返回 null（该段不渲染）。
  String? _torrentStatusLabel(TorrentDisplayStatus status) {
    return switch (status) {
      TorrentDisplayStatus.downloading => t.download_task_status_downloading,
      TorrentDisplayStatus.seeding => t.download_task_status_seeding,
      TorrentDisplayStatus.completed => t.download_task_status_completed,
      TorrentDisplayStatus.paused => t.download_task_status_paused,
      TorrentDisplayStatus.queued => t.download_task_status_queued,
      TorrentDisplayStatus.stalled => t.download_task_status_stalled,
      TorrentDisplayStatus.checking => t.download_task_status_checking,
      TorrentDisplayStatus.fetchingMetadata => t.download_task_status_metadata,
      TorrentDisplayStatus.moving => t.download_task_status_moving,
      TorrentDisplayStatus.error => t.download_task_status_error,
      TorrentDisplayStatus.unknown => null,
    };
  }

  /// 单条任务行（[FushiListItem] compact，自动接焦点系统）。
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
        // BUG-1296：百分比与确定进度环只认 [AnimeDownloadService.downloadProgress]
        // ——它是恒发布的规范通道。BUG-1294 的速度/流量走 downloadStats，只是**增强
        // 位**：拿不到观测值时少一截后缀即可，不能把百分比一起吞掉（`_importNowUnlocked`
        // 那条路径就会短暂只发进度不发观测值）。
        return ValueListenableBuilder<Map<String, double>>(
          valueListenable: service.downloadProgress,
          builder: (BuildContext context, Map<String, double> progress, _) =>
              ValueListenableBuilder<Map<String, DownloadTaskStats>>(
            valueListenable: service.downloadStats,
            builder: (BuildContext context,
                    Map<String, DownloadTaskStats> stats, _) =>
                _buildPlanRowInner(
                    theme, plan, progress[plan.id], stats[plan.id]),
          ),
        );
      }
    }
    return _buildPlanRowInner(theme, plan, null, null);
  }

  Widget _buildPlanRowInner(ThemeData theme, AnimeDownloadPlan plan,
      double? progress, DownloadTaskStats? stats) {
    final ColorScheme scheme = theme.colorScheme;
    final bool eink = isEinkTheme(context);
    final bool downloading = plan.status == AnimeDownloadPlan.statusDownloading;
    final bool failed = plan.status == AnimeDownloadPlan.statusFailed;
    final Widget statusIcon = switch (plan.status) {
      AnimeDownloadPlan.statusImported => Icon(
          Icons.check_circle_outline,
          size: 20,
          color: scheme.primary,
        ),
      AnimeDownloadPlan.statusFailed => Icon(
          Icons.error_outline,
          size: 20,
          color: scheme.error,
        ),
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
    // BUG-1294：进度百分比之外补速度与累计流量（单位串是纯数字/符号，无需
    // i18n key）。速率为 0 时仍显示（「0 B/s 卡住了」本身就是有效信息）。
    // BUG-1296：百分比只依赖 progress；观测值缺席就只渲染百分比，不整条消失。
    // TODO-2481：再补状态文本 / ETA / 分享率 —— 三者都是增强位，算不出
    // （未知词 / 零速度 / 零分母）就整段不渲染，绝不把百分比一起吞掉。
    final TorrentDisplayStatus? displayStatus =
        stats == null ? null : torrentDisplayStatusFor(stats.state);
    final String? statusLabel =
        displayStatus == null ? null : _torrentStatusLabel(displayStatus);
    final String? etaText = stats == null
        ? null
        : formatTorrentEta(
            amountLeft: stats.amountLeft,
            downRateBps: stats.downRateBps,
          );
    final String? ratioText = stats == null
        ? null
        : formatShareRatio(
            uploadedBytes: stats.uploadedBytes,
            downloadedBytes: stats.downloadedBytes,
          );
    final String? progressText = (downloading && progress != null)
        ? <String>[
            '${(progress * 100).toStringAsFixed(0)}%',
            if (statusLabel != null) statusLabel,
            if (stats != null) ...<String>[
              '↓ ${FushiByteFormat.speed(stats.downRateBps.toDouble())}',
              '↑ ${FushiByteFormat.speed(stats.upRateBps.toDouble())}',
              FushiByteFormat.bytes(stats.downloadedBytes),
            ],
            if (etaText != null) '${t.download_task_eta} $etaText',
            if (ratioText != null) '${t.download_task_ratio} $ratioText',
          ].join(' · ')
        : null;
    final String? failReason =
        (failed && (plan.failReason?.isNotEmpty ?? false))
            ? plan.failReason
            : null;
    // 字幕的时序对用户是可见的（BUG-1206）：推送时不再预下字幕，所以必须在这里
    // 说清「还没配」「没配上」，否则用户会以为字幕功能没了。
    // resolved / none 不占行——前者字幕已经贴成 sidecar，后者用户压根没要字幕。
    final (String, Color)? subtitleNote = switch (plan.subtitleStatus) {
      AnimeDownloadPlan.subtitlePending => (
          t.anime_download_subs_pending,
          scheme.onSurfaceVariant,
        ),
      AnimeDownloadPlan.subtitleUnavailable => (
          t.anime_download_subs_unmatched,
          scheme.tertiary,
        ),
      _ => null,
    };
    return FushiListItem(
      density: FushiListDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      // TODO-2482：行点击 = 打开任务详情（四 tab）。详情对话框自己探测
      // 后端能力并降级，这里不做前置门槛。
      onTap: () => _openTaskDetail(plan),
      subtitleMaxLines: plan.importedEarly ? 5 : 3,
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
            Text(progressText, maxLines: 1, style: theme.textTheme.bodySmall),
          if (plan.importedEarly)
            Text(
              t.anime_download_streaming_ready,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.primary),
            ),
          if (subtitleNote != null)
            Text(
              subtitleNote.$1,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: subtitleNote.$2,
              ),
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
          // TODO-2481：暂停/恢复（仅后端具备该能力时显示）。图标随当前
          // 状态切换；操作成功由 tick 刷出新状态，无本地乐观态。
          if (downloading && _pauseCapable)
            if (displayStatus == TorrentDisplayStatus.paused)
              FushiIconButton(
                tooltip: t.download_task_resume,
                icon: Icons.play_arrow_outlined,
                size: 20,
                onTap: () => _togglePausePlan(plan, pause: false),
              )
            else
              FushiIconButton(
                tooltip: t.download_task_pause,
                icon: Icons.pause_circle_outline,
                size: 20,
                onTap: () => _togglePausePlan(plan, pause: true),
              ),
          if (downloading && !plan.importedEarly)
            FushiIconButton(
              tooltip: t.anime_download_play_now,
              icon: Icons.play_circle_outline,
              size: 20,
              onTap: () => _playNow(plan),
            ),
          if (failed)
            FushiIconButton(
              tooltip: t.anime_download_retry,
              icon: Icons.refresh,
              size: 20,
              onTap: () => _retryPlan(plan),
            ),
          FushiIconButton(
            tooltip: t.anime_download_relocate,
            icon: Icons.drive_file_move_outline,
            size: 20,
            onTap: () => _relocatePlan(plan),
          ),
          FushiIconButton(
            tooltip: t.anime_download_delete,
            icon: Icons.delete_outline,
            size: 20,
            onTap: () => _deletePlan(plan),
          ),
        ],
      ),
    );
  }

  /// TODO-2482：打开任务详情对话框（入口 = 任务行点击）。
  void _openTaskDetail(AnimeDownloadPlan plan) {
    showDialog<void>(
      context: context,
      builder: (BuildContext context) => TorrentTaskDetailDialog(plan: plan),
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
    return FushiDialogFrame(
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
    // 迁移目标目录长期承载下载文件，必须是真实路径（见 pickRealDirectoryPath）。
    final String? picked = await pickRealDirectoryPath(
      context: context,
      appModel: ProviderScope.containerOf(
        context,
        listen: false,
      ).read(appProvider),
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
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                t.anime_download_relocate_move_title,
                style: theme.textTheme.titleSmall,
              ),
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
                Text(
                  t.anime_download_relocate_rename_title,
                  style: theme.textTheme.titleSmall,
                ),
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
                        FushiIconButton(
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
