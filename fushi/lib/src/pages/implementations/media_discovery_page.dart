import 'dart:async' show unawaited;
import 'package:collection/collection.dart' show mergeSort;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/media/discovery/discovery_download_queue.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/discovery/discovery_labels.dart';
import 'package:fushi/src/media/discovery/media_discovery_service.dart';
import 'package:fushi/src/media/discovery/media_discovery_source.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi/src/media/torrent/anime_download_plan.dart';
import 'package:fushi_engine/media/torrent/nyaa_client.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/discovery_header.dart';
import 'package:fushi/src/pages/implementations/download_actions.dart';
import 'package:fushi/utils.dart';
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
/// **构建期零 provider 依赖**：游戏页 IndexedStack 急切构建全部子区，本页
/// 在无 ProviderScope 的 widget 测试里也会被 build——容器只在首帧后加载与
/// 交互时解析（同 `_buildImport` 的 QuickImportSection 约定）。
class MediaDiscoveryPage extends StatefulWidget {
  const MediaDiscoveryPage({
    required this.kinds,
    this.navigation,
    this.initialSourceId,
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
    _queryCtrl.dispose();
    _searchFocus.dispose();
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
    setState(() {
      _loading = true;
      _error = null;
      if (!append) {
        _page = 1;
        _entries.clear();
        _result = null;
        _revealHidden = false;
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
                  _entries
                    ..clear()
                    ..addAll(partial.entries);
                });
              },
      );
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _result = result;
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
        _error = e;
      });
    }
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

  /// 提交搜索/清空搜索：把草稿提交成 [_query]，路径栈属于上一轮浏览，必须先清掉。
  void _submitSearch() {
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
    switch (item.payloadKind) {
      case DiscoveryPayloadKind.torrent:
        final String resolvingKey = '${item.sourceId}\u0000${item.id}';
        if (!_resolvingTorrentIds.add(resolvingKey)) return;
        if (mounted) setState(() {});
        bool resolving = true;
        try {
          final MediaDiscoverySource? source =
              appModel.mediaDiscoveryService.sourceById(item.sourceId);
          if (source == null) return;
          final DiscoveryPayload payload =
              item.payload ?? await source.resolvePayload(item);
          resolving = false;
          if (!mounted) return;
          final GenericPushOutcome outcome;
          if (payload is DiscoveryTorrentPayload) {
            outcome = await pushGenericMagnet(
              context: context,
              appModel: appModel,
              magnet: payload.magnetUri,
              contentKind: switch (item.kind) {
                DiscoveryMediaKind.novel => AnimeDownloadPlan.kindBook,
                DiscoveryMediaKind.audiobook => AnimeDownloadPlan.kindAudiobook,
                DiscoveryMediaKind.game => AnimeDownloadPlan.kindGame,
                DiscoveryMediaKind.manga => AnimeDownloadPlan.kindAuto,
              },
            );
          } else if (payload is DiscoverySelectedTorrentPayload) {
            outcome = await enqueueSelectedDiscoveryTorrent(
              context: context,
              appModel: appModel,
              title: item.title,
              resourceTitle: payload.resourceTitle,
              metainfo: payload.metainfo,
              selectedFileIndexes: payload.selectedFileIndexes,
              kind: item.kind,
              importAfterDownload: payload.importAfterDownload,
              coverUrl: item.coverUrl,
              metadataProvider: item.sourceId,
              externalId: item.id,
            );
          } else {
            return;
          }
          if (!mounted) return;
          FushiToast.show(
            msg: genericPushMessage(outcome),
            severity: outcome == GenericPushOutcome.ok
                ? ToastSeverity.success
                : ToastSeverity.error,
          );
        } on Object catch (error, stack) {
          ErrorLogService.instance.log(
            'DiscoveryTorrent.${resolving ? 'resolve' : 'enqueue'}.${item.sourceId}',
            error,
            stack,
          );
          if (mounted) {
            FushiToast.show(
              msg: resolving
                  ? discoveryTorrentResolveFailureMessage(error)
                  : genericPushMessage(GenericPushOutcome.pushFailed),
              severity: ToastSeverity.error,
            );
          }
        } finally {
          _resolvingTorrentIds.remove(resolvingKey);
          if (mounted) setState(() {});
        }
      case DiscoveryPayloadKind.httpFile:
        final bool added = appModel.discoveryDownloadQueue.enqueue(
          item,
          destinationDir: appModel.discoveryDownloadDirFor(item.kind),
        );
        if (added) {
          FushiToast.show(
            msg: t.discovery_download_queued,
            severity: ToastSeverity.success,
          );
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
      if (item.dateText != null) item.dateText!,
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
      onSearchSubmitted: (String _) => _submitSearch(),
      onSearchCleared: () {
        _queryCtrl.clear();
        _submitSearch();
      },
      leading: _buildHeaderLeading(),
    );
  }

  /// 种子结果的筛选条：隐藏无人做种 / 隐藏疑似漫画（客户端过滤）+ Nyaa 过滤
  /// 三态（服务端 `f`）。三组各自只在对当前结果有意义时出现。
  Widget? _buildTorrentFilters() {
    final bool seederChip = _hasSeederEntries;
    final bool mangaChip =
        _kind == DiscoveryMediaKind.novel && _hasContentHints;
    final bool nyaaFilter = _nyaaFilterAvailable;
    if (!seederChip && !mangaChip && !nyaaFilter) return null;
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: <Widget>[
        if (seederChip)
          FilterChip(
            key: const ValueKey<String>('discovery_filter_hide_zero_seeders'),
            label: Text(t.discovery_filter_hide_zero_seeders),
            selected: _hideZeroSeeders,
            onSelected: _setHideZeroSeeders,
          ),
        if (mangaChip)
          FilterChip(
            key:
                const ValueKey<String>('discovery_filter_hide_suspected_manga'),
            label: Text(t.discovery_filter_hide_suspected_manga),
            selected: _hideSuspectedManga,
            onSelected: _setHideSuspectedManga,
          ),
        if (nyaaFilter)
          for (final NyaaQualityFilter f in NyaaQualityFilter.values)
            ChoiceChip(
              key: ValueKey<String>('discovery_nyaa_filter_${f.index}'),
              label: Text(switch (f) {
                NyaaQualityFilter.all => t.discovery_nyaa_filter_all,
                NyaaQualityFilter.noRemakes =>
                  t.discovery_nyaa_filter_no_remakes,
                NyaaQualityFilter.trustedOnly =>
                  t.discovery_nyaa_filter_trusted_only,
              }),
              selected: _nyaaQualityFilter == f,
              onSelected: (_) => _setNyaaQualityFilter(f),
            ),
      ],
    );
  }

  /// header 上方插槽：媒体类型分段（多域时）+ BUG-1910 的游戏汉化状态筛选 +
  /// 种子筛选条。
  ///
  /// 三者可能同时存在（书+游戏合用一页时），所以纵向叠放而不是二选一。
  Widget? _buildHeaderLeading() {
    final Widget? kindSelector = widget.kinds.length > 1
        ? SegmentedButton<DiscoveryMediaKind>(
            segments: <ButtonSegment<DiscoveryMediaKind>>[
              for (final DiscoveryMediaKind kind in widget.kinds)
                ButtonSegment<DiscoveryMediaKind>(
                  value: kind,
                  label: Text(_kindLabel(kind)),
                ),
            ],
            selected: <DiscoveryMediaKind>{_kind},
            onSelectionChanged: (Set<DiscoveryMediaKind> selection) =>
                _selectKind(selection.first),
          )
        : null;
    // BUG-1910：只有当前结果里确实有带分类的条目才出这排 chip——否则视频/书域，
    // 或搜的是不给分类的源时，凭空多一排没用的控件。
    final Widget? typeFilter = _gameTypeFilterAvailable
        ? Wrap(
            spacing: 8,
            runSpacing: 4,
            children: <Widget>[
              for (final _GameTypeFilter f in _GameTypeFilter.values)
                ChoiceChip(
                  label: Text(f.label),
                  // 视觉密度走 MD3 默认：这是普通页面 chrome，不该自开本地决策
                  // （md3_design_system_static_test 钉死）。番剧下载那排 chip 用
                  // compact 是**对话框**里的既有豁免类，不该顺手继承过来。
                  selected: _gameTypeFilter == f,
                  // 纯客户端过滤：不重新请求，只换渲染集合。
                  onSelected: (_) => setState(() => _gameTypeFilter = f),
                ),
            ],
          )
        : null;
    final Widget? torrentFilters = _buildTorrentFilters();
    final List<Widget> rows = <Widget>[
      if (kindSelector != null) kindSelector,
      if (typeFilter != null) typeFilter,
      if (torrentFilters != null) torrentFilters,
    ];
    if (rows.isEmpty) return null;
    if (rows.length == 1) return rows.single;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < rows.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: 8),
          rows[i],
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
      leading: const Icon(Icons.visibility_off_outlined),
      title: Text(text),
      trailing: Text(t.discovery_hidden_show),
      onTap: () => setState(() => _revealHidden = true),
    );
  }

  /// 资源标题 + trusted 绿 / remake 红徽标（来自 nyaa HTML 行 class）。
  Widget _buildResourceTitle(BuildContext context, DiscoveryResourceItem item) {
    final Widget title = Text(item.title);
    if (!item.trusted && !item.remake) return title;
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(child: title),
        if (item.remake)
          FushiTag(
            key: const ValueKey<String>('discovery_badge_remake'),
            text: t.discovery_badge_remake,
            backgroundColor: colors.error,
            foregroundColor: colors.onError,
          )
        else
          FushiTag(
            key: const ValueKey<String>('discovery_badge_trusted'),
            text: t.discovery_badge_trusted,
            backgroundColor: Colors.green.shade700,
            foregroundColor: Colors.white,
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

  /// 「全部来源」+ 空查询的引导态：把候选来源摆出来让用户点，而不是把某个
  /// 恰好支持浏览的源的根目录冒充成聚合结果。
  Widget _buildSourcePicker(
    BuildContext context,
    MediaDiscoveryService service,
  ) {
    final ThemeData theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            t.discovery_source_pick_hint,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        for (final MediaDiscoverySource source in service.sourcesFor(_kind))
          FushiListItem(
            key: ValueKey<String>('discovery_source_pick_${source.id}'),
            leading: const Icon(Icons.travel_explore_outlined),
            title: Text(source.displayName),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _selectSource(source.id),
          ),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    final AppModel? appModel = _appModel;
    final ThemeData theme = Theme.of(context);
    if (appModel == null) {
      return Center(
        child: Text(
          t.discovery_enter_query_hint,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }
    final MediaDiscoveryService service = appModel.mediaDiscoveryService;
    final DiscoveryDownloadQueue queue = appModel.discoveryDownloadQueue;

    switch (_idleMode(appModel)) {
      case _DiscoveryIdle.pickSource:
        return _buildSourcePicker(context, service);
      case _DiscoveryIdle.queryRequired:
        return Center(
          child: Text(
            t.discovery_source_query_required,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        );
      case _DiscoveryIdle.none:
        break;
    }

    if (_error != null) {
      return Center(
        child: Text(
          t.discovery_partial_failure,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.error),
        ),
      );
    }
    if (_loading && _entries.isEmpty) {
      return const Center(child: CircularProgressIndicator());
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
        return Center(
          child: Text(
            '${t.discovery_sources_unavailable} '
            '(${result.failures.map((ExternalProviderFailure f) => f.providerId).toSet().join(', ')})',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.error),
          ),
        );
      }
      // 空查询的两种引导态已在上面分流：能走到这里的空列表就是真·无结果。
      return Center(
        child: Text(
          t.discovery_empty,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }

    final ({
      List<DiscoveryEntry> entries,
      int hiddenZeroSeeders,
      int hiddenManga
    }) visible = _visible;
    return AnimatedBuilder(
      animation: EngineListenable(queue),
      builder: (BuildContext context, Widget? _) => ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          if (visible.hiddenZeroSeeders + visible.hiddenManga > 0)
            _buildHiddenNotice(
              context,
              visible.hiddenZeroSeeders,
              visible.hiddenManga,
            ),
          if (result != null && result.hasFailures)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '${t.discovery_partial_failure} '
                '(${result.failures.map((ExternalProviderFailure f) => f.providerId).toSet().join(', ')})',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
          for (final DiscoveryEntry entry in visible.entries)
            switch (entry) {
              DiscoveryFolder() => FushiListItem(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(entry.title),
                  // 目录条目不带来源名，用户看不出这是哪个站的目录。
                  subtitle: Text(
                    <String>[
                      service.sourceById(entry.sourceId)?.displayName ??
                          entry.sourceId,
                      if (entry.note?.trim().isNotEmpty == true) entry.note!,
                      if (entry.itemCount != null)
                        t.media_source_count_manga(n: entry.itemCount!),
                    ].join(' · '),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _openFolder(entry),
                ),
              // 未隐藏时 0 做种条目灰显：死种能看到，但一眼分得出。
              DiscoveryResourceItem() => Opacity(
                  key: ValueKey<String>(
                    'discovery_item_${entry.sourceId}_${entry.id}',
                  ),
                  opacity: entry.seeders == 0 ? 0.5 : 1,
                  child: FushiListItem(
                    leading: Icon(
                      entry.payloadKind == DiscoveryPayloadKind.torrent
                          ? Icons.link
                          : Icons.insert_drive_file_outlined,
                    ),
                    title: _buildResourceTitle(context, entry),
                    titleMaxLines: 2,
                    subtitle: Text(_subtitleFor(entry, service)),
                    trailing: _resolvingTorrentIds.contains(
                              '${entry.sourceId}\u0000${entry.id}',
                            ) ||
                            queue.isPending(entry)
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : entry.isDownloadable
                            ? FushiIconButton(
                                icon: Icons.download_outlined,
                                tooltip: t.anime_download_generic_download,
                                label: t.anime_download_generic_download,
                                onTap: () => unawaited(_download(entry)),
                              )
                            : null,
                    onTap: entry.isDownloadable
                        ? () => unawaited(_download(entry))
                        : null,
                  ),
                ),
            },
          if (result != null && result.hasMore)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Center(
                child: _loading
                    ? const CircularProgressIndicator()
                    : TextButton(
                        onPressed: () {
                          _page++;
                          unawaited(_load(append: true));
                        },
                        child: Text(t.discovery_load_more),
                      ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget? navigation = widget.navigation;
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          if (navigation != null)
            FushiPageHeader.customTitle(
              title: navigation,
              actions: const <Widget>[],
            ),
          _buildControls(context),
          if (_pathStack.isNotEmpty) _buildBreadcrumb(context),
          Expanded(child: _buildBody(context)),
        ],
      ),
    );
  }
}
