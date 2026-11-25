import 'dart:async' show unawaited;
import 'package:collection/collection.dart' show mergeSort;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/media/downloads/download_source_method.dart';
import 'package:fushi/src/media/downloads/download_start_result.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_engine/media/discovery/discovery_download_queue.dart';
import 'package:fushi/src/media/discovery/discovery_download_inline_status.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/discovery/discovery_labels.dart';
import 'package:fushi/src/media/discovery/discovery_search_relevance.dart';
import 'package:fushi/src/media/discovery/media_discovery_service.dart';
import 'package:fushi/src/media/discovery/media_discovery_source.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/nyaa_client.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/pages/implementations/discovery/discovery_source_block.dart';
import 'package:fushi/src/pages/implementations/discovery/discovery_widgets.dart';
import 'package:fushi/src/pages/implementations/discovery_header.dart';
import 'package:fushi/src/pages/implementations/download_actions.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_neutral_decor.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_section_title.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_tag.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart'
    show FushiShellTitleScope;
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show FushiFloatingChromeInsetSpacer, FushiFloatingChromeOverlay;
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi/src/utils/misc/engine_listenable.dart';
import 'package:fushi/src/media/discovery/sources/nyaa_discovery_source.dart';
import 'package:fushi/src/media/import/apple/apple_import_rows.dart'
    show AppleImportSectionAction;
import 'package:fushi/src/pages/implementations/discovery/apple/apple_discovery_shelf.dart';
import 'package:fushi/src/pages/implementations/discovery/apple/apple_discovery_widgets.dart';
import 'package:fushi/src/utils/components/settings_shared.dart'
    show AdaptiveSettingsSection;

part 'discovery/apple/apple_media_discovery.part.dart';

/// 统一发现页：书（小说/有声书）与 galgame 共用的多源在线资源发现视图。
///
/// 结构：媒体域筛选（多域时）+ 来源下拉（默认「全部来源」）+ 搜索框 +
/// 结果列表（目录可下钻、资源可下载）。**「全部来源」只做搜索**：空查询时不
/// 发任何请求，正文列出候选来源让用户先选一个（聚合浏览没有语义，硬做只会
/// 退化成某个恰好支持浏览的源的根目录，见 BUG-1711）。下载分流按条目 payloadKind：
/// torrent → `pushGenericMagnet`（既有 torrent 后端 + 自动入库），
/// http 直链 → `AppModel.discoveryDownloadQueue`（下载完自动入库）。
/// 单源失败亮徽标不拖垮整页（`DiscoveryAggregateResult` 部分成功语义）。
///
/// 交互口径与视频发现页一致（`docs/specs/2026-09-27-browse-module.md` 阶段 3，
/// 共享件在 `discovery/discovery_widgets.dart`）：输入停顿 350ms 自动搜索、回车
/// 立即搜索；结果滚到离底 600 以内自动翻页（「加载更多」按钮留作键盘 / 手柄与
/// 首页不满一屏时的兜底）；部分来源失败是一条点名来源的横幅，全部失败 / 异常是
/// 可重试的整块提示。
///
/// **构建期零 provider 依赖**：游戏页 IndexedStack 急切构建全部子区，本页
/// 在无 ProviderScope 的 widget 测试里也会被 build——容器只在首帧后加载与
/// 交互时解析（同游戏页 `_buildImport` 的约定）。
class MediaDiscoveryPage extends StatefulWidget {
  const MediaDiscoveryPage({
    required this.kinds,
    this.navigation,
    this.initialSourceId,
    this.onAiAcquire,
    this.onManageSources,
    super.key,
  });

  /// 本页覆盖的媒体域（书域传 [novel, audiobook]，游戏域传 [game]）。
  final List<DiscoveryMediaKind> kinds;

  /// 库页壳注入的分段导航（嵌在头部；游戏域自带段条时传 null 由外层包）。
  final Widget? navigation;

  /// 首帧就选中的来源 id（null = 「全部来源」引导态）。
  ///
  /// 用于从别处「点某个来源直接进它的目录」的入口（漫画发现页的 OPDS 卡片）：
  /// 那种场景下用户已经点名了来源，再让他在引导态里挑一次是多余的一步。
  /// 只作用于**首帧**——之后用户改下拉、下钻目录都以页内状态为准。
  final String? initialSourceId;

  /// 「AI 下载」入口（参数 = 搜索框当前文字）；null = 宿主没接线，按钮不渲染。
  final ValueChanged<String>? onAiAcquire;

  /// 「管理来源」去处（「⋯」里的一项；没有来源时引导块的「管理来源 / 连接
  /// 服务器」按钮）。null = 宿主没有去处，不渲染点了没反应的入口。
  final VoidCallback? onManageSources;

  @override
  State<MediaDiscoveryPage> createState() => _MediaDiscoveryPageState();
}

/// 空查询时的页面态。只有 [none] 才该向源发请求——另外两态发出去要么无语义、
/// 要么必然失败，本页据此在首帧就分流（BUG-1711）。
enum _DiscoveryIdle {
  /// 有关键词，或单源且该源支持目录浏览：正常发请求。
  none,

  /// 「全部来源」+ 空查询：聚合没有浏览语义，先让用户选来源。
  pickSource,

  /// 单源 + 空查询，但该源只支持关键词搜索：请求必然收到 unsupported。
  queryRequired,
}

/// BUG-1910：游戏发现页的汉化状态筛选档位。
///
/// [unlabelled] 是**必须有**的一档：sukebei / AList 的条目 `gameLocalization` 恒为
/// null（那两个源不给这个信息，**不是**「未汉化」）。没有这一档的话，用户在聚合搜索
/// 里一按筛选就把那两个源整个滤没了，还会以为它们挂了。
enum _GameTypeFilter {
  all(null),
  raw(DiscoveryGameLocalization.raw),
  translated(DiscoveryGameLocalization.translated),
  mobile(DiscoveryGameLocalization.mobile),
  unlabelled(null);

  const _GameTypeFilter(this.value);

  /// 对应的分类；[all] 与 [unlabelled] 都没有对应值，靠 [matches] 区分语义。
  final DiscoveryGameLocalization? value;

  bool matches(DiscoveryGameLocalization? item) {
    switch (this) {
      case _GameTypeFilter.all:
        return true;
      case _GameTypeFilter.unlabelled:
        return item == null;
      case _GameTypeFilter.raw:
      case _GameTypeFilter.translated:
      case _GameTypeFilter.mobile:
        return item == value;
    }
  }

  String get label {
    switch (this) {
      case _GameTypeFilter.all:
        return t.discovery_game_type_all;
      case _GameTypeFilter.raw:
        return t.discovery_game_type_raw;
      case _GameTypeFilter.translated:
        return t.discovery_game_type_translated;
      case _GameTypeFilter.mobile:
        return t.discovery_game_type_mobile;
      case _GameTypeFilter.unlabelled:
        return t.discovery_game_type_unlabelled;
    }
  }
}

class _MediaDiscoveryPageState extends State<MediaDiscoveryPage> {
  /// Apple macOS 档「来源」货架是否展开成网格（「查看全部」）。
  bool _appleSourcesExpanded = false;

  /// Apple 画法（part 里的 extension）改页内状态用。
  void _updateState(VoidCallback fn) => setState(fn);

  late DiscoveryMediaKind _kind = widget.kinds.first;
  String _sourceId = kDiscoveryAllSourcesId;
  final TextEditingController _queryCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  /// 首帧后解析到的全局模型；无 ProviderScope（纯布局测试）时保持 null，
  /// 页面停留在提示态。
  AppModel? _appModel;

  AppModel? _resolveAppModel() {
    if (_appModel != null) return _appModel;
    try {
      _appModel = ProviderScope.containerOf(
        context,
        listen: false,
      ).read(appProvider);
    } on StateError {
      return null;
    }
    return _appModel;
  }

  /// 目录下钻栈（(源内路径, 显示名)）；只在单源模式下非空。
  final List<(String, String)> _pathStack = <(String, String)>[];

  /// **已提交**的搜索词（`_queryCtrl` 是草稿，这里是真正发出去过的那一个）。
  ///
  /// BUG-1768：旧实现直接读 `_queryCtrl.text` 当「是不是搜索态」，而
  /// `_openFolder` 只压路径栈、不动搜索框，于是「进文件夹」这次请求仍带着
  /// 关键词 → `DiscoveryRequest.isSearch` 为真 → `path` 被静默丢弃 → 又发了
  /// 一次一模一样的全站搜索，同名目录把自己当子项列出来，可以无限点下去。
  /// 草稿与已提交分开后，「有没有在搜索」不再取决于用户此刻框里打了什么。
  String _query = '';

  final List<DiscoveryEntry> _entries = <DiscoveryEntry>[];

