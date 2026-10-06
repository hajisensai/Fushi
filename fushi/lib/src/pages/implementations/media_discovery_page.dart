import 'dart:async' show unawaited;
import 'package:collection/collection.dart' show mergeSort;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_engine/media/discovery/discovery_download_queue.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/discovery/discovery_labels.dart';
import 'package:fushi/src/media/discovery/media_discovery_service.dart';
import 'package:fushi/src/media/discovery/media_discovery_source.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/nyaa_client.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/discovery/discovery_widgets.dart';
import 'package:fushi/src/pages/implementations/discovery_header.dart';
import 'package:fushi/src/pages/implementations/download_actions.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show
        FushiFloatingChromeInsetPadding,
        FushiFloatingChromeInsetSpacer,
        FushiFloatingChromeOverlay;
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi/src/utils/misc/engine_listenable.dart';
import 'package:fushi/src/media/discovery/sources/nyaa_discovery_source.dart';

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
/// 交互时解析（同 `_buildImport` 的 QuickImportSection 约定）。
class MediaDiscoveryPage extends StatefulWidget {
  const MediaDiscoveryPage({
    required this.kinds,
    this.navigation,
    this.initialSourceId,
    this.onAiAcquire,
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

  @override
  State<MediaDiscoveryPage> createState() => _MediaDiscoveryPageState();
}

/// 引导态来源卡片的最小宽度：按它算列数，宽屏多列、窄屏退成单列。
const double _kSourceCardMinWidth = 280;

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
      _appModel =
          ProviderScope.containerOf(context, listen: false).read(appProvider);
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
      _entries.any((DiscoveryEntry e) =>
          e is DiscoveryResourceItem && e.gameLocalization != null);

  /// 应用游戏汉化筛选后的条目。目录条目（[DiscoveryFolder]）永远保留——它们是
  /// 导航结构，不是资源，把它们筛掉会让用户下不去。
  List<DiscoveryEntry> get _gameFilteredEntries {
    if (_gameTypeFilter == _GameTypeFilter.all || !_gameTypeFilterAvailable) {
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

  /// 源内按做种降序**稳定**排序；跨源仍按 service 给出的 priority 顺序串接。
  ///
  /// 服务端已经按做种排过（`s=seeders&o=desc`），这里是本地兜底：翻页追加的
  /// 条目要能插回正确位置，多个源混排时各自内部也要有序。只对含做种数的源
  /// 分组动手，OPDS / 直链源原序不动。`List.sort` 不稳定，用 [mergeSort]。
  static List<DiscoveryEntry> _sortBySeedersWithinSource(
    List<DiscoveryEntry> entries,
  ) {
    final Map<String, List<DiscoveryEntry>> groups =
        <String, List<DiscoveryEntry>>{};
    for (final DiscoveryEntry e in entries) {
      (groups[e.sourceId] ??= <DiscoveryEntry>[]).add(e);
    }
    final List<DiscoveryEntry> out = <DiscoveryEntry>[];
    for (final List<DiscoveryEntry> group in groups.values) {
      if (group.any((DiscoveryEntry e) => _seedersOf(e) >= 0)) {
        mergeSort<DiscoveryEntry>(
          group,
          compare: (DiscoveryEntry a, DiscoveryEntry b) =>
              _seedersOf(b).compareTo(_seedersOf(a)),
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

  /// 最终渲染集合 + 两类被隐藏的计数（一条只计一次：先算无人做种，再算疑似漫画）。
  ({List<DiscoveryEntry> entries, int hiddenZeroSeeders, int hiddenManga})
      get _visible {
    final List<DiscoveryEntry> sorted =
        _sortBySeedersWithinSource(_gameFilteredEntries);
    if (_revealHidden) {
      return (entries: sorted, hiddenZeroSeeders: 0, hiddenManga: 0);
    }
    int hiddenZeroSeeders = 0;
    int hiddenManga = 0;
    final List<DiscoveryEntry> shown = <DiscoveryEntry>[];
    for (final DiscoveryEntry e in sorted) {
      if (_isHiddenZeroSeeders(e)) {
        hiddenZeroSeeders++;
      } else if (_isHiddenSuspectedManga(e)) {
        hiddenManga++;
      } else {
        shown.add(e);
      }
    }
    return (
      entries: shown,
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
  final ScrollController _resultsScroll =
      ScrollController(keepScrollOffset: false);

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
    final MediaDiscoverySource? source =
        appModel.mediaDiscoveryService.sourceById(_sourceId);
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
      final List<DiscoveryEntry> base =
          append ? List<DiscoveryEntry>.of(_entries) : const <DiscoveryEntry>[];
      final DiscoveryAggregateResult result =
          await appModel.mediaDiscoveryService.load(
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
                  _failures = deduplicateDiscoveryFailures(partial.failures);
                  _entries
                    ..clear()
                    ..addAll(partial.entries);
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
      await startDiscoveryItemDownload(
        context: context,
        appModel: appModel,
        item: item,
      );
    } finally {
      if (torrent) {
        _resolvingTorrentIds.remove(resolvingKey);
        if (mounted) setState(() {});
      }
    }
  }

  String _kindLabel(DiscoveryMediaKind kind) => discoveryMediaKindLabel(kind);

  String _subtitleFor(
    DiscoveryResourceItem item,
    MediaDiscoveryService service,
  ) {
    final List<String> parts = <String>[
      service.sourceById(item.sourceId)?.displayName ?? item.sourceId,
      if (item.sizeBytes != null) formatDiscoveryBytes(item.sizeBytes!),
      if (item.dateText != null) formatDiscoveryDate(item.dateText!),
      if (item.seeders != null) '↑${item.seeders}',
      if (item.note != null) item.note!,
      if (item.contentHint == DiscoveryContentHint.manga)
        t.discovery_content_hint_manga,
      // BUG-1910：游戏的汉化状态走带类型的字段 + i18n 标签，不再是源里那句硬编码
      // 中文（英文用户此前看到的就是「熟肉」两个方块）。
      if (item.gameLocalization != null)
        _GameTypeFilter.values
            .firstWhere((_GameTypeFilter f) => f.value == item.gameLocalization)
            .label,
    ];
    return parts.join(' · ');
  }

  Widget _buildControls(BuildContext context) {
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
      trailing: <Widget>[
        if (widget.onAiAcquire case final ValueChanged<String> onAiAcquire)
          DiscoveryAiAcquireButton(
            key: const ValueKey<String>('media-discovery-ai-acquire'),
            onPressed: () => onAiAcquire(_queryCtrl.text),
          ),
      ],
      leading: _buildHeaderLeading(),
    );
  }

  /// 种子结果的筛选项：隐藏无人做种 / 隐藏疑似漫画（客户端过滤）+ Nyaa 过滤
  /// 三态（服务端 `f`）。每组各自只在对当前结果有意义时出现；返回的是**组**，
  /// 由 [_buildHeaderLeading] 统一排进同一条筛选行。
  List<List<Widget>> _buildTorrentFilterGroups() {
    final bool seederChip = _hasSeederEntries;
    final bool mangaChip =
        _kind == DiscoveryMediaKind.novel && _hasContentHints;
    return <List<Widget>>[
      if (seederChip || mangaChip)
        <Widget>[
          if (seederChip)
            FushiSelectableChip(
              key: const ValueKey<String>('discovery_filter_hide_zero_seeders'),
              label: t.discovery_filter_hide_zero_seeders,
              leadingIcon: Icons.filter_alt_outlined,
              selected: _hideZeroSeeders,
              onSelected: _setHideZeroSeeders,
            ),
          if (mangaChip)
            FushiSelectableChip(
              key: const ValueKey<String>(
                  'discovery_filter_hide_suspected_manga'),
              label: t.discovery_filter_hide_suspected_manga,
              leadingIcon: Icons.filter_alt_outlined,
              selected: _hideSuspectedManga,
              onSelected: _setHideSuspectedManga,
            ),
        ],
      if (_nyaaFilterAvailable)
        <Widget>[
          for (final NyaaQualityFilter f in NyaaQualityFilter.values)
            FushiSelectableChip(
              key: ValueKey<String>('discovery_nyaa_filter_${f.index}'),
              label: switch (f) {
                NyaaQualityFilter.all => t.discovery_nyaa_filter_all,
                NyaaQualityFilter.noRemakes =>
                  t.discovery_nyaa_filter_no_remakes,
                NyaaQualityFilter.trustedOnly =>
                  t.discovery_nyaa_filter_trusted_only,
              },
              selected: _nyaaQualityFilter == f,
              onSelected: (_) => _setNyaaQualityFilter(f),
            ),
        ],
    ];
  }

  /// header 上方插槽：媒体类型分段（多域时）+ BUG-1910 的游戏汉化状态筛选 +
  /// 种子筛选项。
  ///
  /// 几组可能同时存在（书+游戏合用一页时）。此前每组各占一行、三种控件外观
  /// （带勾的分段按钮 / FilterChip / ChoiceChip）纵向叠三层，搜索框被挤到很下面；
  /// 现在排进**同一条**单行 [Row]：组间一道竖分隔线，放不下由共享头部的筛选行
  /// 横滑（四个域的发现页同一口径）。
  Widget? _buildHeaderLeading() {
    final List<List<Widget>> groups = <List<Widget>>[
      // 媒体域（小说 / 有声书）：单选 chip，与同一行的筛选 chip 同一形态。
      // 曾是分段按钮：放进横滑筛选行（无界宽）后分段按等分宽排，长标签那段
      // 右半被裁掉（2026-10-06 用户截图「有声书」被切）；chip 按各自内容取宽。
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
      // BUG-1910：只有当前结果里确实有带分类的条目才出这组 chip——否则视频/书域，
      // 或搜的是不给分类的源时，凭空多一组没用的控件。
      if (_gameTypeFilterAvailable)
        <Widget>[
          for (final _GameTypeFilter f in _GameTypeFilter.values)
            FushiSelectableChip(
              label: f.label,
              selected: _gameTypeFilter == f,
              // 纯客户端过滤：不重新请求，只换渲染集合。
              onSelected: (_) => setState(() => _gameTypeFilter = f),
            ),
        ],
      ..._buildTorrentFilterGroups(),
    ];
    if (groups.isEmpty) return null;
    // 共享头部把这一组放进第二行的单行横滑区：这里是一条 Row（不折行），组间
    // 一道竖分隔线，放不下由外层横滑。
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

  /// 「已隐藏 N 条无人做种 / M 条疑似漫画」提示行，点一下临时显示全部。
  Widget _buildHiddenNotice(
    BuildContext context,
    int hiddenZeroSeeders,
    int hiddenManga,
  ) {
    final String text = <String>[
      if (hiddenZeroSeeders > 0)
        t.discovery_hidden_zero_seeders_count(n: hiddenZeroSeeders),
      if (hiddenManga > 0)
        t.discovery_hidden_suspected_manga_count(n: hiddenManga),
    ].join(' · ');
    return FushiListItem(
      key: const ValueKey<String>('discovery_hidden_reveal'),
      leading: const FushiIcon(Icons.visibility_off_outlined),
      title: Text(text),
      trailing: Text(t.discovery_hidden_show),
      onTap: () => setState(() => _revealHidden = true),
    );
  }

  /// 资源标题 + trusted 绿 / remake 红徽标（来自 nyaa HTML 行 class）。
  Widget _buildResourceTitle(BuildContext context, DiscoveryResourceItem item) {
    final Widget title = Text(item.title);
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
            // 中性徽标底 + 成功色文字：硬编码 green.shade700 实底在深色下
            // 刺眼，也不跟 Apple 系统色。
            backgroundColor: fushiNeutralTagColors(context).background,
            foregroundColor: fushiStatusColor(context, FushiStatusTone.success),
          ),
      ],
    );
  }

  /// 目录下钻面包屑（只在单源浏览时有内容）。
  Widget _buildBreadcrumb(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: tokens.spacing.page,
        right: tokens.spacing.page,
        top: tokens.spacing.gap,
      ),
      child: Row(
        children: <Widget>[
          FushiIconButton(
            key: const ValueKey<String>('discovery_breadcrumb_up'),
            icon: Icons.arrow_upward,
            tooltip: t.back,
            label: t.back,
            onTap: _popFolder,
          ),
          SizedBox(width: tokens.spacing.gap),
          Expanded(
            child: Text(
              _pathStack.map(((String, String) e) => e.$2).join(' / '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// 「全部来源」+ 空查询的引导态（「发现首页」）：把候选来源摆出来让用户点，
  /// 而不是把某个恰好支持浏览的源的根目录冒充成聚合结果。
  ///
  /// 版式与视频 / 漫画发现首屏同一套信息架构：页首一块大圆角引导横幅（本域没有
  /// 封面可当 Hero，用域名 + 单色大图标 + 引导文案），下面按能力分两区——
  /// 「可浏览目录」与「仅支持搜索」——各自一组自适应卡片网格（宽屏多列、窄屏
  /// 单列）。卡片仍标出能力：用户点之前就知道点进去是目录还是要先输关键词。
  Widget _buildSourcePicker(
    BuildContext context,
    MediaDiscoveryService service,
  ) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<MediaDiscoverySource> sources = service.sourcesFor(_kind);
    final List<MediaDiscoverySource> browsable = <MediaDiscoverySource>[
      for (final MediaDiscoverySource source in sources)
        if (source.capabilities.supportsBrowse) source,
    ];
    final List<MediaDiscoverySource> searchOnly = <MediaDiscoverySource>[
      for (final MediaDiscoverySource source in sources)
        if (!source.capabilities.supportsBrowse) source,
    ];
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double gap = tokens.spacing.gap;
        final double page = tokens.spacing.page;
        final double available = constraints.maxWidth - page * 2;
        Widget grid(List<MediaDiscoverySource> group) {
          final int columns =
              ((available + gap) / (_kSourceCardMinWidth + gap)).floor().clamp(
                    1,
                    group.isEmpty ? 1 : group.length,
                  );
          final double cardWidth = (available - gap * (columns - 1)) / columns;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: <Widget>[
              for (final MediaDiscoverySource source in group)
                SizedBox(
                  width: cardWidth,
                  child: _buildSourceCard(context, source),
                ),
            ],
          );
        }

        return ListView(
          padding: EdgeInsets.fromLTRB(page, gap, page, tokens.spacing.section),
          children: <Widget>[
            _buildPickerBanner(context, compact: available < 520),
            if (browsable.isNotEmpty) ...<Widget>[
              FushiSectionTitle(t.discovery_source_capability_browsable),
              grid(browsable),
            ],
            if (searchOnly.isNotEmpty) ...<Widget>[
              FushiSectionTitle(t.discovery_source_capability_search_only),
              grid(searchOnly),
            ],
          ],
        );
      },
    );
  }

  /// 引导横幅：MD3 Expressive 的大圆角 tonal 色块（secondaryContainer，28 圆角）
  /// / Apple 实色分组卡（secondaryGroupedBackground，24 / 桌面 16 圆角，不铺彩色
  /// 容器）。单色大图标 + 域名大标题 + 引导文案；不可点（真正的入口是下面的
  /// 来源卡）。[compact]（手机宽度）收紧内边距与图标。
  Widget _buildPickerBanner(BuildContext context, {required bool compact}) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final bool apple = isGlassDesign(context);
    final Color? foreground =
        apple ? null : theme.colorScheme.onSecondaryContainer;
    final Color secondary = apple
        ? appleColorsOf(context).secondaryLabel
        : theme.colorScheme.onSecondaryContainer.withValues(alpha: 0.78);
    return FushiCard(
      key: const ValueKey<String>('discovery_pick_banner'),
      color: apple ? null : theme.colorScheme.secondaryContainer,
      borderRadius: discoveryHeroRadius(context),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? tokens.spacing.card + 4 : tokens.spacing.section,
        vertical: compact ? tokens.spacing.card + 4 : tokens.spacing.section,
      ),
      child: Row(
        children: <Widget>[
          FushiNeutralIconBadge(
            icon: _kind == DiscoveryMediaKind.game
                ? Icons.sports_esports_outlined
                : Icons.travel_explore_outlined,
            size: compact ? 48 : 64,
            iconSize: compact ? 26 : 32,
          ),
          SizedBox(width: compact ? tokens.spacing.card : tokens.spacing.section),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  _kindLabel(_kind),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: (compact
                          ? theme.textTheme.titleLarge
                          : theme.textTheme.headlineSmall)
                      ?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: apple ? -0.3 : null,
                    color: foreground,
                  ),
                ),
                SizedBox(height: tokens.spacing.gap / 2),
                Text(
                  t.discovery_source_pick_hint,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: secondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSourceCard(BuildContext context, MediaDiscoverySource source) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool browsable = source.capabilities.supportsBrowse;
    final Color secondary = isGlassDesign(context)
        ? appleColorsOf(context).secondaryLabel
        : tokens.surfaces.onVariant;
    return FushiCard(
      key: ValueKey<String>('discovery_source_pick_${source.id}'),
      focusId: FushiFocusId('discovery-source-pick-${source.id}'),
      onTap: () => _selectSource(source.id),
      child: Row(
        children: <Widget>[
          // 中性圆底单色图标（不再是 secondaryContainer 彩色圆）。
          FushiNeutralIconBadge(
            icon: browsable ? Icons.folder_open_outlined : Icons.search,
            iconSize: 20,
          ),
          SizedBox(width: tokens.spacing.rowHorizontal),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  source.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.listTitle,
                ),
                Text(
                  browsable
                      ? t.discovery_source_capability_browsable
                      : t.discovery_source_capability_search_only,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.listSubtitle.copyWith(color: secondary),
                ),
              ],
            ),
          ),
          FushiIcon(Icons.chevron_right, color: secondary),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final AppModel? appModel = _appModel;
    if (appModel == null) {
      return FushiFloatingChromeInsetPadding(
        child: FushiPlaceholderMessage(
          icon: Icons.search_rounded,
          message: t.discovery_enter_query_hint,
        ),
      );
    }
    final MediaDiscoveryService service = appModel.mediaDiscoveryService;
    final DiscoveryDownloadQueue queue = appModel.discoveryDownloadQueue;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);

    switch (_idleMode(appModel)) {
      case _DiscoveryIdle.pickSource:
        return FushiFloatingChromeInsetPadding(
          child: _buildSourcePicker(context, service),
        );
      case _DiscoveryIdle.queryRequired:
        return FushiFloatingChromeInsetPadding(
          child: FushiPlaceholderMessage(
            icon: Icons.search_rounded,
            message: t.discovery_source_query_required,
          ),
        );
      case _DiscoveryIdle.none:
        break;
    }

    if (_error != null) {
      return FushiFloatingChromeInsetPadding(
        child: FushiPlaceholderMessage(
          key: const ValueKey<String>('discovery_load_error'),
          icon: Icons.cloud_off_outlined,
          message: t.discovery_partial_failure,
          action: _retryButton(),
        ),
      );
    }
    if (_loading && _entries.isEmpty) {
      return const FushiFloatingChromeInsetPadding(child: FushiLoadingView());
    }
    final DiscoveryAggregateResult? result = _result;
    if (_entries.isEmpty) {
      // BUG-1770：「一个源都没成功，而且有失败」不是「没有结果」。失败徽标原先
      // 只挂在下面的非空列表分支上，空列表在这里就直接返回 discovery_empty ——
      // 于是**整源失败**被显示成「无结果」，用户会以为那个目录是空的。
      // 实例：erogame.space 的 `/api/fs/list` 对匿名访问在任何路径上都返回
      // `object not found`（搜索仍可用），点进任何目录都只看到「无结果」。
      // 判据用模型层早就有的 `isTotalFailure`（successfulSourceCount==0 && 有失败）。
      if (result != null && result.isTotalFailure) {
        return FushiFloatingChromeInsetPadding(
          child: FushiPlaceholderMessage(
            key: const ValueKey<String>('discovery_sources_unavailable'),
            icon: Icons.cloud_off_outlined,
            message: t.discovery_sources_unavailable,
            // 印来源展示名而不是接线 id（与视频发现页横幅同一条，BUG-2430）。
            detail: <String>{
              for (final ExternalProviderFailure f in result.failures)
                _sourceDisplayName(service, f.providerId),
            }.join(' · '),
            action: _retryButton(),
          ),
        );
      }
      // 空查询的两种引导态已在上面分流：能走到这里的空列表就是真·无结果。
      return FushiFloatingChromeInsetPadding(
        child: FushiPlaceholderMessage(
          icon: Icons.search_off_rounded,
          message: t.discovery_empty,
        ),
      );
    }

    final ({
      List<DiscoveryEntry> entries,
      int hiddenZeroSeeders,
      int hiddenManga
    }) visible = _visible;
    final List<ExternalProviderFailure> failures = _failures;
    return AnimatedBuilder(
      animation: EngineListenable(queue),
      builder: (BuildContext context, Widget? _) =>
          NotificationListener<ScrollNotification>(
        onNotification: (ScrollNotification notification) {
          if (discoveryShouldLoadMore(notification.metrics)) _loadMore();
          return false;
        },
        child: CustomScrollView(
          key: const ValueKey<String>('discovery-results-scroll'),
          controller: _resultsScroll,
          slivers: <Widget>[
            // 让出叠放在上面的浮动工具区（外壳页签 + 本页搜索 / 筛选行）。
            const SliverToBoxAdapter(child: FushiFloatingChromeInsetSpacer()),
            if (failures.isNotEmpty)
              SliverToBoxAdapter(
                child: DiscoveryProviderWarningBanner(
                  key: const ValueKey<String>('discovery_provider_warning'),
                  failures: failures,
                  displayNameFor: (String id) =>
                      _sourceDisplayName(service, id),
                ),
              ),
            if (_resultsTitle(service) case final String title)
              SliverToBoxAdapter(
                child: FushiSectionTitle(
                  title,
                  padding: EdgeInsets.fromLTRB(
                    tokens.spacing.page,
                    tokens.spacing.card,
                    tokens.spacing.page,
                    tokens.spacing.gap,
                  ),
                ),
              ),
            if (visible.hiddenZeroSeeders + visible.hiddenManga > 0)
              SliverToBoxAdapter(
                child: FushiGroupedList(
                  padding: EdgeInsets.fromLTRB(
                    tokens.spacing.page,
                    0,
                    tokens.spacing.page,
                    tokens.spacing.card,
                  ),
                  children: <Widget>[
                    _buildHiddenNotice(
                      context,
                      visible.hiddenZeroSeeders,
                      visible.hiddenManga,
                    ),
                  ],
                ),
              ),
            // 结果是一组 inset grouped 实色分组（MD3 分段卡 / Apple
            // secondaryGroupedBackground 圆角组 + 从文字起点开始的细分隔线），
            // 与视频 / 漫画发现页的内容层同一口径；长列表懒建。
            SliverFushiGroupedList(
              itemCount: visible.entries.length,
              itemMargin:
                  EdgeInsets.symmetric(horizontal: tokens.spacing.page),
              separatorIndent: 56,
              itemBuilder: (BuildContext context, int index) =>
                  _buildEntryRow(
                context,
                visible.entries[index],
                service,
                queue,
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
                            key: const ValueKey<String>(
                                'discovery_load_more_retry'),
                            onPressed: _retryLoadMore,
                            icon: const FushiIcon(Icons.refresh_rounded),
                            label: Text(t.retry),
                          ),
                        )
                      : result != null && result.hasMore
                          ? Center(
                              // 自动翻页之外的兜底：键盘 / 手柄焦点走到页尾、或首页
                              // 不满一屏没有滚动事件可等时，仍能手动拉下一页。
                              child: _loading
                                  ? const FushiLoadingView(compact: true)
                                  : FushiTextButton(
                                      key: const ValueKey<String>(
                                          'discovery_load_more'),
                                      onPressed: _loadMore,
                                      child: Text(t.discovery_load_more),
                                    ),
                            )
                          : const SizedBox.shrink(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 结果区标题：有关键词 = 「搜索结果」；单源浏览 = 来源名；其余不出标题。
  String? _resultsTitle(MediaDiscoveryService service) {
    if (_query.isNotEmpty) return t.video_discovery_search_results;
    if (_sourceId != kDiscoveryAllSourcesId) {
      return _sourceDisplayName(service, _sourceId);
    }
    return null;
  }

  /// 资源行行首：源给了封面（OPDS / 游戏站）就放一张 2:3 小封面（与视频 / 漫画
  /// 发现卡同一圆角与占位），否则是单色类型图标（种子 / 文件）。
  Widget _buildResourceLeading(
    BuildContext context,
    DiscoveryResourceItem entry,
  ) {
    final String cover = entry.coverUrl?.trim() ?? '';
    if (cover.isEmpty) {
      return FushiIcon(
        entry.payloadKind == DiscoveryPayloadKind.torrent
            ? Icons.link
            : Icons.insert_drive_file_outlined,
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 36,
        height: 54,
        child: DiscoveryImageCover(
          image: AppCachedHttpImage(cover),
          placeholderIcon: Icons.insert_drive_file_outlined,
        ),
      ),
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
          leading: const FushiListLeadingIcon(
            Icons.folder_outlined,
            shape: FushiLeadingShape.square,
          ),
          title: Text(entry.title),
          // 目录条目不带来源名，用户看不出这是哪个站的目录。
          subtitle: Text(
            <String>[
              service.sourceById(entry.sourceId)?.displayName ??
                  entry.sourceId,
              if (entry.note?.trim().isNotEmpty == true)
                entry.note!,
              if (entry.itemCount != null)
                t.media_source_count_manga(n: entry.itemCount!),
            ].join(' · '),
          ),
          trailing: const FushiIcon(Icons.chevron_right),
          onTap: () => _openFolder(entry),
        ),
      // 未隐藏时 0 做种条目灰显：死种能看到，但一眼分得出。
      DiscoveryResourceItem() => Opacity(
          key: ValueKey<String>(
            'discovery_item_${entry.sourceId}_${entry.id}',
          ),
          opacity: entry.seeders == 0 ? 0.5 : 1,
          child: FushiListItem(
            leading: _buildResourceLeading(context, entry),
            title: _buildResourceTitle(context, entry),
            // 不限行：同系列书名只在末尾差卷号（OPDS 的「…惰眠を
            // むさぼるまで 3」），两行 ellipsis 恰好把唯一的区分信息
            // 切掉，用户分不出哪一卷。
            titleMaxLines: null,
            subtitle: Text(_subtitleFor(entry, service)),
            trailing: _resolvingTorrentIds.contains(
                      '${entry.sourceId}\u0000${entry.id}',
                    ) ||
                    queue.isPending(entry)
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: FushiCircularProgressIndicator(
                        strokeWidth: 2),
                  )
                : entry.isDownloadable
                    ? FushiIconButton(
                        icon: Icons.download_outlined,
                        tooltip:
                            t.anime_download_generic_download,
                        label:
                            t.anime_download_generic_download,
                        onTap: () =>
                            unawaited(_download(entry)),
                      )
                    : null,
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
        icon: const FushiIcon(Icons.refresh_rounded),
        label: Text(t.retry),
      );

  @override
  Widget build(BuildContext context) {
    final Widget? navigation = widget.navigation;
    // 库页外壳里：页头 / 搜索 / 面包屑叠进 M3E 浮动工具区（与外壳页签同一份
    // 显隐），正文从顶端画起、经 [FushiFloatingChromeInset] 让位，滚上去的
    // 内容在胶囊背后可见。外壳外 [FushiFloatingChromeOverlay] 退化成竖排，
    // 让位为 0，与原来一致。正文用 Builder 的 context 构建，才读得到本层
    // 工具区下发的 inset。
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: FushiFloatingChromeOverlay(
        chrome: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (navigation != null)
              FushiPageHeader.customTitle(
                title: navigation,
                actions: const <Widget>[],
              ),
            _buildControls(context),
            if (_pathStack.isNotEmpty) _buildBreadcrumb(context),
          ],
        ),
        child: Builder(builder: _buildBody),
      ),
    );
  }
}
