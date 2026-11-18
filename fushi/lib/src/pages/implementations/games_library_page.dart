import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_continue_blocks.dart';
import 'package:fushi/src/utils/components/fushi_continue_card_row.dart';
import 'package:fushi/src/utils/components/fushi_continue_hero.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:fushi/src/utils/components/fushi_cover_block_layout.dart';
import 'package:fushi/src/utils/components/fushi_series_cover_block.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/media/collections/library_organize_runner.dart';
import 'package:fushi/src/media/nsfw/media_nsfw_cover.dart';
import 'package:fushi/src/media/downloads/download_source_method.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/fushi_reorderable_grid.dart';
import 'package:fushi/src/utils/components/library_reorder.dart';
import 'package:fushi/src/utils/components/section_visibility.dart'
    show SectionPopScope;
import 'package:fushi_engine/media/collections/shelf_sort.dart'
    show decodeShelfManualOrder, encodeShelfManualOrder, moveInShelfManualOrder;
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/pages/implementations/collection_management_page.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/shortcuts/gamepad_forwarding_action.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show GamepadButtonIntent, GamepadLongPressActions;
import 'package:fushi/src/shortcuts/input_binding.dart' show GamepadButton;
import 'package:fushi_engine/media/discovery/discovery_download_queue.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi_engine/media/metadata/dlsite/dlsite_client.dart';
import 'package:fushi/src/media/links/media_link_entries.dart'
    show MediaLinkEntry;
import 'package:fushi/src/media/links/media_link_inference_host.dart'
    show mediaLinkInferCallback;
import 'package:fushi/src/media/links/media_link_opener.dart'
    show mediaLinkSearchAction, openMediaLinkEntry;
import 'package:fushi/src/media/links/media_links_section.dart'
    show showMediaLinksDialog;
import 'package:fushi/src/media/links/work_kinds_badge.dart';
import 'package:fushi/src/media/collections/collection_context_dialog.dart';
import 'package:fushi/src/media/collections/collection_grouping.dart';
import 'package:fushi/src/media/collections/collection_drag.dart'
    show
        CollectionAddOutcome,
        CollectionDropTarget,
        LibraryDragReorderScope,
        LibraryReorderCell,
        MediaCardDraggable,
        addMediaRefToCollection;
import 'package:fushi/src/media/drag_drop/fushi_file_drop_target.dart';
import 'package:fushi/src/media/tags/tag_drop.dart' show reorderTagsSafely;
import 'package:fushi/src/media/metadata/scrape_batch.dart';
import 'package:fushi/src/media/metadata/scrape_title_matcher.dart';
import 'package:fushi/src/mining/gal_hook_failure_text.dart';
import 'package:fushi/src/mining/gal_hook_session_controller.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/src/mining/galgame_helper_installer.dart';
import 'package:fushi/src/mining/galgame_japanese_locale.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/module_registry.dart' show isAiModuleEnabled;
import 'package:fushi/src/mining/galgame_library_query.dart';
import 'package:fushi/src/mining/galgame_repository.dart';
import 'package:fushi/src/mining/galgame_scrape_dialog.dart';
import 'package:fushi/src/mining/galgame_scrape_controller.dart';
import 'package:fushi/src/mining/metadata/adapters/dlsite_adapter.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:fushi/src/mining/galgame_add_flow.dart';
import 'package:fushi/src/pages/implementations/galgame_detail_page.dart';
import 'package:fushi/src/pages/implementations/games/galgame_item_menu.dart';
import 'package:fushi/src/pages/implementations/games/galgame_library_view_request.dart';
import 'package:fushi/src/pages/implementations/game_shared.dart'
    show
        GalWorkbenchReadiness,
        GameSection,
        galHookSessionRunsGame,
        galWorkbenchReadiness,
        gameSectionNotifier,
        openGameCaptureWorkbench;
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/sync/texthooker_service.dart'
    show TexthookerLineEntry;
import 'package:fushi/src/utils/components/fushi_generated_cover.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/pages/implementations/media_collection_grid_detail_page.dart';
import 'package:fushi/src/pages/implementations/stat_shared.dart'
    show formatStatTime;
import 'package:fushi/src/pages/implementations/library_filter_dropdown.dart';
import 'package:fushi/src/pages/implementations/library_filter_panel.dart';
import 'package:fushi/src/pages/implementations/tag_filter_bar.dart';
import 'package:fushi/src/pages/implementations/library_view_options.dart';
import 'package:fushi/src/models/library_grid_columns.dart'
    show LibraryGridDomain;
import 'package:fushi/src/utils/components/fushi_header_search.dart';
import 'package:fushi/src/utils/components/fushi_header_more_button.dart';
import 'package:fushi/src/pages/implementations/tag_filter_sheet.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/cover_badge.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_header_menu_anchor.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_section_title.dart';
import 'package:fushi/src/utils/components/fushi_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/galgame_poster_card.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_chips.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi_engine/utils/misc/fushi_time_format.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show FushiFloatingChromeOverlay, FushiFloatingChromeScrollInset;
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/cover_image.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/components/fushi_divider.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart' show WindowSizeClass;

// 游戏进合集（统一媒体库）：mediaType 用 [MediaKind.game]（P5 枚举地基，取代旧
// 常量 kGameCollectionMediaType）。entryKey = `galgames.id`（添加时刻微秒时间戳
// 字符串）——**游戏本机局域身份**：与 exe 路径同为本机事实，跨端同步时对端无
// 对应 `galgames` 行则该成员静默忽略（合集同步引擎对 mediaType/entryKey 透传，
// 不解引用）。

/// 首页「游戏」tab：galgame 库。展示用户添加的游戏网格，点击一个游戏经
/// [GalHookSessionController.launchGame]（引擎-hook launch 路径）拉起并注入。
/// 台词进入同一个捕获会话，原生浮窗点词与工作台制卡共享稳定 lineId。
///
/// 顶部工具条提供搜索 / 排序 / 筛选（纯函数实现在 `galgame_library_query.dart`，
/// 排序与筛选偏好走现有偏好体系持久化）；卡片点击**仍然是启动游戏**（不破坏肌肉
/// 记忆），长按 / 右键菜单里进详情页（[GalgameDetailPage]）。
///
/// 持久化自 v55 起走 Drift 表 `galgames`（[GalgameRepository]），旧偏好 JSON key
/// 已由 DB 迁移一次性回填。仅 Windows 桌面有注入能力；非 Windows 点击启动时优雅提示
/// 不支持，添加/管理列表仍可用。
class GamesLibraryPage extends ConsumerStatefulWidget {
  const GamesLibraryPage({
    super.key,
    this.embedded = false,
    this.sessionController,
    this.onLaunched,
    this.header,
    this.onOpenDownloads,
  });

  final bool embedded;
  final GalHookSessionController? sessionController;
  final VoidCallback? onLaunched;

  /// 排在主滚动视图最前、随内容一起滚走的一块（游戏 tab 的捕获会话状态带）。
  /// 它是内容不是工具：放进滚动视图而不是钉在搜索行上方，内容才能一路滚到
  /// 浮动工具区底下，工具区收起后顶部不留一条钉死的带子。
  ///
  /// 有 [sessionController] 且在 Windows 上时不画它：库页自己画会话带
  /// （[_GameSessionBand]，只在有 Hook 会话时出现），外壳传进来的常驻状态带
  /// 不再显示（设计稿 GA5：空闲时也常驻是问题）。
  final Widget? header;

  /// 下载块「打开下载 ›」：跳到统一下载中心（浏览 › 下载 › 任务）。null = 不出
  /// 这个入口（独立使用、或宿主够不到下载页时）；iOS 另经
  /// [StoreRestrictedCapability.downloads] 门控。
  final VoidCallback? onOpenDownloads;

  @override
  ConsumerState<GamesLibraryPage> createState() => _GamesLibraryPageState();
}