  /// BUG-1910：游戏汉化状态筛选，默认「全部」。
  ///
  /// **纯客户端过滤，不重发请求**——分类是条目自带的可判定属性（源在解析时就算好了，
  /// 见 `shinnkuGameLocalization`），没有任何理由为了换个筛选再打一次网络。与番剧
  /// 下载对话框的排序切换同一条纪律（就地重排、不重新请求）。
  _GameTypeFilter _gameTypeFilter = _GameTypeFilter.all;

  /// 筛选是否可用：只有游戏域、且当前结果里确实存在带分类的条目时才出这排 chip。
  /// 视频/书域，或搜的是压根不给分类的源，不该凭空多一排控件。
  bool get _gameTypeFilterAvailable =>
      _kind == DiscoveryMediaKind.game &&
      _entries.any(
        (DiscoveryEntry e) =>
            e is DiscoveryResourceItem && e.gameLocalization != null,
      );

  /// 应用游戏汉化筛选后的条目。目录条目（[DiscoveryFolder]）永远保留——它们是
  /// 导航结构，不是资源，把它们筛掉会让用户下不去。
  List<DiscoveryEntry> get _gameFilteredEntries {
    // 选了非「全部」就照筛（哪怕当前结果一条带分类的都没有、筛到 0 条）：筛选
    // chip 此时仍在，用户能切回「全部」，不会被一个看不见的筛选卡住。
    if (_gameTypeFilter == _GameTypeFilter.all ||
        _kind != DiscoveryMediaKind.game) {
      return _entries;
    }
    return <DiscoveryEntry>[
      for (final DiscoveryEntry e in _entries)
        if (e is! DiscoveryResourceItem ||
            _gameTypeFilter.matches(e.gameLocalization))
          e,
    ];
  }

  /// 「已隐藏 N 条…」被用户点开后的临时显示态；每轮新加载重置。
  ///
  /// 点开**不改偏好**：用户是想看一眼这次被藏了什么，不是想永久关掉过滤。
  bool _revealHidden = false;

  /// 偏好未就绪（无 ProviderScope 的纯布局测试 / 早一帧打开）时用默认值，
  /// 且不写盘。三个偏好的默认值只在 [PreferencesRepository] 一处定义。
  PreferencesRepository? get _prefs {
    final AppModel? appModel = _appModel;
    if (appModel == null || !appModel.isPreferencesReady) return null;
    return appModel.prefsRepo;
  }

  bool get _hideZeroSeeders => _prefs?.discoveryHideZeroSeeders ?? true;

  bool get _hideSuspectedManga => _prefs?.discoveryHideSuspectedManga ?? true;

  NyaaQualityFilter get _nyaaQualityFilter =>
      NyaaQualityFilter.fromIndex(_prefs?.discoveryNyaaQualityFilter ?? 0);

  /// 当前结果里有没有种子类条目（带做种数）。做种相关的 chip / 灰显只对它们
  /// 有意义，OPDS / 直链源不该凭空多一排控件。
  bool get _hasSeederEntries => _entries.any(
    (DiscoveryEntry e) => e is DiscoveryResourceItem && e.seeders != null,
  );

  /// 当前结果里有没有跑过内容分类器的条目（只有 nyaa 小说域会打）。
  bool get _hasContentHints => _entries.any(
    (DiscoveryEntry e) =>
        e is DiscoveryResourceItem &&
        e.contentHint != DiscoveryContentHint.none,
  );

  /// 当前会打到 Nyaa 的来源集合里有没有 Nyaa 源：过滤三态是 nyaa 的服务端参数
  /// （`f`），只在它真会生效时露出。
  bool get _nyaaFilterAvailable {
    final MediaDiscoveryService? service = _appModel?.mediaDiscoveryService;
    if (service == null) return false;
    if (_sourceId != kDiscoveryAllSourcesId) {
      return service.sourceById(_sourceId) is NyaaDiscoverySource;
    }
    return service
        .sourcesFor(_kind)
        .any((MediaDiscoverySource s) => s is NyaaDiscoverySource);
  }

  static int _seedersOf(DiscoveryEntry e) =>
      e is DiscoveryResourceItem ? (e.seeders ?? -1) : -1;

  /// 当前这批结果对应的搜索词：只有「搜索」请求的结果才谈得上相关度。下钻进
  /// 某个目录时 [_query] 仍保留（返回要回到那次搜索），但那时列表是目录内容，
  /// 拿搜索词去判它们只会把整个目录误折叠掉。
  String? get _activeSearchQuery =>
      _pathStack.isEmpty && _query.isNotEmpty ? _query : null;

  /// 源内**稳定**排序：先相关度（搜索时），再做种降序；跨源仍按 service 给出的
  /// priority 顺序串接。
  ///
  /// 服务层已经按相关度重排、Nyaa 服务端已经按做种排过（`s=seeders&o=desc`），
  /// 这里是本地兜底：翻页追加的条目要能插回正确位置，多个源混排时各自内部也要
  /// 有序。做种只对含做种数的源分组参与比较，OPDS / 直链源同档原序不动。
  /// `List.sort` 不稳定，用 [mergeSort]。
  static List<DiscoveryEntry> _sortWithinSource(
    List<DiscoveryEntry> entries,
    Map<DiscoveryEntry, DiscoverySearchRelevance>? relevance,
  ) {
    final Map<String, List<DiscoveryEntry>> groups =
        <String, List<DiscoveryEntry>>{};
    for (final DiscoveryEntry e in entries) {
      (groups[e.sourceId] ??= <DiscoveryEntry>[]).add(e);
    }
    final List<DiscoveryEntry> out = <DiscoveryEntry>[];
    for (final List<DiscoveryEntry> group in groups.values) {
      final bool bySeeders = group.any(
        (DiscoveryEntry e) => _seedersOf(e) >= 0,
      );
      if (bySeeders || relevance != null) {
        mergeSort<DiscoveryEntry>(
          group,
          compare: (DiscoveryEntry a, DiscoveryEntry b) {
            if (relevance != null) {
              final int byRelevance = relevance[b]!.compareTo(relevance[a]!);
              if (byRelevance != 0) return byRelevance;
            }
            return bySeeders ? _seedersOf(b).compareTo(_seedersOf(a)) : 0;
          },
        );
      }
      out.addAll(group);
    }
    return out;
  }

  bool _isHiddenZeroSeeders(DiscoveryEntry e) =>
      _hideZeroSeeders && e is DiscoveryResourceItem && e.seeders == 0;

  bool _isHiddenSuspectedManga(DiscoveryEntry e) =>
      _hideSuspectedManga &&
      e is DiscoveryResourceItem &&
      e.contentHint == DiscoveryContentHint.manga;

  /// 最终渲染集合 + 三类被隐藏的计数（一条只计一次：先算疑似不相关，再算无人
  /// 做种，最后疑似漫画）。
  ///
  /// 疑似不相关（反馈 80S7Esbdec）：源后端的匹配口径不可控（shinnku 是字符级
  /// 模糊匹配），判据见 `discovery_search_relevance.dart`。**折叠而不删**——源可能
  /// 按作者 / 系列这类聚合层看不到的字段命中，用户点计数行即可展开。不设偏好开关：
  /// 与死种 / 疑似漫画不同，它没有「我就是想看不相关结果」的长期需求。
  ({
    List<DiscoveryEntry> entries,
    int hiddenIrrelevant,
    int hiddenZeroSeeders,
    int hiddenManga,
  })
  get _visible {
    final List<DiscoveryEntry> filtered = _gameFilteredEntries;
    final String? query = _activeSearchQuery;
    // 按条目身份记分（条目没有值相等语义），每条只算一次，排序比较直接查表。
    Map<DiscoveryEntry, DiscoverySearchRelevance>? relevance;
    if (query != null) {
      relevance = Map<DiscoveryEntry, DiscoverySearchRelevance>.identity();
      for (final DiscoveryEntry e in filtered) {
        relevance[e] = discoveryEntryRelevance(query, e);
      }
    }
    final List<DiscoveryEntry> sorted = _sortWithinSource(filtered, relevance);
    if (_revealHidden) {
      return (
        entries: sorted,
        hiddenIrrelevant: 0,
        hiddenZeroSeeders: 0,
        hiddenManga: 0,
      );
    }
    int hiddenIrrelevant = 0;
    int hiddenZeroSeeders = 0;
    int hiddenManga = 0;
    final List<DiscoveryEntry> shown = <DiscoveryEntry>[];
    for (final DiscoveryEntry e in sorted) {
      if (relevance != null && !relevance[e]!.isRelevant) {
        hiddenIrrelevant++;
      } else if (_isHiddenZeroSeeders(e)) {
        hiddenZeroSeeders++;
      } else if (_isHiddenSuspectedManga(e)) {
        hiddenManga++;
      } else {
        shown.add(e);
      }
    }
    return (
      entries: shown,
      hiddenIrrelevant: hiddenIrrelevant,
      hiddenZeroSeeders: hiddenZeroSeeders,
      hiddenManga: hiddenManga,
    );
  }

  void _setHideZeroSeeders(bool value) {
    final PreferencesRepository? prefs = _prefs;
    if (prefs == null) return;
    unawaited(prefs.setDiscoveryHideZeroSeeders(value));
    setState(() => _revealHidden = false);
  }

  void _setHideSuspectedManga(bool value) {
    final PreferencesRepository? prefs = _prefs;
    if (prefs == null) return;
    unawaited(prefs.setDiscoveryHideSuspectedManga(value));
    setState(() => _revealHidden = false);
  }

  /// 过滤三态是服务端参数：写穿偏好后必须重新请求（源在每次请求时读偏好）。
  void _setNyaaQualityFilter(NyaaQualityFilter value) {
    final PreferencesRepository? prefs = _prefs;
    if (prefs == null || value == _nyaaQualityFilter) return;
    unawaited(prefs.setDiscoveryNyaaQualityFilter(value.index));
    setState(() {});
    unawaited(_load());
  }

  DiscoveryAggregateResult? _result;
  bool _loading = false;
  Object? _error;
  int _page = 1;

  /// CoreAudio 需要在点击后下载并解析 `.torrent`；按条目去重，避免连点产生多个
  /// 同 hash durable 任务。
  final Set<String> _resolvingTorrentIds = <String>{};

  /// 竞态哨兵：晚到的旧请求结果不覆盖新状态。
  int _loadSeq = 0;

  /// 本轮首批结果上屏的时刻：此后 [_kResultsEntranceWindow] 内挂载的结果块播
  /// 错峰进场，之后滚动带出来的直接出现。
  DateTime? _firstBatchAt;

  /// 最近一次翻页追加的条目（按身份）与追加时刻：只给这些新块播进场。
  final Set<DiscoveryEntry> _appendedEntries = Set<DiscoveryEntry>.identity();
  DateTime? _appendedAt;

  /// 搜索框输入防抖：停顿后按「提交」语义发请求（见 [_scheduleSearch]）。
  final DiscoverySearchDebouncer _searchDebounce = DiscoverySearchDebouncer();

  /// 本轮（首页 + 已追加的各页）累计的来源失败，去重后喂横幅。
  List<ExternalProviderFailure> _failures = const <ExternalProviderFailure>[];

  /// 追加页失败：保留已有条目，页尾换成重试，且不再自动翻页（否则每滚一下就
  /// 重打一次坏掉的那页）。下一轮非追加加载时复位。
  bool _loadMoreFailed = false;

  /// 结果列表的滚动：state 自己持有，不进 PageStorage（`keepScrollOffset: false`）。
  /// 书 / 游戏两域在同一路由下挂同一个页面类，PageStorageKey 会让两域互串偏移，
  /// 还会让每次非追加加载（换来源 / 新搜索）后的新列表恢复旧偏移；页面状态本身
  /// 靠宿主 Offstage 保活，不需要 PageStorage。
  final ScrollController _resultsScroll = ScrollController(
    keepScrollOffset: false,
  );