class _GamesLibraryPageState extends ConsumerState<GamesLibraryPage>
    with LibraryReorderHost<GamesLibraryPage> {
  /// 本页合集卡的成员数，发布给「管理合集」页（与卡片「N 卷 / N 项」同源）。
  final CollectionDisplayCounts _collectionDisplayCounts =
      CollectionDisplayCounts();

  /// 缓存 [AppModel]（`appProvider` 单例，实例不变）。
  late final AppModel _appModel = ref.read(appProvider);

  /// 游戏库仓储（Drift 表真相源）。`late final` 惰性求值，非游戏路径不碰 DB。
  late final GalgameRepository _repo = _appModel.galgameRepo;

  /// 本页持有的**全量**游戏列表（渲染前经 [_view] 过滤排序）。
  late List<GalgameEntry> _games = _repo.games;

  /// 搜索 / 排序 / 筛选视图状态（除搜索词外持久化）。
  late GalgameLibraryView _view = GalgameLibraryView.decode(
    _appModel.galgameLibraryView,
  );

  final TextEditingController _searchController = TextEditingController();

  /// 单行页头的可展开搜索（2026-10-14）：平时是页头里的 🔍，点开整行换成搜索
  /// 栏；搜索词仍是 [_view] 的 search（只影响本次会话、不落库）。
  late final FushiHeaderSearchController _headerSearch =
      FushiHeaderSearchController(
        textController: _searchController,
        buttonFocusId: const FushiFocusId('games-library-search'),
        hintText: t.game_search,
        onQueryChanged: (String value) =>
            setState(() => _view = _view.copyWith(search: value)),
      );

  /// 页头「排序」按钮打开的菜单（常驻锚点见 [_buildSortMenuAnchor]）。
  final FushiHeaderMenuController _sortMenu = FushiHeaderMenuController();

  /// 单行页头（嵌在游戏 tab 里、非 Cupertino）：搜索 / 刮削 / 排序 / 筛选 /
  /// 管理标签 / 布局切换都进页头动作；Cupertino 与独立 push 保留旧工具行。
  bool get _singleRowHeader => widget.embedded && !isCupertinoPlatform(context);

  /// 合集分组映射（与书架 `_loadShelfMaps` 同款三件套）：合集字典、条目 → 主折叠
  /// 合集 id、条目在主折叠合集里的 sortIndex。[_reload] 时一并批量预取。
  Map<int, MediaCollectionRow> _collectionsById =
      const <int, MediaCollectionRow>{};
  Map<String, int> _primaryCollectionByEntry = const <String, int>{};
  Map<String, int> _memberSortIndex = const <String, int>{};

  /// 单个游戏的刮削资料 / 横版背景图 / 艺术字（`item_scrape_meta` +
  /// `item_images`，[GameItemScrapeArt.load] 两类查询批量预取、文件存在性在那里
  /// 探好），与合集映射同一次 [_loadCollectionMaps] 重载，build 零 IO。
  GameItemScrapeArt _gameScrapeArt = GameItemScrapeArt.empty;

  /// 合集刮削资料（collectionId → 行）与含游戏成员的合集附加图组里**文件还在**
  /// 的横版背景图 / 艺术字（collectionId → 路径）：合集色块卡据此画系列色块
  /// （[_collectionSeriesMeta]，与书架合集卡同口径）。
  Map<int, CollectionScrapeMetaRow> _collectionScrapeMetaById =
      const <int, CollectionScrapeMetaRow>{};
  Map<int, String> _collectionBackdropPathById = const <int, String>{};
  Map<int, String> _collectionLogoPathById = const <int, String>{};

  /// 刮削资料 / 附加图变化订阅（单个游戏的 `item_*` 两表、合集刮削资料与
  /// `media_images`），合并成一次映射重载。
  StreamSubscription<void>? _itemScrapeSub;
  StreamSubscription<void>? _collectionScrapeSub;
  Timer? _scrapeReloadDebounce;

  /// 启动流程的**再入守卫**：一次启动含位数探测、helper 确认/下载对话框、注入会话等多个 await，
  /// 全程可能持续数秒。没有此守卫时，用户在等待期间重复点击游戏卡片会各自开一条 _launchGame，
  /// 叠出多个「需要下载 galgame 引擎组件」对话框（用户实测症状）。true 期间忽略新的启动点击。
  bool _launching = false;

  /// 网格 / 列表布局（偏好 `games_library_layout`）。页头切换钮
  /// （[GamesLibraryLayoutToggle]）写偏好，本页监听偏好仓储跟着换。
  late bool _listLayout = _appModel.prefsRepo.gamesLibraryListLayout;

  void _onPrefsChanged() {
    final bool list = _appModel.prefsRepo.gamesLibraryListLayout;
    if (!mounted || list == _listLayout) return;
    setState(() => _listLayout = list);
  }

  @override
  void initState() {
    super.initState();
    _appModel.prefsRepo.addListener(_onPrefsChanged);
    // 仓储是 ChangeNotifier：监听它，游戏从任何入口落库（「导入」视图快速导入、
    // 详情页编辑等）本页都能自动刷新，不再依赖「写操作都发生在本页」的隐含假设。
    _repo.addListener(_refresh);
    // BUG-1911：下载中的游戏要在库页占位，所以也得跟着下载队列刷新。
    _appModel.discoveryDownloadQueue.addListener(_refresh);
    // 游戏首页「全部 ›」/「游玩状态」图例带着视图跳过来：本页常驻 IndexedStack、
    // 不会重读偏好，所以经这条 notifier 就地换视图（挂载前就发出的请求，偏好里
    // 已是新视图，这里消费掉即可）。
    galgameLibraryViewRequestNotifier.addListener(_onViewRequest);
    if (galgameLibraryViewRequestNotifier.value != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onViewRequest());
    }
    // 刮削写回 / 控制通道脚本写的单个游戏资料与附加图、合集刮削资料与附加图：
    // 系列色块的背景图 / 概览走预取映射，任何写入者落库后都重载一次。
    _itemScrapeSub = _appModel.database.watchItemScrapeChanged().listen(
      _onScrapeTablesChanged,
    );
    _collectionScrapeSub = _appModel.database
        .watchVideoScrapePresentationChanged()
        .listen(_onScrapeTablesChanged);
    unawaited(_reload());
  }

  /// 刮削相关表写入回调：300 ms 合并窗口（与书架 `_onCollectionTablesChanged`
  /// 同一节奏，批量写入只重载一次），只重取映射、不重载游戏仓储。
  void _onScrapeTablesChanged(void _) {
    _scrapeReloadDebounce?.cancel();
    _scrapeReloadDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      unawaited(_afterItemAction());
    });
  }

  void _onViewRequest() {
    final GalgameLibraryViewRequest? request =
        galgameLibraryViewRequestNotifier.value;
    if (request == null || !mounted) return;
    galgameLibraryViewRequestNotifier.value = null;
    _setView(request.applyTo(_view));
    // 搜索词被请求清空：页头搜索框也要跟着清，不然框里还留着旧词。
    if (_searchController.text.isNotEmpty) _searchController.clear();
  }

  @override
  void dispose() {
    _itemScrapeSub?.cancel();
    _collectionScrapeSub?.cancel();
    _scrapeReloadDebounce?.cancel();
    _collectionDisplayCounts.dispose();
    _appModel.prefsRepo.removeListener(_onPrefsChanged);
    _repo.removeListener(_refresh);
    _appModel.discoveryDownloadQueue.removeListener(_refresh);
    galgameLibraryViewRequestNotifier.removeListener(_onViewRequest);
    _headerSearch.dispose();
    _searchController.dispose();
    super.dispose();
  }

  /// 从 DB 全量重载（三个批量查询，无 N+1）+ 合集分组映射。
  Future<void> _reload() async {
    await _repo.load();
    await _loadCollectionMaps();
    _refresh();
    // 新加的游戏：开了「导入后自动 AI 整理」时去抖后交 AI（门在 runner）。
    scheduleAutomaticLibraryOrganize(CollectionShelfDomain.games);
  }

  /// 预取合集分组三件套（照书架 `_loadShelfMaps` 的口径：一次 getAllCollectionItems
  /// 内存分组，不逐合集 N+1；memberSortIndex 只记主折叠合集的行）。
  Future<void> _loadCollectionMaps() async {
    final FushiDatabase db = _appModel.database;
    final List<MediaCollectionRow> collections = await db
        .getAllMediaCollections();
    final Map<String, int> primaryMap = await db
        .getPrimaryCollectionIdByEntry();
    final Map<String, int> memberSortIndex = <String, int>{};
    // 有游戏成员的合集：只给它们探系列色块的背景图 / 艺术字文件。
    final Set<int> gameCollectionIds = <int>{};
    for (final MediaCollectionItemRow m in await db.getAllCollectionItems()) {
      final String key = '${m.mediaType}|${m.entryKey}';
      if (primaryMap[key] == m.collectionId) memberSortIndex[key] = m.sortIndex;
      if (m.mediaType == MediaKind.game.dbValue) {
        gameCollectionIds.add(m.collectionId);
      }
    }
    final Map<int, CollectionScrapeMetaRow> scrapeById =
        <int, CollectionScrapeMetaRow>{
          for (final CollectionScrapeMetaRow row
              in await db.getAllCollectionScrapeMeta())
            if (gameCollectionIds.contains(row.collectionId))
              row.collectionId: row,
        };
    final Map<int, String> backdropById =
        await _firstExistingGameCollectionImages(
          db,
          MediaImageKind.backdrop,
          gameCollectionIds,
        );
    final Map<int, String> logoById = await _firstExistingGameCollectionImages(
      db,
      MediaImageKind.logo,
      gameCollectionIds,
    );
    final GameItemScrapeArt scrapeArt = await GameItemScrapeArt.load(db);
    _collectionsById = <int, MediaCollectionRow>{
      for (final MediaCollectionRow c in collections) c.id: c,
    };
    _primaryCollectionByEntry = primaryMap;
    _memberSortIndex = memberSortIndex;
    _collectionScrapeMetaById = scrapeById;
    _collectionBackdropPathById = backdropById;
    _collectionLogoPathById = logoById;
    _gameScrapeArt = scrapeArt;
  }

  /// 合集的系列色块元数据（[collectionSeriesMeta]，与书架合集卡同口径）：合集
  /// 有刮削资料或横版背景图时非 null。只读预取映射，零查询 / 零 IO。
  FushiSeriesMeta? _collectionSeriesMeta(
    MediaCollectionRow collection,
    int memberCount,
  ) {
    final String? backdrop = _collectionBackdropPathById[collection.id];
    final String? logo = _collectionLogoPathById[collection.id];
    return collectionSeriesMeta(
      scrape: _collectionScrapeMetaById[collection.id],
      backdrop: backdrop == null ? null : resizedFileImage(File(backdrop)),
      logo: logo == null ? null : resizedFileImage(File(logo)),
      countLabel: t.game_collection_work_count(n: memberCount),
    );
  }

  /// 把仓储缓存同步到本页（仓储的每个写方法内部已重载）。
  void _refresh() {
    if (!mounted) return;
    setState(() => _games = _repo.games);
  }

  /// 「手动」排序的名次表（单元 tieKey → 下标；合集 `c<id>`、游戏 id），存在偏好
  /// `library_manual_order::game`。
  late Map<String, int> _manualRanks = decodeShelfManualOrder(
    _appModel.prefsRepo.libraryManualOrder(_manualOrderLibrary),
  );

  static const String _manualOrderLibrary = 'game';

  /// 排序模式（条目菜单「排序」进入，[LibraryReorderHost]）：网格换成拖排网格，
  /// 触屏按住即拖，底部「完成」退出。
  bool _reordering = false;

  /// 本帧按当前排序排好的网格单元 tieKey：进排序模式时用它给手动序播种。
  List<String> _sortedUnitKeys = const <String>[];

  @override
  VoidCallback? get libraryReorderEntry => _startReorder;

  /// 进入排序模式：排序方式切到「手动」；之前不是手动的，先把当前显示顺序存成
  /// 手动序，拖动从用户眼前的顺序开始。
  void _startReorder() {
    if (!mounted) return;
    _adoptManualSort();
    setState(() => _reordering = true);
  }

  /// 排序方式切到「手动」；之前不是手动的，先把当前显示顺序存成手动序（排序模式
  /// 与桌面直拖共用）。
  void _adoptManualSort() {
    if (_view.sortField == GalgameSortField.manual) return;
    _setManualOrder(_sortedUnitKeys);
    _setView(_view.copyWith(sortField: GalgameSortField.manual));
  }

  /// 桌面常态网格的直拖重排（[LibraryDragReorderScope]）：任何排序下都可拖，拖一次
  /// 即把当前显示顺序连同这次移动存为手动序（与合集详情页同一语义）。
  void _onGameDragReorder(List<String> visible, int from, int to) {
    _adoptManualSort();
    _onGameReorder(visible, from, to);
  }

  void _endReorder() => setState(() => _reordering = false);

  void _setManualOrder(List<String> order) {
    final String encoded = encodeShelfManualOrder(order);
    _manualRanks = decodeShelfManualOrder(encoded);
    unawaited(
      _appModel.prefsRepo.setLibraryManualOrder(_manualOrderLibrary, encoded),
    );
  }

  /// 排序模式里的一次拖动：[visible] 是网格上的单元（显示顺序）。没有名次的单元
  /// 显示在最前，按显示顺序补进完整手动序再合并。
  void _onGameReorder(List<String> visible, int from, int to) {
    final List<String> all = <String>[
      for (final String key in visible)
        if (!_manualRanks.containsKey(key)) key,
      ..._manualRanks.keys,
    ];
    setState(
      () => _setManualOrder(
        moveInShelfManualOrder(all: all, visible: visible, from: from, to: to),
      ),
    );
  }

  /// 网格单元的手动序身份：合集 `c<id>`、散卡游戏 id（与书架 / 视频库同形）。
  static String _gameUnitKey(CollectionGroup<GalgameEntry> group) {
    final MediaCollectionRow? collection = group.collection;
    return collection == null
        ? group.coverItem.payload.id
        : 'c${collection.id}';
  }

  /// 「手动」排序：按名次升序；没有名次的（排好之后新加的）在最前、按添加时间
  /// 倒序。合集取成员最晚的添加时间。
  int _compareManualUnits(
    CollectionGroup<GalgameEntry> a,
    CollectionGroup<GalgameEntry> b,
  ) {
    final String ka = _gameUnitKey(a);
    final String kb = _gameUnitKey(b);
    final int? ra = _manualRanks[ka];
    final int? rb = _manualRanks[kb];
    if (ra != null && rb != null) return ra.compareTo(rb);
    if (ra != null || rb != null) return ra == null ? -1 : 1;
    int newest(CollectionGroup<GalgameEntry> g) => g.items
        .map((CollectionOrderingItem<GalgameEntry> it) => it.importedAt)
        .reduce((int x, int y) => x > y ? x : y);
    final int c = newest(b).compareTo(newest(a));
    return c != 0 ? c : ka.compareTo(kb);
  }

  /// 改视图状态并持久化（搜索词不落库，见 [GalgameLibraryView]）。
  void _setView(GalgameLibraryView next) {
    setState(() => _view = next);
    unawaited(_appModel.setGalgameLibraryView(next.encode()));
  }

  /// 当前要渲染的列表（筛选 + 搜索 + 排序，纯函数）。
  List<GalgameEntry> _visibleFor(Set<String>? allowedIds) =>
      applyGalgameLibraryView(_games, _view, allowedIds: allowedIds);

  /// 添加游戏（独立使用时的兜底入口）：委托给共享动作 [addGameViaFilePicker]
  /// （选 exe → 查重 → 落库 → 后台补封面），与「导入」视图快速导入区同一条路。
  /// 本页经仓储监听自动刷新。
  Future<void> _addGame() => addGameViaFilePicker(_repo);

  /// 拖入文件导入：委托给共享动作 [addGamesFromPaths]（筛新 exe → 落库 → toast
  /// 汇报数量 → 逐条后台补封面），与「导入」视图的拖放同一条路。
  Future<void> _handleDrop(List<String> paths, Offset _) async {
    await addGamesFromPaths(_repo, paths, onImported: _refresh);
  }

  /// 打开详情页（长按 / 右键菜单入口）。返回后重载，把详情页里的编辑/刮削同步回列表。
  Future<void> _openDetail(GalgameEntry game, {int initialTab = 0}) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext ctx) => GalgameDetailPage(
          gameId: game.id,
          initialTab: initialTab,
          onLaunch: () {
            final GalgameEntry? latest = _repo.byId(game.id);
            if (latest != null) unawaited(_launchGame(latest));
          },
        ),
      ),
    );
    await _reload();
  }

  /// 工具条「全部刮削」：按每个游戏当前显示名搜索，只自动应用每个源内唯一的
  /// 精确匹配。批量属于自动路径，已有本地/手动封面不覆盖；近似结果、同一个源里的
  /// 多条同名结果留给单卡确认。不同源各有一条同名是同一部作品（BUG-4727：跨源同名曾被
  /// 当成歧义，Bangumi 与 VNDB 都收录的作品一律刮不出封面），按源顺序取第一个源。
  Future<void> _scrapeAllGames() async {
    final List<GalgameEntry> games = List<GalgameEntry>.of(_games);
    if (!mounted) return;
    await showScrapeBatchDialog(
      context: context,
      mediaLabel: t.games,
      itemCount: games.length,
      runner: (ScrapeBatchProgressCallback onProgress) async {
        final GalgameScrapeController controller =
            GalgameScrapeController.instance;
        ScrapeBatchSummary summary = const ScrapeBatchSummary();
        for (int index = 0; index < games.length; index++) {
          final GalgameEntry game = games[index];
          ScrapeBatchItemResult result;
          try {
            // 名字 / 安装路径里认得出 DLsite 编号就按编号直取：编号是作品身份，
            // 直取的唯一结果就是这一款，不需要再过标题精确匹配。
            final DlsiteWorkId? dlsiteId = dlsiteWorkIdOfGalgame(game);
            final List<SourceCandidate> candidates = (await controller.search(
              dlsiteId?.value ?? game.displayName,
            )).candidates;
            final SourceCandidate? candidate = dlsiteId != null
                ? (candidates.length == 1 ? candidates.single : null)
                : uniqueExactScrapeTitleMatch<SourceCandidate>(
                    query: game.displayName,
                    candidates: candidates,
                    titles: (SourceCandidate candidate) => <String>[
                      if (candidate.nameCn != null) candidate.nameCn!,
                      if (candidate.name != null) candidate.name!,
                    ],
                    sourceOf: (SourceCandidate candidate) => candidate.source,
                  );
            if (candidate == null) {
              result = candidates.isEmpty
                  ? ScrapeBatchItemResult.skipped
                  : ScrapeBatchItemResult.needsReview;
            } else {
              final bool applied = await applyGalgameScrapeCandidate(
                repo: _repo,
                gameId: game.id,
                candidate: candidate,
                controller: controller,
                replaceExistingCover: false,
              );
              result = applied
                  ? ScrapeBatchItemResult.applied
                  : ScrapeBatchItemResult.skipped;
            }
          } catch (e, stack) {
            ErrorLogService.instance.log('GamesLibrary.scrapeAll', e, stack);
            result = ScrapeBatchItemResult.failed;
          }
          summary = summary.add(result);
          onProgress(
            ScrapeBatchProgress(
              current: index + 1,
              total: games.length,
              title: game.displayName,
              summary: summary,
            ),
          );
        }
        if (mounted) await _reload();
        return summary;
      },
    );
  }

  /// BUG-3361：合集成员数与合集详情页（[buildGameCollectionMemberCard]）同一判据。
  bool _isGameCollectionMemberVisible(String mediaType, String entryKey) =>
      isGameCollectionMemberVisible(
        games: _games,
        mediaType: mediaType,
        entryKey: entryKey,
      );

  /// 把游戏卡拖到合集行头 = 把该游戏加入本合集
  /// （合集折叠卡上的 [CollectionDropTarget]）。
  ///
  /// 「查成员 → 幂等提示 → 落库 → 失败提示」收口在 [addMediaRefToCollection]
  /// （书架 / 视频库 / 游戏库同一份，且永不抛出——它挂在 `void` 回调上）；
  /// 真写进去了才重取合集映射刷新并报成功。
  Future<void> _addMediaToCollection(
    int collectionId,
    MediaRef mediaRef,
  ) async {
    final CollectionAddOutcome outcome = await addMediaRefToCollection(
      database: _appModel.database,
      collectionId: collectionId,
      mediaRef: mediaRef,
    );
    if (outcome != CollectionAddOutcome.added || !mounted) return;
    await _loadCollectionMaps();
    _refresh();
    FushiToast.show(
      msg: t.batch_add_to_collection_success(n: 1),
      severity: ToastSeverity.success,
    );
  }

  /// 合集折叠卡点击 → 通用合集网格详情页。game 成员用游戏卡渲染、点击进详情页；
  /// 非 game 成员（混合合集里的书/视频）builder 返 null 由详情页跳过——书架/视频页
  /// 打开同一合集时依旧渲染它们自己的成员，互不越界。
  ///
  /// 不注入 [MediaCollectionGridDetailPage.onDeleteMembersMedia]：game 维度先只支持
  /// 解散合集不删游戏本体（对齐「删除合集不删媒体本体、勾选才删」语义的保守端——
  /// 游戏本体是用户安装目录，绝不能从合集路径误删）。
  void _openCollectionDetail(MediaCollectionRow collection) {
    Navigator.push<void>(
      context,
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => MediaCollectionGridDetailPage(
          database: _appModel.database,
          collection: collection,
          memberCardBuilder:
              (
                String mediaType,
                String entryKey, {
                VoidCallback? onRemoveFromCollection,
              }) => buildGameCollectionMemberCard(
                games: _games,
                mediaType: mediaType,
                entryKey: entryKey,
                scrapeArt: _gameScrapeArt,
              ),
          isMemberVisible: _isGameCollectionMemberVisible,
          // 合集头部的成员封面扇形（游戏没有阅读进度，不走 memberInfoOf）。
          memberCoverOf: (String mediaType, String entryKey) =>
              gameCollectionMemberCover(
                games: _games,
                mediaType: mediaType,
                entryKey: entryKey,
              ),
          // 头部成员封面的 NSFW 并入游戏自己的成人向标记。
          memberNsfwOf: (String mediaType, String entryKey) =>
              gameCollectionMemberNsfw(
                games: _games,
                mediaType: mediaType,
                entryKey: entryKey,
              ),
          onOpenMember: _openCollectionMember,
          onChanged: () {
            unawaited(_reload());
          },
          collectionAiSettings: isAiModuleEnabled(_appModel.moduleVisibility)
              ? _appModel.prefsRepo
              : null,
        ),
      ),
    );
  }

  /// 合集详情页「打开成员」：game 成员进详情页（含启动按钮，复用库页带再入守卫的
  /// [_launchGame]）；其它 mediaType 非本页职责，忽略。
  void _openCollectionMember(String mediaType, String entryKey) {
    if (MediaKind.tryParse(mediaType) != MediaKind.game) return;
    final GalgameEntry? game = _repo.byId(entryKey);
    if (game == null) return;
    unawaited(_openDetail(game));
  }

  /// 点 / Enter / 手柄 A 激活游戏卡（2026-11-16 所有者：与小说同规则）：刮削过的
  /// 游戏（[GameItemScrapeArt.hasScrapeFor]）先进详情页（[_openDetail]，「启动游戏」
  /// 在那里），没刮削的照旧直接启动。「继续游玩」行 / 伴屏的启动入口仍直接启动
  /// （[_launchGame]）；多选态由卡片自己接管点按，不走这里。
  Future<void> _activateGame(GalgameEntry game) async {
    if (_gameScrapeArt.hasScrapeFor(game)) {
      await _openDetail(game);
      return;
    }
    await _launchGame(game);
  }

  /// 启动一个游戏 → 台词进查词弹窗：非 Windows 优雅提示不支持；Windows 上交给
  /// 启动前先按 exe 位数确保 helper 就位，再交给 app 级 Hook 会话。
  Future<void> _launchGame(GalgameEntry game) async {
    if (_launching) return; // 再入守卫：启动进行中，忽略重复点击（避免多开确认对话框）。
    _launching = true;
    // 查词卡的**词头**跟这个游戏的文本语言走（释义跟词典走）。hook 文本没有任何
    // 语言声明可读，所以这里用的就是用户在卡菜单里指定的值；没指定则落全局默认。
    _appModel.enterGameLookupLanguage(game.language);
    try {
      if (!Platform.isWindows) {
        FushiToast.show(
          msg: t.game_launch_unsupported,
          severity: ToastSeverity.error,
        );
        return;
      }
      if (!File(game.exePath).existsSync()) {
        FushiToast.show(msg: t.game_exe_missing, severity: ToastSeverity.error);
        return;
      }
      final bool is32Bit =
          await EngineHookGalAudioSource.exeIs32Bit(game.exePath) ?? false;
      // BUG-1448：**不得**拿「injector 文件在不在」当调用 ensureInjector 的前置门。
      // 真正的判据是版本对账（`_ensureBundledVersion`，BUG-1246）——文件在、版本却是
      // 上一个 app 版本留下的，恰恰是必须换入的情形，却被这道门整个短路：随包新组件
      // 永远换不进去，旧 hook DLL 建出旧契约共享内存段，本体读到的就是
      // `protocol_mismatch`（用户现场：本体 1.3.1+1171 / 组件停在五天前）。
      // ensureInjector 自身幂等，已就位且版本一致时直接返回 true。
      if (!mounted) return;
      final bool installed = await GalgameHelperInstaller().ensureInjector(
        is32Bit: is32Bit,
        context: context,
      );
      if (!installed || !mounted) return;
      final GalHookSessionController session =
          widget.sessionController ?? GalHookSessionController.instance;
      // 反馈 kEFPY4cuKZ：先取好配置视图模型——会话在启动 / 附着之后才进入，那时页面可能已卸载。
      final ProfileViewModel profileVm = ref.read(
        profileViewModelProvider.notifier,
      );
      final GalHookLaunchResult result = await session.launchGame(
        game.exePath,
        launchArguments: game.launchArgumentTokens,
        workdir: game.workdir,
        gameId: game.id,
        gameTitle: game.displayName,
        japaneseLocaleMode: galJapaneseLocaleModeFromKey(
          game.japaneseLocaleMode,
        ),
        // BUG-2047：内容语言是转区 auto 判定的人工真值，entry 本来就在手上。
        contentLanguage: game.language,
      );
      // 反馈 kEFPY4cuKZ：游戏会话期间作品级配置（查词词典）按绑定生效（语言级 / 「游戏」
      // 媒体类型），不切 App 的激活配置；会话结束（游戏退出 / 停止捕获）即撤层。
      unawaited(
        profileVm.enterWorkSession(
          owner: session,
          languageTag: game.language,
          mediaType: ProfileMediaKind.game,
          endWhen: (listenable: session, ended: () => !session.state.isActive),
        ),
      );
      if (!mounted) return;
      // 每种结果都播报（BUG-1089）。旧实现只在 `!launched` 时说话，可注入降级和
      // 「游戏窗口从未出现」这两条路径 `launchGame` 都返回 true，于是点完「启动游戏」
      // 既看不到游戏也看不到任何提示 —— 用户感知就是「点了没反应」。
      final GalHookSessionState state = session.state;
      final GalHookLaunchOutcome outcome = classifyGalHookLaunchOutcome(
        result: result,
        hasBoundWindow: state.boundWindow != null,
        injectorFailure: state.injectorFailure,
      );
      // message 为 null = 本次启动已被更新的操作取代，不该播报（BUG-1142）。
      final String? message = galHookLaunchOutcomeMessage(
        outcome: outcome,
        result: result,
        failure: state.injectorFailure,
        lastError: state.lastError,
        injectorDetail: state.injectorDetail,
      );
      // BUG-1089 的着色面：outcome 已经把「跑起来了 / 只剩整机混音兜底 / 根本没起来」
      // 分好了，toast 的颜色跟着同一份判定走，别再让三种结局长成同一条无色提示。
      if (message != null) {
        FushiToast.show(
          msg: message,
          severity: switch (outcome) {
            GalHookLaunchOutcome.running => ToastSeverity.success,
            GalHookLaunchOutcome.degradedLoopback => ToastSeverity.warning,
            GalHookLaunchOutcome.failed ||
            GalHookLaunchOutcome.windowMissing => ToastSeverity.error,
            // message 为 null 时根本不播报，这里走不到。
            GalHookLaunchOutcome.superseded => ToastSeverity.neutral,
          },
        );
      }
      if (!result.launched) return;
      widget.onLaunched?.call();
    } finally {
      _launching = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<BookTagRow> allTags =
        ref.watch(allTagsProvider).valueOrNull ?? const <BookTagRow>[];
    final Set<String>? allowedIds = ref
        .watch(filteredGameIdsProvider)
        .valueOrNull;
    final List<GalgameEntry> visible = _visibleFor(allowedIds);
    // 「管理合集」页的成员数（BUG-4277）：管理页列的是全部游戏合集、不随搜索 /
    // 筛选变，成员数取全库折叠结果；放在 build 顶层，空库 / 筛选空态（不建网格）
    // 也照常发布，不会留着上一次的旧数。
    _collectionDisplayCounts.publish<GalgameEntry>(_foldGameUnits(_games));
    // BUG-1911：**不要**把三元收回来。在途下载占位与「库里有什么 / 筛出了什么」
    // 是两条正交的渲染输入，分支判定整个下沉到 [_buildBody]；这里再挑一次分支就
    // 等于重新把占位关进网格分支里。
    // 库页材质（2026-10-25 用户定版）：网格条目走透明卡盒（材质作用域挂在网格 sliver 上，
    // 见 [_buildLibrarySlivers]）。
    final Widget content = FushiFileDropTarget(
      debugLabel: 'games-library',
      onDrop: (List<String> paths, Offset position) =>
          unawaited(_handleDrop(paths, position)),
      // 搜索 / 筛选行叠进库页外壳的浮动工具区（用户标签筛选已并进筛选面板，
      // 不再单占一行标签 chip）（嵌套
      // [FushiFloatingChromeOverlay]，与书架 / 视频库 / 发现页同构）：往下滚
      // 跟外壳页签一起收起，内容滚到它们底下；主滚动视图经
      // [FushiFloatingChromeScrollInset] 拿到 MediaQuery 顶部 padding 自己让位。
      // 不在外壳里（独立 push）时 overlay 退化成「工具行 + 内容」竖排，与旧版面
      // 一致。
      child: FushiFloatingChromeOverlay(
        chrome: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (_singleRowHeader) ...<Widget>[
              _buildPageHeader(context),
            ] else if (_games.isNotEmpty)
              _buildToolbar(context, allTags),
          ],
        ),
        child: FushiFloatingChromeScrollInset(
          child: _buildBody(
            context,
            visible,
            tagFilterActive: allowedIds != null,
          ),
        ),
      ),
    );
    // 排序模式的「完成」栏叠在内容底部；返回键先退出排序模式。
    final Widget body = SectionPopScope(
      intercepting: _reordering,
      onIntercept: _endReorder,
      child: Stack(
        children: <Widget>[
          Positioned.fill(child: content),
          LibraryReorderBar.overlay(
            context: context,
            visible: _reordering,
            onDone: _endReorder,
          ),
        ],
      ),
    );
    // 嵌在游戏 tab 里（生产路径）：单件入口已统一收敛到「导入」分段（与书 /
    // 漫画 / 视频库页同位，2026-08-13 定案），不再摆 FAB。独立 push 时够不到
    // 分段导航，保留 FAB 兜底。
    if (widget.embedded) {
      return body;
    }
    // Apple 没有 FAB：「添加游戏」是导航栏右上角的「+」（iOS / macOS 列表页的
    // 添加动作在导航栏），MD3 才挂右下扩展 FAB。
    final bool apple = isGlassDesign(context);
    return Scaffold(
      appBar: FushiAppBar(
        title: Text(t.games),
        actions: <Widget>[
          const GamesLibraryLayoutToggle(),
          if (apple)
            FushiIconButton(
              key: const ValueKey<String>('games-library-add'),
              icon: FushiIcons.add,
              tooltip: t.game_add,
              onTap: _addGame,
            ),
        ],
      ),
      floatingActionButton: apple
          ? null
          : FushiFab(
              icon: const FushiIcon(FushiIcons.add),
              label: Text(t.game_add),
              tooltip: t.game_add,
              onPressed: _addGame,
            ),
      body: body,
    );
  }

  /// 单行页头（设计稿「游戏 · 库」GA9）：页签由游戏 tab 外壳的浮动工具栏画
  /// （主位零尺寸），动作登记进外壳动作组。高频四项平铺——🔍 搜索（恒外露）/
  /// 排序 / 筛选 / 网格·列表切换；低频三项（全部刮削 / 管理标签 / 管理合集）收进
  /// 恒外露的「⋯」。放不下时按 版式 → 排序 → 筛选 的顺序逐颗收进页头自己的
  /// 「⋯」（[FushiIconButton.overflowPriority]）。用户标签筛选并进筛选面板（不再
  /// 单占一行标签 chip），筛选生效（含用户标签）时筛选按钮亮圆点。库里还没有
  /// 游戏时只留布局切换。
  Widget _buildPageHeader(BuildContext context) {
    final bool hasGames = _games.isNotEmpty;
    final bool list = _listLayout;
    final String layoutLabel = list
        ? t.game_library_view_grid
        : t.game_library_view_list;
    final bool filtered =
        _view.hasActiveFilter || ref.watch(selectedTagIdsProvider).isNotEmpty;
    return FushiPageHeader.customTitle(
      title: const SizedBox.shrink(),
      search: hasGames ? _headerSearch : null,
      menuAnchor: hasGames ? _buildSortMenuAnchor() : null,
      actions: <Widget>[
        if (hasGames) ...<Widget>[
          FushiIconButton(
            key: const ValueKey<String>('games_sort_menu_button'),
            tooltip: list ? t.game_sort : t.library_sort_view,
            icon: FushiIcons.sort,
            overflowPriority: 20,
            // 窄窗：「排序与显示」底部抽屉；宽窗：锚定菜单，从本按钮（被收进
            // ⋯ 时从 ⋯）下沿弹出。
            onTap: libraryViewOptionsUseSheet(context)
                ? _openViewSheet
                : _sortMenu.toggle,
          ),
          FushiIconButton(
            key: const ValueKey<String>('games_filter_button'),
            tooltip: filtered
                ? '${t.game_filter} · ${t.library_filter_active}'
                : t.game_filter,
            icon: filtered
                ? FushiIcons.filled(FushiIcons.filter)
                : FushiIcons.filter,
            badge: filtered,
            overflowPriority: 30,
            onTap: () => unawaited(_showFilterSheet()),
          ),
        ],
        FushiIconButton(
          key: const ValueKey<String>('games-library-layout-toggle'),
          tooltip: layoutLabel,
          label: layoutLabel,
          icon: list ? FushiIcons.gridView : FushiIcons.listView,
          overflowPriority: 10,
          onTap: () =>
              unawaited(_appModel.prefsRepo.setGamesLibraryListLayout(!list)),
        ),
        if (hasGames)
          FushiHeaderMoreButton(
            key: const ValueKey<String>('games-library-more-anchor'),
            buttonKey: const ValueKey<String>('games-library-more'),
            entries: <FushiHeaderMoreEntry>[
              FushiHeaderMoreEntry(
                key: const ValueKey<String>('games_scrape_all'),
                icon: FushiIcons.manageSearch,
                label: t.scrape_all,
                onSelected: _scrapeAllGames,
              ),
              FushiHeaderMoreEntry(
                key: const ValueKey<String>('library_tag_settings'),
                icon: FushiIcons.settingsGear,
                label: t.tag_manage,
                onSelected: () => openLibraryTagManagement(
                  context,
                  ref: ref,
                  onTagsChanged: () => ref.invalidate(gameTagMapProvider),
                ),
              ),
              FushiHeaderMoreEntry(
                key: const ValueKey<String>('library_collection_manage'),
                icon: FushiIcons.collection,
                label: t.collection_manage_title,
                onSelected: _openCollectionManagement,
              ),
            ],
          ),
      ],
    );
  }

  /// 「排序」菜单的常驻锚点（[FushiPageHeader.menuAnchor]，铺满页头动作组）：
  /// 页头里的排序按钮可能被收进「⋯」，菜单挂在这里才总能打开；弹出位置跟着
  /// 触发控件（按钮或 ⋯，BUG-4715）。再点当前维度 = 翻转方向。
  Widget _buildSortMenuAnchor() {
    return FushiHeaderMenuAnchor(
      controller: _sortMenu,
      menuChildren: <Widget>[
        for (final GalgameSortField field in GalgameSortField.values)
          MenuItemButton(
            key: ValueKey<String>('games_sort_${field.name}'),
            autofocus: field == _view.sortField,
            onPressed: () => _selectSortField(field),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(galgameSortFieldLabel(field)),
                if (field == _view.sortField) ...<Widget>[
                  const SizedBox(width: 12),
                  FushiIcon(
                    _view.ascending ? FushiIcons.arrowUp : FushiIcons.arrowDown,
                    size: 16,
                  ),
                ],
              ],
            ),
          ),
        // 「每行数量」只管海报网格，列表布局下不出。
        if (!_listLayout) ...<Widget>[
          const FushiDivider(),
          for (final LibraryViewOption option in _gridColumnsSection().options)
            MenuItemButton(
              key: option.key,
              onPressed: option.onSelected,
              trailingIcon: option.selected
                  ? const FushiIcon(FushiIcons.check, size: 16)
                  : null,
              child: Text('${t.library_grid_columns} · ${option.label}'),
            ),
        ],
      ],
    );
  }

  /// 游戏网格当前尺寸档下的「每行数量」，null = 自动。
  int? get _gridFixedColumns => _appModel.prefsRepo.libraryGridColumns(
    LibraryGridDomain.games,
    libraryGridSizeClassOf(context),
  );

  /// 「每行数量」一组（排序菜单与窄窗抽屉共用）。
  LibraryViewSection _gridColumnsSection() {
    final WindowSizeClass sizeClass = libraryGridSizeClassOf(context);
    return libraryGridColumnsSection(
      sizeClass: sizeClass,
      selected: _gridFixedColumns,
      onSelected: (int? columns) {
        unawaited(
          _appModel.prefsRepo.setLibraryGridColumns(
            LibraryGridDomain.games,
            sizeClass,
            columns,
          ),
        );
        setState(() {});
      },
    );
  }

  /// 窄窗「排序与显示」底部抽屉：排序维度（再点当前维度 = 翻转方向，选中项带
  /// 方向箭头）+ 每行数量（列表布局下不出）。游玩状态等维度仍在「筛选」面板。
  void _openViewSheet() {
    unawaited(
      showLibraryViewSheet(
        context: context,
        title: _listLayout ? t.game_sort : t.library_sort_view,
        sections: () => <LibraryViewSection>[
          LibraryViewSection(
            title: t.game_sort,
            options: <LibraryViewOption>[
              for (final GalgameSortField field in GalgameSortField.values)
                LibraryViewOption(
                  key: ValueKey<String>('games_sort_${field.name}'),
                  label: galgameSortFieldLabel(field),
                  icon: field == _view.sortField
                      ? (_view.ascending
                            ? FushiIcons.arrowUp
                            : FushiIcons.arrowDown)
                      : null,
                  selected: field == _view.sortField,
                  onSelected: () => _selectSortField(field),
                ),
            ],
          ),
          if (!_listLayout) _gridColumnsSection(),
        ],
      ),
    );
  }

  /// 顶部工具行：搜索框 + 游玩状态筛选 + 行尾刮削 / 排序 / 筛选面板 / 管理标签，
  /// 与书架 / 视频库同一个 [LibraryToolbar]（宽屏一行）。
  ///
  /// 2026-10 体验优化：原先窄屏搜索框与行尾五个控件挤一行，手机上被挤到只剩
  /// 图标宽。窄屏改两行：搜索框独占一行，第二行放状态筛选 + 筛选按钮 + 管理
  /// 标签，刮削 / 排序收进溢出菜单（与书架 `_compactLibraryToolbar` 同口径，
  /// 见 [LibraryToolbar.compactTrailing]）。
  Widget _buildToolbar(BuildContext context, List<BookTagRow> allTags) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    // 管理标签（常驻，无标签时唯一的新建标签入口）。
    Widget tagActions() => FushiTagFilterBar(
      tags: allTags,
      part: FushiTagFilterBarPart.actions,
      onToggleFilter: _toggleTagFilter,
      onReorder: _reorderTags,
      onTagsChanged: () => ref.invalidate(gameTagMapProvider),
      // AI 整理库（spec 2026-10-20 §10.1）：过 AI 模块门。
      onAiOrganize: isAiModuleEnabled(_appModel.moduleVisibility)
          ? () => unawaited(
              runLibraryOrganizeInteractive(
                context: context,
                appModel: _appModel,
                domain: CollectionShelfDomain.games,
                onChanged: () {
                  if (mounted) unawaited(_reload());
                },
              ),
            )
          : null,
    );
    return LibraryToolbar(
      compactKey: const ValueKey<String>('games_toolbar_compact'),
      search: LibrarySearchField(
        fieldKey: null,
        controller: _searchController,
        hintText: t.game_search,
        // 搜索词只影响本次会话，不落库（见 GalgameLibraryView 注释）。
        onChanged: (String value) =>
            setState(() => _view = _view.copyWith(search: value)),
        onClear: () {
          _searchController.clear();
          setState(() => _view = _view.copyWith(search: ''));
        },
      ),
      filters: <Widget>[
        // 游玩状态与筛选面板里的「游玩状态」是同一个 [GalgameLibraryView.status]，
        // 两处入口改的是同一份持久化视图，不会互相打架。
        LibraryFilterDropdown<GalgamePlayStatus>(
          key: const ValueKey<String>('games_filter_play_status'),
          value: _view.status,
          options: const <GalgamePlayStatus>[
            ...kGalgamePlayStatusMenuOrder,
            GalgamePlayStatus.unset,
          ],
          labelOf: galgamePlayStatusLabel,
          title: t.game_filter_status,
          allLabel: t.game_filter_all,
          onSelected: (GalgamePlayStatus? status) => _setView(
            status == null
                ? _view.copyWith(clearStatus: true)
                : _view.copyWith(status: status),
          ),
        ),
      ],
      // 宽屏动作：刮削 | 排序 + 筛选（Apple 下各成一枚玻璃胶囊）| 管理标签。
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _buildActionToolbar(colors),
          const SizedBox(width: 8),
          tagActions(),
        ],
      ),
      // 窄屏动作：筛选 | 管理标签 | ⋮（全部刮削 + 排序维度）。
      compactTrailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _buildFilterButton(colors),
          tagActions(),
          _buildCompactOverflowMenu(),
        ],
      ),
    );
  }

  Widget _buildActionToolbar(ColorScheme colors) {
    return FushiToolbar(
      dense: true,
      groups: <List<Widget>>[
        <Widget>[
          FushiIconButton(
            tooltip: t.scrape_all,
            label: t.scrape_all,
            icon: FushiIcons.manageSearch,
            onTap: _scrapeAllGames,
          ),
        ],
        <Widget>[
          FushiPopupMenuButton<GalgameSortField>(
            tooltip: t.game_sort,
            icon: const FushiIcon(FushiIcons.sort),
            onSelected: _selectSortField,
            itemBuilder: (BuildContext context) =>
                <PopupMenuEntry<GalgameSortField>>[
                  for (final GalgameSortField field in GalgameSortField.values)
                    PopupMenuItem<GalgameSortField>(
                      value: field,
                      child: _sortFieldMenuLabel(field),
                    ),
                ],
          ),
          _buildFilterButton(colors),
        ],
      ],
    );
  }

  /// 再点当前维度 = 翻转方向（少一个独立的升降序按钮）。
  void _selectSortField(GalgameSortField field) => _setView(
    field == _view.sortField
        ? _view.copyWith(ascending: !_view.ascending)
        : _view.copyWith(sortField: field),
  );

  Widget _sortFieldMenuLabel(GalgameSortField field) {
    return Row(
      children: <Widget>[
        Expanded(child: Text(galgameSortFieldLabel(field))),
        if (field == _view.sortField)
          FushiIcon(
            _view.ascending ? Icons.arrow_upward : Icons.arrow_downward,
            size: 16,
          ),
      ],
    );
  }

  Widget _buildFilterButton(ColorScheme colors) {
    // 用户标签筛选已并进筛选面板，生效判据同页头筛选钮：持久化筛选或用户标签。
    final bool active =
        _view.hasActiveFilter || ref.watch(selectedTagIdsProvider).isNotEmpty;
    return FushiIconButtonControl(
      tooltip: t.game_filter,
      onPressed: () => unawaited(_showFilterSheet()),
      // 有筛选生效：实心字形 + 强调色（M3E 的「激活」= FILL 1）。
      icon: FushiIcon(
        active ? FushiIcons.filled(FushiIcons.filter) : FushiIcons.filter,
        color: active ? colors.primary : null,
      ),
    );
  }

  /// 窄屏溢出菜单：「全部刮削」+ 排序维度（排序维度直接平铺，少一层子菜单）。
  Widget _buildCompactOverflowMenu() {
    return FushiPopupMenuButton<Object>(
      key: const ValueKey<String>('games_toolbar_overflow'),
      tooltip: t.common_more_actions,
      icon: FushiIcon(
        isGlassDesign(context) ? FushiIcons.moreHoriz : FushiIcons.more,
      ),
      onSelected: (Object value) {
        if (value is GalgameSortField) {
          _selectSortField(value);
        } else if (value == _GamesToolbarOverflowAction.scrapeAll) {
          unawaited(_scrapeAllGames());
        } else if (value == _GamesToolbarOverflowAction.viewOptions) {
          _openViewSheet();
        }
      },
      itemBuilder: (BuildContext context) => <PopupMenuEntry<Object>>[
        PopupMenuItem<Object>(
          value: _GamesToolbarOverflowAction.scrapeAll,
          child: Row(
            children: <Widget>[
              const FushiIcon(FushiIcons.manageSearch, size: 20),
              const SizedBox(width: 12),
              Expanded(child: Text(t.scrape_all)),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<Object>(
          enabled: false,
          height: 32,
          child: Text(t.game_sort),
        ),
        for (final GalgameSortField field in GalgameSortField.values)
          PopupMenuItem<Object>(
            value: field,
            child: _sortFieldMenuLabel(field),
          ),
        // 旧工具行（Apple / 非嵌入）窄屏：「每行数量」进抽屉调。
        if (!_listLayout) ...<PopupMenuEntry<Object>>[
          const PopupMenuDivider(),
          PopupMenuItem<Object>(
            key: const ValueKey<String>('games_overflow_view_options'),
            value: _GamesToolbarOverflowAction.viewOptions,
            child: Text(t.library_grid_columns),
          ),
        ],
      ],
    );
  }

  void _toggleTagFilter(int tagId) {
    final Set<int> next = Set<int>.from(ref.read(selectedTagIdsProvider));
    if (!next.remove(tagId)) next.add(tagId);
    ref.read(selectedTagIdsProvider.notifier).state = next;
  }

  Future<void> _reorderTags(int oldIndex, int newIndex) async {
    final List<BookTagRow>? tags = ref.read(allTagsProvider).valueOrNull;
    if (tags == null) return;
    final List<BookTagRow> reordered = List<BookTagRow>.from(tags);
    final BookTagRow moved = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, moved);
    final bool ok = await reorderTagsSafely(
      write: () => _appModel.database.reorderTags(
        reordered.map((BookTagRow tag) => tag.id).toList(),
      ),
    );
    if (!ok) return;
    ref.invalidate(allTagsProvider);
  }

  /// 清空全部筛选：持久化视图里的状态 / 来源 / 元数据标签 / NSFW 之外的筛选，
  /// 连同用户标签筛选（[selectedTagIdsProvider]，原标签 chip 行并进筛选面板后
  /// 由这里一起清）。
  void _clearAllFilters() {
    _setView(_view.clearFilters());
    if (ref.read(selectedTagIdsProvider).isNotEmpty) {
      ref.read(selectedTagIdsProvider.notifier).state = <int>{};
    }
  }

  /// 筛选面板：状态 / 本地·在线 / 用户标签 / 元数据标签多选 / NSFW 隐藏。改动即时
  /// 生效并持久化（用户标签筛选是会话态，与原标签 chip 行同一份
  /// [selectedTagIdsProvider]）。
  /// 走库页共用的 [showLibraryFilterPanel]（与视频库同一个面板：窄窗底部弹层、
  /// 宽窗居中浮动面板），间距/文字全走 [FushiDesignTokens]。
  Future<void> _showFilterSheet() async {
    final List<String> allTags = collectGalgameTags(_games);
    await showLibraryFilterPanel(
      context: context,
      title: t.game_filter,
      clearLabel: t.game_filter_reset,
      onClearAll: _clearAllFilters,
      sections: (BuildContext ctx, LibraryFilterPanelUpdate update) {
        final FushiDesignTokens tokens = FushiDesignTokens.of(ctx);
        void apply(GalgameLibraryView next) => update(() => _setView(next));
        final List<BookTagRow> userTags =
            ref.read(allTagsProvider).valueOrNull ?? const <BookTagRow>[];
        final Set<int> selectedUserTags = ref.read(selectedTagIdsProvider);
        return <Widget>[
          // M3E：单选维度用 choice chip、多选维度（标签）用 filter chip；状态
          // chip 带各自的语义图标（与封面角标同一套）。
          LibraryFilterSection(
            title: t.game_filter_status,
            children: <Widget>[
              FushiChoiceChip(
                label: Text(t.game_filter_all),
                selected: _view.status == null,
                onSelected: (_) => apply(_view.copyWith(clearStatus: true)),
              ),
              for (final GalgamePlayStatus status in <GalgamePlayStatus>[
                ...kGalgamePlayStatusMenuOrder,
                GalgamePlayStatus.unset,
              ])
                FushiChoiceChip(
                  avatar: FushiIcon(galgamePlayStatusIcon(status), size: 18),
                  label: Text(galgamePlayStatusLabel(status)),
                  selected: _view.status == status,
                  onSelected: (bool selected) => apply(
                    selected
                        ? _view.copyWith(status: status)
                        : _view.copyWith(clearStatus: true),
                  ),
                ),
            ],
          ),
          LibraryFilterChoiceSection<GalgameLocalFilter>(
            title: t.game_filter_source,
            values: GalgameLocalFilter.values,
            selected: _view.localFilter,
            allValue: GalgameLocalFilter.all,
            allLabel: t.game_filter_all,
            labelOf: galgameLocalFilterLabel,
            onSelected: (GalgameLocalFilter filter) =>
                apply(_view.copyWith(localFilter: filter)),
          ),
          // 用户标签（共享标签池，原库页标签 chip 行）：多选 = 取交集，与原
          // chip 行同一语义（[filteredGameIdsProvider]）。
          if (userTags.isNotEmpty)
            LibraryFilterSection(
              key: const ValueKey<String>('games_filter_user_tags'),
              title: t.game_user_tags_title,
              children: <Widget>[
                for (final BookTagRow tag in userTags)
                  FushiFilterChip(
                    key: ValueKey<String>('games_filter_user_tag_${tag.id}'),
                    label: Text(tag.name),
                    selected: selectedUserTags.contains(tag.id),
                    onSelected: (bool _) =>
                        update(() => _toggleTagFilter(tag.id)),
                  ),
              ],
            ),
          if (allTags.isNotEmpty)
            LibraryFilterSection(
              title: t.game_filter_tags,
              children: <Widget>[
                for (final String tag in allTags)
                  FushiFilterChip(
                    label: Text(tag),
                    selected: _view.tags.contains(tag),
                    onSelected: (bool selected) {
                      final Set<String> next = Set<String>.of(_view.tags);
                      if (selected) {
                        next.add(tag);
                      } else {
                        next.remove(tag);
                      }
                      apply(_view.copyWith(tags: next));
                    },
                  ),
              ],
            ),
          SizedBox(height: tokens.spacing.gap),
          AdaptiveSettingsSwitchRow(
            title: t.game_filter_hide_nsfw,
            value: _view.hideNsfw,
            onChanged: (bool value) => apply(_view.copyWith(hideNsfw: value)),
          ),
        ];
      },
    );
  }

  /// 空态：居中图标 + 提示 + 添加按钮。走共享空状态 [FushiPlaceholderMessage]
  /// （MD3 = 中性分组底卡；Apple = ContentUnavailableView 式无底居中），不再
  /// 手写一套图标 + 文案 + 按钮的列。
  Widget _buildEmpty(BuildContext context) {
    return FushiPlaceholderMessage(
      icon: FushiIcons.games,
      message: t.game_empty,
      // 嵌壳时空态引导去「导入」分段（唯一入库位置）；独立使用时直接选 exe。
      action: widget.embedded
          ? FushiFilledButton.icon(
              onPressed: () =>
                  gameSectionNotifier.value = GameSection.importGames,
              icon: const FushiIcon(FushiIcons.libraryAdd),
              label: Text(t.library_empty_go_import),
            )
          : FushiFilledButton.icon(
              onPressed: _addGame,
              icon: const FushiIcon(FushiIcons.add),
              label: Text(t.game_add),
            ),
    );
  }

  /// 「库里有游戏但被筛掉了」态：与空库分开，否则用户以为数据没了。
  /// 附「重置筛选」直达动作，省得用户再去找筛选面板底部的按钮。
  Widget _buildNoMatch(BuildContext context) {
    return FushiPlaceholderMessage(
      icon: FushiIcons.searchOff,
      message: t.game_no_match,
      action:
          _view.hasActiveFilter || ref.read(selectedTagIdsProvider).isNotEmpty
          ? FushiFilledButton.tonalIcon(
              onPressed: _clearAllFilters,
              icon: const FushiIcon(FushiIcons.filterList),
              label: Text(t.game_filter_reset),
            )
          : null,
    );
  }

  /// 游戏卡总高 = 卡盒封面高（[cardWidth] ÷ [kShelfGameCaseAspectRatio]，竖长
  /// 1:1.6）+ 封面下文字块（[ShelfCardMeta.heightFor]：标题一行 + 副行 + 进度条，
  /// 随文字缩放变高）。
  ///
  /// BUG-1184：网格不用死比例（曾是 `childAspectRatio: 0.62`，窄屏文字区被挤得放
  /// 不下），按真实行高算；在途占位段、散卡 / 合集折叠卡网格共用此公式。
  static double _gameCardExtent(BuildContext context, double cardWidth) {
    return cardWidth / kShelfGameCaseAspectRatio +
        ShelfCardMeta.heightFor(context);
  }

  /// 库页主体：**在途下载占位**与**库内容**是两条并列的渲染输入，同挂一棵
  /// [CustomScrollView]。
  ///
  /// BUG-1911（二次修正）：占位卡代表的是「还没进库的东西」，它天然不受「库里
  /// 有什么」（`_games`）和「筛选匹配了什么」（`visible`）这两个判据管辖。首版把
  /// 占位 sliver 挂在网格构造内部，于是空库首次下载（走空态）与筛选无匹配（走无
  /// 匹配态）这两条路径上占位整个消失——恰恰是用户最需要它的时刻（用户原话「否则
  /// 不知道是否加入了」说的正是空库那一次）。现在占位恒定排在库内容段之前；空态 /
  /// 无匹配态用 [SliverFillRemaining] 只吃它**之后**的剩余空间，挤不掉它。
  Widget _buildBody(
    BuildContext context,
    List<GalgameEntry> visible, {
    required bool tagFilterActive,
  }) {
    // 2026-10 动效重做：首屏卡片错峰淡入（与书架 / 视频库同一套），滚动带出的
    // 卡瞬间出现。切换网格 / 列表时重开进场窗口，新布局同样错峰进场。
    return FushiEntranceScope(
      replayKey: _listLayout,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final _GameGridMetrics metrics = _GameGridMetrics.forWidth(
            constraints.maxWidth,
            fixedColumns: _gridFixedColumns,
          );
          // 浮动工具区的让位（[FushiFloatingChromeScrollInset] 交来的 MediaQuery
          // 顶部 padding）由首个 sliver 吃掉，再从子树里摘掉，免得卡片里的
          // 竖向列表 / SafeArea 重复让一遍。
          final GalHookSessionController? session = _windowsSession;
          final Widget? header = session == null ? widget.header : null;
          final double chromeTop = MediaQuery.paddingOf(context).top;
          final List<GalgameEntry> continueGames = _continueGames(
            visible,
            tagFilterActive: tagFilterActive,
          );
          return MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: CustomScrollView(
              slivers: <Widget>[
                SliverToBoxAdapter(child: SizedBox(height: chromeTop)),
                if (session != null)
                  SliverToBoxAdapter(
                    child: _GameSessionBand(
                      controller: session,
                      games: _games,
                      onOpen: () => openGameCaptureWorkbench(context),
                    ),
                  )
                else if (header != null)
                  SliverToBoxAdapter(child: header),
                ..._buildPendingDownloadSlivers(context),
                ..._buildLibrarySlivers(
                  context,
                  visible,
                  metrics,
                  continueGames: continueGames,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 本机 Hook 会话（只在 Windows：galgame Hook 只做 Windows）；独立使用 /
  /// 非 Windows 时为 null。
  GalHookSessionController? get _windowsSession =>
      Platform.isWindows ? widget.sessionController : null;

  /// 下载块（与库内容段并列，见 [_buildBody]）：排在最前——用户刚点完下载，第
  /// 一眼要能确认「加进来了」。只在有任务时出现；块内逐项是「标题 + 真实状态」
  /// （[gameDownloadBlockTasks]），多于一屏横滑。
  List<Widget> _buildPendingDownloadSlivers(BuildContext context) {
    final List<DiscoveryDownloadTask> tasks = gameDownloadBlockTasks(
      _appModel.discoveryDownloadQueue.tasks,
    );
    if (tasks.isEmpty) return const <Widget>[];
    final VoidCallback? openDownloads =
        StoreRestrictedCapability.downloads.isAvailable
        ? widget.onOpenDownloads
        : null;
    return <Widget>[
      SliverPadding(
        key: const ValueKey<String>('games_pending_downloads'),
        padding: const EdgeInsets.fromLTRB(
          _kGameGridEdge,
          16,
          _kGameGridEdge,
          0,
        ),
        sliver: SliverToBoxAdapter(
          child: FushiStaggeredEntrance(
            index: 0,
            child: GameDownloadsBlock(tasks: tasks, onOpen: openDownloads),
          ),
        ),
      ),
    ];
  }

  /// 库内容段：空库 → 空态；有库但筛选无匹配 → 无匹配态；否则 → 海报网格。
  ///
  /// 两个提示态各自持有自己的布局（[SliverFillRemaining] 居中、不带网格那份 FAB
  /// 底部留白），所以它们只填满**占位段之后**的剩余高度，不会把占位挤出视口。
  List<Widget> _buildLibrarySlivers(
    BuildContext context,
    List<GalgameEntry> visible,
    _GameGridMetrics metrics, {
    required List<GalgameEntry> continueGames,
  }) {
    if (_games.isEmpty) {
      return <Widget>[
        SliverFillRemaining(hasScrollBody: false, child: _buildEmpty(context)),
      ];
    }
    if (visible.isEmpty) {
      return <Widget>[
        SliverFillRemaining(
          hasScrollBody: false,
          child: _buildNoMatch(context),
        ),
      ];
    }
    // 2026-10 游戏模块重设计：「继续游戏」横滑行（大横版 key art 卡）+「游戏库」
    // 网格两段。横滑行只在没有搜索 / 筛选时出现——筛选态下用户在找特定条目，
    // 同一个游戏在两段各出现一次只会干扰；没有玩过的游戏时也不出现。
    final bool showContinue = continueGames.isNotEmpty;
    return <Widget>[
      if (showContinue)
        SliverToBoxAdapter(
          key: const ValueKey<String>('games_continue_section'),
          // 主块 chip「游戏中」跟着 Hook 会话变（只在 Windows 有会话）。
          child: switch (_windowsSession) {
            final GalHookSessionController session => ListenableBuilder(
              listenable: session,
              builder: (BuildContext context, Widget? _) =>
                  _buildContinueSection(context, continueGames, metrics),
            ),
            null => _buildContinueSection(context, continueGames, metrics),
          },
        ),
      if (showContinue)
        SliverToBoxAdapter(
          // 封面色块版式：与上面「继续游戏」色块分区同一款分区标题。
          child: FushiContinueBlocks.active(context)
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(
                    _kGameGridEdge,
                    28,
                    _kGameGridEdge,
                    0,
                  ),
                  child: FushiBlockSectionTitle(t.game_library),
                )
              : FushiSectionTitle(
                  t.game_library,
                  padding: const EdgeInsets.fromLTRB(
                    _kGameGridEdge,
                    20,
                    _kGameGridEdge,
                    0,
                  ),
                ),
        ),
      // 透明卡盒材质只挂在网格段：「继续游戏」横版卡是 key art 大卡，不是盒子。
      ShelfCoverMaterialScope(
        material: ShelfCoverMaterial.gameCase,
        child: SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            _kGameGridEdge,
            16,
            _kGameGridEdge,
            88,
          ),
          sliver: SliverMainAxisGroup(
            slivers: _buildGridSlivers(
              context,
              visible,
              metrics,
              heroTaken: showContinue,
            ),
          ),
        ),
      ),
    ];
  }

  /// 「继续游戏」候选：当前可见集里玩过的游戏，按最近游玩倒序取前
  /// [_kContinueMaxItems] 个。搜索 / 状态 / 来源 / 元数据标签 / 用户标签任一
  /// 筛选生效时返回空（NSFW 隐藏是常驻偏好，不算「在找东西」，已体现在 visible 里）。
  List<GalgameEntry> _continueGames(
    List<GalgameEntry> visible, {
    required bool tagFilterActive,
  }) {
    final GalgameLibraryView view = _view;
    if (tagFilterActive ||
        view.search.trim().isNotEmpty ||
        view.status != null ||
        view.localFilter != GalgameLocalFilter.all ||
        view.tags.isNotEmpty) {
      return const <GalgameEntry>[];
    }
    final List<GalgameEntry> played =
        <GalgameEntry>[
          for (final GalgameEntry game in visible)
            if (game.lastPlayedMs > 0) game,
        ]..sort(
          (GalgameEntry a, GalgameEntry b) =>
              b.lastPlayedMs.compareTo(a.lastPlayedMs),
        );
    return played.take(_kContinueMaxItems).toList();
  }

  /// 「继续游戏」段（2026-11-01 用户：「游戏也套用继续阅读这个并列卡统一一下」）。
  ///
  /// 封面色块版式（[FushiContinueBlocks.active]，设计稿「游戏 · 库」）：分区标题
  /// + 「主块 + 横滑条」——第一块（运行中的游戏，否则最近玩的）是**本页唯一的加
  /// 大块**（顶上 chip：游戏中 / 开发商，主按钮外观「▶ 继续游戏」），其余半高块
  /// 在旁边横滑；下方游戏库网格因此全是等尺寸块（见 [_buildGridSlivers]）。
  /// 封面网格 / 墨水屏：与书架同一个封面取色并列卡（[FushiContinueCardRow]）。
  /// 点按启动，长按 / 右键进详情。
  Widget _buildContinueSection(
    BuildContext context,
    List<GalgameEntry> games,
    _GameGridMetrics metrics,
  ) {
    final GalHookSessionController? session = _windowsSession;
    final bool blocks = FushiContinueBlocks.active(context);
    FushiContinueEntry entryOf(GalgameEntry game) {
      final String? cover = game.coverPath;
      final bool hasCover =
          cover != null && cover.isNotEmpty && File(cover).existsSync();
      final bool running =
          session != null &&
          galHookSessionRunsGame(
            session,
            gameId: game.id,
            exePath: game.exePath,
          );
      final List<String> meta = <String>[
        if (game.totalPlaySeconds > 0)
          formatStatTime(game.totalPlaySeconds * 1000),
        if (game.lastPlayedMs > 0)
          formatGalgameDate(
            DateTime.fromMillisecondsSinceEpoch(game.lastPlayedMs),
          ),
      ];
      return FushiContinueEntry(
        key: ValueKey<String>('games_continue_card_${game.id}'),
        focusId: FushiFocusId('games-continue-${game.id}'),
        // 与下方网格同一个卡盒圆角。
        cover: ShelfCoverRadiusScope(
          radius: galgameCoverRadius(context),
          child: GameCoverThumb(game: game),
        ),
        // 游玩状态角标：色块里是 6 档状态色 chip，并列卡里是饱和色块胶囊；
        // 未设置不画。
        badge: game.playStatus == GalgamePlayStatus.unset
            ? null
            : blocks
            ? GalgamePlayStatusChip(status: game.playStatus)
            : galgamePlayStatusBadge(game.playStatus),
        semanticLabel: '${t.game_focus_continue} · ${game.displayName}',
        // 封面色块版式：与库墙色块同一张裸封面（卡盒摆法由色块自己画）。
        blockCover: GameCoverThumb(game: game),
        // 主块顶上的 chip：运行中 =「游戏中」，否则开发商（设计稿 `.chip`）。
        blockEyebrow: running
            ? t.game_library_session_playing
            : _nonEmptyOrNull(game.developer),
        material: ShelfCoverMaterial.gameCase,
        coverAspectRatio: kShelfGameCaseAspectRatio,
        colorSource: hasCover ? resizedFileImage(File(cover)) : null,
        title: game.displayName,
        subtitle: meta.isEmpty ? null : meta.join(' · '),
        onOpen: () => unawaited(_launchGame(game)),
        onLongPress: () => unawaited(_openDetail(game)),
      );
    }

    final List<FushiContinueEntry> entries = <FushiContinueEntry>[
      for (final GalgameEntry g in games) entryOf(g),
    ];
    if (blocks) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          _kGameGridEdge,
          16,
          _kGameGridEdge,
          0,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FushiBlockSectionTitle(t.game_focus_continue),
            SizedBox(height: FushiDesignTokens.of(context).spacing.card),
            FushiCoverBlockStrip(
              key: const ValueKey<String>('games_continue_row'),
              itemCount: entries.length,
              itemBuilder:
                  (BuildContext context, int i, FushiCoverBlockSize size) =>
                      // State（取色、悬停姿态）跟着条目走，不跟格子下标；朝向
                      // 探测与 [FushiContinueBlocks] 同一层包装。
                      KeyedSubtree(
                        key: ValueKey<Key>(entries[i].key),
                        child: FushiContinueOrientedEntry(
                          entry: entries[i],
                          builder: (FushiContinueEntry e) =>
                              FushiContinueBlockCard(
                                entry: e,
                                size: size,
                                label: t.game_focus_continue,
                                action: FushiCoverBlockAction(
                                  icon: FushiIcons.play,
                                  label: t.game_focus_continue,
                                ),
                              ),
                        ),
                      ),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(_kGameGridEdge, 16, _kGameGridEdge, 0),
      child: FushiContinueCardRow.grid(
        rowKey: const ValueKey<String>('games_continue_row'),
        label: t.game_focus_continue,
        bleed: _kGameGridEdge,
        columns: metrics.columns,
        cellWidth: metrics.cardWidth + _kGameGridSpacing,
        cellInset: _kGameGridSpacing / 2,
        entries: entries,
      ),
    );
  }

  /// 游戏显示单元折叠：游戏 → [groupByCollections] 的合集组与散卡组（未排序）。
  /// 网格吃筛选后的 [visible]，「管理合集」页的成员数（[_collectionDisplayCounts]）
  /// 吃全库 [_games]，两处同一份折叠规则（BUG-4277）。
  List<CollectionGroup<GalgameEntry>> _foldGameUnits(
    List<GalgameEntry> games,
  ) => groupByCollections<GalgameEntry>(
    items: <CollectionOrderingItem<GalgameEntry>>[
      for (final GalgameEntry game in games)
        CollectionOrderingItem<GalgameEntry>(
          mediaType: MediaKind.game,
          entryKey: game.id,
          importedAt: game.addedAt.millisecondsSinceEpoch,
          payload: game,
        ),
    ],
    primaryCollectionIdByEntry: _primaryCollectionByEntry,
    collectionsById: _collectionsById,
    memberSortIndex: _memberSortIndex,
  );

  /// 游戏卡盒网格 + 合集折叠卡。
  ///
  /// 卡宽目标≈168（ReinaManager 海报宽档），间距 16，卡高按真实行高算
  /// （[_gameCardExtent]），标题超长由卡内省略。
  ///
  /// 合集照书架范式折成网格里的**一个格子**（[_buildCollectionCard]：成员前几作
  /// 排成扇形，2026-10-25 用户拍板），与散卡同一个网格、按 [groupByCollections]
  /// 已排好的同一顺序混排；原先每个合集一条全宽横排行的形态已移除。排序/筛选
  /// 作用于 [_visibleFor]（散卡序与成员存活），组内成员序走合集 sortIndex（与书架/
  /// 详情页同一顺序真相源）。
  ///
  /// 列表布局：合集折叠卡单独一段网格排在前，散卡走列表行。
  ///
  /// [heroTaken]：上面「继续游戏」段已经出现——它的首块是本页唯一的加大块
  /// （设计稿「游戏 · 库」），网格这时全排等尺寸色块，不再有自己的拼贴首块。
  List<Widget> _buildGridSlivers(
    BuildContext context,
    List<GalgameEntry> visible,
    _GameGridMetrics metrics, {
    required bool heroTaken,
  }) {
    final List<CollectionGroup<GalgameEntry>> groups = _foldGameUnits(visible);
    if (_view.sortField == GalgameSortField.manual) {
      groups.sort(_compareManualUnits);
    }
    final List<String> unitKeys = <String>[
      for (final CollectionGroup<GalgameEntry> g in groups) _gameUnitKey(g),
    ];
    _sortedUnitKeys = unitKeys;
    if (_reordering) {
      final double extent = _gameCardExtent(context, metrics.cardWidth);
      return <Widget>[
        SliverToBoxAdapter(
          child: FushiReorderableGrid(
            key: const ValueKey<String>('games_reorder_grid'),
            itemCount: groups.length,
            crossAxisCount: metrics.columns,
            childAspectRatio: metrics.cardWidth / extent,
            crossAxisSpacing: _kGameGridSpacing,
            mainAxisSpacing: _kGameGridSpacing,
            feedbackBorderRadius: FushiBorderRadius.card,
            reordering: true,
            keyForIndex: (int i) => ValueKey<String>(unitKeys[i]),
            onReorder: (int from, int to) => _onGameReorder(unitKeys, from, to),
            itemBuilder: (BuildContext context, int i) =>
                FushiStaggeredEntrance(
                  index: i,
                  child: IgnorePointer(child: _buildGroupCard(groups[i])),
                ),
          ),
        ),
      ];
    }
    final SliverGridDelegate gridDelegate =
        SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: metrics.columns,
          mainAxisSpacing: _kGameGridSpacing,
          crossAxisSpacing: _kGameGridSpacing,
          mainAxisExtent: _gameCardExtent(context, metrics.cardWidth),
        );
    final ShellContentLayout contentLayout = shellContentLayoutOf(context);
    if (!_listLayout && contentLayout != ShellContentLayout.grid) {
      // 封面色块布局（拼贴 / 规整色块）：同一份分组与直拖重排，每格按色块尺寸档
      // 构造；「每行数量」偏好只管封面网格，这里按目标块宽自动定列。
      return <Widget>[
        LibraryDragReorderScope(
          enabled: !_view.hasActiveFilter && _view.search.trim().isEmpty,
          onReorder: (int from, int to) =>
              _onGameDragReorder(unitKeys, from, to),
          child: SliverFushiCoverBlocks(
            layout: heroTaken ? null : contentLayout,
            itemCount: groups.length,
            targetWidth: kFushiCoverBlockTargetWidthWide,
            itemBuilder:
                (BuildContext context, int i, FushiCoverBlockSize size) =>
                    LibraryReorderCell(
                      index: i,
                      child: _buildGroupCard(groups[i], block: size),
                    ),
          ),
        ),
      ];
    }
    if (!_listLayout) {
      return <Widget>[
        // 桌面直拖：卡与卡之间 = 重排，合集卡正中 = 放进合集（懒构建不变）。
        // 与合集详情页 `canReorder` 同一口径：搜索 / 筛选下不直拖重排（只剩拖进合集）。
        LibraryDragReorderScope(
          enabled: !_view.hasActiveFilter && _view.search.trim().isEmpty,
          onReorder: (int from, int to) =>
              _onGameDragReorder(unitKeys, from, to),
          child: SliverGrid.builder(
            gridDelegate: gridDelegate,
            itemCount: groups.length,
            itemBuilder: (BuildContext context, int i) =>
                FushiStaggeredEntrance(
                  index: i,
                  child: LibraryReorderCell(
                    index: i,
                    child: _buildGroupCard(groups[i]),
                  ),
                ),
          ),
        ),
      ];
    }
    // 列表布局：M3E 分段卡（组首尾大圆角、行间 2），每行小封面 + 标题 + 开发商
    // / 发行日 + 游玩状态 / 时长 / 最后游玩。合集折叠卡排在前面一段网格里。
    final List<CollectionGroup<GalgameEntry>> collections =
        <CollectionGroup<GalgameEntry>>[
          for (final CollectionGroup<GalgameEntry> group in groups)
            if (group.collection != null) group,
        ];
    final List<GalgameEntry> loose = <GalgameEntry>[
      for (final CollectionGroup<GalgameEntry> group in groups)
        if (group.collection == null) group.coverItem.payload,
    ];
    return <Widget>[
      if (collections.isNotEmpty)
        SliverPadding(
          padding: EdgeInsets.only(bottom: loose.isEmpty ? 0 : 16),
          sliver: SliverGrid.builder(
            gridDelegate: gridDelegate,
            itemCount: collections.length,
            itemBuilder: (BuildContext context, int i) =>
                FushiStaggeredEntrance(
                  index: i,
                  child: _buildGroupCard(collections[i]),
                ),
          ),
        ),
      if (loose.isNotEmpty)
        SliverList.builder(
          itemCount: loose.length,
          itemBuilder: (BuildContext context, int i) => FushiStaggeredEntrance(
            index: collections.length + i,
            child: _buildGameCard(
              loose[i],
              listIndex: i,
              listCount: loose.length,
            ),
          ),
        ),
    ];
  }

  /// 网格里的一个格子：散卡（collection == null，单成员）走 [_buildGameCard]；
  /// 合集走 [_buildCollectionCard]。
  /// [block] 非 null = 以封面色块卡渲染（库页布局为拼贴 / 规整色块）。
  Widget _buildGroupCard(
    CollectionGroup<GalgameEntry> group, {
    FushiCoverBlockSize? block,
  }) {
    final MediaCollectionRow? collection = group.collection;
    if (collection == null) {
      final GalgameEntry game = group.coverItem.payload;
      // 「另有：小说 · 动画」作品角标（AI 库管家 spec §4.3），数据取进程级作品图缓存。
      return WorkKindsBadgeOverlay.entry(
        database: _appModel.database,
        endpoint: (kind: MediaLinkKind.game, key: game.id),
        enabled: !_reordering,
        onPressed: _showWorkLinks,
        child: _buildGameCard(game, block: block),
      );
    }
    return WorkKindsBadgeOverlay.collection(
      database: _appModel.database,
      collectionId: collection.id,
      enabled: !_reordering,
      onPressed: _showWorkLinks,
      child: _buildCollectionCard(group, collection, block: block),
    );
  }

  /// 角标点开的「同一作品」弹窗（与书架书卡同一形态；游戏详情页里是常驻区块）。
  void _showWorkLinks(MediaLinkEndpoint self) {
    unawaited(
      showMediaLinksDialog(
        context: context,
        database: _appModel.database,
        self: self,
        onOpen: (MediaLinkEntry e) =>
            openMediaLinkEntry(context: context, ref: ref, entry: e),
        searchActionFor: (MediaLinkKind k) =>
            mediaLinkSearchAction(context: context, ref: ref, kind: k),
        onInfer: mediaLinkInferCallback(ref: ref, self: self),
      ),
    );
  }

  /// 合集长按菜单的封面图源：自设封面 → 组内顺序第一个有封面文件的游戏；都没有
  /// 时为 null（菜单不画封面块）。
  ImageProvider? _collectionMenuCoverImage(
    CollectionGroup<GalgameEntry> group,
    MediaCollectionRow collection,
  ) {
    final List<String?> candidates = <String?>[
      collection.coverPath,
      for (final CollectionOrderingItem<GalgameEntry> it in group.items)
        it.payload.coverPath,
    ];
    for (final String? path in candidates) {
      if (path != null && path.isNotEmpty && File(path).existsSync()) {
        return FileImage(File(path));
      }
    }
    return null;
  }

  /// 合集上下文菜单（合集卡与「管理合集」页同一个）。
  ///
  /// **刻意不注入** onDeleteMembersMedia：游戏合集删除只解散容器、绝不连带删
  /// 游戏（游戏本体是用户安装目录，从库移除走游戏卡菜单的「移除」；用户
  /// 2026-07-28 拍板恢复此纯解散语义）。
  Future<void> _showCollectionMenu(
    MediaCollectionRow collection, {
    ImageProvider? coverImage,
  }) => showCollectionContextDialog(
    context: context,
    db: _appModel.database,
    collection: collection,
    coverImage: coverImage,
    coverMaterial: ShelfCoverMaterial.gameCase,
    onOpenDetail: () => _openCollectionDetail(collection),
    onChanged: () => unawaited(_reload()),
  );

  /// 「管理合集」页：游戏库的全部合集，行动作复用本页的合集详情与合集菜单。
  void _openCollectionManagement() {
    Navigator.push<void>(
      context,
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => CollectionManagementPage(
          database: _appModel.database,
          domain: CollectionShelfDomain.games,
          onOpenCollection: _openCollectionDetail,
          onShowCollectionMenu: _showCollectionMenu,
          displayCounts: _collectionDisplayCounts,
        ),
      ),
    );
  }

  /// 合集折叠卡（2026-10-25 用户拍板，与书架合集格子同一套交互）：
  /// - 封面 = 成员前 4 作排成扇形（合集自设封面在最前，否则组内序首作）；
  /// - 副行 =「N 项 · 累计时长」，进度条 = 已通关成员占比（[galgameCollectionMeta]）；
  /// - 点击 = 进合集详情页；长按 / 右键 / 手柄长按 A = 合集上下文菜单
  ///   （打开详情 / 重命名 / 标签 / 排序 / 删除合集，与原横排行行头同一个）；
  /// - 焦点站点沿用原行头的 `games-collection-<id>`（手柄 / 方向键可达，A/Enter 打开）；
  /// - 拖游戏卡到这张卡 = 把该游戏加入本合集（原行头的拖放接收端搬到这里）。
  Widget _buildCollectionCard(
    CollectionGroup<GalgameEntry> group,
    MediaCollectionRow collection, {
    FushiCoverBlockSize? block,
  }) {
    final List<GalgameEntry> members = <GalgameEntry>[
      for (final CollectionOrderingItem<GalgameEntry> it in group.items)
        it.payload,
    ];
    final String? own = collection.coverPath;
    final bool hasOwnCover =
        own != null && own.isNotEmpty && File(own).existsSync();
    // NSFW 逐张判定（拍板台 w04vrhUAaX）：合集自设封面按合集，成员封面按成员
    // （成人向标记或所在 NSFW 合集）。不在卡壳挂合集一层——没标的合集会把其中
    // 成人向游戏的封面原样露出来。只有最前那张压「已隐藏」图标。
    final List<Widget> covers = <Widget>[
      if (hasOwnCover)
        MediaNsfwCover(
          target: MediaNsfwTarget.collection(collection.id),
          child: ShelfFileCover(
            path: own,
            placeholder: const ShelfCoverPlaceholder(
              icon: FushiIcons.collection,
              iconSize: 40,
            ),
          ),
        ),
      for (final (int i, GalgameEntry game)
          in members.take(hasOwnCover ? 3 : 4).indexed)
        MediaNsfwCover(
          target: MediaNsfwTarget.game(game.id, adult: game.isNsfw),
          showIcon: !hasOwnCover && i == 0,
          child: GameCoverThumb(game: game),
        ),
    ];
    final ({String subtitle, double? progress, bool completed, int seconds})
    meta = galgameCollectionMeta(members);
    // 色块卡：累计时长画成大数字，副行不再重复（语义标签仍用含时长的副行）。
    final FushiCoverBlockFigure? playFigure = galgamePlayTimeFigure(
      meta.seconds,
    );
    void openMenu() => unawaited(
      _showCollectionMenu(
        collection,
        coverImage: _collectionMenuCoverImage(group, collection),
      ),
    );
    return CollectionDropTarget(
      key: ValueKey<String>('games_collection_card_${collection.id}'),
      borderRadius: shelfMaterialRadius(ShelfCoverMaterial.gameCase),
      onMediaDropped: (MediaRef mediaRef) =>
          _addMediaToCollection(collection.id, mediaRef),
      child: block != null
          ? _GameCoverBlockCard(
              size: block,
              art: FushiCoverBlockArt.book,
              // 有刮削资料 / 横版背景图的合集：系列色块（竖版海报斜放 + 背景图 +
              // 概览 / chip），与书架合集卡、视频库系列卡同一个（2026-11-16）。
              series: _collectionSeriesMeta(collection, members.length),
              covers: covers.take(3).toList(growable: false),
              tintImage: hasOwnCover
                  ? resizedFileImage(File(own))
                  : _gameCoverImage(members.isEmpty ? null : members.first),
              title: collection.name,
              subtitle: playFigure == null
                  ? meta.subtitle
                  : galgameCollectionMeta(
                      members,
                      includePlayTime: false,
                    ).subtitle,
              figure: playFigure,
              progress: meta.progress,
              completed: meta.completed,
              focusId: FushiFocusId('games-collection-${collection.id}'),
              semanticLabel: '${collection.name} · ${meta.subtitle}',
              onTap: () => _openCollectionDetail(collection),
              onLongPress: openMenu,
            )
          : GalgamePosterCard(
              cover: covers.first,
              stackedCovers: covers.length > 1 ? covers.sublist(1) : null,
              title: collection.name,
              subtitle: meta.subtitle,
              progress: meta.progress,
              completed: meta.completed,
              focusId: FushiFocusId('games-collection-${collection.id}'),
              semanticLabel: '${collection.name} · ${meta.subtitle}',
              onTap: () => _openCollectionDetail(collection),
              onLongPress: openMenu,
              onSecondaryTap: openMenu,
            ),
    );
  }

  /// 单张游戏卡（散卡网格与合集行内共用同一构造，回调全量接线）。
  ///
  /// 外层 [MediaCardDraggable] = 拖卡进合集的拖拽源（桌面端；游戏库本就只在
  /// Windows 有实际使用场景）。合集行内的成员卡同样可拖——把成员从一个合集拖到
  /// 另一个合集行头即多归属（合集成员是多对多，不是移动）。
  Widget _buildGameCard(
    GalgameEntry game, {
    int? listIndex,
    int? listCount,
    FushiCoverBlockSize? block,
  }) {
    return MediaCardDraggable(
      mediaRef: MediaRef(kind: MediaKind.game, entryKey: game.id),
      label: game.displayName,
      child: _buildGameCardBody(
        game,
        listIndex: listIndex,
        listCount: listCount,
        block: block,
      ),
    );
  }

  /// 卡片菜单的执行体：与游戏首页同一份 [GalgameItemActions]（单一真相源，项目
  /// 与次序见 [galgameItemMenuItems]）。用本页 State 的 context 弹各对话框（卡片
  /// 可能在写操作后因重排被换掉），「详情」走库页自己的 [_openDetail]（带启动
  /// 回调、返回后重载）。仓储落库后自己通知本页刷新，合集映射不在仓储里，所以
  /// 每个动作执行完再重取一次（加入合集 / 刮削 / 移除都会改它）。
  GalgameItemActions _itemActionsFor(GalgameEntry game) => GalgameItemActions(
    context: context,
    ref: ref,
    game: game,
    onDetail: () => unawaited(_openDetail(game)),
    onChanged: () => unawaited(_afterItemAction()),
  );

  Future<void> _afterItemAction() async {
    if (!mounted) return;
    await _loadCollectionMaps();
    _refresh();
  }

  Widget _buildGameCardBody(
    GalgameEntry game, {
    int? listIndex,
    int? listCount,
    FushiCoverBlockSize? block,
  }) {
    return _GameCard(
      game: game,
      series: _gameScrapeArt.seriesOf(game),
      listIndex: listIndex,
      listCount: listCount,
      block: block,
      sortLabel: galgameSortValueLabel(game, _view.sortField),
      onTap: () => unawaited(_activateGame(game)),
      actions: _itemActionsFor(game),
    );
  }
}

/// 游戏网格的卡间距。
const double _kGameGridSpacing = 16;

/// 游戏库内容段的左右页边：与外壳大标题、浮动页签胶囊、工具行同一条左右缘
/// （[FushiSpacingTokens.page]，2026-10-06 库页顶部对齐）。
const double _kGameGridEdge = 20;

/// 游戏海报卡的目标宽度（ReinaManager 海报宽档）。
const double _kGameCardTargetWidth = 168;

/// 游戏网格几何：列数 + 实际卡宽。
///
/// 在途下载占位段、散卡网格、合集横排行三处共用同一份——三段的卡片必须逐像素同
/// 尺寸，各算各的迟早会分叉（BUG-1184 就是两处各写一遍死比例埋的雷）。
class _GameGridMetrics {
  const _GameGridMetrics({
    required this.columns,
    required this.cardWidth,
    required this.viewportWidth,
  });

  /// 复算 `MaxCrossAxisExtent(168)` 的列数与卡宽（ceil → 卡宽 ≤168）。
  ///
  /// [fixedColumns]：库页「每行数量」里用户定的列数（null = 自动）。
  factory _GameGridMetrics.forWidth(double maxWidth, {int? fixedColumns}) {
    // 网格段左右各一个页边的内边距。
    final double rawWidth = maxWidth - _kGameGridEdge * 2;
    final double available = rawWidth < 1 ? 1 : rawWidth;
    final int columns = (fixedColumns != null && fixedColumns > 0)
        ? fixedColumns
        : ((available + _kGameGridSpacing) /
                  (_kGameCardTargetWidth + _kGameGridSpacing))
              .ceil()
              .clamp(1, 1 << 10);
    return _GameGridMetrics(
      columns: columns,
      cardWidth: (available - (columns - 1) * _kGameGridSpacing) / columns,
      viewportWidth: maxWidth,
    );
  }

  final int columns;
  final double cardWidth;

  /// 库页主体的可用宽度（「继续游戏」横滑卡按它定宽）。
  final double viewportWidth;
}

/// 「继续游戏」横滑行最多几张。
const int _kContinueMaxItems = 10;

/// BUG-1911：从下载队列里挑出**尚未入库**的游戏下载（顶层纯函数，供测试直接驱动；
/// 同文件的 [buildGameCollectionMemberCard] 是同一个范式）。
List<DiscoveryDownloadTask> pendingGameDownloads(
  Iterable<DiscoveryDownloadTask> tasks,
) => <DiscoveryDownloadTask>[
  for (final DiscoveryDownloadTask task in tasks)
    if (task.item.kind == DiscoveryMediaKind.game && !task.isFinished) task,
];

/// BUG-1911：**尚未入库**的在途游戏下载。
///
/// 用户原话：「刚开始下载的、下载一半的应该也进到库里面占位。否则不知道是否加入了，
/// 毕竟发现已经获取到对应的名称和封面了」。
///
/// 刻意**不往 `Galgames` 表写占位行**：那张表的 `exePath` 是 NOT NULL，且没有任何
/// 状态列——一行存在就等于「本机有一个可启动的 exe」。为占位造一行意味着要么写个
/// 假路径，要么加 schema 列 + 迁移，还得回答「下载失败/取消后这行归谁删」「同步与
/// 墓碑怎么算」。而下载队列本身就是这些条目此刻的**唯一真相源**，并且随手就带着
/// 用户说的那两样东西（`item.title` / `item.coverUrl`）。所以占位是**渲染**出来的，
/// 不是**存**出来的：下载完成走既有的入库路径落成真条目；失败的留在块里标「下载
/// 失败」（在下载页重试 / 清除），取消的自然消失。
///
/// 只覆盖发现页的 HTTP 直链队列（shinnku / AList）——torrent 通道的游戏计划落 JSON
/// 文件、无变更通知，且 `AnimeDownloadPlan.coverUrl` 对游戏恒为 null，没有可占位的
/// 名称+封面。见本条 bug 档的备注。
///
/// 库页下载块逐项列的任务：游戏域里还在队列中（排队 / 下载中 / 等待重试）的，
/// 加上**失败**的——失败是用户得知道的真实状态（重试 / 清除在下载页）；已完成
/// 的已经落成库条目、取消的是用户自己放弃的，都不再列。
List<DiscoveryDownloadTask> gameDownloadBlockTasks(
  Iterable<DiscoveryDownloadTask> tasks,
) => <DiscoveryDownloadTask>[
  for (final DiscoveryDownloadTask task in tasks)
    if (task.item.kind == DiscoveryMediaKind.game &&
        (!task.isFinished || task.status == DiscoveryDownloadStatus.failed))
      task,
];

/// 下载任务的总进度（0..1）；总大小未知时为 null（不画进度条、不显示百分比）。
double? gameDownloadProgress(DiscoveryDownloadTask task) {
  final int? total = task.totalBytes;
  if (total == null || total <= 0) return null;
  return (task.receivedBytes / total).clamp(0.0, 1.0);
}

/// 下载块里一项的真实状态（设计稿：下载中 · xx% / 等待重试 / 排队中 / 失败）。
/// 下载队列没有「解压中」这一档，不编造。
String pendingGameDownloadLabel(DiscoveryDownloadTask task) {
  switch (task.status) {
    case DiscoveryDownloadStatus.running:
      final double? progress = gameDownloadProgress(task);
      if (progress == null) return t.game_library_downloading;
      return '${t.game_library_downloading} · '
          '${(progress * 100).toStringAsFixed(0)}%';
    case DiscoveryDownloadStatus.waitingRetry:
      return t.game_library_download_retrying;
    case DiscoveryDownloadStatus.queued:
      return t.game_library_download_queued;
    case DiscoveryDownloadStatus.failed:
      return t.game_library_download_failed;
    case DiscoveryDownloadStatus.done:
      return t.game_library_downloading;
    case DiscoveryDownloadStatus.cancelled:
      return t.download_status_cancelled;
  }
}

/// 游戏库下载块（设计稿「游戏 · 库」GA6）：一块卡片，头行「下载中 · N 项」+
/// 外部来源风险标（10-09 风险提示）+「打开下载 ›」（[onOpen] 非 null 时），下面
/// 逐项是「封面 + 标题 + 真实状态」（下载中带进度条）。放得下时平分一行，
/// 放不下（多于 3 项或窄屏）横向滑动。条目不可点——它们还不是能启动的游戏。
class GameDownloadsBlock extends StatelessWidget {
  const GameDownloadsBlock({required this.tasks, this.onOpen, super.key});

  final List<DiscoveryDownloadTask> tasks;
  final VoidCallback? onOpen;

  static const double _itemMinWidth = 220;
  static const double _itemHeight = 64;
  static const double _gap = 12;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final FushiTypography type = context.fushiType;
    final VoidCallback? open = onOpen;
    final Color warning = isEinkTheme(context)
        ? colors.onSurface
        : colors.tertiary;
    return FushiCard(
      key: const ValueKey<String>('games_downloads_block'),
      padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 8, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              FushiIcon(
                FushiIcons.downloading,
                size: 20,
                color: colors.primary,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  t.game_library_downloads_title(n: tasks.length),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: type.titleSmallEmphasized,
                ),
              ),
              const SizedBox(width: 10),
              FushiIcon(kExternalSourceIcon, size: 14, color: warning),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  t.download_source_external,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: type.labelSmall.copyWith(color: warning),
                ),
              ),
              const Spacer(),
              if (open != null)
                FushiTextButton(
                  key: const ValueKey<String>('games_downloads_open'),
                  onPressed: open,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(t.game_library_downloads_open),
                      const SizedBox(width: 2),
                      const FushiIcon(FushiIcons.chevronRight, size: 18),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final double width = constraints.maxWidth;
                final int fit = math.max(
                  1,
                  ((width + _gap) / (_itemMinWidth + _gap)).floor(),
                );
                if (tasks.length <= fit) {
                  return Row(
                    children: <Widget>[
                      for (int i = 0; i < tasks.length; i++) ...<Widget>[
                        if (i > 0) const SizedBox(width: _gap),
                        Expanded(
                          child: SizedBox(
                            height: _itemHeight,
                            child: _GameDownloadItem(task: tasks[i]),
                          ),
                        ),
                      ],
                    ],
                  );
                }
                return SizedBox(
                  height: _itemHeight,
                  child: ListView.separated(
                    key: const ValueKey<String>('games_downloads_strip'),
                    scrollDirection: Axis.horizontal,
                    itemCount: tasks.length,
                    separatorBuilder: (BuildContext context, int index) =>
                        const SizedBox(width: _gap),
                    itemBuilder: (BuildContext context, int i) => SizedBox(
                      width: _itemMinWidth,
                      child: _GameDownloadItem(task: tasks[i]),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 下载块里的一项：小封面（发现页拿到的封面，压暗以示还不能玩；没有就按标题
/// 生成）+ 标题 + 状态（失败用错误色）+ 下载中的进度条。读屏整项读一遍。
class _GameDownloadItem extends StatelessWidget {
  const _GameDownloadItem({required this.task});

  final DiscoveryDownloadTask task;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final FushiTypography type = context.fushiType;
    final String title = task.item.title;
    final String status = pendingGameDownloadLabel(task);
    final String? coverUrl = task.item.coverUrl;
    final double? progress =
        task.status == DiscoveryDownloadStatus.running ||
            task.status == DiscoveryDownloadStatus.waitingRetry
        ? gameDownloadProgress(task)
        : null;
    final bool failed = task.status == DiscoveryDownloadStatus.failed;
    final Widget generated = FushiGeneratedCover(title: title);
    return Semantics(
      container: true,
      label: '$title · $status',
      excludeSemantics: true,
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 40,
            height: 56,
            child: ClipRRect(
              borderRadius: FushiBorderRadius.chip,
              child: coverUrl != null && coverUrl.isNotEmpty
                  ? Opacity(
                      // 压暗以示「还不能玩」。
                      opacity: 0.45,
                      child: Image(
                        image: AppHttpImage(coverUrl),
                        fit: BoxFit.cover,
                        errorBuilder:
                            (
                              BuildContext context,
                              Object error,
                              StackTrace? stackTrace,
                            ) => generated,
                      ),
                    )
                  : generated,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: type.labelLargeEmphasized,
                ),
                const SizedBox(height: 2),
                Text(
                  status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: type.labelMedium.tabular.copyWith(
                    color: failed ? colors.error : colors.onSurfaceVariant,
                  ),
                ),
                if (progress != null) ...<Widget>[
                  const SizedBox(height: 6),
                  FushiLinearProgressIndicator(value: progress, wavy: false),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 游戏合集成员行在合集详情页（[buildGameCollectionMemberCard]）里画不画得出来：
/// 只认 game 行且 [games] 里还在的条目（已从库移除的孤儿引用、混合合集里的书 /
/// 视频都不算）。游戏库页与游戏详情页的「加入合集」共用它计数（BUG-3361）。
bool isGameCollectionMemberVisible({
  required List<GalgameEntry> games,
  required String mediaType,
  required String entryKey,
}) =>
    MediaKind.tryParse(mediaType) == MediaKind.game &&
    games.any((GalgameEntry g) => g.id == entryKey);

/// 合集详情页的 game 成员卡（纯查找 + 纯 widget，顶层函数供 widget 测试直接驱动）。
///
/// 非 game 成员返回 null（详情页跳过，混合合集里的书/视频由各自页面渲染）；game
/// 成员在 [games] 里找不到（已从库移除的孤儿引用）也返回 null。卡片不带 onTap——
/// 详情页网格统一接管激活（[MediaCollectionGridDetailPage.onOpenMember]）与
/// 上下文菜单（移出合集）。
///
/// [scrapeArt]：单个游戏的刮削资料 / 横版背景图（库页预取的
/// [GameItemScrapeArt]），色块下画系列色块用；不给 = 只看游戏自己的合并资料。
Widget? buildGameCollectionMemberCard({
  required List<GalgameEntry> games,
  required String mediaType,
  required String entryKey,
  GameItemScrapeArt scrapeArt = GameItemScrapeArt.empty,
}) {
  if (MediaKind.tryParse(mediaType) != MediaKind.game) return null;
  for (final GalgameEntry game in games) {
    if (game.id == entryKey) {
      // 详情页库页布局为拼贴 / 规整色块时，格子包了 [FushiCoverBlockScope]：换成
      // 与游戏库色块墙同一份色块视觉（[_GameCoverBlockCard] 的内容，不带卡壳——
      // 详情页格子统一接管点按 / 菜单 / 多选）。scope 在格子里，经 Builder 读。
      return Builder(
        builder: (BuildContext context) {
          final FushiCoverBlockSize? block = FushiCoverBlockScope.maybeOf(
            context,
          );
          if (block == null) {
            return GalgamePosterCard(
              cover: GameCoverThumb(game: game),
              title: game.displayName,
            );
          }
          final FushiSeriesMeta? series = scrapeArt.seriesOf(game);
          return fushiSeriesCoverBlock(
            size: block,
            art: series == null
                ? FushiCoverBlockArt.box
                : FushiCoverBlockArt.portrait,
            meta: series,
            backdrop: fushiSeriesBackdrop(series?.backdrop),
            covers: <Widget>[GameCoverThumb(game: game)],
            tintImage: _gameCoverImage(game),
            title: game.displayName,
            eyebrow: game.developer,
            figure: galgamePlayTimeFigure(game.totalPlaySeconds),
            subtitle: _blockSubtitle(
              galgameCardMetaLabel(game, includePlayTime: false),
              game.developer,
            ),
            progress: game.playStatus == GalgamePlayStatus.played ? 1 : null,
            completed: game.playStatus == GalgamePlayStatus.played,
          );
        },
      );
    }
  }
  return null;
}

/// 游戏的系列色块元数据（与视频库系列卡同一套 [FushiSeriesMeta]）：标签 / 评分 /
/// 发行年任一项、或横版背景图 / 艺术字（[backdrop] / [logo]，来自 `item_images`）
/// 存在时非 null。概览 = 标签前两个 · ★ 站点评分，chip = 发行年。
///
/// 标签 / 评分 / 年份以游戏自己的合并资料为准；[scrape]（`item_scrape_meta` 行）
/// 只补合并资料里缺的那几项，不覆盖。
FushiSeriesMeta? galgameSeriesMeta(
  GalgameEntry game, {
  ItemScrapeMetaRow? scrape,
  ImageProvider? backdrop,
  ImageProvider? logo,
}) {
  final GalgameMetadataDraft meta = game.metadata;
  final List<String> tags = meta.tags.isNotEmpty
      ? meta.tags.take(2).toList(growable: false)
      : fushiScrapeTagNames(scrape?.tagsJson, limit: 2);
  final double? ownScore = meta.score;
  final double? score = ownScore != null && ownScore > 0
      ? ownScore
      : scrape?.rating;
  final int? year =
      fushiScrapeYear(game.releaseDate ?? meta.releaseDate) ??
      fushiScrapeYear(scrape?.airDate);
  if (tags.isEmpty &&
      (score == null || score <= 0) &&
      year == null &&
      backdrop == null &&
      logo == null) {
    return null;
  }
  return FushiSeriesMeta.fromParts(
    backdrop: backdrop,
    logo: logo,
    genres: tags,
    rating: score,
    chipParts: <String>[if (year != null) '$year'],
  );
}

/// 游戏库预取的单个游戏刮削附加数据（`item_scrape_meta` + `item_images`，键 =
/// `Galgames.id`）：库页 [GameItemScrapeArt.load] 一次批量取好、文件存在性也在
/// 那里探好，卡片构建只查内存映射（零查询 / 零 IO）。
@immutable
class GameItemScrapeArt {
  const GameItemScrapeArt({
    this.scrapeById = const <String, ItemScrapeMetaRow>{},
    this.backdropPathById = const <String, String>{},
    this.logoPathById = const <String, String>{},
  });

  /// 没有任何刮削附加数据。
  static const GameItemScrapeArt empty = GameItemScrapeArt();

  /// 游戏 id → 刮削资料行。
  final Map<String, ItemScrapeMetaRow> scrapeById;

  /// 游戏 id → position 最小且文件还在的横版背景图路径。
  final Map<String, String> backdropPathById;

  /// 游戏 id → position 最小且文件还在的艺术字路径。
  final Map<String, String> logoPathById;

  /// 一条资料查询 + 每种图一条查询，按游戏分桶；文件存在性异步探好。
  static Future<GameItemScrapeArt> load(FushiDatabase db) async {
    final String game = MediaKind.game.dbValue;
    final Map<String, ItemScrapeMetaRow> scrape = <String, ItemScrapeMetaRow>{
      for (final ItemScrapeMetaRow row in await db.getAllItemScrapeMeta())
        if (row.mediaType == game) row.entryKey: row,
    };
    Future<Map<String, String>> firstExisting(MediaImageKind kind) async {
      final List<ItemImageRow> rows =
          (await db.getItemImagesOfKind(kind))
              .where(
                (ItemImageRow r) => r.mediaType == game && r.path.isNotEmpty,
              )
              .toList()
            ..sort(
              (ItemImageRow a, ItemImageRow b) =>
                  a.position.compareTo(b.position),
            );
      final Map<String, String> out = <String, String>{};
      for (final ItemImageRow row in rows) {
        if (out.containsKey(row.entryKey)) continue;
        if (await File(row.path).exists()) out[row.entryKey] = row.path;
      }
      return out;
    }

    return GameItemScrapeArt(
      scrapeById: scrape,
      backdropPathById: await firstExisting(MediaImageKind.backdrop),
      logoPathById: await firstExisting(MediaImageKind.logo),
    );
  }

  /// [game] 刮削过没有：游戏自己的合并资料（[GalgameEntry.metadata]，元数据刮削
  /// 写回的）非空，或本映射里有它的刮削资料行 / 横版背景图 / 艺术字。库页点卡据此
  /// 决定先进详情页还是直接启动。
  bool hasScrapeFor(GalgameEntry game) =>
      !game.metadata.isEmpty ||
      scrapeById.containsKey(game.id) ||
      backdropPathById.containsKey(game.id) ||
      logoPathById.containsKey(game.id);

  /// [game] 的系列色块元数据（[galgameSeriesMeta] 叠上本映射里的刮削资料 /
  /// 背景图 / 艺术字）。
  FushiSeriesMeta? seriesOf(GalgameEntry game) {
    final String? backdrop = backdropPathById[game.id];
    final String? logo = logoPathById[game.id];
    return galgameSeriesMeta(
      game,
      scrape: scrapeById[game.id],
      backdrop: backdrop == null ? null : resizedFileImage(File(backdrop)),
      logo: logo == null ? null : resizedFileImage(File(logo)),
    );
  }
}

/// [collectionIds] 里各合集附加图组中 [kind] 种类、position 最小且文件还在的那张
/// （collectionId → 路径）：一条 [FushiDatabase.getMediaImagesOfKind] 查询取全库
/// 该种类再按归属分桶（书架 `_firstExistingCollectionImages` 同口径）。
Future<Map<int, String>> _firstExistingGameCollectionImages(
  FushiDatabase db,
  MediaImageKind kind,
  Set<int> collectionIds,
) async {
  if (collectionIds.isEmpty) return const <int, String>{};
  final List<MediaImageRow> rows =
      (await db.getMediaImagesOfKind(kind))
          .where(
            (MediaImageRow r) =>
                collectionIds.contains(r.collectionId) && r.path.isNotEmpty,
          )
          .toList()
        ..sort(
          (MediaImageRow a, MediaImageRow b) =>
              a.position.compareTo(b.position),
        );
  final Map<int, String> out = <int, String>{};
  for (final MediaImageRow row in rows) {
    final int cid = row.collectionId!;
    if (out.containsKey(cid)) continue;
    if (await File(row.path).exists()) out[cid] = row.path;
  }
  return out;
}

/// 合集详情头部扇形用的 game 成员纯封面（与 [buildGameCollectionMemberCard] 同一
/// 查找口径）；非 game 成员或孤儿引用返回 null。
Widget? gameCollectionMemberCover({
  required List<GalgameEntry> games,
  required String mediaType,
  required String entryKey,
}) {
  if (MediaKind.tryParse(mediaType) != MediaKind.game) return null;
  for (final GalgameEntry game in games) {
    if (game.id == entryKey) return GameCoverThumb(game: game);
  }
  return null;
}

/// 游戏合集成员的 NSFW 宿主：成人向标记（编辑页开关 / 刮削）并入合集继承判定。
/// 游戏不在当前列表里（已删 / 未加载）时只按成员行判定。
MediaNsfwTarget? gameCollectionMemberNsfw({
  required List<GalgameEntry> games,
  required String mediaType,
  required String entryKey,
}) {
  if (MediaKind.tryParse(mediaType) != MediaKind.game) {
    return MediaNsfwTarget.collectionMember(mediaType, entryKey);
  }
  for (final GalgameEntry game in games) {
    if (game.id == entryKey) {
      return MediaNsfwTarget.game(game.id, adult: game.isNsfw);
    }
  }
  return MediaNsfwTarget.game(entryKey, adult: false);
}

/// 游玩状态的用户可读标签（枚举 `.name` 直接上屏是 17 语言用户的灾难）。
String galgamePlayStatusLabel(GalgamePlayStatus status) => switch (status) {
  GalgamePlayStatus.unset => t.game_status_unset,
  GalgamePlayStatus.wantToPlay => t.game_status_want_to_play,
  GalgamePlayStatus.played => t.game_status_played,
  GalgamePlayStatus.playing => t.game_status_playing,
  GalgamePlayStatus.onHold => t.game_status_on_hold,
  GalgamePlayStatus.dropped => t.game_status_dropped,
};

/// 排序维度的用户可读标签。
String galgameSortFieldLabel(GalgameSortField field) => switch (field) {
  GalgameSortField.added => t.game_sort_added,
  GalgameSortField.releaseDate => t.game_sort_release,
  GalgameSortField.lastPlayed => t.game_sort_last_played,
  GalgameSortField.siteScore => t.game_sort_site_score,
  GalgameSortField.userRating => t.game_sort_user_rating,
  GalgameSortField.name => t.game_sort_name,
  GalgameSortField.manual => t.sort_manual,
};

/// 本地/在线筛选的用户可读标签。
String galgameLocalFilterLabel(GalgameLocalFilter filter) => switch (filter) {
  GalgameLocalFilter.all => t.game_filter_all,
  GalgameLocalFilter.localOnly => t.game_filter_local_only,
  GalgameLocalFilter.metadataOnly => t.game_filter_metadata_only,
};

/// 卡片「排序字段浮层」的文案：显示当前排序维度在这条游戏上的值。
///
/// 按添加时间/名称排序时返回 null（日期没信息量、名字就在标题里），不画浮层。
String? galgameSortValueLabel(GalgameEntry game, GalgameSortField field) {
  switch (field) {
    case GalgameSortField.added:
    case GalgameSortField.name:
    case GalgameSortField.manual:
      return null;
    case GalgameSortField.releaseDate:
      return game.effectiveReleaseDate;
    case GalgameSortField.lastPlayed:
      if (game.lastPlayedMs <= 0) return t.game_never_played;
      return formatGalgameDate(
        DateTime.fromMillisecondsSinceEpoch(game.lastPlayedMs),
      );
    case GalgameSortField.siteScore:
      return game.siteScore?.toStringAsFixed(1);
    case GalgameSortField.userRating:
      return game.userRating?.toStringAsFixed(1);
  }
}

/// `YYYY-MM-DD` 本地日期（与 `galgame_sessions.dateKey` 同格式）。委托
/// [FushiTimeFormat.dayKey]（G5 收敛）。
String formatGalgameDate(DateTime value) => FushiTimeFormat.dayKey(value);

/// 单个游戏卡：封面（有 coverPath 用图，否则默认手柄图标）+ 固定 footer 名称 +
/// 溢出菜单。点击卡片启动游戏进入制卡，长按/右键出同款菜单（含「查看详情」）。
///
/// 走 [FushiCard]（巡检 G1 根因修复）：注册 `game-card-<id>` 焦点站点，手柄/
/// 方向键可选中、A/Enter 启动；长按（手柄 hold A 之外的触摸长按）与鼠标右键弹
/// 出与封面溢出菜单相同的菜单，封面上的 [PopupMenuButton] 保留供鼠标点按。
class _GameCard extends StatelessWidget {
  const _GameCard({
    required this.game,
    required this.onTap,
    required this.actions,
    this.series,
    this.sortLabel,
    this.listIndex,
    this.listCount,
    this.block,
  });

  final GalgameEntry game;

  /// 系列色块元数据（库页预取映射算好的 [GameItemScrapeArt.seriesOf]；null =
  /// 没有任何刮削资料 / 背景图，色块保持盒封摆法）。
  final FushiSeriesMeta? series;

  /// 非 null = 封面色块卡（库页布局为拼贴 / 规整色块，见 [SliverFushiCoverBlocks]）；
  /// 菜单与回调与海报卡同一份。列表布局（[listIndex]）优先。
  final FushiCoverBlockSize? block;

  /// 非 null = 以列表布局的分段卡行渲染（本行在组内的位置 / 组内总行数，决定
  /// 首尾大圆角）；null = 竖版海报卡。两种外观共用同一份菜单与回调。
  final int? listIndex;
  final int? listCount;

  /// 当前排序维度在这条游戏上的值（null = 不画浮层）。
  final String? sortLabel;

  /// 点卡 = 启动游戏。
  final VoidCallback onTap;

  /// 菜单执行体（与游戏首页共用的 [GalgameItemActions]，库页 State 构造）。
  final GalgameItemActions actions;

  /// 长按 / 右键的上下文菜单：与书卡/视频卡同款 `MediaItemDialogFrame`（封面块 +
  /// 快捷动作 chips + 底部危险区），菜单项与列表行溢出菜单**共用**
  /// [galgameItemMenuItems] 与 [GalgameItemActions.dispatch]（游戏首页也是这一份）。
  /// 用卡片自己的 context 弹：库页的「排序」入口挂在卡片祖先的
  /// [LibraryReorderScope] 上，菜单据此补一项「排序」。
  Future<void> _showContextMenu(BuildContext context) =>
      showGalgameItemActionsMenu(context: context, actions: actions);

  void _onScrape() => actions.dispatch(GalgameItemAction.scrape);

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final String? sort = sortLabel;
    // 透明卡盒卡（1:1.6 封面 + 封面下文字块 + 悬停柔光 + 主色选中环），全部由
    // 共享组件 [GalgamePosterCard] 负责。
    // focusId 沿用 `game-card-<id>`（手柄/键盘可 requestById 聚焦，focus 测试守）。
    //
    // 手柄重设计 P4：卡片聚焦时 X = 打开详情（A=启动、长按 A=上下文菜单在
    // GalgamePosterCard 内）。非 X 的按钮必须**显式转发**给祖先 Actions（home 的
    // LT/RT 换 tab、Y 搜索都注册在那里）——覆写 isEnabled 做不到这件事：
    // Actions.maybeInvoke 的上溯停止条件是「本层注册了这个 Intent 类型没有」，
    // 与 enabled 无关，详见 [GamepadButtonForwardingAction] 的类文档。
    //
    // 用 X 不用 Y：游戏库是 home tab，与 home scope 同 co-active 组，而 Y 在那里
    // 已经绑给了注册表动作 homeFocusSearch（shortcut_defaults）。卡片聚焦时抢 Y
    // 就是把一个**可配置、设置页里看得见**的动作静默吞掉——而游戏库里焦点几乎总
    // 在某张卡上，等于该 tab 里 Y=搜索永久失效。home 组的手柄默认只占 LT/RT/Y，
    // X 是空的；X 的其它绑定都在 reader / video / dictionaryPopup 组，不同组不同
    // 时激活，无遮蔽。
    // NSFW：游戏自己的成人向标记（编辑页开关 / 刮削）或所在 NSFW 合集 → 封面
    // 按「模糊 NSFW 封面」打模糊（卡内封面框读这一层）。
    final Widget body = Actions(
      actions: <Type, Action<Intent>>{
        GamepadButtonIntent: GamepadButtonForwardingAction(
          ancestorContext: context,
          handle: (GamepadButton button) {
            if (button != GamepadButton.x) return false;
            actions.dispatch(GalgameItemAction.detail);
            return true;
          },
        ),
      },
      child: listIndex != null && listCount != null
          ? _buildListRow(context, colors, listIndex!, listCount!)
          : block != null
          ? _GameCoverBlockCard(
              size: block!,
              art: FushiCoverBlockArt.box,
              // 无封面：不画手柄 / 灰占位，色块按标题生成首字封面并取同一色相
              // （[FushiCoverBlock] 的 covers 为空分支），右上角配「刮削」chip。
              covers: _gameCoverImage(game) == null
                  ? const <Widget>[]
                  : <Widget>[GameCoverThumb(game: game)],
              tintImage: _gameCoverImage(game),
              title: game.displayName,
              // 色块卡（设计稿 `.gb`）：开发商进顶上 chip，累计时长画成大数字，
              // 副行只留排序值 / 游玩状态；时长为 0 时不画大数字，改画真实游玩
              // 状态 chip（6 档，状态不再重复进副行）。拼贴首块画「启动游戏」
              // 按钮外观（点卡 / A 就是启动）。
              eyebrow: game.developer,
              figure: galgamePlayTimeFigure(game.totalPlaySeconds),
              statusChip: game.totalPlaySeconds > 0
                  ? null
                  : GalgamePlayStatusChip(status: game.playStatus),
              subtitle: _blockSubtitle(
                game.totalPlaySeconds > 0
                    ? galgameCardMetaLabel(
                        game,
                        sortLabel: sort,
                        includePlayTime: false,
                      )
                    : sort,
                game.developer,
              ),
              onScrape: _gameCoverImage(game) == null ? _onScrape : null,
              // 没有封面时系列色块无从斜放海报，仍走盒封摆法（首字生成封面）。
              series: _gameCoverImage(game) == null ? null : series,
              action: block == FushiCoverBlockSize.hero
                  ? FushiCoverBlockAction(
                      icon: FushiIcons.play,
                      label: t.game_launch,
                    )
                  : null,
              progress: game.playStatus == GalgamePlayStatus.played ? 1 : null,
              completed: game.playStatus == GalgamePlayStatus.played,
              focusId: FushiFocusId('game-card-${game.id}'),
              semanticLabel: galgameBlockSemanticLabel(game),
              onTap: onTap,
              onLongPress: () => unawaited(_showContextMenu(context)),
            )
          // 卡盒卡：封面上不压角标也不放 ⋯ 按钮（2026-10-25 定版）——游玩状态 /
          // 排序值 / 时长进副行，菜单走长按 / 右键 / 手柄长按 A（同一份 galgameItemMenuItems）。
          : GalgamePosterCard(
              cover: GameCoverThumb(game: game),
              title: game.displayName,
              subtitle: galgameCardMetaLabel(game, sortLabel: sort),
              progress: game.playStatus == GalgamePlayStatus.played ? 1 : null,
              completed: game.playStatus == GalgamePlayStatus.played,
              focusId: FushiFocusId('game-card-${game.id}'),
              onTap: onTap,
              onLongPress: () => unawaited(_showContextMenu(context)),
              onSecondaryTap: () => unawaited(_showContextMenu(context)),
              semanticLabel: game.displayName,
            ),
    );
    return MediaNsfwCoverScope(
      target: MediaNsfwTarget.game(game.id, adult: game.isNsfw),
      child: body,
    );
  }

  /// 列表布局的一行（M3E 分段卡）：3:4 小封面（卡内小件 12）+ 标题 / 开发商 ·
  /// 发行日；宽屏（≥640）右侧再排游玩状态、游玩时长、最后游玩三列，窄屏收成
  /// 标题下一行（状态角标 + 时长 · 最后游玩）。行尾更多菜单。
  ///
  /// 焦点站点与海报卡同一个 `game-card-<id>`（手柄 / 方向键逐行可达，A/Enter
  /// 启动，长按 A / 长按 / 右键出同一份上下文菜单，X = 详情由外层 Actions 接）。
  Widget _buildListRow(
    BuildContext context,
    ColorScheme colors,
    int index,
    int count,
  ) {
    final FushiTypography type = context.fushiType;
    final Widget? badge = galgamePlayStatusBadge(game.playStatus);
    final String byline = <String?>[
      game.developer,
      game.effectiveReleaseDate,
    ].whereType<String>().where((String v) => v.trim().isNotEmpty).join(' · ');
    final String? playTime = game.totalPlaySeconds > 0
        ? formatStatTime(game.totalPlaySeconds * 1000)
        : null;
    final String lastPlayed = game.lastPlayedMs > 0
        ? formatGalgameDate(
            DateTime.fromMillisecondsSinceEpoch(game.lastPlayedMs),
          )
        : t.game_never_played;
    final TextStyle metaStyle = type.labelMedium.tabular.copyWith(
      color: colors.onSurfaceVariant,
    );
    void openMenu() => unawaited(_showContextMenu(context));
    return GamepadLongPressActions(
      onLongPress: openMenu,
      child: FushiGroupedListItem(
        key: ValueKey<String>('game-list-row-${game.id}'),
        index: index,
        count: count,
        focusId: FushiFocusId('game-card-${game.id}'),
        onTap: onTap,
        onLongPress: openMenu,
        onSecondaryTap: openMenu,
        child: Semantics(
          label: game.displayName,
          button: true,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final bool wide = constraints.maxWidth >= 640;
              final Widget titleBlock = Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    game.displayName,
                    maxLines: wide ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: type.titleMediumEmphasized,
                  ),
                  if (byline.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        byline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: type.bodyMedium.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  if (!wide)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          if (badge != null) badge,
                          Text(
                            <String>[
                              if (playTime != null) playTime,
                              lastPlayed,
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: metaStyle,
                          ),
                        ],
                      ),
                    ),
                ],
              );
              return Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                child: Row(
                  children: <Widget>[
                    // 行首色点：封面取色（设计稿 GA7 列表模式保留为密集选项）。
                    _GameListColorDot(game: game),
                    const SizedBox(width: 10),
                    // 列表行小缩略图：卡盒材质简化档（用户 2026-10-26）——
                    // 只有圆角 + 外圈 + 轻光泽，不画投影 / 扫光。列表段不在
                    // 网格的材质 Scope 里，这里就地给。
                    SizedBox(
                      width: wide ? 54 : 48,
                      child: AspectRatio(
                        aspectRatio: 3 / 4,
                        child: ShelfCoverMaterialScope(
                          material: ShelfCoverMaterial.gameCase,
                          child: ShelfCoverFrame(
                            density: ShelfCoverDensity.compact,
                            child: GameCoverThumb(game: game),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(child: titleBlock),
                    if (wide) ...<Widget>[
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 112,
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: badge == null
                              ? const SizedBox.shrink()
                              : FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: AlignmentDirectional.centerStart,
                                  child: badge,
                                ),
                        ),
                      ),
                      _ListMetaCell(
                        icon: FushiIcons.timer,
                        label: t.game_library_play_time,
                        value: playTime ?? '—',
                        style: metaStyle,
                      ),
                      _ListMetaCell(
                        icon: FushiIcons.history,
                        label: t.game_sort_last_played,
                        value: lastPlayed,
                        style: metaStyle,
                      ),
                    ],
                    FushiPopupMenuButton<GalgameItemAction>(
                      tooltip: t.common_more_actions,
                      icon: FushiIcon(
                        isGlassDesign(context)
                            ? FushiIcons.moreHoriz
                            : FushiIcons.more,
                      ),
                      onSelected: actions.dispatch,
                      itemBuilder: (BuildContext context) =>
                          <PopupMenuEntry<GalgameItemAction>>[
                            for (final GalgameItemMenuItem item
                                in galgameItemMenuItems(game))
                              PopupMenuItem<GalgameItemAction>(
                                value: item.action,
                                child: Text(item.label),
                              ),
                          ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 游戏封面缩略图（库页卡片 / 合集行成员卡 / 合集详情成员卡共用）。
///
/// 有 coverPath 且文件真实存在 → 经 [ShelfFileCover] 降采样加载（BUG-959 同类：
/// 旧裸 `Image.file` 整帧解码游戏包装图会撑爆 ImageCache）；否则共享占位件
/// [ShelfCoverPlaceholder]（保留原 surfaceContainerHighest 底色 + 手柄图标 48）。
/// existsSync 短路语义保留：缺失文件直接画占位，不进图片加载失败路径。
/// 游戏封面的取色图源（与 [GameCoverThumb] 同一文件）；无封面为 null。
ImageProvider? _gameCoverImage(GalgameEntry? game) {
  final String? cover = game?.coverPath;
  if (cover == null || cover.isEmpty || !File(cover).existsSync()) return null;
  return resizedFileImage(File(cover));
}

/// 游戏库的封面色块卡（色块布局下代替 [GalgamePosterCard]）：卡壳与海报卡同一
/// 套——[shelfCoverCard]（点击 / Enter / 焦点 / 右键）+ 手柄长按 A + 悬停抬升 +
/// 语义标签；视觉是 [FushiCoverBlock]。
class _GameCoverBlockCard extends StatelessWidget {
  const _GameCoverBlockCard({
    required this.size,
    required this.art,
    required this.covers,
    required this.tintImage,
    required this.title,
    required this.focusId,
    required this.semanticLabel,
    required this.onTap,
    required this.onLongPress,
    this.subtitle,
    this.progress,
    this.completed = false,
    this.eyebrow,
    this.figure,
    this.action,
    this.statusChip,
    this.onScrape,
    this.series,
  });

  /// 非 null = 有刮削资料 / 横版背景图的游戏或合集：与视频库系列卡同一个系列
  /// 色块（竖版封面斜放 + 背景图 + 概览「类型 · ★ 评分」+ chip「年份」，见
  /// [galgameSeriesMeta] / [collectionSeriesMeta]），[art] 让位给竖版海报摆法。
  final FushiSeriesMeta? series;

  /// 底部附加件：游玩状态 chip（时长为 0 时代替大数字，见 [GalgamePlayStatusChip]）。
  final Widget? statusChip;

  /// 非 null = 右上角画「刮削」chip（无封面的游戏，设计稿「刮削信息」）：视觉
  /// 26 高、命中区 48×48，点了直接走刮削。不是独立焦点目标（卡片无独立按钮
  /// 纪律），键盘 / 手柄从上下文菜单的「刮削元数据」进同一个动作。
  final VoidCallback? onScrape;

  final FushiCoverBlockSize size;
  final String? eyebrow;
  final FushiCoverBlockFigure? figure;
  final FushiCoverBlockAction? action;
  final FushiCoverBlockArt art;
  final List<Widget> covers;
  final ImageProvider? tintImage;
  final String title;
  final String? subtitle;
  final double? progress;
  final bool completed;
  final FushiFocusId focusId;
  final String semanticLabel;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final Widget card = shelfCoverCard(
      focusId: focusId,
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTap: onLongPress,
      child: fushiSeriesCoverBlock(
        size: size,
        art: series == null ? art : FushiCoverBlockArt.portrait,
        meta: series,
        backdrop: fushiSeriesBackdrop(series?.backdrop),
        covers: covers,
        tintImage: tintImage,
        title: title,
        subtitle: subtitle,
        progress: progress,
        completed: completed,
        eyebrow: eyebrow,
        figure: figure,
        action: action,
        trailing: statusChip,
      ),
    );
    final VoidCallback? scrape = onScrape;
    // 「刮削」chip 叠在色块里（随悬停抬升一起动）：Stack 先命中后画的 chip，
    // 点 chip 不会再落到底下的卡片点按（启动）上。
    final Widget body = scrape == null
        ? card
        : Stack(
            children: <Widget>[
              Positioned.fill(child: card),
              PositionedDirectional(
                top: 4,
                end: 4,
                child: GameScrapeInfoChip(onPressed: scrape),
              ),
            ],
          );
    return GamepadLongPressActions(
      onLongPress: onLongPress,
      child: Semantics(
        label: semanticLabel,
        button: true,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: FushiHoverLift(builder: (BuildContext _, bool __) => body),
        ),
      ),
    );
  }
}

class GameCoverThumb extends StatelessWidget {
  const GameCoverThumb({required this.game, super.key});

  final GalgameEntry game;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Widget placeholder = ShelfCoverPlaceholder(
      icon: FushiIcons.games,
      iconSize: 48,
      backgroundColor: colors.surfaceContainerHighest,
    );
    final String? cover = game.coverPath;
    if (cover != null && cover.isNotEmpty && File(cover).existsSync()) {
      return ShelfFileCover(path: cover, placeholder: placeholder);
    }
    return placeholder;
  }
}

/// 游戏卡封面下的副行（2026-10-25 卡盒定版：原先压在封面上的状态角标 / 排序
/// 浮层全部进这一行）。规则，按序用「 · 」连接：
/// 1. [sortLabel]：当前排序维度在这条游戏上的值（发行日 / 评分 / 最近游玩；按
///    添加时间 / 名称排序时为 null，见 [galgameSortValueLabel]）；
/// 2. 游玩状态（未设置不写）；
/// 3. 累计游玩时长（> 0 才写）。
/// 三样都没有时：从没玩过 →「未游玩」；玩过但没时长 → 开发商 / 发行日（都没有
/// 时为 null，网格行高仍按含这一行算，卡片逐行对齐）。
///
/// [includePlayTime] = false：时长另由色块卡的大数字画（[galgamePlayTimeFigure]），
/// 副行不再重复。
String? galgameCardMetaLabel(
  GalgameEntry game, {
  String? sortLabel,
  bool includePlayTime = true,
}) {
  final List<String> parts = <String>[
    if (sortLabel != null && sortLabel.isNotEmpty) sortLabel,
    if (game.playStatus != GalgamePlayStatus.unset)
      galgamePlayStatusLabel(game.playStatus),
    if (includePlayTime && game.totalPlaySeconds > 0)
      formatStatTime(game.totalPlaySeconds * 1000),
  ];
  if (parts.isNotEmpty) return parts.join(' · ');
  if (game.lastPlayedMs <= 0) return t.game_never_played;
  return game.developer ?? game.effectiveReleaseDate;
}

/// 合集折叠卡的副行与进度：「N 项 · 累计时长」（成员都没玩过时不写时长）；进度
/// 条 = 已通关（[GalgamePlayStatus.played]）成员占比，一个都没通关时不画，全部
/// 通关时换完成色。
///
/// [includePlayTime] 同 [galgameCardMetaLabel]；[seconds] 是成员累计游玩秒数
/// （色块卡的大数字用）。
({String subtitle, double? progress, bool completed, int seconds})
galgameCollectionMeta(
  List<GalgameEntry> members, {
  bool includePlayTime = true,
}) {
  int seconds = 0;
  int played = 0;
  for (final GalgameEntry game in members) {
    seconds += game.totalPlaySeconds;
    if (game.playStatus == GalgamePlayStatus.played) played++;
  }
  final String subtitle = <String>[
    t.game_collection_work_count(n: members.length),
    if (includePlayTime && seconds > 0) formatStatTime(seconds * 1000),
  ].join(' · ');
  return (
    subtitle: subtitle,
    progress: played == 0 || members.isEmpty ? null : played / members.length,
    completed: members.isNotEmpty && played == members.length,
    seconds: seconds,
  );
}

/// 色块卡副行：与顶上 chip（开发商）同文时不重复画（[galgameCardMetaLabel] 在
/// 没状态没时长时回落开发商）。
String? _blockSubtitle(String? label, String? eyebrow) =>
    label == null || label == eyebrow ? null : label;

/// 色块卡的游玩时长大数字（设计稿 `.gb .hrs`）：不满 1 小时按分钟，10 小时内保留
/// 一位小数，再往上取整。没玩过（0 秒）为 null。
FushiCoverBlockFigure? galgamePlayTimeFigure(int seconds) {
  if (seconds <= 0) return null;
  if (seconds < 3600) {
    return FushiCoverBlockFigure(
      value: '${(seconds / 60).round().clamp(1, 60)}',
      unit: t.shelf_block_play_minutes_unit,
    );
  }
  final double hours = seconds / 3600;
  final String value = hours < 10
      ? hours.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '')
      : '${hours.round()}';
  return FushiCoverBlockFigure(
    value: value,
    unit: t.shelf_block_play_hours_unit,
  );
}

/// 游玩状态图标（列表行 / 「继续游戏」卡的状态角标 / 详情页状态胶囊共用）。
IconData galgamePlayStatusIcon(GalgamePlayStatus status) => switch (status) {
  GalgamePlayStatus.unset => FushiIcons.flag,
  GalgamePlayStatus.wantToPlay => FushiIcons.bookmark,
  GalgamePlayStatus.playing => FushiIcons.play,
  GalgamePlayStatus.played => FushiIcons.check,
  GalgamePlayStatus.onHold => FushiIcons.pause,
  GalgamePlayStatus.dropped => FushiIcons.close,
};

/// 游玩状态对应的 M3E 饱和色块档：在玩 = primary（最强调）、玩过 = tertiary、
/// 想玩 = secondary、弃坑 = error；搁置 / 未设置 = null（中性）。
FushiCardTone? galgamePlayStatusTone(GalgamePlayStatus status) =>
    switch (status) {
      GalgamePlayStatus.playing => FushiCardTone.primary,
      GalgamePlayStatus.played => FushiCardTone.tertiary,
      GalgamePlayStatus.wantToPlay => FushiCardTone.secondary,
      GalgamePlayStatus.dropped => FushiCardTone.error,
      GalgamePlayStatus.onHold || GalgamePlayStatus.unset => null,
    };

/// 游玩状态角标（[GalgameStatusBadge]：MD3 = M3E 饱和色块胶囊；Apple / 墨水屏 =
/// 共享 [CoverBadge] 磨砂暗底 / 实色），只用在列表行与「继续游戏」卡的文字栏里，
/// **不再压在卡盒封面上**（封面卡的状态走副行，见 [galgameCardMetaLabel]）；未设置
/// 状态不画（满屏「未设置」只是噪音）。
Widget? galgamePlayStatusBadge(GalgamePlayStatus status) {
  if (status == GalgamePlayStatus.unset) return null;
  return GalgameStatusBadge(status: status);
}

/// 游玩状态角标。
///
/// MD3（M3E）：全圆角胶囊，底色是状态对应的饱和 container 色块（[galgamePlayStatusTone]：
/// 在玩 primaryContainer / 玩过 tertiaryContainer / 想玩 secondaryContainer / 弃坑
/// errorContainer / 搁置 surfaceContainerHighest）+ onContainer 图标与 labelSmall
/// Emphasized 文字——压在封面上也读得出「是哪种状态」，而不是一排同色暗角标比字。
/// Apple 与墨水屏沿用共享 [CoverBadge]（iOS 磨砂暗底 / 墨水屏实色），不在封面上
/// 放 15% 淡染块（Apple tone 是为页面底设计的，压在照片上读不出）。
class GalgameStatusBadge extends StatelessWidget {
  const GalgameStatusBadge({required this.status, super.key});

  final GalgamePlayStatus status;

  @override
  Widget build(BuildContext context) {
    final IconData icon = galgamePlayStatusIcon(status);
    final String label = galgamePlayStatusLabel(status);
    if (isGlassDesign(context) || isEinkTheme(context)) {
      return CoverBadge(icon: icon, label: label, iconSize: 12);
    }
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiCardTone? tone = galgamePlayStatusTone(status);
    final FushiCardColors? toned = tone == null
        ? null
        : fushiCardToneColors(context, tone);
    final Color container = toned?.container ?? cs.surfaceContainerHighest;
    final Color onContainer = toned?.onContainer ?? cs.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 3, 8, 3),
      decoration: ShapeDecoration(
        color: container,
        shape: const StadiumBorder(),
        shadows: <BoxShadow>[
          BoxShadow(
            color: cs.shadow.withValues(alpha: 0.18),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiIcon(icon, size: 14, color: onContainer),
          const SizedBox(width: 4),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.fushiType.labelSmallEmphasized.copyWith(
              color: onContainer,
            ),
          ),
        ],
      ),
    );
  }
}

/// 游戏库窄屏工具条溢出菜单里除排序维度外的动作。
enum _GamesToolbarOverflowAction { scrapeAll, viewOptions }

/// 游戏库列表行宽屏的一格元信息：小图标 + 值（等宽数字），整格带语义标签。
class _ListMetaCell extends StatelessWidget {
  const _ListMetaCell({
    required this.icon,
    required this.label,
    required this.value,
    required this.style,
  });

  final IconData icon;
  final String label;
  final String value;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 120,
      child: Semantics(
        label: '$label $value',
        excludeSemantics: true,
        child: FushiTooltip(
          message: label,
          child: Row(
            children: <Widget>[
              FushiIcon(icon, size: 16, color: style.color),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 游戏库「网格 / 列表」切换钮（页头动作；与视频库「全部视频」的布局切换同形：
/// 图标显示**切过去**的那种布局）。写偏好 `games_library_layout`，
/// [GamesLibraryPage] 监听偏好跟着换；本钮也随偏好变化重建。
class GamesLibraryLayoutToggle extends ConsumerWidget {
  const GamesLibraryLayoutToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PreferencesRepository prefs = ref.read(appProvider).prefsRepo;
    return ListenableBuilder(
      listenable: prefs,
      builder: (BuildContext context, Widget? _) {
        final bool list = prefs.gamesLibraryListLayout;
        final String label = list
            ? t.game_library_view_grid
            : t.game_library_view_list;
        return FushiIconButton(
          key: const ValueKey<String>('games-library-layout-toggle'),
          tooltip: label,
          label: label,
          icon: list ? FushiIcons.gridView : FushiIcons.listView,
          onTap: () => unawaited(prefs.setGamesLibraryListLayout(!list)),
        );
      },
    );
  }
}

/// 去掉首尾空白后为空就当没有（开发商等可空元数据进 chip 前用）。
String? _nonEmptyOrNull(String? value) {
  final String? trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : value;
}

/// 色块卡的读屏标签（设计稿「千恋＊万花，38 小时，在玩」读一次）：名字 + 累计
/// 时长（> 0 才读）+ 游玩状态（时长为 0 时连「未设置」也读，与画出来的状态 chip
/// 一致；有时长时未设置不读）。
String galgameBlockSemanticLabel(GalgameEntry game) {
  final bool played = game.totalPlaySeconds > 0;
  return <String>[
    game.displayName,
    if (played) formatStatTime(game.totalPlaySeconds * 1000),
    if (!played || game.playStatus != GalgamePlayStatus.unset)
      galgamePlayStatusLabel(game.playStatus),
  ].join(' · ');
}

/// 游玩状态色点（设计稿「6 档游玩状态 chip」表）：深色 / 浅色两套，在各自的
/// 色块底上与 chip 文字一起都 ≥4.5:1。没有「已通关」这一档——[GalgamePlayStatus]
/// 只有 6 档，「玩过」就是它。
Color galgamePlayStatusDotColor(
  GalgamePlayStatus status,
  Brightness brightness,
) {
  final bool dark = brightness == Brightness.dark;
  return switch (status) {
    GalgamePlayStatus.unset =>
      dark ? const Color(0xFF8F8B96) : const Color(0xFF6B6E7B),
    GalgamePlayStatus.wantToPlay =>
      dark ? const Color(0xFFA9C8FF) : const Color(0xFF2F62C9),
    GalgamePlayStatus.playing =>
      dark ? const Color(0xFF9BE0AB) : const Color(0xFF1D8A45),
    GalgamePlayStatus.played =>
      dark ? const Color(0xFFE7CF6F) : const Color(0xFF8A6A00),
    GalgamePlayStatus.onHold =>
      dark ? const Color(0xFFC9C6CF) : const Color(0xFF5D5A66),
    GalgamePlayStatus.dropped =>
      dark ? const Color(0xFFFF9B9B) : const Color(0xFFB3261E),
  };
}

/// 色块里的游玩状态 chip（设计稿 `.chip.stc`）：底 = 状态色点 24% 叠在色块底色
/// 上，图标取状态色、文字取所在色块的前景色（[DefaultTextStyle]）。时长为 0 的
/// 游戏用它代替大数字（不再用「未游玩」顶替真实状态），「继续游戏」色块的状态
/// 角标也是它。墨水屏退成描边胶囊。视觉 20 高（色块文字区附加件槽位的高度）。
class GalgamePlayStatusChip extends StatelessWidget {
  const GalgamePlayStatusChip({required this.status, super.key});

  final GalgamePlayStatus status;

  @override
  Widget build(BuildContext context) {
    final bool eink = isEinkTheme(context);
    final Color foreground =
        DefaultTextStyle.of(context).style.color ??
        Theme.of(context).colorScheme.onSurface;
    final Color dot = eink
        ? foreground
        : galgamePlayStatusDotColor(status, Theme.of(context).brightness);
    final String label = galgamePlayStatusLabel(status);
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Container(
        key: ValueKey<String>('galgame-status-chip-${status.name}'),
        height: 20,
        padding: const EdgeInsetsDirectional.fromSTEB(6, 0, 8, 0),
        decoration: ShapeDecoration(
          color: eink ? null : dot.withValues(alpha: 0.24),
          shape: StadiumBorder(
            side: eink ? BorderSide(color: foreground) : BorderSide.none,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FushiIcon(galgamePlayStatusIcon(status), size: 12, color: dot),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.fushiType.labelSmallEmphasized.copyWith(
                  color: foreground,
                  height: 1.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 无封面游戏色块右上角的「刮削」chip（设计稿「⟳ 刮削信息」）：视觉 26 高的
/// 胶囊，命中区外扩到 48×48；点了走该游戏的刮削。不注册焦点站点（卡片内不放
/// 独立焦点目标），键盘 / 手柄从上下文菜单「刮削元数据」进同一个动作。
class GameScrapeInfoChip extends StatelessWidget {
  const GameScrapeInfoChip({required this.onPressed, super.key});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    // chip 叠在色块外层（不在 [FushiCoverBlock] 的前景 DefaultTextStyle 里），
    // 底是 surfaceContainerHighest，文字固定取与之配对的 onSurface。
    final Color foreground = colors.onSurface;
    return Semantics(
      button: true,
      label: t.game_scrape,
      excludeSemantics: true,
      child: ExcludeFocus(
        child: FushiPressScale(
          child: GestureDetector(
            key: const ValueKey<String>('game-scrape-info-chip'),
            behavior: HitTestBehavior.opaque,
            onTap: onPressed,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              child: Center(
                widthFactor: 1,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      color: colors.surfaceContainerHighest.withValues(
                        alpha: 0.88,
                      ),
                      shape: const StadiumBorder(),
                    ),
                    child: SizedBox(
                      height: 26,
                      child: Padding(
                        padding: const EdgeInsetsDirectional.fromSTEB(
                          8,
                          0,
                          10,
                          0,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            FushiIcon(
                              FushiIcons.manageSearch,
                              size: 14,
                              color: colors.onSurfaceVariant,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              t.game_scrape,
                              maxLines: 1,
                              style: context.fushiType.labelSmallEmphasized
                                  .copyWith(color: foreground),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 库页 Hook 会话带（设计稿「游戏 · 库」GA5）：**只在有 Hook 会话时出现**，显示
/// 游戏名 + 已抓台词数 + 最新一行台词，整条点进捕获工作台；空闲时整条收起（高度
/// + 透明度过渡，网格不跳），工作台仍可从二级页签进。只在 Windows 挂（galgame
/// Hook 只做 Windows，见 [_GamesLibraryPageState._windowsSession]）。
///
/// 游戏名取会话活动记账的标题（库页启动时握着的身份），缺席时按启动 exe 在库里
/// 反查；都没有时写「正在捕获」。台词数与最新一行只算本次会话、当前线程的行
/// （[GalHookSessionController.selectedSessionLines]），不把上一局的历史缓冲算进来。
class _GameSessionBand extends StatelessWidget {
  const _GameSessionBand({
    required this.controller,
    required this.games,
    required this.onOpen,
  });

  final GalHookSessionController controller;
  final List<GalgameEntry> games;
  final VoidCallback onOpen;

  String _title(GalHookSessionState state) {
    final String? activity = _nonEmptyOrNull(controller.activityGameTitle);
    if (activity != null) return activity;
    for (final GalgameEntry game in games) {
      if (galHookSessionRunsGame(
        controller,
        gameId: game.id,
        exePath: game.exePath,
      )) {
        return game.displayName;
      }
    }
    return t.game_capture_active;
  }

  @override
  Widget build(BuildContext context) {
    final Duration duration = fushiMotionDuration(context, FushiMotion.medium);
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        final GalHookSessionState state = controller.state;
        return FushiAnimatedSize(
          duration: duration,
          curve: FushiMotion.standard,
          alignment: AlignmentDirectional.topStart,
          child: AnimatedSwitcher(
            duration: duration,
            switchInCurve: FushiMotion.enter,
            switchOutCurve: FushiMotion.exit,
            child: state.isActive
                ? Padding(
                    key: const ValueKey<String>('games-session-band'),
                    padding: const EdgeInsets.fromLTRB(
                      _kGameGridEdge,
                      8,
                      _kGameGridEdge,
                      0,
                    ),
                    child: _buildCard(context, state),
                  )
                : const SizedBox(
                    key: ValueKey<String>('games-session-band-idle'),
                    width: double.infinity,
                  ),
          ),
        );
      },
    );
  }

  Widget _buildCard(BuildContext context, GalHookSessionState state) {
    final bool eink = isEinkTheme(context);
    final FushiTypography type = context.fushiType;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Color? onCard = eink
        ? null
        : fushiCardToneColors(context, FushiCardTone.primary)?.onContainer;
    final Color secondary = onCard ?? colors.onSurfaceVariant;
    final List<TexthookerLineEntry> lines = controller.selectedSessionLines;
    final GalWorkbenchReadiness readiness = galWorkbenchReadiness(
      state: state,
      requiresTextThread: controller.requiresTextThreadSelection,
      selectedTextThreadKey: controller.selectedTextThreadKey,
    );
    final String detail = readiness == GalWorkbenchReadiness.waitingForThread
        ? t.game_session_waiting_thread
        : lines.isEmpty
        ? t.game_waiting_for_text
        : '「${lines.last.text}」';
    final String title = _title(state);
    final String captured = t.game_library_session_captured(n: lines.length);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide = constraints.maxWidth >= 600;
        return FushiCard(
          key: const ValueKey<String>('games-session-band-card'),
          focusId: const FushiFocusId('games-session-band'),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          tone: eink ? FushiCardTone.neutral : FushiCardTone.primary,
          selected: eink,
          onTap: onOpen,
          child: Row(
            children: <Widget>[
              FushiListLeadingIcon(
                FushiIcons.filled(FushiIcons.audio),
                shape: FushiLeadingShape.cookie,
                tone: FushiCardTone.tertiary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text.rich(
                      TextSpan(
                        children: <InlineSpan>[
                          TextSpan(
                            text: '${t.game_library_session_playing}  ',
                            style: type.labelLarge.copyWith(color: secondary),
                          ),
                          TextSpan(
                            text: title,
                            style: type.labelLargeEmphasized.copyWith(
                              color: onCard,
                            ),
                          ),
                          TextSpan(
                            text: '  ·  $captured',
                            style: type.labelLarge.tabular.copyWith(
                              color: secondary,
                            ),
                          ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: type.bodySmall.copyWith(color: secondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (wide)
                Text(
                  t.game_open_capture_workspace,
                  maxLines: 1,
                  style: type.labelLarge.copyWith(color: onCard),
                ),
              FushiIcon(FushiIcons.chevronRight, color: secondary, size: 20),
            ],
          ),
        );
      },
    );
  }
}

/// 列表行行首的色点（设计稿 GA7「行首色点用封面取色」）：有封面取封面配色的
/// primary（与「继续」取色卡同一份缓存，[FushiCoverTint]），没封面取生成封面
/// 的同一色相；还没算好 / 墨水屏 / Apple 外观退回中性描边色。纯装饰，不读屏。
class _GameListColorDot extends StatelessWidget {
  const _GameListColorDot({required this.game});

  final GalgameEntry game;

  @override
  Widget build(BuildContext context) {
    final ImageProvider? cover = _gameCoverImage(game);
    final ThemeData theme = Theme.of(context);
    return ExcludeSemantics(
      child: FushiCoverTint(
        image: cover,
        builder: (BuildContext context, ColorScheme? scheme) {
          final Color color =
              scheme?.primary ??
              (cover == null && !isEinkTheme(context)
                  ? FushiGeneratedCoverColors.of(
                      theme.brightness,
                      fushiGeneratedCoverHue(game.displayName),
                    ).start
                  : theme.colorScheme.outlineVariant);
          return Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          );
        },
      ),
    );
  }
}