  @override
  void initState() {
    super.initState();
    _sourceId = widget.initialSourceId ?? kDiscoveryAllSourcesId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  @override
  void dispose() {
    _searchDebounce.dispose();
    _queryCtrl.dispose();
    _searchFocus.dispose();
    _resultsScroll.dispose();
    super.dispose();
  }

  /// 当前（空查询下的）页面态，见 [_DiscoveryIdle]。
  _DiscoveryIdle _idleMode(AppModel appModel) {
    // 已下钻进某个目录：这是一次有明确位置的 browse，与关键词无关（BUG-1768）。
    if (_pathStack.isNotEmpty) return _DiscoveryIdle.none;
    if (_query.isNotEmpty) return _DiscoveryIdle.none;
    if (_sourceId == kDiscoveryAllSourcesId) return _DiscoveryIdle.pickSource;
    final MediaDiscoverySource? source = appModel.mediaDiscoveryService
        .sourceById(_sourceId);
    if (source != null && !source.capabilities.supportsBrowse) {
      return _DiscoveryIdle.queryRequired;
    }
    return _DiscoveryIdle.none;
  }

  Future<void> _load({bool append = false}) async {
    final AppModel? appModel = _resolveAppModel();
    if (appModel == null) return;
    // 「空查询 = 目录浏览」是错的：聚合模式没有浏览语义（真发出去会被服务层
    // 挡下），只支持搜索的单源也只会换回一块 unsupported 牌坊。这两态一个请求
    // 都不发，正文改成引导态。
    if (_idleMode(appModel) != _DiscoveryIdle.none) {
      _loadSeq++; // 作废在途请求：晚到的结果不许回填引导态
      setState(() {
        _loading = false;
        _error = null;
        _page = 1;
        _entries.clear();
        _result = null;
        _failures = const <ExternalProviderFailure>[];
        _loadMoreFailed = false;
      });
      return;
    }
    // 下钻比「产生这个目录的那次搜索」更具体：路径栈非空就必须走 browse。
    // 反过来（关键词压过路径，BUG-1768 的旧行为）会让「进文件夹」退化成重发
    // 同一次搜索。两者在这里就地互斥，请求出口只有这一个（`DiscoveryRequest`
    // 的断言把这条不变式钉死）。
    final String? path = _pathStack.isNotEmpty ? _pathStack.last.$1 : null;
    final String? query = path == null && _query.isNotEmpty ? _query : null;
    final int seq = ++_loadSeq;
    // 新一轮（非追加）结果从顶部开始，不停在上一轮列表的位置。
    if (!append && _resultsScroll.hasClients) _resultsScroll.jumpTo(0);
    setState(() {
      _loading = true;
      _error = null;
      if (!append) {
        _page = 1;
        _entries.clear();
        _result = null;
        _revealHidden = false;
        _failures = const <ExternalProviderFailure>[];
        _loadMoreFailed = false;
        _firstBatchAt = null;
        _appendedEntries.clear();
        _appendedAt = null;
      }
    });
    try {
      final DiscoveryRequest request = DiscoveryRequest(
        kind: _kind,
        query: query,
        path: path,
        page: _page,
      );
      // 追加页（加载更多）不做渐进：旧条目要保序，等整页齐了再接尾。
      final List<DiscoveryEntry> base = append
          ? List<DiscoveryEntry>.of(_entries)
          : const <DiscoveryEntry>[];
      final DiscoveryAggregateResult result = await appModel
          .mediaDiscoveryService
          .load(
            request,
            sourceId: _sourceId == kDiscoveryAllSourcesId ? null : _sourceId,
            disabledSourceIds: _sourceId == kDiscoveryAllSourcesId
                ? appModel.discoveryDisabledSourceIds
                : const <String>{},
            // 渐进交付：快源先上屏，不等慢源（模式与漫画全源搜索一致）。
            onUpdate: append
                ? null
                : (DiscoveryAggregateResult partial) {
                    if (!mounted || seq != _loadSeq) return;
                    setState(() {
                      _result = partial;
                      _failures = deduplicateDiscoveryFailures(
                        partial.failures,
                      );
                      _entries
                        ..clear()
                        ..addAll(partial.entries);
                      if (_entries.isNotEmpty) _firstBatchAt ??= DateTime.now();
                    });
                  },
          );
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _result = result;
        _failures = deduplicateDiscoveryFailures(<ExternalProviderFailure>[
          if (append) ..._failures,
          ...result.failures,
        ]);
        _entries
          ..clear()
          ..addAll(base)
          ..addAll(result.entries);
        _loading = false;
        if (append) {
          _appendedEntries
            ..clear()
            ..addAll(result.entries);
          _appendedAt = DateTime.now();
        } else if (_entries.isNotEmpty) {
          _firstBatchAt ??= DateTime.now();
        }
      });
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _loading = false;
        if (append) {
          // 追加页失败不推翻已经显示的结果：页码退回、页尾给重试。
          _page--;
          _loadMoreFailed = true;
        } else {
          _error = e;
        }
      });
    }
  }

  /// 翻下一页（滚到底自动触发 / 页尾按钮）。在途请求、没有下一页、上一次追加
  /// 失败未重试时都不发。
  void _loadMore() {
    final DiscoveryAggregateResult? result = _result;
    if (_loading || _loadMoreFailed || result == null || !result.hasMore) {
      return;
    }
    _page++;
    unawaited(_load(append: true));
  }

  void _retryLoadMore() {
    setState(() => _loadMoreFailed = false);
    _loadMore();
  }

  void _selectKind(DiscoveryMediaKind kind) {
    if (kind == _kind) return;
    setState(() {
      _kind = kind;
      _sourceId = kDiscoveryAllSourcesId;
      _pathStack.clear();
    });
    unawaited(_load());
  }

  void _selectSource(String sourceId) {
    if (sourceId == _sourceId) return;
    setState(() {
      _sourceId = sourceId;
      _pathStack.clear();
    });
    unawaited(_load());
  }

  void _openFolder(DiscoveryFolder folder) {
    setState(() {
      // 聚合模式下点进某源的目录 = 隐式切到该源（深层路径是源内语义）。
      _sourceId = folder.sourceId;
      _pathStack.add((folder.path, folder.title));
    });
    unawaited(_load());
  }

  /// 输入中：停顿 [kDiscoverySearchDebounce] 后按 [_submitSearch] 语义自动搜索。
  ///
  /// 输入一变就作废在途请求（与视频发现页 `_scheduleSearch` 同一条纪律）：等防抖
  /// 触发才作废的话，上一个关键词晚到的结果会在用户已经在打下一个词时顶掉列表。
  void _scheduleSearch(String _) {
    _loadSeq++;
    _searchDebounce.schedule(() {
      if (mounted) _submitSearch();
    });
  }

  /// 提交搜索/清空搜索：把草稿提交成 [_query]，路径栈属于上一轮浏览，必须先清掉。
  ///
  /// 防抖触发、回车、清空三条路都走这里，所以「输入停顿自动搜」同样会清路径栈
  /// （BUG-1768：搜索词与目录路径互斥）。
  void _submitSearch() {
    _searchDebounce.cancel();
    setState(() {
      _query = _queryCtrl.text.trim();
      _pathStack.clear();
    });
    unawaited(_load());
  }

  void _popFolder() {
    if (_pathStack.isEmpty) return;
    setState(() => _pathStack.removeLast());
    unawaited(_load());
  }

  Future<void> _download(DiscoveryResourceItem item) async {
    final AppModel? appModel = _resolveAppModel();
    if (appModel == null || !item.isDownloadable) return;
    // 「解析中」只对 torrent 有意义（要先向来源取种子）；直链直接入队。
    final bool torrent = item.payloadKind == DiscoveryPayloadKind.torrent;
    final String resolvingKey = '${item.sourceId}\u0000${item.id}';
    if (torrent) {
      if (!_resolvingTorrentIds.add(resolvingKey)) return;
      if (mounted) setState(() {});
    }
    try {
      showDownloadStartNotices(
        await startDiscoveryItemDownload(
          context: context,
          appModel: appModel,
          item: item,
        ),
      );
    } finally {
      if (torrent) {
        _resolvingTorrentIds.remove(resolvingKey);
        if (mounted) setState(() {});
      }
    }
  }

  String _kindLabel(DiscoveryMediaKind kind) => discoveryMediaKindLabel(kind);

  /// 汉化分类的 i18n 标签（BUG-1910：带类型的字段 + i18n，不是源里的硬编码中文）。
  static String _localizationLabel(DiscoveryGameLocalization value) =>
      _GameTypeFilter.values
          .firstWhere((_GameTypeFilter f) => f.value == value)
          .label;

  /// 结果块副行文字：来源 + 日期 + 做种 / 下载 + 源备注。大小作巨号另排在行尾，
  /// 汉化分类 / 疑似漫画是副行里的 chip（设计稿第 4 节「结果块」）。
  String _subtitleFor(
    DiscoveryResourceItem item,
    MediaDiscoveryService service,
  ) {
    final int? seeders = item.seeders;
    final int? leechers = item.leechers;
    final List<String> parts = <String>[
      _sourceDisplayName(service, item.sourceId),
      if (item.dateText != null) formatDiscoveryDate(item.dateText!),
      if (seeders != null)
        leechers != null
            ? t.discovery_seeders_leechers(seeders: seeders, leechers: leechers)
            : t.discovery_seeders_count(n: seeders),
      if (item.note != null) item.note!,
    ];
    return parts.join(' · ');
  }

  /// 来源块 / 选中页头的 chip：能力（可浏览 / 仅搜索）+ 出处（预置 / 用户添加）。
  List<String> _sourceChips(MediaDiscoverySource source) => <String>[
    source.capabilities.supportsBrowse
        ? t.discovery_source_chip_browsable
        : t.discovery_source_chip_search_only,
    source.isUserConfigured
        ? t.discovery_source_chip_user_added
        : t.discovery_source_chip_preset,
  ];

  /// 页面动作：AI 找资源 +「⋯」。在库页 / 浏览外壳里登记进外壳的动作槽（浮动
  /// 顶栏右侧，切域随之替换）；不在外壳里时排在搜索行末尾。
  List<Widget> _buildActions() => <Widget>[
    if (widget.onAiAcquire case final ValueChanged<String> onAiAcquire)
      DiscoveryAiAcquireButton(
        key: const ValueKey<String>('media-discovery-ai-acquire'),
        onPressed: () => onAiAcquire(_queryCtrl.text),
      ),
    _buildMoreMenu(),
  ];

  /// 「⋯」：刷新、管理来源、隐藏无做种、隐藏疑似漫画、Nyaa 质量过滤（设计稿
  /// 「顶栏清单」）。后三项是持久化偏好，各自只在对当前结果有意义时出现；被它们
  /// 藏掉的条数在结果尾的「已隐藏 n 条」行可见。
  Widget _buildMoreMenu() {
    final AppModel? appModel = _appModel;
    final bool canRefresh =
        appModel != null && _idleMode(appModel) == _DiscoveryIdle.none;
    final bool seederItem = _hasSeederEntries;
    final bool mangaItem =
        _kind == DiscoveryMediaKind.novel && _hasContentHints;
    final VoidCallback? manage = widget.onManageSources;
    return FushiOverflowMenu<VoidCallback>(
      key: const ValueKey<String>('discovery_more_menu'),
      tooltip: t.common_more_actions,
      onSelected: (VoidCallback action) => action(),
      items: <PopupMenuEntry<VoidCallback>>[
        FushiPopupMenuItem<VoidCallback>(
          key: const ValueKey<String>('discovery_refresh'),
          label: t.refresh,
          icon: FushiIcons.refresh,
          enabled: canRefresh,
          value: () => unawaited(_load()),
        ),
        if (manage != null)
          FushiPopupMenuItem<VoidCallback>(
            key: const ValueKey<String>('discovery_manage_sources'),
            label: t.manga_discovery_empty_action,
            icon: FushiIcons.settings,
            value: manage,
          ),
        if (seederItem)
          FushiPopupMenuItem<VoidCallback>(
            key: const ValueKey<String>('discovery_filter_hide_zero_seeders'),
            label: t.discovery_filter_hide_zero_seeders,
            icon: FushiIcons.filter,
            selected: _hideZeroSeeders,
            value: () => _setHideZeroSeeders(!_hideZeroSeeders),
          ),
        if (mangaItem)
          FushiPopupMenuItem<VoidCallback>(
            key: const ValueKey<String>(
              'discovery_filter_hide_suspected_manga',
            ),
            label: t.discovery_filter_hide_suspected_manga,
            icon: FushiIcons.filter,
            selected: _hideSuspectedManga,
            value: () => _setHideSuspectedManga(!_hideSuspectedManga),
          ),
        if (_nyaaFilterAvailable)
          for (final NyaaQualityFilter f in NyaaQualityFilter.values)
            FushiPopupMenuItem<VoidCallback>(
              key: ValueKey<String>('discovery_nyaa_filter_${f.index}'),
              label: switch (f) {
                NyaaQualityFilter.all => t.discovery_nyaa_filter_all,
                NyaaQualityFilter.noRemakes =>
                  t.discovery_nyaa_filter_no_remakes,
                NyaaQualityFilter.trustedOnly =>
                  t.discovery_nyaa_filter_trusted_only,
              },
              selected: _nyaaQualityFilter == f,
              value: () => _setNyaaQualityFilter(f),
            ),
      ],
    );
  }

  /// 内容第一行：来源下拉 + 搜索框（随内容滚走，顶栏只留动作）；下面一行是
  /// 媒体域 chip（搜索前常驻）与游戏汉化筛选。
  Widget _buildControls(BuildContext context, {required bool actionsInShell}) {
    final List<MediaDiscoverySource> sources =
        _appModel?.mediaDiscoveryService.sourcesFor(_kind) ??
        const <MediaDiscoverySource>[];
    return DiscoveryHeaderControls(
      sources: <DiscoverySourceOption>[
        for (final MediaDiscoverySource source in sources)
          DiscoverySourceOption(id: source.id, label: source.displayName),
      ],
      selectedSourceId: _sourceId,
      onSourceSelected: _selectSource,
      searchController: _queryCtrl,
      searchFocusNode: _searchFocus,
      searchHintText: t.discovery_search_hint,
      onSearchChanged: _scheduleSearch,
      onSearchSubmitted: (String _) => _submitSearch(),
      onSearchCleared: () {
        _queryCtrl.clear();
        _submitSearch();
      },
      trailing: actionsInShell ? const <Widget>[] : _buildActions(),
      leading: _buildHeaderLeading(),
      // Apple：第三层筛选是搜索框右边的 pull-down（M3E 不读）。
      appleFilters: isGlassDesign(context) ? _appleFilters() : const <Widget>[],
    );
  }

  /// 汉化筛选是否出现（设计稿「筛选 chip」）：只在游戏域、正在显示结果（有查询
  /// 或在某源的目录里）时出现；BUG-1910 现状——结果里有带分类的条目才出，
  /// 但选了非「全部」后一直保留（筛到 0 条也不把自己藏掉）。
  bool get _gameTypeFilterVisible {
    final AppModel? appModel = _appModel;
    if (_kind != DiscoveryMediaKind.game || appModel == null) return false;
    if (_idleMode(appModel) != _DiscoveryIdle.none) return false;
    return _gameTypeFilterAvailable || _gameTypeFilter != _GameTypeFilter.all;
  }

  /// 搜索框下的筛选行：媒体域 chip（多域时，决定查哪些源，搜索前就常驻）+
  /// 游戏汉化筛选。两组排进同一条单行，组间一道竖分隔线，放不下由共享头部横滑。
  Widget? _buildHeaderLeading() {
    final List<List<Widget>> groups = <List<Widget>>[
      if (widget.kinds.length > 1)
        <Widget>[
          for (final DiscoveryMediaKind kind in widget.kinds)
            FushiSelectableChip(
              key: ValueKey<String>('discovery_kind_${kind.name}'),
              label: _kindLabel(kind),
              selected: _kind == kind,
              onSelected: (_) => _selectKind(kind),
            ),
        ],
      if (_gameTypeFilterVisible)
        <Widget>[
          for (final _GameTypeFilter f in _GameTypeFilter.values)
            FushiSelectableChip(
              key: ValueKey<String>('discovery_game_type_${f.name}'),
              label: f.label,
              selected: _gameTypeFilter == f,
              // 纯客户端过滤：不重新请求，只换渲染集合。
              onSelected: (_) => setState(() => _gameTypeFilter = f),
            ),
        ],
    ];
    if (groups.isEmpty) return null;
    return Row(
      key: const ValueKey<String>('discovery_filter_bar'),
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < groups.length; i++) ...<Widget>[
          if (i > 0)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: SizedBox(
                height: 24,
                child: FushiVerticalDivider(width: 1),
              ),
            ),
          for (int j = 0; j < groups[i].length; j++) ...<Widget>[
            if (j > 0) const SizedBox(width: 8),
            groups[i][j],
          ],
        ],
      ],
    );
  }

  /// 结果尾的「已隐藏 K 条疑似不相关 / N 条无人做种 / M 条疑似漫画 · 显示」行，
  /// 点一下临时显示全部（不改偏好）。
  Widget _buildHiddenNotice(
    BuildContext context,
    int hiddenIrrelevant,
    int hiddenZeroSeeders,
    int hiddenManga,
  ) {
    final String text = <String>[
      if (hiddenIrrelevant > 0)
        t.discovery_hidden_irrelevant_count(n: hiddenIrrelevant),
      if (hiddenZeroSeeders > 0)
        t.discovery_hidden_zero_seeders_count(n: hiddenZeroSeeders),
      if (hiddenManga > 0)
        t.discovery_hidden_suspected_manga_count(n: hiddenManga),
    ].join(' · ');
    return FushiListItem(
      key: const ValueKey<String>('discovery_hidden_reveal'),
      leading: const FushiIcon(FushiIcons.visibilityOff),
      title: Text(text),
      titleMaxLines: null,
      trailing: Text(t.discovery_hidden_show),
      onTap: () => setState(() => _revealHidden = true),
    );
  }

  /// 资源文件名（装盒取字号、完整换行）+ trusted 绿 / remake 红徽标。
  Widget _buildResourceTitle(BuildContext context, DiscoveryResourceItem item) {
    if (isGlassDesign(context)) return _buildAppleResourceTitle(item);
    final Widget title = DiscoveryFitFileName(text: item.title);
    if (!item.trusted && !item.remake) return title;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(child: title),
        if (item.remake)
          FushiTag(
            key: const ValueKey<String>('discovery_badge_remake'),
            text: t.discovery_badge_remake,
            // 与「可信」同一中性徽标底，语义只在错误色文字上。
            backgroundColor: fushiNeutralTagColors(context).background,
            foregroundColor: fushiStatusColor(context, FushiStatusTone.error),
          )
        else
          FushiTag(
            key: const ValueKey<String>('discovery_badge_trusted'),
            text: t.discovery_badge_trusted,
            backgroundColor: fushiNeutralTagColors(context).background,
            foregroundColor: fushiStatusColor(context, FushiStatusTone.success),
          ),
      ],
    );
  }

  /// 单源页头：选中来源的身份色条（「← 全部来源」+ glyph + 名称 + 能力 chip），
  /// 在目录里时下面接面包屑。「全部来源」时没有页头。
  Widget? _buildSourceHeader(
    BuildContext context,
    MediaDiscoveryService service,
  ) {
    if (_sourceId == kDiscoveryAllSourcesId) return null;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final MediaDiscoverySource? source = service.sourceById(_sourceId);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          DiscoverySourceSelectedHeader(
            key: ValueKey<String>('discovery_source_header_$_sourceId'),
            sourceId: _sourceId,
            name: _sourceDisplayName(service, _sourceId),
            chips: source == null ? const <String>[] : _sourceChips(source),
            onBack: () => _selectSource(kDiscoveryAllSourcesId),
          ),
          if (_pathStack.isNotEmpty) _buildBreadcrumb(context),
        ],
      ),
    );
  }

  /// 目录下钻面包屑：「↑ 上一级」+「根目录 › … › 当前目录」。
  Widget _buildBreadcrumb(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String path = <String>[
      t.discovery_breadcrumb_root,
      for (final (String, String) e in _pathStack) e.$2,
    ].join(' › ');
    return Padding(
      padding: EdgeInsets.only(top: tokens.spacing.gap),
      child: Row(
        children: <Widget>[
          FushiTextButton.icon(
            key: const ValueKey<String>('discovery_breadcrumb_up'),
            onPressed: _popFolder,
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const FushiIcon(FushiIcons.arrowUp),
            label: Text(t.discovery_breadcrumb_up),
          ),
          SizedBox(width: tokens.spacing.gap),
          Expanded(
            child: Text(
              path,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: tokens.type.listSubtitle.copyWith(
                color: tokens.surfaces.onVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 「全部来源」+ 空查询的引导态（「发现首页」）：域引导首块（本页唯一加大
  /// 块）+ 来源色块。把候选来源摆出来让用户点，而不是把某个恰好支持浏览的源的
  /// 根目录冒充成聚合结果（BUG-1711）。
  ///
  /// 宽屏是拼贴：引导块占左半、两块高，右半排两行来源块，其余来源块在下面等宽
  /// 排开；窄屏引导块整行，来源块在下面。能力（可浏览 / 仅搜索）是块内 chip，
  /// 不再按能力分两区。
  Widget _buildSourcePicker(
    BuildContext context,
    MediaDiscoveryService service,
  ) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<MediaDiscoverySource> sources = service.sourcesFor(_kind);
    final double gap = tokens.spacing.gap;
    final double page = tokens.spacing.page;
    final VoidCallback? manage = widget.onManageSources;
    // 设计稿 11-20 #13：引导降成一行横幅，来源块回到首行；网格末尾放一张与来源块
    // 同尺寸的「添加来源」块（有去处时），不再让一张半空的引导卡占三块来源的面积。
    final List<Widget> blocks = <Widget>[
      for (final MediaDiscoverySource source in sources)
        _buildSourceCard(context, source),
      if (manage != null)
        DiscoveryAddSourceBlock(
          key: const ValueKey<String>('discovery_guide_manage'),
          // 书 / 游戏的来源不是扩展（内置发现源 + 自配服务器，都在「设置 › 在线
          // 服务」），副文案写「管理来源」；iOS 只有用户服务器（合规门）。
          hint: StoreRestrictedCapability.externalDiscovery.isAvailable
              ? t.manga_discovery_empty_action
              : t.discovery_source_add_hint_server,
          onTap: manage,
        ),
    ];
    return Padding(
      padding: EdgeInsets.fromLTRB(page, gap, page, tokens.spacing.section),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiStaggeredEntrance(
            index: 0,
            child: _buildPickerBanner(context, sources),
          ),
          if (blocks.isNotEmpty) ...<Widget>[
            SizedBox(height: gap),
            DiscoverySourceBlockGrid(indexOffset: 1, children: blocks),
          ],
        ],
      ),
    );
  }

  /// 域引导横幅（一行）：图标 + 引导句 + 能力计数；有可浏览来源时结尾给「浏览
  /// <第一个可浏览源>」。一个来源都没有时写「还没有来源」（去处是网格里的「添加
  /// 来源」块）。MD3 secondaryContainer 底 / Apple 实色分组卡。
  Widget _buildPickerBanner(
    BuildContext context,
    List<MediaDiscoverySource> sources,
  ) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final bool apple = isGlassDesign(context);
    final Color? foreground = apple
        ? null
        : theme.colorScheme.onSecondaryContainer;
    // 副文字实色（DI16：不再叠透明度）。
    final Color secondary = apple
        ? appleColorsOf(context).secondaryLabel
        : theme.colorScheme.onSecondaryContainer;
    final int browsable = sources
        .where((MediaDiscoverySource s) => s.capabilities.supportsBrowse)
        .length;
    MediaDiscoverySource? firstBrowsable;
    for (final MediaDiscoverySource s in sources) {
      if (s.capabilities.supportsBrowse) {
        firstBrowsable = s;
        break;
      }
    }
    final MediaDiscoverySource? first = firstBrowsable;
    return FushiCard(
      key: const ValueKey<String>('discovery_pick_banner'),
      color: apple ? null : theme.colorScheme.secondaryContainer,
      borderRadius: discoveryHeroRadius(context),
      padding: EdgeInsetsDirectional.fromSTEB(
        tokens.spacing.card,
        tokens.spacing.gap,
        tokens.spacing.gap,
        tokens.spacing.gap,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 40),
        child: Row(
          spacing: tokens.spacing.gap,
          children: <Widget>[
            FushiIcon(
              _kind == DiscoveryMediaKind.game
                  ? FushiIcons.games
                  : FushiIcons.travelExplore,
              size: 20,
              color: foreground ?? theme.colorScheme.onSurfaceVariant,
            ),
            Expanded(
              child: Wrap(
                spacing: tokens.spacing.gap,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  Text(
                    sources.isEmpty
                        ? t.discovery_guide_no_sources
                        : t.discovery_source_pick_hint,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: foreground,
                    ),
                  ),
                  if (sources.isNotEmpty)
                    Text(
                      t.discovery_guide_capability_counts(
                        browsable: browsable,
                        searchOnly: sources.length - browsable,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: secondary,
                      ),
                    ),
                ],
              ),
            ),
            if (first != null)
              FushiTextButton(
                key: const ValueKey<String>('discovery_guide_browse'),
                onPressed: () => _selectSource(first.id),
                child: Text(
                  t.discovery_guide_browse_source(source: first.displayName),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 一个来源块：glyph + 源名 +「可浏览 / 仅搜索」「预置 / 用户添加」chip。游戏 /
  /// 书源没有封面，不画封面条；不预取目录计数、不显示上次浏览（DI18）。
  Widget _buildSourceCard(BuildContext context, MediaDiscoverySource source) {
    return DiscoverySourceBlock(
      key: ValueKey<String>('discovery_source_pick_${source.id}'),
      focusId: FushiFocusId('discovery-source-pick-${source.id}'),
      sourceId: source.id,
      name: source.displayName,
      chips: _sourceChips(source),
      onTap: () => _selectSource(source.id),
    );
  }

  Widget _buildBody(BuildContext context, {required bool actionsInShell}) {
    final AppModel? appModel = _appModel;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final _DiscoveryIdle? idle = appModel == null ? null : _idleMode(appModel);
    final MediaDiscoveryService? service = appModel?.mediaDiscoveryService;
    final Widget? header = service == null
        ? null
        : _buildSourceHeader(context, service);
    // 整页一个滚动视图：搜索行是内容第一行（随内容滚走），下面是单源页头 /
    // 面包屑，再下面是当前状态（引导 / 结果 / 占位）。三段的 sliver 槽位恒定，
    // 搜索框不会因为状态切换被重挂（输入中丢焦点）。
    return FushiEntranceScope(
      replayKey: Object.hash(_kind, _sourceId, idle, _pathStack.length),
      child: NotificationListener<ScrollNotification>(
        onNotification: (ScrollNotification notification) {
          if (notification.metrics.axis == Axis.vertical &&
              idle == _DiscoveryIdle.none &&
              discoveryShouldLoadMore(notification.metrics)) {
            _loadMore();
          }
          return false;
        },
        // 手机下拉刷新（设计稿「⋯：刷新…手机同时下拉刷新」）：与「⋯ › 刷新」
        // 同一判据——引导态 / 只能搜索态没有可重拉的请求，下拉直接收起。
        child: FushiRefreshIndicator(
          onRefresh: () async {
            if (idle == _DiscoveryIdle.none) await _load();
          },
          child: CustomScrollView(
            key: const ValueKey<String>('discovery-results-scroll'),
            controller: _resultsScroll,
            slivers: <Widget>[
              // 让出叠放在上面的浮动工具区（外壳页签 / 动作）。
              const SliverToBoxAdapter(child: FushiFloatingChromeInsetSpacer()),
              SliverToBoxAdapter(
                key: const ValueKey<String>('discovery_controls_slot'),
                child: Padding(
                  padding: EdgeInsets.only(top: tokens.spacing.gap),
                  child: _buildControls(
                    context,
                    actionsInShell: actionsInShell,
                  ),
                ),
              ),
              SliverToBoxAdapter(
                key: const ValueKey<String>('discovery_source_header_slot'),
                child: header == null
                    ? const SizedBox.shrink()
                    : FushiStaggeredEntrance(index: 0, child: header),
              ),
              ..._buildStateSlivers(context, idle),
            ],
          ),
        ),
      ),
    );
  }

  /// 当前状态的 sliver：引导 / 只能搜索提示 / 失败 / 加载 / 空 / 结果。
  List<Widget> _buildStateSlivers(BuildContext context, _DiscoveryIdle? idle) {
    Widget fill(Widget child) =>
        SliverFillRemaining(hasScrollBody: false, child: child);
    final AppModel? appModel = _appModel;
    if (appModel == null || idle == null) {
      return <Widget>[
        fill(
          FushiPlaceholderMessage(
            icon: FushiIcons.search,
            message: t.discovery_enter_query_hint,
          ),
        ),
      ];
    }
    final MediaDiscoveryService service = appModel.mediaDiscoveryService;
    final DiscoveryDownloadQueue queue = appModel.discoveryDownloadQueue;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);

    switch (idle) {
      case _DiscoveryIdle.pickSource:
        return <Widget>[
          SliverSafeArea(
            top: false,
            sliver: SliverToBoxAdapter(
              child: isGlassDesign(context)
                  ? _buildAppleSourcePicker(context, service)
                  : _buildSourcePicker(context, service),
            ),
          ),
        ];
      case _DiscoveryIdle.queryRequired:
        return <Widget>[
          fill(
            FushiPlaceholderMessage(
              icon: FushiIcons.search,
              message: t.discovery_source_query_required,
            ),
          ),
        ];
      case _DiscoveryIdle.none:
        break;
    }

    if (_error != null) {
      return <Widget>[
        fill(
          FushiPlaceholderMessage(
            key: const ValueKey<String>('discovery_load_error'),
            icon: FushiIcons.cloudOff,
            message: t.discovery_partial_failure,
            action: _retryButton(),
          ),
        ),
      ];
    }
    if (_loading && _entries.isEmpty) {
      return <Widget>[fill(const FushiLoadingView())];
    }
    final DiscoveryAggregateResult? result = _result;
    if (_entries.isEmpty) {
      // BUG-1770：「一个源都没成功，而且有失败」不是「没有结果」——整源失败显示
      // 成「无结果」，用户会以为那个目录是空的。判据用模型层的 `isTotalFailure`。
      if (result != null && result.isTotalFailure) {
        return <Widget>[
          fill(
            FushiPlaceholderMessage(
              key: const ValueKey<String>('discovery_sources_unavailable'),
              icon: FushiIcons.cloudOff,
              message: t.discovery_sources_unavailable,
              // 印来源展示名而不是接线 id（与视频发现页横幅同一条，BUG-2430）。
              detail: <String>{
                for (final ExternalProviderFailure f in result.failures)
                  _sourceDisplayName(service, f.providerId),
              }.join(' · '),
              action: _retryButton(),
            ),
          ),
        ];
      }
      return <Widget>[
        fill(
          FushiPlaceholderMessage(
            icon: FushiIcons.searchOff,
            message: t.discovery_empty,
          ),
        ),
      ];
    }

    final ({
      List<DiscoveryEntry> entries,
      int hiddenIrrelevant,
      int hiddenZeroSeeders,
      int hiddenManga,
    })
    visible = _visible;
    final int hidden =
        visible.hiddenIrrelevant +
        visible.hiddenZeroSeeders +
        visible.hiddenManga;
    final List<ExternalProviderFailure> failures = _failures;
    final String? title = _resultsTitle();
    final int sourceCount = <String>{
      for (final DiscoveryEntry e in _entries) e.sourceId,
    }.length;
    return <Widget>[
      if (failures.isNotEmpty)
        SliverToBoxAdapter(
          child: DiscoveryProviderWarningBanner(
            key: const ValueKey<String>('discovery_provider_warning'),
            failures: failures,
            displayNameFor: (String id) => _sourceDisplayName(service, id),
          ),
        ),
      if (title != null && isGlassDesign(context))
        // Apple：结果头 = 货架头字阶（标题 + 「n 个来源 · m 条」副行）。
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              appleDiscoveryPageInset(context),
              16,
              appleDiscoveryPageInset(context),
              4,
            ),
            child: AppleDiscoveryShelfHeader(
              title: title,
              subtitle: t.discovery_results_summary(
                sources: sourceCount,
                n: visible.entries.length,
              ),
            ),
          ),
        )
      else if (title != null)
        SliverToBoxAdapter(
          child: FushiSectionTitle(
            title,
            shrinkTrailing: true,
            trailing: Text(
              t.discovery_results_summary(
                sources: sourceCount,
                n: visible.entries.length,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tokens.type.metadata.copyWith(
                color: tokens.surfaces.onVariant,
              ),
            ),
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.page,
              tokens.spacing.card,
              tokens.spacing.page,
              tokens.spacing.gap,
            ),
          ),
        ),
      // 筛选把结果筛到 0 条：筛选行仍在（不把自己藏掉），这里说明没有结果。
      if (visible.entries.isEmpty)
        SliverToBoxAdapter(
          child: FushiPlaceholderMessage(
            key: const ValueKey<String>('discovery_filtered_empty'),
            icon: FushiIcons.searchOff,
            message: t.discovery_empty,
          ),
        ),
      _buildResultsList(context, visible.entries, service, queue),
      // 「已隐藏 n 条 · 显示」在结果尾常驻（有被藏条目时，DI14）。
      if (hidden > 0)
        SliverToBoxAdapter(
          child: FushiGroupedList(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.page,
              tokens.spacing.card,
              tokens.spacing.page,
              0,
            ),
            children: <Widget>[
              _buildHiddenNotice(
                context,
                visible.hiddenIrrelevant,
                visible.hiddenZeroSeeders,
                visible.hiddenManga,
              ),
            ],
          ),
        ),
      // 玻璃设计下首页 extendBody，悬浮导航胶囊的高度并进了 MediaQuery 底部
      // padding：页尾垫到胶囊之上，否则最后几行与「加载更多 / 重试」被胶囊盖住。
      SliverSafeArea(
        top: false,
        sliver: SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.page,
              tokens.spacing.gap,
              tokens.spacing.page,
              tokens.spacing.section,
            ),
            child: _loadMoreFailed
                ? Center(
                    child: FushiTextButton.icon(
                      key: const ValueKey<String>('discovery_load_more_retry'),
                      onPressed: _retryLoadMore,
                      icon: const FushiIcon(FushiIcons.refresh),
                      label: Text(t.retry),
                    ),
                  )
                : result != null && result.hasMore
                ? Center(
                    // 自动翻页之外的兜底：键盘 / 手柄焦点走到页尾、或首页不满
                    // 一屏没有滚动事件可等时，仍能手动拉下一页。
                    child: _loading
                        ? const FushiLoadingView(compact: true)
                        : FushiTextButton(
                            key: const ValueKey<String>('discovery_load_more'),
                            onPressed: _loadMore,
                            child: Text(t.discovery_load_more),
                          ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ),
    ];
  }

  /// 结果列表：一组 inset grouped 实色分组，长列表懒建。错峰进场——首批按可见
  /// 序播一次；翻页追加的只给新块播（序号从新一页的第一条算），已在屏上的旧块
  /// 不重播；滚动带出来的块直接出现（不拖影）。
  Widget _buildResultsList(
    BuildContext context,
    List<DiscoveryEntry> entries,
    MediaDiscoveryService service,
    DiscoveryDownloadQueue queue,
  ) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Map<DiscoveryEntry, int> order = Map<DiscoveryEntry, int>.identity();
    int first = 0;
    int appended = 0;
    for (final DiscoveryEntry e in entries) {
      order[e] = _appendedEntries.contains(e) ? appended++ : first++;
    }
    return AnimatedBuilder(
      animation: EngineListenable(queue),
      builder: (BuildContext context, Widget? _) => SliverFushiGroupedList(
        itemCount: entries.length,
        itemMargin: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
        separatorIndent: 64,
        itemBuilder: (BuildContext context, int index) {
          final DiscoveryEntry entry = entries[index];
          final bool isAppended = _appendedEntries.contains(entry);
          // 窗口判定在块**挂载**那一刻做（[_DiscoveryResultEntrance] 只读一次）：
          // 懒列表滚动时才建出来的块要看「此刻」是否仍在窗口内，不能用整页
          // build 时算好的布尔（那样页面不重建时滚出来的块全会补播进场）。
          return _DiscoveryResultEntrance(
            key: ObjectKey(entry),
            batchAt: isAppended ? _appendedAt : _firstBatchAt,
            index: order[entry] ?? index,
            child: _buildEntryRow(context, entry, service, queue),
          );
        },
      ),
    );
  }

  /// 结果区标题：有关键词（且不在目录里）=「『关键词』的结果」，其余不出标题
  /// （单源 / 目录已由页头条与面包屑点名）。
  String? _resultsTitle() {
    if (_query.isNotEmpty && _pathStack.isEmpty) {
      return t.discovery_results_for_query(query: _query);
    }
    return null;
  }

  /// 资源行行首：源给了封面（OPDS / 游戏站）就放一张 2:3 小封面，否则是来源
  /// 取色 glyph（与来源块同色，同源各处同色）。
  Widget _buildResourceLeading(
    BuildContext context,
    DiscoveryResourceItem entry,
    MediaDiscoveryService service,
  ) {
    final String cover = entry.coverUrl?.trim() ?? '';
    if (cover.isEmpty) {
      return DiscoverySourceGlyph(
        sourceId: entry.sourceId,
        name: _sourceDisplayName(service, entry.sourceId),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 36,
        height: 54,
        child: DiscoveryImageCover(
          // 私有目录（Komga 等）的封面要带源给的凭据头，否则 401 永远是占位图
          // （BUG-3535）。头只由源按同源规则填；磁盘缓存只按 URL 记键。
          image: discoveryCoverImage(cover, entry.coverHeaders),
          placeholderIcon: FushiIcons.file,
        ),
      ),
    );
  }

  /// 文件夹行行首：来源身份色的方块 + 文件夹图标。
  Widget _buildFolderLeading(
    BuildContext context,
    DiscoveryFolder entry,
    MediaDiscoveryService service,
  ) {
    if (isGlassDesign(context)) return _buildAppleFolderLeading(entry, service);
    return DiscoverySourceColorsBuilder(
      sourceId: entry.sourceId,
      name: _sourceDisplayName(service, entry.sourceId),
      builder: (BuildContext context, FushiCoverBlockColors colors) =>
          SizedBox.square(
            dimension: kDiscoverySourceGlyphSize,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.container,
                borderRadius: BorderRadius.circular(FushiRadii.controlValue),
              ),
              child: FushiIcon(
                FushiIcons.folder,
                size: 22,
                color: colors.onContainer,
              ),
            ),
          ),
    );
  }

  /// 结果块副行：汉化 / 疑似漫画 chip + 来源 · 日期 · 做种。
  Widget _buildResourceMeta(
    BuildContext context,
    DiscoveryResourceItem item,
    MediaDiscoveryService service,
  ) {
    if (isGlassDesign(context)) return _buildAppleResourceMeta(item, service);
    final ({Color background, Color foreground}) tag = fushiNeutralTagColors(
      context,
    );
    final DiscoveryGameLocalization? localization = item.gameLocalization;
    final List<Widget> chips = <Widget>[
      if (localization != null)
        FushiTag(
          key: ValueKey<String>('discovery_item_localization_${item.id}'),
          text: _localizationLabel(localization),
          backgroundColor: tag.background,
          foregroundColor: tag.foreground,
        ),
      if (item.contentHint == DiscoveryContentHint.manga)
        FushiTag(
          text: t.discovery_content_hint_manga,
          backgroundColor: tag.background,
          foregroundColor: fushiStatusColor(context, FushiStatusTone.warning),
        ),
    ];
    final Widget line = Text(_subtitleFor(item, service));
    if (chips.isEmpty) return line;
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[...chips, line],
    );
  }

  /// 结果块行尾：大小作巨号 + 下载钮（视觉 44、热区 48dp）/ 解析中转圈。
  Widget? _buildResourceTrailing(
    BuildContext context,
    DiscoveryResourceItem entry,
    DiscoveryDownloadQueue queue,
  ) {
    // torrent 解析中（页内状态，还没进任何队列）才转圈；直链任务的进度已在
    // 副行下的行内状态里，未结束时只收起下载按钮防重复入队。
    final Widget? action =
        _resolvingTorrentIds.contains('${entry.sourceId}\u0000${entry.id}')
        ? const SizedBox.square(
            dimension: 48,
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: FushiCircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        : entry.isDownloadable && !queue.isPending(entry)
        ? FushiIconButton(
            icon: FushiIcons.download,
            tooltip: t.anime_download_generic_download,
            label: t.anime_download_generic_download,
            onTap: () => unawaited(_download(entry)),
          )
        : null;
    final int? size = entry.sizeBytes;
    if (size == null) return action;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        DiscoverySizeFigure(text: formatDiscoveryBytes(size)),
        if (action != null) ...<Widget>[const SizedBox(width: 4), action],
      ],
    );
  }

  /// 一行结果：目录（可下钻）或资源（可下载）。
  Widget _buildEntryRow(
    BuildContext context,
    DiscoveryEntry entry,
    MediaDiscoveryService service,
    DiscoveryDownloadQueue queue,
  ) {
    return switch (entry) {
      DiscoveryFolder() => FushiListItem(
        leading: _buildFolderLeading(context, entry, service),
        title: Text(entry.title),
        titleMaxLines: null,
        // 目录条目不带来源名，用户看不出这是哪个站的目录。
        subtitle: Text(
          <String>[
            _sourceDisplayName(service, entry.sourceId),
            if (entry.note?.trim().isNotEmpty == true) entry.note!,
            if (entry.itemCount != null)
              t.media_source_count_manga(n: entry.itemCount!),
          ].join(' · '),
        ),
        trailing: const FushiIcon(FushiIcons.chevronRight),
        onTap: () => _openFolder(entry),
      ),
      // 未隐藏时 0 做种条目灰显：死种能看到，但一眼分得出。
      DiscoveryResourceItem() => Opacity(
        key: ValueKey<String>('discovery_item_${entry.sourceId}_${entry.id}'),
        opacity: entry.seeders == 0 ? 0.5 : 1,
        child: FushiListItem(
          leading: _buildResourceLeading(context, entry, service),
          title: _buildResourceTitle(context, entry),
          // 不限行：关键信息常在文件名尾部（卷号 / 版本 / 汉化组），截断就丢了
          // 唯一的区分信息。
          titleMaxLines: null,
          // 下载方式（BT / 直链）+ 外部来源：发现源全是第三方站点，用户要在点
          // 「下载」之前就知道这条走 P2P 还是 HTTP（10-09 所有者）。
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _buildResourceMeta(context, entry, service),
              if (entry.isDownloadable) ...<Widget>[
                const SizedBox(height: 4),
                DownloadSourceTags(
                  method: discoveryTransferMethodOf(entry.payloadKind),
                  // 用户自配的 OPDS / Audiobookshelf 是自己指定的服务器，不标
                  // 外部来源；内置源都是第三方站点。
                  external: isExternalDiscoverySource(service, entry.sourceId),
                ),
              ],
              // 直链下载的行内状态（排队 / 下载中 / 完成 / 失败 + 重试）：与
              // Audiobookshelf 条目页同一个组件、同一条队列。
              if (entry.payloadKind == DiscoveryPayloadKind.httpFile)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: DiscoveryDownloadInlineStatus(
                    key: ValueKey<String>(
                      'discovery_item_status_${entry.sourceId}_${entry.id}',
                    ),
                    queue: queue,
                    sourceId: entry.sourceId,
                    itemId: entry.id,
                    idleBuilder: (BuildContext context) =>
                        const SizedBox.shrink(),
                  ),
                ),
            ],
          ),
          trailing: _buildResourceTrailing(context, entry, queue),
          onTap: entry.isDownloadable
              ? () => unawaited(_download(entry))
              : null,
        ),
      ),
    };
  }

  String _sourceDisplayName(MediaDiscoveryService service, String sourceId) =>
      service.sourceById(sourceId)?.displayName ?? sourceId;

  Widget _retryButton() => FushiFilledButton.icon(
    key: const ValueKey<String>('discovery_retry'),
    onPressed: () => unawaited(_load()),
    icon: const FushiIcon(FushiIcons.refresh),
    label: Text(t.retry),
  );

  @override
  Widget build(BuildContext context) {
    final Widget? navigation = widget.navigation;
    // 在库页 / 浏览外壳里：动作（AI / ⋯）登记进外壳的动作槽，画在浮动顶栏
    // 右侧（[FushiPageHeader] 自己按可见性登记，切域随之替换）；搜索行是内容
    // 第一行、随内容滚走（设计稿第 2 节）。外壳外动作排在搜索行末尾。
    final bool actionsInShell =
        FushiShellTitleScope.maybeActionsSlotOf(context) != null;
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: FushiFloatingChromeOverlay(
        chrome: navigation != null || actionsInShell
            ? FushiPageHeader.customTitle(
                title: navigation ?? const SizedBox.shrink(),
                actions: actionsInShell ? _buildActions() : const <Widget>[],
              )
            : const SizedBox.shrink(),
        child: Builder(
          builder: (BuildContext context) =>
              _buildBody(context, actionsInShell: actionsInShell),
        ),
      ),
    );
  }
}

/// 进场窗口：一批结果到达后多久之内挂载的块还播错峰进场。由动效令牌推出
/// （错峰排满一轮 + 一个 medium 时长），不另立时长常量。
final Duration _kResultsEntranceWindow =
    FushiMotion.staggerStep * FushiMotion.staggerMaxItems + FushiMotion.medium;

bool _withinEntranceWindow(DateTime? at) =>
    at != null && DateTime.now().difference(at) <= _kResultsEntranceWindow;

/// 一个结果块的进场：挂载时判一次「所属批次（首批 / 某次翻页追加）是否仍在
/// 进场窗口内」，之后不再改判——`enabled` 中途翻转会让 [FushiEntranceScope]
/// 换代、把正在播的进场直接跳到终态。
class _DiscoveryResultEntrance extends StatefulWidget {
  const _DiscoveryResultEntrance({
    required this.batchAt,
    required this.index,
    required this.child,
    super.key,
  });

  /// 所属批次上屏的时刻；null = 不播。
  final DateTime? batchAt;

  /// 批次内的错峰序号。
  final int index;
  final Widget child;

  @override
  State<_DiscoveryResultEntrance> createState() =>
      _DiscoveryResultEntranceState();
}

class _DiscoveryResultEntranceState extends State<_DiscoveryResultEntrance> {
  late final bool _open = _withinEntranceWindow(widget.batchAt);

  @override
  Widget build(BuildContext context) => FushiEntranceScope(
    enabled: _open,
    child: FushiStaggeredEntrance(index: widget.index, child: widget.child),
  );
}

/// 结果文件名：按排版角色从大到小（titleMedium → titleSmall → bodySmall）取
/// 三行内排得下的最大一档；最小一档也排不下就按它完整换行、块高增高——不截断
/// （关键信息常在文件名尾部）。是真正的 [Text]（读屏、`find.text` 都命中它）。
class DiscoveryFitFileName extends StatelessWidget {
  const DiscoveryFitFileName({required this.text, super.key});

  final String text;

  /// 期望的最多行数：超过就降一档字号。
  static const int maxLines = 3;

  @override
  Widget build(BuildContext context) {
    final FushiTypography type = context.fushiType;
    final List<TextStyle> candidates = <TextStyle>[
      for (final TextStyle role in <TextStyle>[
        type.titleMedium,
        type.titleSmall,
        type.bodySmall,
      ])
        role.copyWith(fontWeight: FontWeight.w600, height: 1.25),
    ];
    final TextDirection direction = Directionality.of(context);
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 480;
        TextStyle chosen = candidates.last;
        for (final TextStyle style in candidates) {
          final TextPainter painter = TextPainter(
            text: TextSpan(text: text, style: style),
            textDirection: direction,
            textScaler: scaler,
          )..layout(maxWidth: width);
          final bool fits =
              painter.computeLineMetrics().length <= maxLines &&
              painter.minIntrinsicWidth <= width + 0.5;
          painter.dispose();
          if (fits) {
            chosen = style;
            break;
          }
        }
        return Text(text, style: chosen);
      },
    );
  }
}

/// 结果块行尾的巨号大小（设计稿「大小作巨号」）：数值大号粗体强调色，单位小号。
class DiscoverySizeFigure extends StatelessWidget {
  const DiscoverySizeFigure({required this.text, super.key});

  /// `formatDiscoveryBytes` 的输出（「6.2 GB」）。
  final String text;

  @override
  Widget build(BuildContext context) {
    final Color accent = isGlassDesign(context)
        ? appleColorsOf(context).accent
        : Theme.of(context).colorScheme.primary;
    final FushiTypography type = context.fushiType;
    final int split = text.lastIndexOf(' ');
    final String value = split < 0 ? text : text.substring(0, split);
    final String unit = split < 0 ? '' : text.substring(split + 1);
    return Text.rich(
      TextSpan(
        children: <InlineSpan>[
          TextSpan(
            text: value,
            style: type.headlineSmall.copyWith(
              fontWeight: FontWeight.w800,
              height: 1,
              letterSpacing: -0.6,
            ),
          ),
          if (unit.isNotEmpty)
            TextSpan(
              text: ' $unit',
              style: type.labelMedium.copyWith(
                fontWeight: FontWeight.w700,
                height: 1,
              ),
            ),
        ],
      ),
      maxLines: 1,
      style: TextStyle(color: accent),
    );
  }
}

/// 发现页资源行的封面 provider：把源给的封面请求头原样交给磁盘缓存图片加载器
/// （BUG-3535）。空表按「无头」处理——匿名封面不必因为一个空 Map 而换一种
/// provider 形态。
AppCachedHttpImage discoveryCoverImage(
  String url,
  Map<String, String>? headers,
) => AppCachedHttpImage(
  url,
  headers: headers == null || headers.isEmpty ? null : headers,
);
